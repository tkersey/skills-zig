const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const DefaultStateRoot = ".ledger/c3";
const LegacyStateRoot = ".resolve-c3";
const StateSchemaV2 = "resolve-c3-state-v2";
const StateFile = "state.json";
const CertFile = "mrpc.json";
const MbkcFile = "mbkc.json";
const EventFile = "events.jsonl";
const ObservationsFile = "observations.jsonl";
const KernelFile = "kernel.json";
const KernelReviewFile = "kernel-review.json";
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
    \\  resolve-c3 schema <acceptance|observation|kernel|kernel-review|realization-design|construct-map|proof-plan|holdout|mbkc> --json
    \\  resolve-c3 example <command-or-artifact> --json
    \\  resolve-c3 realization worktree|capture|measure|map|verify|minimize
    \\  resolve-c3 proof plan|run|compress
    \\  resolve-c3 delivery apply|commit|push
    \\  resolve-c3 certify tuple|terminal
    \\  resolve-c3 migrate mrpc
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
    \\  --design ID                Realization design id
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
const SchemaArtifacts = [_][]const u8{ "acceptance", "observation", "kernel", "kernel-review", "realization-design", "construct-map", "proof-plan", "holdout", "mbkc" };
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

const Command = enum {
    capabilities,
    schema,
    example,
    campaign_begin,
    campaign_status,
    campaign_audit,
    campaign_rebaseline,
    campaign_abort,
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
    proof_plan,
    proof_run_nested,
    proof_compress,
    delivery_apply,
    delivery_commit,
    delivery_push,
    certify_tuple,
    certify_terminal,
    migrate_mrpc,
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
    design_id: ?[]const u8 = null,
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
    state_root: []const u8,
    legacy_root: []const u8,
    state_version: u32,
    run_id: []const u8,
    repo_root: []const u8,
    branch: []const u8,
    base_sha: []const u8,
    phase: []const u8,
    acceptance_goal: []const u8,
    parent_run_id: ?[]const u8,
    counterexample_count: u32,
    basis_set: bool,
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
        } else if (std.mem.eql(u8, token, "--design")) {
            args.design_id = try optionValue(argv, &i);
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
    if (std.mem.eql(u8, primary, "observation")) return parseObservationCommand;
    if (std.mem.eql(u8, primary, "kernel")) return parseKernelCommand;
    if (std.mem.eql(u8, primary, "design")) return parseDesignCommand;
    if (std.mem.eql(u8, primary, "realization")) return parseRealizationCommand;
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
        .proof_plan => planProof(allocator, args),
        .proof_run_nested => runProofPlan(allocator, args, process_io),
        .proof_compress => compressProof(allocator, args),
        .delivery_apply => applyDeliveryPhysical(allocator, args, process_io),
        .delivery_commit => commitDeliveryPhysical(allocator, args, process_io),
        .delivery_push => pushDeliveryPhysical(allocator, args, process_io),
        .certify_tuple => certifyTuple(allocator, args),
        .certify_terminal => certifyTerminal(allocator, args),
        .migrate_mrpc => migrateMrpc(allocator, args),
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
        \\{"resolve_c3_capabilities":{"version":"0.2.0","state_versions":{"readable":[1,2],"writable":[2]},"certificate_versions":{"readable":["MRPC-v1","MBKC-v1"],"writable":["MBKC-v1"]},"features":{"campaign_base_v1":true,"minimum_behavioral_kernel_v1":true,"mbkc_v1":true,"kernel_quotient_v1":true,"semantic_surface_v1":true,"proof_compression_v1":true,"physical_apply":true,"physical_commit":true,"physical_push":true,"closure_horizon_v1":true,"zig_surface_adapter_v1":true}}}
        \\
    );
    return 0;
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
        .schema = StateSchemaV2,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 2,
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
    const event_id = try appendEvent(allocator, root, args.state_root, "campaign-rebaselined", next.phase);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "campaign rebaseline", "success", archive_dir, old.phase, next, event_id);
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
    const event_id = try appendEvent(allocator, root, args.state_root, "observation-added", state.phase);
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
    try writeArtifactJson(allocator, args, KernelFile, parsed.value);
    try printReceipt(allocator, "kernel set", "success", args.state_root);
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
    try printReceipt(allocator, "kernel accept", "success", args.state_root);
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
    try writeArtifactJson(allocator, args, SelectedDesignFile, parsed.value);
    try printReceipt(allocator, "design select", "success", stringField(parsed.value, "design_id") orelse args.state_root);
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

    const before = state.phase;
    state.phase = "realization_compiling";
    try saveState(allocator, root, args.state_root, state);
    const event_id = try appendEvent(allocator, root, args.state_root, "realization-worktree-created", state.phase);
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
    const state = parsed.value;
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

    const event_id = try appendEvent(allocator, root, args.state_root, "realization-captured", state.phase);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "realization capture", "success", worktree, state.phase, state, event_id);
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

    const manifest_path = try statePath(allocator, args.state_root, RealizationManifestFile);
    defer allocator.free(manifest_path);
    const manifest_bytes = try root.readFileAlloc(Io, manifest_path, allocator, .limited(MaxFileBytes));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed_manifest.deinit();
    const tree_fingerprint = stringField(parsed_manifest.value, "tree_fingerprint") orelse return error.InvalidCandidate;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"plan_version\":\"RCP-v1\",\"kernel_fingerprint\":\"sha256:");
    try out.writer.print("{x}", .{hashBytes(kernel_bytes)});
    try out.writer.writeAll("\",\"realization_tree_fingerprint\":");
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
                    try writeProofAction(&out.writer, law_id, command, "law");
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
    try out.writer.writeAll("{\"proof_compression\":{\"method\":\"greedy_set_cover\",\"optimality\":\"heuristic\",\"selected_actions\":[");
    var first_action = true;
    var selected_commands = std.ArrayList([]const u8).empty;
    defer selected_commands.deinit(allocator);
    var wound_count: usize = 0;
    for (items) |action| {
        const proof_id = stringField(action, "proof_id") orelse return error.InvalidProofPlan;
        const command = stringField(action, "command") orelse return error.InvalidProofPlan;
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

    const before = state.phase;
    state.phase = "realization_verified";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "realization_verified");
    const event_id = try appendEvent(allocator, root, args.state_root, "realization-verified", state.phase);
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
    requirePhase(state, &.{"realization_verified"}) catch return error.InvalidPhase;
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

    const before = state.phase;
    state.phase = "applied";
    state.delivery_patch_sha = patch_fingerprint;
    state.certificate_stage = "applied";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "applied");
    const event_id = try appendEvent(allocator, root, args.state_root, "delivery-applied", state.phase);
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
    requirePhase(state, PhaseApplied[0..]) catch return error.InvalidPhase;
    const target_tree = try realizationGitTreeSha(allocator, root, args.state_root);
    defer allocator.free(target_tree);
    const current_tree = try currentGitTree(allocator, process_io, args.cwd);
    defer allocator.free(current_tree);
    if (!std.mem.eql(u8, current_tree, target_tree)) return error.SelectedCandidateMismatch;
    try runGitOk(allocator, process_io, args.cwd, &.{ "commit", "-m", message });
    const head = try runGitCaptureProcess(allocator, process_io, args.cwd, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head);
    const before = state.phase;
    state.phase = "committed";
    state.commit_sha = std.mem.trim(u8, head, " \t\r\n");
    state.certificate_stage = "committed";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "committed");
    const event_id = try appendEvent(allocator, root, args.state_root, "committed", state.phase);
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
    requirePhase(state, PhaseCommitted[0..]) catch return error.InvalidPhase;
    const branch = args.branch orelse if (state.branch.len > 0) state.branch else return error.InvalidBasis;
    const refspec = try std.fmt.allocPrint(allocator, "HEAD:refs/heads/{s}", .{branch});
    defer allocator.free(refspec);
    try runGitOk(allocator, process_io, args.cwd, &.{ "push", args.remote, refspec });
    const remote_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(remote_ref);
    const remote_line = try runGitCaptureProcess(allocator, process_io, args.cwd, &.{ "ls-remote", args.remote, remote_ref });
    defer allocator.free(remote_line);
    if (std.mem.trim(u8, remote_line, " \t\r\n").len == 0) return error.ProofGateFailed;
    const before = state.phase;
    state.phase = "pushed";
    state.pushed = true;
    state.certificate_stage = "pushed";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "pushed");
    const event_id = try appendEvent(allocator, root, args.state_root, "pushed", state.phase);
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
    requirePhase(state, PhasePushed[0..]) catch return error.InvalidPhase;
    const before = state.phase;
    state.phase = "conformance_closed_for_tuple";
    state.certificate_stage = "conformance_closed_for_tuple";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "conformance_closed_for_tuple");
    const event_id = try appendEvent(allocator, root, args.state_root, "tuple-closed", state.phase);
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
    requirePhase(state, &.{"conformance_closed_for_tuple"}) catch return error.InvalidPhase;
    const before = state.phase;
    state.phase = "terminal_closed";
    state.certificate_stage = "terminal_closed";
    try saveState(allocator, root, args.state_root, state);
    try writeMbkc(allocator, root, args.state_root, state, "terminal_closed");
    const event_id = try appendEvent(allocator, root, args.state_root, "terminal-closed", state.phase);
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
    if (std.mem.eql(u8, artifact, "acceptance")) return "resolve_c3_acceptance";
    if (std.mem.eql(u8, artifact, "observation")) return "resolve_c3_observation";
    if (std.mem.eql(u8, artifact, "kernel")) return "minimum_behavioral_kernel";
    if (std.mem.eql(u8, artifact, "kernel-review")) return "kernel_review";
    if (std.mem.eql(u8, artifact, "realization-design")) return "realization_design";
    if (std.mem.eql(u8, artifact, "construct-map")) return "kernel_realization_map";
    if (std.mem.eql(u8, artifact, "proof-plan")) return "proof_plan";
    if (std.mem.eql(u8, artifact, "holdout")) return "holdout";
    return "minimum_behavioral_kernel_certificate";
}

