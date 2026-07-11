const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;
const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "ledger --source actuation";
const DefaultStorePath = ".ledger/actuation/events.jsonl";
const MaxStoreBytes = 64 * 1024 * 1024;
const MaxInputBytes = 4 * 1024 * 1024;
const MaxProcessOutputBytes = 4 * 1024 * 1024;
const GenesisDigest = "actuation-genesis/v1";
threadlocal var runtime_io: ?std.Io = null;

fn defaultIo() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io orelse Io.io();
}

const UsageText =
    \\ledger --source actuation
    \\
    \\usage: ledger --source actuation [-h] [--repo PATH] [--path PATH] {open,prepare,record,execute,observe,state,close,decide,doctor,path} ...
    \\
    \\Advance one causal actuation-kernel transition per invocation. /goal owns iteration.
    \\
    \\commands:
    \\  open       Bind authority, allowed paths, and verifier-backed obligations
    \\  prepare    Admit one operation and issue a random single-use capability
    \\  record     Consume an edit capability after independently reconciling the file delta
    \\  execute    Consume an inspect/verify capability by running its admitted verifier
    \\  observe    Run the admitted verifier after a recorded edit
    \\  state      Fold the event chain and project the next legal transition
    \\  close      Close only after every obligation has a passing observation
    \\  decide     Project a Zig-native closure decision from the live kernel state
    \\  doctor     Validate sequence, hash chain, schemas, and state transitions
    \\  path       Print the resolved actuation event path
    \\
    \\options:
    \\  --repo PATH       Git repository to observe (default: current repository)
    \\  --path PATH       Event store path (default: .ledger/actuation/events.jsonl)
    \\  --json FILE|-     JSON input for open or prepare
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

    fn name(self: Phase) []const u8 {
        return @tagName(self);
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

const RunOpenedBody = struct {
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
    }
};

const RunState = struct {
    run_id: []u8,
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
    phase: Phase = .ready,
    pending: ?Pending = null,

    fn deinit(self: *RunState, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
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
        if (self.pending) |*pending| pending.deinit(allocator);
    }
};

const LedgerLoad = struct {
    event_count: u64 = 0,
    last_digest: []u8,
    state: ?RunState = null,

    fn deinit(self: *LedgerLoad, allocator: std.mem.Allocator) void {
        allocator.free(self.last_digest);
        if (self.state) |*state| state.deinit(allocator);
    }
};

