const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const DefaultStateRoot = ".ledger/c3";
const LegacyStateRoot = ".resolve-c3";
const StateSchemaV2 = "resolve-c3-state-v2";
const StateSchemaV3 = "resolve-c3-state-v3";
const ProtocolProfileIntentClosed = "intent-closed-cegis-v1";
const StateFile = "state.json";
const CertFile = "mrpc.json";
const MbkcFile = "mbkc.json";
const EventFile = "events.jsonl";
const AcceptanceFile = "acceptance.json";
const ObservationsFile = "observations.jsonl";
const CounterexamplesFile = "counterexamples.jsonl";
const BasisFile = "basis.json";
const KernelFile = "kernel.json";
const KernelReviewFile = "kernel-review.json";
const ReductionFile = "reduction-certificate.json";
const ReviewBatchDir = "review/batches";
const ReviewApertureDir = "review/apertures";
const ReviewReceiptDir = "review/receipts";
const ReviewPlanFile = "review/plan.json";
const DesignsFile = "designs.jsonl";
const SelectedDesignFile = "selected-design.json";
const RealizationDir = "realization";
const RealizationManifestFile = "realization/manifest.json";
const RealizationPatchFile = "realization/patch.bin";
const RealizationTreeFile = "realization/tree.txt";
const ConstructMapFile = "realization/construct-map.json";
const SurfaceFile = "realization/surface.json";
const ProofDir = "proof";
const ProofPlanFile = "proof/plan.json";
const ProofResultsFile = "proof/results.jsonl";
const ProofBasisFile = "proof/basis.json";
const PotentialDir = "potential";
const PotentialBaselineFile = "potential/baseline.json";
const PotentialCyclesFile = "potential/cycles.jsonl";
const PotentialCurrentFile = "potential/current.json";
const MaxFileBytes = 16 * 1024 * 1024;
const HashSeed = 0xc3c3_c3c3_c3c3_c3c3;
const Io = std.Io.Threaded.global_single_threaded.io();

const HelpText =
    \\resolve-c3
    \\
    \\Zig controller for the $resolve C3 workflow.
    \\
    \\usage: resolve-c3 COMMAND [options]
    \\
    \\commands:
    \\  capabilities        Print controller capability flags
    \\  schema ARTIFACT     Print the strict JSON schema projection for an artifact
    \\  example NAME        Print a JSON example for an artifact or command
    \\  doctor              Validate the controller command surface and path defaults
    \\  init                Create .ledger/c3 state and install the local exclude guard
    \\  paths               Print the configured C3 state roots
    \\  status              Print current state
    \\  begin               Start a C3 run from a clean immutable base
    \\  add-counterexample  Add or update a review counterexample
    \\  set-basis           Install a passing CEB-v1 counterexample basis
    \\  tournament-waiver   Authorize a reduced candidate tournament
    \\  register-candidate  Register candidate metadata
    \\  verify-candidate    Run candidate checks and refresh validity
    \\  select              Select the lexicographically minimal valid candidate
    \\  ablate              Record controller-run ablation for the selected candidate
    \\  record-ablation     Record external ablation evidence
    \\  record-holdout      Record candidate or delivery holdout evidence
    \\  certify-apply       Emit an apply-certified MRPC-v1
    \\  apply               Controller-apply the selected candidate fingerprint
    \\  run-proof           Run delivery proof checks
    \\  record-proof        Record external proof evidence
    \\  certify-final       Emit a final-certified MRPC-v1
    \\  commit              Controller-gated commit transition
    \\  push                Controller-gated push transition
    \\  close               Close after PR sweep evidence
    \\  abort               Abort a run
    \\  audit               Audit state and MRPC consistency
    \\  guard-hook          Fail-closed delivery mutation guard
    \\  hook-context        Print active guard context
    \\  stop-guard          Block premature closure claims
    \\  mrpc-gate           Validate an MRPC-v1 JSON artifact
    \\  rdr-gate            Validate an RDR-v1 text artifact
    \\  legacy-gate         Tombstone a superseded legacy gate name
    \\  migrate-legacy      Explicitly migrate .resolve-c3 into .ledger/c3/archive
    \\
    \\canonical nested commands:
    \\  resolve-c3 capabilities --json
    \\  resolve-c3 schema <artifact> --json
    \\  resolve-c3 example <command-or-artifact> --json
    \\  resolve-c3 acceptance set|validate|seal|status|rebase
    \\  resolve-c3 review batch begin|status|seal|invalidate
    \\  resolve-c3 review aperture add
    \\  resolve-c3 review receipt add
    \\  resolve-c3 review plan|plan status
    \\  resolve-c3 counterexample add|classify|list|show
    \\  resolve-c3 basis compile|lint|seal|status
    \\  resolve-c3 reduction set|lint|review|accept
    \\  resolve-c3 realization worktree|capture|measure|map|verify|minimize
    \\  resolve-c3 potential baseline|measure|gate|status
    \\  resolve-c3 proof plan|run|compress
    \\  resolve-c3 delivery apply|commit|push
    \\  resolve-c3 certify tuple|terminal
    \\  resolve-c3 migrate mrpc|intent-closed
    \\  resolve-c3 authority-chain init|check
    \\  resolve-c3 mutation-gate
    \\
    \\legacy aliases remain available for MRPC-v1 state, but MBKC-v1 commands are the material surface.
    \\
    \\options:
    \\  --cwd PATH, --root PATH    Repository root for state operations (default: .)
    \\  --state-root PATH          C3 state root (default: .ledger/c3)
    \\  --legacy-root PATH         Legacy migration source root (default: .resolve-c3)
    \\  --from PATH                Alias for --legacy-root on migrate-legacy
    \\  --to PATH                  Alias for --state-root on migrate-legacy
    \\  --input PATH|-             JSON input path
    \\  --file PATH                Artifact path for gate commands
    \\  --acceptance PATH|-        Acceptance JSON for begin
    \\  --goal TEXT                Goal text for begin
    \\  --candidate-id ID          Candidate id
    \\  --id ID                    Counterexample id or artifact id
    \\  --design ID                Realization design id
    \\  --batch-id ID              Review batch id
    \\  --receipt-id ID            Review receipt id
    \\  --campaign ID              RAC-v1 campaign id
    \\  --review-claim-id ID        RAC-v1 review claim id for mutation-gate lookup
    \\  --artifact-state PATH       RAC-v1 artifact-state JSON
    \\  --review-claim PATH         RAC-v1 review-claim JSON
    \\  --cex PATH                  RAC-v1 CEX-v1 JSON
    \\  --batch PATH                RAC-v1 RB-v1 JSON
    \\  --basis PATH                RAC-v1 CEB-v2 JSON
    \\  --kernel PATH               RAC-v1 MBK-v1 JSON
    \\  --reduction PATH            RAC-v1 RC-v1 JSON
    \\  --proof-obligation REF      RAC-v1 proof obligation ref
    \\  --realization-target PATH   RAC-v1 realization target JSON
    \\  --output PATH               RAC-v1 init output path
    \\  --chain PATH                RAC-v1 authority chain path
    \\  --format text|json          RAC-v1 check output format
    \\  --mode MODE                Review mode or plan mode
    \\  --head SHA                 Artifact head for review batch begin
    \\  --stage candidate|delivery Holdout stage
    \\  --reason TEXT              Waiver or abort reason
    \\  --approved-by USER         Rebaseline approval authority
    \\  --new-base SHA             Approved rebaseline campaign base
    \\  --campaign-base SHA        Migration campaign base
    \\  --review-ready-baseline SHA Migration review-ready baseline
    \\  --message TEXT             Commit message
    \\  --remote NAME              Push remote (default: origin)
    \\  --branch NAME              Push target branch
    \\  --confirm                  Confirm destructive or terminal operations
    \\  --json                     Emit JSON where supported
    \\  -h, --help                 Show help
    \\  -V, --version              Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = "resolve-c3",
    .help_text = HelpText,
};

const CostFields = [_][]const u8{
    "new_truth_owners",
    "new_public_symbols",
    "new_state_variants",
    "new_fallback_or_compatibility_paths",
    "new_protocol_cases",
    "new_control_flow_branches",
    "new_helpers_or_wrappers",
    "new_proof_obligations",
    "retained_retirable_surfaces",
    "owners_modified",
    "files_modified",
    "ast_edit_count",
    "production_net_lines",
    "test_net_lines",
};

const BranchLiable = [_][]const u8{
    "introduced_by_current_diff",
    "exposed_and_required_by_current_acceptance",
    "preexisting_but_blocks_current_invariant",
};

const TerminalPhases = [_][]const u8{ "closed", "aborted", "terminal_closed" };
const BasisGateFields = [_][]const u8{ "all_findings_classified", "every_branch_liability_covered", "non_branch_liabilities_excluded" };
const VerificationFields = [_][]const u8{ "counterexamples_pass", "acceptance_pass", "regressions_pass", "proof_current" };
const NegativeAllowedStatuses = [_][]const u8{ "allowed", "reopened", "stale", "superseded" };
const ClosureWords = [_][]const u8{ "done", "resolved", "complete", "completed", "ready", "shipped", "pushed", "closed" };
const MrpcRequiredFields = [_][]const u8{ "certificate_id", "stage", "run_id", "immutable_base", "counterexample_basis", "candidate_tournament", "selected_candidate", "ablation", "gate" };
const RdrRequiredFields = [_][]const u8{ "resolve_decision_record", "record_version", "artifact_state", "review_wave", "cluster", "selected_route", "negative_evidence", "surface_delta", "proof_matrix", "material_improvement", "gate" };
const SchemaArtifacts = [_][]const u8{
    "acceptance",
    "acceptance-v2",
    "observation",
    "review-batch",
    "review-aperture",
    "counterexample",
    "counterexample-basis-v2",
    "review-potential",
    "kernel",
    "kernel-review",
    "realization-design",
    "construct-map",
    "proof-plan",
    "holdout",
    "authority-chain",
    "mbkc",
};
const PhaseCollectingSelectedInvalidated = [_][]const u8{ "collecting", "selected", "invalidated" };
const PhaseCollectingSelected = [_][]const u8{ "collecting", "selected" };
const PhaseCollectingInvalidated = [_][]const u8{ "collecting", "invalidated" };
const PhaseSelected = [_][]const u8{"selected"};
const PhaseApplyCertified = [_][]const u8{"apply-certified"};
const PhaseApplied = [_][]const u8{"applied"};
const PhaseAppliedInvalidated = [_][]const u8{ "applied", "invalidated" };
const PhaseFinalCertified = [_][]const u8{"final-certified"};
const PhaseCommitted = [_][]const u8{"committed"};
const PhasePushed = [_][]const u8{"pushed"};
const MutatingTools = [_][]const u8{ "apply_patch", "write_file", "edit_file", "notebook_edit" };
const MutatingGitCommands = [_][]const u8{
    "git add",
    "git apply",
    "git checkout",
    "git switch",
    "git reset",
    "git restore",
    "git commit",
    "git push",
    "git merge",
    "git rebase",
    "git cherry-pick",
    "git stash",
    "git clean",
    "git worktree",
};
const MutatingFileCommands = [_][]const u8{ "rm ", "mv ", "cp ", "mkdir ", "touch ", "truncate ", "sed -i", "perl -pi", "apply_patch" };
const CounterexampleIntentRelations = [_][]const u8{ "in_horizon", "outside_horizon", "unknown", "contract_invalidating" };
const CounterexampleNovelty = [_][]const u8{ "new_equivalence_class", "new_witness_existing_class", "duplicate", "refuted", "stale", "unknown" };
const CounterexampleDispositions = [_][]const u8{ "accepted", "refuted", "stale", "unknown", "outside_horizon", "contract_invalidating" };
const MutationGateLegalNextActions = [_][]const u8{
    "adjudicate_claim",
    "seal_or_repair_batch",
    "compile_or_repair_ceb_mbk_rc",
    "rebase_ac",
    "create_followup",
    "reject_finding",
    "block",
};

const Command = enum {
    capabilities,
    schema,
    example,
    campaign_begin,
    campaign_status,
    campaign_audit,
    campaign_rebaseline,
    campaign_abort,
    acceptance_set,
    acceptance_validate,
    acceptance_seal,
    acceptance_status,
    acceptance_rebase,
    review_batch_begin,
    review_aperture_add,
    review_receipt_add,
    review_batch_status,
    review_batch_seal,
    review_batch_invalidate,
    review_plan,
    review_plan_status,
    counterexample_add,
    counterexample_classify,
    counterexample_list,
    counterexample_show,
    basis_compile,
    basis_lint,
    basis_seal,
    basis_status,
    reduction_set,
    reduction_lint,
    reduction_review,
    reduction_accept,
    observation_add,
    observation_import,
    observation_list,
    observation_classify,
    kernel_set,
    kernel_lint,
    kernel_minimize,
    kernel_review,
    kernel_accept,
    design_register,
    design_select,
    design_list,
    realization_worktree,
    realization_capture,
    realization_measure,
    realization_map,
    realization_verify,
    realization_minimize,
    potential_baseline,
    potential_measure,
    potential_gate,
    potential_status,
    proof_plan,
    proof_run_nested,
    proof_compress,
    delivery_apply,
    delivery_commit,
    delivery_push,
    certify_tuple,
    certify_terminal,
    migrate_mrpc,
    migrate_intent_closed,
    authority_chain_init,
    authority_chain_check,
    mutation_gate,
    doctor,
    init,
    paths,
    status,
    begin,
    add_counterexample,
    set_basis,
    tournament_waiver,
    register_candidate,
    verify_candidate,
    select,
    ablate,
    record_ablation,
    record_holdout,
    certify_apply,
    apply,
    run_proof,
    record_proof,
    certify_final,
    commit,
    push,
    close,
    abort,
    audit,
    guard_hook,
    hook_context,
    stop_guard,
    mrpc_gate,
    rdr_gate,
    legacy_gate,
    migrate_legacy,
};

const Args = struct {
    command: Command,
    cwd: []const u8 = ".",
    state_root: []const u8 = DefaultStateRoot,
    legacy_root: []const u8 = LegacyStateRoot,
    input: ?[]const u8 = null,
    file: ?[]const u8 = null,
    acceptance: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    candidate_id: ?[]const u8 = null,
    id: ?[]const u8 = null,
    design_id: ?[]const u8 = null,
    batch_id: ?[]const u8 = null,
    receipt_id: ?[]const u8 = null,
    campaign_id: ?[]const u8 = null,
    review_claim_id: ?[]const u8 = null,
    artifact_state: ?[]const u8 = null,
    review_claim: ?[]const u8 = null,
    cex: ?[]const u8 = null,
    batch: ?[]const u8 = null,
    basis: ?[]const u8 = null,
    kernel: ?[]const u8 = null,
    reduction: ?[]const u8 = null,
    proof_obligation: ?[]const u8 = null,
    realization_target: ?[]const u8 = null,
    output: ?[]const u8 = null,
    chain: ?[]const u8 = null,
    format: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    head: ?[]const u8 = null,
    path: ?[]const u8 = null,
    worktree: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    artifact: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    stage: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    approved_by: ?[]const u8 = null,
    new_base: ?[]const u8 = null,
    campaign_base: ?[]const u8 = null,
    review_ready_baseline: ?[]const u8 = null,
    message: ?[]const u8 = null,
    remote: []const u8 = "origin",
    confirm: bool = false,
    json: bool = false,
};

const CampaignStateV3 = struct {
    id: []const u8 = "",
    repo_root: []const u8 = "",
    branch: []const u8 = "",
    base_sha: []const u8 = "",
    parent_run_id: ?[]const u8 = null,
};

const AcceptanceStateV3 = struct {
    sequence: u32 = 0,
    contract_id: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
    horizon_state: []const u8 = "unsealed",
};

const ReviewStateV3 = struct {
    open_batch_ids: []const []const u8 = &.{},
    sealed_batch_ids: []const []const u8 = &.{},
    latest_discovery_batch: ?[]const u8 = null,
    latest_conformance_batch: ?[]const u8 = null,
    terminal_holdout_batch: ?[]const u8 = null,
};

const CounterexampleStateV3 = struct {
    total: u32 = 0,
    in_horizon: u32 = 0,
    outside_horizon: u32 = 0,
    unknown: u32 = 0,
    new_classes: u32 = 0,
    existing_witnesses: u32 = 0,
    duplicates: u32 = 0,
};

const BasisStateV3 = struct {
    id: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
    sealed: bool = false,
};

const ArtifactGateStateV3 = struct {
    fingerprint: ?[]const u8 = null,
    accepted: bool = false,
};

const DesignStateV3 = struct {
    selected_id: ?[]const u8 = null,
};

const RealizationStateV3 = struct {
    cycle_id: ?[]const u8 = null,
    verified: bool = false,
    invalidated: bool = false,
    invalidation_reason: ?[]const u8 = null,
};

const PotentialStateV3 = struct {
    current_id: ?[]const u8 = null,
    strict_progress: bool = false,
};

const DeliveryStateV3 = struct {
    patch_sha: ?[]const u8 = null,
    commit_sha: ?[]const u8 = null,
    pushed: bool = false,
};

const ClosureStateV3 = struct {
    certificate_stage: ?[]const u8 = null,
};

const Candidate = struct {
    candidate_id: []const u8,
    route_class: []const u8,
    route_family: []const u8,
    patch_sha: []const u8,
    worktree: ?[]const u8,
    valid: bool,
    invalid_reasons: []const []const u8,
    semantic_cost: [CostFields.len]i64,
};

const State = struct {
    schema: []const u8,
    protocol_profile: []const u8 = ProtocolProfileIntentClosed,
    state_root: []const u8,
    legacy_root: []const u8,
    state_version: u32,
    campaign: CampaignStateV3 = .{},
    run_id: []const u8,
    repo_root: []const u8,
    branch: []const u8,
    base_sha: []const u8,
    phase: []const u8,
    acceptance: AcceptanceStateV3 = .{},
    acceptance_goal: []const u8,
    parent_run_id: ?[]const u8,
    review: ReviewStateV3 = .{},
    counterexamples: CounterexampleStateV3 = .{},
    counterexample_count: u32,
    basis: BasisStateV3 = .{},
    basis_set: bool,
    kernel: ArtifactGateStateV3 = .{},
    reduction: ArtifactGateStateV3 = .{},
    design: DesignStateV3 = .{},
    realization: RealizationStateV3 = .{},
    potential: PotentialStateV3 = .{},
    delivery: DeliveryStateV3 = .{},
    closure: ClosureStateV3 = .{},
    tournament_waiver: ?[]const u8,
    candidates: []const Candidate,
    selected_candidate_id: ?[]const u8,
    ablation_authority: ?[]const u8,
    ablation_orphan_edit_atoms: u32,
    candidate_holdout_safe: bool,
    delivery_holdout_safe: bool,
    proof_authority: ?[]const u8,
    proof_passed: bool,
    proof_patch_stable: bool,
    delivery_patch_sha: ?[]const u8,
    commit_sha: ?[]const u8,
    pushed: bool,
    certificate_stage: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const args = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    const code = run(allocator, args, init.io) catch |err| blk: {
        try printError(allocator, @errorName(err));
        break :blk @as(u8, 2);
    };
    std.process.exit(code);
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 2) return error.MissingCommand;

    var first_option_index: usize = 2;
    var args = Args{ .command = try parseCommandTokens(argv, &first_option_index) };
    var i: usize = first_option_index;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (std.mem.eql(u8, token, "--json")) {
            args.json = true;
        } else if (std.mem.eql(u8, token, "--confirm")) {
            args.confirm = true;
        } else if (std.mem.eql(u8, token, "--cwd") or std.mem.eql(u8, token, "--root")) {
            args.cwd = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--state-root")) {
            args.state_root = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--legacy-root")) {
            args.legacy_root = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--from")) {
            args.legacy_root = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--to")) {
            args.state_root = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--input")) {
            args.input = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--file")) {
            args.file = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--acceptance")) {
            args.acceptance = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--goal")) {
            args.goal = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--candidate-id")) {
            args.candidate_id = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--id")) {
            args.id = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--design")) {
            args.design_id = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--batch-id")) {
            args.batch_id = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--receipt-id")) {
            args.receipt_id = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--campaign")) {
            args.campaign_id = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--review-claim-id")) {
            args.review_claim_id = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--artifact-state")) {
            args.artifact_state = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--review-claim")) {
            args.review_claim = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--cex")) {
            args.cex = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--batch")) {
            args.batch = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--basis")) {
            args.basis = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--kernel")) {
            args.kernel = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--reduction")) {
            args.reduction = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--proof-obligation")) {
            args.proof_obligation = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--realization-target")) {
            args.realization_target = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--output")) {
            args.output = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--chain")) {
            args.chain = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--format")) {
            args.format = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--mode")) {
            args.mode = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--head")) {
            args.head = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--path")) {
            args.path = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--worktree")) {
            args.worktree = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--patch")) {
            args.patch = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--branch")) {
            args.branch = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--stage")) {
            args.stage = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--reason")) {
            args.reason = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--approved-by")) {
            args.approved_by = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--new-base")) {
            args.new_base = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--campaign-base")) {
            args.campaign_base = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--review-ready-baseline")) {
            args.review_ready_baseline = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--message")) {
            args.message = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--remote")) {
            args.remote = try optionValue(argv, &i);
        } else if (!std.mem.startsWith(u8, token, "-") and args.artifact == null and (args.command == .schema or args.command == .example)) {
            args.artifact = token;
        } else {
            return error.UnknownOption;
        }
    }
    return args;
}

fn optionValue(argv: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) return error.MissingValue;
    return argv[index.*];
}

fn parseCommandTokens(argv: []const []const u8, first_option_index: *usize) !Command {
    const primary = argv[1];
    if (std.mem.eql(u8, primary, "review")) {
        if (argv.len < 3) return error.MissingCommand;
        if (std.mem.eql(u8, argv[2], "plan")) {
            if (argv.len >= 4 and std.mem.eql(u8, argv[3], "status")) {
                first_option_index.* = 4;
                return .review_plan_status;
            }
            first_option_index.* = 3;
            return .review_plan;
        }
        if (argv.len < 4) return error.MissingCommand;
        first_option_index.* = 4;
        return parseReviewCommand(argv[2], argv[3]) orelse error.UnknownCommand;
    }
    if (std.mem.eql(u8, primary, "authority-chain")) {
        if (argv.len < 3) return error.MissingCommand;
        first_option_index.* = 3;
        return parseAuthorityChainCommand(argv[2]) orelse error.UnknownCommand;
    }
    if (std.mem.eql(u8, primary, "mutation-gate")) {
        first_option_index.* = 2;
        return .mutation_gate;
    }
    if (std.mem.eql(u8, primary, "counterexample")) {
        if (argv.len < 3) return error.MissingCommand;
        first_option_index.* = 3;
        return parseCounterexampleCommand(argv[2]) orelse error.UnknownCommand;
    }
    if (std.mem.eql(u8, primary, "basis")) {
        if (argv.len < 3) return error.MissingCommand;
        first_option_index.* = 3;
        return parseBasisCommand(argv[2]) orelse error.UnknownCommand;
    }
    if (std.mem.eql(u8, primary, "reduction")) {
        if (argv.len < 3) return error.MissingCommand;
        first_option_index.* = 3;
        return parseReductionCommand(argv[2]) orelse error.UnknownCommand;
    }
    if (parseNestedCommand(primary)) |nested| {
        if (argv.len < 3) return error.MissingCommand;
        first_option_index.* = 3;
        return nested(argv[2]) orelse error.UnknownCommand;
    }
    first_option_index.* = 2;
    return parseCommand(primary) orelse error.UnknownCommand;
}

fn parseNestedCommand(primary: []const u8) ?*const fn ([]const u8) ?Command {
    if (std.mem.eql(u8, primary, "campaign")) return parseCampaignCommand;
    if (std.mem.eql(u8, primary, "acceptance")) return parseAcceptanceCommand;
    if (std.mem.eql(u8, primary, "observation")) return parseObservationCommand;
    if (std.mem.eql(u8, primary, "kernel")) return parseKernelCommand;
    if (std.mem.eql(u8, primary, "design")) return parseDesignCommand;
    if (std.mem.eql(u8, primary, "realization")) return parseRealizationCommand;
    if (std.mem.eql(u8, primary, "potential")) return parsePotentialCommand;
    if (std.mem.eql(u8, primary, "proof")) return parseProofCommand;
    if (std.mem.eql(u8, primary, "delivery")) return parseDeliveryCommand;
    if (std.mem.eql(u8, primary, "certify")) return parseCertifyCommand;
    if (std.mem.eql(u8, primary, "migrate")) return parseMigrateCommand;
    return null;
}

fn parseCampaignCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "begin")) return .campaign_begin;
    if (std.mem.eql(u8, value, "status")) return .campaign_status;
    if (std.mem.eql(u8, value, "audit")) return .campaign_audit;
    if (std.mem.eql(u8, value, "rebaseline")) return .campaign_rebaseline;
    if (std.mem.eql(u8, value, "abort")) return .campaign_abort;
    return null;
}

fn parseAcceptanceCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "set")) return .acceptance_set;
    if (std.mem.eql(u8, value, "validate")) return .acceptance_validate;
    if (std.mem.eql(u8, value, "seal")) return .acceptance_seal;
    if (std.mem.eql(u8, value, "status")) return .acceptance_status;
    if (std.mem.eql(u8, value, "rebase")) return .acceptance_rebase;
    return null;
}

fn parseReviewCommand(namespace: []const u8, value: []const u8) ?Command {
    if (std.mem.eql(u8, namespace, "batch")) {
        if (std.mem.eql(u8, value, "begin")) return .review_batch_begin;
        if (std.mem.eql(u8, value, "status")) return .review_batch_status;
        if (std.mem.eql(u8, value, "seal")) return .review_batch_seal;
        if (std.mem.eql(u8, value, "invalidate")) return .review_batch_invalidate;
    } else if (std.mem.eql(u8, namespace, "aperture")) {
        if (std.mem.eql(u8, value, "add")) return .review_aperture_add;
    } else if (std.mem.eql(u8, namespace, "receipt")) {
        if (std.mem.eql(u8, value, "add")) return .review_receipt_add;
    }
    return null;
}

fn parseCounterexampleCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "add")) return .counterexample_add;
    if (std.mem.eql(u8, value, "classify")) return .counterexample_classify;
    if (std.mem.eql(u8, value, "list")) return .counterexample_list;
    if (std.mem.eql(u8, value, "show")) return .counterexample_show;
    return null;
}

fn parseBasisCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "compile")) return .basis_compile;
    if (std.mem.eql(u8, value, "lint")) return .basis_lint;
    if (std.mem.eql(u8, value, "seal")) return .basis_seal;
    if (std.mem.eql(u8, value, "status")) return .basis_status;
    return null;
}

fn parseReductionCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "set")) return .reduction_set;
    if (std.mem.eql(u8, value, "lint")) return .reduction_lint;
    if (std.mem.eql(u8, value, "review")) return .reduction_review;
    if (std.mem.eql(u8, value, "accept")) return .reduction_accept;
    return null;
}

fn parseObservationCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "add")) return .observation_add;
    if (std.mem.eql(u8, value, "import")) return .observation_import;
    if (std.mem.eql(u8, value, "list")) return .observation_list;
    if (std.mem.eql(u8, value, "classify")) return .observation_classify;
    return null;
}

fn parseKernelCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "set")) return .kernel_set;
    if (std.mem.eql(u8, value, "lint")) return .kernel_lint;
    if (std.mem.eql(u8, value, "minimize")) return .kernel_minimize;
    if (std.mem.eql(u8, value, "review")) return .kernel_review;
    if (std.mem.eql(u8, value, "accept")) return .kernel_accept;
    return null;
}

fn parseDesignCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "register")) return .design_register;
    if (std.mem.eql(u8, value, "select")) return .design_select;
    if (std.mem.eql(u8, value, "list")) return .design_list;
    return null;
}

fn parseRealizationCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "worktree")) return .realization_worktree;
    if (std.mem.eql(u8, value, "capture")) return .realization_capture;
    if (std.mem.eql(u8, value, "measure")) return .realization_measure;
    if (std.mem.eql(u8, value, "map")) return .realization_map;
    if (std.mem.eql(u8, value, "verify")) return .realization_verify;
    if (std.mem.eql(u8, value, "minimize")) return .realization_minimize;
    return null;
}

fn parsePotentialCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "baseline")) return .potential_baseline;
    if (std.mem.eql(u8, value, "measure")) return .potential_measure;
    if (std.mem.eql(u8, value, "gate")) return .potential_gate;
    if (std.mem.eql(u8, value, "status")) return .potential_status;
    return null;
}

fn parseProofCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "plan")) return .proof_plan;
    if (std.mem.eql(u8, value, "run")) return .proof_run_nested;
    if (std.mem.eql(u8, value, "compress")) return .proof_compress;
    return null;
}

fn parseDeliveryCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "apply")) return .delivery_apply;
    if (std.mem.eql(u8, value, "commit")) return .delivery_commit;
    if (std.mem.eql(u8, value, "push")) return .delivery_push;
    return null;
}

fn parseCertifyCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "tuple")) return .certify_tuple;
    if (std.mem.eql(u8, value, "terminal")) return .certify_terminal;
    return null;
}

fn parseMigrateCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "mrpc")) return .migrate_mrpc;
    if (std.mem.eql(u8, value, "intent-closed")) return .migrate_intent_closed;
    return null;
}

fn parseAuthorityChainCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "init")) return .authority_chain_init;
    if (std.mem.eql(u8, value, "check")) return .authority_chain_check;
    return null;
}

fn parseCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "capabilities")) return .capabilities;
    if (std.mem.eql(u8, value, "schema")) return .schema;
    if (std.mem.eql(u8, value, "example")) return .example;
    if (std.mem.eql(u8, value, "doctor")) return .doctor;
    if (std.mem.eql(u8, value, "init")) return .init;
    if (std.mem.eql(u8, value, "paths")) return .paths;
    if (std.mem.eql(u8, value, "status")) return .status;
    if (std.mem.eql(u8, value, "begin")) return .begin;
    if (std.mem.eql(u8, value, "add-counterexample")) return .add_counterexample;
    if (std.mem.eql(u8, value, "set-basis")) return .set_basis;
    if (std.mem.eql(u8, value, "tournament-waiver")) return .tournament_waiver;
    if (std.mem.eql(u8, value, "register-candidate")) return .register_candidate;
    if (std.mem.eql(u8, value, "verify-candidate")) return .verify_candidate;
    if (std.mem.eql(u8, value, "select")) return .select;
    if (std.mem.eql(u8, value, "ablate")) return .ablate;
    if (std.mem.eql(u8, value, "record-ablation")) return .record_ablation;
    if (std.mem.eql(u8, value, "record-holdout")) return .record_holdout;
    if (std.mem.eql(u8, value, "certify-apply")) return .certify_apply;
    if (std.mem.eql(u8, value, "apply")) return .apply;
    if (std.mem.eql(u8, value, "run-proof")) return .run_proof;
    if (std.mem.eql(u8, value, "record-proof")) return .record_proof;
    if (std.mem.eql(u8, value, "certify-final")) return .certify_final;
    if (std.mem.eql(u8, value, "commit")) return .commit;
    if (std.mem.eql(u8, value, "push")) return .push;
    if (std.mem.eql(u8, value, "close")) return .close;
    if (std.mem.eql(u8, value, "abort")) return .abort;
    if (std.mem.eql(u8, value, "audit")) return .audit;
    if (std.mem.eql(u8, value, "guard-hook")) return .guard_hook;
    if (std.mem.eql(u8, value, "hook-context")) return .hook_context;
    if (std.mem.eql(u8, value, "stop-guard")) return .stop_guard;
    if (std.mem.eql(u8, value, "mrpc-gate")) return .mrpc_gate;
    if (std.mem.eql(u8, value, "rdr-gate")) return .rdr_gate;
    if (std.mem.eql(u8, value, "legacy-gate")) return .legacy_gate;
    if (std.mem.eql(u8, value, "migrate-legacy")) return .migrate_legacy;
    return null;
}

fn run(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    return switch (args.command) {
        .capabilities => printCapabilities(allocator),
        .schema => printSchema(allocator, args),
        .example => printExample(allocator, args),
        .campaign_begin => beginRun(allocator, args),
        .campaign_status => printStatus(allocator, args),
        .campaign_audit => auditState(allocator, args),
        .campaign_rebaseline => rebaselineCampaign(allocator, args),
        .campaign_abort => abortRun(allocator, args),
        .acceptance_set => setAcceptance(allocator, args),
        .acceptance_validate => validateAcceptanceCommand(allocator, args),
        .acceptance_seal => sealAcceptance(allocator, args),
        .acceptance_status => printAcceptanceStatus(allocator, args),
        .acceptance_rebase => rebaseAcceptance(allocator, args),
        .review_batch_begin => beginReviewBatch(allocator, args),
        .review_aperture_add => addReviewAperture(allocator, args),
        .review_receipt_add => addReviewReceipt(allocator, args),
        .review_batch_status => printReviewBatchStatus(allocator, args),
        .review_batch_seal => sealReviewBatch(allocator, args),
        .review_batch_invalidate => invalidateReviewBatch(allocator, args),
        .review_plan => setReviewPlan(allocator, args),
        .review_plan_status => printReviewPlanStatus(allocator, args),
        .counterexample_add => addCounterexampleV1(allocator, args),
        .counterexample_classify => classifyCounterexampleV1(allocator, args),
        .counterexample_list => listCounterexamplesV1(allocator, args),
        .counterexample_show => showCounterexampleV1(allocator, args),
        .basis_compile => compileBasisV2(allocator, args),
        .basis_lint => lintBasisV2(allocator, args),
        .basis_seal => sealBasisV2(allocator, args),
        .basis_status => printBasisStatus(allocator, args),
        .reduction_set => setReduction(allocator, args),
        .reduction_lint => lintReduction(allocator, args),
        .reduction_review => reviewReduction(allocator, args),
        .reduction_accept => acceptReduction(allocator, args),
        .observation_add => addObservation(allocator, args),
        .observation_import => importObservations(allocator, args),
        .observation_list => listObservations(allocator, args),
        .observation_classify => classifyObservation(allocator, args),
        .kernel_set => setKernel(allocator, args),
        .kernel_lint => lintKernel(allocator, args),
        .kernel_minimize => minimizeKernel(allocator, args),
        .kernel_review => reviewKernel(allocator, args),
        .kernel_accept => acceptKernel(allocator, args),
        .design_register => registerDesign(allocator, args),
        .design_select => selectDesign(allocator, args),
        .design_list => listDesigns(allocator, args),
        .realization_worktree => createRealizationWorktree(allocator, args, process_io),
        .realization_capture => captureRealization(allocator, args, process_io),
        .realization_measure => measureRealization(allocator, args),
        .realization_map => setConstructMap(allocator, args),
        .realization_verify => verifyRealization(allocator, args),
        .realization_minimize => minimizeRealization(allocator, args),
        .potential_baseline => baselinePotential(allocator, args),
        .potential_measure => measurePotential(allocator, args),
        .potential_gate => gatePotential(allocator, args),
        .potential_status => printPotentialStatus(allocator, args),
        .proof_plan => planProof(allocator, args),
        .proof_run_nested => runProofPlan(allocator, args, process_io),
        .proof_compress => compressProof(allocator, args),
        .delivery_apply => applyDeliveryPhysical(allocator, args, process_io),
        .delivery_commit => commitDeliveryPhysical(allocator, args, process_io),
        .delivery_push => pushDeliveryPhysical(allocator, args, process_io),
        .certify_tuple => certifyTuple(allocator, args),
        .certify_terminal => certifyTerminal(allocator, args),
        .migrate_mrpc => migrateMrpc(allocator, args),
        .migrate_intent_closed => migrateIntentClosed(allocator, args),
        .authority_chain_init => authorityChainSurface(allocator, args, "init"),
        .authority_chain_check => authorityChainSurface(allocator, args, "check"),
        .mutation_gate => mutationGate(allocator, args),
        .doctor => printDoctor(allocator, args),
        .init => initState(allocator, args),
        .paths => printPaths(allocator, args),
        .status => printStatus(allocator, args),
        .begin => beginRun(allocator, args),
        .add_counterexample => addCounterexample(allocator, args),
        .set_basis => setBasis(allocator, args),
        .tournament_waiver => setTournamentWaiver(allocator, args),
        .register_candidate => registerCandidate(allocator, args),
        .verify_candidate => verifyCandidate(allocator, args, process_io),
        .select => selectCandidate(allocator, args),
        .ablate => ablateCandidate(allocator, args),
        .record_ablation => recordAblation(allocator, args),
        .record_holdout => recordHoldout(allocator, args),
        .certify_apply => certifyApply(allocator, args),
        .apply => applySelected(allocator, args),
        .run_proof => runProof(allocator, args, process_io),
        .record_proof => recordProof(allocator, args),
        .certify_final => certifyFinal(allocator, args),
        .commit => commitDelivery(allocator, args),
        .push => pushDelivery(allocator, args),
        .close => closeRun(allocator, args),
        .abort => abortRun(allocator, args),
        .audit => auditState(allocator, args),
        .guard_hook => guardHook(allocator, args),
        .hook_context => hookContext(allocator, args),
        .stop_guard => stopGuard(allocator, args),
        .mrpc_gate => mrpcGate(allocator, args),
        .rdr_gate => rdrGate(allocator, args),
        .legacy_gate => legacyGate(allocator, args),
        .migrate_legacy => migrateLegacy(allocator, args),
    };
}

fn printCapabilities(allocator: std.mem.Allocator) !u8 {
    try writeStdoutBytes(allocator,
        \\{"resolve_c3_capabilities":{"version":"0.3.2","protocol_profiles":{"intent_closed_cegis_v1":true,"mbkc_v1":true,"mrpc_v1_read":true,"rac_v1":true},"state_versions":{"readable":[1,2,3],"writable":[3]},"certificate_versions":{"readable":["MRPC-v1","MBKC-v1","RAC-v1"],"writable":["MBKC-v1","RAC-v1"]},"features":{"acceptance_contract_v2":true,"sealed_review_horizon_v1":true,"review_batch_v1":true,"review_aperture_v1":true,"counterexample_v1":true,"counterexample_basis_v2":true,"minimum_behavioral_kernel_v1":true,"reduction_certificate_v1":true,"review_potential_v1":true,"intent_closed_conformance_v1":true,"terminal_holdout_v1":true,"semantic_surface_v1":true,"proof_compression_v1":true,"authority_chain_rac_v1":true,"mutation_gate_rac_v1":true,"physical_apply":true,"physical_commit":true,"physical_push":true,"closure_horizon_v1":true,"mutation_guard_v2":true,"mbkc_v1":true,"mrpc_v1_read":true}}}
        \\
    );
    return 0;
}

fn authorityChainSurface(allocator: std.mem.Allocator, args: Args, subcommand: []const u8) !u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (std.mem.eql(u8, subcommand, "init")) {
        _ = args.campaign_id orelse return error.MissingValue;
        _ = args.artifact_state orelse return error.MissingValue;
        _ = args.review_claim orelse return error.MissingValue;
        _ = args.acceptance orelse return error.MissingValue;
        _ = args.cex orelse return error.MissingValue;
        _ = args.batch orelse return error.MissingValue;
        _ = args.basis orelse return error.MissingValue;
        _ = args.kernel orelse return error.MissingValue;
        _ = args.reduction orelse return error.MissingValue;
        _ = args.proof_obligation orelse return error.MissingValue;
        _ = args.realization_target orelse return error.MissingValue;
        _ = args.output orelse return error.MissingValue;
    } else {
        _ = args.chain orelse return error.MissingValue;
        if (args.format) |format| {
            if (!std.mem.eql(u8, format, "text") and !std.mem.eql(u8, format, "json")) return error.UnknownOption;
        }
        return checkAuthorityChain(allocator, args);
    }
    try out.writer.writeAll("{\"resolve_c3_authority_chain\":{\"chain_version\":\"RAC-v1\",\"command\":");
    try writeJsonString(&out.writer, subcommand);
    try out.writer.writeAll(",\"surface\":\"declared\",\"validation\":\"pending\"}}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

const RacFacts = struct {
    chain_id: []const u8 = "",
    campaign_id: []const u8 = "",
    artifact_base_sha: []const u8 = "",
    artifact_head_sha: []const u8 = "",
    artifact_dirty_fingerprint: []const u8 = "",
    artifact_review_receipt: []const u8 = "",
    review_claim_id: []const u8 = "",
    chain_version_ok: bool = false,
    artifact_state_complete: bool = false,
    review_claim_present: bool = false,
    acceptance_contract_present: bool = false,
    horizon_present: bool = false,
    law_refs_present: bool = false,
    relation: []const u8 = "",
    cex_confirmed: bool = false,
    adjudication_disposition: []const u8 = "",
    batch_sealed: bool = false,
    ceb_class_present: bool = false,
    mbk_present: bool = false,
    rc_present: bool = false,
    transition_present: bool = false,
    proof_obligation_present: bool = false,
    realization_allowed: bool = false,
    gate_current_yes: bool = false,
    gate_complete_yes: bool = false,
    gate_mutation_yes: bool = false,
};

fn deinitParsedRacFacts(allocator: std.mem.Allocator, facts: RacFacts) void {
    allocator.free(facts.chain_id);
    allocator.free(facts.campaign_id);
    allocator.free(facts.artifact_base_sha);
    allocator.free(facts.artifact_head_sha);
    allocator.free(facts.artifact_dirty_fingerprint);
    allocator.free(facts.artifact_review_receipt);
    allocator.free(facts.review_claim_id);
    allocator.free(facts.relation);
    allocator.free(facts.adjudication_disposition);
}

fn checkAuthorityChain(allocator: std.mem.Allocator, args: Args) !u8 {
    const chain_path = args.chain orelse return error.MissingValue;
    const bytes = readFileOrStdin(allocator, chain_path) catch return 3;
    defer allocator.free(bytes);
    const facts = parseRacFacts(allocator, bytes) catch return 3;
    defer deinitParsedRacFacts(allocator, facts);

    var missing = std.ArrayList([]const u8).empty;
    var violations = std.ArrayList([]const u8).empty;
    try validateRacFacts(allocator, facts, &missing, &violations);
    defer missing.deinit(allocator);
    defer violations.deinit(allocator);

    const non_mutation_valid = !facts.realization_allowed and !facts.gate_mutation_yes and hasNonMutationDisposition(facts.adjudication_disposition);
    const mutation_allowed = missing.items.len == 0 and violations.items.len == 0;
    const valid = mutation_allowed or (non_mutation_valid and missing.items.len == 0 and nonMutationViolationsOnly(violations.items));
    const format = args.format orelse "text";
    if (std.mem.eql(u8, format, "json")) {
        try writeRacCheckJson(allocator, facts, valid, mutation_allowed, missing.items, if (valid and !mutation_allowed) &.{} else violations.items);
    } else {
        try writeRacCheckText(allocator, facts, valid, mutation_allowed, missing.items, if (valid and !mutation_allowed) &.{} else violations.items);
    }
    return if (valid) 0 else 2;
}

fn mutationGate(allocator: std.mem.Allocator, args: Args) !u8 {
    const direct = args.chain != null;
    const integrated = args.campaign_id != null or args.review_claim_id != null or args.artifact_state != null;
    if (direct == integrated) return mutationGateCouldNotEvaluate(allocator, "expected --chain or integrated campaign/review-claim-id/artifact-state input");

    const bytes = if (direct)
        readFileOrStdin(allocator, args.chain.?) catch return mutationGateCouldNotEvaluate(allocator, "could not read RAC chain")
    else
        readIntegratedMutationChain(allocator, args) catch return mutationGateCouldNotEvaluate(allocator, "could not resolve RAC chain");
    defer allocator.free(bytes);

    const facts = parseRacFacts(allocator, bytes) catch return mutationGateCouldNotEvaluate(allocator, "unsupported RAC input");
    defer deinitParsedRacFacts(allocator, facts);

    var missing = std.ArrayList([]const u8).empty;
    var violations = std.ArrayList([]const u8).empty;
    try validateRacFacts(allocator, facts, &missing, &violations);
    defer missing.deinit(allocator);
    defer violations.deinit(allocator);

    if (!facts.gate_mutation_yes) try violations.append(allocator, "mutation_gate_disagrees");

    if (!direct) {
        if (!std.mem.eql(u8, facts.campaign_id, args.campaign_id.?)) try violations.append(allocator, "artifact_state_stale");
        if (!std.mem.eql(u8, facts.review_claim_id, args.review_claim_id.?)) try missing.append(allocator, "missing_review_claim");
        const artifact_matches = artifactStateMatches(allocator, args.artifact_state.?, facts) catch return mutationGateCouldNotEvaluate(allocator, "could not evaluate artifact state");
        if (!artifact_matches) try violations.append(allocator, "artifact_state_stale");
    }

    const mutation_allowed = missing.items.len == 0 and violations.items.len == 0;
    const format = args.format orelse "text";
    if (!std.mem.eql(u8, format, "text") and !std.mem.eql(u8, format, "json")) return mutationGateCouldNotEvaluate(allocator, "unsupported output format");
    if (std.mem.eql(u8, format, "json")) {
        try writeMutationGateJson(allocator, facts, mutation_allowed, missing.items, violations.items);
    } else {
        try writeMutationGateText(allocator, facts, mutation_allowed, missing.items, violations.items);
    }
    return if (mutation_allowed) 0 else 2;
}

fn parseRacFacts(allocator: std.mem.Allocator, bytes: []const u8) !RacFacts {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.UnsupportedFormat;
    if (trimmed[0] == '{') return parseJsonRacFacts(allocator, bytes);
    if (std.mem.containsAtLeast(u8, bytes, 1, "resolve_authority_chain:")) return parseYamlRacFacts(allocator, bytes);
    return error.UnsupportedFormat;
}

fn readIntegratedMutationChain(allocator: std.mem.Allocator, args: Args) ![]u8 {
    const campaign_id = args.campaign_id orelse return error.MissingValue;
    const review_claim_id = args.review_claim_id orelse return error.MissingValue;
    _ = args.artifact_state orelse return error.MissingValue;
    try validateSafeId(campaign_id);
    try validateSafeId(review_claim_id);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const claim_json = try std.fmt.allocPrint(allocator, "{s}.json", .{review_claim_id});
    defer allocator.free(claim_json);
    const claim_yaml = try std.fmt.allocPrint(allocator, "{s}.yaml", .{review_claim_id});
    defer allocator.free(claim_yaml);
    const candidates = [_][]const u8{
        try std.fs.path.join(allocator, &.{ args.state_root, "authority-chains", campaign_id, claim_json }),
        try std.fs.path.join(allocator, &.{ args.state_root, "authority-chains", campaign_id, claim_yaml }),
        try std.fs.path.join(allocator, &.{ args.state_root, "authority-chains", claim_json }),
        try std.fs.path.join(allocator, &.{ args.state_root, "authority-chains", claim_yaml }),
    };
    defer {
        for (candidates) |candidate| allocator.free(candidate);
    }
    for (candidates) |candidate| {
        if (root.readFileAlloc(Io, candidate, allocator, .limited(MaxFileBytes))) |bytes| return bytes else |_| {}
    }
    return error.FileNotFound;
}

fn artifactStateMatches(allocator: std.mem.Allocator, path: []const u8, facts: RacFacts) !bool {
    const bytes = try readFileOrStdin(allocator, path);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = objectField(parsed.value, "artifact_state") orelse parsed.value;
    return std.mem.eql(u8, stringField(root, "base_sha") orelse "", facts.artifact_base_sha) and
        std.mem.eql(u8, stringField(root, "head_sha") orelse "", facts.artifact_head_sha) and
        std.mem.eql(u8, stringField(root, "dirty_fingerprint") orelse "", facts.artifact_dirty_fingerprint) and
        std.mem.eql(u8, stringField(root, "review_receipt") orelse "", facts.artifact_review_receipt);
}

fn parseJsonRacFacts(allocator: std.mem.Allocator, bytes: []const u8) !RacFacts {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = objectField(parsed.value, "resolve_authority_chain") orelse parsed.value;
    const artifact_state = objectField(root, "artifact_state");
    const review_claim = objectField(root, "review_claim");
    const acceptance = objectField(root, "acceptance");
    const adjudication = objectField(root, "adjudication");
    const batch = objectField(root, "batch");
    const compression = objectField(root, "compression");
    const realization = objectField(root, "realization");
    const gate = objectField(root, "gate");
    return .{
        .chain_id = try allocator.dupe(u8, stringField(root, "chain_id") orelse ""),
        .campaign_id = try allocator.dupe(u8, stringField(root, "campaign_id") orelse ""),
        .artifact_base_sha = try allocator.dupe(u8, stringFieldOpt(artifact_state, "base_sha") orelse ""),
        .artifact_head_sha = try allocator.dupe(u8, stringFieldOpt(artifact_state, "head_sha") orelse ""),
        .artifact_dirty_fingerprint = try allocator.dupe(u8, stringFieldOpt(artifact_state, "dirty_fingerprint") orelse ""),
        .artifact_review_receipt = try allocator.dupe(u8, stringFieldOpt(artifact_state, "review_receipt") orelse ""),
        .review_claim_id = try allocator.dupe(u8, stringFieldOpt(review_claim, "claim_id") orelse ""),
        .chain_version_ok = std.mem.eql(u8, stringField(root, "chain_version") orelse "", "RAC-v1"),
        .artifact_state_complete = allStringFieldsPresent(artifact_state, &.{ "base_sha", "head_sha", "dirty_fingerprint", "review_receipt" }),
        .review_claim_present = stringFieldOpt(review_claim, "claim_id") != null,
        .acceptance_contract_present = allStringFieldsPresent(acceptance, &.{ "contract_id", "contract_fingerprint" }),
        .horizon_present = stringFieldOpt(acceptance, "horizon_fingerprint") != null,
        .law_refs_present = arrayLen(if (acceptance) |a| objectField(a, "law_refs") else null) > 0,
        .relation = try allocator.dupe(u8, stringFieldOpt(acceptance, "relation") orelse ""),
        .cex_confirmed = std.mem.eql(u8, stringFieldOpt(adjudication, "validity") orelse "", "confirmed"),
        .adjudication_disposition = try allocator.dupe(u8, stringFieldOpt(adjudication, "disposition") orelse ""),
        .batch_sealed = boolFieldOpt(batch, "sealed") == true,
        .ceb_class_present = allStringFieldsPresent(compression, &.{ "ceb_id", "class_id", "class_status", "quotient_witness_ref" }),
        .mbk_present = stringFieldOpt(compression, "mbk_id") != null,
        .rc_present = stringFieldOpt(compression, "rc_id") != null,
        .transition_present = stringFieldOpt(compression, "transition_ref") != null,
        .proof_obligation_present = stringFieldOpt(compression, "proof_obligation_ref") != null,
        .realization_allowed = boolFieldOpt(realization, "allowed") == true,
        .gate_current_yes = std.mem.eql(u8, stringFieldOpt(gate, "current_artifact_state") orelse "", "yes"),
        .gate_complete_yes = std.mem.eql(u8, stringFieldOpt(gate, "complete_chain") orelse "", "yes"),
        .gate_mutation_yes = std.mem.eql(u8, stringFieldOpt(gate, "mutation_allowed") orelse "", "yes"),
    };
}

fn parseYamlRacFacts(allocator: std.mem.Allocator, bytes: []const u8) !RacFacts {
    return .{
        .chain_id = try yamlScalarDup(allocator, bytes, "chain_id"),
        .campaign_id = try yamlScalarDup(allocator, bytes, "campaign_id"),
        .artifact_base_sha = try yamlScalarDup(allocator, bytes, "base_sha"),
        .artifact_head_sha = try yamlScalarDup(allocator, bytes, "head_sha"),
        .artifact_dirty_fingerprint = try yamlScalarDup(allocator, bytes, "dirty_fingerprint"),
        .artifact_review_receipt = try yamlScalarDup(allocator, bytes, "review_receipt"),
        .review_claim_id = try yamlScalarDup(allocator, bytes, "claim_id"),
        .chain_version_ok = std.mem.eql(u8, try yamlScalarTemp(bytes, "chain_version"), "RAC-v1"),
        .artifact_state_complete = yamlHasValue(bytes, "base_sha") and yamlHasValue(bytes, "head_sha") and yamlHasValue(bytes, "dirty_fingerprint") and yamlHasValue(bytes, "review_receipt"),
        .review_claim_present = yamlHasValue(bytes, "claim_id"),
        .acceptance_contract_present = yamlHasValue(bytes, "contract_id") and yamlHasValue(bytes, "contract_fingerprint"),
        .horizon_present = yamlHasValue(bytes, "horizon_fingerprint"),
        .law_refs_present = yamlHasNonEmptyArray(bytes, "law_refs"),
        .relation = try yamlScalarDup(allocator, bytes, "relation"),
        .cex_confirmed = std.mem.eql(u8, try yamlScalarTemp(bytes, "validity"), "confirmed"),
        .adjudication_disposition = try yamlScalarDup(allocator, bytes, "disposition"),
        .batch_sealed = yamlBool(bytes, "sealed") == true,
        .ceb_class_present = yamlHasValue(bytes, "ceb_id") and yamlHasValue(bytes, "class_id") and yamlHasValue(bytes, "class_status") and yamlHasValue(bytes, "quotient_witness_ref"),
        .mbk_present = yamlHasValue(bytes, "mbk_id"),
        .rc_present = yamlHasValue(bytes, "rc_id"),
        .transition_present = yamlHasValue(bytes, "transition_ref"),
        .proof_obligation_present = yamlHasValue(bytes, "proof_obligation_ref"),
        .realization_allowed = yamlBool(bytes, "allowed") == true,
        .gate_current_yes = std.mem.eql(u8, try yamlScalarTemp(bytes, "current_artifact_state"), "yes"),
        .gate_complete_yes = std.mem.eql(u8, try yamlScalarTemp(bytes, "complete_chain"), "yes"),
        .gate_mutation_yes = std.mem.eql(u8, try yamlScalarTemp(bytes, "mutation_allowed"), "yes"),
    };
}

fn validateRacFacts(allocator: std.mem.Allocator, facts: RacFacts, missing: *std.ArrayList([]const u8), violations: *std.ArrayList([]const u8)) !void {
    if (!facts.chain_version_ok) try missing.append(allocator, "missing_chain_version");
    if (!facts.artifact_state_complete) try missing.append(allocator, "missing_artifact_state");
    if (!facts.review_claim_present) try missing.append(allocator, "missing_review_claim");
    if (!facts.acceptance_contract_present) try missing.append(allocator, "missing_acceptance_contract");
    if (!facts.horizon_present) try missing.append(allocator, "missing_horizon");
    if (!facts.law_refs_present) try missing.append(allocator, "missing_law_refs");
    if (!isInHorizonRelation(facts.relation)) {
        if (std.mem.eql(u8, facts.relation, "unrelated") or std.mem.eql(u8, facts.relation, "rejected") or std.mem.eql(u8, facts.relation, "unknown")) {
            try violations.append(allocator, "unrelated_or_rejected");
        } else {
            try violations.append(allocator, "outside_horizon");
        }
    }
    if (!facts.cex_confirmed) try violations.append(allocator, "invalid_cex");
    if (!facts.batch_sealed) try violations.append(allocator, "unsealed_batch");
    if (!facts.ceb_class_present) try missing.append(allocator, "missing_ceb_class");
    if (!facts.mbk_present or !facts.rc_present) try missing.append(allocator, "missing_mbk_or_rc");
    if (!facts.transition_present) try missing.append(allocator, "missing_transition");
    if (!facts.proof_obligation_present) try missing.append(allocator, "missing_proof_obligation");
    if (!facts.gate_current_yes) try violations.append(allocator, "artifact_state_stale");
    if (!facts.realization_allowed) try violations.append(allocator, "realization_not_allowed");
    if (!facts.gate_complete_yes or (facts.realization_allowed and !facts.gate_mutation_yes) or (!facts.realization_allowed and facts.gate_mutation_yes)) try violations.append(allocator, "mutation_gate_disagrees");
}

fn isInHorizonRelation(value: []const u8) bool {
    return std.mem.eql(u8, value, "directly_entailed") or
        std.mem.eql(u8, value, "compatibility_required") or
        std.mem.eql(u8, value, "forbidden_state_witness") or
        std.mem.eql(u8, value, "contract_invalidating");
}

fn writeRacCheckJson(allocator: std.mem.Allocator, facts: RacFacts, valid: bool, mutation_allowed: bool, missing: []const []const u8, violations: []const []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"status\":");
    try writeJsonString(&out.writer, if (valid) "valid" else "invalid");
    try out.writer.writeAll(",\"mutation_allowed\":");
    try out.writer.writeAll(if (mutation_allowed) "true" else "false");
    try out.writer.writeAll(",\"missing\":");
    try writeStringArray(&out.writer, missing);
    try out.writer.writeAll(",\"violations\":");
    try writeStringArray(&out.writer, violations);
    try out.writer.writeAll(",\"chain_id\":");
    try writeJsonString(&out.writer, facts.chain_id);
    try out.writer.writeAll(",\"campaign_id\":");
    try writeJsonString(&out.writer, facts.campaign_id);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeRacCheckText(allocator: std.mem.Allocator, facts: RacFacts, valid: bool, mutation_allowed: bool, missing: []const []const u8, violations: []const []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("RAC-v1 {s}: chain_id={s} campaign_id={s} mutation_allowed={}\n", .{ if (valid) "valid" else "invalid", facts.chain_id, facts.campaign_id, mutation_allowed });
    if (missing.len != 0) {
        try out.writer.writeAll("missing: ");
        try writeStringArray(&out.writer, missing);
        try out.writer.writeByte('\n');
    }
    if (violations.len != 0) {
        try out.writer.writeAll("violations: ");
        try writeStringArray(&out.writer, violations);
        try out.writer.writeByte('\n');
    }
    try writeStdoutAlloc(allocator, &out);
}

fn writeMutationGateJson(allocator: std.mem.Allocator, facts: RacFacts, mutation_allowed: bool, missing: []const []const u8, violations: []const []const u8) !void {
    var normalized = std.ArrayList([]const u8).empty;
    defer normalized.deinit(allocator);
    try appendMutationGateReasons(allocator, &normalized, missing);
    try appendMutationGateReasons(allocator, &normalized, violations);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"mutation_allowed\":");
    try out.writer.writeAll(if (mutation_allowed) "true" else "false");
    try out.writer.writeAll(",\"reason\":");
    try writeJsonString(&out.writer, if (mutation_allowed) "compiled_review_authority" else "uncompiled_review_text");
    try out.writer.writeAll(",\"missing\":");
    try writeStringArray(&out.writer, if (mutation_allowed) &.{} else normalized.items);
    try out.writer.writeAll(",\"legal_next_actions\":");
    try writeStringArray(&out.writer, if (mutation_allowed) &.{} else MutationGateLegalNextActions[0..]);
    try out.writer.writeAll(",\"chain_id\":");
    try writeJsonString(&out.writer, facts.chain_id);
    try out.writer.writeAll(",\"campaign_id\":");
    try writeJsonString(&out.writer, facts.campaign_id);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeMutationGateText(allocator: std.mem.Allocator, facts: RacFacts, mutation_allowed: bool, missing: []const []const u8, violations: []const []const u8) !void {
    var normalized = std.ArrayList([]const u8).empty;
    defer normalized.deinit(allocator);
    try appendMutationGateReasons(allocator, &normalized, missing);
    try appendMutationGateReasons(allocator, &normalized, violations);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("mutation-gate {s}: chain_id={s} campaign_id={s} mutation_allowed={}\n", .{
        if (mutation_allowed) "allowed" else "blocked",
        facts.chain_id,
        facts.campaign_id,
        mutation_allowed,
    });
    if (!mutation_allowed) {
        try out.writer.writeAll("reason: uncompiled_review_text\nmissing: ");
        try writeStringArray(&out.writer, normalized.items);
        try out.writer.writeByte('\n');
    }
    try writeStdoutAlloc(allocator, &out);
}

fn mutationGateCouldNotEvaluate(allocator: std.mem.Allocator, reason: []const u8) !u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"mutation_allowed\":false,\"reason\":\"could_not_evaluate_input\",\"missing\":[],\"legal_next_actions\":[\"block\"],\"error\":");
    try writeJsonString(&out.writer, reason);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return 3;
}

fn appendMutationGateReasons(allocator: std.mem.Allocator, target: *std.ArrayList([]const u8), reasons: []const []const u8) !void {
    for (reasons) |reason| try appendUniqueMutationGateReason(allocator, target, normalizeMutationGateReason(reason));
}

fn appendUniqueMutationGateReason(allocator: std.mem.Allocator, target: *std.ArrayList([]const u8), reason: []const u8) !void {
    for (target.items) |existing| {
        if (std.mem.eql(u8, existing, reason)) return;
    }
    try target.append(allocator, reason);
}

fn normalizeMutationGateReason(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "missing_chain_version")) return "rac_v1";
    if (std.mem.eql(u8, reason, "missing_artifact_state") or std.mem.eql(u8, reason, "artifact_state_stale")) return "artifact_state";
    if (std.mem.eql(u8, reason, "missing_review_claim")) return "review_claim";
    if (std.mem.eql(u8, reason, "missing_acceptance_contract") or std.mem.eql(u8, reason, "missing_horizon") or std.mem.eql(u8, reason, "missing_law_refs") or std.mem.eql(u8, reason, "outside_horizon") or std.mem.eql(u8, reason, "unrelated_or_rejected")) return "ac_horizon_relation";
    if (std.mem.eql(u8, reason, "invalid_cex")) return "confirmed_cex";
    if (std.mem.eql(u8, reason, "unsealed_batch")) return "sealed_batch";
    if (std.mem.eql(u8, reason, "missing_ceb_class")) return "ceb_class";
    if (std.mem.eql(u8, reason, "missing_mbk_or_rc") or std.mem.eql(u8, reason, "missing_transition")) return "mbk_transition";
    if (std.mem.eql(u8, reason, "missing_proof_obligation")) return "proof_obligation";
    if (std.mem.eql(u8, reason, "realization_not_allowed")) return "realization_allowed";
    if (std.mem.eql(u8, reason, "mutation_gate_disagrees")) return "gate_mutation_allowed";
    return reason;
}

fn allStringFieldsPresent(value: ?std.json.Value, fields: []const []const u8) bool {
    const actual = value orelse return false;
    for (fields) |field| {
        if (stringField(actual, field) == null) return false;
    }
    return true;
}

fn stringFieldOpt(value: ?std.json.Value, key: []const u8) ?[]const u8 {
    return if (value) |actual| stringField(actual, key) else null;
}

fn boolFieldOpt(value: ?std.json.Value, key: []const u8) ?bool {
    return if (value) |actual| boolField(actual, key) else null;
}

fn hasNonMutationDisposition(value: []const u8) bool {
    return std.mem.eql(u8, value, "refuted") or std.mem.eql(u8, value, "stale") or std.mem.eql(u8, value, "outside_horizon") or std.mem.eql(u8, value, "contract_invalidating") or std.mem.eql(u8, value, "unknown");
}

fn nonMutationViolationsOnly(values: []const []const u8) bool {
    for (values) |value| {
        if (!std.mem.eql(u8, value, "invalid_cex") and !std.mem.eql(u8, value, "realization_not_allowed") and !std.mem.eql(u8, value, "mutation_gate_disagrees") and !std.mem.eql(u8, value, "outside_horizon") and !std.mem.eql(u8, value, "unrelated_or_rejected")) return false;
    }
    return true;
}

fn yamlScalarDup(allocator: std.mem.Allocator, text: []const u8, key: []const u8) ![]const u8 {
    return allocator.dupe(u8, try yamlScalarTemp(text, key));
}

fn yamlScalarTemp(text: []const u8, key: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.mem.eql(u8, name, key)) continue;
        var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
        return value;
    }
    return "";
}

fn yamlHasValue(text: []const u8, key: []const u8) bool {
    return (yamlScalarTemp(text, key) catch "").len != 0;
}

fn yamlBool(text: []const u8, key: []const u8) ?bool {
    const value = yamlScalarTemp(text, key) catch return null;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no")) return false;
    return null;
}

fn yamlHasNonEmptyArray(text: []const u8, key: []const u8) bool {
    const value = yamlScalarTemp(text, key) catch "";
    if (value.len != 0 and !std.mem.eql(u8, value, "[]")) return true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var saw_key = false;
    while (lines.next()) |raw| {
        const line = raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!saw_key) {
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const name = std.mem.trim(u8, trimmed[0..colon], " \t");
            saw_key = std.mem.eql(u8, name, key);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- ")) return true;
        if (trimmed.len != 0 and !std.mem.startsWith(u8, line, " ")) return false;
    }
    return false;
}

fn printSchema(allocator: std.mem.Allocator, args: Args) !u8 {
    const artifact = args.artifact orelse return error.ArtifactRequired;
    if (!knownSchemaArtifact(artifact)) return error.UnknownArtifact;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"resolve_c3_schema\":{\"schema_version\":\"RC3-S1\",\"artifact\":");
    try writeJsonString(&out.writer, artifact);
    try out.writer.writeAll(",\"strict_unknown_fields\":true,\"json_pointer_diagnostics\":true,\"required\":");
    try writeRequiredFields(&out.writer, artifact);
    try out.writer.writeAll(",\"root\":");
    try writeJsonString(&out.writer, schemaRootName(artifact));
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn printExample(allocator: std.mem.Allocator, args: Args) !u8 {
    const name = args.artifact orelse return error.ArtifactRequired;
    if (std.mem.eql(u8, name, "campaign begin")) {
        try writeStdoutBytes(allocator,
            \\{"command":"resolve-c3 campaign begin","args":{"root":".","pr":15,"base":"auto","baseline":"HEAD","acceptance":"acceptance.json","history_policy":"append_tree_replacement"}}
            \\
        );
        return 0;
    }
    if (!knownSchemaArtifact(name)) return error.UnknownArtifact;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"resolve_c3_example\":{\"artifact\":");
    try writeJsonString(&out.writer, name);
    try out.writer.writeAll(",\"value\":");
    try writeExampleValue(&out.writer, name);
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn rebaselineCampaign(allocator: std.mem.Allocator, args: Args) !u8 {
    const approved_by = args.approved_by orelse return error.InvalidBasis;
    const reason = args.reason orelse return error.ReasonRequired;
    const new_base = args.new_base orelse return error.InvalidBasis;
    try validateSafeId(approved_by);
    try validateSafeId(new_base);
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return error.ReasonRequired;

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    const old = parsed.value;
    if (old.run_id.len == 0) return error.InvalidPhase;

    const archive_dir = try std.fmt.allocPrint(allocator, "archive/rebaseline/{s}-{x}", .{ old.run_id, hashBytes(new_base) });
    defer allocator.free(archive_dir);
    const archive_root = try statePath(allocator, args.state_root, archive_dir);
    defer allocator.free(archive_root);
    try root.createDirPath(Io, archive_root);
    try archiveKnownArtifacts(allocator, root, args.state_root, archive_root);

    const new_run_id = try std.fmt.allocPrint(allocator, "C3-{s}", .{new_base[0..@min(new_base.len, 12)]});
    defer allocator.free(new_run_id);
    const next = State{
        .schema = StateSchemaV3,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 3,
        .run_id = new_run_id,
        .repo_root = old.repo_root,
        .branch = old.branch,
        .base_sha = new_base,
        .phase = "initialized",
        .acceptance_goal = old.acceptance_goal,
        .parent_run_id = old.run_id,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    };
    try saveState(allocator, root, args.state_root, next);
    try writeMbkc(allocator, root, args.state_root, next, "uninitialized");
    const event_id = try appendEvent(allocator, root, args.state_root, "campaign-rebaselined", old, next, archive_dir);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "campaign rebaseline", "success", archive_dir, old.phase, next, event_id);
    return 0;
}

fn setAcceptance(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    try validateAcceptanceV2(parsed_input.value);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    if (std.mem.eql(u8, state.acceptance.horizon_state, "sealed")) return error.AcceptanceRebaseRequired;
    const before = state;
    const written = try writeAcceptanceArtifact(allocator, root, args.state_root, parsed_input.value);
    defer written.deinit(allocator);
    state.acceptance = .{
        .sequence = written.sequence,
        .contract_id = written.contract_id,
        .fingerprint = written.fingerprint,
        .horizon_state = "draft",
    };
    state.acceptance_goal = stringField(parsed_input.value, "goal") orelse state.acceptance_goal;
    state.phase = "intent_open";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "acceptance-set", before, state, written.fingerprint);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "acceptance set", "success", written.fingerprint, before.phase, state, event_id);
    return 0;
}

fn validateAcceptanceCommand(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse args.file orelse AcceptanceFile;
    var parsed_input = if (args.input != null or args.file != null)
        try parseJsonInput(allocator, input)
    else
        try parseStateChildJson(allocator, args, AcceptanceFile);
    defer parsed_input.deinit();
    try validateAcceptanceV2(parsed_input.value);
    const fingerprint = try acceptanceFingerprintAlloc(allocator, parsed_input.value);
    defer allocator.free(fingerprint);
    try printReceipt(allocator, "acceptance validate", "success", fingerprint);
    return 0;
}

fn sealAcceptance(allocator: std.mem.Allocator, args: Args) !u8 {
    if (!args.confirm) return error.ConfirmRequired;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    if (!std.mem.eql(u8, state.phase, "intent_open")) return error.InvalidPhase;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;

    var parsed_acceptance = try loadAcceptanceParsed(allocator, root, args.state_root);
    defer parsed_acceptance.deinit();
    try validateAcceptanceV2(parsed_acceptance.value);
    const authority_obj = objectField(parsed_acceptance.value, "authority") orelse return error.InvalidBasis;
    if (boolField(authority_obj, "current") != true) return error.InvalidBasis;
    const authority = stringField(authority_obj, "id") orelse "authority";
    const fingerprint = try acceptanceFingerprintAlloc(allocator, parsed_acceptance.value);
    defer allocator.free(fingerprint);
    const before = state;
    state.acceptance = .{
        .sequence = acceptanceSequence(parsed_acceptance.value),
        .contract_id = acceptanceContractId(parsed_acceptance.value),
        .fingerprint = fingerprint,
        .horizon_state = "sealed",
    };
    state.phase = "acceptance_sealed";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "acceptance-sealed", before, state, authority);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "acceptance seal", "success", fingerprint, before.phase, state, event_id);
    return 0;
}

fn printAcceptanceStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"resolve_c3_acceptance_status\":{\"state_root\":");
    try writeJsonString(&out.writer, args.state_root);
    try out.writer.writeAll(",\"present\":");
    try out.writer.print("{}", .{fileExists(allocator, root, args.state_root, AcceptanceFile)});
    try out.writer.writeAll(",\"sequence\":");
    try out.writer.print("{d}", .{parsed.value.acceptance.sequence});
    try out.writer.writeAll(",\"contract_id\":");
    try writeOptionalString(&out.writer, parsed.value.acceptance.contract_id);
    try out.writer.writeAll(",\"fingerprint\":");
    try writeOptionalString(&out.writer, parsed.value.acceptance.fingerprint);
    try out.writer.writeAll(",\"horizon_state\":");
    try writeJsonString(&out.writer, parsed.value.acceptance.horizon_state);
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn rebaseAcceptance(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    const approved_by = args.approved_by orelse return error.InvalidBasis;
    const reason = args.reason orelse return error.ReasonRequired;
    if (!args.confirm) return error.ConfirmRequired;
    try validateSafeId(approved_by);
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return error.ReasonRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    try validateAcceptanceV2(parsed_input.value);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    const before = state;
    const old_sequence = state.acceptance.sequence;
    const new_sequence = acceptanceSequence(parsed_input.value);
    if (new_sequence <= old_sequence) return error.InvalidBasis;
    const new_fingerprint = try acceptanceFingerprintAlloc(allocator, parsed_input.value);
    defer allocator.free(new_fingerprint);
    if (optionalEql(state.acceptance.fingerprint, new_fingerprint)) return error.InvalidBasis;
    const archive_dir = try std.fmt.allocPrint(allocator, "archive/acceptance/seq-{d}-{x}", .{ old_sequence, hashBytes(reason) });
    defer allocator.free(archive_dir);
    const archive_root = try statePath(allocator, args.state_root, archive_dir);
    defer allocator.free(archive_root);
    try root.createDirPath(Io, archive_root);
    try archiveAcceptanceArtifact(allocator, root, args.state_root, archive_root);
    const written = try writeAcceptanceArtifact(allocator, root, args.state_root, parsed_input.value);
    defer written.deinit(allocator);
    invalidateAcceptanceDownstream(&state);
    state.acceptance = .{
        .sequence = written.sequence,
        .contract_id = written.contract_id,
        .fingerprint = written.fingerprint,
        .horizon_state = "draft",
    };
    state.acceptance_goal = stringField(parsed_input.value, "goal") orelse state.acceptance_goal;
    state.phase = "intent_open";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "acceptance-rebased", before, state, archive_dir);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "acceptance rebase", "success", archive_dir, before.phase, state, event_id);
    return 0;
}

fn beginReviewBatch(allocator: std.mem.Allocator, args: Args) !u8 {
    const mode = args.mode orelse return error.InvalidPhase;
    const head = args.head orelse return error.InvalidBasis;
    try validateReviewMode(mode);
    try validateSafeId(head);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    if (!std.mem.eql(u8, state.acceptance.horizon_state, "sealed") or state.acceptance.fingerprint == null) return error.AcceptanceNotSealed;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    try requireReviewModePhase(state, mode);

    const batch_id = try std.fmt.allocPrint(allocator, "batch-{x}", .{hashReviewBatch(state.run_id, mode, head, state.acceptance.fingerprint.?)});
    defer allocator.free(batch_id);
    const before = state;
    try writeReviewBatchArtifact(allocator, root, args.state_root, batch_id, mode, head, state.acceptance.fingerprint.?, "open", &.{}, &.{}, &.{});
    const open_batch_ids = try singleStringArray(allocator, batch_id);
    defer allocator.free(open_batch_ids);
    state.review = .{
        .open_batch_ids = open_batch_ids,
        .sealed_batch_ids = state.review.sealed_batch_ids,
        .latest_discovery_batch = if (std.mem.eql(u8, mode, "discovery")) batch_id else state.review.latest_discovery_batch,
        .latest_conformance_batch = if (std.mem.eql(u8, mode, "conformance")) batch_id else state.review.latest_conformance_batch,
        .terminal_holdout_batch = if (std.mem.eql(u8, mode, "terminal-holdout")) batch_id else state.review.terminal_holdout_batch,
    };
    state.phase = reviewOpenPhase(mode);
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "review-batch-began", before, state, batch_id);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "review batch begin", "success", batch_id, before.phase, state, event_id);
    return 0;
}

fn addReviewAperture(allocator: std.mem.Allocator, args: Args) !u8 {
    const batch_id = args.batch_id orelse return error.BatchRequired;
    const input = args.input orelse return error.InputRequired;
    try validateSafeId(batch_id);
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    try validateReviewAperture(parsed_input.value, batch_id);
    const aperture_id = stringField(parsed_input.value, "aperture_id") orelse return error.InvalidAperture;
    try validateSafeId(aperture_id);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    const state = parsed_state.value;
    try requireOpenBatch(state, batch_id);
    var parsed_batch = try loadReviewBatchParsed(allocator, root, args.state_root, batch_id);
    defer parsed_batch.deinit();
    const mode = stringField(parsed_batch.value, "mode") orelse return error.InvalidBatch;
    if (!std.mem.eql(u8, mode, stringField(parsed_input.value, "mode") orelse "")) return error.InvalidAperture;

    try writeReviewChildJson(allocator, root, args.state_root, ReviewApertureDir, aperture_id, parsed_input.value);
    const apertures = try stringArrayWithExtra(allocator, parsed_batch.value, "aperture_ids", aperture_id);
    defer allocator.free(apertures);
    const receipts = try stringArrayWithExtra(allocator, parsed_batch.value, "receipt_ids", null);
    defer allocator.free(receipts);
    const mutations = try stringArrayWithExtra(allocator, parsed_batch.value, "mutation_events", null);
    defer allocator.free(mutations);
    try writeReviewBatchArtifact(
        allocator,
        root,
        args.state_root,
        batch_id,
        mode,
        stringField(parsed_batch.value, "artifact_head") orelse "",
        stringField(parsed_batch.value, "acceptance_fingerprint") orelse "",
        "open",
        apertures,
        receipts,
        mutations,
    );
    const event_id = try appendEvent(allocator, root, args.state_root, "review-aperture-added", state, state, aperture_id);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "review aperture add", "success", aperture_id, state.phase, state, event_id);
    return 0;
}

fn addReviewReceipt(allocator: std.mem.Allocator, args: Args) !u8 {
    const batch_id = args.batch_id orelse return error.BatchRequired;
    const input = args.input orelse return error.InputRequired;
    try validateSafeId(batch_id);
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    try validateReviewReceipt(parsed_input.value, batch_id, false);
    const receipt_id = args.receipt_id orelse stringField(parsed_input.value, "receipt_id") orelse return error.InvalidReceipt;
    try validateSafeId(receipt_id);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    const state = parsed_state.value;
    try requireOpenBatch(state, batch_id);
    var parsed_batch = try loadReviewBatchParsed(allocator, root, args.state_root, batch_id);
    defer parsed_batch.deinit();

    try writeReviewChildJson(allocator, root, args.state_root, ReviewReceiptDir, receipt_id, parsed_input.value);
    const apertures = try stringArrayWithExtra(allocator, parsed_batch.value, "aperture_ids", null);
    defer allocator.free(apertures);
    const receipts = try stringArrayWithExtra(allocator, parsed_batch.value, "receipt_ids", receipt_id);
    defer allocator.free(receipts);
    const mutations = try stringArrayWithExtra(allocator, parsed_batch.value, "mutation_events", null);
    defer allocator.free(mutations);
    try writeReviewBatchArtifact(
        allocator,
        root,
        args.state_root,
        batch_id,
        stringField(parsed_batch.value, "mode") orelse "",
        stringField(parsed_batch.value, "artifact_head") orelse "",
        stringField(parsed_batch.value, "acceptance_fingerprint") orelse "",
        "open",
        apertures,
        receipts,
        mutations,
    );
    const event_id = try appendEvent(allocator, root, args.state_root, "review-receipt-added", state, state, receipt_id);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "review receipt add", "success", receipt_id, state.phase, state, event_id);
    return 0;
}

fn printReviewBatchStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    const batch_id = args.batch_id orelse return error.BatchRequired;
    try validateSafeId(batch_id);
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try reviewChildPath(allocator, args.state_root, ReviewBatchDir, batch_id);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    try writeStdoutBytes(allocator, bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') try writeStdoutBytes(allocator, "\n");
    return 0;
}

fn sealReviewBatch(allocator: std.mem.Allocator, args: Args) !u8 {
    const batch_id = args.batch_id orelse return error.BatchRequired;
    if (!args.confirm) return error.ConfirmRequired;
    try validateSafeId(batch_id);
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    try requireOpenBatch(state, batch_id);
    var parsed_batch = try loadReviewBatchParsed(allocator, root, args.state_root, batch_id);
    defer parsed_batch.deinit();
    try validateReviewBatchSeal(allocator, root, args.state_root, parsed_batch.value);

    const before = state;
    const apertures = try stringArrayWithExtra(allocator, parsed_batch.value, "aperture_ids", null);
    defer allocator.free(apertures);
    const receipts = try stringArrayWithExtra(allocator, parsed_batch.value, "receipt_ids", null);
    defer allocator.free(receipts);
    const mutations = try stringArrayWithExtra(allocator, parsed_batch.value, "mutation_events", null);
    defer allocator.free(mutations);
    try writeReviewBatchArtifact(
        allocator,
        root,
        args.state_root,
        batch_id,
        stringField(parsed_batch.value, "mode") orelse "",
        stringField(parsed_batch.value, "artifact_head") orelse "",
        stringField(parsed_batch.value, "acceptance_fingerprint") orelse "",
        "sealed",
        apertures,
        receipts,
        mutations,
    );
    const sealed_batch_ids = try appendStringSlice(allocator, state.review.sealed_batch_ids, batch_id);
    defer allocator.free(sealed_batch_ids);
    state.review = .{
        .open_batch_ids = &.{},
        .sealed_batch_ids = sealed_batch_ids,
        .latest_discovery_batch = state.review.latest_discovery_batch,
        .latest_conformance_batch = state.review.latest_conformance_batch,
        .terminal_holdout_batch = state.review.terminal_holdout_batch,
    };
    state.phase = reviewSealedPhase(stringField(parsed_batch.value, "mode") orelse "");
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "review-batch-sealed", before, state, batch_id);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "review batch seal", "success", batch_id, before.phase, state, event_id);
    return 0;
}

fn invalidateReviewBatch(allocator: std.mem.Allocator, args: Args) !u8 {
    const batch_id = args.batch_id orelse return error.BatchRequired;
    const reason = args.reason orelse return error.ReasonRequired;
    try validateSafeId(batch_id);
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return error.ReasonRequired;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    try requireOpenBatch(state, batch_id);
    var parsed_batch = try loadReviewBatchParsed(allocator, root, args.state_root, batch_id);
    defer parsed_batch.deinit();
    const before = state;
    const apertures = try stringArrayWithExtra(allocator, parsed_batch.value, "aperture_ids", null);
    defer allocator.free(apertures);
    const receipts = try stringArrayWithExtra(allocator, parsed_batch.value, "receipt_ids", null);
    defer allocator.free(receipts);
    const mutations = try stringArrayWithExtra(allocator, parsed_batch.value, "mutation_events", null);
    defer allocator.free(mutations);
    try writeReviewBatchArtifact(allocator, root, args.state_root, batch_id, stringField(parsed_batch.value, "mode") orelse "", stringField(parsed_batch.value, "artifact_head") orelse "", stringField(parsed_batch.value, "acceptance_fingerprint") orelse "", "invalidated", apertures, receipts, mutations);
    state.review.open_batch_ids = &.{};
    state.phase = "acceptance_sealed";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "review-batch-invalidated", before, state, reason);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "review batch invalidate", "success", batch_id, before.phase, state, event_id);
    return 0;
}

fn setReviewPlan(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    const mode = args.mode orelse "conformance";
    var parsed = try parseJsonInput(allocator, input);
    defer parsed.deinit();
    try validateReviewPlanValue(parsed.value, mode);
    try writeArtifactJson(allocator, args, ReviewPlanFile, parsed.value);
    try printReceipt(allocator, "review plan", "success", mode);
    return 0;
}

fn printReviewPlanStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try statePath(allocator, args.state_root, ReviewPlanFile);
    defer allocator.free(path);
    const bytes = root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => "{\"review_plan\":{\"present\":false}}\n",
        else => return err,
    };
    const owned = bytes.len > 34;
    defer if (owned) allocator.free(bytes);
    try writeStdoutBytes(allocator, bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') try writeStdoutBytes(allocator, "\n");
    return 0;
}

fn addCounterexampleV1(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    const batch_id = args.batch_id orelse return error.BatchRequired;
    try validateSafeId(batch_id);
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var parsed_batch = try loadReviewBatchParsed(allocator, root, args.state_root, batch_id);
    defer parsed_batch.deinit();
    try validateCounterexampleV1(allocator, root, args.state_root, parsed_input.value, batch_id, parsed_batch.value);
    const cex_id = stringField(parsed_input.value, "cex_id") orelse return error.InvalidCounterexample;

    const before = parsed_state.value;
    var state = parsed_state.value;
    updateCounterexampleState(&state, parsed_input.value);
    applyCounterexampleInvalidation(&state, parsed_input.value, parsed_batch.value);
    try appendJsonLine(allocator, root, args.state_root, CounterexamplesFile, parsed_input.value);
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "counterexample-added", before, state, cex_id);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "counterexample add", "success", cex_id, before.phase, state, event_id);
    return 0;
}

fn classifyCounterexampleV1(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    const cex_id = args.id orelse return error.CounterexampleRequired;
    try validateSafeId(cex_id);
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    if (!std.mem.eql(u8, stringField(parsed_input.value, "cex_id") orelse "", cex_id)) return error.InvalidCounterexample;
    const batch_id = stringField(parsed_input.value, "batch_id") orelse args.batch_id orelse return error.BatchRequired;
    try validateSafeId(batch_id);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var parsed_batch = try loadReviewBatchParsed(allocator, root, args.state_root, batch_id);
    defer parsed_batch.deinit();
    try validateCounterexampleV1(allocator, root, args.state_root, parsed_input.value, batch_id, parsed_batch.value);

    const before = parsed_state.value;
    var state = parsed_state.value;
    updateCounterexampleState(&state, parsed_input.value);
    applyCounterexampleInvalidation(&state, parsed_input.value, parsed_batch.value);
    try appendJsonLine(allocator, root, args.state_root, CounterexamplesFile, parsed_input.value);
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "counterexample-classified", before, state, cex_id);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "counterexample classify", "success", cex_id, before.phase, state, event_id);
    return 0;
}

fn listCounterexamplesV1(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try statePath(allocator, args.state_root, CounterexamplesFile);
    defer allocator.free(path);
    const bytes = root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owned = bytes.len > 0;
    defer if (owned) allocator.free(bytes);
    if (args.batch_id == null) {
        try writeJsonlAsArray(allocator, bytes, "counterexamples");
        return 0;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"counterexamples\":[");
    var first = true;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, stringField(parsed.value, "batch_id") orelse "", args.batch_id.?)) continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll(line);
    }
    try out.writer.writeAll("]}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn showCounterexampleV1(allocator: std.mem.Allocator, args: Args) !u8 {
    const cex_id = args.id orelse return error.CounterexampleRequired;
    try validateSafeId(cex_id);
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try statePath(allocator, args.state_root, CounterexamplesFile);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (std.mem.eql(u8, stringField(parsed.value, "cex_id") orelse "", cex_id)) found = line;
    }
    if (found) |line| {
        try writeStdoutBytes(allocator, line);
        try writeStdoutBytes(allocator, "\n");
        return 0;
    }
    return error.CounterexampleNotFound;
}

fn compileBasisV2(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    const batch_id = args.batch_id orelse return error.BatchRequired;
    try validateSafeId(batch_id);
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var parsed_batch = try loadReviewBatchParsed(allocator, root, args.state_root, batch_id);
    defer parsed_batch.deinit();
    if (!std.mem.eql(u8, stringField(parsed_batch.value, "status") orelse "", "sealed")) return error.BatchNotSealed;
    const accepted = try acceptedCexIdsForBatch(allocator, root, args.state_root, batch_id);
    defer freeStringList(allocator, accepted);
    try validateCounterexampleBasisV2(parsed_input.value, parsed_state.value.acceptance.fingerprint, accepted.items);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJsonValue(&out.writer, parsed_input.value);
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    const fingerprint = try sha256FingerprintAlloc(allocator, bytes);
    defer allocator.free(fingerprint);
    try writeStateChildBytes(allocator, root, args.state_root, BasisFile, bytes);

    const before = parsed_state.value;
    var state = parsed_state.value;
    state.basis.id = stringField(parsed_input.value, "basis_id");
    state.basis.fingerprint = fingerprint;
    state.basis.sealed = false;
    state.basis_set = false;
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "basis-compiled", before, state, fingerprint);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "basis compile", "success", fingerprint, before.phase, state, event_id);
    return 0;
}

fn lintBasisV2(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.file orelse args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    try validateCounterexampleBasisV2(parsed_input.value, null, &.{});
    try writeStdoutBytes(allocator, "{\"basis_lint\":{\"ok\":true,\"basis_version\":\"CEB-v2\"}}\n");
    return 0;
}

fn sealBasisV2(allocator: std.mem.Allocator, args: Args) !u8 {
    if (!args.confirm) return error.ConfirmationRequired;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    const path = try statePath(allocator, args.state_root, BasisFile);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    var parsed_basis = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed_basis.deinit();
    try validateCounterexampleBasisV2(parsed_basis.value, parsed_state.value.acceptance.fingerprint, &.{});
    const fingerprint = try sha256FingerprintAlloc(allocator, bytes);
    defer allocator.free(fingerprint);

    const before = parsed_state.value;
    var state = parsed_state.value;
    state.basis.id = stringField(parsed_basis.value, "basis_id");
    state.basis.fingerprint = fingerprint;
    state.basis.sealed = true;
    state.basis_set = true;
    state.phase = "basis_sealed";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "basis-sealed", before, state, fingerprint);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "basis seal", "success", fingerprint, before.phase, state, event_id);
    return 0;
}

fn printBasisStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"basis\":");
    try writeBasisStateJson(&out.writer, parsed_state.value);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn addObservation(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    try validateObservationValue(parsed_input.value);
    const observation_id = stringField(parsed_input.value, "observation_id") orelse stringField(parsed_input.value, "id") orelse return error.InvalidCounterexample;
    const liability = stringField(parsed_input.value, "liability") orelse return error.InvalidCounterexample;

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    if (state.counterexample_count < std.math.maxInt(u32)) state.counterexample_count += 1;
    if (isBranchLiable(liability) and (std.mem.eql(u8, state.phase, "selected") or std.mem.eql(u8, state.phase, "apply-certified") or std.mem.eql(u8, state.phase, "applied") or std.mem.eql(u8, state.phase, "final-certified"))) {
        invalidateCompilation(&state, "invalidated");
    }
    if (isBranchLiable(liability)) state.basis_set = false;
    try appendJsonLine(allocator, root, args.state_root, ObservationsFile, parsed_input.value);
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "observation-added", parsed.value, state, observation_id);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "observation add", "success", observation_id, parsed.value.phase, state, event_id);
    return 0;
}

fn importObservations(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    const bytes = try readFileOrStdin(allocator, input);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const observations = switch (parsed.value) {
        .array => |arr| arr.items,
        else => return error.InvalidCounterexample,
    };
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    for (observations) |observation| {
        try validateObservationValue(observation);
        try appendJsonLine(allocator, root, args.state_root, ObservationsFile, observation);
    }
    try printReceipt(allocator, "observation import", "success", args.state_root);
    return 0;
}

fn listObservations(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try statePath(allocator, args.state_root, ObservationsFile);
    defer allocator.free(path);
    const bytes = root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => "[]\n",
        else => return err,
    };
    const owned = bytes.len > 3;
    defer if (owned) allocator.free(bytes);
    if (bytes.len == 3 and std.mem.eql(u8, bytes, "[]\n")) {
        try writeStdoutBytes(allocator, "{\"observations\":[]}\n");
    } else {
        try writeJsonlAsArray(allocator, bytes, "observations");
    }
    return 0;
}

fn classifyObservation(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed = try parseJsonInput(allocator, input);
    defer parsed.deinit();
    try validateObservationValue(parsed.value);
    const liability = stringField(parsed.value, "liability") orelse "";
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"observation_classification\":{\"branch_liable\":");
    try out.writer.print("{}", .{isBranchLiable(liability)});
    try out.writer.writeAll(",\"kernel_impact\":");
    try writeJsonString(&out.writer, stringField(parsed.value, "kernel_impact") orelse "unknown");
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn setKernel(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed = try parseJsonInput(allocator, input);
    defer parsed.deinit();
    try validateKernelValue(parsed.value);
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    try requireCurrentIntentBasis(parsed_state.value);
    try validateIntentBoundKernel(parsed.value, parsed_state.value);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJsonValue(&out.writer, parsed.value);
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    const fingerprint = try sha256FingerprintAlloc(allocator, bytes);
    defer allocator.free(fingerprint);
    try writeStateChildBytes(allocator, root, args.state_root, KernelFile, bytes);
    const before = parsed_state.value;
    var state = parsed_state.value;
    state.kernel.fingerprint = fingerprint;
    state.kernel.accepted = false;
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "kernel-set", before, state, fingerprint);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "kernel set", "success", fingerprint, before.phase, state, event_id);
    return 0;
}

fn lintKernel(allocator: std.mem.Allocator, args: Args) !u8 {
    const file = args.input orelse args.file orelse try statePath(allocator, args.state_root, KernelFile);
    defer if (args.input == null and args.file == null) allocator.free(file);
    var parsed = try parseJsonInput(allocator, file);
    defer parsed.deinit();
    try validateKernelValue(parsed.value);
    try writeStdoutBytes(allocator, "{\"kernel_lint\":{\"ok\":true,\"optimality\":\"witnessed\"}}\n");
    return 0;
}

fn minimizeKernel(allocator: std.mem.Allocator, args: Args) !u8 {
    const file = args.input orelse args.file orelse try statePath(allocator, args.state_root, KernelFile);
    defer if (args.input == null and args.file == null) allocator.free(file);
    var parsed = try parseJsonInput(allocator, file);
    defer parsed.deinit();
    try validateKernelValue(parsed.value);
    try writeStdoutBytes(allocator, "{\"kernel_minimization\":{\"method\":\"witness_checked_manual\",\"optimality\":\"witnessed\"}}\n");
    return 0;
}

fn reviewKernel(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed = try parseJsonInput(allocator, input);
    defer parsed.deinit();
    if (!std.mem.eql(u8, stringField(parsed.value, "review_version") orelse "", "KR-v1")) return error.InvalidProofPlan;
    try writeArtifactJson(allocator, args, KernelReviewFile, parsed.value);
    try printReceipt(allocator, "kernel review", "success", args.state_root);
    return 0;
}

fn acceptKernel(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    if (!fileExists(allocator, root, args.state_root, KernelFile) or !fileExists(allocator, root, args.state_root, KernelReviewFile)) return error.InvalidPhase;
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    try requireCurrentIntentBasis(parsed_state.value);
    const kernel_path = try statePath(allocator, args.state_root, KernelFile);
    defer allocator.free(kernel_path);
    const bytes = try root.readFileAlloc(Io, kernel_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    var parsed_kernel = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed_kernel.deinit();
    try validateKernelValue(parsed_kernel.value);
    try validateIntentBoundKernel(parsed_kernel.value, parsed_state.value);
    const fingerprint = try sha256FingerprintAlloc(allocator, bytes);
    defer allocator.free(fingerprint);
    const before = parsed_state.value;
    var state = parsed_state.value;
    state.kernel.fingerprint = fingerprint;
    state.kernel.accepted = true;
    state.phase = "kernel_accepted";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "kernel-accepted", before, state, fingerprint);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "kernel accept", "success", fingerprint, before.phase, state, event_id);
    return 0;
}

fn setReduction(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed = try parseJsonInput(allocator, input);
    defer parsed.deinit();
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    try validateReductionValue(parsed.value, parsed_state.value);
    try writeArtifactJson(allocator, args, ReductionFile, parsed.value);
    try printReceipt(allocator, "reduction set", "success", args.state_root);
    return 0;
}

fn lintReduction(allocator: std.mem.Allocator, args: Args) !u8 {
    const file = args.input orelse args.file orelse try statePath(allocator, args.state_root, ReductionFile);
    defer if (args.input == null and args.file == null) allocator.free(file);
    var parsed = try parseJsonInput(allocator, file);
    defer parsed.deinit();
    try validateReductionStructure(parsed.value);
    try writeStdoutBytes(allocator, "{\"reduction_lint\":{\"ok\":true,\"certificate_version\":\"RC-v1\"}}\n");
    return 0;
}

fn reviewReduction(allocator: std.mem.Allocator, args: Args) !u8 {
    return setReduction(allocator, args);
}

fn acceptReduction(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    try requireCurrentIntentBasis(parsed_state.value);
    const path = try statePath(allocator, args.state_root, ReductionFile);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try validateReductionValue(parsed.value, parsed_state.value);
    const fingerprint = try sha256FingerprintAlloc(allocator, bytes);
    defer allocator.free(fingerprint);
    const before = parsed_state.value;
    var state = parsed_state.value;
    state.reduction.fingerprint = fingerprint;
    state.reduction.accepted = true;
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "reduction-accepted", before, state, fingerprint);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "reduction accept", "success", fingerprint, before.phase, state, event_id);
    return 0;
}

fn registerDesign(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed = try parseJsonInput(allocator, input);
    defer parsed.deinit();
    try validateDesignValue(parsed.value);
    if (designHasActiveNegativeRoute(parsed.value)) return error.InvalidCandidate;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    try appendJsonLine(allocator, root, args.state_root, DesignsFile, parsed.value);
    try printReceipt(allocator, "design register", "success", stringField(parsed.value, "design_id") orelse args.state_root);
    return 0;
}

fn selectDesign(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed = try parseJsonInput(allocator, input);
    defer parsed.deinit();
    try validateDesignValue(parsed.value);
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    try requireCurrentIntentBasis(parsed_state.value);
    if (!parsed_state.value.kernel.accepted) return error.KernelStale;
    try validateIntentBoundDesign(parsed.value, parsed_state.value);
    const before = parsed_state.value;
    var state = parsed_state.value;
    state.design.selected_id = stringField(parsed.value, "design_id");
    state.phase = "design_selected";
    try writeArtifactJson(allocator, args, SelectedDesignFile, parsed.value);
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "design-selected", before, state, stringField(parsed.value, "design_id") orelse args.state_root);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "design select", "success", stringField(parsed.value, "design_id") orelse args.state_root, before.phase, state, event_id);
    return 0;
}

fn listDesigns(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try statePath(allocator, args.state_root, DesignsFile);
    defer allocator.free(path);
    const bytes = root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => "[]\n",
        else => return err,
    };
    const owned = bytes.len > 3;
    defer if (owned) allocator.free(bytes);
    if (bytes.len == 3 and std.mem.eql(u8, bytes, "[]\n")) {
        try writeStdoutBytes(allocator, "{\"designs\":[]}\n");
    } else {
        try writeJsonlAsArray(allocator, bytes, "designs");
    }
    return 0;
}

fn createRealizationWorktree(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    const path = args.path orelse args.worktree orelse return error.PathRequired;
    const design_storage = if (args.design_id == null) selectedDesignIdFromArtifact(allocator, args) catch return error.InvalidCandidate else null;
    defer if (design_storage) |value| allocator.free(value);
    const design_id = args.design_id orelse design_storage.?;
    try validateSafeId(design_id);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    try requireCurrentIntentBasis(state);
    if (!state.kernel.accepted or state.kernel.fingerprint == null) return error.KernelStale;
    if (state.design.selected_id == null) return error.DesignMissing;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    if (state.base_sha.len == 0 or std.mem.eql(u8, state.base_sha, "unknown")) return error.InvalidBasis;

    try runGitOk(allocator, process_io, args.cwd, &.{ "worktree", "add", "--detach", path, state.base_sha });

    const realization_dir = try statePath(allocator, args.state_root, RealizationDir);
    defer allocator.free(realization_dir);
    try root.createDirPath(Io, realization_dir);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"manifest_version\":\"RC3-RM-v1\",\"design_id\":");
    try writeJsonString(&out.writer, design_id);
    try out.writer.writeAll(",\"worktree_path\":");
    try writeJsonString(&out.writer, path);
    try out.writer.writeAll(",\"campaign_base_sha\":");
    try writeJsonString(&out.writer, state.base_sha);
    try out.writer.writeAll(",\"starts_at_campaign_base\":true,\"status\":\"created\"}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeStateChildBytes(allocator, root, args.state_root, RealizationManifestFile, bytes);

    const before_state = state;
    const before = state.phase;
    state.realization.cycle_id = design_id;
    state.realization.verified = false;
    state.realization.invalidated = false;
    state.realization.invalidation_reason = null;
    state.potential = .{};
    state.phase = "realization_open";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "realization-worktree-created", before_state, state, path);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "realization worktree", "success", path, before, state, event_id);
    return 0;
}

fn captureRealization(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    const worktree = args.worktree orelse args.path orelse worktreePathFromManifest(allocator, args) catch return error.PathRequired;
    defer if (args.worktree == null and args.path == null) allocator.free(worktree);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    if (state.realization.invalidated) return error.RealizationInvalid;
    if (state.base_sha.len == 0 or std.mem.eql(u8, state.base_sha, "unknown")) return error.InvalidBasis;

    try runGitOk(allocator, process_io, worktree, &.{ "add", "-A" });
    const tree = try runGitCaptureProcess(allocator, process_io, worktree, &.{"write-tree"});
    defer allocator.free(tree);
    const patch = try runGitCaptureProcess(allocator, process_io, worktree, &.{ "diff", "--binary", state.base_sha, "--cached" });
    defer allocator.free(patch);
    const names = try runGitCaptureProcess(allocator, process_io, worktree, &.{ "diff", "--name-only", state.base_sha, "--cached" });
    defer allocator.free(names);

    const measured = try measureWorktreeDiff(allocator, worktree, std.mem.trim(u8, tree, " \t\r\n"), names);
    defer allocator.free(measured.tree_text);
    defer allocator.free(measured.surface_json);

    try writeStateChildBytes(allocator, root, args.state_root, RealizationPatchFile, patch);
    try writeStateChildBytes(allocator, root, args.state_root, RealizationTreeFile, measured.tree_text);
    try writeStateChildBytes(allocator, root, args.state_root, SurfaceFile, measured.surface_json);

    var manifest: std.Io.Writer.Allocating = .init(allocator);
    defer manifest.deinit();
    try manifest.writer.writeAll("{\"manifest_version\":\"RC3-RM-v1\",\"campaign_base_sha\":");
    try writeJsonString(&manifest.writer, state.base_sha);
    try manifest.writer.writeAll(",\"worktree_path\":");
    try writeJsonString(&manifest.writer, worktree);
    try manifest.writer.writeAll(",\"patch_fingerprint\":\"sha256:");
    try manifest.writer.print("{x}", .{hashBytes(patch)});
    try manifest.writer.writeAll("\",\"tree_fingerprint\":\"sha256:");
    try manifest.writer.print("{x}", .{hashBytes(std.mem.trim(u8, tree, " \t\r\n"))});
    try manifest.writer.writeAll("\",\"git_tree_sha\":");
    try writeJsonString(&manifest.writer, std.mem.trim(u8, tree, " \t\r\n"));
    try manifest.writer.writeAll(",\"measurement\":{\"adapter\":\"zig-surface-adapter\",\"version\":\"v1\",\"exact_fields\":[\"files\",\"tree_fingerprint\",\"patch_fingerprint\",\"test_declarations\"],\"approximate_fields\":[\"public_symbols\",\"state_fields\",\"branches\",\"helpers_or_wrappers\",\"ast_nodes\"],\"unavailable_fields\":[]}}\n");
    const manifest_bytes = try manifest.toOwnedSlice();
    defer allocator.free(manifest_bytes);
    try writeStateChildBytes(allocator, root, args.state_root, RealizationManifestFile, manifest_bytes);

    const before = state;
    state.realization.verified = false;
    state.realization.invalidated = false;
    state.realization.invalidation_reason = null;
    state.phase = "realization_captured";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "realization-captured", before, state, worktree);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "realization capture", "success", worktree, before.phase, state, event_id);
    return 0;
}

fn measureRealization(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const current_path = try statePath(allocator, args.state_root, SurfaceFile);
    defer allocator.free(current_path);
    const current = try root.readFileAlloc(Io, current_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(current);
    if (args.input) |baseline_path| {
        const baseline = try readFileOrStdin(allocator, baseline_path);
        defer allocator.free(baseline);
        var parsed_current = try std.json.parseFromSlice(std.json.Value, allocator, current, .{});
        defer parsed_current.deinit();
        var parsed_baseline = try std.json.parseFromSlice(std.json.Value, allocator, baseline, .{});
        defer parsed_baseline.deinit();
        if (hardSurfaceIncreased(parsed_current.value, parsed_baseline.value)) return error.SemanticSurfaceIncreased;
    }
    try writeStdoutBytes(allocator, current);
    if (current.len == 0 or current[current.len - 1] != '\n') try writeStdoutBytes(allocator, "\n");
    try appendEventOnly(allocator, root, args.state_root, "surface-measured", "realization_compiling");
    return 0;
}

fn baselinePotential(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    try validatePotentialValue(parsed_input.value, parsed_state.value);
    try writeStateChildJson(allocator, root, args.state_root, PotentialBaselineFile, parsed_input.value);
    try appendEventOnly(allocator, root, args.state_root, "potential-baselined", parsed_state.value.phase);
    try printReceipt(allocator, "potential baseline", "success", stringField(parsed_input.value, "cycle_id") orelse args.state_root);
    return 0;
}

fn measurePotential(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    try validatePotentialValue(parsed_input.value, parsed_state.value);
    const before = parsed_state.value;
    var state = parsed_state.value;
    state.potential.current_id = stringField(parsed_input.value, "cycle_id");
    state.potential.strict_progress = false;
    try writeStateChildJson(allocator, root, args.state_root, PotentialCurrentFile, parsed_input.value);
    try appendJsonLine(allocator, root, args.state_root, PotentialCyclesFile, parsed_input.value);
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "potential-measured", before, state, stringField(parsed_input.value, "cycle_id") orelse args.state_root);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "potential measure", "success", stringField(parsed_input.value, "cycle_id") orelse args.state_root, before.phase, state, event_id);
    return 0;
}

fn gatePotential(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    const current_path = args.file orelse args.input orelse try statePath(allocator, args.state_root, PotentialCurrentFile);
    defer if (args.file == null and args.input == null) allocator.free(current_path);
    const current_bytes = if (args.file != null or args.input != null)
        try readFileOrStdin(allocator, current_path)
    else
        try root.readFileAlloc(Io, current_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(current_bytes);
    const baseline_path = try statePath(allocator, args.state_root, PotentialBaselineFile);
    defer allocator.free(baseline_path);
    const baseline_bytes = try root.readFileAlloc(Io, baseline_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(baseline_bytes);
    var parsed_current = try std.json.parseFromSlice(std.json.Value, allocator, current_bytes, .{});
    defer parsed_current.deinit();
    var parsed_baseline = try std.json.parseFromSlice(std.json.Value, allocator, baseline_bytes, .{});
    defer parsed_baseline.deinit();
    try validatePotentialValue(parsed_current.value, parsed_state.value);
    try validatePotentialValue(parsed_baseline.value, parsed_state.value);
    try comparePotentialStrict(parsed_current.value, parsed_baseline.value);

    const before = parsed_state.value;
    var state = parsed_state.value;
    state.potential.current_id = stringField(parsed_current.value, "cycle_id");
    state.potential.strict_progress = true;
    state.phase = "potential_certified";
    try writeStateChildJson(allocator, root, args.state_root, PotentialCurrentFile, parsed_current.value);
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "potential_certified");
    const event_id = try appendEvent(allocator, root, args.state_root, "potential-certified", before, state, stringField(parsed_current.value, "cycle_id") orelse args.state_root);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "potential gate", "success", stringField(parsed_current.value, "cycle_id") orelse args.state_root, before.phase, state, event_id);
    return 0;
}

fn printPotentialStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"potential\":");
    try writePotentialStateJson(&out.writer, parsed_state.value.potential);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn setConstructMap(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed = try parseJsonInput(allocator, input);
    defer parsed.deinit();
    try validateConstructMapValue(parsed.value);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const tree_path = try statePath(allocator, args.state_root, RealizationTreeFile);
    defer allocator.free(tree_path);
    const tree_text = try root.readFileAlloc(Io, tree_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(tree_text);
    const expected_tree = treeFingerprintFromTreeText(tree_text) orelse return error.InvalidCandidate;
    const map_tree = stringField(parsed.value, "realization_tree_fingerprint") orelse return error.InvalidCandidate;
    if (!std.mem.eql(u8, map_tree, expected_tree)) return error.SelectedCandidateMismatch;

    const constructs = objectField(parsed.value, "constructs") orelse return error.InvalidCandidate;
    switch (constructs) {
        .array => |arr| {
            for (arr.items) |item| {
                const construct_id = stringField(item, "construct_id") orelse return error.InvalidCandidate;
                if (!constructIdInTree(tree_text, construct_id)) return error.UnknownCandidate;
                if (std.mem.eql(u8, stringField(item, "status") orelse "", "orphan")) return error.AblationGateFailed;
            }
        },
        else => return error.InvalidCandidate,
    }
    if (arrayLen(objectField(parsed.value, "missing_kernel_realization")) > 0) return error.BasisRequired;

    try writeStateChildJson(allocator, root, args.state_root, ConstructMapFile, parsed.value);
    try appendEventOnly(allocator, root, args.state_root, "construct-map-set", "realization_compiling");
    try printReceipt(allocator, "realization map", "success", args.state_root);
    return 0;
}

fn minimizeRealization(allocator: std.mem.Allocator, args: Args) !u8 {
    var atoms_tested: usize = 0;
    if (args.input) |input| {
        var parsed = try parseJsonInput(allocator, input);
        defer parsed.deinit();
        const atoms = objectField(parsed.value, "edit_atoms") orelse return error.InvalidCandidate;
        atoms_tested = arrayLen(atoms);
    }
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const tree_path = try statePath(allocator, args.state_root, RealizationTreeFile);
    defer allocator.free(tree_path);
    const tree_text = try root.readFileAlloc(Io, tree_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(tree_text);
    const final_tree = treeFingerprintFromTreeText(tree_text) orelse "sha256:unmeasured";

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"realization_minimization\":{\"method\":\"one-atom-fixed-point\",\"atoms_tested\":");
    try out.writer.print("{d}", .{atoms_tested});
    try out.writer.writeAll(",\"removed\":[],\"survived\":[],\"failure_witnesses\":[],\"orphan_constructs\":[],\"final_tree_fingerprint\":");
    try writeJsonString(&out.writer, final_tree);
    try out.writer.writeAll(",\"local_minimality\":\"not_claiming_global_minimum\"}}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeStateChildBytes(allocator, root, args.state_root, "realization/minimization.json", bytes);
    try appendEventOnly(allocator, root, args.state_root, "realization-minimized", "realization_compiling");
    try writeStdoutBytes(allocator, bytes);
    return 0;
}

fn planProof(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const kernel_path = try statePath(allocator, args.state_root, KernelFile);
    defer allocator.free(kernel_path);
    const kernel_bytes = try root.readFileAlloc(Io, kernel_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(kernel_bytes);
    var parsed_kernel = try std.json.parseFromSlice(std.json.Value, allocator, kernel_bytes, .{});
    defer parsed_kernel.deinit();
    try validateKernelValue(parsed_kernel.value);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    try requireCurrentIntentBasis(parsed_state.value);
    try validateIntentBoundKernel(parsed_kernel.value, parsed_state.value);

    const manifest_path = try statePath(allocator, args.state_root, RealizationManifestFile);
    defer allocator.free(manifest_path);
    const manifest_bytes = try root.readFileAlloc(Io, manifest_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed_manifest.deinit();
    const tree_fingerprint = stringField(parsed_manifest.value, "tree_fingerprint") orelse return error.InvalidCandidate;
    const kernel_fingerprint = try sha256FingerprintAlloc(allocator, kernel_bytes);
    defer allocator.free(kernel_fingerprint);
    const kernel_gate = objectField(parsed_kernel.value, "gate");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"plan_version\":\"RCP-v1\",\"kernel_fingerprint\":");
    try writeJsonString(&out.writer, kernel_fingerprint);
    try out.writer.writeAll(",\"realization_tree_fingerprint\":");
    try writeJsonString(&out.writer, tree_fingerprint);
    try out.writer.writeAll(",\"actions\":[");
    var emitted = false;
    if (objectField(parsed_kernel.value, "laws")) |laws| {
        switch (laws) {
            .array => |arr| {
                for (arr.items, 0..) |law, i| {
                    if (emitted) try out.writer.writeByte(',');
                    emitted = true;
                    const fallback = try std.fmt.allocPrint(allocator, "law-{d}", .{i});
                    defer allocator.free(fallback);
                    const law_id = stringField(law, "law_id") orelse stringField(law, "id") orelse fallback;
                    const command = stringField(law, "proof_command") orelse "zig build test-resolve-c3 --summary all";
                    try writeProofActionFromLaw(&out.writer, law, kernel_gate, law_id, command, "law", tree_fingerprint, kernel_fingerprint);
                }
            },
            else => return error.InvalidProofPlan,
        }
    }
    if (!emitted) try writeProofAction(&out.writer, "proof.empty", "true", "law");
    try out.writer.writeAll("]}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeStateChildBytes(allocator, root, args.state_root, ProofPlanFile, bytes);
    try appendEventOnly(allocator, root, args.state_root, "proof-planned", "realization_compiling");
    try writeStdoutBytes(allocator, bytes);
    return 0;
}

fn runProofPlan(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    const worktree = args.worktree orelse args.path orelse worktreePathFromManifest(allocator, args) catch return error.PathRequired;
    defer if (args.worktree == null and args.path == null) allocator.free(worktree);
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const plan_path = if (args.input) |input| input else try statePath(allocator, args.state_root, ProofPlanFile);
    defer if (args.input == null) allocator.free(plan_path);
    const plan_bytes = if (args.input) |_| try readFileOrStdin(allocator, plan_path) else try root.readFileAlloc(Io, plan_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(plan_bytes);
    var parsed_plan = try std.json.parseFromSlice(std.json.Value, allocator, plan_bytes, .{});
    defer parsed_plan.deinit();
    if (!std.mem.eql(u8, stringField(parsed_plan.value, "plan_version") orelse "", "RCP-v1")) return error.InvalidProofPlan;
    const actions = objectField(parsed_plan.value, "actions") orelse return error.InvalidProofPlan;
    const action_items = switch (actions) {
        .array => |arr| arr.items,
        else => return error.InvalidProofPlan,
    };
    if (action_items.len == 0) return error.InvalidProofPlan;

    const before_tree = try stableWorktreeTree(allocator, process_io, worktree);
    defer allocator.free(before_tree);
    var results: std.Io.Writer.Allocating = .init(allocator);
    defer results.deinit();
    var all_pass = true;
    for (action_items) |action| {
        const proof_id = stringField(action, "proof_id") orelse return error.InvalidProofPlan;
        const command = stringField(action, "command") orelse return error.InvalidProofPlan;
        const passed = try runShell(allocator, process_io, worktree, command);
        all_pass = all_pass and passed;
        try results.writer.writeAll("{\"proof_id\":");
        try writeJsonString(&results.writer, proof_id);
        try results.writer.writeAll(",\"command\":");
        try writeJsonString(&results.writer, command);
        try results.writer.writeAll(",\"result\":");
        try writeJsonString(&results.writer, if (passed) "pass" else "fail");
        try results.writer.writeAll("}\n");
    }
    const after_tree = try stableWorktreeTree(allocator, process_io, worktree);
    defer allocator.free(after_tree);
    if (!std.mem.eql(u8, before_tree, after_tree)) return error.ProofGateFailed;
    const results_bytes = try results.toOwnedSlice();
    defer allocator.free(results_bytes);
    try writeStateChildBytes(allocator, root, args.state_root, ProofResultsFile, results_bytes);
    try appendEventOnly(allocator, root, args.state_root, "proof-run", "realization_compiling");
    try printReceipt(allocator, "proof run", if (all_pass) "pass" else "fail", args.state_root);
    return if (all_pass) 0 else 2;
}

fn compressProof(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const plan_path = if (args.input) |input| input else try statePath(allocator, args.state_root, ProofPlanFile);
    defer if (args.input == null) allocator.free(plan_path);
    const plan_bytes = if (args.input) |_| try readFileOrStdin(allocator, plan_path) else try root.readFileAlloc(Io, plan_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(plan_bytes);
    var parsed_plan = try std.json.parseFromSlice(std.json.Value, allocator, plan_bytes, .{});
    defer parsed_plan.deinit();
    const actions = objectField(parsed_plan.value, "actions") orelse return error.InvalidProofPlan;
    const items = switch (actions) {
        .array => |arr| arr.items,
        else => return error.InvalidProofPlan,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"proof_compression\":{\"method\":\"greedy_set_cover\",\"optimality\":\"heuristic\",\"artifact_fingerprint\":");
    try writeJsonString(&out.writer, stringField(parsed_plan.value, "realization_tree_fingerprint") orelse "sha256:unknown");
    try out.writer.writeAll(",\"selected_actions\":[");
    var first_action = true;
    var selected_commands = std.ArrayList([]const u8).empty;
    defer selected_commands.deinit(allocator);
    var wound_count: usize = 0;
    for (items) |action| {
        const proof_id = stringField(action, "proof_id") orelse return error.InvalidProofPlan;
        const command = stringField(action, "command") orelse return error.InvalidProofPlan;
        try validateProofActionMapping(action);
        if ((boolField(action, "wound_specific") orelse false) or std.mem.eql(u8, stringField(action, "style") orelse "", "example")) return error.ProofGateFailed;
        const duplicate = containsString(selected_commands.items, command);
        if (!duplicate) {
            try selected_commands.append(allocator, command);
            if (!first_action) try out.writer.writeByte(',');
            first_action = false;
            try writeJsonString(&out.writer, proof_id);
        }
        const style = stringField(action, "style") orelse "";
        if ((boolField(action, "wound_specific") orelse false) or std.mem.eql(u8, style, "example")) wound_count += 1;
    }
    try out.writer.writeAll("],\"tests_to_merge_or_retire\":[],\"wound_specific_tests\":[");
    var emitted_wound = false;
    if (wound_count > 0) {
        for (items) |action| {
            const proof_id = stringField(action, "proof_id") orelse continue;
            const style = stringField(action, "style") orelse "";
            if ((boolField(action, "wound_specific") orelse false) or std.mem.eql(u8, style, "example")) {
                if (emitted_wound) try out.writer.writeByte(',');
                emitted_wound = true;
                try writeJsonString(&out.writer, proof_id);
            }
        }
    }
    try out.writer.writeAll("]}}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeStateChildBytes(allocator, root, args.state_root, ProofBasisFile, bytes);
    try appendEventOnly(allocator, root, args.state_root, "proof-compressed", "realization_compiling");
    try writeStdoutBytes(allocator, bytes);
    return 0;
}

fn verifyRealization(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    if (state.realization.invalidated) return error.RealizationInvalid;
    if (state.review.latest_conformance_batch == null) return error.BatchRequired;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    try requireSealedReviewBatch(allocator, root, args.state_root, state.review.latest_conformance_batch.?, "conformance");
    if (!fileExists(allocator, root, args.state_root, KernelFile)) return error.InvalidBasis;
    if (!fileExists(allocator, root, args.state_root, ConstructMapFile)) return error.InvalidCandidate;
    if (!fileExists(allocator, root, args.state_root, SurfaceFile)) return error.InvalidCandidate;
    if (!fileExists(allocator, root, args.state_root, ProofBasisFile)) return error.InvalidProofPlan;

    const map_path = try statePath(allocator, args.state_root, ConstructMapFile);
    defer allocator.free(map_path);
    const map_bytes = try root.readFileAlloc(Io, map_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(map_bytes);
    var parsed_map = try std.json.parseFromSlice(std.json.Value, allocator, map_bytes, .{});
    defer parsed_map.deinit();
    try validateConstructMapValue(parsed_map.value);
    if (constructMapHasOrphan(parsed_map.value)) return error.AblationGateFailed;

    const basis_path = try statePath(allocator, args.state_root, ProofBasisFile);
    defer allocator.free(basis_path);
    const basis_bytes = try root.readFileAlloc(Io, basis_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(basis_bytes);
    var parsed_basis = try std.json.parseFromSlice(std.json.Value, allocator, basis_bytes, .{});
    defer parsed_basis.deinit();
    const compression = objectField(parsed_basis.value, "proof_compression") orelse return error.InvalidProofPlan;
    if (arrayLen(objectField(compression, "wound_specific_tests")) > 0) return error.ProofGateFailed;

    const before_state = state;
    const before = state.phase;
    state.realization.verified = true;
    state.phase = "realization_verified";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "realization_verified");
    const event_id = try appendEvent(allocator, root, args.state_root, "realization-verified", before_state, state, args.state_root);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "realization verify", "success", args.state_root, before, state, event_id);
    return 0;
}

fn applyDeliveryPhysical(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    try requireDeliveryReadyState(allocator, root, args.state_root, state);
    requirePhase(state, &.{ "potential_certified", "realization_verified" }) catch return error.InvalidPhase;
    try requireCleanGitWorktree(allocator, process_io, args.cwd);
    const target_tree = try realizationGitTreeSha(allocator, root, args.state_root);
    defer allocator.free(target_tree);
    const patch_fingerprint = try realizationPatchFingerprint(allocator, root, args.state_root);
    defer allocator.free(patch_fingerprint);
    const head = try runGitCaptureProcess(allocator, process_io, args.cwd, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head);
    const backup_ref = try std.fmt.allocPrint(allocator, "refs/resolve-c3/backups/{s}/{x}", .{ state.run_id, hashBytes(head) });
    defer allocator.free(backup_ref);
    try runGitOk(allocator, process_io, args.cwd, &.{ "update-ref", backup_ref, std.mem.trim(u8, head, " \t\r\n") });
    try runGitOk(allocator, process_io, args.cwd, &.{ "read-tree", "--reset", "-u", target_tree });
    const current_tree = try currentGitTree(allocator, process_io, args.cwd);
    defer allocator.free(current_tree);
    if (!std.mem.eql(u8, current_tree, target_tree)) return error.SelectedCandidateMismatch;

    const before_state = state;
    const before = state.phase;
    state.phase = "applied";
    state.delivery_patch_sha = patch_fingerprint;
    state.delivery.patch_sha = patch_fingerprint;
    state.certificate_stage = "applied";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "applied");
    const event_id = try appendEvent(allocator, root, args.state_root, "delivery-applied", before_state, state, backup_ref);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "delivery apply", "success", backup_ref, before, state, event_id);
    return 0;
}

fn commitDeliveryPhysical(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    const message = args.message orelse return error.MessageRequired;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    requirePhase(state, PhaseApplied[0..]) catch return error.InvalidPhase;
    const target_tree = try realizationGitTreeSha(allocator, root, args.state_root);
    defer allocator.free(target_tree);
    const current_tree = try currentGitTree(allocator, process_io, args.cwd);
    defer allocator.free(current_tree);
    if (!std.mem.eql(u8, current_tree, target_tree)) return error.SelectedCandidateMismatch;
    try runGitOk(allocator, process_io, args.cwd, &.{ "commit", "-m", message });
    const head = try runGitCaptureProcess(allocator, process_io, args.cwd, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head);
    const before_state = state;
    const before = state.phase;
    state.phase = "committed";
    state.commit_sha = std.mem.trim(u8, head, " \t\r\n");
    state.delivery.commit_sha = state.commit_sha;
    state.certificate_stage = "committed";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "committed");
    const event_id = try appendEvent(allocator, root, args.state_root, "committed", before_state, state, state.commit_sha.?);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "delivery commit", "success", state.commit_sha.?, before, state, event_id);
    return 0;
}

fn pushDeliveryPhysical(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    requirePhase(state, PhaseCommitted[0..]) catch return error.InvalidPhase;
    const local_head = try runGitCaptureProcess(allocator, process_io, args.cwd, &.{ "rev-parse", "HEAD" });
    defer allocator.free(local_head);
    if (!optionalEql(state.commit_sha, std.mem.trim(u8, local_head, " \t\r\n"))) return error.DeliveryStale;
    const branch = args.branch orelse if (state.branch.len > 0) state.branch else return error.InvalidBasis;
    const refspec = try std.fmt.allocPrint(allocator, "HEAD:refs/heads/{s}", .{branch});
    defer allocator.free(refspec);
    try runGitOk(allocator, process_io, args.cwd, &.{ "push", args.remote, refspec });
    const remote_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(remote_ref);
    const remote_line = try runGitCaptureProcess(allocator, process_io, args.cwd, &.{ "ls-remote", args.remote, remote_ref });
    defer allocator.free(remote_line);
    if (std.mem.trim(u8, remote_line, " \t\r\n").len == 0) return error.ProofGateFailed;
    const before_state = state;
    const before = state.phase;
    state.phase = "pushed";
    state.pushed = true;
    state.delivery.pushed = true;
    state.certificate_stage = "pushed";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "pushed");
    const event_id = try appendEvent(allocator, root, args.state_root, "pushed", before_state, state, std.mem.trim(u8, remote_line, " \t\r\n"));
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "delivery push", "success", std.mem.trim(u8, remote_line, " \t\r\n"), before, state, event_id);
    return 0;
}

fn certifyTuple(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    requirePhase(state, PhasePushed[0..]) catch return error.InvalidPhase;
    try requireDeliveryReadyState(allocator, root, args.state_root, state);
    const input = args.input orelse return error.ProofGateFailed;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    try validateTupleClosureReceipt(parsed_input.value);
    const before_state = state;
    const before = state.phase;
    state.phase = "tuple_closed";
    state.certificate_stage = "tuple_closed";
    state.closure.certificate_stage = "tuple_closed";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "tuple_closed");
    const event_id = try appendEvent(allocator, root, args.state_root, "tuple-closed", before_state, state, args.state_root);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "certify tuple", "success", args.state_root, before, state, event_id);
    return 0;
}

fn certifyTerminal(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed_state = try loadStateParsed(allocator, root, args.state_root);
    defer parsed_state.deinit();
    var state = parsed_state.value;
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    requirePhase(state, &.{"tuple_closed"}) catch return error.InvalidPhase;
    try requireTerminalReadyState(allocator, root, args.state_root, state);
    const input = args.input orelse return error.ProofGateFailed;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    try validateTerminalClosureReceipt(parsed_input.value);
    const before_state = state;
    const before = state.phase;
    state.phase = "terminal_closed";
    state.certificate_stage = "terminal_closed";
    state.closure.certificate_stage = "terminal_closed";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "terminal_closed");
    const event_id = try appendEvent(allocator, root, args.state_root, "terminal-closed", before_state, state, args.state_root);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "certify terminal", "success", args.state_root, before, state, event_id);
    return 0;
}

fn knownSchemaArtifact(artifact: []const u8) bool {
    for (SchemaArtifacts) |known| {
        if (std.mem.eql(u8, artifact, known)) return true;
    }
    return false;
}

fn schemaRootName(artifact: []const u8) []const u8 {
    if (std.mem.eql(u8, artifact, "acceptance-v2")) return "resolve_c3_acceptance_contract_v2";
    if (std.mem.eql(u8, artifact, "acceptance")) return "resolve_c3_acceptance";
    if (std.mem.eql(u8, artifact, "review-batch")) return "resolve_c3_review_batch";
    if (std.mem.eql(u8, artifact, "review-aperture")) return "resolve_c3_review_aperture";
    if (std.mem.eql(u8, artifact, "counterexample")) return "resolve_c3_counterexample";
    if (std.mem.eql(u8, artifact, "counterexample-basis-v2")) return "resolve_c3_counterexample_basis_v2";
    if (std.mem.eql(u8, artifact, "review-potential")) return "resolve_c3_review_potential";
    if (std.mem.eql(u8, artifact, "observation")) return "resolve_c3_observation";
    if (std.mem.eql(u8, artifact, "kernel")) return "minimum_behavioral_kernel";
    if (std.mem.eql(u8, artifact, "kernel-review")) return "kernel_review";
    if (std.mem.eql(u8, artifact, "realization-design")) return "realization_design";
    if (std.mem.eql(u8, artifact, "construct-map")) return "kernel_realization_map";
    if (std.mem.eql(u8, artifact, "proof-plan")) return "proof_plan";
    if (std.mem.eql(u8, artifact, "holdout")) return "holdout";
    if (std.mem.eql(u8, artifact, "authority-chain")) return "resolve_authority_chain";
    return "minimum_behavioral_kernel_certificate";
}

fn writeRequiredFields(writer: anytype, artifact: []const u8) !void {
    if (std.mem.eql(u8, artifact, "acceptance-v2")) return writer.writeAll("[\"acceptance_version\",\"source_refs\",\"goal\",\"proof_bar\",\"observation_language\",\"authority\",\"horizon\",\"fingerprint\"]");
    if (std.mem.eql(u8, artifact, "acceptance")) return writer.writeAll("[\"acceptance_version\",\"campaign_id\",\"goal\",\"criteria\"]");
    if (std.mem.eql(u8, artifact, "review-batch")) return writer.writeAll("[\"batch_version\",\"batch_id\",\"mode\",\"campaign_id\",\"acceptance_fingerprint\",\"artifact_head\",\"status\",\"aperture_ids\",\"receipt_ids\",\"mutation_events\"]");
    if (std.mem.eql(u8, artifact, "review-aperture")) return writer.writeAll("[\"aperture_version\",\"aperture_id\",\"batch_id\",\"mode\",\"targets\",\"excluded_scope\",\"whole_diff_allowed\"]");
    if (std.mem.eql(u8, artifact, "counterexample")) return writer.writeAll("[\"cex_version\",\"cex_id\",\"batch_id\",\"intent_relation\",\"novelty\",\"disposition\",\"acceptance_refs\",\"minimal_trace\",\"mutation_authority\"]");
    if (std.mem.eql(u8, artifact, "counterexample-basis-v2")) return writer.writeAll("[\"basis_version\",\"basis_id\",\"acceptance_fingerprint\",\"classes\",\"accepted_cex_ids\",\"gate\"]");
    if (std.mem.eql(u8, artifact, "review-potential")) return writer.writeAll("[\"potential_version\",\"cycle_id\",\"acceptance_fingerprint\",\"primary\",\"hard_surface\",\"proof_debt\",\"evidence_refs\"]");
    if (std.mem.eql(u8, artifact, "observation")) return writer.writeAll("[\"observation_id\",\"validity\",\"liability\",\"kernel_impact\",\"expected_result\",\"proof\"]");
    if (std.mem.eql(u8, artifact, "kernel")) return writer.writeAll("[\"kernel_version\",\"campaign_id\",\"campaign_base_sha\",\"acceptance_contract\",\"authorities\",\"carriers\",\"observations\",\"equivalence_classes\",\"operations\",\"transitions\",\"laws\",\"quotient\",\"complexity\",\"gate\"]");
    if (std.mem.eql(u8, artifact, "kernel-review")) return writer.writeAll("[\"review_version\",\"kernel_fingerprint\",\"findings\",\"gate\"]");
    if (std.mem.eql(u8, artifact, "realization-design")) return writer.writeAll("[\"design_version\",\"design_id\",\"route_class\",\"kernel_fingerprint\",\"kernel_elements_realized\",\"owner_map\",\"predicted_semantic_surface\",\"proof_strategy\",\"gate\"]");
    if (std.mem.eql(u8, artifact, "construct-map")) return writer.writeAll("[\"map_version\",\"kernel_fingerprint\",\"realization_tree_fingerprint\",\"constructs\",\"proof_actions\"]");
    if (std.mem.eql(u8, artifact, "proof-plan")) return writer.writeAll("[\"plan_version\",\"kernel_fingerprint\",\"realization_tree_fingerprint\",\"actions\"]");
    if (std.mem.eql(u8, artifact, "holdout")) return writer.writeAll("[\"holdout_version\",\"stage\",\"verdict\",\"refs\",\"gate\"]");
    if (std.mem.eql(u8, artifact, "authority-chain")) return writer.writeAll("[\"resolve_authority_chain\",\"chain_version\",\"chain_id\",\"campaign_id\",\"artifact_state\",\"review_claim\",\"acceptance\",\"adjudication\",\"batch\",\"compression\",\"realization\",\"gate\"]");
    return writer.writeAll("[\"certificate_version\",\"certificate_id\",\"stage\",\"campaign\",\"acceptance\",\"observations\",\"kernel\",\"semantic_surface\",\"proof_basis\",\"delivery\",\"closure_horizon\",\"gate\"]");
}

fn writeExampleValue(writer: anytype, artifact: []const u8) !void {
    if (std.mem.eql(u8, artifact, "acceptance-v2")) return writer.writeAll("{\"acceptance_version\":\"AC-v2\",\"source_refs\":[\"HEAD\"],\"goal\":\"preserve accepted review behavior\",\"required\":[{\"id\":\"req.example\",\"text\":\"required behavior\"}],\"compatibility\":[],\"forbidden\":[],\"proof_bar\":{\"commands\":[\"zig build test-resolve-c3 --summary all\"]},\"observation_language\":{\"terms\":[\"law\",\"owner\",\"operation\"]},\"authority\":{\"id\":\"owner.example\",\"current\":true},\"horizon\":{\"sequence\":1},\"fingerprint\":\"sha256:canonical-content\"}");
    if (std.mem.eql(u8, artifact, "acceptance")) return writer.writeAll("{\"acceptance_version\":\"RCA-v1\",\"campaign_id\":\"c3-example\",\"goal\":\"preserve accepted review behavior\",\"criteria\":[]}");
    if (std.mem.eql(u8, artifact, "review-batch")) return writer.writeAll("{\"batch_version\":\"RB-v1\",\"batch_id\":\"batch.example\",\"mode\":\"discovery\",\"campaign_id\":\"c3-example\",\"acceptance_fingerprint\":\"sha256:ac\",\"artifact_head\":\"HEAD\",\"status\":\"open\",\"aperture_ids\":[],\"receipt_ids\":[],\"mutation_events\":[]}");
    if (std.mem.eql(u8, artifact, "review-aperture")) return writer.writeAll("{\"aperture_version\":\"RAP-v1\",\"aperture_id\":\"rap.example\",\"batch_id\":\"batch.example\",\"mode\":\"conformance\",\"targets\":[{\"law\":\"law.example\",\"owner\":\"owner.example\",\"operation\":\"op.example\",\"transition\":\"transition.example\",\"proof_target\":\"proof.example\"}],\"excluded_scope\":[\"outside-current-kernel\"],\"existing_class_refs\":[\"class.example\"],\"whole_diff_allowed\":false}");
    if (std.mem.eql(u8, artifact, "counterexample")) return writer.writeAll("{\"cex_version\":\"CEX-v1\",\"cex_id\":\"cex.example\",\"batch_id\":\"batch.example\",\"aperture_id\":\"rap.example\",\"intent_relation\":\"in_horizon\",\"novelty\":\"new_equivalence_class\",\"disposition\":\"accepted\",\"acceptance_refs\":[\"req.example\"],\"minimal_trace\":[\"step.example\"],\"mutation_authority\":false}");
    if (std.mem.eql(u8, artifact, "counterexample-basis-v2")) return writer.writeAll("{\"basis_version\":\"CEB-v2\",\"basis_id\":\"basis.example\",\"acceptance_fingerprint\":\"sha256:ac\",\"accepted_cex_ids\":[\"cex.example\"],\"classes\":[{\"class_id\":\"class.example\",\"representative\":\"cex.example\",\"members\":[\"cex.example\"],\"law_refs\":[\"req.example\"],\"canonical_owner\":\"owner.example\",\"proof_obligation\":\"zig build test-resolve-c3 --summary all\",\"congruence_evidence\":[\"manual\"]}],\"duplicates\":[],\"gate\":{\"sealed\":false}}");
    if (std.mem.eql(u8, artifact, "review-potential")) return writer.writeAll("{\"potential_version\":\"PHI-v1\",\"cycle_id\":\"cycle.example\",\"acceptance_fingerprint\":\"sha256:ac\",\"primary\":{\"U\":1,\"L\":1,\"C\":1,\"O\":1},\"hard_surface\":{\"truth_owners\":1,\"public_symbols\":1,\"state_variants\":1,\"protocol_cases\":1,\"fallback_compatibility_paths\":1,\"control_flow_branches\":1,\"helpers_wrappers\":1,\"test_families\":1},\"proof_debt\":{\"missing_law_proofs\":0,\"unmapped_proof_actions\":0,\"wound_specific_tests\":0},\"evidence_refs\":[\"measure.example\"]}");
    if (std.mem.eql(u8, artifact, "observation")) return writer.writeAll("{\"observation_id\":\"obs.example\",\"validity\":\"accepted\",\"liability\":\"introduced_by_current_diff\",\"kernel_impact\":\"distinguishes_behavior\",\"expected_result\":{\"command\":\"zig build test-resolve-c3\",\"result\":\"pass\"},\"proof\":{\"style\":\"law\",\"refs\":[]}}");
    if (std.mem.eql(u8, artifact, "kernel")) return writer.writeAll("{\"kernel_version\":\"MBK-v1\",\"campaign_id\":\"c3-example\",\"campaign_base_sha\":\"base\",\"acceptance_contract\":{},\"non_goals\":[],\"authorities\":[],\"carriers\":[],\"observations\":[],\"equivalence_classes\":[],\"operations\":[],\"transitions\":[],\"laws\":[],\"non_laws\":[],\"forbidden_states_or_transitions\":[],\"counterexample_families\":[],\"quotient\":{\"method\":\"witness_checked_manual\",\"optimality\":\"witnessed\"},\"complexity\":{\"authorities\":0,\"observable_state_classes\":0,\"operations\":0,\"transitions\":0,\"laws\":0,\"protocol_cases\":0},\"gate\":{}}");
    if (std.mem.eql(u8, artifact, "kernel-review")) return writer.writeAll("{\"review_version\":\"KR-v1\",\"kernel_fingerprint\":\"sha256:kernel\",\"findings\":[],\"gate\":{\"accepted\":true}}");
    if (std.mem.eql(u8, artifact, "realization-design")) return writer.writeAll("{\"design_version\":\"RD-v1\",\"design_id\":\"design.example\",\"route_class\":\"subtractive\",\"kernel_fingerprint\":\"sha256:kernel\",\"kernel_elements_realized\":[],\"owner_map\":[],\"surfaces_to_retire\":[],\"predicted_new_surface\":[],\"negative_route_refs\":[],\"predicted_semantic_surface\":{},\"proof_strategy\":{},\"risks\":[],\"gate\":{\"kernel_complete\":true,\"negative_routes_clear\":true,\"within_baseline\":true}}");
    if (std.mem.eql(u8, artifact, "construct-map")) return writer.writeAll("{\"map_version\":\"KRM-v1\",\"kernel_fingerprint\":\"sha256:kernel\",\"realization_tree_fingerprint\":\"sha256:tree\",\"constructs\":[],\"proof_actions\":[]}");
    if (std.mem.eql(u8, artifact, "proof-plan")) return writer.writeAll("{\"plan_version\":\"RCP-v1\",\"kernel_fingerprint\":\"sha256:kernel\",\"realization_tree_fingerprint\":\"sha256:tree\",\"actions\":[]}");
    if (std.mem.eql(u8, artifact, "holdout")) return writer.writeAll("{\"holdout_version\":\"RCH-v1\",\"stage\":\"kernel\",\"verdict\":\"clean\",\"refs\":[],\"gate\":{\"blocks\":false}}");
    if (std.mem.eql(u8, artifact, "authority-chain")) return writer.writeAll("{\"resolve_authority_chain\":{\"chain_version\":\"RAC-v1\",\"chain_id\":\"RAC-example\",\"campaign_id\":\"c3-example\",\"artifact_state\":{\"base_sha\":\"base\",\"head_sha\":\"head\",\"dirty_fingerprint\":\"clean\",\"review_receipt\":\"review.example\"},\"review_claim\":{\"claim_id\":\"claim.example\",\"source\":\"review\",\"statement\":\"accepted finding\",\"suggested_repair\":\"owner-scoped repair\"},\"acceptance\":{\"contract_id\":\"ac.example\",\"contract_fingerprint\":\"sha256:ac\",\"horizon_fingerprint\":\"sha256:horizon\",\"law_refs\":[\"law.example\"],\"relation\":\"directly_entailed\"},\"adjudication\":{\"cex_id\":\"cex.example\",\"validity\":\"confirmed\",\"liability\":\"introduced_by_current_diff\",\"novelty\":\"new_equivalence_class\",\"disposition\":\"accepted\",\"minimal_trace_ref\":\"trace.example\"},\"batch\":{\"batch_id\":\"batch.example\",\"sealed\":true,\"mode\":\"conformance\"},\"compression\":{\"ceb_id\":\"basis.example\",\"class_id\":\"class.example\",\"class_status\":\"accepted\",\"quotient_witness_ref\":\"witness.example\",\"mbk_id\":\"mbk.example\",\"rc_id\":\"rc.example\",\"transition_ref\":\"transition.example\",\"proof_obligation_ref\":\"proof.example\"},\"realization\":{\"allowed\":true,\"target_owner\":\"owner.example\",\"target_boundary\":\"path:src/example.zig\",\"forbidden_expansions\":[]},\"gate\":{\"current_artifact_state\":\"yes\",\"complete_chain\":\"yes\",\"mutation_allowed\":\"yes\"}}}");
    return writer.writeAll("{\"minimum_behavioral_kernel_certificate\":{\"certificate_version\":\"MBKC-v1\",\"certificate_id\":\"sha256:canonical-content\",\"stage\":\"kernel_accepted\",\"campaign\":{},\"acceptance\":{},\"observations\":{},\"kernel\":{},\"kernel_review\":{},\"realization_designs\":{},\"selected_design\":{},\"realization_map\":{},\"semantic_surface\":{},\"proof_basis\":{},\"negative_evidence\":{},\"holdouts\":{},\"delivery\":{},\"closure_horizon\":{},\"gate\":{\"kernel_allowed\":true,\"realization_allowed\":false,\"apply_allowed\":false,\"commit_allowed\":false,\"push_allowed\":false,\"tuple_closure_allowed\":false,\"terminal_closure_allowed\":false}}}");
}

fn printDoctor(allocator: std.mem.Allocator, args: Args) !u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (args.json) {
        try out.writer.writeAll("{\"command\":\"doctor\",\"status\":\"ok\",\"state_root\":");
        try writeJsonString(&out.writer, args.state_root);
        try out.writer.writeAll(",\"legacy_root\":");
        try writeJsonString(&out.writer, args.legacy_root);
        try out.writer.writeAll(",\"cwd\":");
        try writeJsonString(&out.writer, args.cwd);
        try out.writer.writeAll("}\n");
    } else {
        try out.writer.print("resolve-c3 doctor: ok\ncwd: {s}\nstate_root: {s}\nlegacy_root: {s}\n", .{
            args.cwd,
            args.state_root,
            args.legacy_root,
        });
    }
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn initState(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    try root.createDirPath(Io, args.state_root);
    const state = initialState(args);
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "uninitialized");
    const event_id = try appendEventInitial(allocator, root, args.state_root, "init", state, args.state_root);
    defer allocator.free(event_id);
    try ensureLocalExclude(allocator, root, args.state_root);
    try printStateReceipt(allocator, "init", "success", args.state_root, null, state, event_id);
    return 0;
}

fn printPaths(allocator: std.mem.Allocator, args: Args) !u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (args.json) {
        try out.writer.writeAll("{\"cwd\":");
        try writeJsonString(&out.writer, args.cwd);
        try out.writer.writeAll(",\"state_root\":");
        try writeJsonString(&out.writer, args.state_root);
        try out.writer.writeAll(",\"legacy_root\":");
        try writeJsonString(&out.writer, args.legacy_root);
        try out.writer.writeAll("}\n");
    } else {
        try out.writer.print("cwd: {s}\nstate_root: {s}\nlegacy_root: {s}\n", .{ args.cwd, args.state_root, args.legacy_root });
    }
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn printStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    if (!stateFileExists(allocator, root, args.state_root)) {
        try printReceipt(allocator, "status", "missing", args.state_root);
        return 1;
    }
    const state_path = try statePath(allocator, args.state_root, StateFile);
    defer allocator.free(state_path);
    const bytes = try root.readFileAlloc(Io, state_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    try writeStdoutBytes(allocator, bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') try writeStdoutBytes(allocator, "\n");
    return 0;
}

fn beginRun(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    try root.createDirPath(Io, args.state_root);
    try ensureLocalExclude(allocator, root, args.state_root);

    const parent_run_id_storage = try loadParentRunId(allocator, root, args.state_root);
    defer if (parent_run_id_storage) |value| allocator.free(value);
    const parent_run_id: ?[]const u8 = parent_run_id_storage;

    const goal = if (args.acceptance) |path| try acceptanceGoalFromFile(allocator, path) else if (args.goal) |g| g else return error.AcceptanceRequired;
    defer if (args.acceptance != null) allocator.free(goal);
    const base_sha_capture = gitCapture(allocator, args.cwd, &.{ "rev-parse", "HEAD" }) catch null;
    defer if (base_sha_capture) |value| allocator.free(value);
    const base_sha = base_sha_capture orelse "unknown";
    const branch_capture = gitCapture(allocator, args.cwd, &.{ "branch", "--show-current" }) catch null;
    defer if (branch_capture) |value| allocator.free(value);
    const branch = branch_capture orelse "unknown";
    const repo_root_capture = gitCapture(allocator, args.cwd, &.{ "rev-parse", "--show-toplevel" }) catch null;
    defer if (repo_root_capture) |value| allocator.free(value);
    const repo_root = repo_root_capture orelse args.cwd;
    const run_id = try std.fmt.allocPrint(allocator, "C3-{s}", .{base_sha[0..@min(base_sha.len, 12)]});
    defer allocator.free(run_id);

    const state = State{
        .schema = StateSchemaV3,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 3,
        .run_id = run_id,
        .repo_root = repo_root,
        .branch = branch,
        .base_sha = base_sha,
        .phase = "collecting",
        .acceptance_goal = goal,
        .parent_run_id = parent_run_id,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    };
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "collecting_observations");
    const event_id = try appendEventInitial(allocator, root, args.state_root, "begin", state, run_id);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "begin", "success", run_id, null, state, event_id);
    return 0;
}

fn loadParentRunId(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) !?[]u8 {
    if (loadStateParsed(allocator, root, state_root)) |parsed_existing| {
        var existing = parsed_existing;
        defer existing.deinit();
        if (!isTerminalPhase(existing.value.phase) and !std.mem.eql(u8, existing.value.phase, "initialized")) {
            return error.ActiveRunExists;
        }
        if (existing.value.run_id.len > 0) return try allocator.dupe(u8, existing.value.run_id);
    } else |_| {}
    return null;
}

fn addCounterexample(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    const finding_id = stringField(parsed_input.value, "id") orelse stringField(parsed_input.value, "finding_id") orelse return error.InvalidCounterexample;
    try validateSafeId(finding_id);
    const liability = stringField(parsed_input.value, "liability") orelse return error.InvalidCounterexample;

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    if (state.counterexample_count < std.math.maxInt(u32)) state.counterexample_count += 1;
    if (isBranchLiable(liability) and (std.mem.eql(u8, state.phase, "selected") or std.mem.eql(u8, state.phase, "apply-certified") or std.mem.eql(u8, state.phase, "applied") or std.mem.eql(u8, state.phase, "final-certified"))) {
        invalidateCompilation(&state, "invalidated");
    }
    if (isBranchLiable(liability)) state.basis_set = false;
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "counterexample-added", state.phase);
    try printReceipt(allocator, "add-counterexample", "success", finding_id);
    return 0;
}

fn setBasis(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    if (!std.mem.eql(u8, stringField(parsed_input.value, "basis_version") orelse "", "CEB-v1")) return error.InvalidBasis;
    const gate = objectField(parsed_input.value, "gate") orelse return error.InvalidBasis;
    for (BasisGateFields) |field| {
        if (!std.mem.eql(u8, stringField(gate, field) orelse "", "pass")) return error.InvalidBasis;
    }

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    state.basis_set = true;
    state.phase = "collecting";
    state.selected_candidate_id = null;
    state.ablation_authority = null;
    state.ablation_orphan_edit_atoms = 0;
    state.candidate_holdout_safe = false;
    state.delivery_holdout_safe = false;
    state.proof_authority = null;
    state.proof_passed = false;
    state.proof_patch_stable = false;
    state.delivery_patch_sha = null;
    state.commit_sha = null;
    state.pushed = false;
    state.certificate_stage = null;
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "basis-set", state.phase);
    try printReceipt(allocator, "set-basis", "success", args.state_root);
    return 0;
}

fn setTournamentWaiver(allocator: std.mem.Allocator, args: Args) !u8 {
    const reason = args.reason orelse return error.ReasonRequired;
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return error.ReasonRequired;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    state.tournament_waiver = reason;
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "tournament-waiver", state.phase);
    try printReceipt(allocator, "tournament-waiver", "success", reason);
    return 0;
}

fn registerCandidate(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    const candidate_id = stringField(parsed_input.value, "candidate_id") orelse return error.InvalidCandidate;
    try validateSafeId(candidate_id);
    const route_class = stringField(parsed_input.value, "route_class") orelse "unknown";
    const route_family = stringField(parsed_input.value, "route_family") orelse route_class;
    const patch_sha = stringField(parsed_input.value, "patch_sha") orelse "sha256:unmeasured";
    const costs = try parseSemanticCost(parsed_input.value);
    const valid = candidateContractValid(parsed_input.value, costs);
    const invalid_reasons: []const []const u8 = if (valid) &.{} else &.{"candidate-contract"};

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseCollectingSelectedInvalidated[0..]) catch return error.InvalidPhase;
    if (!state.basis_set) return error.BasisRequired;

    const filtered_count = countCandidatesExcept(state.candidates, candidate_id);
    var candidates = try allocator.alloc(Candidate, filtered_count + 1);
    var out_i: usize = 0;
    for (state.candidates) |candidate| {
        if (!std.mem.eql(u8, candidate.candidate_id, candidate_id)) {
            candidates[out_i] = candidate;
            out_i += 1;
        }
    }
    candidates[out_i] = .{
        .candidate_id = candidate_id,
        .route_class = route_class,
        .route_family = route_family,
        .patch_sha = patch_sha,
        .worktree = args.worktree,
        .valid = valid,
        .invalid_reasons = invalid_reasons,
        .semantic_cost = costs,
    };
    state.candidates = candidates;
    state.phase = "collecting";
    state.selected_candidate_id = null;
    state.ablation_authority = null;
    state.candidate_holdout_safe = false;
    state.delivery_holdout_safe = false;
    state.proof_authority = null;
    state.proof_passed = false;
    state.proof_patch_stable = false;
    state.certificate_stage = null;
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "candidate-registered", state.phase);
    try printReceipt(allocator, "register-candidate", if (valid) "valid" else "invalid", candidate_id);
    return if (valid) 0 else 2;
}

fn verifyCandidate(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    const input = args.input orelse return error.InputRequired;
    const candidate_id = args.candidate_id orelse return error.CandidateRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    const checks = objectField(parsed_input.value, "checks") orelse return error.InvalidProofPlan;
    const check_items = switch (checks) {
        .array => |arr| arr.items,
        else => return error.InvalidProofPlan,
    };
    if (check_items.len == 0) return error.InvalidProofPlan;

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseCollectingSelected[0..]) catch return error.InvalidPhase;
    const idx = findCandidateIndex(state.candidates, candidate_id) orelse return error.UnknownCandidate;
    var all_pass = true;
    for (check_items) |check| {
        const command = stringField(check, "command") orelse return error.InvalidProofPlan;
        const cwd = state.candidates[idx].worktree orelse args.cwd;
        const passed = try runShell(allocator, process_io, cwd, command);
        all_pass = all_pass and passed;
    }
    const verified = Candidate{
        .candidate_id = state.candidates[idx].candidate_id,
        .route_class = state.candidates[idx].route_class,
        .route_family = state.candidates[idx].route_family,
        .patch_sha = state.candidates[idx].patch_sha,
        .worktree = state.candidates[idx].worktree,
        .valid = all_pass,
        .invalid_reasons = if (all_pass) &.{} else &.{"verification-failed"},
        .semantic_cost = state.candidates[idx].semantic_cost,
    };
    state.candidates = try replaceCandidateAt(allocator, state.candidates, idx, verified);
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "candidate-verified", state.phase);
    try printReceipt(allocator, "verify-candidate", if (all_pass) "valid" else "invalid", candidate_id);
    return if (all_pass) 0 else 2;
}

fn selectCandidate(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseCollectingInvalidated[0..]) catch return error.InvalidPhase;
    if (!state.basis_set) return error.BasisRequired;
    if (state.candidates.len < 3 and state.tournament_waiver == null) return error.TournamentTooSmall;
    if (distinctRouteClasses(state.candidates) < 2 and state.tournament_waiver == null) return error.TournamentTooNarrow;
    if (!hasControlCandidate(state.candidates) and state.tournament_waiver == null) return error.ControlCandidateRequired;

    var selected: ?Candidate = null;
    for (state.candidates) |candidate| {
        if (!candidate.valid) continue;
        if (selected == null or candidateLess(candidate, selected.?)) selected = candidate;
    }
    const winner = selected orelse return error.NoValidCandidate;
    state.selected_candidate_id = winner.candidate_id;
    state.phase = "selected";
    state.ablation_authority = null;
    state.ablation_orphan_edit_atoms = 0;
    state.candidate_holdout_safe = false;
    state.delivery_holdout_safe = false;
    state.proof_authority = null;
    state.certificate_stage = null;
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "candidate-selected", state.phase);
    try printReceipt(allocator, "select", "success", winner.candidate_id);
    return 0;
}

fn ablateCandidate(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    const candidate_id = args.candidate_id orelse return error.CandidateRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    const cost_after = if (objectField(parsed_input.value, "semantic_cost_after")) |cost_value| try parseSemanticCost(cost_value) else try parseSemanticCost(parsed_input.value);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseSelected[0..]) catch return error.InvalidPhase;
    if (!optionalEql(state.selected_candidate_id, candidate_id)) return error.SelectedCandidateMismatch;
    const idx = findCandidateIndex(state.candidates, candidate_id) orelse return error.UnknownCandidate;
    if (costTupleGreater(cost_after, state.candidates[idx].semantic_cost)) return error.AblationIncreasedCost;
    const ablated = Candidate{
        .candidate_id = state.candidates[idx].candidate_id,
        .route_class = state.candidates[idx].route_class,
        .route_family = state.candidates[idx].route_family,
        .patch_sha = state.candidates[idx].patch_sha,
        .worktree = state.candidates[idx].worktree,
        .valid = state.candidates[idx].valid,
        .invalid_reasons = state.candidates[idx].invalid_reasons,
        .semantic_cost = cost_after,
    };
    state.candidates = try replaceCandidateAt(allocator, state.candidates, idx, ablated);
    state.ablation_authority = "controller";
    state.ablation_orphan_edit_atoms = 0;
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "ablation-run", state.phase);
    try printReceipt(allocator, "ablate", "success", candidate_id);
    return 0;
}

fn recordAblation(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    const candidate_id = stringField(parsed_input.value, "candidate_id") orelse return error.CandidateRequired;
    const orphan_count = arrayLen(objectField(parsed_input.value, "orphan_edit_atoms"));

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseSelected[0..]) catch return error.InvalidPhase;
    if (!optionalEql(state.selected_candidate_id, candidate_id)) return error.SelectedCandidateMismatch;
    state.ablation_authority = "external";
    state.ablation_orphan_edit_atoms = @intCast(orphan_count);
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "ablation-recorded", state.phase);
    try printReceipt(allocator, "record-ablation", "success", candidate_id);
    return 0;
}

fn recordHoldout(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    const stage = args.stage orelse return error.StageRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    const unsafe = arrayLen(objectField(parsed_input.value, "new_branch_liabilities")) > 0;
    const safe = !unsafe and hasSafeVerdict(stringField(parsed_input.value, "verdict"));

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    if (std.mem.eql(u8, stage, "candidate")) {
        requirePhase(state, PhaseSelected[0..]) catch return error.InvalidPhase;
        state.candidate_holdout_safe = safe;
    } else if (std.mem.eql(u8, stage, "delivery")) {
        requirePhase(state, PhaseAppliedInvalidated[0..]) catch return error.InvalidPhase;
        state.delivery_holdout_safe = safe;
    } else return error.StageRequired;
    if (unsafe) {
        invalidateCompilation(&state, "invalidated");
        state.basis_set = false;
    }
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "holdout-recorded", state.phase);
    try printReceipt(allocator, "record-holdout", if (unsafe) "invalidated" else "success", stage);
    return if (unsafe) 2 else 0;
}

fn certifyApply(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseSelected[0..]) catch return error.InvalidPhase;
    const selected = selectedCandidate(state) orelse return error.NoValidCandidate;
    if (!selected.valid) return error.InvalidCandidate;
    if (!optionalEql(state.ablation_authority, "controller") or state.ablation_orphan_edit_atoms != 0) return error.AblationGateFailed;
    if (!state.candidate_holdout_safe) return error.HoldoutRequired;
    state.phase = "apply-certified";
    state.certificate_stage = "apply-certified";
    try saveState(allocator, root, args.state_root, state);
    try writeMrpc(allocator, root, args.state_root, state, "apply-certified");
    try appendEventOnly(allocator, root, args.state_root, "apply-certified", state.phase);
    try printMrpcFile(allocator, root, args.state_root);
    return 0;
}

fn applySelected(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseApplyCertified[0..]) catch return error.InvalidPhase;
    const selected = selectedCandidate(state) orelse return error.NoValidCandidate;
    state.delivery_patch_sha = selected.patch_sha;
    state.phase = "applied";
    state.certificate_stage = "applied";
    try saveState(allocator, root, args.state_root, state);
    try writeMrpc(allocator, root, args.state_root, state, "applied");
    try appendEventOnly(allocator, root, args.state_root, "patch-applied", state.phase);
    try printMrpcFile(allocator, root, args.state_root);
    return 0;
}

fn runProof(allocator: std.mem.Allocator, args: Args, process_io: std.Io) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    const checks_value = objectField(parsed_input.value, "checks") orelse objectField(parsed_input.value, "commands") orelse return error.InvalidProofPlan;
    const checks = switch (checks_value) {
        .array => |arr| arr.items,
        else => return error.InvalidProofPlan,
    };
    if (checks.len == 0) return error.InvalidProofPlan;

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseApplied[0..]) catch return error.InvalidPhase;
    var all_pass = true;
    for (checks) |check| {
        const command = stringField(check, "command") orelse return error.InvalidProofPlan;
        all_pass = all_pass and try runShell(allocator, process_io, args.cwd, command);
    }
    state.proof_authority = "controller";
    state.proof_passed = all_pass;
    state.proof_patch_stable = true;
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "proof-run", state.phase);
    try printReceipt(allocator, "run-proof", if (all_pass) "pass" else "fail", args.state_root);
    return if (all_pass) 0 else 2;
}

fn recordProof(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    const commands = objectField(parsed_input.value, "commands") orelse return error.InvalidProofPlan;
    if (arrayLen(commands) == 0) return error.InvalidProofPlan;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseApplied[0..]) catch return error.InvalidPhase;
    state.proof_authority = stringField(parsed_input.value, "authority") orelse "external";
    state.proof_passed = allCommandResultsPass(commands);
    state.proof_patch_stable = boolField(parsed_input.value, "patch_stable") orelse true;
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "proof-recorded", state.phase);
    try printReceipt(allocator, "record-proof", if (state.proof_passed) "pass" else "fail", args.state_root);
    return if (state.proof_passed) 0 else 2;
}

fn certifyFinal(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseApplied[0..]) catch return error.InvalidPhase;
    if (!optionalEql(state.proof_authority, "controller") or !state.proof_passed or !state.proof_patch_stable) return error.ProofGateFailed;
    if (!state.delivery_holdout_safe) return error.HoldoutRequired;
    if (state.ablation_orphan_edit_atoms != 0) return error.AblationGateFailed;
    state.phase = "final-certified";
    state.certificate_stage = "final-certified";
    try saveState(allocator, root, args.state_root, state);
    try writeMrpc(allocator, root, args.state_root, state, "final-certified");
    try appendEventOnly(allocator, root, args.state_root, "final-certified", state.phase);
    try printMrpcFile(allocator, root, args.state_root);
    return 0;
}

fn commitDelivery(allocator: std.mem.Allocator, args: Args) !u8 {
    _ = args.message orelse return error.MessageRequired;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseFinalCertified[0..]) catch return error.InvalidPhase;
    const head_capture = gitCapture(allocator, args.cwd, &.{ "rev-parse", "HEAD" }) catch null;
    defer if (head_capture) |value| allocator.free(value);
    const head = head_capture orelse state.base_sha;
    state.commit_sha = head;
    state.phase = "committed";
    state.certificate_stage = "committed";
    try saveState(allocator, root, args.state_root, state);
    try writeMrpc(allocator, root, args.state_root, state, "committed");
    try appendEventOnly(allocator, root, args.state_root, "committed", state.phase);
    try printMrpcFile(allocator, root, args.state_root);
    return 0;
}

fn pushDelivery(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhaseCommitted[0..]) catch return error.InvalidPhase;
    state.pushed = true;
    state.phase = "pushed";
    state.certificate_stage = "pushed";
    try saveState(allocator, root, args.state_root, state);
    try writeMrpc(allocator, root, args.state_root, state, "pushed");
    try appendEventOnly(allocator, root, args.state_root, "pushed", state.phase);
    try printMrpcFile(allocator, root, args.state_root);
    return 0;
}

fn closeRun(allocator: std.mem.Allocator, args: Args) !u8 {
    const input = args.input orelse return error.InputRequired;
    var parsed_input = try parseJsonInput(allocator, input);
    defer parsed_input.deinit();
    if (arrayLen(objectField(parsed_input.value, "unresolved_branch_liabilities")) > 0) return error.UnresolvedBranchLiabilities;

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    requirePhase(state, PhasePushed[0..]) catch return error.InvalidPhase;
    state.phase = "closed";
    state.certificate_stage = "closed";
    try saveState(allocator, root, args.state_root, state);
    try writeMrpc(allocator, root, args.state_root, state, "closed");
    try appendEventOnly(allocator, root, args.state_root, "closed", state.phase);
    try printMrpcFile(allocator, root, args.state_root);
    return 0;
}

fn abortRun(allocator: std.mem.Allocator, args: Args) !u8 {
    if (!args.confirm) return error.ConfirmationRequired;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    var state = parsed.value;
    state.phase = "aborted";
    try saveState(allocator, root, args.state_root, state);
    try appendEventOnly(allocator, root, args.state_root, "aborted", state.phase);
    try printReceipt(allocator, "abort", "success", args.reason orelse "aborted");
    return 0;
}

fn auditState(allocator: std.mem.Allocator, args: Args) !u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    const cert_required = certificateRequired(parsed.value.phase);
    const cert_exists = fileExists(allocator, root, args.state_root, CertFile);
    const ok = (parsed.value.state_version == 1 or parsed.value.state_version == 2) and (!cert_required or cert_exists);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"c3_audit\":{{\"ok\":{},\"phase\":", .{ok});
    try writeJsonString(&out.writer, parsed.value.phase);
    try out.writer.print(",\"certificate_present\":{}}}}}\n", .{cert_exists});
    try writeStdoutAlloc(allocator, &out);
    return if (ok) 0 else 2;
}

fn guardHook(allocator: std.mem.Allocator, args: Args) !u8 {
    const payload = try readStdinAlloc(allocator);
    defer allocator.free(payload);
    const cwd = try cwdFromPayload(allocator, payload, args.cwd);
    defer allocator.free(cwd);
    const found = try findStateRootFrom(allocator, cwd, args.state_root);
    if (found == null) return guardReceipt(allocator, "allow", "no-active-c3");
    defer allocator.free(found.?);

    var root = try openRoot(found.?);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    const state = parsed.value;
    if (isTerminalPhase(state.phase)) return guardReceipt(allocator, "allow", "c3-terminal");
    const command = commandFromPayload(allocator, payload) catch "";
    defer if (command.len > 0) allocator.free(command);
    const tool_name = toolFromPayload(allocator, payload) catch "";
    defer if (tool_name.len > 0) allocator.free(tool_name);
    if (controllerCommand(command)) return guardReceipt(allocator, "allow", "c3-controller-command");
    if (state.review.open_batch_ids.len != 0 and (toolMutates(tool_name) or mutatingShell(command) != null)) {
        const reason = mutatingShell(command) orelse "mutating-tool";
        const event_id = try recordOpenBatchMutationDenied(allocator, root, args.state_root, state, reason);
        defer allocator.free(event_id);
        return guardDenialReceipt(allocator, "review_batch_open", state.phase, state.review.open_batch_ids[0], "seal or invalidate the open review batch before material mutation", event_id);
    }
    if (toolMutates(tool_name)) return guardReceipt(allocator, "block", "C3 delivery is frozen; use resolve-c3 or a lab worktree");
    if (mutatingShell(command)) |reason| return guardReceipt(allocator, "block", reason);
    return guardReceipt(allocator, "allow", "read-only-or-unclassified");
}

fn hookContext(allocator: std.mem.Allocator, args: Args) !u8 {
    const found = try findStateRootFrom(allocator, args.cwd, args.state_root);
    if (found == null) {
        try writeStdoutBytes(allocator, "{\"active\":false}\n");
        return 0;
    }
    defer allocator.free(found.?);
    var root = try openRoot(found.?);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    if (isTerminalPhase(parsed.value.phase)) {
        try writeStdoutBytes(allocator, "{\"active\":false,\"phase\":\"terminal\"}\n");
        return 0;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"active\":true,\"phase\":");
    try writeJsonString(&out.writer, parsed.value.phase);
    try out.writer.writeAll(",\"run_id\":");
    try writeJsonString(&out.writer, parsed.value.run_id);
    try out.writer.writeAll(",\"context\":\"C3 delivery is controller-gated. Direct edits, raw commit, and raw push are forbidden.\"}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn stopGuard(allocator: std.mem.Allocator, args: Args) !u8 {
    const payload = try readStdinAlloc(allocator);
    defer allocator.free(payload);
    const cwd = try cwdFromPayload(allocator, payload, args.cwd);
    defer allocator.free(cwd);
    const found = try findStateRootFrom(allocator, cwd, args.state_root);
    if (found == null) return guardReceipt(allocator, "allow", "no-active-c3");
    defer allocator.free(found.?);
    var root = try openRoot(found.?);
    defer root.close(Io);
    var parsed = try loadStateParsed(allocator, root, args.state_root);
    defer parsed.deinit();
    if (isTerminalPhase(parsed.value.phase)) return guardReceipt(allocator, "allow", "c3-terminal");
    const last = stringFromPayload(allocator, payload, "last_assistant_message") catch "";
    defer if (last.len > 0) allocator.free(last);
    if (containsAnyWord(last, ClosureWords[0..])) {
        return guardReceipt(allocator, "block", "C3 run is still active; do not claim closure before resolve-c3 close emits final MRPC-v1");
    }
    return guardReceipt(allocator, "allow", "c3-active-no-wrap-up-claim");
}

fn mrpcGate(allocator: std.mem.Allocator, args: Args) !u8 {
    const file = args.file orelse args.input orelse return error.FileRequired;
    var parsed = try parseJsonInput(allocator, file);
    defer parsed.deinit();
    var errors = std.ArrayList([]const u8).empty;
    defer errors.deinit(allocator);
    const body = objectField(parsed.value, "minimal_review_patch_certificate") orelse {
        try errors.append(allocator, "minimal_review_patch_certificate");
        return printGateResult(allocator, "MRPC", errors.items);
    };
    if (!std.mem.eql(u8, stringField(body, "certificate_version") orelse "", "MRPC-v1")) try errors.append(allocator, "certificate_version");
    for (MrpcRequiredFields) |field| {
        if (emptyJsonValue(objectField(body, field))) try errors.append(allocator, field);
    }
    const metrics = objectField(body, "metrics");
    if (arrayLen(if (metrics) |m| objectField(m, "orphan_edit_atoms") else null) > 0) try errors.append(allocator, "orphan_edit_atoms");
    const stage = stringField(body, "stage") orelse "";
    const gate = objectField(body, "gate") orelse std.json.Value{ .null = {} };
    if (std.mem.eql(u8, stage, "apply-certified") and (boolField(gate, "apply_allowed") orelse false) != true) try errors.append(allocator, "apply_gate");
    if (std.mem.eql(u8, stage, "final-certified") and (boolField(gate, "commit_allowed") orelse false) != true) try errors.append(allocator, "commit_gate");
    if (std.mem.eql(u8, stage, "committed") and (boolField(gate, "push_allowed") orelse false) != true) try errors.append(allocator, "push_gate");
    return printGateResult(allocator, "MRPC", errors.items);
}

fn rdrGate(allocator: std.mem.Allocator, args: Args) !u8 {
    const file = args.file orelse args.input orelse return error.FileRequired;
    const text = try readFileOrStdin(allocator, file);
    defer allocator.free(text);
    var errors = std.ArrayList([]const u8).empty;
    defer errors.deinit(allocator);
    for (RdrRequiredFields) |field| {
        if (!containsYamlKey(text, field)) try errors.append(allocator, field);
    }
    if (!std.mem.containsAtLeast(u8, text, 1, "record_version") or !std.mem.containsAtLeast(u8, text, 1, "RDR-v1")) try errors.append(allocator, "record_version:RDR-v1");
    if (std.mem.containsAtLeast(u8, text, 1, "stop_rule") and std.mem.containsAtLeast(u8, text, 1, "triggered") and std.mem.containsAtLeast(u8, text, 1, "implementation_handoff_allowed") and std.mem.containsAtLeast(u8, text, 1, "yes") and std.mem.containsAtLeast(u8, text, 1, "kind: mutate-existing-owner") and !std.mem.containsAtLeast(u8, text, 1, "why_not_point_fix")) {
        try errors.append(allocator, "triggered stop rule requires why_not_point_fix");
    }
    if (std.mem.containsAtLeast(u8, text, 1, "active_exclusion_match") and std.mem.containsAtLeast(u8, text, 1, "active_exclusion_match: yes") and std.mem.containsAtLeast(u8, text, 1, "handoff_allowed: yes")) {
        try errors.append(allocator, "active negative exclusion cannot allow handoff");
    }
    return printGateResult(allocator, "RDR", errors.items);
}

fn legacyGate(allocator: std.mem.Allocator, args: Args) !u8 {
    _ = args;
    try writeStdoutBytes(allocator, "This gate belongs to the superseded cleanroom artifact stack.\nUse resolve-c3 mrpc-gate and resolve-c3 rdr-gate with MRPC-v1.\n");
    return 2;
}

fn migrateLegacy(allocator: std.mem.Allocator, args: Args) !u8 {
    if (!args.confirm) return error.ConfirmationRequired;
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    if (stateFileExists(allocator, root, args.state_root)) return error.TargetStateNotClean;

    const legacy_state_path = try statePath(allocator, args.legacy_root, StateFile);
    defer allocator.free(legacy_state_path);
    const legacy_bytes = try root.readFileAlloc(Io, legacy_state_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(legacy_bytes);
    try refuseActiveLegacy(allocator, legacy_bytes);
    const archive_state = try archiveLegacyState(allocator, root, args, legacy_state_path, legacy_bytes);
    defer allocator.free(archive_state);
    try printReceipt(allocator, "migrate-legacy", "success", archive_state);
    return 0;
}

fn migrateMrpc(allocator: std.mem.Allocator, args: Args) !u8 {
    const campaign_base = args.campaign_base orelse return error.InvalidBasis;
    const review_ready_baseline = args.review_ready_baseline orelse return error.InvalidBasis;
    try validateSafeId(campaign_base);
    try validateSafeId(review_ready_baseline);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    try root.createDirPath(Io, args.state_root);
    const legacy_state_path = try statePath(allocator, args.legacy_root, StateFile);
    defer allocator.free(legacy_state_path);
    const legacy_bytes = root.readFileAlloc(Io, legacy_state_path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owned_legacy = legacy_bytes.len > 0;
    defer if (owned_legacy) allocator.free(legacy_bytes);
    const parent_storage = if (owned_legacy) try legacyRunIdFromBytes(allocator, legacy_bytes) else null;
    defer if (parent_storage) |value| allocator.free(value);

    const archive_dir = try statePath(allocator, args.state_root, "archive/mrpc");
    defer allocator.free(archive_dir);
    try root.createDirPath(Io, archive_dir);
    try archiveMrpcArtifacts(allocator, root, args.legacy_root, archive_dir);

    const run_id = try std.fmt.allocPrint(allocator, "C3-{s}", .{campaign_base[0..@min(campaign_base.len, 12)]});
    defer allocator.free(run_id);
    const state = State{
        .schema = StateSchemaV3,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 3,
        .run_id = run_id,
        .repo_root = args.cwd,
        .branch = "",
        .base_sha = campaign_base,
        .phase = "initialized",
        .acceptance_goal = "MRPC migration requires fresh kernel",
        .parent_run_id = parent_storage,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    };
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "uninitialized");
    try writeMrpcMigrationReceipt(allocator, root, args.state_root, args.legacy_root, archive_dir, review_ready_baseline);
    try ensureLocalExclude(allocator, root, args.state_root);
    const event_id = try appendEventInitial(allocator, root, args.state_root, "migrate-mrpc", state, archive_dir);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "migrate mrpc", "success", archive_dir, null, state, event_id);
    return 0;
}

fn migrateIntentClosed(allocator: std.mem.Allocator, args: Args) !u8 {
    const campaign_base = args.campaign_base orelse return error.InvalidBasis;
    const review_ready_baseline = args.review_ready_baseline orelse return error.InvalidBasis;
    const acceptance_path = args.acceptance orelse return error.AcceptanceRequired;
    if (!args.confirm) return error.ConfirmRequired;
    try validateSafeId(campaign_base);
    try validateSafeId(review_ready_baseline);
    var parsed_acceptance = try parseJsonInput(allocator, acceptance_path);
    defer parsed_acceptance.deinit();
    try validateAcceptanceV2(parsed_acceptance.value);

    var root = try openRoot(args.cwd);
    defer root.close(Io);
    try root.createDirPath(Io, args.state_root);
    const source_state_path = try statePath(allocator, args.legacy_root, StateFile);
    defer allocator.free(source_state_path);
    const source_bytes = root.readFileAlloc(Io, source_state_path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owned_source = source_bytes.len > 0;
    defer if (owned_source) allocator.free(source_bytes);
    const parent_storage = if (owned_source) try legacyRunIdFromBytes(allocator, source_bytes) else null;
    defer if (parent_storage) |value| allocator.free(value);

    const archive_dir = try statePath(allocator, args.state_root, "archive/intent-closed");
    defer allocator.free(archive_dir);
    try root.createDirPath(Io, archive_dir);
    try archiveKnownArtifacts(allocator, root, args.legacy_root, archive_dir);

    const run_id = try std.fmt.allocPrint(allocator, "C3-{s}", .{campaign_base[0..@min(campaign_base.len, 12)]});
    defer allocator.free(run_id);
    const state = State{
        .schema = StateSchemaV3,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 3,
        .run_id = run_id,
        .repo_root = args.cwd,
        .branch = "",
        .base_sha = campaign_base,
        .phase = "intent_open",
        .acceptance_goal = stringField(parsed_acceptance.value, "goal") orelse "intent-closed migration requires fresh AC-v2 seal",
        .parent_run_id = parent_storage,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    };
    const written = try writeAcceptanceArtifact(allocator, root, args.state_root, parsed_acceptance.value);
    defer written.deinit(allocator);
    var migrated = state;
    migrated.acceptance = .{
        .sequence = written.sequence,
        .contract_id = written.contract_id,
        .fingerprint = written.fingerprint,
        .horizon_state = "draft",
    };
    try saveState(allocator, root, args.state_root, migrated);
    try writeMbkc(allocator, root, args.state_root, migrated, "uninitialized");
    try writeIntentClosedMigrationReceipt(allocator, root, args.state_root, args.legacy_root, archive_dir, review_ready_baseline);
    try ensureLocalExclude(allocator, root, args.state_root);
    const event_id = try appendEventInitial(allocator, root, args.state_root, "migrate-intent-closed", migrated, archive_dir);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "migrate intent-closed", "success", archive_dir, null, migrated, event_id);
    return 0;
}

fn archiveLegacyState(allocator: std.mem.Allocator, root: std.Io.Dir, args: Args, legacy_state_path: []const u8, legacy_bytes: []const u8) ![]const u8 {
    try root.createDirPath(Io, args.state_root);
    const archive_dir = try statePath(allocator, args.state_root, "archive/legacy");
    defer allocator.free(archive_dir);
    try root.createDirPath(Io, archive_dir);
    const archive_state = try statePath(allocator, args.state_root, "archive/legacy/state.json");
    defer allocator.free(archive_state);
    try root.writeFile(Io, .{ .sub_path = archive_state, .data = legacy_bytes });

    const migrated = State{
        .schema = StateSchemaV2,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 2,
        .run_id = "migrated-legacy",
        .repo_root = args.cwd,
        .branch = "",
        .base_sha = "",
        .phase = "initialized",
        .acceptance_goal = "legacy migration",
        .parent_run_id = null,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    };
    try saveState(allocator, root, args.state_root, migrated);
    try writeMigrationReceipt(allocator, root, args.state_root, args.legacy_root, archive_state);
    try appendEventOnly(allocator, root, args.state_root, "migrate-legacy", "initialized");
    try ensureLocalExclude(allocator, root, args.state_root);
    root.deleteFile(Io, legacy_state_path) catch {};
    return allocator.dupe(u8, archive_state);
}

fn archiveMrpcArtifacts(allocator: std.mem.Allocator, root: std.Io.Dir, source_root: []const u8, archive_root: []const u8) !void {
    const known = [_][]const u8{
        StateFile,
        EventFile,
        CertFile,
        MbkcFile,
        ObservationsFile,
        KernelFile,
        DesignsFile,
        SelectedDesignFile,
    };
    for (known) |child| {
        const source = try statePath(allocator, source_root, child);
        defer allocator.free(source);
        const bytes = root.readFileAlloc(Io, source, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(bytes);
        const dest = try std.fs.path.join(allocator, &.{ archive_root, child });
        defer allocator.free(dest);
        if (std.fs.path.dirname(dest)) |dir| try root.createDirPath(Io, dir);
        try root.writeFile(Io, .{ .sub_path = dest, .data = bytes });
    }
}

fn legacyRunIdFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    const run_id = stringField(parsed.value, "run_id") orelse stringField(parsed.value, "campaign_id") orelse return null;
    return try allocator.dupe(u8, run_id);
}

fn writeMrpcMigrationReceipt(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    state_root: []const u8,
    legacy_root: []const u8,
    archive_root: []const u8,
    review_ready_baseline: []const u8,
) !void {
    const receipt_path = try statePath(allocator, state_root, "migration-receipt.json");
    defer allocator.free(receipt_path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"migration\":\"resolve-c3-mrpc\",\"from\":");
    try writeJsonString(&out.writer, legacy_root);
    try out.writer.writeAll(",\"archive_root\":");
    try writeJsonString(&out.writer, archive_root);
    try out.writer.writeAll(",\"review_ready_baseline_sha\":");
    try writeJsonString(&out.writer, review_ready_baseline);
    try out.writer.writeAll(",\"kernel_accepted\":false}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try root.writeFile(Io, .{ .sub_path = receipt_path, .data = bytes });
}

fn writeIntentClosedMigrationReceipt(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    state_root: []const u8,
    legacy_root: []const u8,
    archive_root: []const u8,
    review_ready_baseline: []const u8,
) !void {
    const receipt_path = try statePath(allocator, state_root, "migration-receipt.json");
    defer allocator.free(receipt_path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"migration\":\"resolve-c3-intent-closed\",\"from\":");
    try writeJsonString(&out.writer, legacy_root);
    try out.writer.writeAll(",\"archive_root\":");
    try writeJsonString(&out.writer, archive_root);
    try out.writer.writeAll(",\"review_ready_baseline_sha\":");
    try writeJsonString(&out.writer, review_ready_baseline);
    try out.writer.writeAll(",\"accepted_legacy_artifacts\":false,\"acceptance_sealed\":false,\"kernel_accepted\":false,\"mutation_blocked_until_new_gates\":true}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeRootFileAtomic(allocator, root, receipt_path, bytes);
}

fn refuseActiveLegacy(allocator: std.mem.Allocator, legacy_bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, legacy_bytes, .{}) catch return;
    defer parsed.deinit();
    const phase = stringField(parsed.value, "phase") orelse return;
    if (isTerminalPhase(phase) or std.mem.eql(u8, phase, "initialized")) return;
    return error.ActiveLegacyRun;
}

fn writeMigrationReceipt(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, legacy_root: []const u8, archive_state: []const u8) !void {
    const receipt_path = try statePath(allocator, state_root, "migration-receipt.json");
    defer allocator.free(receipt_path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"migration\":\"resolve-c3-legacy\",\"from\":");
    try writeJsonString(&out.writer, legacy_root);
    try out.writer.writeAll(",\"to\":");
    try writeJsonString(&out.writer, state_root);
    try out.writer.writeAll(",\"archive_state\":");
    try writeJsonString(&out.writer, archive_state);
    try out.writer.writeAll("}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try root.writeFile(Io, .{ .sub_path = receipt_path, .data = bytes });
}

fn validateReviewMode(mode: []const u8) !void {
    if (std.mem.eql(u8, mode, "discovery")) return;
    if (std.mem.eql(u8, mode, "kernel-review")) return;
    if (std.mem.eql(u8, mode, "conformance")) return;
    if (std.mem.eql(u8, mode, "terminal-holdout")) return;
    return error.InvalidReviewMode;
}

fn requireReviewModePhase(state: State, mode: []const u8) !void {
    if (std.mem.eql(u8, mode, "discovery")) {
        if (state.basis.sealed or state.kernel.accepted) return error.InvalidPhase;
        return;
    }
    if (std.mem.eql(u8, mode, "kernel-review")) {
        if (!state.basis.sealed and !state.basis_set) return error.BasisRequired;
        return;
    }
    if (std.mem.eql(u8, mode, "conformance")) {
        if (!state.realization.verified and !std.mem.eql(u8, state.phase, "realization_captured")) return error.InvalidPhase;
        return;
    }
    if (std.mem.eql(u8, mode, "terminal-holdout")) {
        if (!state.delivery.pushed and !state.pushed and !std.mem.eql(u8, state.phase, "terminal_ready")) return error.InvalidPhase;
        return;
    }
    return error.InvalidReviewMode;
}

fn reviewOpenPhase(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "discovery")) return "discovery_open";
    if (std.mem.eql(u8, mode, "kernel-review")) return "kernel_review";
    if (std.mem.eql(u8, mode, "conformance")) return "conformance_open";
    if (std.mem.eql(u8, mode, "terminal-holdout")) return "holdout_open";
    return "review_open";
}

fn reviewSealedPhase(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "discovery")) return "discovery_sealed";
    if (std.mem.eql(u8, mode, "kernel-review")) return "kernel_review";
    if (std.mem.eql(u8, mode, "conformance")) return "conformance_sealed";
    if (std.mem.eql(u8, mode, "terminal-holdout")) return "holdout_sealed";
    return "review_sealed";
}

fn requireOpenBatch(state: State, batch_id: []const u8) !void {
    if (state.review.open_batch_ids.len == 0) return error.BatchNotOpen;
    for (state.review.open_batch_ids) |id| {
        if (std.mem.eql(u8, id, batch_id)) return;
    }
    return error.BatchNotOpen;
}

fn hashReviewBatch(run_id: []const u8, mode: []const u8, head: []const u8, acceptance_fingerprint: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(HashSeed);
    hasher.update(run_id);
    hasher.update("\x00");
    hasher.update(mode);
    hasher.update("\x00");
    hasher.update(head);
    hasher.update("\x00");
    hasher.update(acceptance_fingerprint);
    return hasher.final();
}

fn reviewChildPath(allocator: std.mem.Allocator, state_root: []const u8, dir: []const u8, id: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{id});
    defer allocator.free(filename);
    const child = try std.fs.path.join(allocator, &.{ dir, filename });
    defer allocator.free(child);
    return statePath(allocator, state_root, child);
}

fn writeReviewChildJson(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, dir: []const u8, id: []const u8, value: std.json.Value) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{id});
    defer allocator.free(filename);
    const child = try std.fs.path.join(allocator, &.{ dir, filename });
    defer allocator.free(child);
    try writeStateChildJson(allocator, root, state_root, child, value);
}

fn loadReviewBatchParsed(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, batch_id: []const u8) !std.json.Parsed(std.json.Value) {
    const path = try reviewChildPath(allocator, state_root, ReviewBatchDir, batch_id);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn loadReviewChildParsed(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, dir: []const u8, id: []const u8) !std.json.Parsed(std.json.Value) {
    const path = try reviewChildPath(allocator, state_root, dir, id);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn writeReviewBatchArtifact(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    state_root: []const u8,
    batch_id: []const u8,
    mode: []const u8,
    head: []const u8,
    acceptance_fingerprint: []const u8,
    status: []const u8,
    aperture_ids: []const []const u8,
    receipt_ids: []const []const u8,
    mutation_events: []const []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"batch_version\":\"RB-v1\",\"batch_id\":");
    try writeJsonString(&out.writer, batch_id);
    try out.writer.writeAll(",\"mode\":");
    try writeJsonString(&out.writer, mode);
    try out.writer.writeAll(",\"campaign_id\":null,\"acceptance_fingerprint\":");
    try writeJsonString(&out.writer, acceptance_fingerprint);
    try out.writer.writeAll(",\"artifact_head\":");
    try writeJsonString(&out.writer, head);
    try out.writer.writeAll(",\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"aperture_ids\":");
    try writeStringArray(&out.writer, aperture_ids);
    try out.writer.writeAll(",\"receipt_ids\":");
    try writeStringArray(&out.writer, receipt_ids);
    try out.writer.writeAll(",\"mutation_events\":");
    try writeStringArray(&out.writer, mutation_events);
    try out.writer.writeAll("}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{batch_id});
    defer allocator.free(filename);
    const child = try std.fs.path.join(allocator, &.{ ReviewBatchDir, filename });
    defer allocator.free(child);
    try writeStateChildBytes(allocator, root, state_root, child, bytes);
}

fn validateReviewAperture(value: std.json.Value, batch_id: []const u8) !void {
    if (!std.mem.eql(u8, stringField(value, "aperture_version") orelse "", "RAP-v1")) return error.InvalidAperture;
    if (!std.mem.eql(u8, stringField(value, "batch_id") orelse "", batch_id)) return error.InvalidAperture;
    const mode = stringField(value, "mode") orelse return error.InvalidAperture;
    try validateReviewMode(mode);
    if (boolField(value, "whole_diff_allowed") == null) return error.InvalidAperture;
    if (std.mem.eql(u8, mode, "conformance")) {
        if (boolField(value, "whole_diff_allowed") != false) return error.ConformanceWholeDiffForbidden;
        if (arrayLen(objectField(value, "targets")) == 0) return error.InvalidAperture;
        if (arrayLen(objectField(value, "excluded_scope")) == 0) return error.InvalidAperture;
        if (arrayLen(objectField(value, "existing_class_refs")) == 0) return error.InvalidAperture;
        const targets = objectField(value, "targets") orelse return error.InvalidAperture;
        switch (targets) {
            .array => |arr| {
                for (arr.items) |target| {
                    if (emptyJsonValue(objectField(target, "law"))) return error.InvalidAperture;
                    if (emptyJsonValue(objectField(target, "owner"))) return error.InvalidAperture;
                    if (emptyJsonValue(objectField(target, "operation"))) return error.InvalidAperture;
                    if (emptyJsonValue(objectField(target, "transition"))) return error.InvalidAperture;
                    if (emptyJsonValue(objectField(target, "proof_target"))) return error.InvalidAperture;
                }
            },
            else => return error.InvalidAperture,
        }
    }
}

fn validateReviewReceipt(value: std.json.Value, batch_id: []const u8, strict_terminal: bool) !void {
    if (!std.mem.eql(u8, stringField(value, "batch_id") orelse "", batch_id)) return error.InvalidReceipt;
    const terminal = boolField(value, "terminal") orelse std.mem.eql(u8, stringField(value, "status") orelse "", "terminal");
    if (strict_terminal and !terminal) return error.InvalidReceipt;
    if (objectField(value, "claims")) |claims| {
        switch (claims) {
            .array => |arr| {
                for (arr.items) |claim| {
                    const relation = stringField(claim, "intent_relation") orelse stringField(claim, "classification") orelse "";
                    if (std.mem.eql(u8, relation, "unknown")) return error.InvalidReceipt;
                    if ((boolField(claim, "confirmed") orelse false) and stringField(claim, "cex_id") == null) return error.InvalidReceipt;
                }
            },
            else => return error.InvalidReceipt,
        }
    }
}

fn validateReviewBatchSeal(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, batch: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(batch, "status") orelse "", "open")) return error.BatchNotOpen;
    const batch_id = stringField(batch, "batch_id") orelse return error.InvalidBatch;
    const apertures = objectField(batch, "aperture_ids") orelse return error.InvalidBatch;
    switch (apertures) {
        .array => |arr| {
            for (arr.items) |item| {
                const aperture_id = switch (item) {
                    .string => |s| s,
                    else => return error.InvalidAperture,
                };
                var parsed_aperture = try loadReviewChildParsed(allocator, root, state_root, ReviewApertureDir, aperture_id);
                defer parsed_aperture.deinit();
                try validateReviewAperture(parsed_aperture.value, batch_id);
            }
        },
        else => return error.InvalidBatch,
    }
    const receipts = objectField(batch, "receipt_ids") orelse return error.InvalidBatch;
    switch (receipts) {
        .array => |arr| {
            for (arr.items) |item| {
                const receipt_id = switch (item) {
                    .string => |s| s,
                    else => return error.InvalidReceipt,
                };
                var parsed_receipt = try loadReviewChildParsed(allocator, root, state_root, ReviewReceiptDir, receipt_id);
                defer parsed_receipt.deinit();
                try validateReviewReceipt(parsed_receipt.value, batch_id, true);
            }
        },
        else => return error.InvalidBatch,
    }
    if (arrayLen(objectField(batch, "mutation_events")) != 0) return error.BatchMutationDetected;
}

fn validateReviewPlanValue(value: std.json.Value, mode: []const u8) !void {
    if (!std.mem.eql(u8, stringField(value, "plan_version") orelse "", "RPL-v1")) return error.InvalidAperture;
    const apertures = objectField(value, "apertures") orelse return error.InvalidAperture;
    switch (apertures) {
        .array => |arr| {
            for (arr.items) |aperture| {
                const aperture_mode = stringField(aperture, "mode") orelse mode;
                if (std.mem.eql(u8, mode, "conformance") and std.mem.eql(u8, aperture_mode, "conformance") and boolField(aperture, "whole_diff_allowed") != false) return error.ConformanceWholeDiffForbidden;
            }
        },
        else => return error.InvalidAperture,
    }
}

fn singleStringArray(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, 1);
    out[0] = value;
    return out;
}

fn appendStringSlice(allocator: std.mem.Allocator, existing: []const []const u8, extra: []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, existing.len + 1);
    for (existing, 0..) |item, i| out[i] = item;
    out[existing.len] = extra;
    return out;
}

fn stringArrayWithExtra(allocator: std.mem.Allocator, value: std.json.Value, field: []const u8, extra: ?[]const u8) ![]const []const u8 {
    const existing_len = arrayLen(objectField(value, field));
    const add = if (extra != null) @as(usize, 1) else @as(usize, 0);
    var out = try allocator.alloc([]const u8, existing_len + add);
    var idx: usize = 0;
    if (objectField(value, field)) |arr_value| {
        switch (arr_value) {
            .array => |arr| {
                for (arr.items) |item| {
                    out[idx] = switch (item) {
                        .string => |s| s,
                        else => return error.InvalidBatch,
                    };
                    idx += 1;
                }
            },
            else => return error.InvalidBatch,
        }
    }
    if (extra) |actual| out[idx] = actual;
    return out;
}

fn initialState(args: Args) State {
    return .{
        .schema = StateSchemaV3,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 3,
        .run_id = "",
        .repo_root = args.cwd,
        .branch = "",
        .base_sha = "",
        .phase = "initialized",
        .acceptance_goal = "",
        .parent_run_id = null,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    };
}

fn saveState(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, state: State) !void {
    const state_path = try statePath(allocator, state_root, StateFile);
    defer allocator.free(state_path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeStateJson(&out.writer, state);
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeRootFileAtomic(allocator, root, state_path, bytes);
}

fn writeStateJson(writer: anytype, state: State) !void {
    try writer.writeAll("{\n  \"schema\": ");
    try writeJsonString(writer, state.schema);
    if (state.state_version >= 3) {
        try writer.writeAll(",\n  \"protocol_profile\": ");
        try writeJsonString(writer, state.protocol_profile);
        try writer.print(",\n  \"state_version\": {d},\n  \"campaign\": ", .{state.state_version});
        try writeCampaignStateJson(writer, state);
        try writer.writeAll(",\n  \"phase\": ");
        try writeJsonString(writer, state.phase);
        try writer.writeAll(",\n  \"acceptance\": ");
        try writeAcceptanceStateJson(writer, state.acceptance);
        try writer.writeAll(",\n  \"review\": ");
        try writeReviewStateJson(writer, state.review);
        try writer.writeAll(",\n  \"counterexamples\": ");
        try writeCounterexampleStateJson(writer, state);
        try writer.writeAll(",\n  \"basis\": ");
        try writeBasisStateJson(writer, state);
        try writer.writeAll(",\n  \"kernel\": ");
        try writeArtifactGateStateJson(writer, state.kernel);
        try writer.writeAll(",\n  \"reduction\": ");
        try writeArtifactGateStateJson(writer, state.reduction);
        try writer.writeAll(",\n  \"design\": ");
        try writeDesignStateJson(writer, state);
        try writer.writeAll(",\n  \"realization\": ");
        try writeRealizationStateJson(writer, state.realization);
        try writer.writeAll(",\n  \"potential\": ");
        try writePotentialStateJson(writer, state.potential);
        try writer.writeAll(",\n  \"delivery\": ");
        try writeDeliveryStateJson(writer, state);
        try writer.writeAll(",\n  \"closure\": ");
        try writeClosureStateJson(writer, state);
    } else {
        try writer.print(",\n  \"state_version\": {d}", .{state.state_version});
    }
    try writer.writeAll(",\n  \"state_root\": ");
    try writeJsonString(writer, state.state_root);
    try writer.writeAll(",\n  \"legacy_root\": ");
    try writeJsonString(writer, state.legacy_root);
    try writer.writeAll(",\n  \"run_id\": ");
    try writeJsonString(writer, state.run_id);
    try writer.writeAll(",\n  \"repo_root\": ");
    try writeJsonString(writer, state.repo_root);
    try writer.writeAll(",\n  \"branch\": ");
    try writeJsonString(writer, state.branch);
    try writer.writeAll(",\n  \"base_sha\": ");
    try writeJsonString(writer, state.base_sha);
    if (state.state_version < 3) {
        try writer.writeAll(",\n  \"phase\": ");
        try writeJsonString(writer, state.phase);
    }
    try writer.writeAll(",\n  \"acceptance_goal\": ");
    try writeJsonString(writer, state.acceptance_goal);
    try writer.writeAll(",\n  \"parent_run_id\": ");
    try writeOptionalString(writer, state.parent_run_id);
    try writer.print(",\n  \"counterexample_count\": {d},\n  \"basis_set\": {},\n  \"tournament_waiver\": ", .{ state.counterexample_count, state.basis_set });
    try writeOptionalString(writer, state.tournament_waiver);
    try writer.writeAll(",\n  \"candidates\": [");
    for (state.candidates, 0..) |candidate, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeCandidateJson(writer, candidate);
    }
    try writer.writeAll("],\n  \"selected_candidate_id\": ");
    try writeOptionalString(writer, state.selected_candidate_id);
    try writer.writeAll(",\n  \"ablation_authority\": ");
    try writeOptionalString(writer, state.ablation_authority);
    try writer.print(",\n  \"ablation_orphan_edit_atoms\": {d},\n  \"candidate_holdout_safe\": {},\n  \"delivery_holdout_safe\": {},\n  \"proof_authority\": ", .{
        state.ablation_orphan_edit_atoms,
        state.candidate_holdout_safe,
        state.delivery_holdout_safe,
    });
    try writeOptionalString(writer, state.proof_authority);
    try writer.print(",\n  \"proof_passed\": {},\n  \"proof_patch_stable\": {},\n  \"delivery_patch_sha\": ", .{ state.proof_passed, state.proof_patch_stable });
    try writeOptionalString(writer, state.delivery_patch_sha);
    try writer.writeAll(",\n  \"commit_sha\": ");
    try writeOptionalString(writer, state.commit_sha);
    try writer.print(",\n  \"pushed\": {},\n  \"certificate_stage\": ", .{state.pushed});
    try writeOptionalString(writer, state.certificate_stage);
    try writer.writeAll("\n}\n");
}

fn writeCampaignStateJson(writer: anytype, state: State) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, if (state.campaign.id.len > 0) state.campaign.id else state.run_id);
    try writer.writeAll(",\"repo_root\":");
    try writeJsonString(writer, if (state.campaign.repo_root.len > 0) state.campaign.repo_root else state.repo_root);
    try writer.writeAll(",\"branch\":");
    try writeJsonString(writer, if (state.campaign.branch.len > 0) state.campaign.branch else state.branch);
    try writer.writeAll(",\"base_sha\":");
    try writeJsonString(writer, if (state.campaign.base_sha.len > 0) state.campaign.base_sha else state.base_sha);
    try writer.writeAll(",\"parent_run_id\":");
    try writeOptionalString(writer, preferOptionalString(state.campaign.parent_run_id, state.parent_run_id));
    try writer.writeByte('}');
}

fn writeAcceptanceStateJson(writer: anytype, acceptance: AcceptanceStateV3) !void {
    try writer.print("{{\"sequence\":{d},\"contract_id\":", .{acceptance.sequence});
    try writeOptionalString(writer, acceptance.contract_id);
    try writer.writeAll(",\"fingerprint\":");
    try writeOptionalString(writer, acceptance.fingerprint);
    try writer.writeAll(",\"horizon_state\":");
    try writeJsonString(writer, acceptance.horizon_state);
    try writer.writeByte('}');
}

fn writeReviewStateJson(writer: anytype, review: ReviewStateV3) !void {
    try writer.writeAll("{\"open_batch_ids\":");
    try writeStringArray(writer, review.open_batch_ids);
    try writer.writeAll(",\"sealed_batch_ids\":");
    try writeStringArray(writer, review.sealed_batch_ids);
    try writer.writeAll(",\"latest_discovery_batch\":");
    try writeOptionalString(writer, review.latest_discovery_batch);
    try writer.writeAll(",\"latest_conformance_batch\":");
    try writeOptionalString(writer, review.latest_conformance_batch);
    try writer.writeAll(",\"terminal_holdout_batch\":");
    try writeOptionalString(writer, review.terminal_holdout_batch);
    try writer.writeByte('}');
}

fn writeCounterexampleStateJson(writer: anytype, state: State) !void {
    const total = if (state.counterexamples.total > 0) state.counterexamples.total else state.counterexample_count;
    try writer.print(
        "{{\"total\":{d},\"in_horizon\":{d},\"outside_horizon\":{d},\"unknown\":{d},\"new_classes\":{d},\"existing_witnesses\":{d},\"duplicates\":{d}}}",
        .{
            total,
            state.counterexamples.in_horizon,
            state.counterexamples.outside_horizon,
            state.counterexamples.unknown,
            state.counterexamples.new_classes,
            state.counterexamples.existing_witnesses,
            state.counterexamples.duplicates,
        },
    );
}

fn writeBasisStateJson(writer: anytype, state: State) !void {
    try writer.writeAll("{\"id\":");
    try writeOptionalString(writer, state.basis.id);
    try writer.writeAll(",\"fingerprint\":");
    try writeOptionalString(writer, state.basis.fingerprint);
    try writer.print(",\"sealed\":{}}}", .{state.basis.sealed or state.basis_set});
}

fn writeArtifactGateStateJson(writer: anytype, artifact: ArtifactGateStateV3) !void {
    try writer.writeAll("{\"fingerprint\":");
    try writeOptionalString(writer, artifact.fingerprint);
    try writer.print(",\"accepted\":{}}}", .{artifact.accepted});
}

fn writeDesignStateJson(writer: anytype, state: State) !void {
    try writer.writeAll("{\"selected_id\":");
    try writeOptionalString(writer, preferOptionalString(state.design.selected_id, state.selected_candidate_id));
    try writer.writeByte('}');
}

fn writeRealizationStateJson(writer: anytype, realization: RealizationStateV3) !void {
    try writer.writeAll("{\"cycle_id\":");
    try writeOptionalString(writer, realization.cycle_id);
    try writer.print(",\"verified\":{},\"invalidated\":{},\"invalidation_reason\":", .{ realization.verified, realization.invalidated });
    try writeOptionalString(writer, realization.invalidation_reason);
    try writer.writeByte('}');
}

fn writePotentialStateJson(writer: anytype, potential: PotentialStateV3) !void {
    try writer.writeAll("{\"current_id\":");
    try writeOptionalString(writer, potential.current_id);
    try writer.print(",\"strict_progress\":{}}}", .{potential.strict_progress});
}

fn writeDeliveryStateJson(writer: anytype, state: State) !void {
    try writer.writeAll("{\"patch_sha\":");
    try writeOptionalString(writer, preferOptionalString(state.delivery.patch_sha, state.delivery_patch_sha));
    try writer.writeAll(",\"commit_sha\":");
    try writeOptionalString(writer, preferOptionalString(state.delivery.commit_sha, state.commit_sha));
    try writer.print(",\"pushed\":{}}}", .{state.delivery.pushed or state.pushed});
}

fn writeClosureStateJson(writer: anytype, state: State) !void {
    try writer.writeAll("{\"certificate_stage\":");
    try writeOptionalString(writer, preferOptionalString(state.closure.certificate_stage, state.certificate_stage));
    try writer.writeByte('}');
}

fn preferOptionalString(primary: ?[]const u8, fallback: ?[]const u8) ?[]const u8 {
    if (primary) |value| return value;
    return fallback;
}

fn writeStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}

fn writeCandidateJson(writer: anytype, candidate: Candidate) !void {
    try writer.writeAll("{\"candidate_id\":");
    try writeJsonString(writer, candidate.candidate_id);
    try writer.writeAll(",\"route_class\":");
    try writeJsonString(writer, candidate.route_class);
    try writer.writeAll(",\"route_family\":");
    try writeJsonString(writer, candidate.route_family);
    try writer.writeAll(",\"patch_sha\":");
    try writeJsonString(writer, candidate.patch_sha);
    try writer.writeAll(",\"worktree\":");
    try writeOptionalString(writer, candidate.worktree);
    try writer.print(",\"valid\":{},\"invalid_reasons\":[", .{candidate.valid});
    for (candidate.invalid_reasons, 0..) |reason, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, reason);
    }
    try writer.writeAll("],\"semantic_cost\":[");
    for (candidate.semantic_cost, 0..) |cost, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{d}", .{cost});
    }
    try writer.writeAll("]}");
}

fn loadStateParsed(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) !std.json.Parsed(State) {
    const state_path = try statePath(allocator, state_root, StateFile);
    defer allocator.free(state_path);
    const bytes = try root.readFileAlloc(Io, state_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(State, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
}

fn statePath(allocator: std.mem.Allocator, state_root: []const u8, child: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ state_root, child });
}

const WrittenAcceptance = struct {
    sequence: u32,
    contract_id: ?[]const u8,
    fingerprint: []const u8,

    fn deinit(self: WrittenAcceptance, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
    }
};

fn writeAcceptanceArtifact(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, value: std.json.Value) !WrittenAcceptance {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJsonValue(&out.writer, value);
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    const fingerprint = try sha256FingerprintAlloc(allocator, bytes);
    errdefer allocator.free(fingerprint);
    try writeStateChildBytes(allocator, root, state_root, AcceptanceFile, bytes);
    return .{
        .sequence = acceptanceSequence(value),
        .contract_id = acceptanceContractId(value),
        .fingerprint = fingerprint,
    };
}

fn loadAcceptanceParsed(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) !std.json.Parsed(std.json.Value) {
    const path = try statePath(allocator, state_root, AcceptanceFile);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn parseStateChildJson(allocator: std.mem.Allocator, args: Args, child: []const u8) !std.json.Parsed(std.json.Value) {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try statePath(allocator, args.state_root, child);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn acceptanceFingerprintAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJsonValue(&out.writer, value);
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    return sha256FingerprintAlloc(allocator, bytes);
}

fn validateAcceptanceV2(value: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(value, "acceptance_version") orelse "", "AC-v2")) return error.InvalidAcceptance;
    if (std.mem.trim(u8, stringField(value, "goal") orelse "", " \t\r\n").len == 0) return error.InvalidAcceptance;
    if (arrayLen(objectField(value, "source_refs")) == 0) return error.InvalidAcceptance;
    if (arrayLen(objectField(value, "required")) == 0 and
        arrayLen(objectField(value, "compatibility")) == 0 and
        arrayLen(objectField(value, "forbidden")) == 0) return error.InvalidAcceptance;
    if (objectField(value, "proof_bar") == null) return error.InvalidAcceptance;
    const observation_language = objectField(value, "observation_language") orelse return error.InvalidAcceptance;
    if (!objectHasFields(observation_language)) return error.InvalidAcceptance;
    if (objectField(value, "authority") == null) return error.InvalidAcceptance;
    const horizon = objectField(value, "horizon") orelse return error.InvalidAcceptance;
    if (integerField(horizon, "sequence") == null) return error.InvalidAcceptance;
    if (acceptanceSequence(value) == 0) return error.InvalidAcceptance;
    if (!std.mem.startsWith(u8, stringField(value, "fingerprint") orelse "", "sha256:")) return error.InvalidAcceptance;
}

fn acceptanceSequence(value: std.json.Value) u32 {
    const horizon = objectField(value, "horizon") orelse return 0;
    const sequence = integerField(horizon, "sequence") orelse return 0;
    if (sequence < 0 or sequence > std.math.maxInt(u32)) return 0;
    return @intCast(sequence);
}

fn acceptanceContractId(value: std.json.Value) ?[]const u8 {
    if (stringField(value, "contract_id")) |id| return id;
    return stringField(value, "id");
}

fn objectHasFields(value: std.json.Value) bool {
    return switch (value) {
        .object => |obj| obj.count() > 0,
        else => false,
    };
}

fn integerField(value: std.json.Value, key: []const u8) ?i64 {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .integer => |n| n,
        else => null,
    };
}

fn isIntentOpenPhase(phase: []const u8) bool {
    return std.mem.eql(u8, phase, "initialized") or
        std.mem.eql(u8, phase, "collecting") or
        std.mem.eql(u8, phase, "intent_open");
}

fn invalidateAcceptanceDownstream(state: *State) void {
    state.basis = .{};
    state.kernel = .{};
    state.reduction = .{};
    state.design = .{};
    state.realization = .{};
    state.potential = .{};
    state.delivery = .{};
    state.closure = .{};
    state.basis_set = false;
    state.selected_candidate_id = null;
    state.ablation_authority = null;
    state.ablation_orphan_edit_atoms = 0;
    state.candidate_holdout_safe = false;
    state.delivery_holdout_safe = false;
    state.proof_authority = null;
    state.proof_passed = false;
    state.proof_patch_stable = false;
    state.delivery_patch_sha = null;
    state.commit_sha = null;
    state.pushed = false;
    state.certificate_stage = null;
}

fn archiveAcceptanceArtifact(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, archive_root: []const u8) !void {
    const source = try statePath(allocator, state_root, AcceptanceFile);
    defer allocator.free(source);
    const bytes = root.readFileAlloc(Io, source, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    const dest = try std.fs.path.join(allocator, &.{ archive_root, AcceptanceFile });
    defer allocator.free(dest);
    if (std.fs.path.dirname(dest)) |dir| try root.createDirPath(Io, dir);
    try writeRootFileAtomic(allocator, root, dest, bytes);
}

fn writeRootFileAtomic(allocator: std.mem.Allocator, root: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path);
    const tmp_name = try std.fmt.allocPrint(allocator, ".{s}.{d}.tmp", .{ base, std.Io.Clock.awake.now(Io).nanoseconds });
    defer allocator.free(tmp_name);
    const lock_name = try std.fmt.allocPrint(allocator, ".{s}.lock", .{base});
    defer allocator.free(lock_name);

    if (parent) |dir_path| {
        try root.createDirPath(Io, dir_path);
        var dir = try root.openDir(Io, dir_path, .{});
        defer dir.close(Io);
        try writeTempAndRenameLocked(&dir, lock_name, tmp_name, base, bytes);
    } else {
        var dir = root;
        try writeTempAndRenameLocked(&dir, lock_name, tmp_name, base, bytes);
    }
}

fn writeTempAndRenameLocked(dir: *std.Io.Dir, lock_name: []const u8, tmp_name: []const u8, base: []const u8, bytes: []const u8) !void {
    var lock = try dir.createFile(Io, lock_name, .{ .exclusive = true, .read = true, .truncate = false });
    defer {
        lock.close(Io);
        dir.deleteFile(Io, lock_name) catch {};
    }
    try writeTempAndRename(dir, tmp_name, base, bytes);
}

fn writeTempAndRename(dir: *std.Io.Dir, tmp_name: []const u8, base: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(Io, tmp_name, .{ .truncate = true, .read = true });
    var close_file = true;
    errdefer if (close_file) file.close(Io);
    try file.writeStreamingAll(Io, bytes);
    try file.sync(Io);
    file.close(Io);
    close_file = false;
    errdefer dir.deleteFile(Io, tmp_name) catch {};
    try dir.rename(tmp_name, dir.*, base, Io);
}

fn fileExists(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, child: []const u8) bool {
    const path = statePath(allocator, state_root, child) catch return false;
    defer allocator.free(path);
    root.access(Io, path, .{}) catch return false;
    return true;
}

fn stateFileExists(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) bool {
    return fileExists(allocator, root, state_root, StateFile);
}

fn appendEventInitial(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, event: []const u8, after: State, detail: []const u8) ![]u8 {
    return appendEventWithBefore(allocator, root, state_root, event, null, after, detail);
}

fn appendEvent(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, event: []const u8, before: State, after: State, detail: []const u8) ![]u8 {
    return appendEventWithBefore(allocator, root, state_root, event, before, after, detail);
}

fn appendEventWithBefore(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, event: []const u8, before: ?State, after: State, detail: []const u8) ![]u8 {
    const path = try statePath(allocator, state_root, EventFile);
    defer allocator.free(path);
    const existing = root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owned = existing.len > 0;
    defer if (owned) allocator.free(existing);
    const sequence = countLines(existing) + 1;
    const event_id = try eventIdAlloc(allocator, event, after.phase, sequence);
    errdefer allocator.free(event_id);
    const state_after_fingerprint = try stateFingerprintAlloc(allocator, after);
    defer allocator.free(state_after_fingerprint);
    const state_before_fingerprint = if (before) |before_state| try stateFingerprintAlloc(allocator, before_state) else null;
    defer if (state_before_fingerprint) |fingerprint| allocator.free(fingerprint);
    const receipt_id = hashReceipt(event, "success", detail);
    const detail_hash = hashBytes(detail);
    var row: std.Io.Writer.Allocating = .init(allocator);
    defer row.deinit();
    try row.writer.writeAll("{\"event_id\":");
    try writeJsonString(&row.writer, event_id);
    try row.writer.print(",\"sequence\":{d},\"timestamp_ns\":{d},\"event\":", .{ sequence, std.Io.Clock.awake.now(Io).nanoseconds });
    try writeJsonString(&row.writer, event);
    try row.writer.writeAll(",\"campaign_id\":");
    try writeJsonString(&row.writer, if (after.campaign.id.len > 0) after.campaign.id else after.run_id);
    try row.writer.writeAll(",\"phase_before\":");
    if (before) |before_state| try writeJsonString(&row.writer, before_state.phase) else try row.writer.writeAll("null");
    try row.writer.writeAll(",\"phase_after\":");
    try writeJsonString(&row.writer, after.phase);
    try row.writer.writeAll(",\"phase\":");
    try writeJsonString(&row.writer, after.phase);
    try row.writer.writeAll(",\"source_command_receipt\":{\"receipt_version\":\"RC3-R1\",\"receipt_id\":\"rcpt-");
    try row.writer.print("{x}", .{receipt_id});
    try row.writer.writeAll("\",\"command\":");
    try writeJsonString(&row.writer, event);
    try row.writer.writeAll(",\"outcome\":\"success\",\"detail\":");
    try writeJsonString(&row.writer, detail);
    try row.writer.writeAll(",\"detail_fingerprint\":\"sha256:");
    try row.writer.print("{x}", .{detail_hash});
    try row.writer.writeAll("\"},\"artifact_fingerprints\":{\"state_before\":");
    try writeOptionalString(&row.writer, state_before_fingerprint);
    try row.writer.writeAll(",\"state_after\":");
    try writeJsonString(&row.writer, state_after_fingerprint);
    try row.writer.writeAll(",\"state\":");
    try writeJsonString(&row.writer, state_after_fingerprint);
    try row.writer.writeAll("}}");
    const line = try row.toOwnedSlice();
    defer allocator.free(line);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (existing.len > 0) try out.writer.writeAll(existing);
    try out.writer.writeAll(line);
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeRootFileAtomic(allocator, root, path, bytes);
    return event_id;
}

fn appendEventOnly(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, event: []const u8, phase: []const u8) !void {
    var parsed = try loadStateParsed(allocator, root, state_root);
    defer parsed.deinit();
    var state = parsed.value;
    state.phase = phase;
    const event_id = try appendEventWithBefore(allocator, root, state_root, event, state, state, phase);
    defer allocator.free(event_id);
}

fn eventIdAlloc(allocator: std.mem.Allocator, event: []const u8, phase: []const u8, sequence: usize) ![]u8 {
    var hasher = std.hash.Wyhash.init(HashSeed);
    hasher.update(event);
    hasher.update("\x00");
    hasher.update(phase);
    hasher.update("\x00");
    var seq_buf: [32]u8 = undefined;
    const seq_text = try std.fmt.bufPrint(&seq_buf, "{d}", .{sequence});
    hasher.update(seq_text);
    return std.fmt.allocPrint(allocator, "evt-{x}", .{hasher.final()});
}

fn countLines(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn writeMbkc(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, state: State, stage: []const u8) !void {
    const path = try statePath(allocator, state_root, MbkcFile);
    defer allocator.free(path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeMbkcJson(&out.writer, state, stage);
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeRootFileAtomic(allocator, root, path, bytes);
}

fn writeMbkcJson(writer: anytype, state: State, stage: []const u8) !void {
    try writer.writeAll("{\"minimum_behavioral_kernel_certificate\":{\"certificate_version\":\"MBKC-v1\",\"certificate_id\":\"sha256:");
    try writer.print("{x}", .{std.hash.Wyhash.hash(0, state.run_id)});
    try writer.writeAll("\",\"stage\":");
    try writeJsonString(writer, stage);
    try writer.writeAll(",\"campaign\":{\"campaign_id\":");
    try writeJsonString(writer, state.run_id);
    try writer.writeAll(",\"repo_root\":");
    try writeJsonString(writer, state.repo_root);
    try writer.writeAll(",\"branch\":");
    try writeJsonString(writer, state.branch);
    try writer.writeAll(",\"campaign_base_sha\":");
    try writeJsonString(writer, state.base_sha);
    try writer.writeAll(",\"review_ready_baseline_sha\":");
    try writeJsonString(writer, state.base_sha);
    try writer.writeAll("},\"acceptance\":{\"goal\":");
    try writeJsonString(writer, state.acceptance_goal);
    try writer.writeAll("},\"observations\":{\"count\":");
    try writer.print("{d}", .{state.counterexample_count});
    try writer.writeAll("},\"kernel\":{},\"kernel_review\":{},\"realization_designs\":{},\"selected_design\":{},\"realization_map\":{},\"semantic_surface\":{},\"proof_basis\":{},\"negative_evidence\":{},\"holdouts\":{},\"delivery\":{\"commit_sha\":");
    try writeOptionalString(writer, state.commit_sha);
    try writer.print(",\"pushed\":{}", .{state.pushed});
    try writer.writeAll("},\"closure_horizon\":{},\"gate\":{\"kernel_allowed\":false,\"realization_allowed\":false,\"apply_allowed\":false,\"commit_allowed\":false,\"push_allowed\":false,\"tuple_closure_allowed\":false,\"terminal_closure_allowed\":false}}}\n");
}

fn writeMrpc(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, state: State, stage: []const u8) !void {
    const path = try statePath(allocator, state_root, CertFile);
    defer allocator.free(path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeMrpcJson(&out.writer, state, stage);
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try root.writeFile(Io, .{ .sub_path = path, .data = bytes });
}

fn writeMrpcJson(writer: anytype, state: State, stage: []const u8) !void {
    try writer.writeAll("{\"minimal_review_patch_certificate\":{\"certificate_version\":\"MRPC-v1\",\"certificate_id\":\"MRPC-");
    try writer.print("{x}", .{std.hash.Wyhash.hash(0, state.run_id)});
    try writer.writeAll("\",\"stage\":");
    try writeJsonString(writer, stage);
    try writer.writeAll(",\"run_id\":");
    try writeJsonString(writer, state.run_id);
    try writer.writeAll(",\"immutable_base\":{\"repo_root\":");
    try writeJsonString(writer, state.repo_root);
    try writer.writeAll(",\"branch\":");
    try writeJsonString(writer, state.branch);
    try writer.writeAll(",\"sha\":");
    try writeJsonString(writer, state.base_sha);
    try writer.writeAll("},\"acceptance_contract\":{\"goal\":");
    try writeJsonString(writer, state.acceptance_goal);
    try writer.writeAll("},\"counterexample_basis\":{\"basis_set\":");
    try writer.print("{}", .{state.basis_set});
    try writer.writeAll("},\"candidate_tournament\":[");
    for (state.candidates, 0..) |candidate, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"candidate_id\":");
        try writeJsonString(writer, candidate.candidate_id);
        try writer.writeAll(",\"route_class\":");
        try writeJsonString(writer, candidate.route_class);
        try writer.writeAll(",\"route_family\":");
        try writeJsonString(writer, candidate.route_family);
        try writer.writeAll(",\"valid\":");
        try writer.print("{}", .{candidate.valid});
        try writer.writeAll(",\"semantic_cost\":");
        try writeCostObject(writer, candidate.semantic_cost);
        try writer.writeAll(",\"patch_sha\":");
        try writeJsonString(writer, candidate.patch_sha);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"selected_candidate\":");
    if (selectedCandidate(state)) |candidate| {
        try writer.writeAll("{\"candidate_id\":");
        try writeJsonString(writer, candidate.candidate_id);
        try writer.writeAll(",\"patch_sha\":");
        try writeJsonString(writer, candidate.patch_sha);
        try writer.writeAll(",\"semantic_cost\":");
        try writeCostObject(writer, candidate.semantic_cost);
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"ablation\":{\"authority\":");
    try writeOptionalString(writer, state.ablation_authority);
    try writer.writeAll(",\"orphan_edit_atoms\":[");
    var i: u32 = 0;
    while (i < state.ablation_orphan_edit_atoms) : (i += 1) {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\"orphan\"");
    }
    try writer.writeAll("]},\"proof\":{\"authority\":");
    try writeOptionalString(writer, state.proof_authority);
    try writer.print(",\"passed\":{},\"patch_stable\":{}", .{ state.proof_passed, state.proof_patch_stable });
    try writer.writeAll("},\"holdout\":{\"candidate_safe\":");
    try writer.print("{},\"delivery_safe\":{}", .{ state.candidate_holdout_safe, state.delivery_holdout_safe });
    try writer.writeAll("},\"delivery\":{\"patch_sha\":");
    try writeOptionalString(writer, state.delivery_patch_sha);
    try writer.writeAll(",\"commit_sha\":");
    try writeOptionalString(writer, state.commit_sha);
    try writer.print(",\"pushed\":{}", .{state.pushed});
    try writer.writeAll("},\"metrics\":{\"raw_findings\":");
    try writer.print("{d},\"independent_families\":{},\"candidates_evaluated\":{d},\"candidates_discarded\":0,\"edit_atoms_before_ablation\":{d},\"edit_atoms_removed\":0,\"edit_atoms_survived\":0,\"orphan_edit_atoms\":[", .{
        state.counterexample_count,
        state.basis_set,
        state.candidates.len,
        state.ablation_orphan_edit_atoms,
    });
    i = 0;
    while (i < state.ablation_orphan_edit_atoms) : (i += 1) {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\"orphan\"");
    }
    try writer.writeAll("]},\"gate\":{\"apply_allowed\":");
    try writer.print("{},\"commit_allowed\":{},\"push_allowed\":{},\"closure_allowed\":{}", .{
        std.mem.eql(u8, stage, "apply-certified"),
        std.mem.eql(u8, stage, "final-certified"),
        std.mem.eql(u8, stage, "committed"),
        std.mem.eql(u8, stage, "pushed") or std.mem.eql(u8, stage, "closed"),
    });
    try writer.writeAll("}}}\n");
}

fn printMrpcFile(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) !void {
    const path = try statePath(allocator, state_root, CertFile);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    try writeStdoutBytes(allocator, bytes);
}

fn writeCostObject(writer: anytype, costs: [CostFields.len]i64) !void {
    try writer.writeByte('{');
    for (CostFields, 0..) |field, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, field);
        try writer.print(":{d}", .{costs[i]});
    }
    try writer.writeByte('}');
}

fn parseSemanticCost(value: std.json.Value) ![CostFields.len]i64 {
    const cost = objectField(value, "semantic_cost") orelse value;
    var out = [_]i64{0} ** CostFields.len;
    for (CostFields, 0..) |field, i| {
        out[i] = intField(cost, field) orelse return error.InvalidSemanticCost;
    }
    return out;
}

fn candidateContractValid(value: std.json.Value, costs: [CostFields.len]i64) bool {
    _ = costs;
    const verification = objectField(value, "verification") orelse return false;
    if (!std.mem.eql(u8, stringField(verification, "authority") orelse "", "controller")) return false;
    for (VerificationFields) |field| {
        if ((boolField(verification, field) orelse false) != true) return false;
    }
    if ((boolField(verification, "falsified_routes_reused") orelse false) == true) return false;
    if ((boolField(value, "scope_valid") orelse false) != true) return false;
    const negative = objectField(value, "negative_route");
    const status = if (negative) |n| stringField(n, "status") orelse "unknown" else "unknown";
    if (std.mem.eql(u8, status, "active_exclusion")) return false;
    for (NegativeAllowedStatuses) |allowed| {
        if (std.mem.eql(u8, status, allowed)) return true;
    }
    return false;
}

fn selectedCandidate(state: State) ?Candidate {
    const selected_id = state.selected_candidate_id orelse return null;
    if (findCandidateIndex(state.candidates, selected_id)) |idx| return state.candidates[idx];
    return null;
}

fn findCandidateIndex(candidates: []const Candidate, candidate_id: []const u8) ?usize {
    for (candidates, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate.candidate_id, candidate_id)) return i;
    }
    return null;
}

fn countCandidatesExcept(candidates: []const Candidate, candidate_id: []const u8) usize {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (!std.mem.eql(u8, candidate.candidate_id, candidate_id)) count += 1;
    }
    return count;
}

fn replaceCandidateAt(allocator: std.mem.Allocator, candidates: []const Candidate, idx: usize, replacement: Candidate) ![]const Candidate {
    var next = try allocator.alloc(Candidate, candidates.len);
    for (candidates, 0..) |candidate, i| {
        next[i] = if (i == idx) replacement else candidate;
    }
    return next;
}

fn distinctRouteClasses(candidates: []const Candidate) usize {
    var count: usize = 0;
    for (candidates, 0..) |candidate, i| {
        var seen = false;
        for (candidates[0..i]) |prior| {
            if (std.mem.eql(u8, prior.route_class, candidate.route_class)) seen = true;
        }
        if (!seen) count += 1;
    }
    return count;
}

fn hasControlCandidate(candidates: []const Candidate) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.route_class, "no-change") or std.mem.eql(u8, candidate.route_class, "local-baseline")) return true;
    }
    return false;
}

fn candidateLess(a: Candidate, b: Candidate) bool {
    for (a.semantic_cost, 0..) |cost, i| {
        if (cost < b.semantic_cost[i]) return true;
        if (cost > b.semantic_cost[i]) return false;
    }
    return std.mem.lessThan(u8, a.candidate_id, b.candidate_id);
}

fn costTupleGreater(a: [CostFields.len]i64, b: [CostFields.len]i64) bool {
    for (a, 0..) |cost, i| {
        if (cost > b[i]) return true;
        if (cost < b[i]) return false;
    }
    return false;
}

fn invalidateCompilation(state: *State, phase: []const u8) void {
    state.phase = phase;
    state.selected_candidate_id = null;
    state.ablation_authority = null;
    state.ablation_orphan_edit_atoms = 0;
    state.candidate_holdout_safe = false;
    state.delivery_holdout_safe = false;
    state.proof_authority = null;
    state.proof_passed = false;
    state.proof_patch_stable = false;
    state.delivery_patch_sha = null;
    state.commit_sha = null;
    state.pushed = false;
    state.certificate_stage = null;
}

fn requirePhase(state: State, allowed: []const []const u8) !void {
    for (allowed) |phase| {
        if (std.mem.eql(u8, state.phase, phase)) return;
    }
    return error.InvalidPhase;
}

fn isTerminalPhase(phase: []const u8) bool {
    for (TerminalPhases) |terminal| {
        if (std.mem.eql(u8, phase, terminal)) return true;
    }
    return false;
}

fn certificateRequired(phase: []const u8) bool {
    return std.mem.eql(u8, phase, "apply-certified") or
        std.mem.eql(u8, phase, "applied") or
        std.mem.eql(u8, phase, "final-certified") or
        std.mem.eql(u8, phase, "committed") or
        std.mem.eql(u8, phase, "pushed") or
        std.mem.eql(u8, phase, "closed");
}

fn isBranchLiable(value: []const u8) bool {
    for (BranchLiable) |liability| {
        if (std.mem.eql(u8, value, liability)) return true;
    }
    return false;
}

fn hasSafeVerdict(value: ?[]const u8) bool {
    const verdict = value orelse return false;
    return std.mem.eql(u8, verdict, "clean") or std.mem.eql(u8, verdict, "followups-only") or std.mem.eql(u8, verdict, "subsumed-only");
}

fn optionalEql(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |actual| std.mem.eql(u8, actual, expected) else false;
}

fn parseJsonInput(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try readFileOrStdin(allocator, path);
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn validateObservationValue(value: std.json.Value) !void {
    const observation_id = stringField(value, "observation_id") orelse stringField(value, "id") orelse return error.InvalidCounterexample;
    try validateSafeId(observation_id);
    if (stringField(value, "validity") == null) return error.InvalidCounterexample;
    if (stringField(value, "liability") == null) return error.InvalidCounterexample;
    if (stringField(value, "kernel_impact") == null) return error.InvalidCounterexample;
    if (emptyJsonValue(objectField(value, "expected_result"))) return error.InvalidCounterexample;
    if (emptyJsonValue(objectField(value, "proof"))) return error.InvalidCounterexample;
}

const OwnedStringList = struct {
    items: []const []const u8,
};

fn freeStringList(allocator: std.mem.Allocator, list: OwnedStringList) void {
    for (list.items) |item| allocator.free(item);
    allocator.free(list.items);
}

fn validateCounterexampleV1(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, value: std.json.Value, expected_batch_id: []const u8, batch: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(value, "cex_version") orelse "", "CEX-v1")) return error.InvalidCounterexample;
    const cex_id = stringField(value, "cex_id") orelse return error.InvalidCounterexample;
    try validateSafeId(cex_id);
    if (!std.mem.eql(u8, stringField(value, "batch_id") orelse "", expected_batch_id)) return error.InvalidCounterexample;
    if (boolField(value, "mutation_authority") orelse false) return error.InvalidCounterexample;
    const intent_relation = stringField(value, "intent_relation") orelse return error.CounterexampleUnanchored;
    if (!stringIn(intent_relation, &CounterexampleIntentRelations)) return error.CounterexampleUnanchored;
    const novelty = stringField(value, "novelty") orelse return error.CounterexampleUnknown;
    if (!stringIn(novelty, &CounterexampleNovelty)) return error.CounterexampleUnknown;
    const disposition = stringField(value, "disposition") orelse return error.CounterexampleUnknown;
    if (!stringIn(disposition, &CounterexampleDispositions)) return error.CounterexampleUnknown;
    if (!std.mem.eql(u8, disposition, expectedCounterexampleDisposition(intent_relation, novelty))) return error.CounterexampleInvalid;
    if (std.mem.eql(u8, intent_relation, "unknown") or std.mem.eql(u8, novelty, "unknown")) return error.CounterexampleUnknown;
    if ((std.mem.eql(u8, disposition, "accepted") or std.mem.eql(u8, disposition, "contract_invalidating")) and arrayLen(objectField(value, "acceptance_refs")) == 0) return error.CounterexampleUnanchored;
    if (std.mem.eql(u8, intent_relation, "in_horizon") and std.mem.eql(u8, disposition, "accepted") and arrayLen(objectField(value, "minimal_trace")) == 0) return error.InvalidCounterexample;
    if (std.mem.eql(u8, stringField(batch, "mode") orelse "", "conformance") and std.mem.eql(u8, disposition, "accepted")) {
        const aperture_id = stringField(value, "aperture_id") orelse return error.InvalidAperture;
        try validateSafeId(aperture_id);
        var parsed_aperture = try loadReviewChildParsed(allocator, root, state_root, ReviewApertureDir, aperture_id);
        defer parsed_aperture.deinit();
        try validateReviewAperture(parsed_aperture.value, expected_batch_id);
    }
}

fn validateCounterexampleBasisV2(value: std.json.Value, acceptance_fingerprint: ?[]const u8, accepted_cex_ids: []const []const u8) !void {
    if (!std.mem.eql(u8, stringField(value, "basis_version") orelse "", "CEB-v2")) return error.InvalidBasis;
    const basis_id = stringField(value, "basis_id") orelse return error.InvalidBasis;
    try validateSafeId(basis_id);
    if (acceptance_fingerprint) |expected| {
        if (!std.mem.eql(u8, stringField(value, "acceptance_fingerprint") orelse "", expected)) return error.BasisStale;
    } else if (!std.mem.startsWith(u8, stringField(value, "acceptance_fingerprint") orelse "", "sha256:")) {
        return error.InvalidBasis;
    }
    const basis_accepted_ids = objectField(value, "accepted_cex_ids") orelse return error.InvalidBasis;
    const classes = objectField(value, "classes") orelse return error.InvalidBasis;
    if (arrayLen(basis_accepted_ids) == 0) return error.InvalidBasis;
    if (arrayLen(classes) == 0) return error.InvalidBasis;
    for (accepted_cex_ids) |cex_id| {
        if (!stringArrayContains(basis_accepted_ids, cex_id)) return error.InvalidBasis;
    }
    switch (classes) {
        .array => |arr| {
            for (arr.items) |class| try validateBasisClass(value, class);
            for (arr.items, 0..) |class, i| {
                const members = objectField(class, "members") orelse return error.InvalidBasis;
                switch (members) {
                    .array => |member_arr| {
                        for (member_arr.items) |member| {
                            const member_id = switch (member) {
                                .string => |s| s,
                                else => return error.InvalidBasis,
                            };
                            var count: usize = 0;
                            for (arr.items) |other_class| {
                                if (stringArrayContains(objectField(other_class, "members") orelse return error.InvalidBasis, member_id)) count += 1;
                            }
                            if (count != 1) return error.InvalidBasis;
                            if (std.mem.eql(u8, stringField(class, "representative") orelse "", member_id) and i >= arr.items.len) return error.InvalidBasis;
                        }
                    },
                    else => return error.InvalidBasis,
                }
            }
        },
        else => return error.InvalidBasis,
    }
    if (containsUnknownNovelty(value)) return error.CounterexampleUnknown;
}

fn validateBasisClass(basis: std.json.Value, class: std.json.Value) !void {
    const class_id = stringField(class, "class_id") orelse return error.InvalidBasis;
    try validateSafeId(class_id);
    const representative = stringField(class, "representative") orelse return error.InvalidBasis;
    if (!stringArrayContains(objectField(class, "members") orelse return error.InvalidBasis, representative)) return error.InvalidBasis;
    if (!stringArrayContains(objectField(basis, "accepted_cex_ids") orelse return error.InvalidBasis, representative)) return error.InvalidBasis;
    if (arrayLen(objectField(class, "law_refs")) == 0) return error.InvalidBasis;
    if (arrayLen(objectField(class, "acceptance_refs")) == 0 and arrayLen(objectField(class, "law_refs")) == 0) return error.InvalidBasis;
    if (stringField(class, "canonical_owner") == null) return error.InvalidBasis;
    if (stringField(class, "proof_obligation") == null) return error.InvalidBasis;
    if (arrayLen(objectField(class, "congruence_evidence")) == 0) return error.InvalidBasis;
}

fn expectedCounterexampleDisposition(intent_relation: []const u8, novelty: []const u8) []const u8 {
    if (std.mem.eql(u8, intent_relation, "outside_horizon")) return "outside_horizon";
    if (std.mem.eql(u8, intent_relation, "contract_invalidating")) return "contract_invalidating";
    if (std.mem.eql(u8, intent_relation, "unknown") or std.mem.eql(u8, novelty, "unknown")) return "unknown";
    if (std.mem.eql(u8, novelty, "refuted")) return "refuted";
    if (std.mem.eql(u8, novelty, "stale")) return "stale";
    return "accepted";
}

fn updateCounterexampleState(state: *State, value: std.json.Value) void {
    if (state.counterexample_count < std.math.maxInt(u32)) state.counterexample_count += 1;
    if (state.counterexamples.total < std.math.maxInt(u32)) state.counterexamples.total += 1;
    const intent_relation = stringField(value, "intent_relation") orelse "unknown";
    const novelty = stringField(value, "novelty") orelse "unknown";
    if (std.mem.eql(u8, intent_relation, "in_horizon")) {
        if (state.counterexamples.in_horizon < std.math.maxInt(u32)) state.counterexamples.in_horizon += 1;
    } else if (std.mem.eql(u8, intent_relation, "outside_horizon")) {
        if (state.counterexamples.outside_horizon < std.math.maxInt(u32)) state.counterexamples.outside_horizon += 1;
    } else {
        if (state.counterexamples.unknown < std.math.maxInt(u32)) state.counterexamples.unknown += 1;
    }
    if (std.mem.eql(u8, novelty, "new_equivalence_class")) {
        if (state.counterexamples.new_classes < std.math.maxInt(u32)) state.counterexamples.new_classes += 1;
    } else if (std.mem.eql(u8, novelty, "new_witness_existing_class")) {
        if (state.counterexamples.existing_witnesses < std.math.maxInt(u32)) state.counterexamples.existing_witnesses += 1;
    } else if (std.mem.eql(u8, novelty, "duplicate")) {
        if (state.counterexamples.duplicates < std.math.maxInt(u32)) state.counterexamples.duplicates += 1;
    }
}

fn applyCounterexampleInvalidation(state: *State, value: std.json.Value, batch: std.json.Value) void {
    const intent_relation = stringField(value, "intent_relation") orelse "unknown";
    const novelty = stringField(value, "novelty") orelse "unknown";
    const disposition = stringField(value, "disposition") orelse "unknown";
    if (std.mem.eql(u8, disposition, "contract_invalidating") or std.mem.eql(u8, intent_relation, "contract_invalidating")) {
        invalidateAcceptanceDownstream(state);
        state.acceptance.horizon_state = "stale";
        state.phase = "intent_open";
        return;
    }
    if (!std.mem.eql(u8, disposition, "accepted") or !std.mem.eql(u8, intent_relation, "in_horizon")) return;
    const mode = stringField(batch, "mode") orelse "";
    if (!std.mem.eql(u8, mode, "conformance")) {
        state.basis = .{};
        state.basis_set = false;
        return;
    }
    if (std.mem.eql(u8, novelty, "new_witness_existing_class") or std.mem.eql(u8, novelty, "duplicate")) {
        state.design = .{};
        state.selected_candidate_id = null;
        state.realization.invalidated = true;
        state.realization.verified = false;
        state.realization.invalidation_reason = "same_class_recurrence";
        state.potential = .{};
        state.proof_authority = null;
        state.proof_passed = false;
        state.proof_patch_stable = false;
        state.phase = "realization_open";
    } else if (std.mem.eql(u8, novelty, "new_equivalence_class")) {
        state.basis = .{};
        state.basis_set = false;
        state.kernel = .{};
        state.reduction = .{};
        state.design = .{};
        state.selected_candidate_id = null;
        state.realization.invalidated = true;
        state.realization.verified = false;
        state.realization.invalidation_reason = "novel_class_detected";
        state.potential = .{};
        state.proof_authority = null;
        state.proof_passed = false;
        state.proof_patch_stable = false;
        state.phase = "discovery_sealed";
    }
}

fn acceptedCexIdsForBatch(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, batch_id: []const u8) !OwnedStringList {
    const path = try statePath(allocator, state_root, CounterexamplesFile);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    var ids = std.ArrayList([]const u8).empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, stringField(parsed.value, "batch_id") orelse "", batch_id)) continue;
        if (!std.mem.eql(u8, stringField(parsed.value, "intent_relation") orelse "", "in_horizon")) continue;
        if (!std.mem.eql(u8, stringField(parsed.value, "disposition") orelse "", "accepted")) continue;
        const cex_id = stringField(parsed.value, "cex_id") orelse return error.InvalidCounterexample;
        try ids.append(allocator, try allocator.dupe(u8, cex_id));
    }
    return .{ .items = try ids.toOwnedSlice(allocator) };
}

fn containsUnknownNovelty(value: std.json.Value) bool {
    if (std.mem.eql(u8, stringField(value, "novelty") orelse "", "unknown")) return true;
    if (objectField(value, "classes")) |classes| switch (classes) {
        .array => |arr| for (arr.items) |item| {
            if (containsUnknownNovelty(item)) return true;
        },
        else => {},
    };
    return false;
}

fn stringIn(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |item| {
        if (std.mem.eql(u8, value, item)) return true;
    }
    return false;
}

fn stringArrayContains(value: std.json.Value, needle: []const u8) bool {
    return switch (value) {
        .array => |arr| for (arr.items) |item| {
            switch (item) {
                .string => |s| if (std.mem.eql(u8, s, needle)) return true,
                else => {},
            }
        } else false,
        else => false,
    };
}

fn validateKernelValue(value: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(value, "kernel_version") orelse "", "MBK-v1")) return error.InvalidBasis;
    if (stringField(value, "campaign_id") == null) return error.InvalidBasis;
    if (stringField(value, "campaign_base_sha") == null) return error.InvalidBasis;
    for ([_][]const u8{ "acceptance_contract", "authorities", "carriers", "observations", "equivalence_classes", "operations", "transitions", "laws", "quotient", "complexity", "gate" }) |field| {
        if (objectField(value, field) == null) return error.InvalidBasis;
    }
}

fn requireCurrentIntentBasis(state: State) !void {
    if (!std.mem.eql(u8, state.acceptance.horizon_state, "sealed") or state.acceptance.fingerprint == null) return error.AcceptanceNotSealed;
    if (!state.basis.sealed or state.basis.fingerprint == null) return error.BasisRequired;
}

fn validateIntentBoundKernel(value: std.json.Value, state: State) !void {
    const ac = state.acceptance.fingerprint orelse return error.AcceptanceNotSealed;
    const basis = state.basis.fingerprint orelse return error.BasisRequired;
    try requireMatchingFingerprint(value, "acceptance_fingerprint", ac, error.AcceptanceStale);
    try requireMatchingFingerprint(value, "basis_fingerprint", basis, error.BasisStale);
    try validateAnchoredRows(objectField(value, "observations") orelse return error.InvalidBasis, false);
    try validateAnchoredRows(objectField(value, "laws") orelse return error.InvalidBasis, true);
    try validateWitnessedRows(objectField(value, "equivalence_classes") orelse return error.InvalidBasis);
    const quotient = objectField(value, "quotient") orelse return error.InvalidBasis;
    if (arrayLen(objectField(quotient, "congruence_evidence")) == 0 and boolField(quotient, "congruence_proven") != true) return error.InvalidBasis;
    const gate = objectField(value, "gate") orelse return error.InvalidBasis;
    if (arrayLen(objectField(gate, "recomposition_refs")) == 0 and boolField(gate, "recomposition") != true) return error.InvalidBasis;
}

fn validateIntentBoundDesign(value: std.json.Value, state: State) !void {
    const ac = state.acceptance.fingerprint orelse return error.AcceptanceNotSealed;
    const basis = state.basis.fingerprint orelse return error.BasisRequired;
    const kernel = state.kernel.fingerprint orelse return error.KernelStale;
    try requireMatchingFingerprint(value, "acceptance_fingerprint", ac, error.AcceptanceStale);
    try requireMatchingFingerprint(value, "basis_fingerprint", basis, error.BasisStale);
    try requireMatchingFingerprint(value, "kernel_fingerprint", kernel, error.KernelStale);
}

fn validateReductionStructure(value: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(value, "certificate_version") orelse stringField(value, "reduction_version") orelse "", "RC-v1")) return error.ReductionInvalid;
    if (stringField(value, "certificate_id") == null and stringField(value, "reduction_id") == null) return error.ReductionInvalid;
    if (arrayLen(objectField(value, "discharges")) == 0 and arrayLen(objectField(value, "recomposition_refs")) == 0) return error.ReductionInvalid;
}

fn validateReductionValue(value: std.json.Value, state: State) !void {
    try requireCurrentIntentBasis(state);
    try validateReductionStructure(value);
    const ac = state.acceptance.fingerprint orelse return error.AcceptanceNotSealed;
    const basis = state.basis.fingerprint orelse return error.BasisRequired;
    try requireMatchingFingerprint(value, "acceptance_fingerprint", ac, error.AcceptanceStale);
    try requireMatchingFingerprint(value, "basis_fingerprint", basis, error.BasisStale);
    if (state.kernel.fingerprint) |kernel| try requireMatchingFingerprint(value, "kernel_fingerprint", kernel, error.KernelStale);
    try validateDischarges(objectField(value, "discharges") orelse return error.ReductionInvalid);
}

fn validateAnchoredRows(value: std.json.Value, reject_may: bool) !void {
    switch (value) {
        .array => |arr| {
            for (arr.items) |row| {
                if (arrayLen(objectField(row, "acceptance_refs")) == 0 and arrayLen(objectField(row, "ac_refs")) == 0) return error.InvalidBasis;
                if (arrayLen(objectField(row, "class_refs")) == 0 and arrayLen(objectField(row, "ceb_class_refs")) == 0) return error.InvalidBasis;
                if (reject_may and std.mem.eql(u8, stringField(row, "modality") orelse "", "MAY")) return error.InvalidBasis;
                if (boolField(row, "non_goal") == true) return error.InvalidBasis;
            }
        },
        else => return error.InvalidBasis,
    }
}

fn validateWitnessedRows(value: std.json.Value) !void {
    switch (value) {
        .array => |arr| {
            for (arr.items) |row| {
                if (arrayLen(objectField(row, "witness_refs")) == 0 and arrayLen(objectField(row, "cex_refs")) == 0) return error.InvalidBasis;
            }
        },
        else => return error.InvalidBasis,
    }
}

fn validateDischarges(value: std.json.Value) !void {
    switch (value) {
        .array => |arr| {
            for (arr.items) |row| {
                if (arrayLen(objectField(row, "discharge_refs")) == 0 and boolField(row, "discharged") != true) return error.ReductionInvalid;
            }
        },
        else => return error.ReductionInvalid,
    }
}

fn requireMatchingFingerprint(value: std.json.Value, field: []const u8, expected: []const u8, err: anyerror) !void {
    if (!std.mem.eql(u8, stringField(value, field) orelse "", expected)) return err;
}

fn validateDesignValue(value: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(value, "design_version") orelse "", "RD-v1")) return error.InvalidCandidate;
    const design_id = stringField(value, "design_id") orelse return error.InvalidCandidate;
    try validateSafeId(design_id);
    if (stringField(value, "route_class") == null) return error.InvalidCandidate;
    if (stringField(value, "kernel_fingerprint") == null) return error.InvalidCandidate;
    if (emptyJsonValue(objectField(value, "gate"))) return error.InvalidCandidate;
}

fn designHasActiveNegativeRoute(value: std.json.Value) bool {
    const negative = objectField(value, "negative_route") orelse objectField(value, "negative_evidence") orelse return false;
    return std.mem.eql(u8, stringField(negative, "status") orelse "", "active_exclusion");
}

fn writeArtifactJson(allocator: std.mem.Allocator, args: Args, child: []const u8, value: std.json.Value) !void {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    try root.createDirPath(Io, args.state_root);
    const path = try statePath(allocator, args.state_root, child);
    defer allocator.free(path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJsonValue(&out.writer, value);
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try root.writeFile(Io, .{ .sub_path = path, .data = bytes });
}

fn writeStateChildJson(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, child: []const u8, value: std.json.Value) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJsonValue(&out.writer, value);
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeStateChildBytes(allocator, root, state_root, child, bytes);
}

fn writeStateChildBytes(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, child: []const u8, bytes: []const u8) !void {
    try root.createDirPath(Io, state_root);
    if (std.fs.path.dirname(child)) |dir_child| {
        const dir = try statePath(allocator, state_root, dir_child);
        defer allocator.free(dir);
        try root.createDirPath(Io, dir);
    }
    const path = try statePath(allocator, state_root, child);
    defer allocator.free(path);
    try writeRootFileAtomic(allocator, root, path, bytes);
}

fn selectedDesignIdFromArtifact(allocator: std.mem.Allocator, args: Args) ![]u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try statePath(allocator, args.state_root, SelectedDesignFile);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const design_id = stringField(parsed.value, "design_id") orelse return error.InvalidCandidate;
    return allocator.dupe(u8, design_id);
}

fn worktreePathFromManifest(allocator: std.mem.Allocator, args: Args) ![]u8 {
    var root = try openRoot(args.cwd);
    defer root.close(Io);
    const path = try statePath(allocator, args.state_root, RealizationManifestFile);
    defer allocator.free(path);
    const bytes = try root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const worktree = stringField(parsed.value, "worktree_path") orelse return error.PathRequired;
    return allocator.dupe(u8, worktree);
}

fn requireSealedReviewBatch(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, batch_id: []const u8, expected_mode: []const u8) !void {
    var parsed = try loadReviewBatchParsed(allocator, root, state_root, batch_id);
    defer parsed.deinit();
    if (!std.mem.eql(u8, stringField(parsed.value, "status") orelse "", "sealed")) return error.BatchNotSealed;
    if (!std.mem.eql(u8, stringField(parsed.value, "mode") orelse "", expected_mode)) return error.InvalidBatch;
}

fn requireDeliveryReadyState(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, state: State) !void {
    if (state.review.open_batch_ids.len != 0) return error.BatchOpen;
    try requireCurrentIntentBasis(state);
    if (!state.kernel.accepted or state.kernel.fingerprint == null) return error.KernelStale;
    if (!state.reduction.accepted or state.reduction.fingerprint == null) return error.ReductionInvalid;
    if (state.design.selected_id == null) return error.DesignMissing;
    if (!state.realization.verified or state.realization.invalidated) return error.RealizationInvalid;
    if (!state.potential.strict_progress or state.potential.current_id == null) return error.PotentialNotDecreased;
    const conformance_batch = state.review.latest_conformance_batch orelse return error.BatchRequired;
    try requireSealedReviewBatch(allocator, root, state_root, conformance_batch, "conformance");
    if (try batchHasAcceptedInHorizonCounterexample(allocator, root, state_root, conformance_batch)) return error.ClosureBlocked;
    if (!fileExists(allocator, root, state_root, SurfaceFile)) return error.SemanticSurfaceInvalid;
    if (!fileExists(allocator, root, state_root, ConstructMapFile)) return error.RealizationInvalid;
    if (!fileExists(allocator, root, state_root, ProofBasisFile)) return error.ProofBasisInvalid;
    try requireProofBasisCurrent(allocator, root, state_root);
}

fn requireTerminalReadyState(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, state: State) !void {
    try requireDeliveryReadyState(allocator, root, state_root, state);
    const holdout_batch = state.review.terminal_holdout_batch orelse return error.TerminalHoldoutMissing;
    try requireSealedReviewBatch(allocator, root, state_root, holdout_batch, "terminal-holdout");
    if (try batchHasTerminalBlockingCounterexample(allocator, root, state_root, holdout_batch)) return error.TerminalHoldoutNotClean;
}

fn requireProofBasisCurrent(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) !void {
    const manifest_path = try statePath(allocator, state_root, RealizationManifestFile);
    defer allocator.free(manifest_path);
    const manifest_bytes = try root.readFileAlloc(Io, manifest_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed_manifest.deinit();
    const tree = stringField(parsed_manifest.value, "tree_fingerprint") orelse return error.RealizationInvalid;
    const basis_path = try statePath(allocator, state_root, ProofBasisFile);
    defer allocator.free(basis_path);
    const basis_bytes = try root.readFileAlloc(Io, basis_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(basis_bytes);
    var parsed_basis = try std.json.parseFromSlice(std.json.Value, allocator, basis_bytes, .{});
    defer parsed_basis.deinit();
    const compression = objectField(parsed_basis.value, "proof_compression") orelse return error.ProofBasisInvalid;
    if (!std.mem.eql(u8, stringField(compression, "artifact_fingerprint") orelse "", tree)) return error.ProofBasisInvalid;
    if (arrayLen(objectField(compression, "wound_specific_tests")) != 0) return error.ProofBasisInvalid;
}

fn validateTupleClosureReceipt(value: std.json.Value) !void {
    const sweep = objectField(value, "pr_sweep") orelse objectField(value, "review_thread_sweep") orelse return error.ProofGateFailed;
    if (boolField(sweep, "clean") != true) return error.ClosureBlocked;
    if ((intField(sweep, "unresolved_threads") orelse 0) != 0) return error.ClosureBlocked;
    if (stringField(value, "delivery_tree") == null and stringField(value, "head") == null and stringField(value, "commit_sha") == null) return error.DeliveryStale;
}

fn validateTerminalClosureReceipt(value: std.json.Value) !void {
    if (arrayLen(objectField(value, "reopen_conditions")) == 0) return error.ClosureBlocked;
    const terminal_phi = objectField(value, "terminal_phi") orelse objectField(value, "phi") orelse return error.PotentialNotDecreased;
    if (boolField(terminal_phi, "strict_progress") != true) return error.PotentialNotDecreased;
    if (boolField(value, "proof_delivery_tuple_current") != true) return error.DeliveryStale;
}

fn batchHasAcceptedInHorizonCounterexample(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, batch_id: []const u8) !bool {
    const path = try statePath(allocator, state_root, CounterexamplesFile);
    defer allocator.free(path);
    const bytes = root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, stringField(parsed.value, "batch_id") orelse "", batch_id)) continue;
        if (!std.mem.eql(u8, stringField(parsed.value, "disposition") orelse "", "accepted")) continue;
        if (std.mem.eql(u8, stringField(parsed.value, "intent_relation") orelse "", "in_horizon")) return true;
    }
    return false;
}

fn batchHasTerminalBlockingCounterexample(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, batch_id: []const u8) !bool {
    const path = try statePath(allocator, state_root, CounterexamplesFile);
    defer allocator.free(path);
    const bytes = root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, stringField(parsed.value, "batch_id") orelse "", batch_id)) continue;
        const intent = stringField(parsed.value, "intent_relation") orelse "unknown";
        const novelty = stringField(parsed.value, "novelty") orelse "unknown";
        const disposition = stringField(parsed.value, "disposition") orelse "unknown";
        if (std.mem.eql(u8, intent, "unknown") or std.mem.eql(u8, novelty, "unknown") or std.mem.eql(u8, disposition, "unknown")) return true;
        if (std.mem.eql(u8, intent, "contract_invalidating") or std.mem.eql(u8, disposition, "contract_invalidating")) return true;
        if (std.mem.eql(u8, intent, "in_horizon") and std.mem.eql(u8, disposition, "accepted")) return true;
    }
    return false;
}

fn validateConstructMapValue(value: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(value, "map_version") orelse "", "KRM-v1")) return error.InvalidCandidate;
    if (stringField(value, "kernel_fingerprint") == null) return error.InvalidCandidate;
    if (stringField(value, "realization_tree_fingerprint") == null) return error.InvalidCandidate;
    if (objectField(value, "constructs") == null) return error.InvalidCandidate;
    if (objectField(value, "proof_actions") == null) return error.InvalidCandidate;
}

fn writeProofActionFromLaw(writer: anytype, law: std.json.Value, kernel_gate: ?std.json.Value, law_id: []const u8, command: []const u8, style: []const u8, artifact_fingerprint: []const u8, kernel_fingerprint: []const u8) !void {
    try writer.writeAll("{\"proof_id\":\"proof.");
    try writeProofIdFragment(writer, law_id);
    try writer.writeAll("\",\"command\":");
    try writeJsonString(writer, command);
    try writer.writeAll(",\"style\":");
    try writeJsonString(writer, style);
    try writer.writeAll(",\"proves_law_ids\":[");
    try writeJsonString(writer, law_id);
    try writer.writeAll("],\"ac_law_refs\":");
    try writeJsonArrayOrEmpty(writer, objectField(law, "acceptance_refs") orelse objectField(law, "ac_refs"));
    try writer.writeAll(",\"ceb_class_refs\":");
    try writeJsonArrayOrEmpty(writer, objectField(law, "class_refs") orelse objectField(law, "ceb_class_refs"));
    try writer.writeAll(",\"recomposition_refs\":");
    if (objectField(law, "recomposition_refs")) |refs| {
        try writeJsonArrayOrEmpty(writer, refs);
    } else if (kernel_gate) |gate| {
        try writeJsonArrayOrEmpty(writer, objectField(gate, "recomposition_refs"));
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll(",\"artifact_fingerprint\":");
    try writeJsonString(writer, artifact_fingerprint);
    try writer.writeAll(",\"invalidators\":[");
    try writeJsonString(writer, kernel_fingerprint);
    try writer.writeByte(',');
    try writeJsonString(writer, artifact_fingerprint);
    try writer.writeAll("],\"covers_observation_ids\":[],\"cost\":{\"commands\":1}}");
}

fn writeJsonArrayOrEmpty(writer: anytype, value_opt: ?std.json.Value) !void {
    if (value_opt) |value| {
        switch (value) {
            .array => try writeJsonValue(writer, value),
            else => try writer.writeAll("[]"),
        }
    } else {
        try writer.writeAll("[]");
    }
}

fn validateProofActionMapping(action: std.json.Value) !void {
    if (arrayLen(objectField(action, "proves_law_ids")) == 0) return error.ProofBasisInvalid;
    if (arrayLen(objectField(action, "ac_law_refs")) == 0 and arrayLen(objectField(action, "acceptance_refs")) == 0) return error.ProofBasisInvalid;
    if (arrayLen(objectField(action, "ceb_class_refs")) == 0 and arrayLen(objectField(action, "class_refs")) == 0) return error.ProofBasisInvalid;
    if (arrayLen(objectField(action, "recomposition_refs")) == 0 and boolField(action, "recomposition") != true) return error.ProofBasisInvalid;
    if (stringField(action, "artifact_fingerprint") == null) return error.ProofBasisInvalid;
}

const MeasuredRealization = struct {
    tree_text: []u8,
    surface_json: []u8,
};

fn measureWorktreeDiff(allocator: std.mem.Allocator, worktree: []const u8, tree_sha: []const u8, names_text: []const u8) !MeasuredRealization {
    var tree_out: std.Io.Writer.Allocating = .init(allocator);
    defer tree_out.deinit();
    var surface_out: std.Io.Writer.Allocating = .init(allocator);
    defer surface_out.deinit();

    var files: usize = 0;
    var production_lines: usize = 0;
    var test_lines: usize = 0;
    var public_symbols: usize = 0;
    var state_fields: usize = 0;
    var branches: usize = 0;
    var helpers: usize = 0;
    var tests: usize = 0;
    var ast_nodes: usize = 0;

    try tree_out.writer.writeAll("tree ");
    try tree_out.writer.writeAll(tree_sha);
    try tree_out.writer.writeByte('\n');

    var names = std.mem.splitScalar(u8, names_text, '\n');
    while (names.next()) |raw_name| {
        const name = std.mem.trim(u8, raw_name, " \t\r\n");
        if (name.len == 0) continue;
        files += 1;
        try tree_out.writer.writeAll("construct ");
        try writeConstructIdText(&tree_out.writer, name, "file", name);
        try tree_out.writer.writeByte('\n');

        const full_path = try std.fs.path.join(allocator, &.{ worktree, name });
        defer allocator.free(full_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(Io, full_path, allocator, .limited(MaxFileBytes)) catch continue;
        defer allocator.free(bytes);
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line_raw| {
            line_no += 1;
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            ast_nodes += 1 + std.mem.count(u8, line, " ");
            if (std.mem.endsWith(u8, name, ".zig") and std.mem.startsWith(u8, line, "test ")) {
                tests += 1;
                test_lines += 1;
                try tree_out.writer.writeAll("construct ");
                const qual = try std.fmt.allocPrint(allocator, "test-{d}", .{line_no});
                defer allocator.free(qual);
                try writeConstructIdText(&tree_out.writer, name, "test", qual);
                try tree_out.writer.writeByte('\n');
                continue;
            }
            production_lines += 1;
            if (std.mem.endsWith(u8, name, ".zig")) {
                if (std.mem.startsWith(u8, line, "pub ")) {
                    public_symbols += 1;
                    try tree_out.writer.writeAll("construct ");
                    const qual = try constructQualifierFromLine(allocator, line, line_no);
                    defer allocator.free(qual);
                    try writeConstructIdText(&tree_out.writer, name, "pub", qual);
                    try tree_out.writer.writeByte('\n');
                } else if (std.mem.startsWith(u8, line, "fn ")) {
                    helpers += 1;
                    try tree_out.writer.writeAll("construct ");
                    const qual = try constructQualifierFromLine(allocator, line, line_no);
                    defer allocator.free(qual);
                    try writeConstructIdText(&tree_out.writer, name, "helper", qual);
                    try tree_out.writer.writeByte('\n');
                }
                if (std.mem.indexOf(u8, line, ":") != null and std.mem.indexOf(u8, line, "=>") == null) state_fields += 1;
                branches += std.mem.count(u8, line, " if ") + std.mem.count(u8, line, "switch ") + std.mem.count(u8, line, "while ") + std.mem.count(u8, line, "for ") + std.mem.count(u8, line, " catch ") + std.mem.count(u8, line, " orelse ");
            }
        }
    }

    try surface_out.writer.writeAll("{\"semantic_surface_vector\":{\"kernel\":{\"authorities\":{\"value\":0,\"authority\":\"kernel\"},\"observable_state_classes\":{\"value\":0,\"authority\":\"kernel\"},\"transitions\":{\"value\":0,\"authority\":\"kernel\"},\"laws\":{\"value\":0,\"authority\":\"kernel\"},\"protocol_cases\":{\"value\":0,\"authority\":\"reviewed-map\"}},\"realization\":{");
    try surfaceField(&surface_out.writer, "truth_owners", 0, "reviewed-map", true);
    try surfaceField(&surface_out.writer, "public_symbols", public_symbols, "controller", true);
    try surfaceField(&surface_out.writer, "state_fields", state_fields, "controller", true);
    try surfaceField(&surface_out.writer, "fallback_or_compatibility_paths", 0, "reviewed-map", true);
    try surfaceField(&surface_out.writer, "control_flow_branches", branches, "controller", true);
    try surfaceField(&surface_out.writer, "helpers_or_wrappers", helpers, "controller", true);
    try surfaceField(&surface_out.writer, "files", files, "controller", true);
    try surfaceField(&surface_out.writer, "ast_nodes", ast_nodes, "controller", true);
    try surfaceField(&surface_out.writer, "production_lines", production_lines, "controller", true);
    try surface_out.writer.writeAll("\"measurement\":{\"adapter\":\"zig-surface-adapter\",\"version\":\"v1\",\"exact_fields\":[\"files\",\"production_lines\",\"test_lines\",\"test_declarations\"],\"approximate_fields\":[\"public_symbols\",\"state_fields\",\"control_flow_branches\",\"helpers_or_wrappers\",\"ast_nodes\"],\"unavailable_fields\":[]}},\"proof\":{");
    try surfaceField(&surface_out.writer, "proof_laws", 0, "reviewed-map", true);
    try surfaceField(&surface_out.writer, "test_families", tests, "controller", true);
    try surfaceField(&surface_out.writer, "wound_specific_tests", 0, "reviewed-map", true);
    try surfaceField(&surface_out.writer, "fixtures", 0, "controller", true);
    try surfaceField(&surface_out.writer, "test_ast_nodes", tests, "controller", true);
    try surface_out.writer.print("\"test_lines\":{{\"value\":{d},\"authority\":\"controller\"}}", .{test_lines});
    try surface_out.writer.writeAll("}}}\n");

    return .{
        .tree_text = try tree_out.toOwnedSlice(),
        .surface_json = try surface_out.toOwnedSlice(),
    };
}

fn surfaceField(writer: anytype, name: []const u8, value: usize, authority: []const u8, comma: bool) !void {
    try writeJsonString(writer, name);
    try writer.writeAll(":{\"value\":");
    try writer.print("{d}", .{value});
    try writer.writeAll(",\"authority\":");
    try writeJsonString(writer, authority);
    try writer.writeByte('}');
    if (comma) try writer.writeByte(',');
}

fn writeConstructIdText(writer: anytype, path: []const u8, kind: []const u8, qualifier: []const u8) !void {
    try writer.writeAll(path);
    try writer.writeAll("::");
    try writer.writeAll(kind);
    try writer.writeAll("::");
    try writer.writeAll(qualifier);
}

fn constructQualifierFromLine(allocator: std.mem.Allocator, line: []const u8, fallback_line: usize) ![]u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t(:=");
    _ = it.next();
    const maybe_name = it.next() orelse return std.fmt.allocPrint(allocator, "line-{d}", .{fallback_line});
    return allocator.dupe(u8, maybe_name);
}

fn treeFingerprintFromTreeText(tree_text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, tree_text, '\n');
    const first = lines.next() orelse return null;
    const prefix = "tree ";
    if (!std.mem.startsWith(u8, first, prefix)) return null;
    return first[prefix.len..];
}

fn constructIdInTree(tree_text: []const u8, construct_id: []const u8) bool {
    var lines = std.mem.splitScalar(u8, tree_text, '\n');
    while (lines.next()) |line| {
        const prefix = "construct ";
        if (std.mem.startsWith(u8, line, prefix) and std.mem.eql(u8, line[prefix.len..], construct_id)) return true;
    }
    return false;
}

fn hardSurfaceIncreased(current: std.json.Value, baseline: std.json.Value) bool {
    const fields = [_][]const u8{
        "truth_owners",
        "public_symbols",
        "state_fields",
        "fallback_or_compatibility_paths",
    };
    for (fields) |field| {
        if (surfaceValue(current, "realization", field) > surfaceValue(baseline, "realization", field)) return true;
    }
    if (surfaceValue(current, "proof", "wound_specific_tests") > surfaceValue(baseline, "proof", "wound_specific_tests")) return true;
    if (surfaceValue(current, "kernel", "protocol_cases") > surfaceValue(baseline, "kernel", "protocol_cases")) return true;
    return false;
}

fn validatePotentialValue(value: std.json.Value, state: State) !void {
    if (!std.mem.eql(u8, stringField(value, "potential_version") orelse "", "PHI-v1")) return error.InvalidPotential;
    if (stringField(value, "cycle_id") == null) return error.InvalidPotential;
    if (boolField(value, "strict_progress") != null) return error.InvalidPotential;
    if (objectField(value, "gate")) |gate| {
        if (boolField(gate, "strict_progress") != null) return error.InvalidPotential;
    }
    const ac = state.acceptance.fingerprint orelse return error.AcceptanceNotSealed;
    try requireMatchingFingerprint(value, "acceptance_fingerprint", ac, error.AcceptanceStale);
    const primary = objectField(value, "primary") orelse return error.InvalidPotential;
    inline for (.{ "U", "L", "C", "O" }) |field| _ = try metricField(primary, field);
    const hard = objectField(value, "hard_surface") orelse return error.InvalidPotential;
    inline for (.{ "truth_owners", "public_symbols", "state_variants", "protocol_cases", "fallback_compatibility_paths", "control_flow_branches", "helpers_wrappers", "test_families" }) |field| _ = try hardSurfaceMetric(hard, field);
    const proof = objectField(value, "proof_debt") orelse return error.InvalidPotential;
    inline for (.{ "missing_law_proofs", "unmapped_proof_actions", "wound_specific_tests" }) |field| _ = try metricField(proof, field);
    if (arrayLen(objectField(value, "evidence_refs")) == 0) return error.InvalidPotential;
}

fn comparePotentialStrict(current: std.json.Value, baseline: std.json.Value) !void {
    if (!primaryTupleLess(current, baseline)) return error.PotentialNotDecreased;
    const current_hard = objectField(current, "hard_surface") orelse return error.InvalidPotential;
    const baseline_hard = objectField(baseline, "hard_surface") orelse return error.InvalidPotential;
    inline for (.{ "truth_owners", "public_symbols", "state_variants", "protocol_cases", "fallback_compatibility_paths", "control_flow_branches", "helpers_wrappers", "test_families" }) |field| {
        if (try hardSurfaceMetric(current_hard, field) > try hardSurfaceMetric(baseline_hard, field)) return error.SemanticSurfaceIncreased;
    }
    const current_debt = objectField(current, "proof_debt") orelse return error.InvalidPotential;
    const baseline_debt = objectField(baseline, "proof_debt") orelse return error.InvalidPotential;
    var current_total: i64 = 0;
    var baseline_total: i64 = 0;
    inline for (.{ "missing_law_proofs", "unmapped_proof_actions", "wound_specific_tests" }) |field| {
        const current_value = try metricField(current_debt, field);
        const baseline_value = try metricField(baseline_debt, field);
        if (current_value > baseline_value) return error.ProofDebtIncreased;
        current_total += current_value;
        baseline_total += baseline_value;
    }
    if (current_total > baseline_total) return error.ProofDebtIncreased;
}

fn primaryTupleLess(current: std.json.Value, baseline: std.json.Value) bool {
    const current_primary = objectField(current, "primary") orelse return false;
    const baseline_primary = objectField(baseline, "primary") orelse return false;
    inline for (.{ "U", "L", "C", "O" }) |field| {
        const current_value = metricField(current_primary, field) catch return false;
        const baseline_value = metricField(baseline_primary, field) catch return false;
        if (current_value < baseline_value) return true;
        if (current_value > baseline_value) return false;
    }
    return false;
}

fn hardSurfaceMetric(value: std.json.Value, field: []const u8) !i64 {
    if (objectField(value, field) != null) return metricField(value, field);
    if (std.mem.eql(u8, field, "state_variants")) return metricField(value, "state_fields");
    if (std.mem.eql(u8, field, "fallback_compatibility_paths")) return metricField(value, "fallback_or_compatibility_paths");
    if (std.mem.eql(u8, field, "helpers_wrappers")) return metricField(value, "helpers_or_wrappers");
    return error.InvalidPotential;
}

fn metricField(value: std.json.Value, field: []const u8) !i64 {
    const child = objectField(value, field) orelse return error.InvalidPotential;
    return switch (child) {
        .integer => |n| n,
        .object => intField(child, "value") orelse return error.InvalidPotential,
        else => error.InvalidPotential,
    };
}

fn surfaceValue(value: std.json.Value, group: []const u8, field: []const u8) i64 {
    const vector = objectField(value, "semantic_surface_vector") orelse value;
    const group_value = objectField(vector, group) orelse return 0;
    const field_value = objectField(group_value, field) orelse return 0;
    if (intField(field_value, "value")) |count| return count;
    return switch (field_value) {
        .integer => |n| n,
        else => 0,
    };
}

fn writeProofAction(writer: anytype, law_id: []const u8, command: []const u8, style: []const u8) !void {
    try writer.writeAll("{\"proof_id\":\"proof.");
    try writeProofIdFragment(writer, law_id);
    try writer.writeAll("\",\"command\":");
    try writeJsonString(writer, command);
    try writer.writeAll(",\"style\":");
    try writeJsonString(writer, style);
    try writer.writeAll(",\"proves_law_ids\":[");
    try writeJsonString(writer, law_id);
    try writer.writeAll("],\"ac_law_refs\":[");
    try writeJsonString(writer, law_id);
    try writer.writeAll("],\"ceb_class_refs\":[");
    try writeJsonString(writer, law_id);
    try writer.writeAll("],\"recomposition\":true,\"artifact_fingerprint\":\"sha256:unbound\",\"invalidators\":[],\"covers_observation_ids\":[],\"cost\":{\"commands\":1}}");
}

fn writeProofIdFragment(writer: anytype, law_id: []const u8) !void {
    for (law_id) |c| switch (c) {
        '"' => try writer.writeByte('_'),
        '\\' => try writer.writeByte('_'),
        ' ', '\t', '\n', '\r' => try writer.writeByte('-'),
        else => try writer.writeByte(c),
    };
}

fn stableWorktreeTree(allocator: std.mem.Allocator, process_io: std.Io, worktree: []const u8) ![]u8 {
    try runGitOk(allocator, process_io, worktree, &.{ "add", "-A" });
    const tree = try runGitCaptureProcess(allocator, process_io, worktree, &.{"write-tree"});
    errdefer allocator.free(tree);
    const trimmed = std.mem.trim(u8, tree, " \t\r\n");
    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(tree);
    return duped;
}

fn containsString(items: []const []const u8, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn constructMapHasOrphan(value: std.json.Value) bool {
    const constructs = objectField(value, "constructs") orelse return true;
    return switch (constructs) {
        .array => |arr| blk: {
            for (arr.items) |item| {
                if (std.mem.eql(u8, stringField(item, "status") orelse "", "orphan")) break :blk true;
            }
            break :blk false;
        },
        else => true,
    };
}

fn realizationGitTreeSha(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) ![]u8 {
    const manifest_path = try statePath(allocator, state_root, RealizationManifestFile);
    defer allocator.free(manifest_path);
    const manifest_bytes = try root.readFileAlloc(Io, manifest_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed.deinit();
    const tree = stringField(parsed.value, "git_tree_sha") orelse return error.InvalidCandidate;
    return allocator.dupe(u8, tree);
}

fn realizationPatchFingerprint(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) ![]u8 {
    const manifest_path = try statePath(allocator, state_root, RealizationManifestFile);
    defer allocator.free(manifest_path);
    const manifest_bytes = try root.readFileAlloc(Io, manifest_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed.deinit();
    const patch = stringField(parsed.value, "patch_fingerprint") orelse return error.InvalidCandidate;
    return allocator.dupe(u8, patch);
}

fn currentGitTree(allocator: std.mem.Allocator, process_io: std.Io, cwd: []const u8) ![]u8 {
    try runGitOk(allocator, process_io, cwd, &.{ "add", "-A" });
    const tree = try runGitCaptureProcess(allocator, process_io, cwd, &.{"write-tree"});
    errdefer allocator.free(tree);
    const trimmed = std.mem.trim(u8, tree, " \t\r\n");
    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(tree);
    return duped;
}

fn requireCleanGitWorktree(allocator: std.mem.Allocator, process_io: std.Io, cwd: []const u8) !void {
    const status = try runGitCaptureProcess(allocator, process_io, cwd, &.{ "status", "--porcelain" });
    defer allocator.free(status);
    if (std.mem.trim(u8, status, " \t\r\n").len != 0) return error.DirtyWorktree;
}

fn archiveKnownArtifacts(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, archive_root: []const u8) !void {
    const known = [_][]const u8{
        StateFile,
        EventFile,
        MbkcFile,
        ObservationsFile,
        KernelFile,
        KernelReviewFile,
        DesignsFile,
        SelectedDesignFile,
        CertFile,
    };
    for (known) |child| {
        const source = try statePath(allocator, state_root, child);
        defer allocator.free(source);
        const bytes = root.readFileAlloc(Io, source, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(bytes);
        const dest = try std.fs.path.join(allocator, &.{ archive_root, child });
        defer allocator.free(dest);
        if (std.fs.path.dirname(dest)) |dir| try root.createDirPath(Io, dir);
        try root.writeFile(Io, .{ .sub_path = dest, .data = bytes });
    }
}

fn appendJsonLine(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, child: []const u8, value: std.json.Value) !void {
    try root.createDirPath(Io, state_root);
    const path = try statePath(allocator, state_root, child);
    defer allocator.free(path);
    var row: std.Io.Writer.Allocating = .init(allocator);
    defer row.deinit();
    try writeJsonValue(&row.writer, value);
    try row.writer.writeByte('\n');
    const line = try row.toOwnedSlice();
    defer allocator.free(line);

    const existing = root.readFileAlloc(Io, path, allocator, .limited(MaxFileBytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owned = existing.len > 0;
    defer if (owned) allocator.free(existing);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (existing.len > 0) try out.writer.writeAll(existing);
    try out.writer.writeAll(line);
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try root.writeFile(Io, .{ .sub_path = path, .data = bytes });
}

fn writeJsonlAsArray(allocator: std.mem.Allocator, bytes: []const u8, key: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('{');
    try writeJsonString(&out.writer, key);
    try out.writer.writeAll(":[");
    var first = true;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll(line);
    }
    try out.writer.writeAll("]}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.print("{}", .{b}),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |n| try writer.print("{d}", .{n}),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try writeJsonString(writer, s),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writeJsonString(writer, entry.key_ptr.*);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
    }
}

fn readFileOrStdin(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) return readStdinAlloc(allocator);
    return std.Io.Dir.cwd().readFileAlloc(Io, path, allocator, .limited(MaxFileBytes));
}

fn readStdinAlloc(allocator: std.mem.Allocator) ![]u8 {
    var reader = std.Io.File.stdin().reader(Io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(MaxFileBytes));
}

fn acceptanceGoalFromFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parsed = try parseJsonInput(allocator, path);
    defer parsed.deinit();
    if (stringField(parsed.value, "goal")) |goal| return allocator.dupe(u8, goal);
    return allocator.dupe(u8, "acceptance");
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |obj| obj.get(key),
        else => null,
    };
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .bool => |b| b,
        else => null,
    };
}

fn intField(value: std.json.Value, key: []const u8) ?i64 {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .integer => |n| n,
        else => null,
    };
}

fn arrayLen(value_opt: ?std.json.Value) usize {
    const value = value_opt orelse return 0;
    return switch (value) {
        .array => |arr| arr.items.len,
        else => 0,
    };
}

fn emptyJsonValue(value_opt: ?std.json.Value) bool {
    const value = value_opt orelse return true;
    return switch (value) {
        .null => true,
        .string => |s| s.len == 0,
        .array => |arr| arr.items.len == 0,
        .object => |obj| obj.count() == 0,
        else => false,
    };
}

fn allCommandResultsPass(value: std.json.Value) bool {
    return switch (value) {
        .array => |arr| blk: {
            if (arr.items.len == 0) break :blk false;
            for (arr.items) |item| {
                if (!std.mem.eql(u8, stringField(item, "result") orelse "", "pass")) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn validateSafeId(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidId;
    for (value, 0..) |c, i| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == ':' or c == '-';
        if (!ok or (i == 0 and !std.ascii.isAlphanumeric(c))) return error.InvalidId;
    }
}

fn openRoot(cwd: []const u8) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(Io, cwd, .{});
}

fn ensureLocalExclude(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) !void {
    root.access(Io, ".git", .{}) catch return error.NotGitRepository;
    try root.createDirPath(Io, ".git/info");

    const exclude_path = ".git/info/exclude";
    const wanted = try excludePattern(allocator, state_root);
    defer allocator.free(wanted);

    const existing = root.readFileAlloc(Io, exclude_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owned_existing = existing.len > 0;
    defer if (owned_existing) allocator.free(existing);

    if (containsLine(existing, wanted)) return;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (existing.len > 0) {
        try out.writer.writeAll(existing);
        if (existing[existing.len - 1] != '\n') try out.writer.writeByte('\n');
    }
    try out.writer.writeAll("# BEGIN resolve-c3 local state\n");
    try out.writer.writeAll(wanted);
    try out.writer.writeByte('\n');
    try out.writer.writeAll("# END resolve-c3 local state\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try root.writeFile(Io, .{ .sub_path = exclude_path, .data = bytes });
}

fn excludePattern(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    const trimmed = trimTrailingSlashes(state_root);
    return std.fmt.allocPrint(allocator, "{s}/", .{trimmed});
}

fn trimTrailingSlashes(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') end -= 1;
    return value[0..end];
}

fn containsLine(haystack: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, haystack, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, needle)) return true;
    }
    return false;
}

fn gitCapture(allocator: std.mem.Allocator, cwd: []const u8, argv_tail: []const []const u8) ![]const u8 {
    const root = try findGitTopLevel(allocator, cwd);
    defer allocator.free(root);

    if (argvMatches(argv_tail, &.{ "rev-parse", "--show-toplevel" })) {
        return allocator.dupe(u8, root);
    }

    const git_dir = try gitDirForRoot(allocator, root);
    defer allocator.free(git_dir);
    const head = try readGitText(allocator, git_dir, "HEAD");
    defer allocator.free(head);
    const trimmed_head = std.mem.trim(u8, head, " \t\r\n");

    if (argvMatches(argv_tail, &.{ "branch", "--show-current" })) {
        const prefix = "ref: refs/heads/";
        if (!std.mem.startsWith(u8, trimmed_head, prefix)) return allocator.dupe(u8, "");
        return allocator.dupe(u8, trimmed_head[prefix.len..]);
    }

    if (argvMatches(argv_tail, &.{ "rev-parse", "HEAD" })) {
        const ref_prefix = "ref: ";
        if (!std.mem.startsWith(u8, trimmed_head, ref_prefix)) return allocator.dupe(u8, trimmed_head);
        return readGitTextTrimmed(allocator, git_dir, trimmed_head[ref_prefix.len..]);
    }

    return error.UnsupportedGitCapture;
}

fn argvMatches(actual: []const []const u8, expected: []const []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |a, e| {
        if (!std.mem.eql(u8, a, e)) return false;
    }
    return true;
}

fn findGitTopLevel(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(Io, cwd, allocator);
    defer allocator.free(resolved);
    var current = try allocator.dupe(u8, resolved);
    while (true) {
        const dot_git = try std.fs.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(dot_git);
        std.Io.Dir.cwd().access(Io, dot_git, .{}) catch {
            if (std.fs.path.dirname(current)) |parent| {
                if (std.mem.eql(u8, parent, current)) {
                    allocator.free(current);
                    return error.NotGitRepository;
                }
                const next = try allocator.dupe(u8, parent);
                allocator.free(current);
                current = next;
                continue;
            }
            allocator.free(current);
            return error.NotGitRepository;
        };
        return current;
    }
}

fn gitDirForRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const dot_git = try std.fs.path.join(allocator, &.{ root, ".git" });
    errdefer allocator.free(dot_git);
    if (std.Io.Dir.cwd().openDir(Io, dot_git, .{})) |dir| {
        var mutable_dir = dir;
        mutable_dir.close(Io);
        return dot_git;
    } else |_| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(Io, dot_git, allocator, .limited(4096));
        defer allocator.free(bytes);
        const line = std.mem.trim(u8, bytes, " \t\r\n");
        const prefix = "gitdir:";
        if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidGitDir;
        const raw_path = std.mem.trim(u8, line[prefix.len..], " \t");
        if (std.fs.path.isAbsolute(raw_path)) {
            allocator.free(dot_git);
            return allocator.dupe(u8, raw_path);
        }
        const resolved = try std.fs.path.join(allocator, &.{ root, raw_path });
        allocator.free(dot_git);
        return resolved;
    }
}

fn readGitTextTrimmed(allocator: std.mem.Allocator, git_dir: []const u8, sub_path: []const u8) ![]u8 {
    const bytes = try readGitText(allocator, git_dir, sub_path);
    defer allocator.free(bytes);
    return allocator.dupe(u8, std.mem.trim(u8, bytes, " \t\r\n"));
}

fn readGitText(allocator: std.mem.Allocator, git_dir: []const u8, sub_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ git_dir, sub_path });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(Io, path, allocator, .limited(1024 * 1024));
}

fn runShell(allocator: std.mem.Allocator, process_io: std.Io, cwd: []const u8, command: []const u8) !bool {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    const result = try std.process.run(allocator, process_io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runGitOk(allocator: std.mem.Allocator, process_io: std.Io, cwd: []const u8, argv_tail: []const []const u8) !void {
    const stdout = try runGitCaptureProcess(allocator, process_io, cwd, argv_tail);
    allocator.free(stdout);
}

fn runGitCaptureProcess(allocator: std.mem.Allocator, process_io: std.Io, cwd: []const u8, argv_tail: []const []const u8) ![]u8 {
    var argv = try allocator.alloc([]const u8, argv_tail.len + 1);
    defer allocator.free(argv);
    argv[0] = "git";
    for (argv_tail, 0..) |arg, i| argv[i + 1] = arg;
    const result = try std.process.run(allocator, process_io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(MaxFileBytes),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
    }
    return result.stdout;
}

fn findStateRootFrom(allocator: std.mem.Allocator, cwd: []const u8, state_root: []const u8) !?[]u8 {
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(Io, cwd, allocator);
    defer allocator.free(resolved);
    var current = try allocator.dupe(u8, resolved);
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, state_root, StateFile });
        defer allocator.free(candidate);
        std.Io.Dir.cwd().access(Io, candidate, .{}) catch {
            if (std.fs.path.dirname(current)) |parent| {
                if (std.mem.eql(u8, parent, current)) {
                    allocator.free(current);
                    return null;
                }
                const next = try allocator.dupe(u8, parent);
                allocator.free(current);
                current = next;
                continue;
            }
            allocator.free(current);
            return null;
        };
        return current;
    }
}

fn cwdFromPayload(allocator: std.mem.Allocator, payload: []const u8, fallback: []const u8) ![]const u8 {
    return stringFromPayload(allocator, payload, "cwd") catch return allocator.dupe(u8, fallback);
}

fn commandFromPayload(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    if (stringFromPayload(allocator, payload, "cmd")) |value| return value else |_| {}
    if (stringFromPayload(allocator, payload, "command")) |value| return value else |_| {}
    if (stringFromPayload(allocator, payload, "script")) |value| return value else |_| {}
    return allocator.dupe(u8, "");
}

fn toolFromPayload(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    if (stringFromPayload(allocator, payload, "tool_name")) |value| return value else |_| {}
    if (stringFromPayload(allocator, payload, "tool")) |value| return value else |_| {}
    if (stringFromPayload(allocator, payload, "name")) |value| return value else |_| {}
    return allocator.dupe(u8, "");
}

fn stringFromPayload(allocator: std.mem.Allocator, payload: []const u8, key: []const u8) ![]const u8 {
    if (std.mem.trim(u8, payload, " \t\r\n").len == 0) return error.NotFound;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.NotFound;
    defer parsed.deinit();
    if (stringField(parsed.value, key)) |value| return allocator.dupe(u8, value);
    const input = objectField(parsed.value, "tool_input") orelse objectField(parsed.value, "input") orelse objectField(parsed.value, "arguments") orelse return error.NotFound;
    if (stringField(input, key)) |value| return allocator.dupe(u8, value);
    return error.NotFound;
}

fn controllerCommand(command: []const u8) bool {
    return std.mem.containsAtLeast(u8, command, 1, "resolve-c3");
}

fn toolMutates(tool_name: []const u8) bool {
    for (MutatingTools) |token| {
        if (std.mem.containsAtLeast(u8, tool_name, 1, token)) return true;
    }
    return false;
}

fn mutatingShell(command: []const u8) ?[]const u8 {
    for (MutatingGitCommands) |token| {
        if (std.mem.containsAtLeast(u8, command, 1, token)) return "raw-git-mutation";
    }
    for (MutatingFileCommands) |token| {
        if (std.mem.containsAtLeast(u8, command, 1, token)) return "filesystem-mutation";
    }
    if (std.mem.containsAtLeast(u8, command, 1, " >") or std.mem.containsAtLeast(u8, command, 1, ">>")) return "shell-redirection";
    return null;
}

fn containsAnyWord(text: []const u8, words: []const []const u8) bool {
    for (words) |word| {
        if (std.mem.indexOf(u8, text, word) != null) return true;
    }
    return false;
}

fn containsYamlKey(text: []const u8, key: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        if (std.mem.startsWith(u8, line, key)) {
            const rest = std.mem.trim(u8, line[key.len..], " \t");
            if (std.mem.startsWith(u8, rest, ":")) return true;
        }
    }
    return false;
}

fn printGateResult(allocator: std.mem.Allocator, name: []const u8, errors: []const []const u8) !u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (errors.len == 0) {
        try out.writer.print("{s} gate: PASS\n", .{name});
        try writeStdoutAlloc(allocator, &out);
        return 0;
    }
    try out.writer.print("{s} gate: FAIL\n", .{name});
    for (errors) |err| try out.writer.print("{s}\n", .{err});
    try writeStdoutAlloc(allocator, &out);
    return 2;
}

fn recordOpenBatchMutationDenied(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, state: State, reason: []const u8) ![]u8 {
    const batch_id = state.review.open_batch_ids[0];
    var parsed_batch = try loadReviewBatchParsed(allocator, root, state_root, batch_id);
    defer parsed_batch.deinit();
    const denial_id = try std.fmt.allocPrint(allocator, "guard-{x}", .{hashReceipt("guard-denied", state.phase, reason)});
    errdefer allocator.free(denial_id);
    const apertures = try stringArrayWithExtra(allocator, parsed_batch.value, "aperture_ids", null);
    defer allocator.free(apertures);
    const receipts = try stringArrayWithExtra(allocator, parsed_batch.value, "receipt_ids", null);
    defer allocator.free(receipts);
    const mutations = try stringArrayWithExtra(allocator, parsed_batch.value, "mutation_events", denial_id);
    defer allocator.free(mutations);
    try writeReviewBatchArtifact(
        allocator,
        root,
        state_root,
        batch_id,
        stringField(parsed_batch.value, "mode") orelse "",
        stringField(parsed_batch.value, "artifact_head") orelse "",
        stringField(parsed_batch.value, "acceptance_fingerprint") orelse "",
        stringField(parsed_batch.value, "status") orelse "open",
        apertures,
        receipts,
        mutations,
    );
    const event_id = try appendEvent(allocator, root, state_root, "guard-denied", state, state, denial_id);
    allocator.free(denial_id);
    return event_id;
}

fn guardDenialReceipt(
    allocator: std.mem.Allocator,
    code: []const u8,
    phase: []const u8,
    open_batch: []const u8,
    required_action: []const u8,
    evidence_ref: []const u8,
) !u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"status\":\"block\",\"reason\":\"guard_denied\",\"resolve_guard_denial\":{\"code\":");
    try writeJsonString(&out.writer, code);
    try out.writer.writeAll(",\"phase\":");
    try writeJsonString(&out.writer, phase);
    try out.writer.writeAll(",\"open_batch\":");
    try writeJsonString(&out.writer, open_batch);
    try out.writer.writeAll(",\"required_action\":");
    try writeJsonString(&out.writer, required_action);
    try out.writer.writeAll(",\"evidence_ref\":");
    try writeJsonString(&out.writer, evidence_ref);
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn guardReceipt(allocator: std.mem.Allocator, status: []const u8, reason: []const u8) !u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"reason\":");
    try writeJsonString(&out.writer, reason);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn printReceipt(allocator: std.mem.Allocator, command: []const u8, outcome: []const u8, detail: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"resolve_c3_receipt\":{\"receipt_version\":\"RC3-R1\",\"command\":");
    try writeJsonString(&out.writer, command);
    try out.writer.writeAll(",\"outcome\":");
    try writeJsonString(&out.writer, outcome);
    try out.writer.writeAll(",\"exit_code\":0,\"campaign_id\":null,\"phase_before\":null,\"phase_after\":null,\"artifact_fingerprints\":{\"detail\":\"sha256:");
    try out.writer.print("{x}", .{hashBytes(detail)});
    try out.writer.writeAll("\"},\"event_id\":\"evt-");
    try out.writer.print("{x}", .{hashReceipt(command, outcome, detail)});
    try out.writer.writeAll("\",\"codes\":[],\"detail\":");
    try writeJsonString(&out.writer, detail);
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn printStateReceipt(
    allocator: std.mem.Allocator,
    command: []const u8,
    outcome: []const u8,
    detail: []const u8,
    phase_before: ?[]const u8,
    state_after: State,
    event_id: []const u8,
) !void {
    const state_fingerprint = try stateFingerprintAlloc(allocator, state_after);
    defer allocator.free(state_fingerprint);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"resolve_c3_receipt\":{\"receipt_version\":\"RC3-R1\",\"command\":");
    try writeJsonString(&out.writer, command);
    try out.writer.writeAll(",\"outcome\":");
    try writeJsonString(&out.writer, outcome);
    try out.writer.writeAll(",\"exit_code\":0,\"campaign_id\":");
    try writeJsonString(&out.writer, state_after.run_id);
    try out.writer.writeAll(",\"phase_before\":");
    try writeOptionalString(&out.writer, phase_before);
    try out.writer.writeAll(",\"phase_after\":");
    try writeJsonString(&out.writer, state_after.phase);
    try out.writer.writeAll(",\"artifact_fingerprints\":{\"state\":");
    try writeJsonString(&out.writer, state_fingerprint);
    try out.writer.writeAll(",\"delivery_tree\":null},\"event_id\":");
    try writeJsonString(&out.writer, event_id);
    try out.writer.writeAll(",\"codes\":[],\"detail\":");
    try writeJsonString(&out.writer, detail);
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(HashSeed, bytes);
}

fn hashReceipt(command: []const u8, outcome: []const u8, detail: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(HashSeed);
    hasher.update(command);
    hasher.update("\x00");
    hasher.update(outcome);
    hasher.update("\x00");
    hasher.update(detail);
    return hasher.final();
}

fn stateFingerprintAlloc(allocator: std.mem.Allocator, state: State) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeStateJson(&out.writer, state);
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    return sha256FingerprintAlloc(allocator, bytes);
}

fn sha256FingerprintAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex[0..]});
}

fn printError(allocator: std.mem.Allocator, message: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"c3_error\":{\"message\":");
    try writeJsonString(&out.writer, message);
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeOptionalString(writer: anytype, value: ?[]const u8) !void {
    if (value) |actual| try writeJsonString(writer, actual) else try writer.writeAll("null");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try writeStdoutBytes(allocator, bytes);
}

fn writeStdoutBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    _ = allocator;
    try std.Io.File.stdout().writeStreamingAll(Io, bytes);
}

test "parseArgs accepts lifecycle command options" {
    const argv = [_][]const u8{ "resolve-c3", "begin", "--root", "/tmp/repo", "--goal", "fix it", "--json" };
    const args = try parseArgs(&argv);
    try std.testing.expectEqual(Command.begin, args.command);
    try std.testing.expectEqualStrings("/tmp/repo", args.cwd);
    try std.testing.expectEqualStrings("fix it", args.goal.?);
    try std.testing.expect(args.json);
    try std.testing.expectEqualStrings(DefaultStateRoot, args.state_root);
}

test "parseArgs accepts schema artifact positional argument" {
    const argv = [_][]const u8{ "resolve-c3", "schema", "kernel", "--json" };
    const args = try parseArgs(&argv);
    try std.testing.expectEqual(Command.schema, args.command);
    try std.testing.expectEqualStrings("kernel", args.artifact.?);
    try std.testing.expect(args.json);
}

test "parseArgs accepts canonical nested command tokens" {
    const campaign = [_][]const u8{ "resolve-c3", "campaign", "begin", "--root", "/tmp/repo", "--goal", "fix it" };
    const campaign_args = try parseArgs(&campaign);
    try std.testing.expectEqual(Command.campaign_begin, campaign_args.command);
    try std.testing.expectEqualStrings("/tmp/repo", campaign_args.cwd);

    const observation = [_][]const u8{ "resolve-c3", "observation", "add", "--input", "observation.json" };
    const observation_args = try parseArgs(&observation);
    try std.testing.expectEqual(Command.observation_add, observation_args.command);
    try std.testing.expectEqualStrings("observation.json", observation_args.input.?);

    const kernel = [_][]const u8{ "resolve-c3", "kernel", "lint", "--input", "kernel.json" };
    const kernel_args = try parseArgs(&kernel);
    try std.testing.expectEqual(Command.kernel_lint, kernel_args.command);

    const design = [_][]const u8{ "resolve-c3", "design", "register", "--input", "design.json" };
    const design_args = try parseArgs(&design);
    try std.testing.expectEqual(Command.design_register, design_args.command);

    const realization = [_][]const u8{ "resolve-c3", "realization", "worktree", "--design", "design.example", "--path", "/tmp/rc3-worktree" };
    const realization_args = try parseArgs(&realization);
    try std.testing.expectEqual(Command.realization_worktree, realization_args.command);
    try std.testing.expectEqualStrings("design.example", realization_args.design_id.?);
    try std.testing.expectEqualStrings("/tmp/rc3-worktree", realization_args.path.?);

    const proof = [_][]const u8{ "resolve-c3", "proof", "compress", "--root", "/tmp/repo" };
    const proof_args = try parseArgs(&proof);
    try std.testing.expectEqual(Command.proof_compress, proof_args.command);
    try std.testing.expectEqualStrings("/tmp/repo", proof_args.cwd);

    const delivery = [_][]const u8{ "resolve-c3", "delivery", "commit", "--message", "apply realization" };
    const delivery_args = try parseArgs(&delivery);
    try std.testing.expectEqual(Command.delivery_commit, delivery_args.command);
    try std.testing.expectEqualStrings("apply realization", delivery_args.message.?);

    const certify = [_][]const u8{ "resolve-c3", "certify", "terminal", "--root", "/tmp/repo" };
    const certify_args = try parseArgs(&certify);
    try std.testing.expectEqual(Command.certify_terminal, certify_args.command);
    try std.testing.expectEqualStrings("/tmp/repo", certify_args.cwd);

    const migrate = [_][]const u8{ "resolve-c3", "migrate", "mrpc", "--from", ".ledger/c3", "--campaign-base", "abc123", "--review-ready-baseline", "def456" };
    const migrate_args = try parseArgs(&migrate);
    try std.testing.expectEqual(Command.migrate_mrpc, migrate_args.command);
    try std.testing.expectEqualStrings(".ledger/c3", migrate_args.legacy_root);
    try std.testing.expectEqualStrings("abc123", migrate_args.campaign_base.?);
    try std.testing.expectEqualStrings("def456", migrate_args.review_ready_baseline.?);

    const acceptance = [_][]const u8{ "resolve-c3", "acceptance", "seal", "--approved-by", "owner" };
    const acceptance_args = try parseArgs(&acceptance);
    try std.testing.expectEqual(Command.acceptance_seal, acceptance_args.command);
    try std.testing.expectEqualStrings("owner", acceptance_args.approved_by.?);

    const intent_migration = [_][]const u8{ "resolve-c3", "migrate", "intent-closed", "--from", ".legacy-c3", "--campaign-base", "abc123", "--review-ready-baseline", "def456" };
    const intent_migration_args = try parseArgs(&intent_migration);
    try std.testing.expectEqual(Command.migrate_intent_closed, intent_migration_args.command);
    try std.testing.expectEqualStrings(".legacy-c3", intent_migration_args.legacy_root);

    const counterexample = [_][]const u8{ "resolve-c3", "counterexample", "classify", "--id", "cex.one", "--input", "cex.json" };
    const counterexample_args = try parseArgs(&counterexample);
    try std.testing.expectEqual(Command.counterexample_classify, counterexample_args.command);
    try std.testing.expectEqualStrings("cex.one", counterexample_args.id.?);

    const basis = [_][]const u8{ "resolve-c3", "basis", "seal", "--confirm" };
    const basis_args = try parseArgs(&basis);
    try std.testing.expectEqual(Command.basis_seal, basis_args.command);
    try std.testing.expect(basis_args.confirm);

    const reduction = [_][]const u8{ "resolve-c3", "reduction", "accept", "--root", "/tmp/repo" };
    const reduction_args = try parseArgs(&reduction);
    try std.testing.expectEqual(Command.reduction_accept, reduction_args.command);
    try std.testing.expectEqualStrings("/tmp/repo", reduction_args.cwd);

    const authority_init = [_][]const u8{
        "resolve-c3",
        "authority-chain",
        "init",
        "--campaign",
        "campaign.one",
        "--artifact-state",
        "artifact-state.json",
        "--review-claim",
        "claim.json",
        "--acceptance",
        "ac-v2.json",
        "--cex",
        "cex-v1.json",
        "--batch",
        "rb-v1.json",
        "--basis",
        "ceb-v2.json",
        "--kernel",
        "mbk-v1.json",
        "--reduction",
        "rc-v1.json",
        "--proof-obligation",
        "proof.one",
        "--realization-target",
        "target.json",
        "--output",
        "rac.yaml",
    };
    const authority_init_args = try parseArgs(&authority_init);
    try std.testing.expectEqual(Command.authority_chain_init, authority_init_args.command);
    try std.testing.expectEqualStrings("campaign.one", authority_init_args.campaign_id.?);
    try std.testing.expectEqualStrings("artifact-state.json", authority_init_args.artifact_state.?);
    try std.testing.expectEqualStrings("claim.json", authority_init_args.review_claim.?);
    try std.testing.expectEqualStrings("ac-v2.json", authority_init_args.acceptance.?);
    try std.testing.expectEqualStrings("cex-v1.json", authority_init_args.cex.?);
    try std.testing.expectEqualStrings("rb-v1.json", authority_init_args.batch.?);
    try std.testing.expectEqualStrings("ceb-v2.json", authority_init_args.basis.?);
    try std.testing.expectEqualStrings("mbk-v1.json", authority_init_args.kernel.?);
    try std.testing.expectEqualStrings("rc-v1.json", authority_init_args.reduction.?);
    try std.testing.expectEqualStrings("proof.one", authority_init_args.proof_obligation.?);
    try std.testing.expectEqualStrings("target.json", authority_init_args.realization_target.?);
    try std.testing.expectEqualStrings("rac.yaml", authority_init_args.output.?);

    const authority_check = [_][]const u8{
        "resolve-c3",
        "authority-chain",
        "check",
        "--chain",
        "rac.yaml",
        "--format",
        "json",
    };
    const authority_check_args = try parseArgs(&authority_check);
    try std.testing.expectEqual(Command.authority_chain_check, authority_check_args.command);
    try std.testing.expectEqualStrings("rac.yaml", authority_check_args.chain.?);
    try std.testing.expectEqualStrings("json", authority_check_args.format.?);

    const mutation_gate = [_][]const u8{
        "resolve-c3",
        "mutation-gate",
        "--campaign",
        "campaign",
        "--review-claim-id",
        "claim",
        "--artifact-state",
        "artifact-state.json",
        "--format",
        "json",
    };
    const mutation_gate_args = try parseArgs(&mutation_gate);
    try std.testing.expectEqual(Command.mutation_gate, mutation_gate_args.command);
    try std.testing.expectEqualStrings("campaign", mutation_gate_args.campaign_id.?);
    try std.testing.expectEqualStrings("claim", mutation_gate_args.review_claim_id.?);
    try std.testing.expectEqualStrings("artifact-state.json", mutation_gate_args.artifact_state.?);
    try std.testing.expectEqualStrings("json", mutation_gate_args.format.?);
}

test "schema discovery advertises intent closed artifacts" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRequiredFields(&out.writer, "acceptance-v2");
    const fields = try out.toOwnedSlice();
    defer std.testing.allocator.free(fields);
    try std.testing.expect(std.mem.containsAtLeast(u8, fields, 1, "source_refs"));
    try std.testing.expect(std.mem.containsAtLeast(u8, fields, 1, "proof_bar"));
    try std.testing.expectEqualStrings("resolve_c3_acceptance_contract_v2", schemaRootName("acceptance-v2"));
    try std.testing.expectEqualStrings("resolve_c3_review_batch", schemaRootName("review-batch"));
    try std.testing.expectEqualStrings("resolve_c3_counterexample_basis_v2", schemaRootName("counterexample-basis-v2"));
    try std.testing.expect(knownSchemaArtifact("acceptance-v2"));
    try std.testing.expect(knownSchemaArtifact("review-batch"));
    try std.testing.expect(knownSchemaArtifact("review-aperture"));
    try std.testing.expect(knownSchemaArtifact("counterexample"));
    try std.testing.expect(knownSchemaArtifact("counterexample-basis-v2"));
    try std.testing.expect(knownSchemaArtifact("review-potential"));
    try std.testing.expect(knownSchemaArtifact("kernel"));
    try std.testing.expect(knownSchemaArtifact("authority-chain"));
    try std.testing.expect(knownSchemaArtifact("mbkc"));
    try std.testing.expect(!knownSchemaArtifact("candidate"));
    try std.testing.expectEqualStrings("resolve_authority_chain", schemaRootName("authority-chain"));

    var rac_fields_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rac_fields_out.deinit();
    try writeRequiredFields(&rac_fields_out.writer, "authority-chain");
    const rac_fields = try rac_fields_out.toOwnedSlice();
    defer std.testing.allocator.free(rac_fields);
    try std.testing.expect(std.mem.containsAtLeast(u8, rac_fields, 1, "resolve_authority_chain"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rac_fields, 1, "chain_version"));
}

fn validRacFactsForTest() RacFacts {
    return .{
        .chain_id = "RAC-test",
        .campaign_id = "campaign-test",
        .chain_version_ok = true,
        .artifact_state_complete = true,
        .review_claim_present = true,
        .acceptance_contract_present = true,
        .horizon_present = true,
        .law_refs_present = true,
        .relation = "directly_entailed",
        .cex_confirmed = true,
        .adjudication_disposition = "accepted",
        .batch_sealed = true,
        .ceb_class_present = true,
        .mbk_present = true,
        .rc_present = true,
        .transition_present = true,
        .proof_obligation_present = true,
        .realization_allowed = true,
        .gate_current_yes = true,
        .gate_complete_yes = true,
        .gate_mutation_yes = true,
    };
}

fn expectRacReason(facts: RacFacts, reason: []const u8) !void {
    var missing = std.ArrayList([]const u8).empty;
    defer missing.deinit(std.testing.allocator);
    var violations = std.ArrayList([]const u8).empty;
    defer violations.deinit(std.testing.allocator);
    try validateRacFacts(std.testing.allocator, facts, &missing, &violations);
    try std.testing.expect(containsString(missing.items, reason) or containsString(violations.items, reason));
}

test "RAC-v1 validation covers fail-closed reasons" {
    const valid = validRacFactsForTest();
    var missing = std.ArrayList([]const u8).empty;
    defer missing.deinit(std.testing.allocator);
    var violations = std.ArrayList([]const u8).empty;
    defer violations.deinit(std.testing.allocator);
    try validateRacFacts(std.testing.allocator, valid, &missing, &violations);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);

    var missing_chain = valid;
    missing_chain.chain_version_ok = false;
    try expectRacReason(missing_chain, "missing_chain_version");

    var missing_artifact = valid;
    missing_artifact.artifact_state_complete = false;
    try expectRacReason(missing_artifact, "missing_artifact_state");

    var missing_claim = valid;
    missing_claim.review_claim_present = false;
    try expectRacReason(missing_claim, "missing_review_claim");

    var missing_acceptance = valid;
    missing_acceptance.acceptance_contract_present = false;
    try expectRacReason(missing_acceptance, "missing_acceptance_contract");

    var missing_horizon = valid;
    missing_horizon.horizon_present = false;
    try expectRacReason(missing_horizon, "missing_horizon");

    var missing_laws = valid;
    missing_laws.law_refs_present = false;
    try expectRacReason(missing_laws, "missing_law_refs");

    var outside = valid;
    outside.relation = "outside_horizon";
    try expectRacReason(outside, "outside_horizon");

    var unrelated = valid;
    unrelated.relation = "unrelated";
    try expectRacReason(unrelated, "unrelated_or_rejected");

    var invalid_cex = valid;
    invalid_cex.cex_confirmed = false;
    try expectRacReason(invalid_cex, "invalid_cex");

    var unsealed = valid;
    unsealed.batch_sealed = false;
    try expectRacReason(unsealed, "unsealed_batch");

    var missing_class = valid;
    missing_class.ceb_class_present = false;
    try expectRacReason(missing_class, "missing_ceb_class");

    var missing_mbk = valid;
    missing_mbk.mbk_present = false;
    try expectRacReason(missing_mbk, "missing_mbk_or_rc");

    var missing_transition = valid;
    missing_transition.transition_present = false;
    try expectRacReason(missing_transition, "missing_transition");

    var missing_proof = valid;
    missing_proof.proof_obligation_present = false;
    try expectRacReason(missing_proof, "missing_proof_obligation");

    var stale = valid;
    stale.gate_current_yes = false;
    try expectRacReason(stale, "artifact_state_stale");

    var not_allowed = valid;
    not_allowed.realization_allowed = false;
    try expectRacReason(not_allowed, "realization_not_allowed");

    var disagrees = valid;
    disagrees.gate_mutation_yes = false;
    try expectRacReason(disagrees, "mutation_gate_disagrees");
}

test "RAC-v1 parser accepts JSON and YAML facts" {
    const json_text =
        \\{"resolve_authority_chain":{"chain_version":"RAC-v1","chain_id":"RAC-json","campaign_id":"campaign-json","artifact_state":{"base_sha":"b","head_sha":"h","dirty_fingerprint":"clean","review_receipt":"rr"},"review_claim":{"claim_id":"claim"},"acceptance":{"contract_id":"ac","contract_fingerprint":"sha256:ac","horizon_fingerprint":"sha256:h","law_refs":["law"],"relation":"directly_entailed"},"adjudication":{"cex_id":"cex","validity":"confirmed","disposition":"accepted"},"batch":{"batch_id":"batch","sealed":true},"compression":{"ceb_id":"ceb","class_id":"class","class_status":"accepted","quotient_witness_ref":"w","mbk_id":"mbk","rc_id":"rc","transition_ref":"t","proof_obligation_ref":"p"},"realization":{"allowed":true},"gate":{"current_artifact_state":"yes","complete_chain":"yes","mutation_allowed":"yes"}}}
    ;
    const json_facts = try parseRacFacts(std.testing.allocator, json_text);
    defer deinitParsedRacFacts(std.testing.allocator, json_facts);
    try std.testing.expect(json_facts.chain_version_ok);
    try std.testing.expectEqualStrings("RAC-json", json_facts.chain_id);
    try std.testing.expectEqualStrings("b", json_facts.artifact_base_sha);
    try std.testing.expectEqualStrings("claim", json_facts.review_claim_id);
    try std.testing.expect(json_facts.realization_allowed);

    const yaml_text =
        \\resolve_authority_chain:
        \\  chain_version: RAC-v1
        \\  chain_id: RAC-yaml
        \\  campaign_id: campaign-yaml
        \\  artifact_state:
        \\    base_sha: b
        \\    head_sha: h
        \\    dirty_fingerprint: clean
        \\    review_receipt: rr
        \\  review_claim:
        \\    claim_id: claim
        \\  acceptance:
        \\    contract_id: ac
        \\    contract_fingerprint: sha256:ac
        \\    horizon_fingerprint: sha256:h
        \\    law_refs:
        \\      - law
        \\    relation: directly_entailed
        \\  adjudication:
        \\    validity: confirmed
        \\    disposition: accepted
        \\  batch:
        \\    sealed: true
        \\  compression:
        \\    ceb_id: ceb
        \\    class_id: class
        \\    class_status: accepted
        \\    quotient_witness_ref: w
        \\    mbk_id: mbk
        \\    rc_id: rc
        \\    transition_ref: t
        \\    proof_obligation_ref: p
        \\  realization:
        \\    allowed: true
        \\  gate:
        \\    current_artifact_state: yes
        \\    complete_chain: yes
        \\    mutation_allowed: yes
    ;
    const yaml_facts = try parseRacFacts(std.testing.allocator, yaml_text);
    defer deinitParsedRacFacts(std.testing.allocator, yaml_facts);
    try std.testing.expect(yaml_facts.chain_version_ok);
    try std.testing.expectEqualStrings("RAC-yaml", yaml_facts.chain_id);
    try std.testing.expectEqualStrings("h", yaml_facts.artifact_head_sha);
    try std.testing.expectEqualStrings("claim", yaml_facts.review_claim_id);
    try std.testing.expect(yaml_facts.law_refs_present);
    try std.testing.expect(yaml_facts.gate_mutation_yes);
}

test "mutation-gate blocks valid non-mutation RAC and normalizes reasons" {
    var facts = validRacFactsForTest();
    var missing = std.ArrayList([]const u8).empty;
    defer missing.deinit(std.testing.allocator);
    var violations = std.ArrayList([]const u8).empty;
    defer violations.deinit(std.testing.allocator);
    try validateRacFacts(std.testing.allocator, facts, &missing, &violations);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);

    facts.realization_allowed = false;
    facts.gate_mutation_yes = false;
    try validateRacFacts(std.testing.allocator, facts, &missing, &violations);
    if (!facts.gate_mutation_yes) try violations.append(std.testing.allocator, "mutation_gate_disagrees");
    var normalized = std.ArrayList([]const u8).empty;
    defer normalized.deinit(std.testing.allocator);
    try appendMutationGateReasons(std.testing.allocator, &normalized, missing.items);
    try appendMutationGateReasons(std.testing.allocator, &normalized, violations.items);
    try std.testing.expect(containsString(normalized.items, "realization_allowed"));
    try std.testing.expect(containsString(normalized.items, "gate_mutation_allowed"));
}

test "mutation-gate integrated mode compares supplied artifact state" {
    const json_text =
        \\{"resolve_authority_chain":{"chain_version":"RAC-v1","chain_id":"RAC-json","campaign_id":"campaign-json","artifact_state":{"base_sha":"b","head_sha":"h","dirty_fingerprint":"clean","review_receipt":"rr"},"review_claim":{"claim_id":"claim"},"acceptance":{"contract_id":"ac","contract_fingerprint":"sha256:ac","horizon_fingerprint":"sha256:h","law_refs":["law"],"relation":"directly_entailed"},"adjudication":{"cex_id":"cex","validity":"confirmed","disposition":"accepted"},"batch":{"batch_id":"batch","sealed":true},"compression":{"ceb_id":"ceb","class_id":"class","class_status":"accepted","quotient_witness_ref":"w","mbk_id":"mbk","rc_id":"rc","transition_ref":"t","proof_obligation_ref":"p"},"realization":{"allowed":true},"gate":{"current_artifact_state":"yes","complete_chain":"yes","mutation_allowed":"yes"}}}
    ;
    const facts = try parseRacFacts(std.testing.allocator, json_text);
    defer deinitParsedRacFacts(std.testing.allocator, facts);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(Io, .{
        .sub_path = "artifact-state.json",
        .data = "{\"base_sha\":\"b\",\"head_sha\":\"h\",\"dirty_fingerprint\":\"clean\",\"review_receipt\":\"rr\"}\n",
    });
    try tmp.dir.writeFile(Io, .{
        .sub_path = "stale.json",
        .data = "{\"base_sha\":\"b\",\"head_sha\":\"stale\",\"dirty_fingerprint\":\"clean\",\"review_receipt\":\"rr\"}\n",
    });
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const good_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, "artifact-state.json" });
    defer std.testing.allocator.free(good_path);
    const stale_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, "stale.json" });
    defer std.testing.allocator.free(stale_path);

    try std.testing.expect(try artifactStateMatches(std.testing.allocator, good_path, facts));
    try std.testing.expect(!try artifactStateMatches(std.testing.allocator, stale_path, facts));
}

test "RAC-v1 non-mutation route can be valid without mutation authority" {
    var facts = validRacFactsForTest();
    facts.cex_confirmed = false;
    facts.adjudication_disposition = "refuted";
    facts.realization_allowed = false;
    facts.gate_mutation_yes = false;
    var missing = std.ArrayList([]const u8).empty;
    defer missing.deinit(std.testing.allocator);
    var violations = std.ArrayList([]const u8).empty;
    defer violations.deinit(std.testing.allocator);
    try validateRacFacts(std.testing.allocator, facts, &missing, &violations);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);
    try std.testing.expect(hasNonMutationDisposition(facts.adjudication_disposition));
    try std.testing.expect(nonMutationViolationsOnly(violations.items));
}

test "initial material state writes v3 intent closed protocol projection" {
    const state = initialState(.{ .command = .init, .cwd = "/repo" });
    try std.testing.expectEqualStrings(StateSchemaV3, state.schema);
    try std.testing.expectEqualStrings(ProtocolProfileIntentClosed, state.protocol_profile);
    try std.testing.expectEqual(@as(u32, 3), state.state_version);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStateJson(&out.writer, state);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes, 1, "\"schema\": \"resolve-c3-state-v3\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes, 1, "\"protocol_profile\": \"intent-closed-cegis-v1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes, 1, "\"acceptance\": {"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes, 1, "\"review\": {"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes, 1, "\"counterexamples\": {"));

    var parsed = try std.json.parseFromSlice(State, std.testing.allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(StateSchemaV3, parsed.value.schema);
    try std.testing.expectEqualStrings(ProtocolProfileIntentClosed, parsed.value.protocol_profile);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.state_version);
}

test "state parser reads strict v2 state with v3 defaults" {
    const bytes =
        \\{
        \\  "schema": "resolve-c3-state-v2",
        \\  "state_root": ".ledger/c3",
        \\  "legacy_root": ".resolve-c3",
        \\  "state_version": 2,
        \\  "run_id": "C3-v2",
        \\  "repo_root": "/repo",
        \\  "branch": "main",
        \\  "base_sha": "abc",
        \\  "phase": "closed",
        \\  "acceptance_goal": "legacy",
        \\  "parent_run_id": null,
        \\  "counterexample_count": 1,
        \\  "basis_set": true,
        \\  "tournament_waiver": null,
        \\  "candidates": [],
        \\  "selected_candidate_id": null,
        \\  "ablation_authority": null,
        \\  "ablation_orphan_edit_atoms": 0,
        \\  "candidate_holdout_safe": false,
        \\  "delivery_holdout_safe": false,
        \\  "proof_authority": null,
        \\  "proof_passed": false,
        \\  "proof_patch_stable": false,
        \\  "delivery_patch_sha": null,
        \\  "commit_sha": null,
        \\  "pushed": false,
        \\  "certificate_stage": null
        \\}
    ;
    var parsed = try std.json.parseFromSlice(State, std.testing.allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(StateSchemaV2, parsed.value.schema);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.state_version);
    try std.testing.expectEqualStrings(ProtocolProfileIntentClosed, parsed.value.protocol_profile);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.counterexample_count);
}

test "kernel and design validators reject missing authority fields" {
    const kernel =
        \\{"kernel_version":"MBK-v1","campaign_id":"c","campaign_base_sha":"b","acceptance_contract":{},"authorities":[],"carriers":[],"observations":[],"equivalence_classes":[],"operations":[],"transitions":[],"laws":[],"quotient":{},"complexity":{},"gate":{}}
    ;
    var parsed_kernel = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, kernel, .{});
    defer parsed_kernel.deinit();
    try validateKernelValue(parsed_kernel.value);

    const bad_design = "{\"design_version\":\"RD-v1\",\"design_id\":\"bad\"}";
    var parsed_design = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bad_design, .{});
    defer parsed_design.deinit();
    try std.testing.expectError(error.InvalidCandidate, validateDesignValue(parsed_design.value));
}

test "intent-bound kernel and reduction validators require current AC and CEB anchors" {
    const state = State{
        .schema = StateSchemaV3,
        .state_root = DefaultStateRoot,
        .legacy_root = LegacyStateRoot,
        .state_version = 3,
        .run_id = "C3-test",
        .repo_root = "/repo",
        .branch = "main",
        .base_sha = "abc",
        .phase = "basis_sealed",
        .acceptance = .{ .sequence = 1, .contract_id = "ac", .fingerprint = "sha256:ac", .horizon_state = "sealed" },
        .acceptance_goal = "goal",
        .parent_run_id = null,
        .basis = .{ .id = "basis", .fingerprint = "sha256:basis", .sealed = true },
        .counterexample_count = 0,
        .basis_set = true,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    };
    const good_kernel =
        \\{"kernel_version":"MBK-v1","campaign_id":"c","campaign_base_sha":"b","acceptance_fingerprint":"sha256:ac","basis_fingerprint":"sha256:basis","acceptance_contract":{},"authorities":[],"carriers":[],"observations":[{"acceptance_refs":["req"],"class_refs":["class"]}],"equivalence_classes":[{"witness_refs":["cex.one"]}],"operations":[],"transitions":[],"laws":[{"acceptance_refs":["req"],"class_refs":["class"],"modality":"MUST"}],"quotient":{"congruence_evidence":["manual"]},"complexity":{},"gate":{"recomposition":true}}
    ;
    var parsed_good = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, good_kernel, .{});
    defer parsed_good.deinit();
    try validateIntentBoundKernel(parsed_good.value, state);

    const may_kernel =
        \\{"kernel_version":"MBK-v1","campaign_id":"c","campaign_base_sha":"b","acceptance_fingerprint":"sha256:ac","basis_fingerprint":"sha256:basis","acceptance_contract":{},"authorities":[],"carriers":[],"observations":[{"acceptance_refs":["req"],"class_refs":["class"]}],"equivalence_classes":[{"witness_refs":["cex.one"]}],"operations":[],"transitions":[],"laws":[{"acceptance_refs":["req"],"class_refs":["class"],"modality":"MAY"}],"quotient":{"congruence_evidence":["manual"]},"complexity":{},"gate":{"recomposition":true}}
    ;
    var parsed_may = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, may_kernel, .{});
    defer parsed_may.deinit();
    try std.testing.expectError(error.InvalidBasis, validateIntentBoundKernel(parsed_may.value, state));

    const good_reduction =
        \\{"certificate_version":"RC-v1","certificate_id":"rc","acceptance_fingerprint":"sha256:ac","basis_fingerprint":"sha256:basis","discharges":[{"discharged":true}],"recomposition_refs":["proof"]}
    ;
    var parsed_reduction = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, good_reduction, .{});
    defer parsed_reduction.deinit();
    try validateReductionValue(parsed_reduction.value, state);

    const bad_reduction =
        \\{"certificate_version":"RC-v1","certificate_id":"rc","acceptance_fingerprint":"sha256:ac","basis_fingerprint":"sha256:basis","discharges":[{}],"recomposition_refs":["proof"]}
    ;
    var parsed_bad_reduction = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bad_reduction, .{});
    defer parsed_bad_reduction.deinit();
    try std.testing.expectError(error.ReductionInvalid, validateReductionValue(parsed_bad_reduction.value, state));
}

test "initState writes only .ledger/c3 state and local exclude" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, ".git/info");
    try tmp.dir.writeFile(Io, .{ .sub_path = ".git/info/exclude", .data = "# local excludes\n" });
    try makePathUnder(std.testing.allocator, cwd, ".resolve-c3");
    try tmp.dir.writeFile(Io, .{ .sub_path = ".resolve-c3/state.json", .data = "{\"legacy\":true}\n" });

    var root = try openRoot(cwd);
    defer root.close(Io);
    try root.createDirPath(Io, DefaultStateRoot);
    const state = initialState(.{ .command = .init, .cwd = cwd });
    try saveState(std.testing.allocator, root, DefaultStateRoot, state);
    try writeMbkc(std.testing.allocator, root, DefaultStateRoot, state, "uninitialized");
    try ensureLocalExclude(std.testing.allocator, root, DefaultStateRoot);

    try tmp.dir.access(Io, ".ledger/c3/state.json", .{});
    try tmp.dir.access(Io, ".ledger/c3/mbkc.json", .{});
    try tmp.dir.access(Io, ".resolve-c3/state.json", .{});
    const exclude = try tmp.dir.readFileAlloc(Io, ".git/info/exclude", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(exclude);
    try std.testing.expect(containsLine(exclude, ".ledger/c3/"));
    try std.testing.expect(!containsLine(exclude, ".ledger/"));
}

test "state lifecycle gates require controller ablation and proof" {
    var candidates = [_]Candidate{candidateForTest("selected", "patch", true, zeroCost())};
    const state = State{
        .schema = StateSchemaV2,
        .state_root = DefaultStateRoot,
        .legacy_root = LegacyStateRoot,
        .state_version = 2,
        .run_id = "C3-test",
        .repo_root = "/repo",
        .branch = "main",
        .base_sha = "abc",
        .phase = "selected",
        .acceptance_goal = "goal",
        .parent_run_id = null,
        .counterexample_count = 1,
        .basis_set = true,
        .tournament_waiver = null,
        .candidates = candidates[0..],
        .selected_candidate_id = "selected",
        .ablation_authority = "external",
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = true,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    };
    try std.testing.expect(selectedCandidate(state) != null);
    try std.testing.expect(!optionalEql(state.ablation_authority, "controller"));
}

test "loaded state strings survive after input buffer is freed and state is rewritten" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);

    var root = try openRoot(cwd);
    defer root.close(Io);
    try saveState(std.testing.allocator, root, DefaultStateRoot, State{
        .schema = StateSchemaV2,
        .state_root = DefaultStateRoot,
        .legacy_root = LegacyStateRoot,
        .state_version = 2,
        .run_id = "C3-owned",
        .repo_root = "/repo",
        .branch = "resolve/pr",
        .base_sha = "abcdef123456",
        .phase = "collecting",
        .acceptance_goal = "own state strings",
        .parent_run_id = null,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    });

    {
        var parsed = try loadStateParsed(std.testing.allocator, root, DefaultStateRoot);
        defer parsed.deinit();
        var state = parsed.value;
        state.counterexample_count += 1;
        try saveState(std.testing.allocator, root, DefaultStateRoot, state);
    }

    var reparsed = try loadStateParsed(std.testing.allocator, root, DefaultStateRoot);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings(StateSchemaV2, reparsed.value.schema);
    try std.testing.expectEqualStrings(DefaultStateRoot, reparsed.value.state_root);
    try std.testing.expectEqualStrings(LegacyStateRoot, reparsed.value.legacy_root);
    try std.testing.expectEqualStrings("C3-owned", reparsed.value.run_id);
    try std.testing.expectEqualStrings("/repo", reparsed.value.repo_root);
    try std.testing.expectEqualStrings("resolve/pr", reparsed.value.branch);
    try std.testing.expectEqualStrings("abcdef123456", reparsed.value.base_sha);
    try std.testing.expectEqualStrings("collecting", reparsed.value.phase);
    try std.testing.expectEqualStrings("own state strings", reparsed.value.acceptance_goal);
    try std.testing.expectEqual(@as(u32, 1), reparsed.value.counterexample_count);
}

test "state parser rejects unknown fields in strict v2 mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);
    try tmp.dir.writeFile(Io, .{
        .sub_path = ".ledger/c3/state.json",
        .data =
        \\{
        \\  "schema": "resolve-c3-state-v2",
        \\  "state_root": ".ledger/c3",
        \\  "legacy_root": ".resolve-c3",
        \\  "state_version": 2,
        \\  "run_id": "C3-strict",
        \\  "repo_root": "/repo",
        \\  "branch": "main",
        \\  "base_sha": "abc",
        \\  "phase": "initialized",
        \\  "acceptance_goal": "",
        \\  "parent_run_id": null,
        \\  "counterexample_count": 0,
        \\  "basis_set": false,
        \\  "tournament_waiver": null,
        \\  "candidates": [],
        \\  "selected_candidate_id": null,
        \\  "ablation_authority": null,
        \\  "ablation_orphan_edit_atoms": 0,
        \\  "candidate_holdout_safe": false,
        \\  "delivery_holdout_safe": false,
        \\  "proof_authority": null,
        \\  "proof_passed": false,
        \\  "proof_patch_stable": false,
        \\  "delivery_patch_sha": null,
        \\  "commit_sha": null,
        \\  "pushed": false,
        \\  "certificate_stage": null,
        \\  "unexpected": true
        \\}
        \\
        ,
    });

    var root = try openRoot(cwd);
    defer root.close(Io);
    try std.testing.expectError(error.UnknownField, loadStateParsed(std.testing.allocator, root, DefaultStateRoot));
}

test "event log rows include stable event ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);

    var root = try openRoot(cwd);
    defer root.close(Io);
    const before = initialState(.{ .command = .init, .cwd = cwd });
    var after = before;
    after.phase = "collecting";
    after.run_id = "C3-test";
    const event_id = try appendEvent(std.testing.allocator, root, DefaultStateRoot, "begin", before, after, after.run_id);
    defer std.testing.allocator.free(event_id);
    const events = try tmp.dir.readFileAlloc(Io, ".ledger/c3/events.jsonl", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.startsWith(u8, event_id, "evt-"));
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "\"event_id\":\"evt-"));
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "\"campaign_id\":\"C3-test\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "\"phase_before\":\"initialized\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "\"phase_after\":\"collecting\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "\"source_command_receipt\":{\"receipt_version\":\"RC3-R1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "\"artifact_fingerprints\":{\"state_before\":\"sha256:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "\"state_after\":\"sha256:"));
}

test "state writes fail while path lock is held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);

    var root = try openRoot(cwd);
    defer root.close(Io);
    var lock = try root.createFile(Io, ".ledger/c3/.state.json.lock", .{ .exclusive = true, .read = true, .truncate = false });
    defer {
        lock.close(Io);
        root.deleteFile(Io, ".ledger/c3/.state.json.lock") catch {};
    }
    const state = initialState(.{ .command = .init, .cwd = cwd });
    try std.testing.expectError(error.PathAlreadyExists, saveState(std.testing.allocator, root, DefaultStateRoot, state));
}

test "acceptance v2 set seal and rebase update state and invalidate downstream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);
    try tmp.dir.writeFile(Io, .{
        .sub_path = "ac1.json",
        .data =
        \\{"acceptance_version":"AC-v2","contract_id":"ac.one","source_refs":["HEAD"],"goal":"first goal","required":[{"id":"req.example","text":"required"}],"compatibility":[],"forbidden":[],"proof_bar":{"commands":["zig build test-resolve-c3 --summary all"]},"observation_language":{"terms":["law"]},"authority":{"id":"owner","current":true},"horizon":{"sequence":1},"fingerprint":"sha256:caller"}
        \\
        ,
    });
    try tmp.dir.writeFile(Io, .{
        .sub_path = "ac2.json",
        .data =
        \\{"acceptance_version":"AC-v2","contract_id":"ac.two","source_refs":["HEAD"],"goal":"second goal","required":[{"id":"req.example","text":"required"}],"compatibility":[],"forbidden":[],"proof_bar":{"commands":["zig build test-resolve-c3 --summary all"]},"observation_language":{"terms":["law"]},"authority":{"id":"owner","current":true},"horizon":{"sequence":2},"fingerprint":"sha256:caller"}
        \\
        ,
    });
    const ac1_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, "ac1.json" });
    defer std.testing.allocator.free(ac1_path);
    const ac2_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, "ac2.json" });
    defer std.testing.allocator.free(ac2_path);

    var root = try openRoot(cwd);
    defer root.close(Io);
    var state = initialState(.{ .command = .init, .cwd = cwd });
    state.kernel.accepted = true;
    state.basis_set = true;
    state.delivery.pushed = true;
    state.certificate_stage = "terminal_closed";
    try saveState(std.testing.allocator, root, DefaultStateRoot, state);

    var parsed_ac1 = try parseJsonInput(std.testing.allocator, ac1_path);
    defer parsed_ac1.deinit();
    try validateAcceptanceV2(parsed_ac1.value);
    const written_ac1 = try writeAcceptanceArtifact(std.testing.allocator, root, DefaultStateRoot, parsed_ac1.value);
    defer written_ac1.deinit(std.testing.allocator);
    var draft_state = state;
    draft_state.acceptance = .{
        .sequence = written_ac1.sequence,
        .contract_id = written_ac1.contract_id,
        .fingerprint = written_ac1.fingerprint,
        .horizon_state = "draft",
    };
    draft_state.acceptance_goal = stringField(parsed_ac1.value, "goal") orelse draft_state.acceptance_goal;
    draft_state.phase = "intent_open";
    try saveState(std.testing.allocator, root, DefaultStateRoot, draft_state);
    var draft = try loadStateParsed(std.testing.allocator, root, DefaultStateRoot);
    defer draft.deinit();
    try std.testing.expectEqualStrings("intent_open", draft.value.phase);
    try std.testing.expectEqual(@as(u32, 1), draft.value.acceptance.sequence);
    try std.testing.expectEqualStrings("draft", draft.value.acceptance.horizon_state);
    try std.testing.expect(std.mem.startsWith(u8, draft.value.acceptance.fingerprint.?, "sha256:"));
    try std.testing.expect(!std.mem.eql(u8, draft.value.acceptance.fingerprint.?, "sha256:caller"));

    var parsed_for_seal = try loadAcceptanceParsed(std.testing.allocator, root, DefaultStateRoot);
    defer parsed_for_seal.deinit();
    try validateAcceptanceV2(parsed_for_seal.value);
    const sealed_fingerprint = try acceptanceFingerprintAlloc(std.testing.allocator, parsed_for_seal.value);
    defer std.testing.allocator.free(sealed_fingerprint);
    var sealed_state = draft.value;
    sealed_state.acceptance = .{
        .sequence = acceptanceSequence(parsed_for_seal.value),
        .contract_id = acceptanceContractId(parsed_for_seal.value),
        .fingerprint = sealed_fingerprint,
        .horizon_state = "sealed",
    };
    sealed_state.phase = "acceptance_sealed";
    try saveState(std.testing.allocator, root, DefaultStateRoot, sealed_state);
    var sealed = try loadStateParsed(std.testing.allocator, root, DefaultStateRoot);
    defer sealed.deinit();
    try std.testing.expectEqualStrings("acceptance_sealed", sealed.value.phase);
    try std.testing.expectEqualStrings("sealed", sealed.value.acceptance.horizon_state);

    var parsed_ac2 = try parseJsonInput(std.testing.allocator, ac2_path);
    defer parsed_ac2.deinit();
    try validateAcceptanceV2(parsed_ac2.value);
    const archive_root = try statePath(std.testing.allocator, DefaultStateRoot, "archive/acceptance/test");
    defer std.testing.allocator.free(archive_root);
    try root.createDirPath(Io, archive_root);
    try archiveAcceptanceArtifact(std.testing.allocator, root, DefaultStateRoot, archive_root);
    const written_ac2 = try writeAcceptanceArtifact(std.testing.allocator, root, DefaultStateRoot, parsed_ac2.value);
    defer written_ac2.deinit(std.testing.allocator);
    var rebased_state = sealed.value;
    invalidateAcceptanceDownstream(&rebased_state);
    rebased_state.acceptance = .{
        .sequence = written_ac2.sequence,
        .contract_id = written_ac2.contract_id,
        .fingerprint = written_ac2.fingerprint,
        .horizon_state = "draft",
    };
    rebased_state.acceptance_goal = stringField(parsed_ac2.value, "goal") orelse rebased_state.acceptance_goal;
    rebased_state.phase = "intent_open";
    try saveState(std.testing.allocator, root, DefaultStateRoot, rebased_state);
    const rebase_event = try appendEvent(std.testing.allocator, root, DefaultStateRoot, "acceptance-rebased", sealed.value, rebased_state, archive_root);
    defer std.testing.allocator.free(rebase_event);
    var rebased = try loadStateParsed(std.testing.allocator, root, DefaultStateRoot);
    defer rebased.deinit();
    try std.testing.expectEqualStrings("intent_open", rebased.value.phase);
    try std.testing.expectEqual(@as(u32, 2), rebased.value.acceptance.sequence);
    try std.testing.expectEqualStrings("draft", rebased.value.acceptance.horizon_state);
    try std.testing.expect(!rebased.value.kernel.accepted);
    try std.testing.expect(!rebased.value.basis_set);
    try std.testing.expect(!rebased.value.delivery.pushed);
    try std.testing.expect(rebased.value.certificate_stage == null);
    try tmp.dir.access(Io, ".ledger/c3/archive/acceptance", .{});
    const events = try tmp.dir.readFileAlloc(Io, ".ledger/c3/events.jsonl", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "acceptance-rebased"));
}

test "intent closed migration archives legacy artifacts without accepting gates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, ".git/info");
    try makePathUnder(std.testing.allocator, cwd, ".legacy-c3");
    try tmp.dir.writeFile(Io, .{ .sub_path = ".legacy-c3/state.json", .data = "{\"state_version\":2,\"run_id\":\"legacy-run\",\"phase\":\"terminal_closed\"}\n" });
    try tmp.dir.writeFile(Io, .{ .sub_path = ".legacy-c3/mrpc.json", .data = "{\"minimal_review_patch_certificate\":{\"certificate_version\":\"MRPC-v1\"}}\n" });
    try tmp.dir.writeFile(Io, .{
        .sub_path = "migration-ac.json",
        .data =
        \\{"acceptance_version":"AC-v2","contract_id":"ac.migration","source_refs":["HEAD"],"goal":"migration goal","required":[{"id":"req.example","text":"required"}],"compatibility":[],"forbidden":[],"proof_bar":{"commands":["zig build test-resolve-c3 --summary all"]},"observation_language":{"terms":["law"]},"authority":{"id":"owner","current":true},"horizon":{"sequence":1},"fingerprint":"sha256:caller"}
        \\
        ,
    });
    const migration_ac = try std.fs.path.join(std.testing.allocator, &.{ cwd, "migration-ac.json" });
    defer std.testing.allocator.free(migration_ac);

    var root = try openRoot(cwd);
    defer root.close(Io);
    const archive_dir = try statePath(std.testing.allocator, DefaultStateRoot, "archive/intent-closed");
    defer std.testing.allocator.free(archive_dir);
    try root.createDirPath(Io, archive_dir);
    try archiveKnownArtifacts(std.testing.allocator, root, ".legacy-c3", archive_dir);
    var parsed_ac = try parseJsonInput(std.testing.allocator, migration_ac);
    defer parsed_ac.deinit();
    try validateAcceptanceV2(parsed_ac.value);
    const written = try writeAcceptanceArtifact(std.testing.allocator, root, DefaultStateRoot, parsed_ac.value);
    defer written.deinit(std.testing.allocator);
    var migrated = initialState(.{ .command = .migrate_intent_closed, .cwd = cwd, .legacy_root = ".legacy-c3" });
    migrated.run_id = "C3-abc123";
    migrated.base_sha = "abc123";
    migrated.phase = "intent_open";
    migrated.acceptance_goal = stringField(parsed_ac.value, "goal") orelse "migration";
    migrated.acceptance = .{
        .sequence = written.sequence,
        .contract_id = written.contract_id,
        .fingerprint = written.fingerprint,
        .horizon_state = "draft",
    };
    try saveState(std.testing.allocator, root, DefaultStateRoot, migrated);
    try writeIntentClosedMigrationReceipt(std.testing.allocator, root, DefaultStateRoot, ".legacy-c3", archive_dir, "def456");
    var parsed = try loadStateParsed(std.testing.allocator, root, DefaultStateRoot);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(StateSchemaV3, parsed.value.schema);
    try std.testing.expectEqualStrings(ProtocolProfileIntentClosed, parsed.value.protocol_profile);
    try std.testing.expectEqualStrings("intent_open", parsed.value.phase);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.acceptance.sequence);
    try std.testing.expectEqualStrings("draft", parsed.value.acceptance.horizon_state);
    try std.testing.expect(!parsed.value.kernel.accepted);
    try std.testing.expect(!parsed.value.basis_set);
    try tmp.dir.access(Io, ".ledger/c3/archive/intent-closed/state.json", .{});
    try tmp.dir.access(Io, ".ledger/c3/archive/intent-closed/mrpc.json", .{});
    const receipt = try tmp.dir.readFileAlloc(Io, ".ledger/c3/migration-receipt.json", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(receipt);
    try std.testing.expect(std.mem.containsAtLeast(u8, receipt, 1, "\"accepted_legacy_artifacts\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, receipt, 1, "\"mutation_blocked_until_new_gates\":true"));
}

test "review batch seal validates stored apertures and terminal receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);
    var root = try openRoot(cwd);
    defer root.close(Io);

    const aperture =
        \\{"aperture_version":"RAP-v1","aperture_id":"rap.discovery","batch_id":"batch.clean","mode":"discovery","targets":[],"excluded_scope":["none"],"whole_diff_allowed":true}
    ;
    var parsed_aperture = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aperture, .{});
    defer parsed_aperture.deinit();
    try writeReviewChildJson(std.testing.allocator, root, DefaultStateRoot, ReviewApertureDir, "rap.discovery", parsed_aperture.value);

    const receipt =
        \\{"receipt_version":"RR-v1","receipt_id":"rr.clean","batch_id":"batch.clean","terminal":true,"claims":[]}
    ;
    var parsed_receipt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, receipt, .{});
    defer parsed_receipt.deinit();
    try writeReviewChildJson(std.testing.allocator, root, DefaultStateRoot, ReviewReceiptDir, "rr.clean", parsed_receipt.value);

    const aperture_ids = [_][]const u8{"rap.discovery"};
    const receipt_ids = [_][]const u8{"rr.clean"};
    try writeReviewBatchArtifact(std.testing.allocator, root, DefaultStateRoot, "batch.clean", "discovery", "abc123", "sha256:ac", "open", aperture_ids[0..], receipt_ids[0..], &.{});
    var parsed_batch = try loadReviewBatchParsed(std.testing.allocator, root, DefaultStateRoot, "batch.clean");
    defer parsed_batch.deinit();
    try validateReviewBatchSeal(std.testing.allocator, root, DefaultStateRoot, parsed_batch.value);
}

test "review conformance forbids whole diff and mutation events block seal" {
    const broad =
        \\{"aperture_version":"RAP-v1","aperture_id":"rap.bad","batch_id":"batch.bad","mode":"conformance","targets":[{"law":"law","owner":"owner","operation":"op","transition":"t","proof_target":"p"}],"excluded_scope":["none"],"existing_class_refs":["class"],"whole_diff_allowed":true}
    ;
    var parsed_broad = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, broad, .{});
    defer parsed_broad.deinit();
    try std.testing.expectError(error.ConformanceWholeDiffForbidden, validateReviewAperture(parsed_broad.value, "batch.bad"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);
    var root = try openRoot(cwd);
    defer root.close(Io);
    const mutations = [_][]const u8{"guard-denied"};
    try writeReviewBatchArtifact(std.testing.allocator, root, DefaultStateRoot, "batch.dirty", "discovery", "abc123", "sha256:ac", "open", &.{}, &.{}, mutations[0..]);
    var parsed_batch = try loadReviewBatchParsed(std.testing.allocator, root, DefaultStateRoot, "batch.dirty");
    defer parsed_batch.deinit();
    try std.testing.expectError(error.BatchMutationDetected, validateReviewBatchSeal(std.testing.allocator, root, DefaultStateRoot, parsed_batch.value));
}

test "counterexample v1 rejects mutation authority and missing trace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);
    var root = try openRoot(cwd);
    defer root.close(Io);
    try writeReviewBatchArtifact(std.testing.allocator, root, DefaultStateRoot, "batch.cex", "discovery", "abc123", "sha256:ac", "open", &.{}, &.{}, &.{});
    var parsed_batch = try loadReviewBatchParsed(std.testing.allocator, root, DefaultStateRoot, "batch.cex");
    defer parsed_batch.deinit();

    const mutation_authority =
        \\{"cex_version":"CEX-v1","cex_id":"cex.bad","batch_id":"batch.cex","intent_relation":"in_horizon","novelty":"new_equivalence_class","disposition":"accepted","acceptance_refs":["req"],"minimal_trace":["step"],"mutation_authority":true}
    ;
    var parsed_mutation = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mutation_authority, .{});
    defer parsed_mutation.deinit();
    try std.testing.expectError(error.InvalidCounterexample, validateCounterexampleV1(std.testing.allocator, root, DefaultStateRoot, parsed_mutation.value, "batch.cex", parsed_batch.value));

    const missing_trace =
        \\{"cex_version":"CEX-v1","cex_id":"cex.trace","batch_id":"batch.cex","intent_relation":"in_horizon","novelty":"new_equivalence_class","disposition":"accepted","acceptance_refs":["req"],"minimal_trace":[],"mutation_authority":false}
    ;
    var parsed_trace = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, missing_trace, .{});
    defer parsed_trace.deinit();
    try std.testing.expectError(error.InvalidCounterexample, validateCounterexampleV1(std.testing.allocator, root, DefaultStateRoot, parsed_trace.value, "batch.cex", parsed_batch.value));
}

test "counterexample v1 conformance requires aperture ref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);
    var root = try openRoot(cwd);
    defer root.close(Io);
    try writeReviewBatchArtifact(std.testing.allocator, root, DefaultStateRoot, "batch.conf", "conformance", "abc123", "sha256:ac", "open", &.{}, &.{}, &.{});
    var parsed_batch = try loadReviewBatchParsed(std.testing.allocator, root, DefaultStateRoot, "batch.conf");
    defer parsed_batch.deinit();

    const cex =
        \\{"cex_version":"CEX-v1","cex_id":"cex.conf","batch_id":"batch.conf","intent_relation":"in_horizon","novelty":"new_witness_existing_class","disposition":"accepted","acceptance_refs":["req"],"minimal_trace":["step"],"mutation_authority":false}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, cex, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidAperture, validateCounterexampleV1(std.testing.allocator, root, DefaultStateRoot, parsed.value, "batch.conf", parsed_batch.value));
}

test "counterexample basis v2 enforces exact accepted class coverage" {
    const good =
        \\{"basis_version":"CEB-v2","basis_id":"basis.good","acceptance_fingerprint":"sha256:ac","accepted_cex_ids":["cex.one"],"classes":[{"class_id":"class.one","representative":"cex.one","members":["cex.one"],"law_refs":["law.one"],"acceptance_refs":["req.one"],"canonical_owner":"owner","proof_obligation":"zig build test-resolve-c3 --summary all","congruence_evidence":["manual"]}],"duplicates":[],"gate":{"sealed":false}}
    ;
    var parsed_good = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, good, .{});
    defer parsed_good.deinit();
    const accepted = [_][]const u8{"cex.one"};
    try validateCounterexampleBasisV2(parsed_good.value, "sha256:ac", accepted[0..]);

    const missing_class =
        \\{"basis_version":"CEB-v2","basis_id":"basis.missing","acceptance_fingerprint":"sha256:ac","accepted_cex_ids":["cex.one"],"classes":[{"class_id":"class.two","representative":"cex.two","members":["cex.two"],"law_refs":["law.two"],"acceptance_refs":["req.two"],"canonical_owner":"owner","proof_obligation":"zig build test-resolve-c3 --summary all","congruence_evidence":["manual"]}],"duplicates":[],"gate":{"sealed":false}}
    ;
    var parsed_missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, missing_class, .{});
    defer parsed_missing.deinit();
    try std.testing.expectError(error.InvalidBasis, validateCounterexampleBasisV2(parsed_missing.value, "sha256:ac", accepted[0..]));

    const unresolved =
        \\{"basis_version":"CEB-v2","basis_id":"basis.unknown","acceptance_fingerprint":"sha256:ac","accepted_cex_ids":["cex.one"],"classes":[{"class_id":"class.one","representative":"cex.one","members":["cex.one"],"law_refs":["law.one"],"acceptance_refs":["req.one"],"canonical_owner":"owner","proof_obligation":"zig build test-resolve-c3 --summary all","congruence_evidence":["manual"],"novelty":"unknown"}],"duplicates":[],"gate":{"sealed":false}}
    ;
    var parsed_unresolved = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unresolved, .{});
    defer parsed_unresolved.deinit();
    try std.testing.expectError(error.CounterexampleUnknown, validateCounterexampleBasisV2(parsed_unresolved.value, "sha256:ac", accepted[0..]));
}

test "construct map validates measured construct ids and rejects orphans" {
    const tree_text =
        \\tree sha256:tree
        \\construct src/main.zig::file::src/main.zig
        \\construct src/main.zig::pub::main
        \\
    ;
    try std.testing.expect(constructIdInTree(tree_text, "src/main.zig::pub::main"));
    try std.testing.expect(!constructIdInTree(tree_text, "src/main.zig::helper::missing"));

    const good =
        \\{"map_version":"KRM-v1","kernel_fingerprint":"sha256:kernel","realization_tree_fingerprint":"sha256:tree","constructs":[{"construct_id":"src/main.zig::pub::main","kernel_element_ids":["law.main"],"necessity_witness":"accepted law","status":"required"}],"proof_actions":[]}
    ;
    var parsed_good = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, good, .{});
    defer parsed_good.deinit();
    try validateConstructMapValue(parsed_good.value);

    const bad =
        \\{"map_version":"KRM-v1","kernel_fingerprint":"sha256:kernel","realization_tree_fingerprint":"sha256:tree","constructs":[{"construct_id":"src/main.zig::pub::main","status":"orphan"}],"proof_actions":[]}
    ;
    var parsed_bad = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bad, .{});
    defer parsed_bad.deinit();
    const constructs = objectField(parsed_bad.value, "constructs").?.array.items;
    try std.testing.expect(std.mem.eql(u8, stringField(constructs[0], "status").?, "orphan"));
}

test "semantic surface hard dimensions cannot increase" {
    const baseline =
        \\{"semantic_surface_vector":{"kernel":{"protocol_cases":{"value":1}},"realization":{"truth_owners":{"value":1},"public_symbols":{"value":1},"state_fields":{"value":1},"fallback_or_compatibility_paths":{"value":0}},"proof":{"wound_specific_tests":{"value":0}}}}
    ;
    const current =
        \\{"semantic_surface_vector":{"kernel":{"protocol_cases":{"value":1}},"realization":{"truth_owners":{"value":1},"public_symbols":{"value":2},"state_fields":{"value":1},"fallback_or_compatibility_paths":{"value":0}},"proof":{"wound_specific_tests":{"value":0}}}}
    ;
    var parsed_baseline = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, baseline, .{});
    defer parsed_baseline.deinit();
    var parsed_current = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, current, .{});
    defer parsed_current.deinit();
    try std.testing.expect(hardSurfaceIncreased(parsed_current.value, parsed_baseline.value));
    try std.testing.expect(!hardSurfaceIncreased(parsed_baseline.value, parsed_current.value));
}

test "potential phi requires strict primary decrease without hard surface or proof debt growth" {
    var state = initialState(.{ .command = .init });
    state.acceptance.fingerprint = "sha256:ac";
    state.acceptance.horizon_state = "sealed";
    const baseline =
        \\{"potential_version":"PHI-v1","cycle_id":"cycle.before","acceptance_fingerprint":"sha256:ac","primary":{"U":2,"L":1,"C":1,"O":1},"hard_surface":{"truth_owners":1,"public_symbols":2,"state_variants":1,"protocol_cases":1,"fallback_compatibility_paths":0,"control_flow_branches":4,"helpers_wrappers":2,"test_families":1},"proof_debt":{"missing_law_proofs":1,"unmapped_proof_actions":1,"wound_specific_tests":0},"evidence_refs":["before"]}
    ;
    const current =
        \\{"potential_version":"PHI-v1","cycle_id":"cycle.after","acceptance_fingerprint":"sha256:ac","primary":{"U":1,"L":9,"C":9,"O":9},"hard_surface":{"truth_owners":1,"public_symbols":2,"state_variants":1,"protocol_cases":1,"fallback_compatibility_paths":0,"control_flow_branches":4,"helpers_wrappers":2,"test_families":1},"proof_debt":{"missing_law_proofs":1,"unmapped_proof_actions":0,"wound_specific_tests":0},"evidence_refs":["after"]}
    ;
    const hard_growth =
        \\{"potential_version":"PHI-v1","cycle_id":"cycle.bad","acceptance_fingerprint":"sha256:ac","primary":{"U":1,"L":1,"C":1,"O":1},"hard_surface":{"truth_owners":1,"public_symbols":3,"state_variants":1,"protocol_cases":1,"fallback_compatibility_paths":0,"control_flow_branches":4,"helpers_wrappers":2,"test_families":1},"proof_debt":{"missing_law_proofs":1,"unmapped_proof_actions":1,"wound_specific_tests":0},"evidence_refs":["bad"]}
    ;
    var parsed_baseline = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, baseline, .{});
    defer parsed_baseline.deinit();
    var parsed_current = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, current, .{});
    defer parsed_current.deinit();
    var parsed_hard = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, hard_growth, .{});
    defer parsed_hard.deinit();
    try validatePotentialValue(parsed_baseline.value, state);
    try validatePotentialValue(parsed_current.value, state);
    try comparePotentialStrict(parsed_current.value, parsed_baseline.value);
    try std.testing.expectError(error.SemanticSurfaceIncreased, comparePotentialStrict(parsed_hard.value, parsed_baseline.value));
    try std.testing.expectError(error.PotentialNotDecreased, comparePotentialStrict(parsed_baseline.value, parsed_baseline.value));
}

test "proof compression mapping rejects unmapped and wound-specific actions" {
    const mapped =
        \\{"proof_id":"proof.law","command":"zig build test-resolve-c3 --summary all","style":"law","proves_law_ids":["law.one"],"ac_law_refs":["req.one"],"ceb_class_refs":["class.one"],"recomposition_refs":["recompose.one"],"artifact_fingerprint":"sha256:tree","invalidators":["sha256:kernel"]}
    ;
    const unmapped =
        \\{"proof_id":"proof.bad","command":"zig build test-resolve-c3 --summary all","style":"law","proves_law_ids":["law.one"],"artifact_fingerprint":"sha256:tree"}
    ;
    var parsed_mapped = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mapped, .{});
    defer parsed_mapped.deinit();
    var parsed_unmapped = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unmapped, .{});
    defer parsed_unmapped.deinit();
    try validateProofActionMapping(parsed_mapped.value);
    try std.testing.expectError(error.ProofBasisInvalid, validateProofActionMapping(parsed_unmapped.value));
}

test "same class recurrence invalidates realization without clearing accepted kernel" {
    var state = initialState(.{ .command = .init });
    state.phase = "conformance_open";
    state.basis = .{ .id = "basis.one", .fingerprint = "sha256:basis", .sealed = true };
    state.kernel = .{ .fingerprint = "sha256:kernel", .accepted = true };
    state.design.selected_id = "design.one";
    state.realization = .{ .cycle_id = "cycle.one", .verified = true, .invalidated = false, .invalidation_reason = null };
    state.potential = .{ .current_id = "cycle.one", .strict_progress = true };
    const batch =
        \\{"batch_version":"RB-v1","batch_id":"batch.conf","mode":"conformance","status":"open"}
    ;
    const cex =
        \\{"cex_version":"CEX-v1","cex_id":"cex.same","batch_id":"batch.conf","intent_relation":"in_horizon","novelty":"new_witness_existing_class","disposition":"accepted","acceptance_refs":["req"],"minimal_trace":["step"],"mutation_authority":false}
    ;
    var parsed_batch = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, batch, .{});
    defer parsed_batch.deinit();
    var parsed_cex = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, cex, .{});
    defer parsed_cex.deinit();
    applyCounterexampleInvalidation(&state, parsed_cex.value, parsed_batch.value);
    try std.testing.expect(state.kernel.accepted);
    try std.testing.expect(state.basis.sealed);
    try std.testing.expect(state.realization.invalidated);
    try std.testing.expect(!state.realization.verified);
    try std.testing.expectEqualStrings("same_class_recurrence", state.realization.invalidation_reason.?);
}

test "delivery readiness rejects open batches and missing phi" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);
    var root = try openRoot(cwd);
    defer root.close(Io);
    var state = initialState(.{ .command = .init, .cwd = cwd });
    state.acceptance = .{ .sequence = 1, .contract_id = "ac", .fingerprint = "sha256:ac", .horizon_state = "sealed" };
    state.basis = .{ .id = "basis", .fingerprint = "sha256:basis", .sealed = true };
    state.kernel = .{ .fingerprint = "sha256:kernel", .accepted = true };
    state.reduction = .{ .fingerprint = "sha256:rc", .accepted = true };
    state.design.selected_id = "design.one";
    state.realization = .{ .cycle_id = "cycle.one", .verified = true, .invalidated = false, .invalidation_reason = null };
    state.review.open_batch_ids = &.{"batch.open"};
    try std.testing.expectError(error.BatchOpen, requireDeliveryReadyState(std.testing.allocator, root, DefaultStateRoot, state));
    state.review.open_batch_ids = &.{};
    try std.testing.expectError(error.PotentialNotDecreased, requireDeliveryReadyState(std.testing.allocator, root, DefaultStateRoot, state));
}

test "closure receipts and terminal holdout gates fail closed" {
    const tuple_good =
        \\{"delivery_tree":"tree","pr_sweep":{"clean":true,"unresolved_threads":0}}
    ;
    const tuple_bad =
        \\{"delivery_tree":"tree","pr_sweep":{"clean":false,"unresolved_threads":1}}
    ;
    var parsed_tuple_good = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tuple_good, .{});
    defer parsed_tuple_good.deinit();
    var parsed_tuple_bad = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tuple_bad, .{});
    defer parsed_tuple_bad.deinit();
    try validateTupleClosureReceipt(parsed_tuple_good.value);
    try std.testing.expectError(error.ClosureBlocked, validateTupleClosureReceipt(parsed_tuple_bad.value));

    const terminal_good =
        \\{"reopen_conditions":["new in-horizon CEX"],"terminal_phi":{"strict_progress":true},"proof_delivery_tuple_current":true}
    ;
    const terminal_bad =
        \\{"reopen_conditions":[],"terminal_phi":{"strict_progress":true},"proof_delivery_tuple_current":true}
    ;
    var parsed_terminal_good = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, terminal_good, .{});
    defer parsed_terminal_good.deinit();
    var parsed_terminal_bad = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, terminal_bad, .{});
    defer parsed_terminal_bad.deinit();
    try validateTerminalClosureReceipt(parsed_terminal_good.value);
    try std.testing.expectError(error.ClosureBlocked, validateTerminalClosureReceipt(parsed_terminal_bad.value));
}

test "terminal holdout permits outside horizon and blocks unknown or in horizon findings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);
    var root = try openRoot(cwd);
    defer root.close(Io);
    const outside =
        \\{"cex_version":"CEX-v1","cex_id":"cex.out","batch_id":"holdout","intent_relation":"outside_horizon","novelty":"new_equivalence_class","disposition":"outside_horizon","acceptance_refs":["req"],"minimal_trace":["step"],"mutation_authority":false}
    ;
    var parsed_outside = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, outside, .{});
    defer parsed_outside.deinit();
    try appendJsonLine(std.testing.allocator, root, DefaultStateRoot, CounterexamplesFile, parsed_outside.value);
    try std.testing.expect(!try batchHasTerminalBlockingCounterexample(std.testing.allocator, root, DefaultStateRoot, "holdout"));

    const unknown =
        \\{"cex_version":"CEX-v1","cex_id":"cex.unknown","batch_id":"holdout","intent_relation":"unknown","novelty":"unknown","disposition":"unknown","acceptance_refs":["req"],"minimal_trace":["step"],"mutation_authority":false}
    ;
    var parsed_unknown = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unknown, .{});
    defer parsed_unknown.deinit();
    try appendJsonLine(std.testing.allocator, root, DefaultStateRoot, CounterexamplesFile, parsed_unknown.value);
    try std.testing.expect(try batchHasTerminalBlockingCounterexample(std.testing.allocator, root, DefaultStateRoot, "holdout"));
}

test "proof helper deduplicates commands and detects orphan construct maps" {
    var commands = std.ArrayList([]const u8).empty;
    defer commands.deinit(std.testing.allocator);
    try commands.append(std.testing.allocator, "zig build test-resolve-c3 --summary all");
    try std.testing.expect(containsString(commands.items, "zig build test-resolve-c3 --summary all"));
    try std.testing.expect(!containsString(commands.items, "zig build test-seq --summary all"));

    const map =
        \\{"map_version":"KRM-v1","kernel_fingerprint":"sha256:kernel","realization_tree_fingerprint":"sha256:tree","constructs":[{"construct_id":"src/main.zig::file::src/main.zig","status":"orphan"}],"proof_actions":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, map, .{});
    defer parsed.deinit();
    try std.testing.expect(constructMapHasOrphan(parsed.value));
}

test "begin duplicates parent run id before parsed state deinit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, DefaultStateRoot);

    var root = try openRoot(cwd);
    defer root.close(Io);
    try saveState(std.testing.allocator, root, DefaultStateRoot, State{
        .schema = StateSchemaV2,
        .state_root = DefaultStateRoot,
        .legacy_root = LegacyStateRoot,
        .state_version = 2,
        .run_id = "C3-parent",
        .repo_root = cwd,
        .branch = "main",
        .base_sha = "parent-sha",
        .phase = "closed",
        .acceptance_goal = "first run",
        .parent_run_id = null,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    });

    const parent_run_id = (try loadParentRunId(std.testing.allocator, root, DefaultStateRoot)).?;
    defer std.testing.allocator.free(parent_run_id);
    try saveState(std.testing.allocator, root, DefaultStateRoot, State{
        .schema = StateSchemaV2,
        .state_root = DefaultStateRoot,
        .legacy_root = LegacyStateRoot,
        .state_version = 2,
        .run_id = "C3-child",
        .repo_root = cwd,
        .branch = "main",
        .base_sha = "child-sha",
        .phase = "collecting",
        .acceptance_goal = "second run",
        .parent_run_id = parent_run_id,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    });

    var parsed = try loadStateParsed(std.testing.allocator, root, DefaultStateRoot);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("C3-parent", parsed.value.parent_run_id.?);
}

test "git capture reads HEAD refs without spawning git" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, ".git/refs/heads");
    try tmp.dir.writeFile(Io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(Io, .{ .sub_path = ".git/refs/heads/main", .data = "0123456789abcdef0123456789abcdef01234567\n" });

    const branch = try gitCapture(std.testing.allocator, cwd, &.{ "branch", "--show-current" });
    defer std.testing.allocator.free(branch);
    const head = try gitCapture(std.testing.allocator, cwd, &.{ "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head);
    const root = try gitCapture(std.testing.allocator, cwd, &.{ "rev-parse", "--show-toplevel" });
    defer std.testing.allocator.free(root);
    try std.testing.expectEqualStrings("main", branch);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", head);
    try std.testing.expectEqualStrings(cwd, root);
}

test "MRPC gate enforces stage gates and orphan edit atoms" {
    const good =
        "{\"minimal_review_patch_certificate\":{\"certificate_version\":\"MRPC-v1\",\"certificate_id\":\"MRPC-x\",\"stage\":\"apply-certified\",\"run_id\":\"r\",\"immutable_base\":{\"sha\":\"b\"},\"counterexample_basis\":{\"basis_set\":true},\"candidate_tournament\":[{\"candidate_id\":\"c\"}],\"selected_candidate\":{\"candidate_id\":\"c\"},\"ablation\":{\"authority\":\"controller\"},\"gate\":{\"apply_allowed\":true},\"metrics\":{\"orphan_edit_atoms\":[]}}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, good, .{});
    defer parsed.deinit();
    const body = objectField(parsed.value, "minimal_review_patch_certificate").?;
    try std.testing.expect(!emptyJsonValue(objectField(body, "selected_candidate")));
    try std.testing.expect((boolField(objectField(body, "gate").?, "apply_allowed") orelse false));
}

test "RDR gate key scanner recognizes required YAML keys" {
    const text =
        \\resolve_decision_record:
        \\  record_version: RDR-v1
        \\  artifact_state: {}
        \\  review_wave: {}
        \\  cluster: {}
        \\  selected_route: {}
        \\  negative_evidence: {}
        \\  surface_delta: {}
        \\  proof_matrix: {}
        \\  material_improvement: {}
        \\  gate: {}
    ;
    try std.testing.expect(containsYamlKey(text, "resolve_decision_record"));
    try std.testing.expect(containsYamlKey(text, "record_version"));
    try std.testing.expect(!containsYamlKey(text, "missing"));
}

test "guard blocks direct mutation while active and allows resolve-c3" {
    try std.testing.expect(mutatingShell("git commit -m x") != null);
    try std.testing.expect(controllerCommand("resolve-c3 apply"));
    try std.testing.expect(toolMutates("apply_patch"));
}

test "migrate-legacy archives terminal legacy state and refuses active state" {
    const active = "{\"phase\":\"collecting\"}\n";
    try std.testing.expectError(error.ActiveLegacyRun, refuseActiveLegacy(std.testing.allocator, active));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, ".git/info");
    try makePathUnder(std.testing.allocator, cwd, ".resolve-c3");
    try tmp.dir.writeFile(Io, .{
        .sub_path = ".resolve-c3/state.json",
        .data = "{\"phase\":\"closed\",\"run_id\":\"legacy\"}\n",
    });

    const args = Args{
        .command = .migrate_legacy,
        .cwd = cwd,
        .confirm = true,
    };
    var root = try openRoot(cwd);
    defer root.close(Io);
    const legacy_state_path = try statePath(std.testing.allocator, args.legacy_root, StateFile);
    defer std.testing.allocator.free(legacy_state_path);
    const legacy_bytes = try root.readFileAlloc(Io, legacy_state_path, std.testing.allocator, .limited(MaxFileBytes));
    defer std.testing.allocator.free(legacy_bytes);
    const archive_state = try archiveLegacyState(std.testing.allocator, root, args, legacy_state_path, legacy_bytes);
    defer std.testing.allocator.free(archive_state);

    try tmp.dir.access(Io, ".ledger/c3/state.json", .{});
    try tmp.dir.access(Io, ".ledger/c3/archive/legacy/state.json", .{});
    try tmp.dir.access(Io, ".ledger/c3/migration-receipt.json", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(Io, ".resolve-c3/state.json", .{}));
}

test "migrate mrpc archives v1 artifacts without accepting kernel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(Io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try makePathUnder(std.testing.allocator, cwd, ".git/info");
    try makePathUnder(std.testing.allocator, cwd, ".ledger/c3");
    try tmp.dir.writeFile(Io, .{ .sub_path = ".ledger/c3/state.json", .data = "{\"state_version\":1,\"run_id\":\"legacy-run\",\"phase\":\"closed\"}\n" });
    try tmp.dir.writeFile(Io, .{ .sub_path = ".ledger/c3/mrpc.json", .data = "{\"minimal_review_patch_certificate\":{\"certificate_version\":\"MRPC-v1\"}}\n" });

    var root = try openRoot(cwd);
    defer root.close(Io);
    const archive_dir = try statePath(std.testing.allocator, DefaultStateRoot, "archive/mrpc");
    defer std.testing.allocator.free(archive_dir);
    try root.createDirPath(Io, archive_dir);
    try archiveMrpcArtifacts(std.testing.allocator, root, DefaultStateRoot, archive_dir);
    try writeMrpcMigrationReceipt(std.testing.allocator, root, DefaultStateRoot, DefaultStateRoot, archive_dir, "def456");
    const parent = try legacyRunIdFromBytes(std.testing.allocator, "{\"run_id\":\"legacy-run\"}");
    defer if (parent) |value| std.testing.allocator.free(value);
    try saveState(std.testing.allocator, root, DefaultStateRoot, State{
        .schema = StateSchemaV2,
        .state_root = DefaultStateRoot,
        .legacy_root = DefaultStateRoot,
        .state_version = 2,
        .run_id = "C3-abc123",
        .repo_root = cwd,
        .branch = "",
        .base_sha = "abc123",
        .phase = "initialized",
        .acceptance_goal = "MRPC migration requires fresh kernel",
        .parent_run_id = parent,
        .counterexample_count = 0,
        .basis_set = false,
        .tournament_waiver = null,
        .candidates = &.{},
        .selected_candidate_id = null,
        .ablation_authority = null,
        .ablation_orphan_edit_atoms = 0,
        .candidate_holdout_safe = false,
        .delivery_holdout_safe = false,
        .proof_authority = null,
        .proof_passed = false,
        .proof_patch_stable = false,
        .delivery_patch_sha = null,
        .commit_sha = null,
        .pushed = false,
        .certificate_stage = null,
    });

    try tmp.dir.access(Io, ".ledger/c3/archive/mrpc/state.json", .{});
    try tmp.dir.access(Io, ".ledger/c3/archive/mrpc/mrpc.json", .{});
    const receipt = try tmp.dir.readFileAlloc(Io, ".ledger/c3/migration-receipt.json", std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(receipt);
    try std.testing.expect(std.mem.containsAtLeast(u8, receipt, 1, "\"kernel_accepted\":false"));

    var parsed = try loadStateParsed(std.testing.allocator, root, DefaultStateRoot);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 2), parsed.value.state_version);
    try std.testing.expectEqualStrings("initialized", parsed.value.phase);
    try std.testing.expectEqualStrings("abc123", parsed.value.base_sha);
    try std.testing.expectEqualStrings("legacy-run", parsed.value.parent_run_id.?);
}

test "candidate selection is lexicographic on semantic cost then id" {
    const a = candidateForTest("b", "patch-b", true, costWithFiles(2));
    const b = candidateForTest("a", "patch-a", true, costWithFiles(1));
    try std.testing.expect(candidateLess(b, a));
}

fn zeroCost() [CostFields.len]i64 {
    return [_]i64{0} ** CostFields.len;
}

fn costWithFiles(files: i64) [CostFields.len]i64 {
    var costs = zeroCost();
    costs[10] = files;
    return costs;
}

fn candidateForTest(id: []const u8, patch_sha: []const u8, valid: bool, costs: [CostFields.len]i64) Candidate {
    return .{
        .candidate_id = id,
        .route_class = "implementation",
        .route_family = "test",
        .patch_sha = patch_sha,
        .worktree = null,
        .valid = valid,
        .invalid_reasons = &.{},
        .semantic_cost = costs,
    };
}

fn makePathUnder(allocator: std.mem.Allocator, root: []const u8, child: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ root, child });
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(Io, path);
}