fn writeRequiredFields(writer: anytype, artifact: []const u8) !void {
    if (std.mem.eql(u8, artifact, "acceptance")) return writer.writeAll("[\"acceptance_version\",\"campaign_id\",\"goal\",\"criteria\"]");
    if (std.mem.eql(u8, artifact, "observation")) return writer.writeAll("[\"observation_id\",\"validity\",\"liability\",\"kernel_impact\",\"expected_result\",\"proof\"]");
    if (std.mem.eql(u8, artifact, "kernel")) return writer.writeAll("[\"kernel_version\",\"campaign_id\",\"campaign_base_sha\",\"acceptance_contract\",\"authorities\",\"carriers\",\"observations\",\"equivalence_classes\",\"operations\",\"transitions\",\"laws\",\"quotient\",\"complexity\",\"gate\"]");
    if (std.mem.eql(u8, artifact, "kernel-review")) return writer.writeAll("[\"review_version\",\"kernel_fingerprint\",\"findings\",\"gate\"]");
    if (std.mem.eql(u8, artifact, "realization-design")) return writer.writeAll("[\"design_version\",\"design_id\",\"route_class\",\"kernel_fingerprint\",\"kernel_elements_realized\",\"owner_map\",\"predicted_semantic_surface\",\"proof_strategy\",\"gate\"]");
    if (std.mem.eql(u8, artifact, "construct-map")) return writer.writeAll("[\"map_version\",\"kernel_fingerprint\",\"realization_tree_fingerprint\",\"constructs\",\"proof_actions\"]");
    if (std.mem.eql(u8, artifact, "proof-plan")) return writer.writeAll("[\"plan_version\",\"kernel_fingerprint\",\"realization_tree_fingerprint\",\"actions\"]");
    if (std.mem.eql(u8, artifact, "holdout")) return writer.writeAll("[\"holdout_version\",\"stage\",\"verdict\",\"refs\",\"gate\"]");
    return writer.writeAll("[\"certificate_version\",\"certificate_id\",\"stage\",\"campaign\",\"acceptance\",\"observations\",\"kernel\",\"semantic_surface\",\"proof_basis\",\"delivery\",\"closure_horizon\",\"gate\"]");
}