const TransitionResult = struct {
    run_id: []u8,
    event_digest: []u8,
    artifact_digest: []u8,
    capability: ?[]u8 = null,
    passed: ?bool = null,
    exit_code: ?u8 = null,

    fn deinit(self: *TransitionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.event_digest);
        allocator.free(self.artifact_digest);
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
    if ((command == .open or command == .prepare) and args.json_path == null) return error.MissingJsonInput;
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
    const completion = try validateOpenInput(input);
    if (!builtin.is_test) try ensureStoreLockIgnored(allocator, repo, store_path);

    var lock = try durable_store.acquireLock(allocator, store_path);
    defer lock.release(allocator);
    var loaded = try loadLedger(allocator, store_path, input.run_id);
    defer loaded.deinit(allocator);
    if (loaded.state != null) return error.DuplicateRunId;

    const artifact = try repositoryArtifactDigestAlloc(allocator, repo, store_path, input.allowed_paths);
    defer allocator.free(artifact);
    const body = RunOpenedBody{
        .goal_id = input.goal_id,
        .goal_contract_digest = input.goal_contract_digest,
        .resolution_digest = input.resolution_digest,
        .source_ref = input.source_ref,
        .execution_authority_ref = input.execution_authority_ref,
        .mutation_allowed = input.mutation_allowed,
        .completion = completion.name(),
        .repo = repo,
        .store_path = store_path,
        .allowed_paths = input.allowed_paths,
        .obligations = input.obligations,
        .artifact_digest = artifact,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(allocator, store_path, loaded, input.run_id, "run_opened", body_json);
    errdefer allocator.free(event_digest);
    return .{
        .run_id = try allocator.dupe(u8, input.run_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, artifact),
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

    var lock = try durable_store.acquireLock(allocator, store_path);
    defer lock.release(allocator);
    var loaded = try loadLedger(allocator, store_path, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(state, repo, store_path);
    if (state.phase != .ready) return error.InvalidPhase;
    if (containsString(state.step_ids.items, operation.step_id)) return error.DuplicateStepId;
    if (containsString(state.idempotency_keys.items, operation.idempotency_key)) return error.DuplicateIdempotencyKey;
    if (effect == .edit and !state.mutation_allowed) return error.MutationForbidden;
    try validateOperationPaths(state.allowed_paths, operation.paths);

    const verifier = try commonVerifierForRefs(state, operation.obligation_refs);
    const current_artifact = try repositoryArtifactDigestAlloc(allocator, repo, store_path, stringSlice(state.allowed_paths));
    defer allocator.free(current_artifact);
    if (!std.mem.eql(u8, current_artifact, state.artifact_digest)) return error.ArtifactStale;

    const raw_capability = try randomCapabilityAlloc(allocator);
    errdefer allocator.free(raw_capability);
    const capability_digest = try digestTextAlloc(allocator, raw_capability);
    defer allocator.free(capability_digest);
    const unscoped_before = try unscopedDigestAlloc(allocator, repo, store_path, operation.paths, stringSlice(state.allowed_paths));
    defer allocator.free(unscoped_before);
    const path_states = try snapshotPathStatesAlloc(allocator, repo, operation.paths);
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
    const event_digest = try appendEventAlloc(allocator, store_path, loaded, run_id, "operation_prepared", body_json);
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, current_artifact),
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
    var lock = try durable_store.acquireLock(allocator, store_path);
    defer lock.release(allocator);
    var loaded = try loadLedger(allocator, store_path, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(state, repo, store_path);
    if (state.phase != .prepared) return error.InvalidPhase;
    const pending = if (state.pending) |*value| value else return error.PendingOperationMissing;
    if (pending.effect != .edit) return error.RecordRequiresEdit;
    try validateCapability(allocator, pending.capability_digest, raw_capability);

    const artifact_after = try repositoryArtifactDigestAlloc(allocator, repo, store_path, stringSlice(state.allowed_paths));
    defer allocator.free(artifact_after);
    if (std.mem.eql(u8, artifact_after, pending.artifact_before)) return error.EditDidNotChangeArtifact;

    const unscoped_after = try unscopedDigestAlloc(allocator, repo, store_path, stringSlice(pending.paths), stringSlice(state.allowed_paths));
    defer allocator.free(unscoped_after);
    if (!std.mem.eql(u8, unscoped_after, pending.unscoped_before)) return error.OutOfScopeMutation;

    const path_states_after = try snapshotPathStatesAlloc(allocator, repo, stringSlice(pending.paths));
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
    const event_digest = try appendEventAlloc(allocator, store_path, loaded, run_id, "effect_recorded", body_json);
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, artifact_after),
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
    var lock = try durable_store.acquireLock(allocator, store_path);
    defer lock.release(allocator);
    var loaded = try loadLedger(allocator, store_path, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(state, repo, store_path);
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
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(allocator, store_path, loaded, run_id, "operation_observed", body_json);
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, artifact_after),
        .passed = passed,
        .exit_code = process.exit_code,
    };
}

fn cmdClose(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
) !TransitionResult {
    var lock = try durable_store.acquireLock(allocator, store_path);
    defer lock.release(allocator);
    var loaded = try loadLedger(allocator, store_path, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(state, repo, store_path);
    if (state.phase != .ready or state.pending != null) return error.InvalidPhase;
    if (outstandingObligationCount(state) != 0) return error.ObligationsOutstanding;
    const current_artifact = try repositoryArtifactDigestAlloc(allocator, repo, store_path, stringSlice(state.allowed_paths));
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
    const event_digest = try appendEventAlloc(allocator, store_path, loaded, run_id, "run_closed", body_json);
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, current_artifact),
    };
}

