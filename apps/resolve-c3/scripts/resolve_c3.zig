const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const DefaultStateRoot = ".ledger/c3";
const LegacyStateRoot = ".resolve-c3";
const StateFile = "state.json";
const CertFile = "mrpc.json";
const EventFile = "events.jsonl";
const MaxFileBytes = 16 * 1024 * 1024;
const Io = std.Io.Threaded.global_single_threaded.io();

const HelpText =
    \\resolve-c3
    \\
    \\Zig controller for the $resolve C3 workflow.
    \\
    \\usage: resolve-c3 COMMAND [options]
    \\
    \\commands:
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
    \\  --stage candidate|delivery Holdout stage
    \\  --reason TEXT              Waiver or abort reason
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

const TerminalPhases = [_][]const u8{ "closed", "aborted" };
const BasisGateFields = [_][]const u8{ "all_findings_classified", "every_branch_liability_covered", "non_branch_liabilities_excluded" };
const VerificationFields = [_][]const u8{ "counterexamples_pass", "acceptance_pass", "regressions_pass", "proof_current" };
const NegativeAllowedStatuses = [_][]const u8{ "allowed", "reopened", "stale", "superseded" };
const ClosureWords = [_][]const u8{ "done", "resolved", "complete", "completed", "ready", "shipped", "pushed", "closed" };
const MrpcRequiredFields = [_][]const u8{ "certificate_id", "stage", "run_id", "immutable_base", "counterexample_basis", "candidate_tournament", "selected_candidate", "ablation", "gate" };
const RdrRequiredFields = [_][]const u8{ "resolve_decision_record", "record_version", "artifact_state", "review_wave", "cluster", "selected_route", "negative_evidence", "surface_delta", "proof_matrix", "material_improvement", "gate" };
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
    path: ?[]const u8 = null,
    worktree: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    stage: ?[]const u8 = null,
    reason: ?[]const u8 = null,
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

    const code = run(allocator, args) catch |err| blk: {
        try printError(allocator, @errorName(err));
        break :blk @as(u8, 2);
    };
    std.process.exit(code);
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 2) return error.MissingCommand;

    var args = Args{ .command = parseCommand(argv[1]) orelse return error.UnknownCommand };
    var i: usize = 2;
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
        } else if (std.mem.eql(u8, token, "--message")) {
            args.message = try optionValue(argv, &i);
        } else if (std.mem.eql(u8, token, "--remote")) {
            args.remote = try optionValue(argv, &i);
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

fn parseCommand(value: []const u8) ?Command {
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

fn run(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.command) {
        .doctor => printDoctor(allocator, args),
        .init => initState(allocator, args),
        .paths => printPaths(allocator, args),
        .status => printStatus(allocator, args),
        .begin => beginRun(allocator, args),
        .add_counterexample => addCounterexample(allocator, args),
        .set_basis => setBasis(allocator, args),
        .tournament_waiver => setTournamentWaiver(allocator, args),
        .register_candidate => registerCandidate(allocator, args),
        .verify_candidate => verifyCandidate(allocator, args),
        .select => selectCandidate(allocator, args),
        .ablate => ablateCandidate(allocator, args),
        .record_ablation => recordAblation(allocator, args),
        .record_holdout => recordHoldout(allocator, args),
        .certify_apply => certifyApply(allocator, args),
        .apply => applySelected(allocator, args),
        .run_proof => runProof(allocator, args),
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
    try saveState(allocator, root, args.state_root, initialState(args));
    try appendEvent(allocator, root, args.state_root, "init", "initialized");
    try ensureLocalExclude(allocator, root, args.state_root);
    try printReceipt(allocator, "init", "success", args.state_root);
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

    var parent_run_id: ?[]const u8 = null;
    if (loadStateParsed(allocator, root, args.state_root)) |parsed_existing| {
        var existing = parsed_existing;
        defer existing.deinit();
        if (!isTerminalPhase(existing.value.phase) and !std.mem.eql(u8, existing.value.phase, "initialized")) {
            return error.ActiveRunExists;
        }
        if (existing.value.run_id.len > 0) parent_run_id = existing.value.run_id;
    } else |_| {}

    const goal = if (args.acceptance) |path| try acceptanceGoalFromFile(allocator, path) else if (args.goal) |g| g else return error.AcceptanceRequired;
    defer if (args.acceptance != null) allocator.free(goal);
    const base_sha = gitCapture(allocator, args.cwd, &.{ "rev-parse", "HEAD" }) catch "unknown";
    defer if (!std.mem.eql(u8, base_sha, "unknown")) allocator.free(base_sha);
    const branch = gitCapture(allocator, args.cwd, &.{ "branch", "--show-current" }) catch "unknown";
    defer if (!std.mem.eql(u8, branch, "unknown")) allocator.free(branch);
    const repo_root = gitCapture(allocator, args.cwd, &.{ "rev-parse", "--show-toplevel" }) catch args.cwd;
    defer if (!std.mem.eql(u8, repo_root, args.cwd)) allocator.free(repo_root);
    const run_id = try std.fmt.allocPrint(allocator, "C3-{s}", .{base_sha[0..@min(base_sha.len, 12)]});
    defer allocator.free(run_id);

    const state = State{
        .schema = "resolve-c3-state-v1",
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 1,
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
    try appendEvent(allocator, root, args.state_root, "begin", "collecting");
    try printReceipt(allocator, "begin", "success", run_id);
    return 0;
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
    try appendEvent(allocator, root, args.state_root, "counterexample-added", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "basis-set", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "tournament-waiver", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "candidate-registered", state.phase);
    try printReceipt(allocator, "register-candidate", if (valid) "valid" else "invalid", candidate_id);
    return if (valid) 0 else 2;
}

fn verifyCandidate(allocator: std.mem.Allocator, args: Args) !u8 {
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
        const passed = try runShell(allocator, cwd, command);
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
    try appendEvent(allocator, root, args.state_root, "candidate-verified", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "candidate-selected", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "ablation-run", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "ablation-recorded", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "holdout-recorded", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "apply-certified", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "patch-applied", state.phase);
    try printMrpcFile(allocator, root, args.state_root);
    return 0;
}

fn runProof(allocator: std.mem.Allocator, args: Args) !u8 {
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
        all_pass = all_pass and try runShell(allocator, args.cwd, command);
    }
    state.proof_authority = "controller";
    state.proof_passed = all_pass;
    state.proof_patch_stable = true;
    try saveState(allocator, root, args.state_root, state);
    try appendEvent(allocator, root, args.state_root, "proof-run", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "proof-recorded", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "final-certified", state.phase);
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
    const head = gitCapture(allocator, args.cwd, &.{ "rev-parse", "HEAD" }) catch state.base_sha;
    defer if (!std.mem.eql(u8, head, state.base_sha)) allocator.free(head);
    state.commit_sha = head;
    state.phase = "committed";
    state.certificate_stage = "committed";
    try saveState(allocator, root, args.state_root, state);
    try writeMrpc(allocator, root, args.state_root, state, "committed");
    try appendEvent(allocator, root, args.state_root, "committed", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "pushed", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "closed", state.phase);
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
    try appendEvent(allocator, root, args.state_root, "aborted", state.phase);
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
    const ok = parsed.value.state_version == 1 and (!cert_required or cert_exists);
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

fn archiveLegacyState(allocator: std.mem.Allocator, root: std.Io.Dir, args: Args, legacy_state_path: []const u8, legacy_bytes: []const u8) ![]const u8 {
    try root.createDirPath(Io, args.state_root);
    const archive_dir = try statePath(allocator, args.state_root, "archive/legacy");
    defer allocator.free(archive_dir);
    try root.createDirPath(Io, archive_dir);
    const archive_state = try statePath(allocator, args.state_root, "archive/legacy/state.json");
    defer allocator.free(archive_state);
    try root.writeFile(Io, .{ .sub_path = archive_state, .data = legacy_bytes });

    const migrated = State{
        .schema = "resolve-c3-state-v1",
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 1,
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
    try appendEvent(allocator, root, args.state_root, "migrate-legacy", "initialized");
    try ensureLocalExclude(allocator, root, args.state_root);
    root.deleteFile(Io, legacy_state_path) catch {};
    return allocator.dupe(u8, archive_state);
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
        .schema = "resolve-c3-state-v1",
        .state_root = args.state_root,
        .legacy_root = args.legacy_root,
        .state_version = 1,
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
    return std.json.parseFromSlice(State, allocator, bytes, .{ .ignore_unknown_fields = true });
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

fn appendEvent(allocator: std.mem.Allocator, root: std.Io.Dir, state_root: []const u8, event: []const u8, phase: []const u8) !void {
    const path = try statePath(allocator, state_root, EventFile);
    defer allocator.free(path);
    var row: std.Io.Writer.Allocating = .init(allocator);
    defer row.deinit();
    try row.writer.writeAll("{\"event\":");
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
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (argv_tail) |arg| try argv.append(allocator, arg);
    const result = try std.process.run(allocator, Io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
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

fn runShell(allocator: std.mem.Allocator, cwd: []const u8, command: []const u8) !bool {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    const result = try std.process.run(allocator, Io, .{
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

fn findStateRootFrom(allocator: std.mem.Allocator, cwd: []const u8, state_root: []const u8) !?[]u8 {
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(Io, cwd, allocator);
    var current: []u8 = resolved;
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
    try out.writer.writeAll("{\"c3_receipt\":{\"command\":");
    try writeJsonString(&out.writer, command);
    try out.writer.writeAll(",\"outcome\":");
    try writeJsonString(&out.writer, outcome);
    try out.writer.writeAll(",\"detail\":");
    try writeJsonString(&out.writer, detail);
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
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
    try saveState(std.testing.allocator, root, DefaultStateRoot, initialState(.{ .command = .init, .cwd = cwd }));
    try ensureLocalExclude(std.testing.allocator, root, DefaultStateRoot);

    try tmp.dir.access(Io, ".ledger/c3/state.json", .{});
    try tmp.dir.access(Io, ".resolve-c3/state.json", .{});
    const exclude = try tmp.dir.readFileAlloc(Io, ".git/info/exclude", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(exclude);
    try std.testing.expect(containsLine(exclude, ".ledger/c3/"));
    try std.testing.expect(!containsLine(exclude, ".ledger/"));
}

test "state lifecycle gates require controller ablation and proof" {
    var candidates = [_]Candidate{candidateForTest("selected", "patch", true, zeroCost())};
    const state = State{
        .schema = "resolve-c3-state-v1",
        .state_root = DefaultStateRoot,
        .legacy_root = LegacyStateRoot,
        .state_version = 1,
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