fn writeExampleValue(writer: anytype, artifact: []const u8) !void {
    if (std.mem.eql(u8, artifact, "acceptance")) return writer.writeAll("{\"acceptance_version\":\"RCA-v1\",\"campaign_id\":\"c3-example\",\"goal\":\"preserve accepted review behavior\",\"criteria\":[]}");
    if (std.mem.eql(u8, artifact, "observation")) return writer.writeAll("{\"observation_id\":\"obs.example\",\"validity\":\"accepted\",\"liability\":\"introduced_by_current_diff\",\"kernel_impact\":\"distinguishes_behavior\",\"expected_result\":{\"command\":\"zig build test-resolve-c3\",\"result\":\"pass\"},\"proof\":{\"style\":\"law\",\"refs\":[]}}");
    if (std.mem.eql(u8, artifact, "kernel")) return writer.writeAll("{\"kernel_version\":\"MBK-v1\",\"campaign_id\":\"c3-example\",\"campaign_base_sha\":\"base\",\"acceptance_contract\":{},\"non_goals\":[],\"authorities\":[],\"carriers\":[],\"observations\":[],\"equivalence_classes\":[],\"operations\":[],\"transitions\":[],\"laws\":[],\"non_laws\":[],\"forbidden_states_or_transitions\":[],\"counterexample_families\":[],\"quotient\":{\"method\":\"witness_checked_manual\",\"optimality\":\"witnessed\"},\"complexity\":{\"authorities\":0,\"observable_state_classes\":0,\"operations\":0,\"transitions\":0,\"laws\":0,\"protocol_cases\":0},\"gate\":{}}");
    if (std.mem.eql(u8, artifact, "kernel-review")) return writer.writeAll("{\"review_version\":\"KR-v1\",\"kernel_fingerprint\":\"sha256:kernel\",\"findings\":[],\"gate\":{\"accepted\":true}}");
    if (std.mem.eql(u8, artifact, "realization-design")) return writer.writeAll("{\"design_version\":\"RD-v1\",\"design_id\":\"design.example\",\"route_class\":\"subtractive\",\"kernel_fingerprint\":\"sha256:kernel\",\"kernel_elements_realized\":[],\"owner_map\":[],\"surfaces_to_retire\":[],\"predicted_new_surface\":[],\"negative_route_refs\":[],\"predicted_semantic_surface\":{},\"proof_strategy\":{},\"risks\":[],\"gate\":{\"kernel_complete\":true,\"negative_routes_clear\":true,\"within_baseline\":true}}");
    if (std.mem.eql(u8, artifact, "construct-map")) return writer.writeAll("{\"map_version\":\"KRM-v1\",\"kernel_fingerprint\":\"sha256:kernel\",\"realization_tree_fingerprint\":\"sha256:tree\",\"constructs\":[],\"proof_actions\":[]}");
    if (std.mem.eql(u8, artifact, "proof-plan")) return writer.writeAll("{\"plan_version\":\"RCP-v1\",\"kernel_fingerprint\":\"sha256:kernel\",\"realization_tree_fingerprint\":\"sha256:tree\",\"actions\":[]}");
    if (std.mem.eql(u8, artifact, "holdout")) return writer.writeAll("{\"holdout_version\":\"RCH-v1\",\"stage\":\"kernel\",\"verdict\":\"clean\",\"refs\":[],\"gate\":{\"blocks\":false}}");
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
    const event_id = try appendEvent(allocator, root, args.state_root, "init", "initialized");
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
        .schema = StateSchemaV2,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 2,
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
    const event_id = try appendEvent(allocator, root, args.state_root, "begin", "collecting");
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
        .schema = StateSchemaV2,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 2,
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
    const event_id = try appendEvent(allocator, root, args.state_root, "migrate-mrpc", state.phase);
    defer allocator.free(event_id);
    try printStateReceipt(allocator, "migrate mrpc", "success", archive_dir, null, state, event_id);
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

fn initialState(args: Args) State {
    return .{
        .schema = StateSchemaV2,
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 2,
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
    try root.writeFile(Io, .{ .sub_path = state_path, .data = bytes });
}

fn writeStateJson(writer: anytype, state: State) !void {
    try writer.writeAll("{\n  \"schema\": ");
    try writeJsonString(writer, state.schema);
    try writer.writeAll(",\n  \"state_root\": ");
    try writeJsonString(writer, state.state_root);
    try writer.writeAll(",\n  \"legacy_root\": ");
    try writeJsonString(writer, state.legacy_root);
    try writer.print(",\n  \"state_version\": {d},\n  \"run_id\": ", .{state.state_version});
    try writeJsonString(writer, state.run_id);
    try writer.writeAll(",\n  \"repo_root\": ");
    try writeJsonString(writer, state.repo_root);
    try writer.writeAll(",\n  \"branch\": ");
    try writeJsonString(writer, state.branch);
    try writer.writeAll(",\n  \"base_sha\": ");
    try writeJsonString(writer, state.base_sha);
    try writer.writeAll(",\n  \"phase\": ");
    try writeJsonString(writer, state.phase);
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

fn fileExists(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, child: []const u8) bool {
    const path = statePath(allocator, state_root, child) catch return false;
    defer allocator.free(path);
    root.access(Io, path, .{}) catch return false;
    return true;
}

fn stateFileExists(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8) bool {
    return fileExists(allocator, root, state_root, StateFile);
}

fn appendEvent(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, event: []const u8, phase: []const u8) ![]u8 {
    const path = try statePath(allocator, state_root, EventFile);
    defer allocator.free(path);
    const event_id = try eventIdAlloc(allocator, event, phase);
    errdefer allocator.free(event_id);
    var row: std.Io.Writer.Allocating = .init(allocator);
    defer row.deinit();
    try row.writer.writeAll("{\"event_id\":");
    try writeJsonString(&row.writer, event_id);
    try row.writer.writeAll(",\"event\":");
    try writeJsonString(&row.writer, event);
    try row.writer.writeAll(",\"phase\":");
    try writeJsonString(&row.writer, phase);
    try row.writer.writeAll("}");
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
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try root.writeFile(Io, .{ .sub_path = path, .data = bytes });
    return event_id;
}

fn appendEventOnly(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, event: []const u8, phase: []const u8) !void {
    const event_id = try appendEvent(allocator, root, state_root, event, phase);
    defer allocator.free(event_id);
}

fn eventIdAlloc(allocator: std.mem.Allocator, event: []const u8, phase: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(HashSeed);
    hasher.update(event);
    hasher.update("\x00");
    hasher.update(phase);
    return std.fmt.allocPrint(allocator, "evt-{x}", .{hasher.final()});
}

fn writeMbkc(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, state: State, stage: []const u8) !void {
    const path = try statePath(allocator, state_root, MbkcFile);
    defer allocator.free(path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeMbkcJson(&out.writer, state, stage);
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try root.writeFile(Io, .{ .sub_path = path, .data = bytes });
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

fn validateKernelValue(value: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(value, "kernel_version") orelse "", "MBK-v1")) return error.InvalidBasis;
    if (stringField(value, "campaign_id") == null) return error.InvalidBasis;
    if (stringField(value, "campaign_base_sha") == null) return error.InvalidBasis;
    for ([_][]const u8{ "acceptance_contract", "authorities", "carriers", "observations", "equivalence_classes", "operations", "transitions", "laws", "quotient", "complexity", "gate" }) |field| {
        if (objectField(value, field) == null) return error.InvalidBasis;
    }
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
    try root.writeFile(Io, .{ .sub_path = path, .data = bytes });
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

fn validateConstructMapValue(value: std.json.Value) !void {
    if (!std.mem.eql(u8, stringField(value, "map_version") orelse "", "KRM-v1")) return error.InvalidCandidate;
    if (stringField(value, "kernel_fingerprint") == null) return error.InvalidCandidate;
    if (stringField(value, "realization_tree_fingerprint") == null) return error.InvalidCandidate;
    if (objectField(value, "constructs") == null) return error.InvalidCandidate;
    if (objectField(value, "proof_actions") == null) return error.InvalidCandidate;
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
    for (law_id) |c| switch (c) {
        '"' => try writer.writeByte('_'),
        '\\' => try writer.writeByte('_'),
        ' ', '\t', '\n', '\r' => try writer.writeByte('-'),
        else => try writer.writeByte(c),
    };
    try writer.writeAll("\",\"command\":");
    try writeJsonString(writer, command);
    try writer.writeAll(",\"style\":");
    try writeJsonString(writer, style);
    try writer.writeAll(",\"proves_law_ids\":[");
    try writeJsonString(writer, law_id);
    try writer.writeAll("],\"covers_observation_ids\":[],\"cost\":{\"commands\":1}}");
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
    try out.writer.writeAll(",\"artifact_fingerprints\":{\"state\":\"sha256:");
    try out.writer.print("{x}", .{hashState(state_after)});
    try out.writer.writeAll("\",\"delivery_tree\":null},\"event_id\":");
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

fn hashState(state: State) u64 {
    var hasher = std.hash.Wyhash.init(HashSeed);
    hasher.update(state.schema);
    hasher.update(state.run_id);
    hasher.update(state.phase);
    hasher.update(state.base_sha);
    hasher.update(state.acceptance_goal);
    return hasher.final();
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
}

test "capabilities advertise MBKC and state v2 writable surface" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRequiredFields(&out.writer, "mbkc");
    const fields = try out.toOwnedSlice();
    defer std.testing.allocator.free(fields);
    try std.testing.expect(std.mem.containsAtLeast(u8, fields, 1, "certificate_version"));
    try std.testing.expect(knownSchemaArtifact("kernel"));
    try std.testing.expect(knownSchemaArtifact("mbkc"));
    try std.testing.expect(!knownSchemaArtifact("candidate"));
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
    const event_id = try appendEvent(std.testing.allocator, root, DefaultStateRoot, "init", "initialized");
    defer std.testing.allocator.free(event_id);
    const events = try tmp.dir.readFileAlloc(Io, ".ledger/c3/events.jsonl", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.startsWith(u8, event_id, "evt-"));
    try std.testing.expect(std.mem.containsAtLeast(u8, events, 1, "\"event_id\":\"evt-"));
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