fn cmdState(allocator: std.mem.Allocator, repo: []const u8, store_path: []const u8, run_id: []const u8) !void {
    var loaded = try loadLedger(allocator, store_path, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(state, repo, store_path);
    try printState(allocator, state, loaded.event_count);
}

fn cmdDecide(allocator: std.mem.Allocator, repo: []const u8, store_path: []const u8, run_id: []const u8) !void {
    var loaded = try loadLedger(allocator, store_path, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(state, repo, store_path);

    const current_artifact = try repositoryArtifactDigestAlloc(allocator, repo, store_path, stringSlice(state.allowed_paths));
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
    const terminal = state.phase == .closed;
    return .{
        .terminal = terminal,
        .verdict = if (terminal) state.completion.name() else "continue",
        .goal_outcome = if (!terminal or state.completion == .ready_to_ship) "continue" else "complete",
        .implementation_outcome = if (terminal) "complete" else "incomplete",
        .next_owner = if (!terminal)
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
    hashTagged(&hasher, "schema", "actuation-kernel-state/v1");
    hashTagged(&hasher, "run", state.run_id);
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
    store_path: []const u8,
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
    try durable_store.appendLineAtomic(allocator, store_path, line, MaxStoreBytes);
    return event_digest;
}

fn loadLedger(allocator: std.mem.Allocator, store_path: []const u8, target_run_id: ?[]const u8) !LedgerLoad {
    const bytes = durable_store.readRegularFileNoSymlink(allocator, store_path, MaxStoreBytes) catch |err| switch (err) {
        error.FileNotFound => return .{ .last_digest = try allocator.dupe(u8, GenesisDigest) },
        else => return err,
    };
    defer allocator.free(bytes);

    var states: std.ArrayList(RunState) = .empty;
    defer {
        for (states.items) |*state| state.deinit(allocator);
        states.deinit(allocator);
    }
    var last_digest = try allocator.dupe(u8, GenesisDigest);
    errdefer allocator.free(last_digest);
    var expected_sequence: u64 = 1;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(EventWire, allocator, line, .{});
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

    var result = LedgerLoad{
        .event_count = expected_sequence - 1,
        .last_digest = last_digest,
    };
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
        try states.append(allocator, try stateFromOpenEvent(allocator, run_id, body_json));
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
    if (std.mem.eql(u8, kind, "run_closed")) {
        try applyClosedEvent(allocator, state, body_json);
        return;
    }
    return error.UnknownEventKind;
}

fn stateFromOpenEvent(allocator: std.mem.Allocator, run_id: []const u8, body_json: []const u8) !RunState {
    var parsed = try std.json.parseFromSlice(RunOpenedBody, allocator, body_json, .{});
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

fn applyPreparedEvent(allocator: std.mem.Allocator, state: *RunState, body_json: []const u8) !void {
    if (state.phase != .ready or state.pending != null) return error.InvalidEventTransition;
    var parsed = try std.json.parseFromSlice(OperationPreparedBody, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-operation-prepared/v1")) return error.InvalidBodySchema;
    try validateToken("step_id", body.step_id);
    if (containsString(state.step_ids.items, body.step_id)) return error.DuplicateStepId;
    try validateToken("idempotency_key", body.idempotency_key);
    if (containsString(state.idempotency_keys.items, body.idempotency_key)) return error.DuplicateIdempotencyKey;
    const effect = Effect.parse(body.effect) orelse return error.InvalidEffect;
    if (effect == .edit and !state.mutation_allowed) return error.MutationForbidden;
    try validateNonEmpty("owner_boundary", body.owner_boundary);
    try validateOperationPaths(state.allowed_paths, body.paths);
    const expected_verifier = try commonVerifierForRefs(state, body.obligation_refs);
    if (!equalStringLists(stringSlice(expected_verifier), body.verifier)) return error.VerifierSubstitution;
    try validateDigest(body.capability_digest);
    if (!std.mem.eql(u8, state.artifact_digest, body.artifact_before)) return error.EventArtifactMismatch;
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
    pending.artifact_after = try allocator.dupe(u8, body.artifact_after);
    allocator.free(state.artifact_digest);
    state.artifact_digest = try allocator.dupe(u8, body.artifact_after);
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
    allocator.free(state.artifact_digest);
    state.artifact_digest = try allocator.dupe(u8, body.artifact_after);
    pending.deinit(allocator);
    state.pending = null;
    state.phase = .ready;
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
        if (!std.mem.eql(u8, obligation.id, body.discharged_obligations[index])) return error.ClosureMismatch;
    }
    state.phase = .closed;
}

fn findRunState(states: []const RunState, run_id: []const u8) ?usize {
    for (states, 0..) |state, index| {
        if (std.mem.eql(u8, state.run_id, run_id)) return index;
    }
    return null;
}

fn validateOpenInput(input: OpenInput) !Completion {
    if (!std.mem.eql(u8, input.schema, "actuation-open/v1")) return error.InvalidInputSchema;
    try validateToken("run_id", input.run_id);
    try validateToken("goal_id", input.goal_id);
    try validateDigest(input.goal_contract_digest);
    if (input.resolution_digest) |digest| try validateDigest(digest);
    try validateNonEmpty("source_ref", input.source_ref);
    try validateNonEmpty("execution_authority_ref", input.execution_authority_ref);
    const completion = Completion.parse(input.completion) orelse return error.InvalidCompletion;
    try validateAllowedPaths(input.allowed_paths);
    try validateObligations(input.obligations);
    return completion;
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
        for (paths[0..index]) |prior| {
            if (std.mem.eql(u8, path, prior)) return error.DuplicatePath;
            if (pathWithin(path, prior) or pathWithin(prior, path)) return error.OverlappingPath;
        }
    }
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
    if (path[0] == ':' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidRepoPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidRepoPath;
        }
    }
    if (pathWithin(path, ".git") or pathWithin(path, ".ledger/actuation")) return error.ReservedRepoPath;
}

fn validateToken(_: []const u8, value: []const u8) !void {
    if (value.len == 0 or value.len > 160) return error.InvalidToken;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':' and byte != '/') {
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

fn validateContext(state: *const RunState, repo: []const u8, store_path: []const u8) !void {
    if (!std.mem.eql(u8, state.repo, repo) or !std.mem.eql(u8, state.store_path, store_path)) {
        return error.RunContextMismatch;
    }
}

fn commonVerifierForRefs(state: *RunState, refs: []const []const u8) ![][]u8 {
    if (refs.len == 0) return error.ObligationRefsMissing;
    var verifier: ?[][]u8 = null;
    for (refs, 0..) |ref, index| {
        try validateToken("obligation_ref", ref);
        for (refs[0..index]) |prior| if (std.mem.eql(u8, prior, ref)) return error.DuplicateObligationRef;
        const obligation = findObligation(state, ref) orelse return error.UnknownObligation;
        if (obligation.discharged_by != null) return error.ObligationAlreadyDischarged;
        if (verifier) |expected| {
            if (!equalStringLists(stringSlice(expected), stringSlice(obligation.verifier))) return error.MixedVerifiers;
        } else {
            verifier = obligation.verifier;
        }
    }
    return verifier.?;
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

fn validateCapability(allocator: std.mem.Allocator, expected_digest: []const u8, raw_capability: []const u8) !void {
    const actual = try digestTextAlloc(allocator, raw_capability);
    defer allocator.free(actual);
    if (!std.crypto.timing_safe.eql([71]u8, actual[0..71].*, expected_digest[0..71].*)) return error.CapabilityMismatch;
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
    const store_relative = try storeRelativeAlloc(allocator, repo, store_path);
    defer if (store_relative) |value| allocator.free(value);
    const excludes = if (store_relative) |value| &[_][]const u8{value} else &[_][]const u8{};
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
    for (allowed_paths) |path| {
        const path_digest = try pathStateDigestAlloc(allocator, repo, path);
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
    const store_relative = try storeRelativeAlloc(allocator, repo, store_path);
    defer if (store_relative) |value| allocator.free(value);
    if (store_relative) |value| try excludes.append(allocator, value);
    const workspace = try workspaceDigestAlloc(allocator, repo, excludes.items);
    defer allocator.free(workspace);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "workspace", workspace);
    for (allowed_paths) |path| {
        if (pathOverlapsAny(path, operation_paths)) continue;
        const path_digest = try pathStateDigestAlloc(allocator, repo, path);
        defer allocator.free(path_digest);
        hashTagged(&hasher, path, path_digest);
    }
    return finishDigestAlloc(allocator, &hasher);
}

fn workspaceDigestAlloc(allocator: std.mem.Allocator, repo: []const u8, excludes: []const []const u8) ![]u8 {
    var diff_args: std.ArrayList([]const u8) = .empty;
    defer diff_args.deinit(allocator);
    var owned_pathspecs: std.ArrayList([]u8) = .empty;
    defer freeOwnedArrayList(allocator, &owned_pathspecs);
    try diff_args.appendSlice(allocator, &.{ "diff", "--binary", "--full-index", "HEAD", "--", "." });
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
    const untracked = try runGitRawAlloc(allocator, repo, &.{ "ls-files", "--others", "--exclude-standard", "-z" });
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

fn pathStateDigestAlloc(allocator: std.mem.Allocator, repo: []const u8, path: []const u8) ![]u8 {
    const tree = try runGitRawAlloc(allocator, repo, &.{ "ls-tree", "-r", "-z", "HEAD", "--", path });
    defer allocator.free(tree);
    const index = try runGitRawAlloc(allocator, repo, &.{ "ls-files", "--stage", "-z", "--", path });
    defer allocator.free(index);
    const diff = try runGitRawAlloc(allocator, repo, &.{ "diff", "--binary", "--full-index", "HEAD", "--", path });
    defer allocator.free(diff);
    const untracked = try runGitRawAlloc(allocator, repo, &.{ "ls-files", "--others", "--exclude-standard", "-z", "--", path });
    defer allocator.free(untracked);
    const exact = exactPathDigestAlloc(allocator, repo, path) catch try allocator.dupe(u8, "not-a-regular-file");
    defer allocator.free(exact);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "tree", tree);
    hashTagged(&hasher, "index", index);
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

fn exactPathDigestAlloc(allocator: std.mem.Allocator, repo: []const u8, path: []const u8) ![]u8 {
    const raw = try runGitRawAlloc(allocator, repo, &.{ "hash-object", "--no-filters", "--", path });
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.PathUnreadable;
    return digestTextAlloc(allocator, trimmed);
}

fn snapshotPathStatesAlloc(allocator: std.mem.Allocator, repo: []const u8, paths: []const []const u8) ![]PathState {
    const states = try allocator.alloc(PathState, paths.len);
    var initialized: usize = 0;
    errdefer {
        for (states[0..initialized]) |*state| state.deinit(allocator);
        allocator.free(states);
    }
    for (paths, 0..) |path, index| {
        states[index] = .{
            .path = try allocator.dupe(u8, path),
            .digest = try pathStateDigestAlloc(allocator, repo, path),
        };
        initialized += 1;
    }
    return states;
}

fn pathStateWiresAlloc(allocator: std.mem.Allocator, states: []const PathState) ![]PathStateWire {
    const wires = try allocator.alloc(PathStateWire, states.len);
    for (states, 0..) |state, index| wires[index] = .{ .path = state.path, .digest = state.digest };
    return wires;
}

fn allPathStatesChanged(before: []const PathState, after: []const PathState) bool {
    if (before.len != after.len) return false;
    for (before, after) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path) or std.mem.eql(u8, left.digest, right.digest)) return false;
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

fn storeRelativeAlloc(allocator: std.mem.Allocator, repo: []const u8, store_path: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, store_path, repo)) return null;
    if (store_path.len == repo.len) return null;
    if (store_path[repo.len] != '/') return null;
    return try allocator.dupe(u8, store_path[repo.len + 1 ..]);
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

fn runProcessAlloc(allocator: std.mem.Allocator, repo: []const u8, argv: []const []const u8) !ProcessResult {
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

fn resolveStorePathAlloc(allocator: std.mem.Allocator, repo: []const u8, raw_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) return allocator.dupe(u8, raw_path);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo, raw_path });
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
    try out.writer.writeAll(",\"event_digest\":");
    try std.json.Stringify.value(result.event_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"artifact_digest\":");
    try std.json.Stringify.value(result.artifact_digest, .{}, &out.writer);
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
    try out.writer.writeAll("{\"schema\":\"actuation-kernel-state/v1\",\"run_id\":");
    try std.json.Stringify.value(state.run_id, .{}, &out.writer);
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
        .closed => "terminal",
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
    try durable_store.writeTextAtomic(allocator, gitignore, ".ledger/\n");
    try durable_store.writeTextAtomic(allocator, target, "before\n");
    try durable_store.writeTextAtomic(allocator, other, "stable\n");
    try runTestCommand(allocator, root, &.{ "git", "init", "--quiet" });
    try runTestCommand(allocator, root, &.{ "git", "config", "user.email", "actuation@example.invalid" });
    try runTestCommand(allocator, root, &.{ "git", "config", "user.name", "Actuation Test" });
    try runTestCommand(allocator, root, &.{ "git", "add", ".gitignore", "target.txt", "other.txt" });
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

fn runTestCommand(allocator: std.mem.Allocator, repo: []const u8, argv: []const []const u8) !void {
    var result = try runProcessAlloc(allocator, repo, argv);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

const TestOpenSingle =
    \\{"schema":"actuation-open/v1","run_id":"run-1","goal_id":"goal-1","goal_contract_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","source_ref":"user:turn","execution_authority_ref":"user:turn","mutation_allowed":true,"completion":"complete","allowed_paths":["target.txt"],"obligations":[{"id":"obl-1","kind":"implementation","statement":"The diff remains whitespace-clean.","verifier":["git","diff","--check"]}]}
;

const TestOpenTwoPaths =
    \\{"schema":"actuation-open/v1","run_id":"run-1","goal_id":"goal-1","goal_contract_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","source_ref":"user:turn","execution_authority_ref":"user:turn","mutation_allowed":true,"completion":"complete","allowed_paths":["target.txt","other.txt"],"obligations":[{"id":"obl-1","kind":"implementation","statement":"The diff remains whitespace-clean.","verifier":["git","diff","--check"]}]}
;

const TestOpenTwoObligations =
    \\{"schema":"actuation-open/v1","run_id":"run-1","goal_id":"goal-1","goal_contract_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","resolution_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","source_ref":"user:turn","execution_authority_ref":"user:turn","mutation_allowed":true,"completion":"ready-to-ship","allowed_paths":["target.txt"],"obligations":[{"id":"obl-1","kind":"implementation","statement":"The first verifier passes.","verifier":["git","diff","--check"]},{"id":"obl-2","kind":"ship","statement":"The second verifier passes.","verifier":["git","diff","--check"]}]}
;

const TestOpenDirectory =
    \\{"schema":"actuation-open/v1","run_id":"run-1","goal_id":"goal-1","goal_contract_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","source_ref":"user:turn","execution_authority_ref":"user:turn","mutation_allowed":true,"completion":"complete","allowed_paths":["scope"],"obligations":[{"id":"obl-1","kind":"implementation","statement":"The diff remains whitespace-clean.","verifier":["git","diff","--check"]}]}
;

const TestOpenMutatingVerifier =
    \\{"schema":"actuation-open/v1","run_id":"run-1","goal_id":"goal-1","goal_contract_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","source_ref":"user:turn","execution_authority_ref":"user:turn","mutation_allowed":true,"completion":"complete","allowed_paths":["target.txt"],"obligations":[{"id":"obl-1","kind":"implementation","statement":"The verifier is observational.","verifier":["sh","-c","printf 'mutated\\n' > other.txt; exit 1"]}]}
;

const TestEditOperation =
    \\{"schema":"actuation-operation/v1","step_id":"step-1","effect":"edit","idempotency_key":"run-1:step-1","owner_boundary":"fixture","paths":["target.txt"],"obligation_refs":["obl-1"]}
;

test "edit capability is issued before effect, consumed once, observed, and closed" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);

    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", TestEditOperation);
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expect(prepared.capability != null);

    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "after\n");
    var recorded = try cmdRecord(std.testing.allocator, fixture.root, fixture.store, "run-1", prepared.capability.?);
    defer recorded.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidPhase,
        cmdRecord(std.testing.allocator, fixture.root, fixture.store, "run-1", prepared.capability.?),
    );

    var observed = try cmdObserve(std.testing.allocator, fixture.root, fixture.store, "run-1", "step-1");
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

test "idempotency keys cannot authorize a second operation" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenTwoObligations);
    defer opened.deinit(std.testing.allocator);
    const first =
        \\{"schema":"actuation-operation/v1","step_id":"step-1","effect":"verify","idempotency_key":"same-key","owner_boundary":"fixture","paths":["target.txt"],"obligation_refs":["obl-1"]}
    ;
    var prepared = try cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", first);
    defer prepared.deinit(std.testing.allocator);
    var executed = try cmdExecute(std.testing.allocator, fixture.root, fixture.store, "run-1", prepared.capability.?);
    defer executed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, true), executed.passed);

    const second =
        \\{"schema":"actuation-operation/v1","step_id":"step-2","effect":"verify","idempotency_key":"same-key","owner_boundary":"fixture","paths":["target.txt"],"obligation_refs":["obl-2"]}
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
        \\{"schema":"actuation-operation/v1","step_id":"step-1","effect":"verify","idempotency_key":"verify-all","owner_boundary":"fixture","paths":["target.txt"],"obligation_refs":["obl-1","obl-2"]}
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
    try std.testing.expectEqualStrings(
        "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        loaded.state.?.resolution_digest.?,
    );
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
        \\{"schema":"actuation-operation/v1","step_id":"step-1","effect":"edit","idempotency_key":"nested-edit","owner_boundary":"fixture","paths":["scope/child.txt"],"obligation_refs":["obl-1"]}
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
        \\{"schema":"actuation-operation/v1","step_id":"step-1","effect":"verify","idempotency_key":"mutating-verifier","owner_boundary":"fixture","paths":["target.txt"],"obligation_refs":["obl-1"]}
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
        \\{"schema":"actuation-open/v1","run_id":"run-1","goal_id":"goal-1","goal_contract_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","source_ref":"user:turn","execution_authority_ref":"user:turn","mutation_allowed":true,"completion":"complete","allowed_paths":["target.txt"],"obligations":[{"id":"obl-1","kind":"summary","statement":"Invalid proof kind.","verifier":["git","diff","--check"]}]}
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
