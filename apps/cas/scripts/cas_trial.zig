const std = @import("std");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const retrace_core = @import("retrace_core");
const app_meta = @import("app_meta");
const hctp_fixtures = @import("hctp_fixtures");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// Darwin's public proc_bsdshortinfo ABI from sys/proc_info.h. CAS is a
// macOS-only product surface, and the existing libc link exports libproc.
const DarwinProcessShortInfo = extern struct {
    pid: u32,
    parent_pid: u32,
    process_group_id: u32,
    status: u32,
    command: [16]u8,
    flags: u32,
    uid: u32,
    gid: u32,
    real_uid: u32,
    real_gid: u32,
    saved_uid: u32,
    saved_gid: u32,
    reserved: u32,
};

extern "c" fn proc_listpgrppids(
    process_group_id: std.posix.pid_t,
    buffer: ?*anyopaque,
    buffer_size: c_int,
) c_int;
extern "c" fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: *anyopaque,
    buffer_size: c_int,
) c_int;

const adapter = retrace_core.hctp_adapter;
const attestation = retrace_core.hctp_attestation;
const Version = core_cli.normalizeVersion(app_meta.version);
const MaxInputBytes = 64 * 1024 * 1024;
const MaxTargetCarrierBytes = 96 * 1024 * 1024;
const ExecutorPollIntervalMs: i64 = 10;
const ExecutorPostReapDrainGraceMs: i64 = 250;
const DarwinProcessShortInfoFlavor: c_int = 13;
const DarwinZombieProcessStatus: u32 = 5;
const MaxExecutorGroupCensusPids: usize = 65_536;
const StagedExecutableMode: std.posix.mode_t = 0o500;
const ExecutableStoreMode: std.posix.mode_t = 0o700;
// Darwin sys/stat.h SF_RESTRICTED. Zig 0.16 exposes st_flags but not this SDK
// constant. Restricted Apple platform code cannot execute from a byte-identical
// user-owned staging path, so it is rejected before the lane is claimed.
const MacOSRestrictedFileFlag: u32 = 0x00080000;

comptime {
    if (@sizeOf(DarwinProcessShortInfo) != 64 or
        @offsetOf(DarwinProcessShortInfo, "pid") != 0 or
        @offsetOf(DarwinProcessShortInfo, "process_group_id") != 8 or
        @offsetOf(DarwinProcessShortInfo, "status") != 12)
    {
        @compileError("Darwin proc_bsdshortinfo ABI changed");
    }
}

const UsageText =
    \\cas_trial
    \\
    \\One-claim HCTP-v1 lane runner and receipt normalizer.
    \\
    \\Usage:
    \\  cas_trial preflight --trial FILE --lane-id ID [--json]
    \\  cas_trial compile-replay --trial FILE --lane-id ID --output-dir DIR [--json]
    \\  cas_trial run --trial FILE --lane-id ID --repo DIR --receipt-dir DIR
    \\      --registration-event-digest SHA256 --start-event-digest SHA256
    \\      --lease-fd N --input-fd N --presented-input-fingerprint SHA256
    \\      --executor PATH --ledger PATH [--source-profile-fd N]
    \\      [--signing-seed-fd N] [--producer-id ID]
    \\      [--producer-key-id ID] [--json]
    \\  cas_trial status --trial-id ID --lane-id ID --receipt-dir DIR
    \\      [--registration-event-digest SHA256] [--json]
    \\  cas_trial cleanup --trial-id ID --lane-id ID --receipt-dir DIR
    \\      [--registration-event-digest SHA256] [--json]
    \\  cas_trial key-info --signing-seed-fd N [--producer-key-id ID] [--json]
    \\
    \\The executor is invoked exactly once as:
    \\  EXECUTOR --request REQUEST.json --result RESULT.json
    \\It receives no lane lease or hidden reference. CAS claims the lane before
    \\execution, creates a fresh workspace, hashes every evidence file, and emits
    \\one hylo-run-receipt/v1. A persistent claim makes retry a hard error.
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_trial",
    .help_text = UsageText,
};

const Command = enum { preflight, compile_replay, run, status, cleanup, key_info };

const Options = struct {
    command: Command,
    trial_path: ?[]const u8 = null,
    trial_id: ?[]const u8 = null,
    lane_id: ?[]const u8 = null,
    repo: []const u8 = ".",
    receipt_dir: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    registration_event_digest: ?[]const u8 = null,
    start_event_digest: ?[]const u8 = null,
    lease_fd: ?std.posix.fd_t = null,
    input_fd: ?std.posix.fd_t = null,
    source_profile_fd: ?std.posix.fd_t = null,
    presented_input_fingerprint: ?[]const u8 = null,
    executor: ?[]const u8 = null,
    ledger: ?[]const u8 = null,
    signing_seed_fd: ?std.posix.fd_t = null,
    producer_id: []const u8 = "cas-trial",
    producer_key_id: []const u8 = "runner-key",
    json: bool = false,
    // Tests inject an isolated authority root without exposing a production CLI
    // flag that could split the exactly-once claim store.
    claim_store_override: ?[]const u8 = null,
    // Tests exercise terminal normalization at a small bound without changing
    // the frozen production protocol limit or exposing a CLI override.
    executor_output_limit_override: ?usize = null,
};

const LaneView = struct {
    trial: std.json.ObjectMap,
    trial_id: []const u8,
    purpose: []const u8,
    unit_id: []const u8,
    scenario_id: []const u8,
    pair_id: []const u8,
    pair: std.json.ObjectMap,
    lane_id: []const u8,
    arm_id: []const u8,
    arm: std.json.ObjectMap,
    source_profile: std.json.Value,
    execution: std.json.ObjectMap,
};

const SourceIdentity = struct {
    episode_fingerprint: []const u8,
    profile_fingerprint: []const u8,
};

fn sourceIdentity(view: LaneView) !?SourceIdentity {
    const sealing_value = view.trial.get("sealing") orelse return null;
    const sealing = try object(sealing_value);
    const receipt_value = sealing.get("source_selection_receipt") orelse return null;
    if (receipt_value == .null) return null;
    var matched: ?SourceIdentity = null;
    for ((try requiredArray(try object(receipt_value), "cases")).items) |case_value| {
        const source_case = try object(case_value);
        if (!std.mem.eql(u8, try requiredString(source_case, "unit_id"), view.unit_id) or
            !std.mem.eql(u8, try requiredString(source_case, "scenario_id"), view.scenario_id)) continue;
        if (matched != null) return error.SourceSelectionReceiptInvalid;
        matched = .{
            .episode_fingerprint = try requiredString(source_case, "source_episode_fingerprint"),
            .profile_fingerprint = try requiredString(source_case, "source_profile_fingerprint"),
        };
    }
    return matched orelse error.SourceSelectionReceiptInvalid;
}

const FactorMaterialization = struct {
    present: bool,
    ref: []const u8,
    fingerprint: []const u8,
    canonical_bytes: ?[]u8,
    workspace_ref: []const u8,
    archive_ref: []const u8,

    fn deinit(self: FactorMaterialization, allocator: std.mem.Allocator) void {
        if (self.canonical_bytes) |bytes| allocator.free(bytes);
    }
};

const TargetMaterialization = struct {
    present: bool,
    arm_value_fingerprint: ?[]const u8,
    snapshot_ref: ?[]const u8,
    snapshot_fingerprint: ?[]const u8,
    carrier_bytes: ?[]u8,
    carrier_fingerprint: ?[]u8,
    common_projection_bytes: ?[]u8 = null,
    common_projection_fingerprint: ?[]u8 = null,
    effect_policy_bytes: ?[]u8 = null,
    effect_policy_fingerprint: ?[]u8 = null,
    workspace_ref: []const u8,
    archive_ref: []const u8,
    package_root: []const u8,

    fn deinit(self: TargetMaterialization, allocator: std.mem.Allocator) void {
        if (self.arm_value_fingerprint) |fingerprint| allocator.free(fingerprint);
        if (self.snapshot_ref) |ref| allocator.free(ref);
        if (self.snapshot_fingerprint) |fingerprint| allocator.free(fingerprint);
        if (self.carrier_bytes) |bytes| allocator.free(bytes);
        if (self.carrier_fingerprint) |fingerprint| allocator.free(fingerprint);
        if (self.common_projection_bytes) |bytes| allocator.free(bytes);
        if (self.common_projection_fingerprint) |fingerprint| allocator.free(fingerprint);
        if (self.effect_policy_bytes) |bytes| allocator.free(bytes);
        if (self.effect_policy_fingerprint) |fingerprint| allocator.free(fingerprint);
    }
};

const TargetCommonProjection = struct {
    bytes: []u8,
    fingerprint: []u8,

    fn deinit(self: TargetCommonProjection, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.fingerprint);
    }
};

const EffectPolicyMaterialization = struct {
    bytes: ?[]u8 = null,
    fingerprint: ?[]u8 = null,

    fn deinit(self: EffectPolicyMaterialization, allocator: std.mem.Allocator) void {
        if (self.bytes) |bytes| allocator.free(bytes);
        if (self.fingerprint) |fingerprint| allocator.free(fingerprint);
    }
};

const RunnerObservationReceipts = struct {
    reset_fingerprint: []u8,
    filesystem_fingerprint: []u8,
    network_fingerprint: []u8,
    external_effect_fingerprint: []u8,
    limitations: []u8,

    fn deinit(self: RunnerObservationReceipts, allocator: std.mem.Allocator) void {
        allocator.free(self.reset_fingerprint);
        allocator.free(self.filesystem_fingerprint);
        allocator.free(self.network_fingerprint);
        allocator.free(self.external_effect_fingerprint);
        allocator.free(self.limitations);
    }
};

const ExecutableBinding = struct {
    origin_path: []u8,
    spawn_path: []u8,
    file: std.Io.File,
    inode: std.Io.File.INode,
    size: u64,
    mode: std.posix.mode_t,
    ctime_nanoseconds: i96,
    fingerprint: []u8,

    fn deinit(self: ExecutableBinding, allocator: std.mem.Allocator) void {
        self.file.close(defaultIo());
        allocator.free(self.origin_path);
        allocator.free(self.spawn_path);
        allocator.free(self.fingerprint);
    }
};

const CapabilitySealIdentity = struct {
    profile_id: []const u8,
    effect_policy_fingerprint: []const u8,
};

const RunnerContractValidation = struct {
    capability_seal: ?CapabilitySealIdentity = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;
    if (comptime builtin.os.tag != .macos) return error.CasTrialRequiresMacOS;
    const options = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    switch (options.command) {
        .preflight => try cmdPreflight(allocator, options),
        .compile_replay => try cmdCompileReplay(allocator, options),
        .run => try cmdRun(allocator, options),
        .status => try cmdStatus(allocator, options),
        .cleanup => try cmdCleanup(allocator, options),
        .key_info => try cmdKeyInfo(allocator, options),
    }
}

fn parseArgs(argv: []const []const u8) !Options {
    if (argv.len < 2) return error.MissingCommand;
    var options = Options{ .command = if (std.mem.eql(u8, argv[1], "preflight"))
        .preflight
    else if (std.mem.eql(u8, argv[1], "compile-replay"))
        .compile_replay
    else if (std.mem.eql(u8, argv[1], "run"))
        .run
    else if (std.mem.eql(u8, argv[1], "status"))
        .status
    else if (std.mem.eql(u8, argv[1], "cleanup"))
        .cleanup
    else if (std.mem.eql(u8, argv[1], "key-info"))
        .key_info
    else
        return error.UnknownCommand };
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (std.mem.eql(u8, token, "--json")) {
            options.json = true;
            continue;
        }
        const value = if (index + 1 < argv.len) argv[index + 1] else return error.MissingValue;
        index += 1;
        if (std.mem.eql(u8, token, "--trial")) options.trial_path = value else if (std.mem.eql(u8, token, "--trial-id")) options.trial_id = value else if (std.mem.eql(u8, token, "--lane-id")) options.lane_id = value else if (std.mem.eql(u8, token, "--repo")) options.repo = value else if (std.mem.eql(u8, token, "--receipt-dir")) options.receipt_dir = value else if (std.mem.eql(u8, token, "--output-dir")) options.output_dir = value else if (std.mem.eql(u8, token, "--registration-event-digest")) options.registration_event_digest = value else if (std.mem.eql(u8, token, "--start-event-digest")) options.start_event_digest = value else if (std.mem.eql(u8, token, "--presented-input-fingerprint")) options.presented_input_fingerprint = value else if (std.mem.eql(u8, token, "--executor")) options.executor = value else if (std.mem.eql(u8, token, "--ledger")) options.ledger = value else if (std.mem.eql(u8, token, "--producer-id")) options.producer_id = value else if (std.mem.eql(u8, token, "--producer-key-id")) options.producer_key_id = value else if (std.mem.eql(u8, token, "--lease-fd")) options.lease_fd = try parseFd(value) else if (std.mem.eql(u8, token, "--input-fd")) options.input_fd = try parseFd(value) else if (std.mem.eql(u8, token, "--source-profile-fd")) options.source_profile_fd = try parseFd(value) else if (std.mem.eql(u8, token, "--signing-seed-fd")) options.signing_seed_fd = try parseFd(value) else return error.UnknownFlag;
    }
    return options;
}

fn parseFd(raw: []const u8) !std.posix.fd_t {
    const value = try std.fmt.parseInt(i32, raw, 10);
    if (value < 3) return error.InvalidFd;
    return value;
}

fn cmdPreflight(allocator: std.mem.Allocator, options: Options) !void {
    var loaded = try loadLane(allocator, options.trial_path orelse return error.MissingTrial, options.lane_id orelse return error.MissingLaneId);
    defer loaded.parsed.deinit();
    var effective_profile = try effectiveSourceProfile(allocator, loaded.view.source_profile, options.source_profile_fd);
    defer effective_profile.deinit();
    var view = loaded.view;
    view.source_profile = effective_profile.value;
    const source_kind = try requiredString(try object(view.source_profile), "kind");
    if (std.mem.eql(u8, source_kind, "historical_decision")) {
        var profile = try adapter.validateHistoricalProfile(
            allocator,
            view.source_profile,
            std.mem.eql(u8, view.purpose, "promotion") or std.mem.eql(u8, view.purpose, "practice_repair"),
        );
        profile.deinit(allocator);
    } else if (!std.mem.eql(u8, source_kind, "direct")) return error.SourceProfileInvalid;
    const reset = try requiredObject(view.execution, "reset_policy");
    inline for (.{ "fresh_thread", "fresh_workspace", "clear_target_local_caches", "sibling_output_isolation" }) |key| {
        if (!try requiredBool(reset, key)) return error.ResetPolicyInvalid;
    }
    try printJson(.{
        .schema = "cas-trial-preflight/v1",
        .status = "ready",
        .trial_id = view.trial_id,
        .lane_id = view.lane_id,
        .source_kind = source_kind,
        .atomic_claim_required = true,
        .fresh_workspace_required = true,
        .lease_transport = "fd-only",
    });
}

fn cmdCompileReplay(allocator: std.mem.Allocator, options: Options) !void {
    var loaded = try loadLane(allocator, options.trial_path orelse return error.MissingTrial, options.lane_id orelse return error.MissingLaneId);
    defer loaded.parsed.deinit();
    var effective_profile = try effectiveSourceProfile(allocator, loaded.view.source_profile, options.source_profile_fd);
    defer effective_profile.deinit();
    var view = loaded.view;
    view.source_profile = effective_profile.value;
    var profile_report = try adapter.validateHistoricalProfile(
        allocator,
        view.source_profile,
        std.mem.eql(u8, view.purpose, "promotion") or std.mem.eql(u8, view.purpose, "practice_repair"),
    );
    defer profile_report.deinit(allocator);
    const profile = try object(view.source_profile);
    const output_dir = options.output_dir orelse return error.MissingOutputDir;
    try std.Io.Dir.cwd().createDirPath(defaultIo(), output_dir);
    const capsule_path = try std.fmt.allocPrint(allocator, "{s}/{s}.dcp.json", .{ output_dir, view.lane_id });
    defer allocator.free(capsule_path);
    const plan_path = try std.fmt.allocPrint(allocator, "{s}/{s}.rip.json", .{ output_dir, view.lane_id });
    defer allocator.free(plan_path);
    const context = profile.get("decision_context") orelse return error.DecisionContextMissing;
    const context_json = try attestation.canonicalJsonAlloc(allocator, context);
    defer allocator.free(context_json);
    try durable_store.writeTextAtomic(allocator, capsule_path, context_json);
    const prompt = try replayPromptAlloc(allocator, view);
    defer allocator.free(prompt);
    const plan = try adapter.compileReplayPlanAlloc(allocator, context, .{
        .inquiry_id = view.trial_id,
        .lane_id = view.lane_id,
        .prompt_template = prompt,
        .workspace_policy = profile_report.reconstructability,
        .maximum_lane_duration_ms = try requiredU64(view.execution, "maximum_lane_duration_ms"),
        .maximum_tokens_per_lane = try requiredU64(view.execution, "maximum_tokens_per_lane"),
    });
    defer allocator.free(plan);
    try durable_store.writeTextAtomic(allocator, plan_path, plan);
    try printJson(.{
        .schema = "cas-trial-replay-plan-receipt/v1",
        .trial_id = view.trial_id,
        .lane_id = view.lane_id,
        .capsule_ref = capsule_path,
        .plan_ref = plan_path,
        .lane_count = 1,
        .fork_count = 1,
    });
}

fn cmdRun(allocator: std.mem.Allocator, options: Options) !void {
    var loaded = try loadLane(allocator, options.trial_path orelse return error.MissingTrial, options.lane_id orelse return error.MissingLaneId);
    defer loaded.parsed.deinit();
    const receipt_dir = options.receipt_dir orelse return error.MissingReceiptDir;
    const registration_digest = options.registration_event_digest orelse return error.MissingRegistrationDigest;
    const start_digest = options.start_event_digest orelse return error.MissingStartDigest;
    try validateFingerprint(registration_digest);
    try validateFingerprint(start_digest);

    const lease_fd = options.lease_fd orelse return error.MissingLeaseFd;
    const input_fd = options.input_fd orelse return error.MissingInputFd;
    const signing_seed_fd = options.signing_seed_fd;
    try validateSensitiveInputFds(lease_fd, input_fd, options.source_profile_fd, signing_seed_fd);
    const lease = try readOwnedFdRawAlloc(allocator, lease_fd, 256);
    defer {
        std.crypto.secureZero(u8, lease);
        allocator.free(lease);
    }
    if (!std.mem.startsWith(u8, lease, "HYL1-")) return error.LaneLeaseInvalid;
    const lease_digest = try attestation.digestBytesAlloc(allocator, lease);
    defer allocator.free(lease_digest);
    const input = try readOwnedFdRawAlloc(allocator, input_fd, MaxInputBytes);
    defer allocator.free(input);
    const input_fingerprint = try attestation.digestBytesAlloc(allocator, input);
    defer allocator.free(input_fingerprint);
    if (!std.mem.eql(u8, input_fingerprint, options.presented_input_fingerprint orelse return error.MissingInputFingerprint)) {
        return error.PresentedInputMismatch;
    }
    var effective_profile = try effectiveSourceProfile(allocator, loaded.view.source_profile, options.source_profile_fd);
    defer effective_profile.deinit();
    var view = loaded.view;
    view.source_profile = effective_profile.value;
    const source_kind = try requiredString(try object(view.source_profile), "kind");
    if (std.mem.eql(u8, source_kind, "historical_decision")) {
        var profile_report = try adapter.validateHistoricalProfile(
            allocator,
            view.source_profile,
            std.mem.eql(u8, view.purpose, "promotion") or std.mem.eql(u8, view.purpose, "practice_repair"),
        );
        profile_report.deinit(allocator);
    } else if (!std.mem.eql(u8, source_kind, "direct")) return error.SourceProfileInvalid;

    // Everything needed to produce and, when required, sign a terminal receipt
    // is established before the irreversible lane claim. A missing executor,
    // invalid contract, or unavailable signing authority therefore cannot strand
    // a claimed lane without an accountable terminal artifact.
    const executable_store = if (options.claim_store_override) |override|
        try std.fs.path.resolve(allocator, &.{ override, ".executables" })
    else
        try authoritativeRunnerStoreAlloc(allocator, "hctp-executables-v1");
    defer allocator.free(executable_store);
    const executor = try bindExecutableInStoreAlloc(
        allocator,
        options.executor orelse return error.MissingExecutor,
        executable_store,
    );
    defer executor.deinit(allocator);
    const ledger = try bindExecutableInStoreAlloc(
        allocator,
        options.ledger orelse return error.MissingLedger,
        executable_store,
    );
    defer ledger.deinit(allocator);
    const assurance = try requiredString(try requiredObject(view.trial, "assurance"), "required_level");
    const sealed = std.mem.eql(u8, assurance, "sealed");
    const producer_binary = try currentExecutableFingerprintAlloc(allocator);
    defer allocator.free(producer_binary);
    const runner_contract = try validateRunnerContract(
        allocator,
        view.trial,
        view.execution,
        producer_binary,
        executor.fingerprint,
        ledger.fingerprint,
    );
    var signing_seed: ?[32]u8 = if (std.mem.eql(u8, assurance, "precommitted")) blk: {
        if (signing_seed_fd) |fd| {
            closeOwnedFd(fd);
            return error.SigningSeedForbidden;
        }
        break :blk null;
    } else blk: {
        var seed = try readSigningSeed(signing_seed_fd orelse return error.MissingSigningSeedFd);
        defer std.crypto.secureZero(u8, &seed);
        try validateSigningAuthority(allocator, view.trial, options.producer_id, options.producer_key_id, seed);
        break :blk seed;
    };
    defer if (signing_seed) |*seed| std.crypto.secureZero(u8, seed);

    const paths = try lanePathsAlloc(
        allocator,
        receipt_dir,
        options.claim_store_override,
        view.trial_id,
        view.lane_id,
    );
    defer paths.deinit(allocator);
    const target_materialization = try resolveTargetMaterializationAlloc(
        allocator,
        view,
        options.repo,
        &ledger,
        registration_digest,
        start_digest,
        lease_digest,
        input_fingerprint,
        paths.target_materialization_workspace,
        paths.target_materialization_archive,
        paths.target_package_root,
    );
    defer target_materialization.deinit(allocator);
    if (sealed and
        (target_materialization.effect_policy_bytes == null or
            target_materialization.effect_policy_fingerprint == null))
    {
        return error.EffectPolicyMissing;
    }
    const factor_materialization = try resolveFactorMaterializationAlloc(
        allocator,
        view,
        options.repo,
        paths.factor_materialization_workspace,
        paths.factor_materialization_archive,
    );
    defer factor_materialization.deinit(allocator);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.root);
    if (pathExists(paths.receipt) or pathExists(paths.workspace)) {
        return error.LaneAlreadyClaimed;
    }
    const input_path = try std.fmt.allocPrint(allocator, "{s}/presented-input.json", .{paths.workspace});
    defer allocator.free(input_path);
    const request = try buildExecutorRequestAlloc(
        allocator,
        view,
        paths.execution_root,
        paths.decision_context,
        input_path,
        input_fingerprint,
        lease_digest,
        factor_materialization,
        target_materialization,
    );
    defer allocator.free(request);
    const claim_path = try claimPathAlloc(allocator, paths.claim, registration_digest);
    defer allocator.free(claim_path);
    try claimLane(allocator, claim_path, view, registration_digest, start_digest, lease_digest);
    var milestones = FailureMilestones{};
    const executor_output_limit = options.executor_output_limit_override orelse MaxInputBytes;
    const receipt = runClaimedLaneAlloc(
        allocator,
        view,
        paths,
        options.repo,
        input,
        input_path,
        request,
        registration_digest,
        start_digest,
        lease_digest,
        input_fingerprint,
        &executor,
        runner_contract,
        options.producer_id,
        producer_binary,
        options.producer_key_id,
        signing_seed,
        factor_materialization,
        target_materialization,
        &milestones,
        executor_output_limit,
    ) catch |run_error| blk: {
        // A claimed lane remains nonterminal while executor liveness is
        // unproved. Sealing evidence or a receipt here would let a surviving
        // process mutate the attested workspace after terminalization.
        if (run_error == error.ExecutorLivenessUnproved) return run_error;
        const failure_receipt = try buildClaimedFailureReceiptAlloc(
            allocator,
            view,
            paths,
            registration_digest,
            start_digest,
            lease_digest,
            input_fingerprint,
            executor.origin_path,
            executor.fingerprint,
            runner_contract,
            options.producer_id,
            producer_binary,
            options.producer_key_id,
            signing_seed,
            factor_materialization,
            target_materialization,
            milestones,
            run_error,
            executor_output_limit,
        );
        break :blk failure_receipt;
    };
    defer allocator.free(receipt);
    try sealEvidenceArchive(allocator, paths.evidence);
    if (try regularFileExistsNoFollow(paths.failure_detail)) {
        const failure_fingerprint = try sealExistingControlArtifactAlloc(allocator, paths.failure_detail);
        allocator.free(failure_fingerprint);
    }
    try persistTerminalPayload(
        allocator,
        paths,
        view.trial_id,
        view.lane_id,
        registration_digest,
        receipt,
    );
    const terminal_control = try reconcileTerminalProjectionAlloc(
        allocator,
        paths,
        view.trial_id,
        view.lane_id,
        registration_digest,
    );
    terminal_control.deinit(allocator);
    const fingerprint = try digestJsonTextAlloc(allocator, receipt);
    defer allocator.free(fingerprint);
    var receipt_parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{});
    defer receipt_parsed.deinit();
    const terminal_status = try requiredString(try requiredObject(try object(receipt_parsed.value), "terminal"), "status");
    if (!builtin.is_test) {
        try printJson(.{
            .schema = "cas-trial-run-result/v1",
            .status = "terminal",
            .terminal_status = terminal_status,
            .trial_id = view.trial_id,
            .lane_id = view.lane_id,
            .receipt_ref = paths.receipt,
            .receipt_fingerprint = fingerprint,
            .lease_digest = lease_digest,
        });
    }
}

fn runClaimedLaneAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    paths: LanePaths,
    repo: []const u8,
    input: []const u8,
    input_path: []const u8,
    request: []const u8,
    registration_digest: []const u8,
    start_digest: []const u8,
    lease_digest: []const u8,
    input_fingerprint: []const u8,
    executor: *const ExecutableBinding,
    runner_contract: RunnerContractValidation,
    producer_id: []const u8,
    producer_binary: []const u8,
    producer_key_id: []const u8,
    signing_seed: ?[32]u8,
    factor_materialization: FactorMaterialization,
    target_materialization: TargetMaterialization,
    milestones: *FailureMilestones,
    executor_output_limit: usize,
) ![]u8 {
    try durable_store.ensureDirectoryPathNoSymlinks(paths.workspace);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.execution_root);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.executor_output_root);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.evidence);
    milestones.workspace_created = true;
    try persistTargetMaterialization(allocator, target_materialization);
    milestones.target_materialization_persisted = target_materialization.present;
    const target_package_baseline = try captureTargetPackageBaselineAlloc(allocator, target_materialization);
    defer if (target_package_baseline) |snapshot| snapshot.deinit(allocator);
    try persistFactorMaterialization(allocator, factor_materialization);
    milestones.factor_materialization_persisted = factor_materialization.present;
    try materializeExecutionProjection(
        allocator,
        view,
        repo,
        paths.execution_root,
        target_materialization,
    );
    const execution_tree_baseline = try captureExecutionTreeAlloc(allocator, paths.execution_root);
    defer execution_tree_baseline.deinit(allocator);
    try verifyExecutionTreeBaseline(allocator, execution_tree_baseline, target_materialization);
    try durable_store.writeTextCreateNewAtomic(allocator, input_path, input, .{});
    try archiveFileAtPath(allocator, input_path, paths.presented_input_archive, input_fingerprint);
    milestones.input_persisted = true;
    try persistDecisionContext(allocator, view, paths);
    try durable_store.writeTextCreateNewAtomic(allocator, paths.request, request, .{});
    milestones.request_persisted = true;
    const result = runExecutorForTrial(
        allocator,
        executor,
        paths.request,
        paths.executor_result,
        paths.execution_root,
        paths.executor_output_root,
        try requiredU64(view.execution, "maximum_lane_duration_ms"),
        executor_output_limit,
    ) catch |run_error| {
        const package_observation = observeTargetPackageAfterExecutionAlloc(
            allocator,
            target_materialization,
            target_package_baseline,
        ) catch |observation_error| {
            return preserveOutputCarrierDistrust(run_error, observation_error);
        };
        package_observation.deinit(allocator);
        return run_error;
    };
    milestones.executor_returned = true;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const target_package_observation = try observeTargetPackageAfterExecutionAlloc(
        allocator,
        target_materialization,
        target_package_baseline,
    );
    defer target_package_observation.deinit(allocator);
    if (result.termination == .signaled) return error.ExecutorAborted;
    if (result.exit_code != 0) return error.ExecutorFailed;
    const output_carrier_fingerprint = try verifyExecutorOutputCarrierAlloc(
        allocator,
        paths.executor_output_root,
        paths.executor_result,
    );
    defer allocator.free(output_carrier_fingerprint);
    const result_raw = try readFileAlloc(allocator, paths.executor_result, MaxInputBytes);
    defer allocator.free(result_raw);
    const execution_tree_observed = try observeExecutionTreeAlloc(
        allocator,
        paths.execution_root,
        execution_tree_baseline,
        target_materialization,
        result_raw,
        output_carrier_fingerprint,
    );
    defer execution_tree_observed.deinit(allocator);
    const unsigned = try buildRunReceiptAlloc(
        allocator,
        view,
        result_raw,
        paths,
        registration_digest,
        start_digest,
        lease_digest,
        input_path,
        input_fingerprint,
        executor.origin_path,
        executor.fingerprint,
        runner_contract,
        producer_id,
        Version,
        producer_binary,
        producer_key_id,
        factor_materialization,
        target_materialization,
        target_package_observation,
        execution_tree_observed,
    );
    defer allocator.free(unsigned);
    return signTerminalReceiptAlloc(
        allocator,
        unsigned,
        producer_id,
        producer_binary,
        producer_key_id,
        signing_seed,
    );
}

fn persistDecisionContext(
    allocator: std.mem.Allocator,
    view: LaneView,
    paths: LanePaths,
) !void {
    const profile = try object(view.source_profile);
    if (std.mem.eql(u8, try requiredString(profile, "kind"), "direct")) return;
    const context = profile.get("decision_context") orelse return error.DecisionContextMissing;
    const canonical = try attestation.canonicalJsonAlloc(allocator, context);
    defer allocator.free(canonical);
    const expected_fingerprint = try requiredString(profile, "decision_context_fingerprint");
    try requireBytesFingerprint(allocator, canonical, expected_fingerprint);
    try durable_store.writeTextCreateNewAtomic(allocator, paths.decision_context, canonical, .{});
    try archiveFileAtPath(
        allocator,
        paths.decision_context,
        paths.decision_context_archive,
        expected_fingerprint,
    );
    try makePathReadOnly(paths.decision_context);
}

const FailureDisposition = struct {
    status: []const u8,
    class: []const u8,
};

const FailureMilestones = struct {
    workspace_created: bool = false,
    target_materialization_persisted: bool = false,
    factor_materialization_persisted: bool = false,
    input_persisted: bool = false,
    request_persisted: bool = false,
    executor_returned: bool = false,
};

fn createFailureRunnerObservationsAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    paths: LanePaths,
    target_materialization: TargetMaterialization,
    executor_fingerprint: []const u8,
    runner_contract: RunnerContractValidation,
    milestones: FailureMilestones,
    failure_detail_fingerprint: []const u8,
) !RunnerObservationReceipts {
    const effect_policy_fingerprint = try requiredString(view.execution, "effect_policy_fingerprint");
    try validateFingerprint(effect_policy_fingerprint);
    const effect_policy_authenticated = target_materialization.effect_policy_fingerprint != null;

    var reset: std.Io.Writer.Allocating = .init(allocator);
    defer reset.deinit();
    try reset.writer.writeByte('{');
    try writeStringMember(&reset.writer, "schema", "cas-reset-observation/v1", true);
    try writeStringMember(&reset.writer, "status", "incomplete", true);
    try writeStringMember(&reset.writer, "trial_id", view.trial_id, true);
    try writeStringMember(&reset.writer, "lane_id", view.lane_id, true);
    try writeStringMember(&reset.writer, "executor_binary_fingerprint", executor_fingerprint, true);
    try writeStringMember(&reset.writer, "failure_detail_ref", paths.failure_detail, true);
    try writeStringMember(&reset.writer, "failure_detail_fingerprint", failure_detail_fingerprint, true);
    try reset.writer.writeAll("\"workspace_created\":");
    try reset.writer.writeAll(if (milestones.workspace_created) "true" else "false");
    try reset.writer.writeAll(",\"request_persisted\":");
    try reset.writer.writeAll(if (milestones.request_persisted) "true" else "false");
    try reset.writer.writeAll(",\"executor_returned\":");
    try reset.writer.writeAll(if (milestones.executor_returned) "true" else "false");
    try writeCapabilitySealMembers(&reset.writer, runner_contract.capability_seal);
    try reset.writer.writeByte('}');
    const reset_fingerprint = try persistRunnerObservationAlloc(allocator, paths.failure_reset_observation, reset.written());
    errdefer allocator.free(reset_fingerprint);

    var filesystem: std.Io.Writer.Allocating = .init(allocator);
    defer filesystem.deinit();
    try filesystem.writer.writeByte('{');
    try writeStringMember(&filesystem.writer, "schema", "cas-filesystem-observation/v1", true);
    try writeStringMember(&filesystem.writer, "status", "unobserved", true);
    try writeStringMember(&filesystem.writer, "trial_id", view.trial_id, true);
    try writeStringMember(&filesystem.writer, "lane_id", view.lane_id, true);
    try writeStringMember(&filesystem.writer, "effect_policy_fingerprint", effect_policy_fingerprint, true);
    try writeStringMember(&filesystem.writer, "policy", "workspace_write", true);
    try writeStringMember(&filesystem.writer, "mediation_owner", "attested-executor", true);
    try writeStringMember(&filesystem.writer, "default_effect_decision", "deny", true);
    try writeStringMember(&filesystem.writer, "failure_detail_ref", paths.failure_detail, true);
    try writeStringMember(&filesystem.writer, "failure_detail_fingerprint", failure_detail_fingerprint, true);
    try filesystem.writer.writeAll("\"registered_policy_authenticated\":");
    try filesystem.writer.writeAll(if (effect_policy_authenticated) "true" else "false");
    try filesystem.writer.writeAll(",\"independently_enforced\":false,\"carrier_observation_complete\":false,\"os_confinement\":false}");
    const filesystem_fingerprint = try persistRunnerObservationAlloc(allocator, paths.failure_filesystem_observation, filesystem.written());
    errdefer allocator.free(filesystem_fingerprint);

    var network: std.Io.Writer.Allocating = .init(allocator);
    defer network.deinit();
    try network.writer.writeByte('{');
    try writeStringMember(&network.writer, "schema", "cas-network-observation/v1", true);
    try writeStringMember(&network.writer, "status", "unobserved", true);
    try writeStringMember(&network.writer, "trial_id", view.trial_id, true);
    try writeStringMember(&network.writer, "lane_id", view.lane_id, true);
    try writeStringMember(&network.writer, "effect_policy_fingerprint", effect_policy_fingerprint, true);
    try writeStringMember(&network.writer, "policy", "deny", true);
    try writeStringMember(&network.writer, "mediation_owner", "attested-executor", true);
    try writeStringMember(&network.writer, "default_effect_decision", "deny", true);
    try writeStringMember(&network.writer, "failure_detail_ref", paths.failure_detail, true);
    try writeStringMember(&network.writer, "failure_detail_fingerprint", failure_detail_fingerprint, true);
    try network.writer.writeAll("\"registered_policy_authenticated\":");
    try network.writer.writeAll(if (effect_policy_authenticated) "true" else "false");
    try network.writer.writeAll(",\"independently_enforced\":false,\"os_confinement\":false}");
    const network_fingerprint = try persistRunnerObservationAlloc(allocator, paths.failure_network_observation, network.written());
    errdefer allocator.free(network_fingerprint);

    var external_effect: std.Io.Writer.Allocating = .init(allocator);
    defer external_effect.deinit();
    try external_effect.writer.writeByte('{');
    try writeStringMember(&external_effect.writer, "schema", "cas-external-effect-observation/v1", true);
    try writeStringMember(&external_effect.writer, "status", "unobserved", true);
    try writeStringMember(&external_effect.writer, "trial_id", view.trial_id, true);
    try writeStringMember(&external_effect.writer, "lane_id", view.lane_id, true);
    try writeStringMember(&external_effect.writer, "effect_policy_fingerprint", effect_policy_fingerprint, true);
    try writeStringMember(&external_effect.writer, "policy", "deny", true);
    try writeStringMember(&external_effect.writer, "mediation_owner", "attested-executor", true);
    try writeStringMember(&external_effect.writer, "default_effect_decision", "deny", true);
    try writeStringMember(&external_effect.writer, "failure_detail_ref", paths.failure_detail, true);
    try writeStringMember(&external_effect.writer, "failure_detail_fingerprint", failure_detail_fingerprint, true);
    try external_effect.writer.writeAll("\"registered_policy_authenticated\":");
    try external_effect.writer.writeAll(if (effect_policy_authenticated) "true" else "false");
    try external_effect.writer.writeAll(",\"independently_enforced\":false,\"direct_native_effects_intercepted\":false,\"os_confinement\":false}");
    const external_effect_fingerprint = try persistRunnerObservationAlloc(
        allocator,
        paths.failure_external_effect_observation,
        external_effect.written(),
    );
    errdefer allocator.free(external_effect_fingerprint);

    return .{
        .reset_fingerprint = reset_fingerprint,
        .filesystem_fingerprint = filesystem_fingerprint,
        .network_fingerprint = network_fingerprint,
        .external_effect_fingerprint = external_effect_fingerprint,
        .limitations = try allocator.dupe(
            u8,
            "[\"carrier, process, and effect-mediation observations are incomplete; inspect the CAS failure detail\",\"hostile arbitrary native code is not OS-confined and can bypass attested-executor mediation\"]",
        ),
    };
}

fn failureDisposition(err: anyerror) FailureDisposition {
    return switch (err) {
        error.ExecutorTimedOut => .{ .status = "aborted", .class = "executor_deadline_exceeded" },
        error.ExecutorStdoutLimitExceeded,
        error.ExecutorStderrLimitExceeded,
        error.ExecutorOutputLimitExceeded,
        => .{ .status = "aborted", .class = "executor_output_limit_exceeded" },
        error.ExecutorAborted => .{ .status = "aborted", .class = "executor_terminated_by_signal" },
        error.ExecutorGroupKillFailed,
        error.ExecutorGroupWaitFailed,
        error.ExecutorGroupStillAlive,
        => .{ .status = "aborted", .class = "executor_process_group_failure" },
        error.ExecutorFailed => .{ .status = "failed", .class = "executor_exit_nonzero" },
        error.ExecutorSpawnFailed,
        error.ExecutorSpawnAccessDenied,
        error.ExecutorNotFoundAtSpawn,
        error.ExecutorFormatInvalid,
        error.ExecutorSpawnOutOfMemory,
        error.ExecutorWaitFailed,
        error.SpawnFileActionsFailed,
        error.SpawnAttributesFailed,
        error.ExecutorFdContainmentFailed,
        => .{ .status = "failed", .class = "executor_process_failure" },
        error.ExecutorOutputCaptureFailed,
        error.ExecutorOutputCarrierDrift,
        => .{ .status = "invalid", .class = "runner_output_capture_failure" },
        error.ExecutableBindingDrift => .{ .status = "invalid", .class = "executor_binary_binding_drift" },
        else => .{ .status = "invalid", .class = "runner_normalization_failure" },
    };
}

fn preserveOutputCarrierDistrust(run_error: anyerror, secondary_error: anyerror) anyerror {
    return if (run_error == error.ExecutorOutputCarrierDrift) run_error else secondary_error;
}

fn executorCaptureWasForcedIncomplete(err: anyerror) bool {
    return switch (err) {
        error.ExecutorTimedOut,
        error.ExecutorStdoutLimitExceeded,
        error.ExecutorStderrLimitExceeded,
        error.ExecutorOutputLimitExceeded,
        error.ExecutorOutputCaptureFailed,
        error.ExecutorOutputCarrierDrift,
        error.ExecutorWaitFailed,
        error.ExecutorGroupKillFailed,
        error.ExecutorGroupWaitFailed,
        error.ExecutorGroupStillAlive,
        => true,
        else => false,
    };
}

fn buildClaimedFailureReceiptAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    paths: LanePaths,
    registration_digest: []const u8,
    start_digest: []const u8,
    lease_digest: []const u8,
    input_fingerprint: []const u8,
    executor: []const u8,
    executor_fingerprint: []const u8,
    runner_contract: RunnerContractValidation,
    producer_id: []const u8,
    producer_binary: []const u8,
    producer_key_id: []const u8,
    signing_seed: ?[32]u8,
    factor_materialization: FactorMaterialization,
    target_materialization: TargetMaterialization,
    milestones: FailureMilestones,
    run_error: anyerror,
    executor_output_limit: usize,
) ![]u8 {
    const disposition = failureDisposition(run_error);
    const carrier_path_untrusted = run_error == error.ExecutorOutputCarrierDrift;
    const stdout_evidence = if (carrier_path_untrusted)
        null
    else
        try boundedRegularCaptureEvidenceAlloc(
            allocator,
            paths.executor_stdout,
            executor_output_limit,
        );
    defer if (stdout_evidence) |evidence| allocator.free(evidence.fingerprint);
    const stderr_evidence = if (carrier_path_untrusted)
        null
    else
        try boundedRegularCaptureEvidenceAlloc(
            allocator,
            paths.executor_stderr,
            executor_output_limit,
        );
    defer if (stderr_evidence) |evidence| allocator.free(evidence.fingerprint);
    const stdout_fingerprint = if (stdout_evidence) |evidence| evidence.fingerprint else null;
    const stderr_fingerprint = if (stderr_evidence) |evidence| evidence.fingerprint else null;
    const stdout_size = if (stdout_evidence) |evidence| evidence.size else null;
    const stderr_size = if (stderr_evidence) |evidence| evidence.size else null;
    const forced_incomplete = executorCaptureWasForcedIncomplete(run_error);
    const stdout_truncated = run_error == error.ExecutorStdoutLimitExceeded or
        run_error == error.ExecutorOutputLimitExceeded;
    const stderr_truncated = run_error == error.ExecutorStderrLimitExceeded or
        run_error == error.ExecutorOutputLimitExceeded;
    const detail = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-trial-failure-detail/v1\",\"trial_id\":{f},\"lane_id\":{f},\"terminal_status\":{f},\"failure_class\":{f},\"runner_error\":{f},\"executor\":{f},\"executor_binary_fingerprint\":{f},\"milestones\":{{\"workspace_created\":{},\"target_materialization_persisted\":{},\"factor_materialization_persisted\":{},\"input_persisted\":{},\"request_persisted\":{},\"executor_returned\":{}}},\"executor_stdout_ref\":{f},\"executor_stdout_fingerprint\":{f},\"executor_stderr_ref\":{f},\"executor_stderr_fingerprint\":{f},\"output_capture\":{{\"limit_bytes_per_stream\":{},\"stdout_bytes_persisted\":{f},\"stderr_bytes_persisted\":{f},\"stdout_complete\":{},\"stderr_complete\":{},\"stdout_truncated\":{},\"stderr_truncated\":{}}},\"lease_secret_persisted\":false,\"signing_seed_persisted\":false}}\n",
        .{
            std.json.fmt(view.trial_id, .{}),
            std.json.fmt(view.lane_id, .{}),
            std.json.fmt(disposition.status, .{}),
            std.json.fmt(disposition.class, .{}),
            std.json.fmt(@errorName(run_error), .{}),
            std.json.fmt(executor, .{}),
            std.json.fmt(executor_fingerprint, .{}),
            milestones.workspace_created,
            milestones.target_materialization_persisted,
            milestones.factor_materialization_persisted,
            milestones.input_persisted,
            milestones.request_persisted,
            milestones.executor_returned,
            std.json.fmt(if (stdout_fingerprint != null) paths.executor_stdout else null, .{}),
            std.json.fmt(stdout_fingerprint, .{}),
            std.json.fmt(if (stderr_fingerprint != null) paths.executor_stderr else null, .{}),
            std.json.fmt(stderr_fingerprint, .{}),
            executor_output_limit,
            std.json.fmt(stdout_size, .{}),
            std.json.fmt(stderr_size, .{}),
            milestones.executor_returned and !forced_incomplete and stdout_fingerprint != null,
            milestones.executor_returned and !forced_incomplete and stderr_fingerprint != null,
            stdout_truncated,
            stderr_truncated,
        },
    );
    defer allocator.free(detail);
    const detail_fingerprint = try persistExpectedSealedArtifactAlloc(allocator, paths.failure_detail, detail);
    defer allocator.free(detail_fingerprint);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.evidence);
    const observations = try createFailureRunnerObservationsAlloc(
        allocator,
        view,
        paths,
        target_materialization,
        executor_fingerprint,
        runner_contract,
        milestones,
        detail_fingerprint,
    );
    defer observations.deinit(allocator);
    const failure_audit_path = paths.failure_execution_audit;
    const failure_audit = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-trial-process-audit/v1\",\"trial_id\":{f},\"lane_id\":{f},\"executor_launch_count\":{},\"executor_returned\":{},\"internal_model_execution_count\":null,\"internal_retry_count\":null,\"internal_fork_count\":null,\"internal_execution_verified\":false}}\n",
        .{
            std.json.fmt(view.trial_id, .{}),
            std.json.fmt(view.lane_id, .{}),
            @intFromBool(milestones.request_persisted),
            milestones.executor_returned,
        },
    );
    defer allocator.free(failure_audit);
    const failure_audit_fingerprint = try persistExpectedSealedArtifactAlloc(allocator, failure_audit_path, failure_audit);
    defer allocator.free(failure_audit_fingerprint);
    const source_profile = try object(view.source_profile);
    const historical = std.mem.eql(u8, try requiredString(source_profile, "kind"), "historical_decision");
    if (historical) try ensureHistoricalDecisionContextArchive(allocator, view, paths);
    const native = if (historical)
        try historicalTerminalNativeReceiptAlloc(
            allocator,
            view,
            lease_digest,
            disposition,
            executor,
            executor_fingerprint,
            paths.decision_context_archive,
            failure_audit_path,
            failure_audit_fingerprint,
        )
    else
        try casNativeReceiptAlloc(
            allocator,
            view,
            lease_digest,
            disposition.status,
            executor,
            executor_fingerprint,
            failure_audit_path,
            failure_audit_fingerprint,
            false,
        );
    defer allocator.free(native.json);
    defer allocator.free(native.fingerprint);
    try archiveBytesAtPath(allocator, native.json, paths.failure_native_receipt, native.fingerprint);
    const seed_json = try canonicalFieldAlloc(allocator, view.pair.get("shared_seed") orelse .null);
    defer allocator.free(seed_json);
    const now = unixSeconds();
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try writeStringMember(writer, "schema", "hylo-run-receipt/v1", true);
    try writeStringMember(writer, "trial_id", view.trial_id, true);
    try writeStringMember(writer, "unit_id", view.unit_id, true);
    try writeStringMember(writer, "scenario_id", view.scenario_id, true);
    try writeStringMember(writer, "pair_id", view.pair_id, true);
    try writeStringMember(writer, "lane_id", view.lane_id, true);
    try writeStringMember(writer, "opaque_arm_id", view.arm_id, true);
    try writer.writeAll("\"lineage\":{");
    try writeStringMember(writer, "registration_event_digest", registration_digest, true);
    try writeStringMember(writer, "lane_started_event_digest", start_digest, true);
    try writeStringMember(writer, "lane_lease_digest", lease_digest, false);
    try writer.writeAll("},\"producer\":{");
    try writeStringMember(writer, "id", producer_id, true);
    try writeStringMember(writer, "version", Version, true);
    try writeStringMember(writer, "binary_fingerprint", producer_binary, true);
    try writeStringMember(writer, "key_id", producer_key_id, true);
    try writeStringMember(writer, "receiver_role", "runner", true);
    try writeStringMember(writer, "receiver_key_id", producer_key_id, false);
    try writer.writeAll("},\"materialization\":{");
    try writeStringMember(writer, "arm_value_fingerprint", target_materialization.arm_value_fingerprint orelse return error.TargetMaterializationClaimMismatch, true);
    try writeStringMember(writer, "target_snapshot_ref", target_materialization.snapshot_ref orelse return error.TargetMaterializationClaimMismatch, true);
    try writeStringMember(writer, "target_snapshot_fingerprint", target_materialization.snapshot_fingerprint orelse return error.TargetMaterializationClaimMismatch, true);
    try writeOptionalStringMember(
        writer,
        "target_materialization_archive_ref",
        if (target_materialization.present and pathExists(target_materialization.archive_ref)) target_materialization.archive_ref else null,
        true,
    );
    try writeOptionalStringMember(
        writer,
        "target_materialization_archive_fingerprint",
        if (target_materialization.present and pathExists(target_materialization.archive_ref)) target_materialization.carrier_fingerprint else null,
        true,
    );
    try writeOptionalStringMember(writer, "factor_materialization_ref", if (factor_materialization.present) factor_materialization.ref else null, true);
    try writeOptionalStringMember(writer, "factor_materialization_fingerprint", if (factor_materialization.present) factor_materialization.fingerprint else null, true);
    try writeOptionalStringMember(
        writer,
        "factor_materialization_archive_ref",
        if (factor_materialization.present and pathExists(factor_materialization.archive_ref)) factor_materialization.archive_ref else null,
        true,
    );
    try writeOptionalStringMember(
        writer,
        "factor_materialization_archive_fingerprint",
        if (factor_materialization.present and pathExists(factor_materialization.archive_ref)) factor_materialization.fingerprint else null,
        true,
    );
    try writeStringMember(writer, "presented_input_ref", paths.presented_input_archive, true);
    try writeStringMember(writer, "presented_input_fingerprint", input_fingerprint, true);
    if (try sourceIdentity(view)) |identity| {
        try writeStringMember(writer, "source_episode_fingerprint", identity.episode_fingerprint, true);
        try writeStringMember(writer, "source_profile_fingerprint", identity.profile_fingerprint, true);
    }
    try writer.writeAll("\"hidden_reference_presented\":false,\"sibling_output_presented\":false},\"runtime\":{");
    try writeStringMember(writer, "environment_fingerprint", try requiredString(view.execution, "environment_fingerprint"), true);
    try writeStringMember(writer, "replay_policy_fingerprint", try requiredString(view.execution, "replay_policy_fingerprint"), true);
    try writeStringMember(writer, "effect_policy_fingerprint", try requiredString(view.execution, "effect_policy_fingerprint"), true);
    try writeStringMember(writer, "model_id", "unavailable-after-runner-failure", true);
    try writeStringMember(writer, "model_provider", "unavailable", true);
    try writeStringMember(writer, "model_configuration_fingerprint", try requiredString(view.execution, "model_policy_fingerprint"), true);
    try writeStringMember(writer, "runtime_version", Version, true);
    try writer.writeAll("\"seed\":");
    try writer.writeAll(seed_json);
    try writer.print(",\"tokens_used\":0,\"started_at_unix\":{d},\"ended_at_unix\":{d}}},", .{ now, now });
    try writer.writeAll("\"isolation\":{\"fresh_thread\":false,\"fresh_workspace\":");
    try writer.writeAll(if (milestones.workspace_created) "true," else "false,");
    try writeStringMember(writer, "reset_receipt_ref", paths.failure_reset_observation, true);
    try writeStringMember(writer, "reset_receipt_fingerprint", observations.reset_fingerprint, true);
    try writer.writeAll("\"target_cache_cleared\":false,\"shared_mutable_state_detected\":false,\"limitations\":");
    try writer.writeAll(observations.limitations);
    try writeCapabilitySealMembers(writer, runner_contract.capability_seal);
    try writer.writeAll("},\"effects\":{");
    try writeStringMember(writer, "filesystem_receipt_ref", paths.failure_filesystem_observation, true);
    try writeStringMember(writer, "filesystem_receipt_fingerprint", observations.filesystem_fingerprint, true);
    try writeStringMember(writer, "network_receipt_ref", paths.failure_network_observation, true);
    try writeStringMember(writer, "network_receipt_fingerprint", observations.network_fingerprint, true);
    try writeStringMember(writer, "external_effect_receipt_ref", paths.failure_external_effect_observation, true);
    try writeStringMember(writer, "external_effect_receipt_fingerprint", observations.external_effect_fingerprint, true);
    try writer.writeAll("\"policy_violations\":[\"effect-observation-incomplete\"]},\"terminal\":{");
    try writeStringMember(writer, "status", disposition.status, true);
    try writeStringMember(writer, "failure_class", disposition.class, true);
    try writeStringMember(writer, "failure_detail_ref", paths.failure_detail, false);
    try writer.writeAll("},\"evidence\":{\"output_ref\":null,\"output_fingerprint\":null,\"trace_ref\":null,\"trace_fingerprint\":null,\"world_state_ref\":null,\"world_state_fingerprint\":null,\"metrics_ref\":null,\"metrics_fingerprint\":null},\"native_receipt\":{");
    try writeStringMember(writer, "kind", native.kind, true);
    try writeStringMember(writer, "ref", paths.failure_native_receipt, true);
    try writeStringMember(writer, "fingerprint", native.fingerprint, true);
    try writer.writeAll("\"receipt\":");
    try writer.writeAll(native.json);
    try writer.writeAll("},\"attestation\":null}");
    const unsigned = try out.toOwnedSlice();
    defer allocator.free(unsigned);
    return signTerminalReceiptAlloc(
        allocator,
        unsigned,
        producer_id,
        producer_binary,
        producer_key_id,
        signing_seed,
    );
}

fn ensureHistoricalDecisionContextArchive(
    allocator: std.mem.Allocator,
    view: LaneView,
    paths: LanePaths,
) !void {
    const profile = try object(view.source_profile);
    if (!std.mem.eql(u8, try requiredString(profile, "kind"), "historical_decision")) return;
    const context = profile.get("decision_context") orelse return error.DecisionContextMissing;
    const canonical = try attestation.canonicalJsonAlloc(allocator, context);
    defer allocator.free(canonical);
    const fingerprint = try requiredString(profile, "decision_context_fingerprint");
    try requireBytesFingerprint(allocator, canonical, fingerprint);
    if (pathExists(paths.decision_context_archive)) {
        const observed = try fileFingerprintAlloc(allocator, paths.decision_context_archive);
        defer allocator.free(observed);
        if (!std.mem.eql(u8, observed, fingerprint)) return error.DecisionContextFingerprintMismatch;
        return;
    }
    try archiveBytesAtPath(allocator, canonical, paths.decision_context_archive, fingerprint);
}

fn historicalTerminalNativeReceiptAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    lease_digest: []const u8,
    disposition: FailureDisposition,
    executor: []const u8,
    executor_fingerprint: []const u8,
    decision_context_ref: []const u8,
    execution_audit_ref: []const u8,
    execution_audit_fingerprint: []const u8,
) !NativeReceipt {
    const profile = try object(view.source_profile);
    const target_text_witness = profile.get("source_target_text_witness") orelse
        return error.SourceTargetTextWitnessMissing;
    const target_text_witness_fingerprint = try attestation.digestValueAlloc(allocator, target_text_witness);
    defer allocator.free(target_text_witness_fingerprint);
    const identity = try sourceIdentity(view);
    const source_profile_fingerprint = if (identity) |source|
        source.profile_fingerprint
    else
        optionalString(profile, "source_profile_fingerprint");
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"schema\":\"cas-historical-terminal-receipt/v1\",\"trial_id\":");
    try std.json.Stringify.value(view.trial_id, .{}, writer);
    try writer.writeAll(",\"lane_id\":");
    try std.json.Stringify.value(view.lane_id, .{}, writer);
    try writer.writeAll(",\"terminal_status\":");
    try std.json.Stringify.value(disposition.status, .{}, writer);
    try writer.writeAll(",\"claim\":{\"claim_id\":");
    try std.json.Stringify.value(view.lane_id, .{}, writer);
    try writer.writeAll(",\"atomic\":true,\"claimed_before_execution\":true,\"claim_count\":1,\"lane_lease_digest\":");
    try std.json.Stringify.value(lease_digest, .{}, writer);
    try writer.writeAll("},\"source\":{\"source_governance_fingerprint\":");
    try std.json.Stringify.value(try requiredString(profile, "source_governance_fingerprint"), .{}, writer);
    try writer.writeAll(",\"decision_context_ref\":");
    try std.json.Stringify.value(decision_context_ref, .{}, writer);
    try writer.writeAll(",\"decision_context_fingerprint\":");
    try std.json.Stringify.value(try requiredString(profile, "decision_context_fingerprint"), .{}, writer);
    try writer.writeAll(",\"temporal_horizon\":");
    try std.json.Stringify.value(try requiredString(profile, "temporal_horizon"), .{}, writer);
    try writer.writeAll(",\"source_target_text_policy\":");
    try std.json.Stringify.value(try requiredString(profile, "source_target_text_policy"), .{}, writer);
    try writer.writeAll(",\"source_target_text_witness_fingerprint\":");
    try std.json.Stringify.value(target_text_witness_fingerprint, .{}, writer);
    try writer.writeAll(",\"required_lineage\":");
    try std.json.Stringify.value(try requiredString(profile, "required_lineage"), .{}, writer);
    try writer.writeAll(",\"required_fir_version\":");
    try std.json.Stringify.value(try requiredString(profile, "required_fir_version"), .{}, writer);
    try writer.writeAll(",\"source_profile_fingerprint\":");
    try std.json.Stringify.value(source_profile_fingerprint, .{}, writer);
    try writer.writeAll("},\"execution\":{\"executor\":");
    try std.json.Stringify.value(executor, .{}, writer);
    try writer.writeAll(",\"executor_binary_fingerprint\":");
    try std.json.Stringify.value(executor_fingerprint, .{}, writer);
    try writer.writeAll(",\"execution_audit_ref\":");
    try std.json.Stringify.value(execution_audit_ref, .{}, writer);
    try writer.writeAll(",\"execution_audit_fingerprint\":");
    try std.json.Stringify.value(execution_audit_fingerprint, .{}, writer);
    try writer.writeAll(",\"handle_count\":1,\"retry_count\":0,\"hidden_fork_count\":0,\"internal_execution_verified\":false},\"fir\":{\"status\":\"unavailable\",\"receipt_ref\":null,\"receipt_fingerprint\":null,\"reason\":");
    try std.json.Stringify.value(disposition.class, .{}, writer);
    try writer.writeAll("},\"runner_contract_fingerprint\":");
    try std.json.Stringify.value(try requiredString(view.execution, "runner_contract_fingerprint"), .{}, writer);
    try writer.writeByte('}');
    const raw = try out.toOwnedSlice();
    defer allocator.free(raw);
    const json = try canonicalJsonTextAlloc(allocator, raw);
    return .{
        .kind = "cas-historical-terminal-receipt",
        .fingerprint = try attestation.digestBytesAlloc(allocator, json),
        .json = json,
    };
}

fn signTerminalReceiptAlloc(
    allocator: std.mem.Allocator,
    unsigned: []const u8,
    producer_id: []const u8,
    producer_binary: []const u8,
    producer_key_id: []const u8,
    signing_seed: ?[32]u8,
) ![]u8 {
    if (signing_seed == null) return allocator.dupe(u8, unsigned);
    return attestation.signReceiptAlloc(allocator, unsigned, .{
        .id = producer_id,
        .version = Version,
        .binary_fingerprint = producer_binary,
        .key_id = producer_key_id,
    }, "runner", unixSeconds(), signing_seed.?);
}

fn persistTerminalReceipt(allocator: std.mem.Allocator, path: []const u8, receipt: []const u8) !void {
    const fingerprint = persistExpectedSealedArtifactAlloc(allocator, path, receipt) catch |err| switch (err) {
        error.PersistedArtifactConflict => return error.LaneAlreadyTerminal,
        else => return err,
    };
    allocator.free(fingerprint);
}

fn sealEvidenceArchive(allocator: std.mem.Allocator, evidence_dir: []const u8) !void {
    const names = try durable_store.listSortedRegularFilesNoSymlink(
        allocator,
        evidence_dir,
        64,
        MaxTargetCarrierBytes,
    );
    defer durable_store.freeStringList(allocator, names);
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ evidence_dir, name });
        defer allocator.free(path);
        try makePathReadOnly(path);
    }
    var dir = if (std.fs.path.isAbsolute(evidence_dir))
        try std.Io.Dir.openDirAbsolute(defaultIo(), evidence_dir, .{})
    else
        try std.Io.Dir.cwd().openDir(defaultIo(), evidence_dir, .{});
    defer dir.close(defaultIo());
    try dir.setPermissions(defaultIo(), .fromMode(0o500));
}

const LaneControlVerification = struct {
    registration_digest: []u8,
    terminal_control_fingerprint: []u8,

    fn deinit(self: LaneControlVerification, allocator: std.mem.Allocator) void {
        allocator.free(self.registration_digest);
        allocator.free(self.terminal_control_fingerprint);
    }
};

const ControlArtifactKind = enum { terminal_payload, terminal, cleanup_intent, cleanup };

fn controlMarker(kind: ControlArtifactKind) []const u8 {
    return switch (kind) {
        .terminal_payload => ".payload-",
        .terminal => ".terminal-",
        .cleanup_intent => ".intent-",
        .cleanup => ".cleanup-",
    };
}

fn controlArtifactPathAlloc(
    allocator: std.mem.Allocator,
    claim_root: []const u8,
    registration_digest: []const u8,
    kind: ControlArtifactKind,
    fingerprint: []const u8,
) ![]u8 {
    try validateFingerprint(registration_digest);
    try validateFingerprint(fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}{s}{s}.json",
        .{ claim_root, registration_digest[7..], controlMarker(kind), fingerprint[7..] },
    );
}

fn findControlArtifactPathAlloc(
    allocator: std.mem.Allocator,
    claim_root: []const u8,
    registration_digest: []const u8,
    kind: ControlArtifactKind,
) !?[]u8 {
    try validateFingerprint(registration_digest);
    if (!pathExists(claim_root)) return null;
    const prefix = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ registration_digest[7..], controlMarker(kind) },
    );
    defer allocator.free(prefix);
    const root_stat = try std.Io.Dir.cwd().statFile(defaultIo(), claim_root, .{ .follow_symlinks = false });
    if (root_stat.kind == .sym_link) return error.SymlinkComponent;
    if (root_stat.kind != .directory) return error.NotDir;
    var dir = if (std.fs.path.isAbsolute(claim_root))
        try std.Io.Dir.openDirAbsolute(defaultIo(), claim_root, .{ .iterate = true, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(defaultIo(), claim_root, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(defaultIo());
    var matched: ?[]u8 = null;
    errdefer if (matched) |path| allocator.free(path);
    var iter = dir.iterate();
    while (try iter.next(defaultIo())) |entry| {
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (matched != null) return error.ControlArtifactConflict;
        const path = try std.fs.path.join(allocator, &.{ claim_root, entry.name });
        errdefer allocator.free(path);
        const stat = try std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) return error.NotFile;
        if (stat.size > MaxInputBytes) return error.FileTooBig;
        matched = path;
    }
    return matched;
}

fn findUniqueRegistrationDigestAlloc(
    allocator: std.mem.Allocator,
    claim_root: []const u8,
    kind: ?ControlArtifactKind,
) !?[]u8 {
    if (!pathExists(claim_root)) return null;
    const root_stat = try std.Io.Dir.cwd().statFile(defaultIo(), claim_root, .{ .follow_symlinks = false });
    if (root_stat.kind == .sym_link) return error.SymlinkComponent;
    if (root_stat.kind != .directory) return error.NotDir;
    var dir = if (std.fs.path.isAbsolute(claim_root))
        try std.Io.Dir.openDirAbsolute(defaultIo(), claim_root, .{ .iterate = true, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(defaultIo(), claim_root, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(defaultIo());
    var matched: ?[]u8 = null;
    errdefer if (matched) |digest| allocator.free(digest);
    var iter = dir.iterate();
    while (try iter.next(defaultIo())) |entry| {
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .file or entry.name.len < 64 + ".json".len) continue;
        const hex = entry.name[0..64];
        if (!isLowerHex(hex) or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (kind) |artifact_kind| {
            const marker = controlMarker(artifact_kind);
            if (entry.name.len <= 64 + marker.len + ".json".len or
                !std.mem.startsWith(u8, entry.name[64..], marker)) continue;
        } else if (entry.name.len != 64 + ".json".len) continue;
        if (matched != null) return error.ControlArtifactConflict;
        matched = try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
    }
    return matched;
}

fn controlArtifactFingerprintFromPathAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    kind: ControlArtifactKind,
) ![]u8 {
    const name = std.fs.path.basename(path);
    const marker = controlMarker(kind);
    const marker_index = std.mem.indexOf(u8, name, marker) orelse return error.ControlArtifactNameInvalid;
    if (!std.mem.endsWith(u8, name, ".json")) return error.ControlArtifactNameInvalid;
    const hex = name[marker_index + marker.len .. name.len - ".json".len];
    if (hex.len != 64 or !isLowerHex(hex)) return error.ControlArtifactNameInvalid;
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn hasAnyControlArtifactAlloc(
    allocator: std.mem.Allocator,
    claim_root: []const u8,
    registration_digest: []const u8,
    kind: ControlArtifactKind,
) !bool {
    const path = try findControlArtifactPathAlloc(allocator, claim_root, registration_digest, kind);
    defer if (path) |owned| allocator.free(owned);
    return path != null;
}

fn hasVerifiedClaimArtifactAlloc(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    registration_digest: []const u8,
) !bool {
    if (!pathExists(paths.claim)) return false;
    try validateFingerprint(registration_digest);
    const path = try claimPathAlloc(allocator, paths.claim, registration_digest);
    defer allocator.free(path);
    if (!try regularFileExistsNoFollow(path)) return false;
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
    defer allocator.free(bytes);
    const fingerprint = try attestation.digestBytesAlloc(allocator, bytes);
    defer allocator.free(fingerprint);
    try verifySealedControlArtifact(allocator, path, fingerprint);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const claim = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(claim, "schema"), "cas-trial-claim/v1") or
        !std.mem.eql(u8, try requiredString(claim, "trial_id"), std.fs.path.basename(std.fs.path.dirname(paths.claim) orelse "")) or
        !std.mem.eql(u8, try requiredString(claim, "lane_id"), std.fs.path.basename(paths.claim)) or
        !std.mem.eql(u8, try requiredString(claim, "registration_event_digest"), registration_digest))
    {
        return error.ControlArtifactInvalid;
    }
    return true;
}

const TerminalPayload = struct {
    registration_digest: []u8,
    payload_ref: []u8,
    payload_fingerprint: []u8,
    receipt: []u8,

    fn deinit(self: TerminalPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.registration_digest);
        allocator.free(self.payload_ref);
        allocator.free(self.payload_fingerprint);
        allocator.free(self.receipt);
    }
};

fn validateTerminalReceiptIdentity(
    allocator: std.mem.Allocator,
    receipt: []const u8,
    trial_id: []const u8,
    lane_id: []const u8,
    registration_digest: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(root, "schema"), "hylo-run-receipt/v1") or
        !std.mem.eql(u8, try requiredString(root, "trial_id"), trial_id) or
        !std.mem.eql(u8, try requiredString(root, "lane_id"), lane_id) or
        !std.mem.eql(
            u8,
            try requiredString(try requiredObject(root, "lineage"), "registration_event_digest"),
            registration_digest,
        ))
    {
        return error.TerminalPayloadInvalid;
    }
    try validateFingerprint(registration_digest);
}

fn persistTerminalPayload(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
    registration_digest: []const u8,
    receipt: []const u8,
) !void {
    try validateTerminalReceiptIdentity(allocator, receipt, trial_id, lane_id, registration_digest);
    const payload_fingerprint = try attestation.digestBytesAlloc(allocator, receipt);
    defer allocator.free(payload_fingerprint);
    const payload_path = try controlArtifactPathAlloc(
        allocator,
        paths.claim,
        registration_digest,
        .terminal_payload,
        payload_fingerprint,
    );
    defer allocator.free(payload_path);
    const persisted = try persistSealedControlArtifactAlloc(allocator, payload_path, receipt);
    defer allocator.free(persisted);
    if (!std.mem.eql(u8, persisted, payload_fingerprint)) return error.ControlArtifactFingerprintMismatch;
}

fn loadTerminalPayloadAlloc(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
    expected_registration_digest: []const u8,
) !TerminalPayload {
    try validateFingerprint(expected_registration_digest);
    const payload_path = (try findControlArtifactPathAlloc(
        allocator,
        paths.claim,
        expected_registration_digest,
        .terminal_payload,
    )) orelse return error.TerminalPayloadMissing;
    defer allocator.free(payload_path);
    const payload_fingerprint = try controlArtifactFingerprintFromPathAlloc(
        allocator,
        payload_path,
        .terminal_payload,
    );
    defer allocator.free(payload_fingerprint);
    try verifySealedControlArtifact(allocator, payload_path, payload_fingerprint);
    const receipt = try durable_store.readRegularFileNoSymlink(allocator, payload_path, MaxInputBytes);
    errdefer allocator.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const receipt_root = try object(parsed.value);
    const registration_digest = try requiredString(try requiredObject(receipt_root, "lineage"), "registration_event_digest");
    if (!std.mem.eql(u8, try requiredString(receipt_root, "schema"), "hylo-run-receipt/v1") or
        !std.mem.eql(u8, try requiredString(receipt_root, "trial_id"), trial_id) or
        !std.mem.eql(u8, try requiredString(receipt_root, "lane_id"), lane_id))
    {
        return error.TerminalPayloadInvalid;
    }
    try validateFingerprint(registration_digest);
    if (!std.mem.eql(u8, registration_digest, expected_registration_digest)) {
        return error.TerminalPayloadInvalid;
    }
    const expected_path = try controlArtifactPathAlloc(
        allocator,
        paths.claim,
        registration_digest,
        .terminal_payload,
        payload_fingerprint,
    );
    defer allocator.free(expected_path);
    if (!std.mem.eql(u8, expected_path, payload_path)) return error.TerminalPayloadInvalid;
    const owned_registration = try allocator.dupe(u8, registration_digest);
    errdefer allocator.free(owned_registration);
    const owned_payload_ref = try allocator.dupe(u8, payload_path);
    errdefer allocator.free(owned_payload_ref);
    const owned_payload_fingerprint = try allocator.dupe(u8, payload_fingerprint);
    errdefer allocator.free(owned_payload_fingerprint);
    return .{
        .registration_digest = owned_registration,
        .payload_ref = owned_payload_ref,
        .payload_fingerprint = owned_payload_fingerprint,
        .receipt = receipt,
    };
}

fn persistTerminalControl(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
    registration_digest: []const u8,
    terminal_payload: TerminalPayload,
) !void {
    if (!std.mem.eql(u8, terminal_payload.registration_digest, registration_digest)) {
        return error.TerminalPayloadInvalid;
    }
    const claim_path = try claimPathAlloc(allocator, paths.claim, registration_digest);
    defer allocator.free(claim_path);
    const claim_fingerprint = try sealExistingControlArtifactAlloc(allocator, claim_path);
    defer allocator.free(claim_fingerprint);
    const receipt_fingerprint = try sealExistingControlArtifactAlloc(allocator, paths.receipt);
    defer allocator.free(receipt_fingerprint);
    if (!std.mem.eql(u8, receipt_fingerprint, terminal_payload.payload_fingerprint)) {
        return error.TerminalPayloadInvalid;
    }
    const failure_stat = std.Io.Dir.cwd().statFile(defaultIo(), paths.failure_detail, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const failure_fingerprint: ?[]u8 = if (failure_stat) |stat| blk: {
        if (stat.kind != .file) return error.ControlArtifactInvalid;
        break :blk try sealExistingControlArtifactAlloc(allocator, paths.failure_detail);
    } else null;
    defer if (failure_fingerprint) |fingerprint| allocator.free(fingerprint);
    var evidence = try captureExecutionTreeAlloc(allocator, paths.evidence);
    defer evidence.deinit(allocator);
    if (evidence.root_mode & 0o777 != 0o500) return error.ControlArtifactNotSealed;
    const evidence_fingerprint = try evidence.fingerprintAlloc(allocator);
    defer allocator.free(evidence_fingerprint);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"schema\":\"cas-trial-terminal-control/v1\",");
    try writeStringMember(writer, "trial_id", trial_id, true);
    try writeStringMember(writer, "lane_id", lane_id, true);
    try writeStringMember(writer, "registration_event_digest", registration_digest, true);
    try writeStringMember(writer, "claim_ref", claim_path, true);
    try writeStringMember(writer, "claim_fingerprint", claim_fingerprint, true);
    try writeStringMember(writer, "receipt_ref", paths.receipt, true);
    try writeStringMember(writer, "receipt_fingerprint", receipt_fingerprint, true);
    try writeStringMember(writer, "terminal_payload_ref", terminal_payload.payload_ref, true);
    try writeStringMember(writer, "terminal_payload_fingerprint", terminal_payload.payload_fingerprint, true);
    try writeOptionalStringMember(writer, "failure_detail_ref", if (failure_fingerprint != null) paths.failure_detail else null, true);
    try writeOptionalStringMember(writer, "failure_detail_fingerprint", failure_fingerprint, true);
    try writeStringMember(writer, "evidence_ref", paths.evidence, true);
    try writeStringMember(writer, "evidence_tree_fingerprint", evidence_fingerprint, false);
    try writer.writeByte('}');
    const control_fingerprint = try attestation.digestBytesAlloc(allocator, out.written());
    defer allocator.free(control_fingerprint);
    const control_path = try controlArtifactPathAlloc(
        allocator,
        paths.claim,
        registration_digest,
        .terminal,
        control_fingerprint,
    );
    defer allocator.free(control_path);
    const persisted_fingerprint = try persistSealedControlArtifactAlloc(allocator, control_path, out.written());
    defer allocator.free(persisted_fingerprint);
    if (!std.mem.eql(u8, persisted_fingerprint, control_fingerprint)) return error.ControlArtifactFingerprintMismatch;
}

fn reconcileTerminalProjectionAlloc(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
    registration_digest: []const u8,
) !LaneControlVerification {
    const payload = try loadTerminalPayloadAlloc(
        allocator,
        paths,
        trial_id,
        lane_id,
        registration_digest,
    );
    defer payload.deinit(allocator);
    try persistTerminalReceipt(allocator, paths.receipt, payload.receipt);
    try persistTerminalControl(
        allocator,
        paths,
        trial_id,
        lane_id,
        payload.registration_digest,
        payload,
    );
    return verifyTerminalControlAlloc(allocator, paths, trial_id, lane_id);
}

fn regularFileExistsNoFollow(path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.ControlArtifactSymlinkForbidden;
    if (stat.kind != .file) return error.ControlArtifactInvalid;
    return true;
}

fn verifyTerminalControlAlloc(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    expected_trial_id: []const u8,
    expected_lane_id: []const u8,
) !LaneControlVerification {
    const receipt = try durable_store.readRegularFileNoSymlink(allocator, paths.receipt, MaxInputBytes);
    defer allocator.free(receipt);
    var receipt_parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer receipt_parsed.deinit();
    const receipt_root = try object(receipt_parsed.value);
    if (!std.mem.eql(u8, try requiredString(receipt_root, "trial_id"), expected_trial_id) or
        !std.mem.eql(u8, try requiredString(receipt_root, "lane_id"), expected_lane_id))
    {
        return error.ControlArtifactInvalid;
    }
    const registration_digest = try requiredString(try requiredObject(receipt_root, "lineage"), "registration_event_digest");
    try validateFingerprint(registration_digest);
    const terminal_payload = try loadTerminalPayloadAlloc(
        allocator,
        paths,
        expected_trial_id,
        expected_lane_id,
        registration_digest,
    );
    defer terminal_payload.deinit(allocator);
    if (!std.mem.eql(u8, terminal_payload.registration_digest, registration_digest) or
        !std.mem.eql(u8, terminal_payload.receipt, receipt))
    {
        return error.TerminalPayloadInvalid;
    }
    const control_path = (try findControlArtifactPathAlloc(
        allocator,
        paths.claim,
        registration_digest,
        .terminal,
    )) orelse return error.TerminalControlMissing;
    defer allocator.free(control_path);
    const control_fingerprint = try controlArtifactFingerprintFromPathAlloc(allocator, control_path, .terminal);
    errdefer allocator.free(control_fingerprint);
    try verifySealedControlArtifact(allocator, control_path, control_fingerprint);
    const control_bytes = try durable_store.readRegularFileNoSymlink(allocator, control_path, MaxInputBytes);
    defer allocator.free(control_bytes);
    var control_parsed = try std.json.parseFromSlice(std.json.Value, allocator, control_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer control_parsed.deinit();
    const control = try object(control_parsed.value);
    if (!std.mem.eql(u8, try requiredString(control, "schema"), "cas-trial-terminal-control/v1") or
        !std.mem.eql(u8, try requiredString(control, "trial_id"), expected_trial_id) or
        !std.mem.eql(u8, try requiredString(control, "lane_id"), expected_lane_id) or
        !std.mem.eql(u8, try requiredString(control, "registration_event_digest"), registration_digest) or
        !std.mem.eql(u8, try requiredString(control, "receipt_ref"), paths.receipt) or
        !std.mem.eql(u8, try requiredString(control, "terminal_payload_ref"), terminal_payload.payload_ref) or
        !std.mem.eql(u8, try requiredString(control, "terminal_payload_fingerprint"), terminal_payload.payload_fingerprint) or
        !std.mem.eql(u8, try requiredString(control, "evidence_ref"), paths.evidence))
    {
        return error.ControlArtifactInvalid;
    }
    const claim_path = try claimPathAlloc(allocator, paths.claim, registration_digest);
    defer allocator.free(claim_path);
    if (!std.mem.eql(u8, try requiredString(control, "claim_ref"), claim_path)) {
        return error.ControlArtifactInvalid;
    }
    try verifySealedControlArtifact(allocator, claim_path, try requiredString(control, "claim_fingerprint"));
    try verifySealedControlArtifact(allocator, paths.receipt, try requiredString(control, "receipt_fingerprint"));

    const failure_ref = optionalString(control, "failure_detail_ref");
    const failure_fingerprint = optionalString(control, "failure_detail_fingerprint");
    if ((failure_ref == null) != (failure_fingerprint == null)) return error.ControlArtifactInvalid;
    if (failure_ref) |ref| {
        if (!std.mem.eql(u8, ref, paths.failure_detail)) return error.ControlArtifactInvalid;
        try verifySealedControlArtifact(allocator, ref, failure_fingerprint.?);
    } else if (try regularFileExistsNoFollow(paths.failure_detail)) return error.ControlArtifactInvalid;

    var evidence = captureExecutionTreeAlloc(allocator, paths.evidence) catch
        return error.ControlArtifactInvalid;
    defer evidence.deinit(allocator);
    if (evidence.root_mode & 0o777 != 0o500) return error.ControlArtifactNotSealed;
    const evidence_fingerprint = try evidence.fingerprintAlloc(allocator);
    defer allocator.free(evidence_fingerprint);
    if (!std.mem.eql(u8, evidence_fingerprint, try requiredString(control, "evidence_tree_fingerprint"))) {
        return error.ControlArtifactFingerprintMismatch;
    }
    return .{
        .registration_digest = try allocator.dupe(u8, registration_digest),
        .terminal_control_fingerprint = control_fingerprint,
    };
}

const CleanupIntent = struct {
    intent_ref: []u8,
    intent_fingerprint: []u8,
    cleanup: []u8,
    cleanup_fingerprint: []u8,

    fn deinit(self: CleanupIntent, allocator: std.mem.Allocator) void {
        allocator.free(self.intent_ref);
        allocator.free(self.intent_fingerprint);
        allocator.free(self.cleanup);
        allocator.free(self.cleanup_fingerprint);
    }
};

fn buildCleanupReceiptAlloc(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-trial-cleanup-receipt/v1\",\"trial_id\":{f},\"lane_id\":{f},\"workspace_removed\":true,\"claim_preserved\":true,\"terminal_receipt_preserved\":true,\"evidence_preserved\":true,\"evidence_ref\":{f}}}\n",
        .{ std.json.fmt(trial_id, .{}), std.json.fmt(lane_id, .{}), std.json.fmt(paths.evidence, .{}) },
    );
}

fn persistCleanupIntent(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
    terminal: LaneControlVerification,
    cleanup: []const u8,
) !void {
    const cleanup_fingerprint = try attestation.digestBytesAlloc(allocator, cleanup);
    defer allocator.free(cleanup_fingerprint);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try writeStringMember(writer, "schema", "cas-trial-cleanup-intent/v1", true);
    try writeStringMember(writer, "trial_id", trial_id, true);
    try writeStringMember(writer, "lane_id", lane_id, true);
    try writeStringMember(writer, "registration_event_digest", terminal.registration_digest, true);
    try writeStringMember(writer, "terminal_control_fingerprint", terminal.terminal_control_fingerprint, true);
    try writeStringMember(writer, "workspace_ref", paths.workspace, true);
    try writeStringMember(writer, "evidence_ref", paths.evidence, true);
    try writeStringMember(writer, "cleanup_ref", paths.cleanup_receipt, true);
    try writeStringMember(writer, "cleanup_fingerprint", cleanup_fingerprint, true);
    try writeStringMember(writer, "cleanup_bytes", cleanup, false);
    try writer.writeByte('}');
    const intent_fingerprint = try attestation.digestBytesAlloc(allocator, out.written());
    defer allocator.free(intent_fingerprint);
    const intent_path = try controlArtifactPathAlloc(
        allocator,
        paths.claim,
        terminal.registration_digest,
        .cleanup_intent,
        intent_fingerprint,
    );
    defer allocator.free(intent_path);
    const persisted = try persistSealedControlArtifactAlloc(allocator, intent_path, out.written());
    defer allocator.free(persisted);
    if (!std.mem.eql(u8, persisted, intent_fingerprint)) return error.ControlArtifactFingerprintMismatch;
}

fn loadCleanupIntentAlloc(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
    terminal: LaneControlVerification,
) !CleanupIntent {
    const intent_path = (try findControlArtifactPathAlloc(
        allocator,
        paths.claim,
        terminal.registration_digest,
        .cleanup_intent,
    )) orelse return error.CleanupIntentMissing;
    defer allocator.free(intent_path);
    const intent_fingerprint = try controlArtifactFingerprintFromPathAlloc(
        allocator,
        intent_path,
        .cleanup_intent,
    );
    defer allocator.free(intent_fingerprint);
    try verifySealedControlArtifact(allocator, intent_path, intent_fingerprint);
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, intent_path, MaxInputBytes);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const intent = try object(parsed.value);
    const cleanup = try requiredString(intent, "cleanup_bytes");
    const cleanup_fingerprint = try requiredString(intent, "cleanup_fingerprint");
    if (!std.mem.eql(u8, try requiredString(intent, "schema"), "cas-trial-cleanup-intent/v1") or
        !std.mem.eql(u8, try requiredString(intent, "trial_id"), trial_id) or
        !std.mem.eql(u8, try requiredString(intent, "lane_id"), lane_id) or
        !std.mem.eql(u8, try requiredString(intent, "registration_event_digest"), terminal.registration_digest) or
        !std.mem.eql(u8, try requiredString(intent, "terminal_control_fingerprint"), terminal.terminal_control_fingerprint) or
        !std.mem.eql(u8, try requiredString(intent, "workspace_ref"), paths.workspace) or
        !std.mem.eql(u8, try requiredString(intent, "evidence_ref"), paths.evidence) or
        !std.mem.eql(u8, try requiredString(intent, "cleanup_ref"), paths.cleanup_receipt))
    {
        return error.CleanupIntentInvalid;
    }
    try validateFingerprint(cleanup_fingerprint);
    try requireBytesFingerprint(allocator, cleanup, cleanup_fingerprint);
    const expected_path = try controlArtifactPathAlloc(
        allocator,
        paths.claim,
        terminal.registration_digest,
        .cleanup_intent,
        intent_fingerprint,
    );
    defer allocator.free(expected_path);
    if (!std.mem.eql(u8, expected_path, intent_path)) return error.CleanupIntentInvalid;
    const owned_intent_ref = try allocator.dupe(u8, intent_path);
    errdefer allocator.free(owned_intent_ref);
    const owned_intent_fingerprint = try allocator.dupe(u8, intent_fingerprint);
    errdefer allocator.free(owned_intent_fingerprint);
    const owned_cleanup = try allocator.dupe(u8, cleanup);
    errdefer allocator.free(owned_cleanup);
    const owned_cleanup_fingerprint = try allocator.dupe(u8, cleanup_fingerprint);
    return .{
        .intent_ref = owned_intent_ref,
        .intent_fingerprint = owned_intent_fingerprint,
        .cleanup = owned_cleanup,
        .cleanup_fingerprint = owned_cleanup_fingerprint,
    };
}

fn persistCleanupControl(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
    terminal: LaneControlVerification,
    intent: CleanupIntent,
) !void {
    const cleanup_fingerprint = try sealExistingControlArtifactAlloc(allocator, paths.cleanup_receipt);
    defer allocator.free(cleanup_fingerprint);
    if (!std.mem.eql(u8, cleanup_fingerprint, intent.cleanup_fingerprint)) {
        return error.CleanupArtifactConflict;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"schema\":\"cas-trial-cleanup-control/v1\",");
    try writeStringMember(writer, "trial_id", trial_id, true);
    try writeStringMember(writer, "lane_id", lane_id, true);
    try writeStringMember(writer, "registration_event_digest", terminal.registration_digest, true);
    try writeStringMember(writer, "terminal_control_fingerprint", terminal.terminal_control_fingerprint, true);
    try writeStringMember(writer, "cleanup_intent_ref", intent.intent_ref, true);
    try writeStringMember(writer, "cleanup_intent_fingerprint", intent.intent_fingerprint, true);
    try writeStringMember(writer, "cleanup_ref", paths.cleanup_receipt, true);
    try writeStringMember(writer, "cleanup_fingerprint", cleanup_fingerprint, false);
    try writer.writeByte('}');
    const control_fingerprint = try attestation.digestBytesAlloc(allocator, out.written());
    defer allocator.free(control_fingerprint);
    const control_path = try controlArtifactPathAlloc(
        allocator,
        paths.claim,
        terminal.registration_digest,
        .cleanup,
        control_fingerprint,
    );
    defer allocator.free(control_path);
    const persisted_fingerprint = try persistSealedControlArtifactAlloc(allocator, control_path, out.written());
    defer allocator.free(persisted_fingerprint);
    if (!std.mem.eql(u8, persisted_fingerprint, control_fingerprint)) return error.ControlArtifactFingerprintMismatch;
}

fn verifyCleanupControlIfPresent(
    allocator: std.mem.Allocator,
    paths: LanePaths,
    trial_id: []const u8,
    lane_id: []const u8,
    terminal: LaneControlVerification,
) !bool {
    const cleanup_exists = try regularFileExistsNoFollow(paths.cleanup_receipt);
    const control_path = try findControlArtifactPathAlloc(
        allocator,
        paths.claim,
        terminal.registration_digest,
        .cleanup,
    );
    defer if (control_path) |path| allocator.free(path);
    if (control_path == null) return false;
    if (!cleanup_exists) return error.CleanupControlMismatch;
    const intent = try loadCleanupIntentAlloc(allocator, paths, trial_id, lane_id, terminal);
    defer intent.deinit(allocator);
    const control_fingerprint = try controlArtifactFingerprintFromPathAlloc(allocator, control_path.?, .cleanup);
    defer allocator.free(control_fingerprint);
    try verifySealedControlArtifact(allocator, control_path.?, control_fingerprint);
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, control_path.?, MaxInputBytes);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const control = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(control, "schema"), "cas-trial-cleanup-control/v1") or
        !std.mem.eql(u8, try requiredString(control, "trial_id"), trial_id) or
        !std.mem.eql(u8, try requiredString(control, "lane_id"), lane_id) or
        !std.mem.eql(u8, try requiredString(control, "registration_event_digest"), terminal.registration_digest) or
        !std.mem.eql(u8, try requiredString(control, "terminal_control_fingerprint"), terminal.terminal_control_fingerprint) or
        !std.mem.eql(u8, try requiredString(control, "cleanup_intent_ref"), intent.intent_ref) or
        !std.mem.eql(u8, try requiredString(control, "cleanup_intent_fingerprint"), intent.intent_fingerprint) or
        !std.mem.eql(u8, try requiredString(control, "cleanup_ref"), paths.cleanup_receipt))
    {
        return error.CleanupControlMismatch;
    }
    try verifySealedControlArtifact(allocator, paths.cleanup_receipt, try requiredString(control, "cleanup_fingerprint"));
    const cleanup_bytes = try durable_store.readRegularFileNoSymlink(allocator, paths.cleanup_receipt, MaxInputBytes);
    defer allocator.free(cleanup_bytes);
    if (!std.mem.eql(u8, cleanup_bytes, intent.cleanup)) return error.CleanupArtifactConflict;
    return true;
}

fn selectedRegistrationDigestAlloc(
    allocator: std.mem.Allocator,
    claim_root: []const u8,
    provided: ?[]const u8,
    kind: ?ControlArtifactKind,
) !?[]u8 {
    if (provided) |registration_digest| {
        try validateFingerprint(registration_digest);
        return try allocator.dupe(u8, registration_digest);
    }
    return findUniqueRegistrationDigestAlloc(allocator, claim_root, kind);
}

fn terminalReceiptRegistrationDigestAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_trial_id: []const u8,
    expected_lane_id: []const u8,
) ![]u8 {
    const receipt = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
    defer allocator.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(root, "schema"), "hylo-run-receipt/v1") or
        !std.mem.eql(u8, try requiredString(root, "trial_id"), expected_trial_id) or
        !std.mem.eql(u8, try requiredString(root, "lane_id"), expected_lane_id))
    {
        return error.TerminalPayloadInvalid;
    }
    const registration_digest = try requiredString(
        try requiredObject(root, "lineage"),
        "registration_event_digest",
    );
    try validateFingerprint(registration_digest);
    return allocator.dupe(u8, registration_digest);
}

fn cmdStatus(allocator: std.mem.Allocator, options: Options) !void {
    const trial_id = options.trial_id orelse return error.MissingTrialId;
    const lane_id = options.lane_id orelse return error.MissingLaneId;
    const receipt_dir = options.receipt_dir orelse return error.MissingReceiptDir;
    const paths = try lanePathsAlloc(allocator, receipt_dir, options.claim_store_override, trial_id, lane_id);
    defer paths.deinit(allocator);
    const receipt_exists = try regularFileExistsNoFollow(paths.receipt);
    if (receipt_exists) {
        const terminal = verifyTerminalControlAlloc(allocator, paths, trial_id, lane_id) catch |err| switch (err) {
            error.TerminalControlMissing => {
                try printJson(.{
                    .schema = "cas-trial-status/v1",
                    .trial_id = trial_id,
                    .lane_id = lane_id,
                    .state = "terminalizing",
                    .integrity = "recoverable",
                    .claim_ref = paths.claim,
                    .receipt_ref = paths.receipt,
                });
                return;
            },
            else => return err,
        };
        defer terminal.deinit(allocator);
        _ = try verifyCleanupControlIfPresent(allocator, paths, trial_id, lane_id, terminal);
        try printJson(.{
            .schema = "cas-trial-status/v1",
            .trial_id = trial_id,
            .lane_id = lane_id,
            .state = "terminal",
            .integrity = "verified",
            .claim_ref = paths.claim,
            .receipt_ref = paths.receipt,
            .terminal_control_fingerprint = terminal.terminal_control_fingerprint,
        });
        return;
    }
    var registration_digest = try selectedRegistrationDigestAlloc(
        allocator,
        paths.claim,
        options.registration_event_digest,
        .terminal_payload,
    );
    if (registration_digest == null and options.registration_event_digest == null) {
        registration_digest = try selectedRegistrationDigestAlloc(allocator, paths.claim, null, null);
    }
    defer if (registration_digest) |digest| allocator.free(digest);
    if (registration_digest) |digest| {
        if (try hasAnyControlArtifactAlloc(allocator, paths.claim, digest, .terminal_payload)) {
            const payload = try loadTerminalPayloadAlloc(allocator, paths, trial_id, lane_id, digest);
            payload.deinit(allocator);
            try printJson(.{
                .schema = "cas-trial-status/v1",
                .trial_id = trial_id,
                .lane_id = lane_id,
                .state = "terminalizing",
                .integrity = "recoverable",
                .claim_ref = paths.claim,
                .receipt_ref = null,
            });
            return;
        }
        if (try hasAnyControlArtifactAlloc(allocator, paths.claim, digest, .terminal)) {
            return error.TerminalReceiptMissing;
        }
    }
    const claimed = if (registration_digest) |digest|
        try hasVerifiedClaimArtifactAlloc(allocator, paths, digest)
    else
        false;
    try printJson(.{
        .schema = "cas-trial-status/v1",
        .trial_id = trial_id,
        .lane_id = lane_id,
        .state = if (claimed) "claimed" else "unclaimed",
        .integrity = if (claimed) "verified" else "not_applicable",
        .claim_ref = if (claimed) paths.claim else null,
        .receipt_ref = null,
    });
}

fn cmdCleanup(allocator: std.mem.Allocator, options: Options) !void {
    const trial_id = options.trial_id orelse return error.MissingTrialId;
    const lane_id = options.lane_id orelse return error.MissingLaneId;
    const receipt_dir = options.receipt_dir orelse return error.MissingReceiptDir;
    const paths = try lanePathsAlloc(allocator, receipt_dir, options.claim_store_override, trial_id, lane_id);
    defer paths.deinit(allocator);
    const receipt_exists = try regularFileExistsNoFollow(paths.receipt);
    const terminal = if (receipt_exists) blk: {
        const registration_digest = try terminalReceiptRegistrationDigestAlloc(
            allocator,
            paths.receipt,
            trial_id,
            lane_id,
        );
        defer allocator.free(registration_digest);
        break :blk verifyTerminalControlAlloc(allocator, paths, trial_id, lane_id) catch |err| switch (err) {
            error.TerminalControlMissing => try reconcileTerminalProjectionAlloc(
                allocator,
                paths,
                trial_id,
                lane_id,
                registration_digest,
            ),
            else => return err,
        };
    } else blk: {
        const registration_digest = (try selectedRegistrationDigestAlloc(
            allocator,
            paths.claim,
            options.registration_event_digest,
            .terminal_payload,
        )) orelse return error.CleanupBeforeTerminal;
        defer allocator.free(registration_digest);
        if (!try hasAnyControlArtifactAlloc(
            allocator,
            paths.claim,
            registration_digest,
            .terminal_payload,
        )) return error.CleanupBeforeTerminal;
        break :blk try reconcileTerminalProjectionAlloc(
            allocator,
            paths,
            trial_id,
            lane_id,
            registration_digest,
        );
    };
    defer terminal.deinit(allocator);
    if (try verifyCleanupControlIfPresent(allocator, paths, trial_id, lane_id, terminal)) {
        if (pathExists(paths.workspace)) return error.CleanupStateUnverified;
        if (!builtin.is_test) {
            const cleanup_fingerprint = try fileFingerprintAlloc(allocator, paths.cleanup_receipt);
            defer allocator.free(cleanup_fingerprint);
            try printJson(.{
                .schema = "cas-trial-cleanup-receipt/v1",
                .trial_id = trial_id,
                .lane_id = lane_id,
                .workspace_removed = true,
                .claim_preserved = true,
                .receipt_preserved = true,
                .evidence_preserved = true,
                .cleanup_ref = paths.cleanup_receipt,
                .cleanup_fingerprint = cleanup_fingerprint,
                .integrity = "verified",
            });
        }
        return;
    }
    if (!pathExists(paths.evidence) or !pathExists(paths.presented_input_archive)) return error.CleanupEvidenceMissing;
    const cleanup = try buildCleanupReceiptAlloc(allocator, paths, trial_id, lane_id);
    defer allocator.free(cleanup);
    const intent_path = try findControlArtifactPathAlloc(
        allocator,
        paths.claim,
        terminal.registration_digest,
        .cleanup_intent,
    );
    const intent_exists = intent_path != null;
    if (intent_path) |path| allocator.free(path);
    if (!intent_exists) {
        if (try regularFileExistsNoFollow(paths.cleanup_receipt)) return error.CleanupControlMismatch;
        if (!pathExists(paths.workspace)) return error.CleanupStateUnverified;
        try persistCleanupIntent(allocator, paths, trial_id, lane_id, terminal, cleanup);
    }
    const intent = try loadCleanupIntentAlloc(allocator, paths, trial_id, lane_id, terminal);
    defer intent.deinit(allocator);
    if (!std.mem.eql(u8, intent.cleanup, cleanup)) return error.CleanupArtifactConflict;
    if (pathExists(paths.workspace)) try deleteTree(paths.workspace);
    if (pathExists(paths.workspace)) return error.CleanupStateUnverified;
    const cleanup_fingerprint = persistExpectedSealedArtifactAlloc(
        allocator,
        paths.cleanup_receipt,
        cleanup,
    ) catch |err| switch (err) {
        error.PersistedArtifactConflict => return error.CleanupArtifactConflict,
        else => return err,
    };
    defer allocator.free(cleanup_fingerprint);
    try persistCleanupControl(allocator, paths, trial_id, lane_id, terminal, intent);
    if (!try verifyCleanupControlIfPresent(allocator, paths, trial_id, lane_id, terminal)) {
        return error.CleanupControlMismatch;
    }
    if (!builtin.is_test) {
        try printJson(.{
            .schema = "cas-trial-cleanup-receipt/v1",
            .trial_id = trial_id,
            .lane_id = lane_id,
            .workspace_removed = !pathExists(paths.workspace),
            .claim_preserved = pathExists(paths.claim),
            .receipt_preserved = pathExists(paths.receipt),
            .evidence_preserved = pathExists(paths.evidence),
            .cleanup_ref = paths.cleanup_receipt,
            .cleanup_fingerprint = cleanup_fingerprint,
            .integrity = "verified",
        });
    }
}

fn cmdKeyInfo(allocator: std.mem.Allocator, options: Options) !void {
    var seed = try readSigningSeed(options.signing_seed_fd orelse return error.MissingSigningSeedFd);
    defer std.crypto.secureZero(u8, &seed);
    const public_key = try attestation.publicKeyBase64Alloc(allocator, seed);
    defer allocator.free(public_key);
    try printJson(.{
        .schema = "hylo-trust-key-info/v1",
        .key_id = options.producer_key_id,
        .algorithm = "ed25519",
        .public_key_base64 = public_key,
    });
}

const LoadedLane = struct {
    parsed: std.json.Parsed(std.json.Value),
    view: LaneView,
};

const EffectiveSourceProfile = struct {
    value: std.json.Value,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn deinit(self: *EffectiveSourceProfile) void {
        if (self.parsed) |*parsed| parsed.deinit();
        self.* = undefined;
    }
};

fn effectiveSourceProfile(
    allocator: std.mem.Allocator,
    projected_value: std.json.Value,
    source_profile_fd: ?std.posix.fd_t,
) !EffectiveSourceProfile {
    if (source_profile_fd) |fd| _ = try sensitiveInputEndpoint(fd);
    const projected = try object(projected_value);
    const kind = try requiredString(projected, "kind");
    if (std.mem.eql(u8, kind, "direct")) {
        if (source_profile_fd) |fd| {
            const raw = try readOwnedFdRawAlloc(allocator, fd, MaxInputBytes);
            defer allocator.free(raw);
            if (std.mem.trim(u8, raw, " \t\r\n").len != 0) return error.SourceProfileFdForbidden;
        }
        return .{ .value = projected_value };
    }
    if (!std.mem.eql(u8, kind, "historical_decision")) return error.SourceProfileInvalid;
    const policy = try requiredString(projected, "source_target_text_policy");
    const sealed_payload = optionalBool(projected, "sealed_payload") orelse false;
    if (projected.get("profile_body_delivery")) |delivery| {
        if (!std.mem.eql(u8, try requiredString(projected, "profile_body_delivery"), "source_profile_fd")) {
            return error.SourceProfileInvalid;
        }
        _ = delivery;
    }
    if (source_profile_fd == null) {
        if (sealed_payload or std.mem.eql(u8, policy, "strip_and_replace")) {
            return error.SourceProfileFdRequired;
        }
        return .{ .value = projected_value };
    }

    const raw = try readOwnedFdRawAlloc(allocator, source_profile_fd.?, MaxInputBytes);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    const supplied = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(supplied, "kind"), "historical_decision") or
        !std.mem.eql(u8, try requiredString(supplied, "source_target_text_policy"), policy))
    {
        return error.SourceProfileInvalid;
    }
    const observed_profile_fingerprint = try attestation.digestValueAlloc(allocator, parsed.value);
    defer allocator.free(observed_profile_fingerprint);
    if (!std.mem.eql(
        u8,
        observed_profile_fingerprint,
        try requiredString(projected, "source_profile_fingerprint"),
    )) return error.SourceProfileFingerprintMismatch;
    inline for (.{
        "source_governance_fingerprint",
        "decision_context_fingerprint",
        "temporal_horizon",
        "source_target_text_policy",
        "retrace_mode",
        "required_lineage",
        "required_fir_version",
        "reconstructability",
    }) |key| {
        if (!std.mem.eql(u8, try requiredString(projected, key), try requiredString(supplied, key))) {
            return error.SourceProfileFingerprintMismatch;
        }
    }
    inline for (.{"limitations"}) |key| {
        const projected_json = try canonicalFieldAlloc(
            allocator,
            projected.get(key) orelse return error.SourceProfileInvalid,
        );
        defer allocator.free(projected_json);
        const supplied_json = try canonicalFieldAlloc(
            allocator,
            supplied.get(key) orelse return error.SourceProfileInvalid,
        );
        defer allocator.free(supplied_json);
        if (!std.mem.eql(u8, projected_json, supplied_json)) return error.SourceProfileFingerprintMismatch;
    }
    const supplied_witness = supplied.get("source_target_text_witness") orelse
        return error.SourceProfileInvalid;
    const supplied_witness_fingerprint = try attestation.digestValueAlloc(allocator, supplied_witness);
    defer allocator.free(supplied_witness_fingerprint);
    if (projected.get("source_target_text_witness_fingerprint")) |commitment_value| {
        if (projected.get("source_target_text_witness") != null) return error.SourceProfileInvalid;
        const commitment = try string(commitment_value);
        try validateFingerprint(commitment);
        if (!std.mem.eql(u8, supplied_witness_fingerprint, commitment)) {
            return error.SourceProfileFingerprintMismatch;
        }
    } else {
        if (sealed_payload) return error.SourceProfileInvalid;
        const projected_witness = projected.get("source_target_text_witness") orelse
            return error.SourceProfileInvalid;
        const projected_witness_fingerprint = try attestation.digestValueAlloc(allocator, projected_witness);
        defer allocator.free(projected_witness_fingerprint);
        if (!std.mem.eql(u8, supplied_witness_fingerprint, projected_witness_fingerprint)) {
            return error.SourceProfileFingerprintMismatch;
        }
    }
    if (std.mem.eql(u8, policy, "strip_and_replace")) {
        try validateSanitizedHistoricalProfile(allocator, supplied);
    }
    return .{ .value = parsed.value, .parsed = parsed };
}

fn validateSanitizedHistoricalProfile(allocator: std.mem.Allocator, profile: std.json.ObjectMap) !void {
    const context_value = profile.get("decision_context") orelse return error.DecisionContextMissing;
    const context_fingerprint = try attestation.digestValueAlloc(allocator, context_value);
    defer allocator.free(context_fingerprint);
    if (!std.mem.eql(
        u8,
        context_fingerprint,
        try requiredString(profile, "decision_context_fingerprint"),
    )) return error.DecisionContextFingerprintMismatch;
    const witness = try requiredObject(profile, "source_target_text_witness");
    const sanitization = try requiredObject(witness, "sanitization");
    if (!try requiredBool(sanitization, "applied") or
        !std.mem.eql(
            u8,
            context_fingerprint,
            try requiredString(sanitization, "sanitized_context_fingerprint"),
        ))
    {
        return error.SourceTargetTextSanitizationInvalid;
    }
    const context_root = try object(context_value);
    const packet = if (context_root.get("decision_context_packet")) |wrapped|
        try object(wrapped)
    else
        context_root;
    const contamination = try requiredObject(packet, "contamination");
    inline for (.{ "injected_skill_blocks", "generated_reports", "current_audit_prompt", "quoted_material" }) |key| {
        if (try requiredBool(contamination, key)) return error.SourceTargetTextContamination;
    }
}

fn loadLane(allocator: std.mem.Allocator, trial_path: []const u8, lane_id: []const u8) !LoadedLane {
    const raw = try readFileAlloc(allocator, trial_path, MaxInputBytes);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    const trial = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(trial, "schema"), "hylo-trial/v1")) return error.TrialSchemaInvalid;
    const trial_id = try requiredString(trial, "trial_id");
    const purpose = try requiredString(trial, "purpose");
    const units = try requiredArray(trial, "units");
    var selected_unit: ?std.json.ObjectMap = null;
    var selected_pair: ?std.json.ObjectMap = null;
    var selected_arm: ?[]const u8 = null;
    for (units.items) |unit_value| {
        const unit = try object(unit_value);
        const pairs = try requiredArray(unit, "pairs");
        for (pairs.items) |pair_value| {
            const pair = try object(pair_value);
            const lanes = try requiredObject(pair, "lanes");
            var iterator = lanes.iterator();
            while (iterator.next()) |entry| {
                const lane = try object(entry.value_ptr.*);
                if (std.mem.eql(u8, try requiredString(lane, "lane_id"), lane_id)) {
                    if (selected_unit != null) return error.DuplicateLane;
                    selected_unit = unit;
                    selected_pair = pair;
                    selected_arm = entry.key_ptr.*;
                }
            }
        }
    }
    const unit = selected_unit orelse return error.LaneNotRegistered;
    const pair = selected_pair.?;
    const arm_id = selected_arm.?;
    const arms = try requiredArray(trial, "arms");
    var arm: ?std.json.ObjectMap = null;
    for (arms.items) |arm_value| {
        const candidate = try object(arm_value);
        if (std.mem.eql(u8, try requiredString(candidate, "arm_id"), arm_id)) arm = candidate;
    }
    return .{
        .parsed = parsed,
        .view = .{
            .trial = trial,
            .trial_id = trial_id,
            .purpose = purpose,
            .unit_id = try requiredString(unit, "unit_id"),
            .scenario_id = try requiredString(unit, "scenario_id"),
            .pair_id = try requiredString(pair, "pair_id"),
            .pair = pair,
            .lane_id = lane_id,
            .arm_id = arm_id,
            .arm = arm orelse return error.ArmMissing,
            .source_profile = unit.get("source_profile") orelse return error.SourceProfileMissing,
            .execution = try requiredObject(trial, "execution"),
        },
    };
}

fn replayPromptAlloc(allocator: std.mem.Allocator, view: LaneView) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Execute exactly one HCTP replay lane `{s}`. Use only the pre-decision context and the one opaque target package materialized for this lane. Do not compare arms, retry, fork a portfolio, or use later outcomes.",
        .{view.lane_id},
    );
}

const LanePaths = struct {
    root: []u8,
    claim: []u8,
    request: []u8,
    executor_output_root: []u8,
    executor_result: []u8,
    executor_stdout: []u8,
    executor_stderr: []u8,
    workspace: []u8,
    execution_root: []u8,
    decision_context: []u8,
    receipt: []u8,
    failure_detail: []u8,
    evidence: []u8,
    native_receipt: []u8,
    reset_observation: []u8,
    filesystem_observation: []u8,
    network_observation: []u8,
    external_effect_observation: []u8,
    failure_native_receipt: []u8,
    failure_execution_audit: []u8,
    failure_reset_observation: []u8,
    failure_filesystem_observation: []u8,
    failure_network_observation: []u8,
    failure_external_effect_observation: []u8,
    presented_input_archive: []u8,
    decision_context_archive: []u8,
    factor_materialization_workspace: []u8,
    factor_materialization_archive: []u8,
    target_materialization_workspace: []u8,
    target_materialization_archive: []u8,
    target_package_root: []u8,
    cleanup_receipt: []u8,

    fn deinit(self: LanePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.claim);
        allocator.free(self.request);
        allocator.free(self.executor_output_root);
        allocator.free(self.executor_result);
        allocator.free(self.executor_stdout);
        allocator.free(self.executor_stderr);
        allocator.free(self.workspace);
        allocator.free(self.execution_root);
        allocator.free(self.decision_context);
        allocator.free(self.receipt);
        allocator.free(self.failure_detail);
        allocator.free(self.evidence);
        allocator.free(self.native_receipt);
        allocator.free(self.reset_observation);
        allocator.free(self.filesystem_observation);
        allocator.free(self.network_observation);
        allocator.free(self.external_effect_observation);
        allocator.free(self.failure_native_receipt);
        allocator.free(self.failure_execution_audit);
        allocator.free(self.failure_reset_observation);
        allocator.free(self.failure_filesystem_observation);
        allocator.free(self.failure_network_observation);
        allocator.free(self.failure_external_effect_observation);
        allocator.free(self.presented_input_archive);
        allocator.free(self.decision_context_archive);
        allocator.free(self.factor_materialization_workspace);
        allocator.free(self.factor_materialization_archive);
        allocator.free(self.target_materialization_workspace);
        allocator.free(self.target_materialization_archive);
        allocator.free(self.target_package_root);
        allocator.free(self.cleanup_receipt);
    }
};

fn lanePathsAlloc(
    allocator: std.mem.Allocator,
    receipt_dir: []const u8,
    claim_store_override: ?[]const u8,
    trial_id: []const u8,
    lane_id: []const u8,
) !LanePaths {
    try validatePathComponent(trial_id);
    try validatePathComponent(lane_id);
    const resolved_receipt_dir = try std.fs.path.resolve(allocator, &.{receipt_dir});
    defer allocator.free(resolved_receipt_dir);
    const claim_store = if (claim_store_override) |override|
        try std.fs.path.resolve(allocator, &.{override})
    else
        try authoritativeClaimStoreAlloc(allocator);
    defer allocator.free(claim_store);
    const workspace_store = if (claim_store_override) |override|
        try std.fs.path.resolve(allocator, &.{ override, ".workspaces" })
    else
        try authoritativeWorkspaceStoreAlloc(allocator);
    defer allocator.free(workspace_store);
    const receipt_store_fingerprint = try attestation.digestBytesAlloc(allocator, resolved_receipt_dir);
    defer allocator.free(receipt_store_fingerprint);
    const root = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ resolved_receipt_dir, trial_id, lane_id });
    errdefer allocator.free(root);
    const claim_root = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ claim_store, trial_id, lane_id });
    defer allocator.free(claim_root);
    const workspace = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/{s}",
        .{ workspace_store, receipt_store_fingerprint[7..], trial_id, lane_id },
    );
    errdefer allocator.free(workspace);
    return .{
        .root = root,
        .claim = try allocator.dupe(u8, claim_root),
        .request = try std.fmt.allocPrint(allocator, "{s}/request.json", .{workspace}),
        .executor_output_root = try std.fmt.allocPrint(allocator, "{s}/executor-output", .{workspace}),
        .executor_result = try std.fmt.allocPrint(allocator, "{s}/executor-output/result.json", .{workspace}),
        .executor_stdout = try std.fmt.allocPrint(allocator, "{s}/executor-output/result.json.stdout", .{workspace}),
        .executor_stderr = try std.fmt.allocPrint(allocator, "{s}/executor-output/result.json.stderr", .{workspace}),
        .workspace = workspace,
        .execution_root = try std.fmt.allocPrint(allocator, "{s}/common-projection", .{workspace}),
        .decision_context = try std.fmt.allocPrint(allocator, "{s}/decision-context.json", .{workspace}),
        .receipt = try std.fmt.allocPrint(allocator, "{s}/run-receipt.json", .{root}),
        .failure_detail = try std.fmt.allocPrint(allocator, "{s}/failure-detail.json", .{root}),
        .evidence = try std.fmt.allocPrint(allocator, "{s}/evidence", .{root}),
        .native_receipt = try std.fmt.allocPrint(allocator, "{s}/evidence/native-receipt.json", .{root}),
        .reset_observation = try std.fmt.allocPrint(allocator, "{s}/evidence/cas-reset-observation.json", .{root}),
        .filesystem_observation = try std.fmt.allocPrint(allocator, "{s}/evidence/cas-filesystem-observation.json", .{root}),
        .network_observation = try std.fmt.allocPrint(allocator, "{s}/evidence/cas-network-observation.json", .{root}),
        .external_effect_observation = try std.fmt.allocPrint(allocator, "{s}/evidence/cas-external-effect-observation.json", .{root}),
        .failure_native_receipt = try std.fmt.allocPrint(allocator, "{s}/evidence/failure-native-receipt.json", .{root}),
        .failure_execution_audit = try std.fmt.allocPrint(allocator, "{s}/evidence/failure-execution-audit.json", .{root}),
        .failure_reset_observation = try std.fmt.allocPrint(allocator, "{s}/evidence/failure-cas-reset-observation.json", .{root}),
        .failure_filesystem_observation = try std.fmt.allocPrint(allocator, "{s}/evidence/failure-cas-filesystem-observation.json", .{root}),
        .failure_network_observation = try std.fmt.allocPrint(allocator, "{s}/evidence/failure-cas-network-observation.json", .{root}),
        .failure_external_effect_observation = try std.fmt.allocPrint(allocator, "{s}/evidence/failure-cas-external-effect-observation.json", .{root}),
        .presented_input_archive = try std.fmt.allocPrint(allocator, "{s}/evidence/presented-input.json", .{root}),
        .decision_context_archive = try std.fmt.allocPrint(allocator, "{s}/evidence/decision-context.json", .{root}),
        .factor_materialization_workspace = try std.fmt.allocPrint(allocator, "{s}/factor-materialization.json", .{workspace}),
        .factor_materialization_archive = try std.fmt.allocPrint(allocator, "{s}/evidence/factor-materialization.json", .{root}),
        .target_materialization_workspace = try std.fmt.allocPrint(allocator, "{s}/target-materialization.json", .{workspace}),
        .target_materialization_archive = try std.fmt.allocPrint(allocator, "{s}/evidence/target-materialization.json", .{root}),
        .target_package_root = try std.fmt.allocPrint(allocator, "{s}/target-package", .{workspace}),
        .cleanup_receipt = try std.fmt.allocPrint(allocator, "{s}/cleanup-receipt.json", .{root}),
    };
}

fn claimPathAlloc(
    allocator: std.mem.Allocator,
    claim_root: []const u8,
    registration_digest: []const u8,
) ![]u8 {
    try validateFingerprint(registration_digest);
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}.json",
        .{ claim_root, registration_digest[7..] },
    );
}

fn authoritativeClaimStoreAlloc(allocator: std.mem.Allocator) ![]u8 {
    return authoritativeRunnerStoreAlloc(allocator, "hctp-claims-v1");
}

fn authoritativeWorkspaceStoreAlloc(allocator: std.mem.Allocator) ![]u8 {
    return authoritativeRunnerStoreAlloc(allocator, "hctp-workspaces-v1");
}

fn authoritativeRunnerStoreAlloc(allocator: std.mem.Allocator, store_name: []const u8) ![]u8 {
    var passwd: std.c.passwd = undefined;
    var storage: [64 * 1024]u8 = undefined;
    var result: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(std.c.getuid(), &passwd, &storage, storage.len, &result) != 0 or result == null) {
        return error.RunnerIdentityLookupFailed;
    }
    const home_pointer = passwd.dir orelse return error.RunnerHomeMissing;
    const home = std.mem.span(home_pointer);
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.RunnerHomeInvalid;
    return std.fs.path.resolve(allocator, &.{ home, ".codex", "cas", store_name });
}

fn claimLane(
    allocator: std.mem.Allocator,
    path: []const u8,
    view: LaneView,
    registration_digest: []const u8,
    start_digest: []const u8,
    lease_digest: []const u8,
) !void {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-trial-claim/v1\",\"trial_id\":{f},\"lane_id\":{f},\"claim_id\":{f},\"registration_event_digest\":{f},\"lane_started_event_digest\":{f},\"atomic\":true,\"claimed_before_execution\":true,\"claim_count\":1,\"expected_lane_lease_digest\":{f},\"lane_lease_digest\":{f}}}\n",
        .{
            std.json.fmt(view.trial_id, .{}),
            std.json.fmt(view.lane_id, .{}),
            std.json.fmt(view.lane_id, .{}),
            std.json.fmt(registration_digest, .{}),
            std.json.fmt(start_digest, .{}),
            std.json.fmt(lease_digest, .{}),
            std.json.fmt(lease_digest, .{}),
        },
    );
    defer allocator.free(payload);
    durable_store.writeTextCreateNewAtomic(allocator, path, payload, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => return error.LaneAlreadyClaimed,
        else => return err,
    };
    const fingerprint = try sealExistingControlArtifactAlloc(allocator, path);
    allocator.free(fingerprint);
}

fn resolveTargetMaterializationAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    repo: []const u8,
    ledger: *const ExecutableBinding,
    registration_digest: []const u8,
    start_digest: []const u8,
    lease_digest: []const u8,
    input_fingerprint: []const u8,
    workspace_ref: []const u8,
    archive_ref: []const u8,
    package_root: []const u8,
) !TargetMaterialization {
    const claim_bytes = try runLedgerLaneMaterializationAlloc(
        allocator,
        ledger,
        repo,
        view.trial_id,
        view.lane_id,
        registration_digest,
        start_digest,
        lease_digest,
    );
    defer allocator.free(claim_bytes);
    var claim_parsed = try std.json.parseFromSlice(std.json.Value, allocator, claim_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer claim_parsed.deinit();
    const claim = try object(claim_parsed.value);
    const local_trial_fingerprint = try attestation.digestValueAlloc(allocator, .{ .object = view.trial });
    defer allocator.free(local_trial_fingerprint);
    if (!std.mem.eql(u8, try requiredString(claim, "schema"), "hylo-lane-materialization-claim/v1") or
        !std.mem.eql(u8, try requiredString(claim, "trial_fingerprint"), local_trial_fingerprint) or
        !std.mem.eql(u8, try requiredString(claim, "trial_id"), view.trial_id) or
        !std.mem.eql(u8, try requiredString(claim, "lane_id"), view.lane_id) or
        !std.mem.eql(u8, try requiredString(claim, "opaque_arm_id"), view.arm_id) or
        !std.mem.eql(u8, try requiredString(claim, "registration_event_digest"), registration_digest) or
        !std.mem.eql(u8, try requiredString(claim, "lane_started_event_digest"), start_digest) or
        !std.mem.eql(u8, try requiredString(claim, "lane_lease_digest"), lease_digest) or
        !std.mem.eql(u8, try requiredString(claim, "presented_input_fingerprint"), input_fingerprint))
    {
        return error.TargetMaterializationClaimMismatch;
    }
    if (optionalString(claim, "unit_id")) |unit_id| {
        if (!std.mem.eql(u8, unit_id, view.unit_id)) return error.TargetMaterializationClaimMismatch;
    }
    if (optionalString(claim, "scenario_id")) |scenario_id| {
        if (!std.mem.eql(u8, scenario_id, view.scenario_id)) return error.TargetMaterializationClaimMismatch;
    }
    if (optionalString(claim, "pair_id")) |pair_id| {
        if (!std.mem.eql(u8, pair_id, view.pair_id)) return error.TargetMaterializationClaimMismatch;
    }
    const effect_policy = try resolveEffectPolicyAlloc(allocator, view, claim);
    errdefer effect_policy.deinit(allocator);
    const envelope_value = claim.get("arm_materialization") orelse return error.TargetMaterializationMissing;
    const envelope = try object(envelope_value);
    if (!std.mem.eql(u8, try requiredString(envelope, "schema"), "hylo-arm-materialization/v1") or
        !std.mem.eql(u8, try requiredString(envelope, "arm_id"), view.arm_id) or
        !std.mem.eql(u8, try requiredString(envelope, "value_fingerprint"), try requiredString(view.arm, "value_fingerprint")) or
        !std.mem.eql(u8, try requiredString(envelope, "materialization_ref"), try requiredString(view.arm, "materialization_ref")) or
        !std.mem.eql(u8, try requiredString(envelope, "materialization_fingerprint"), try requiredString(view.arm, "materialization_fingerprint")))
    {
        return error.TargetMaterializationClaimMismatch;
    }
    const factor_kind = try requiredString(try requiredObject(view.trial, "factor"), "kind");
    if (!std.mem.eql(u8, factor_kind, "target_snapshot")) return .{
        .present = false,
        .arm_value_fingerprint = try allocator.dupe(u8, try requiredString(envelope, "value_fingerprint")),
        .snapshot_ref = try allocator.dupe(u8, try requiredString(envelope, "materialization_ref")),
        .snapshot_fingerprint = try allocator.dupe(u8, try requiredString(envelope, "materialization_fingerprint")),
        .carrier_bytes = null,
        .carrier_fingerprint = null,
        .effect_policy_bytes = effect_policy.bytes,
        .effect_policy_fingerprint = effect_policy.fingerprint,
        .workspace_ref = workspace_ref,
        .archive_ref = archive_ref,
        .package_root = package_root,
    };
    const common_projection = try resolveTargetCommonProjectionAlloc(allocator, view, claim);
    errdefer common_projection.deinit(allocator);
    const snapshot_value = envelope.get("materialization") orelse return error.TargetMaterializationMissing;
    const snapshot = try object(snapshot_value);
    if (!std.mem.eql(u8, try requiredString(snapshot, "schema"), "hylo-target-snapshot/v1")) {
        return error.TargetMaterializationClaimMismatch;
    }
    const observed_snapshot_fingerprint = try attestation.digestValueAlloc(allocator, snapshot_value);
    defer allocator.free(observed_snapshot_fingerprint);
    if (!std.mem.eql(u8, observed_snapshot_fingerprint, try requiredString(view.arm, "materialization_fingerprint"))) {
        return error.TargetMaterializationFingerprintMismatch;
    }
    const roots = try requiredArray(snapshot, "roots");
    if (roots.items.len == 0) return error.TargetMaterializationRootsMissing;
    for (roots.items) |root_value| try validateTargetRelativePath(try string(root_value));

    var carrier: std.Io.Writer.Allocating = .init(allocator);
    errdefer carrier.deinit();
    try carrier.writer.writeAll("{\"schema\":\"cas-target-materialization/v1\",\"trial_id\":");
    try std.json.Stringify.value(view.trial_id, .{}, &carrier.writer);
    try carrier.writer.writeAll(",\"lane_id\":");
    try std.json.Stringify.value(view.lane_id, .{}, &carrier.writer);
    try carrier.writer.writeAll(",\"registration_event_digest\":");
    try std.json.Stringify.value(registration_digest, .{}, &carrier.writer);
    try carrier.writer.writeAll(",\"lane_started_event_digest\":");
    try std.json.Stringify.value(start_digest, .{}, &carrier.writer);
    try carrier.writer.writeAll(",\"lane_lease_digest\":");
    try std.json.Stringify.value(lease_digest, .{}, &carrier.writer);
    try carrier.writer.writeAll(",\"arm_materialization\":");
    const envelope_json = try canonicalFieldAlloc(allocator, envelope_value);
    defer allocator.free(envelope_json);
    try carrier.writer.writeAll(envelope_json);
    try carrier.writer.writeAll(",\"files\":[");
    const entries = try requiredArray(snapshot, "entries");
    var previous_path: ?[]const u8 = null;
    var raw_bytes_total: usize = 0;
    for (entries.items, 0..) |entry_value, index| {
        const entry = try object(entry_value);
        const path = try requiredString(entry, "path");
        try validateTargetRelativePath(path);
        if (!targetPathCoveredByRoots(path, roots)) return error.TargetMaterializationPathOutsideRoots;
        if (previous_path) |previous| if (!std.mem.lessThan(u8, previous, path)) return error.TargetMaterializationEntriesInvalid;
        previous_path = path;
        const mode = try requiredString(entry, "mode");
        if (!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) {
            return error.TargetMaterializationModeUnsupported;
        }
        if (!std.mem.eql(u8, try requiredString(entry, "object_type"), "blob")) {
            return error.TargetMaterializationObjectInvalid;
        }
        const object_id = try requiredString(entry, "object_id");
        if ((object_id.len != 40 and object_id.len != 64) or !isLowerHex(object_id)) {
            return error.TargetMaterializationObjectInvalid;
        }
        const object_type_raw = try runGitStdoutAlloc(allocator, repo, &.{ "cat-file", "-t", object_id });
        defer allocator.free(object_type_raw);
        if (!std.mem.eql(u8, std.mem.trim(u8, object_type_raw, " \t\r\n"), "blob")) {
            return error.TargetMaterializationObjectInvalid;
        }
        const bytes = try runGitStdoutAlloc(allocator, repo, &.{ "cat-file", "blob", object_id });
        defer allocator.free(bytes);
        raw_bytes_total = std.math.add(usize, raw_bytes_total, bytes.len) catch return error.TargetMaterializationTooLarge;
        if (raw_bytes_total > MaxInputBytes) return error.TargetMaterializationTooLarge;
        try verifyGitBlobObjectId(allocator, object_id, bytes);
        const content_fingerprint = try attestation.digestBytesAlloc(allocator, bytes);
        defer allocator.free(content_fingerprint);
        const encoded = try base64EncodeAlloc(allocator, bytes);
        defer allocator.free(encoded);
        if (index != 0) try carrier.writer.writeByte(',');
        try carrier.writer.writeAll("{\"path\":");
        try std.json.Stringify.value(path, .{}, &carrier.writer);
        try carrier.writer.writeAll(",\"mode\":");
        try std.json.Stringify.value(mode, .{}, &carrier.writer);
        try carrier.writer.writeAll(",\"object_id\":");
        try std.json.Stringify.value(object_id, .{}, &carrier.writer);
        try carrier.writer.writeAll(",\"content_fingerprint\":");
        try std.json.Stringify.value(content_fingerprint, .{}, &carrier.writer);
        try carrier.writer.writeAll(",\"content_base64\":");
        try std.json.Stringify.value(encoded, .{}, &carrier.writer);
        try carrier.writer.writeByte('}');
    }
    try carrier.writer.writeAll("]}");
    if (carrier.written().len > MaxTargetCarrierBytes) return error.TargetMaterializationTooLarge;
    const carrier_bytes = try carrier.toOwnedSlice();
    errdefer allocator.free(carrier_bytes);
    return .{
        .present = true,
        .arm_value_fingerprint = try allocator.dupe(u8, try requiredString(envelope, "value_fingerprint")),
        .snapshot_ref = try allocator.dupe(u8, try requiredString(envelope, "materialization_ref")),
        .snapshot_fingerprint = try allocator.dupe(u8, try requiredString(envelope, "materialization_fingerprint")),
        .carrier_bytes = carrier_bytes,
        .carrier_fingerprint = try attestation.digestBytesAlloc(allocator, carrier_bytes),
        .common_projection_bytes = common_projection.bytes,
        .common_projection_fingerprint = common_projection.fingerprint,
        .effect_policy_bytes = effect_policy.bytes,
        .effect_policy_fingerprint = effect_policy.fingerprint,
        .workspace_ref = workspace_ref,
        .archive_ref = archive_ref,
        .package_root = package_root,
    };
}

fn resolveEffectPolicyAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    claim: std.json.ObjectMap,
) !EffectPolicyMaterialization {
    const assurance = if (view.trial.get("assurance")) |assurance_value|
        try requiredString(try object(assurance_value), "required_level")
    else
        "precommitted";
    const policy_value = claim.get("effect_policy") orelse {
        if (std.mem.eql(u8, assurance, "sealed")) return error.EffectPolicyMissing;
        return .{};
    };
    const claimed_fingerprint = try requiredString(claim, "effect_policy_fingerprint");
    try validateFingerprint(claimed_fingerprint);
    const bytes = try attestation.canonicalJsonAlloc(allocator, policy_value);
    errdefer allocator.free(bytes);
    const observed_fingerprint = try attestation.digestBytesAlloc(allocator, bytes);
    errdefer allocator.free(observed_fingerprint);
    if (!std.mem.eql(u8, observed_fingerprint, claimed_fingerprint) or
        !std.mem.eql(u8, observed_fingerprint, try requiredString(view.execution, "effect_policy_fingerprint")))
    {
        return error.EffectPolicyFingerprintMismatch;
    }
    try validateEffectPolicyShape(try object(policy_value));
    return .{ .bytes = bytes, .fingerprint = observed_fingerprint };
}

fn validateEffectPolicyShape(policy: std.json.ObjectMap) !void {
    if (policy.count() != 6 or
        !std.mem.eql(u8, try requiredString(policy, "filesystem"), "workspace_write") or
        !std.mem.eql(u8, try requiredString(policy, "network"), "deny") or
        !std.mem.eql(u8, try requiredString(policy, "external_side_effects"), "deny") or
        (try requiredArray(policy, "allowed_paths")).items.len != 0 or
        (try requiredArray(policy, "network_allowlist")).items.len != 0 or
        (try requiredArray(policy, "external_effect_allowlist")).items.len != 0)
    {
        return error.EffectPolicyUnsupported;
    }
}

fn resolveTargetCommonProjectionAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    claim: std.json.ObjectMap,
) !TargetCommonProjection {
    const factor = try requiredObject(view.trial, "factor");
    const registered_value = factor.get("target_common_projection") orelse
        return error.TargetCommonProjectionMissing;
    const claimed_value = claim.get("target_common_projection") orelse
        return error.TargetCommonProjectionMissing;
    const registered = try object(registered_value);
    const claimed_bytes = try attestation.canonicalJsonAlloc(allocator, claimed_value);
    defer allocator.free(claimed_bytes);
    const registered_bytes = try attestation.canonicalJsonAlloc(allocator, registered_value);
    errdefer allocator.free(registered_bytes);
    if (!std.mem.eql(u8, registered_bytes, claimed_bytes)) return error.TargetCommonProjectionMismatch;
    try validateTargetCommonProjectionShape(factor, registered);
    const fingerprint = try attestation.digestBytesAlloc(allocator, registered_bytes);
    errdefer allocator.free(fingerprint);
    const witness = try requiredObject(factor, "intervention_witness");
    if (!std.mem.eql(u8, fingerprint, try requiredString(factor, "common_projection_fingerprint")) or
        !std.mem.eql(
            u8,
            fingerprint,
            try requiredString(try requiredObject(witness, "common_projection"), "fingerprint"),
        ))
    {
        return error.TargetCommonProjectionMismatch;
    }
    return .{ .bytes = registered_bytes, .fingerprint = fingerprint };
}

fn validateTargetCommonProjectionShape(
    factor: std.json.ObjectMap,
    projection: std.json.ObjectMap,
) !void {
    if (projection.count() != 5 or
        !std.mem.eql(u8, try requiredString(projection, "schema"), "hylo-target-common-projection/v1"))
    {
        return error.TargetCommonProjectionInvalid;
    }
    const verifier = try requiredObject(projection, "verifier");
    if (verifier.count() != 2 or
        !std.mem.eql(u8, try requiredString(verifier, "id"), "git-target-common-projection") or
        !std.mem.eql(u8, try requiredString(verifier, "version"), "v1"))
    {
        return error.TargetCommonProjectionInvalid;
    }
    const baseline_revision = try requiredString(projection, "baseline_revision");
    if ((baseline_revision.len != 40 and baseline_revision.len != 64) or !isLowerHex(baseline_revision)) {
        return error.TargetCommonProjectionInvalid;
    }
    const declared_roots = try requiredArray(factor, "allowed_difference_roots");
    const excluded_roots = try requiredArray(projection, "excluded_roots");
    if (excluded_roots.items.len != declared_roots.items.len) return error.TargetCommonProjectionInvalid;
    for (excluded_roots.items, 0..) |root_value, index| {
        const root = try string(root_value);
        try validateTargetRelativePath(root);
        if (index != 0 and !std.mem.lessThan(u8, try string(excluded_roots.items[index - 1]), root)) {
            return error.TargetCommonProjectionInvalid;
        }
        var matches: usize = 0;
        for (declared_roots.items) |declared_value| {
            if (std.mem.eql(u8, root, try string(declared_value))) matches += 1;
        }
        if (matches != 1) return error.TargetCommonProjectionInvalid;
    }
    const entries = try requiredArray(projection, "entries");
    for (entries.items, 0..) |entry_value, index| {
        const entry = try object(entry_value);
        if (entry.count() != 5) return error.TargetCommonProjectionInvalid;
        const path = try requiredString(entry, "path");
        try validateTargetRelativePath(path);
        if (index != 0 and
            !std.mem.lessThan(u8, try requiredString(try object(entries.items[index - 1]), "path"), path))
        {
            return error.TargetCommonProjectionInvalid;
        }
        for (excluded_roots.items) |root_value| {
            if (targetPathCoveredByRoot(path, try string(root_value))) {
                return error.TargetCommonProjectionInvalid;
            }
        }
        const mode = try requiredString(entry, "mode");
        if (!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) {
            return error.TargetCommonProjectionEntryUnsupported;
        }
        if (!std.mem.eql(u8, try requiredString(entry, "object_type"), "blob")) {
            return error.TargetCommonProjectionEntryUnsupported;
        }
        const object_id = try requiredString(entry, "object_id");
        if ((object_id.len != 40 and object_id.len != 64) or !isLowerHex(object_id)) {
            return error.TargetCommonProjectionInvalid;
        }
        try validateFingerprint(try requiredString(entry, "content_fingerprint"));
    }
}

fn targetPathCoveredByRoot(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or
        (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/');
}

fn runLedgerLaneMaterializationAlloc(
    allocator: std.mem.Allocator,
    ledger: *const ExecutableBinding,
    repo: []const u8,
    trial_id: []const u8,
    lane_id: []const u8,
    registration_digest: []const u8,
    start_digest: []const u8,
    lease_digest: []const u8,
) ![]u8 {
    const argv = [_][]const u8{
        ledger.spawn_path,
        "--source",
        "hylo",
        "lane-materialization",
        "--repo",
        repo,
        "--trial-id",
        trial_id,
        "--lane-id",
        lane_id,
        "--registration-event-digest",
        registration_digest,
        "--lane-started-event-digest",
        start_digest,
        "--lane-lease-digest",
        lease_digest,
        "--format",
        "json",
    };
    const process_allocator = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = process_allocator;
    try validateExecutableAtSpawn(allocator, ledger);
    const result = std.process.run(process_allocator, threaded.io(), .{
        .argv = &argv,
        .cwd = .{ .path = repo },
        .stdout_limit = .limited(MaxTargetCarrierBytes),
        .stderr_limit = .limited(MaxInputBytes),
    }) catch {
        try validateExecutableAtSpawn(allocator, ledger);
        return error.LedgerMaterializationUnavailable;
    };
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    try validateExecutableAtSpawn(allocator, ledger);
    if (processExitCode(result.term) != 0) return error.LedgerMaterializationUnavailable;
    return allocator.dupe(u8, result.stdout);
}

fn persistTargetMaterialization(
    allocator: std.mem.Allocator,
    materialization: TargetMaterialization,
) !void {
    if (!materialization.present) return;
    const carrier = materialization.carrier_bytes orelse return error.TargetMaterializationMissing;
    const fingerprint = materialization.carrier_fingerprint orelse return error.TargetMaterializationMissing;
    try archiveBytesAtPathLimited(allocator, carrier, materialization.workspace_ref, fingerprint, MaxTargetCarrierBytes);
    try archiveBytesAtPathLimited(allocator, carrier, materialization.archive_ref, fingerprint, MaxTargetCarrierBytes);
    try durable_store.ensureDirectoryPathNoSymlinks(materialization.package_root);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, carrier, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    for ((try requiredArray(try object(parsed.value), "files")).items) |file_value| {
        const file = try object(file_value);
        const relative = try requiredString(file, "path");
        try validateTargetRelativePath(relative);
        const destination = try std.fs.path.join(allocator, &.{ materialization.package_root, relative });
        defer allocator.free(destination);
        const parent = std.fs.path.dirname(destination) orelse return error.TargetMaterializationPathInvalid;
        try durable_store.ensureDirectoryPathNoSymlinks(parent);
        const decoded = try base64DecodeAlloc(allocator, try requiredString(file, "content_base64"));
        defer allocator.free(decoded);
        try requireBytesFingerprint(allocator, decoded, try requiredString(file, "content_fingerprint"));
        try verifyGitBlobObjectId(allocator, try requiredString(file, "object_id"), decoded);
        try durable_store.writeTextCreateNewAtomic(allocator, destination, decoded, .{});
        try setTargetFileReadOnly(destination, try requiredString(file, "mode"));
    }
    try makeDirectoryTreeReadOnly(allocator, materialization.package_root);
}

fn materializeExecutionProjection(
    allocator: std.mem.Allocator,
    view: LaneView,
    repo: []const u8,
    execution_root: []const u8,
    materialization: TargetMaterialization,
) !void {
    try durable_store.ensureDirectoryPathNoSymlinks(execution_root);
    if (!materialization.present) return;
    const projection_bytes = materialization.common_projection_bytes orelse
        return error.TargetCommonProjectionMissing;
    var projection_parsed = try std.json.parseFromSlice(std.json.Value, allocator, projection_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer projection_parsed.deinit();
    const projection = try object(projection_parsed.value);
    try validateTargetCommonProjectionShape(try requiredObject(view.trial, "factor"), projection);
    const revision = try requiredString(projection, "baseline_revision");
    const revision_type = runGitStdoutAlloc(allocator, repo, &.{ "cat-file", "-t", revision }) catch
        return error.TargetCommonProjectionUnavailable;
    defer allocator.free(revision_type);
    if (!std.mem.eql(u8, std.mem.trim(u8, revision_type, " \t\r\n"), "commit")) {
        return error.TargetCommonProjectionInvalid;
    }
    for ((try requiredArray(projection, "entries")).items) |entry_value| {
        const entry = try object(entry_value);
        const object_id = try requiredString(entry, "object_id");
        const object_type = runGitStdoutAlloc(allocator, repo, &.{ "cat-file", "-t", object_id }) catch
            return error.TargetCommonProjectionUnavailable;
        defer allocator.free(object_type);
        if (!std.mem.eql(u8, std.mem.trim(u8, object_type, " \t\r\n"), "blob")) {
            return error.TargetCommonProjectionEntryUnsupported;
        }
        const bytes = runGitStdoutAlloc(allocator, repo, &.{ "cat-file", "blob", object_id }) catch
            return error.TargetCommonProjectionUnavailable;
        defer allocator.free(bytes);
        try verifyGitBlobObjectId(allocator, object_id, bytes);
        try requireBytesFingerprint(allocator, bytes, try requiredString(entry, "content_fingerprint"));
        const destination = try std.fs.path.join(allocator, &.{ execution_root, try requiredString(entry, "path") });
        defer allocator.free(destination);
        const parent = std.fs.path.dirname(destination) orelse return error.TargetCommonProjectionInvalid;
        try durable_store.ensureDirectoryPathNoSymlinks(parent);
        try durable_store.writeTextCreateNewAtomic(allocator, destination, bytes, .{});
        try setProjectionFilePermissions(destination, try requiredString(entry, "mode"));
    }
    const carrier = materialization.carrier_bytes orelse return error.TargetMaterializationMissing;
    var carrier_parsed = try std.json.parseFromSlice(std.json.Value, allocator, carrier, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer carrier_parsed.deinit();
    for ((try requiredArray(try object(carrier_parsed.value), "files")).items) |file_value| {
        const file = try object(file_value);
        const destination = try std.fs.path.join(allocator, &.{ execution_root, try requiredString(file, "path") });
        defer allocator.free(destination);
        const parent = std.fs.path.dirname(destination) orelse return error.TargetMaterializationPathInvalid;
        try durable_store.ensureDirectoryPathNoSymlinks(parent);
        const decoded = try base64DecodeAlloc(allocator, try requiredString(file, "content_base64"));
        defer allocator.free(decoded);
        try requireBytesFingerprint(allocator, decoded, try requiredString(file, "content_fingerprint"));
        try verifyGitBlobObjectId(allocator, try requiredString(file, "object_id"), decoded);
        try durable_store.writeTextCreateNewAtomic(allocator, destination, decoded, .{});
        try setTargetFileReadOnly(destination, try requiredString(file, "mode"));
    }
    try verifyExecutionProjection(allocator, projection, execution_root, materialization);
}

fn verifyExecutionProjection(
    allocator: std.mem.Allocator,
    projection: std.json.ObjectMap,
    execution_root: []const u8,
    materialization: TargetMaterialization,
) !void {
    for ((try requiredArray(projection, "entries")).items) |entry_value| {
        const entry = try object(entry_value);
        const path = try std.fs.path.join(allocator, &.{ execution_root, try requiredString(entry, "path") });
        defer allocator.free(path);
        const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
        defer allocator.free(bytes);
        try requireBytesFingerprint(allocator, bytes, try requiredString(entry, "content_fingerprint"));
        try verifyGitBlobObjectId(allocator, try requiredString(entry, "object_id"), bytes);
    }
    try verifyExecutionTargetOverlay(allocator, execution_root, materialization);
}

const MaxExecutionTreeEntries = 4096;

const ExecutionTreeEntryKind = enum { directory, file };

const ExecutionTreeEntry = struct {
    path: []u8,
    kind: ExecutionTreeEntryKind,
    mode: std.posix.mode_t,
    content_fingerprint: ?[]u8,

    fn deinit(self: ExecutionTreeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.content_fingerprint) |fingerprint| allocator.free(fingerprint);
    }
};

const ExecutionTreeSnapshot = struct {
    root_mode: std.posix.mode_t,
    entries: []ExecutionTreeEntry,

    fn deinit(self: ExecutionTreeSnapshot, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }

    fn find(self: ExecutionTreeSnapshot, path: []const u8) ?*const ExecutionTreeEntry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    fn fingerprintAlloc(self: ExecutionTreeSnapshot, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.print(
            "{{\"schema\":\"cas-execution-tree-projection/v1\",\"root_mode\":{d},\"entries\":[",
            .{self.root_mode & 0o777},
        );
        for (self.entries, 0..) |entry, index| {
            if (index != 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"path\":");
            try std.json.Stringify.value(entry.path, .{}, &out.writer);
            try out.writer.writeAll(",\"kind\":");
            try std.json.Stringify.value(@tagName(entry.kind), .{}, &out.writer);
            try out.writer.print(",\"mode\":{d},\"content_fingerprint\":", .{entry.mode & 0o777});
            try std.json.Stringify.value(entry.content_fingerprint, .{}, &out.writer);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return attestation.digestBytesAlloc(allocator, out.written());
    }
};

const TargetPackageObservation = struct {
    before_fingerprint: ?[]u8,
    after_fingerprint: ?[]u8,

    fn deinit(self: TargetPackageObservation, allocator: std.mem.Allocator) void {
        if (self.before_fingerprint) |fingerprint| allocator.free(fingerprint);
        if (self.after_fingerprint) |fingerprint| allocator.free(fingerprint);
    }
};

fn captureExecutionTreeAlloc(
    allocator: std.mem.Allocator,
    execution_root: []const u8,
) !ExecutionTreeSnapshot {
    const root_stat = try std.Io.Dir.cwd().statFile(defaultIo(), execution_root, .{ .follow_symlinks = false });
    if (root_stat.kind == .sym_link) return error.TargetCommonProjectionMutation;
    if (root_stat.kind != .directory) return error.TargetCommonProjectionMutation;
    var entries: std.ArrayList(ExecutionTreeEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    try captureExecutionTreeEntries(allocator, execution_root, "", &entries);
    std.mem.sort(ExecutionTreeEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: ExecutionTreeEntry, rhs: ExecutionTreeEntry) bool {
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
    return .{
        .root_mode = root_stat.permissions.toMode(),
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn verifyExactTreeEqual(before: ExecutionTreeSnapshot, after: ExecutionTreeSnapshot) !void {
    if (before.root_mode & 0o777 != after.root_mode & 0o777 or
        before.entries.len != after.entries.len)
    {
        return error.ExactTreeMutation;
    }
    for (before.entries, after.entries) |expected, observed| {
        if (!std.mem.eql(u8, expected.path, observed.path) or
            expected.kind != observed.kind or
            expected.mode & 0o777 != observed.mode & 0o777)
        {
            return error.ExactTreeMutation;
        }
        if (expected.content_fingerprint) |expected_fingerprint| {
            const observed_fingerprint = observed.content_fingerprint orelse return error.ExactTreeMutation;
            if (!std.mem.eql(u8, expected_fingerprint, observed_fingerprint)) return error.ExactTreeMutation;
        } else if (observed.content_fingerprint != null) return error.ExactTreeMutation;
    }
}

fn captureTargetPackageBaselineAlloc(
    allocator: std.mem.Allocator,
    materialization: TargetMaterialization,
) !?ExecutionTreeSnapshot {
    if (!materialization.present) return null;
    var snapshot = captureExecutionTreeAlloc(allocator, materialization.package_root) catch
        return error.TargetPackageTreeMutation;
    errdefer snapshot.deinit(allocator);
    if (snapshot.root_mode & 0o777 != 0o500) return error.TargetPackageTreeMutation;
    const carrier = materialization.carrier_bytes orelse return error.TargetMaterializationMissing;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, carrier, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const files = try requiredArray(try object(parsed.value), "files");
    for (snapshot.entries) |entry| {
        if (entry.kind == .directory) {
            if (entry.mode & 0o777 != 0o500 or
                !try registeredExecutionPathIsOrHasDescendant(null, try object(parsed.value), entry.path))
            {
                return error.TargetPackageTreeMutation;
            }
            continue;
        }
        var matched = false;
        for (files.items) |file_value| {
            const expected = try object(file_value);
            if (!std.mem.eql(u8, entry.path, try requiredString(expected, "path"))) continue;
            matched = true;
            const expected_mode: std.posix.mode_t = if (std.mem.eql(u8, try requiredString(expected, "mode"), "100755"))
                0o500
            else
                0o400;
            if (entry.mode & 0o777 != expected_mode or
                !std.mem.eql(
                    u8,
                    entry.content_fingerprint orelse return error.TargetPackageTreeMutation,
                    try requiredString(expected, "content_fingerprint"),
                ))
            {
                return error.TargetPackageTreeMutation;
            }
            break;
        }
        if (!matched) return error.TargetPackageTreeMutation;
    }
    for (files.items) |file_value| {
        const expected = try object(file_value);
        const observed = snapshot.find(try requiredString(expected, "path")) orelse
            return error.TargetPackageTreeMutation;
        if (observed.kind != .file) return error.TargetPackageTreeMutation;
    }
    return snapshot;
}

fn observeTargetPackageAfterExecutionAlloc(
    allocator: std.mem.Allocator,
    materialization: TargetMaterialization,
    baseline: ?ExecutionTreeSnapshot,
) !TargetPackageObservation {
    const before = baseline orelse return .{
        .before_fingerprint = null,
        .after_fingerprint = null,
    };
    var observed = captureExecutionTreeAlloc(allocator, materialization.package_root) catch
        return error.TargetPackageTreeMutation;
    defer observed.deinit(allocator);
    verifyExactTreeEqual(before, observed) catch return error.TargetPackageTreeMutation;
    return .{
        .before_fingerprint = try before.fingerprintAlloc(allocator),
        .after_fingerprint = try observed.fingerprintAlloc(allocator),
    };
}

fn captureExecutionTreeEntries(
    allocator: std.mem.Allocator,
    execution_root: []const u8,
    relative_root: []const u8,
    entries: *std.ArrayList(ExecutionTreeEntry),
) !void {
    const directory_path = if (relative_root.len == 0)
        try allocator.dupe(u8, execution_root)
    else
        try std.fs.path.join(allocator, &.{ execution_root, relative_root });
    defer allocator.free(directory_path);
    var directory = if (std.fs.path.isAbsolute(directory_path))
        try std.Io.Dir.openDirAbsolute(defaultIo(), directory_path, .{ .iterate = true, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(defaultIo(), directory_path, .{ .iterate = true, .follow_symlinks = false });
    defer directory.close(defaultIo());
    var iterator = directory.iterate();
    while (try iterator.next(defaultIo())) |entry| {
        if (entries.items.len >= MaxExecutionTreeEntries) return error.TargetCommonProjectionMutation;
        const relative = if (relative_root.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ relative_root, entry.name });
        errdefer allocator.free(relative);
        const path = try std.fs.path.join(allocator, &.{ execution_root, relative });
        defer allocator.free(path);
        const stat = try std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.TargetCommonProjectionMutation;
        const kind: ExecutionTreeEntryKind = switch (stat.kind) {
            .directory => .directory,
            .file => .file,
            else => return error.TargetCommonProjectionMutation,
        };
        const content_fingerprint = if (kind == .file) blk: {
            const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
            defer allocator.free(bytes);
            break :blk try attestation.digestBytesAlloc(allocator, bytes);
        } else null;
        errdefer if (content_fingerprint) |fingerprint| allocator.free(fingerprint);
        try entries.append(allocator, .{
            .path = relative,
            .kind = kind,
            .mode = stat.permissions.toMode(),
            .content_fingerprint = content_fingerprint,
        });
        if (kind == .directory) try captureExecutionTreeEntries(allocator, execution_root, relative, entries);
    }
}

fn verifyExecutorOutputCarrierAlloc(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    result_path: []const u8,
) ![]u8 {
    const output_root_resolved = try std.fs.path.resolve(allocator, &.{output_root});
    defer allocator.free(output_root_resolved);
    const result_resolved = try std.fs.path.resolve(allocator, &.{result_path});
    defer allocator.free(result_resolved);
    if (!isStrictDescendant(output_root_resolved, result_resolved)) {
        return error.ExecutorOutputCarrierInvalid;
    }
    const result_relative = result_resolved[output_root_resolved.len + 1 ..];
    if (!std.mem.eql(u8, result_relative, "result.json")) return error.ExecutorOutputCarrierInvalid;
    var snapshot = captureExecutionTreeAlloc(allocator, output_root) catch
        return error.ExecutorOutputCarrierInvalid;
    defer snapshot.deinit(allocator);
    if (snapshot.entries.len != 4) return error.ExecutorOutputCarrierInvalid;
    inline for (.{
        .{ "result.json", ExecutionTreeEntryKind.file },
        .{ "result.json.stdout", ExecutionTreeEntryKind.file },
        .{ "result.json.stderr", ExecutionTreeEntryKind.file },
        .{ "tmp", ExecutionTreeEntryKind.directory },
    }) |expected| {
        const entry = snapshot.find(expected[0]) orelse return error.ExecutorOutputCarrierInvalid;
        if (entry.kind != expected[1]) return error.ExecutorOutputCarrierInvalid;
        if (entry.kind == .file and entry.mode & 0o022 != 0) return error.ExecutorOutputCarrierInvalid;
    }
    return snapshot.fingerprintAlloc(allocator);
}

fn registeredExecutionPathIsOrHasDescendant(
    projection: ?std.json.ObjectMap,
    carrier: ?std.json.ObjectMap,
    relative: []const u8,
) !bool {
    if (projection) |value| {
        for ((try requiredArray(value, "entries")).items) |entry_value| {
            const path = try requiredString(try object(entry_value), "path");
            if (std.mem.eql(u8, path, relative) or
                (path.len > relative.len and std.mem.startsWith(u8, path, relative) and path[relative.len] == '/')) return true;
        }
    }
    if (carrier) |value| {
        for ((try requiredArray(value, "files")).items) |file_value| {
            const path = try requiredString(try object(file_value), "path");
            if (std.mem.eql(u8, path, relative) or
                (path.len > relative.len and std.mem.startsWith(u8, path, relative) and path[relative.len] == '/')) return true;
        }
    }
    return false;
}

fn verifyExecutionTreeBaseline(
    allocator: std.mem.Allocator,
    snapshot: ExecutionTreeSnapshot,
    materialization: TargetMaterialization,
) !void {
    var projection_parsed: ?std.json.Parsed(std.json.Value) = if (materialization.common_projection_bytes) |bytes|
        try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        })
    else
        null;
    defer if (projection_parsed) |*parsed| parsed.deinit();
    const projection = if (projection_parsed) |parsed| try object(parsed.value) else null;
    var carrier_parsed: ?std.json.Parsed(std.json.Value) = if (materialization.carrier_bytes) |bytes|
        try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        })
    else
        null;
    defer if (carrier_parsed) |*parsed| parsed.deinit();
    const carrier = if (carrier_parsed) |parsed| try object(parsed.value) else null;

    for (snapshot.entries) |entry| {
        if (entry.kind == .directory) {
            if (!try registeredExecutionPathIsOrHasDescendant(projection, carrier, entry.path)) {
                return error.TargetCommonProjectionMutation;
            }
            continue;
        }
        var matched = false;
        if (projection) |value| {
            for ((try requiredArray(value, "entries")).items) |entry_value| {
                const expected = try object(entry_value);
                if (!std.mem.eql(u8, entry.path, try requiredString(expected, "path"))) continue;
                matched = true;
                const expected_mode: std.posix.mode_t = if (std.mem.eql(u8, try requiredString(expected, "mode"), "100755"))
                    0o700
                else
                    0o600;
                if (entry.mode & 0o777 != expected_mode or
                    !std.mem.eql(u8, entry.content_fingerprint orelse return error.TargetCommonProjectionMutation, try requiredString(expected, "content_fingerprint")))
                {
                    return error.TargetCommonProjectionMutation;
                }
            }
        }
        if (carrier) |value| {
            for ((try requiredArray(value, "files")).items) |file_value| {
                const expected = try object(file_value);
                if (!std.mem.eql(u8, entry.path, try requiredString(expected, "path"))) continue;
                if (matched) return error.TargetCommonProjectionMutation;
                matched = true;
                const expected_mode: std.posix.mode_t = if (std.mem.eql(u8, try requiredString(expected, "mode"), "100755"))
                    0o500
                else
                    0o400;
                if (entry.mode & 0o777 != expected_mode or
                    !std.mem.eql(u8, entry.content_fingerprint orelse return error.TargetCommonProjectionMutation, try requiredString(expected, "content_fingerprint")))
                {
                    return error.TargetCommonProjectionMutation;
                }
            }
        }
        if (!matched) return error.TargetCommonProjectionMutation;
    }
    if (projection) |value| {
        for ((try requiredArray(value, "entries")).items) |entry_value| {
            const expected = try object(entry_value);
            const observed = snapshot.find(try requiredString(expected, "path")) orelse
                return error.TargetCommonProjectionMutation;
            if (observed.kind != .file) return error.TargetCommonProjectionMutation;
        }
    }
    if (carrier) |value| {
        for ((try requiredArray(value, "files")).items) |file_value| {
            const expected = try object(file_value);
            const observed = snapshot.find(try requiredString(expected, "path")) orelse
                return error.TargetCommonProjectionMutation;
            if (observed.kind != .file) return error.TargetCommonProjectionMutation;
        }
    }
}

const DeclaredExecutionEvidence = struct {
    path: []const u8,
    expected_fingerprint: ?[]u8,
    seen: bool = false,
};

fn deinitDeclaredExecutionEvidence(
    allocator: std.mem.Allocator,
    declared: *std.ArrayList(DeclaredExecutionEvidence),
) void {
    for (declared.items) |entry| {
        if (entry.expected_fingerprint) |fingerprint| allocator.free(fingerprint);
    }
    declared.deinit(allocator);
}

fn appendDeclaredExecutionEvidence(
    allocator: std.mem.Allocator,
    declared: *std.ArrayList(DeclaredExecutionEvidence),
    execution_root: []const u8,
    raw_path: []const u8,
    fixed_path: []const u8,
    expected_fingerprint: ?[]const u8,
) !void {
    const expected = try std.fs.path.resolve(allocator, &.{ execution_root, fixed_path });
    defer allocator.free(expected);
    const presented = if (std.fs.path.isAbsolute(raw_path))
        try std.fs.path.resolve(allocator, &.{raw_path})
    else
        try std.fs.path.resolve(allocator, &.{ execution_root, raw_path });
    defer allocator.free(presented);
    if (!std.mem.eql(u8, expected, presented)) return error.TargetCommonProjectionMutation;
    const owned_fingerprint = if (expected_fingerprint) |fingerprint|
        try allocator.dupe(u8, fingerprint)
    else
        null;
    errdefer if (owned_fingerprint) |fingerprint| allocator.free(fingerprint);
    try declared.append(allocator, .{
        .path = fixed_path,
        .expected_fingerprint = owned_fingerprint,
    });
}

fn declaredExecutionEvidenceAlloc(
    allocator: std.mem.Allocator,
    execution_root: []const u8,
    executor_result_text: []const u8,
) !std.ArrayList(DeclaredExecutionEvidence) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, executor_result_text, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const result = try object(parsed.value);
    const isolation = try requiredObject(result, "isolation");
    const effects = try requiredObject(result, "effects");
    const evidence = try requiredObject(result, "evidence");
    var declared: std.ArrayList(DeclaredExecutionEvidence) = .empty;
    errdefer deinitDeclaredExecutionEvidence(allocator, &declared);
    try appendDeclaredExecutionEvidence(
        allocator,
        &declared,
        execution_root,
        try requiredString(result, "execution_audit_ref"),
        "execution-audit.json",
        try requiredString(result, "execution_audit_fingerprint"),
    );
    try appendDeclaredExecutionEvidence(
        allocator,
        &declared,
        execution_root,
        try requiredString(isolation, "reset_receipt_ref"),
        "reset.json",
        try requiredString(isolation, "reset_receipt_fingerprint"),
    );
    inline for (.{
        .{ "filesystem_receipt_ref", "filesystem_receipt_fingerprint", "filesystem.json" },
        .{ "network_receipt_ref", "network_receipt_fingerprint", "network.json" },
        .{ "external_effect_receipt_ref", "external_effect_receipt_fingerprint", "external.json" },
    }) |spec| {
        try appendDeclaredExecutionEvidence(
            allocator,
            &declared,
            execution_root,
            try requiredString(effects, spec[0]),
            spec[2],
            try requiredString(effects, spec[1]),
        );
    }
    inline for (.{
        .{ "output_path", "output.json" },
        .{ "trace_path", "trace.json" },
        .{ "world_state_path", "world.json" },
        .{ "metrics_path", "metrics.json" },
    }) |spec| {
        if (optionalString(evidence, spec[0])) |path| {
            try appendDeclaredExecutionEvidence(allocator, &declared, execution_root, path, spec[1], null);
        }
    }
    return declared;
}

const ExecutionTreeObservation = struct {
    common_projection_fingerprint: ?[]u8,
    exact_tree_fingerprint: []u8,
    output_carrier_fingerprint: []u8,

    fn deinit(self: ExecutionTreeObservation, allocator: std.mem.Allocator) void {
        if (self.common_projection_fingerprint) |fingerprint| allocator.free(fingerprint);
        allocator.free(self.exact_tree_fingerprint);
        allocator.free(self.output_carrier_fingerprint);
    }
};

fn observeExecutionTreeAlloc(
    allocator: std.mem.Allocator,
    execution_root: []const u8,
    baseline: ExecutionTreeSnapshot,
    materialization: TargetMaterialization,
    executor_result_text: []const u8,
    output_carrier_fingerprint: []const u8,
) !ExecutionTreeObservation {
    var observed = try captureExecutionTreeAlloc(allocator, execution_root);
    defer observed.deinit(allocator);
    var declared = try declaredExecutionEvidenceAlloc(allocator, execution_root, executor_result_text);
    defer deinitDeclaredExecutionEvidence(allocator, &declared);

    try verifyExecutionTreeTransition(baseline, observed, &declared);
    const common_projection_fingerprint = try rehashRegisteredCommonProjectionAlloc(
        allocator,
        execution_root,
        materialization,
    );
    errdefer if (common_projection_fingerprint) |fingerprint| allocator.free(fingerprint);
    return .{
        .common_projection_fingerprint = common_projection_fingerprint,
        .exact_tree_fingerprint = try observed.fingerprintAlloc(allocator),
        .output_carrier_fingerprint = try allocator.dupe(u8, output_carrier_fingerprint),
    };
}

fn verifyExecutionTreeTransition(
    baseline: ExecutionTreeSnapshot,
    observed: ExecutionTreeSnapshot,
    declared: *std.ArrayList(DeclaredExecutionEvidence),
) !void {
    if (baseline.root_mode & 0o777 != observed.root_mode & 0o777) {
        return error.TargetCommonProjectionMutation;
    }
    for (baseline.entries) |before| {
        const after = observed.find(before.path) orelse return error.TargetCommonProjectionMutation;
        if (after.kind != before.kind or after.mode & 0o777 != before.mode & 0o777) {
            return error.TargetCommonProjectionMutation;
        }
        if (before.kind == .file and
            !std.mem.eql(u8, after.content_fingerprint orelse return error.TargetCommonProjectionMutation, before.content_fingerprint orelse return error.TargetCommonProjectionMutation))
        {
            return error.TargetCommonProjectionMutation;
        }
    }
    for (observed.entries) |after| {
        if (baseline.find(after.path) != null) continue;
        if (after.kind != .file) return error.TargetCommonProjectionMutation;
        var allowed = false;
        for (declared.items) |*expected| {
            if (!std.mem.eql(u8, after.path, expected.path)) continue;
            if (expected.seen) return error.TargetCommonProjectionMutation;
            if (expected.expected_fingerprint) |fingerprint| {
                if (!std.mem.eql(u8, after.content_fingerprint orelse return error.TargetCommonProjectionMutation, fingerprint)) {
                    return error.TargetCommonProjectionMutation;
                }
            }
            expected.seen = true;
            allowed = true;
            break;
        }
        if (!allowed) return error.TargetCommonProjectionMutation;
    }
    for (declared.items) |expected| {
        if (!expected.seen) return error.TargetCommonProjectionMutation;
    }
}

fn rehashRegisteredCommonProjectionAlloc(
    allocator: std.mem.Allocator,
    execution_root: []const u8,
    materialization: TargetMaterialization,
) !?[]u8 {
    const projection_bytes = materialization.common_projection_bytes orelse return null;
    const expected_fingerprint = materialization.common_projection_fingerprint orelse
        return error.TargetCommonProjectionMissing;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, projection_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const projection = try object(parsed.value);
    var observed: std.Io.Writer.Allocating = .init(allocator);
    errdefer observed.deinit();
    const writer = &observed.writer;
    try writer.writeAll("{\"schema\":\"hylo-target-common-projection/v1\",\"verifier\":");
    try std.json.Stringify.value(projection.get("verifier") orelse return error.TargetCommonProjectionInvalid, .{}, writer);
    try writer.writeAll(",\"baseline_revision\":");
    try std.json.Stringify.value(try requiredString(projection, "baseline_revision"), .{}, writer);
    try writer.writeAll(",\"excluded_roots\":");
    try std.json.Stringify.value(projection.get("excluded_roots") orelse return error.TargetCommonProjectionInvalid, .{}, writer);
    try writer.writeAll(",\"entries\":[");
    for ((try requiredArray(projection, "entries")).items, 0..) |entry_value, index| {
        const entry = try object(entry_value);
        const relative = try requiredString(entry, "path");
        const path = try std.fs.path.join(allocator, &.{ execution_root, relative });
        defer allocator.free(path);
        const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
        defer allocator.free(bytes);
        const content_fingerprint = try attestation.digestBytesAlloc(allocator, bytes);
        defer allocator.free(content_fingerprint);
        const expected_content_fingerprint = try requiredString(entry, "content_fingerprint");
        if (!std.mem.eql(u8, content_fingerprint, expected_content_fingerprint)) {
            return error.TargetCommonProjectionMutation;
        }
        const object_id = try requiredString(entry, "object_id");
        verifyGitBlobObjectId(allocator, object_id, bytes) catch
            return error.TargetCommonProjectionMutation;
        const stat = std.Io.Dir.cwd().statFile(defaultIo(), path, .{}) catch
            return error.TargetCommonProjectionMutation;
        const expected_mode: std.posix.mode_t = if (std.mem.eql(u8, try requiredString(entry, "mode"), "100755"))
            0o700
        else
            0o600;
        if (stat.permissions.toMode() & 0o777 != expected_mode) {
            return error.TargetCommonProjectionMutation;
        }
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(relative, .{}, writer);
        try writer.writeAll(",\"mode\":");
        try std.json.Stringify.value(try requiredString(entry, "mode"), .{}, writer);
        try writer.writeAll(",\"object_type\":\"blob\",\"object_id\":");
        try std.json.Stringify.value(object_id, .{}, writer);
        try writer.writeAll(",\"content_fingerprint\":");
        try std.json.Stringify.value(content_fingerprint, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    const observed_bytes = try observed.toOwnedSlice();
    defer allocator.free(observed_bytes);
    const observed_fingerprint = try digestJsonTextAlloc(allocator, observed_bytes);
    errdefer allocator.free(observed_fingerprint);
    if (!std.mem.eql(u8, observed_fingerprint, expected_fingerprint)) {
        return error.TargetCommonProjectionMutation;
    }
    try verifyExecutionTargetOverlay(allocator, execution_root, materialization);
    return observed_fingerprint;
}

fn verifyExecutionTargetOverlay(
    allocator: std.mem.Allocator,
    execution_root: []const u8,
    materialization: TargetMaterialization,
) !void {
    if (!materialization.present) return;
    const carrier = materialization.carrier_bytes orelse return error.TargetMaterializationMissing;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, carrier, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    for ((try requiredArray(try object(parsed.value), "files")).items) |file_value| {
        const file = try object(file_value);
        const path = try std.fs.path.join(allocator, &.{ execution_root, try requiredString(file, "path") });
        defer allocator.free(path);
        const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
        defer allocator.free(bytes);
        try requireBytesFingerprint(allocator, bytes, try requiredString(file, "content_fingerprint"));
        try verifyGitBlobObjectId(allocator, try requiredString(file, "object_id"), bytes);
    }
}

fn verifyTargetMaterialization(
    allocator: std.mem.Allocator,
    materialization: TargetMaterialization,
    execution_root: []const u8,
) !void {
    if (!materialization.present) return;
    const fingerprint = materialization.carrier_fingerprint orelse return error.TargetMaterializationMissing;
    try archiveFileAtPathLimited(
        allocator,
        materialization.workspace_ref,
        materialization.archive_ref,
        fingerprint,
        MaxTargetCarrierBytes,
    );
    const carrier = try durable_store.readRegularFileNoSymlink(allocator, materialization.archive_ref, MaxTargetCarrierBytes);
    defer allocator.free(carrier);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, carrier, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    for ((try requiredArray(try object(parsed.value), "files")).items) |file_value| {
        const file = try object(file_value);
        const path = try std.fs.path.join(allocator, &.{ materialization.package_root, try requiredString(file, "path") });
        defer allocator.free(path);
        const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
        defer allocator.free(bytes);
        try requireBytesFingerprint(allocator, bytes, try requiredString(file, "content_fingerprint"));
        try verifyGitBlobObjectId(allocator, try requiredString(file, "object_id"), bytes);
    }
    try verifyExecutionTargetOverlay(allocator, execution_root, materialization);
}

fn validateTargetRelativePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) {
        return error.TargetMaterializationPathInvalid;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.TargetMaterializationPathInvalid;
        }
    }
}

fn targetPathCoveredByRoots(path: []const u8, roots: std.json.Array) bool {
    for (roots.items) |root_value| {
        const root = string(root_value) catch continue;
        if (std.mem.eql(u8, path, root) or
            (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/')) return true;
    }
    return false;
}

fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |raw| raw,
        else => error.ExpectedString,
    };
}

fn verifyGitBlobObjectId(allocator: std.mem.Allocator, object_id: []const u8, bytes: []const u8) !void {
    const header = try std.fmt.allocPrint(allocator, "blob {d}\x00", .{bytes.len});
    defer allocator.free(header);
    if (object_id.len == 40) {
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(header);
        hasher.update(bytes);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, object_id)) return error.TargetMaterializationObjectMismatch;
    } else if (object_id.len == 64) {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(header);
        hasher.update(bytes);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, object_id)) return error.TargetMaterializationObjectMismatch;
    } else return error.TargetMaterializationObjectInvalid;
}

fn base64EncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(result, bytes);
    return result;
}

fn base64DecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.TargetMaterializationEncodingInvalid;
    const result = try allocator.alloc(u8, size);
    errdefer allocator.free(result);
    std.base64.standard.Decoder.decode(result, encoded) catch return error.TargetMaterializationEncodingInvalid;
    return result;
}

fn setTargetFileReadOnly(path: []const u8, mode: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(defaultIo(), path, .{ .allow_directory = false });
    defer file.close(defaultIo());
    try file.setPermissions(defaultIo(), .fromMode(if (std.mem.eql(u8, mode, "100755")) 0o500 else 0o400));
}

fn setProjectionFilePermissions(path: []const u8, mode: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(defaultIo(), path, .{ .allow_directory = false });
    defer file.close(defaultIo());
    try file.setPermissions(defaultIo(), .fromMode(if (std.mem.eql(u8, mode, "100755")) 0o700 else 0o600));
}

fn makeDirectoryTreeReadOnly(allocator: std.mem.Allocator, path: []const u8) !void {
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(defaultIo(), path, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(defaultIo(), path, .{ .iterate = true });
    defer dir.close(defaultIo());
    var iterator = dir.iterate();
    while (try iterator.next(defaultIo())) |entry| {
        if (entry.kind == .sym_link) return error.TargetMaterializationSymlinkForbidden;
        if (entry.kind != .directory) continue;
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        try makeDirectoryTreeReadOnly(allocator, child);
    }
    try dir.setPermissions(defaultIo(), .fromMode(0o500));
}

fn resolveFactorMaterializationAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    repo: []const u8,
    workspace_ref: []const u8,
    archive_ref: []const u8,
) !FactorMaterialization {
    const factor = try requiredObject(view.trial, "factor");
    const kind = try requiredString(factor, "kind");
    const ref = try requiredString(view.arm, "materialization_ref");
    const prefix = "git-blob-json:";
    if (std.mem.eql(u8, kind, "target_snapshot") or
        (std.mem.eql(u8, kind, "null") and !std.mem.startsWith(u8, ref, prefix)))
    {
        return .{
            .present = false,
            .ref = "",
            .fingerprint = "",
            .canonical_bytes = null,
            .workspace_ref = workspace_ref,
            .archive_ref = archive_ref,
        };
    }
    if (!std.mem.eql(u8, kind, "null") and !oneOf(kind, &.{
        "instruction_bundle",
        "evidence_set",
        "environment_variant",
        "model_configuration",
        "tool_policy",
    })) return error.FactorKindUnsupported;

    if (!std.mem.startsWith(u8, ref, prefix)) return error.FactorMaterializationReferenceUnsupported;
    const object_id = ref[prefix.len..];
    if ((object_id.len != 40 and object_id.len != 64) or !isLowerHex(object_id)) {
        return error.FactorMaterializationReferenceUnsupported;
    }
    const object_type_raw = try runGitStdoutAlloc(allocator, repo, &.{ "cat-file", "-t", object_id });
    defer allocator.free(object_type_raw);
    if (!std.mem.eql(u8, std.mem.trim(u8, object_type_raw, " \t\r\n"), "blob")) {
        return error.FactorMaterializationObjectInvalid;
    }
    const blob = try runGitStdoutAlloc(allocator, repo, &.{ "cat-file", "blob", object_id });
    defer allocator.free(blob);
    const canonical = canonicalJsonTextAlloc(allocator, blob) catch return error.FactorMaterializationJsonInvalid;
    errdefer allocator.free(canonical);
    const fingerprint = try requiredString(view.arm, "materialization_fingerprint");
    requireBytesFingerprint(allocator, canonical, fingerprint) catch return error.FactorMaterializationFingerprintMismatch;
    return .{
        .present = true,
        .ref = ref,
        .fingerprint = fingerprint,
        .canonical_bytes = canonical,
        .workspace_ref = workspace_ref,
        .archive_ref = archive_ref,
    };
}

fn persistFactorMaterialization(
    allocator: std.mem.Allocator,
    materialization: FactorMaterialization,
) !void {
    if (!materialization.present) return;
    const canonical = materialization.canonical_bytes orelse return error.FactorMaterializationMissing;
    try archiveBytesAtPath(allocator, canonical, materialization.workspace_ref, materialization.fingerprint);
    try archiveBytesAtPath(allocator, canonical, materialization.archive_ref, materialization.fingerprint);
}

fn runGitStdoutAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    args: []const []const u8,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    const process_allocator = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = process_allocator;
    const result = std.process.run(process_allocator, threaded.io(), .{
        .argv = argv.items,
        .cwd = .{ .path = repo },
        .stdout_limit = .limited(MaxInputBytes),
        .stderr_limit = .limited(MaxInputBytes),
    }) catch return error.FactorMaterializationUnavailable;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    if (processExitCode(result.term) != 0) {
        return error.FactorMaterializationUnavailable;
    }
    return allocator.dupe(u8, result.stdout);
}

fn isLowerHex(raw: []const u8) bool {
    for (raw) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn buildExecutorRequestAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    workspace: []const u8,
    decision_context_path: []const u8,
    input_path: []const u8,
    input_fingerprint: []const u8,
    lease_digest: []const u8,
    factor_materialization: FactorMaterialization,
    target_materialization: TargetMaterialization,
) ![]u8 {
    const factor = try requiredObject(view.trial, "factor");
    const allowed_roots = try canonicalFieldAlloc(
        allocator,
        factor.get("allowed_difference_roots") orelse return error.AllowedRootsMissing,
    );
    defer allocator.free(allowed_roots);
    const source_profile = try object(view.source_profile);
    const historical = std.mem.eql(
        u8,
        try requiredString(source_profile, "kind"),
        "historical_decision",
    );
    const source_episode_value: std.json.Value = if (historical) blk: {
        const governance_root = try requiredObject(source_profile, "source_governance");
        const governance = if (governance_root.get("source_governance_gate")) |wrapped|
            try object(wrapped)
        else
            governance_root;
        break :blk .{ .string = try requiredString(governance, "source_episode_id") };
    } else .null;
    const source_episode_id = try canonicalFieldAlloc(
        allocator,
        source_episode_value,
    );
    defer allocator.free(source_episode_id);
    const identity = try sourceIdentity(view);
    const source_episode_fingerprint = try canonicalFieldAlloc(
        allocator,
        if (identity) |source| std.json.Value{ .string = source.episode_fingerprint } else .null,
    );
    defer allocator.free(source_episode_fingerprint);
    const source_profile_fingerprint = try canonicalFieldAlloc(
        allocator,
        if (identity) |source| std.json.Value{ .string = source.profile_fingerprint } else .null,
    );
    defer allocator.free(source_profile_fingerprint);
    const decision_context_ref = try canonicalFieldAlloc(
        allocator,
        if (historical) std.json.Value{ .string = decision_context_path } else .null,
    );
    defer allocator.free(decision_context_ref);
    const decision_context_fingerprint = try canonicalFieldAlloc(
        allocator,
        if (historical)
            source_profile.get("decision_context_fingerprint") orelse return error.DecisionContextFingerprintMismatch
        else
            .null,
    );
    defer allocator.free(decision_context_fingerprint);
    const factor_ref = try canonicalFieldAlloc(
        allocator,
        if (factor_materialization.present)
            std.json.Value{ .string = factor_materialization.ref }
        else
            .null,
    );
    defer allocator.free(factor_ref);
    const factor_fingerprint = try canonicalFieldAlloc(
        allocator,
        if (factor_materialization.present)
            std.json.Value{ .string = factor_materialization.fingerprint }
        else
            .null,
    );
    defer allocator.free(factor_fingerprint);
    const factor_archive_ref = try canonicalFieldAlloc(
        allocator,
        if (factor_materialization.present)
            std.json.Value{ .string = factor_materialization.workspace_ref }
        else
            .null,
    );
    defer allocator.free(factor_archive_ref);
    const target_materialization_ref = if (target_materialization.present)
        target_materialization.workspace_ref
    else if (factor_materialization.present)
        factor_materialization.workspace_ref
    else
        try requiredString(view.arm, "materialization_ref");
    const target_package_ref = try canonicalFieldAlloc(
        allocator,
        if (target_materialization.present)
            std.json.Value{ .string = target_materialization.package_root }
        else
            .null,
    );
    defer allocator.free(target_package_ref);
    const target_carrier_fingerprint = try canonicalFieldAlloc(
        allocator,
        if (target_materialization.carrier_fingerprint) |fingerprint|
            std.json.Value{ .string = fingerprint }
        else
            .null,
    );
    defer allocator.free(target_carrier_fingerprint);
    const common_projection_fingerprint = try canonicalFieldAlloc(
        allocator,
        if (target_materialization.common_projection_fingerprint) |fingerprint|
            std.json.Value{ .string = fingerprint }
        else
            .null,
    );
    defer allocator.free(common_projection_fingerprint);
    const snapshot_fingerprint = target_materialization.snapshot_fingerprint orelse
        return error.TargetMaterializationClaimMismatch;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try writeStringMember(writer, "schema", "cas-trial-executor-request/v1", true);
    try writeStringMember(writer, "trial_id", view.trial_id, true);
    try writeStringMember(writer, "unit_id", view.unit_id, true);
    try writeStringMember(writer, "scenario_id", view.scenario_id, true);
    try writeStringMember(writer, "pair_id", view.pair_id, true);
    try writeStringMember(writer, "lane_id", view.lane_id, true);
    try writeStringMember(writer, "opaque_arm_id", view.arm_id, true);
    try writeRawMember(writer, "source_episode_id", source_episode_id, true);
    try writeRawMember(writer, "source_episode_fingerprint", source_episode_fingerprint, true);
    try writeRawMember(writer, "source_profile_fingerprint", source_profile_fingerprint, true);
    try writeRawMember(writer, "decision_context_ref", decision_context_ref, true);
    try writeRawMember(writer, "decision_context_fingerprint", decision_context_fingerprint, true);
    try writeStringMember(writer, "workspace", workspace, true);
    try writeRawMember(writer, "common_projection_fingerprint", common_projection_fingerprint, true);
    try writeStringMember(writer, "presented_input_ref", input_path, true);
    try writeStringMember(writer, "presented_input_fingerprint", input_fingerprint, true);
    try writeStringMember(writer, "arm_value_fingerprint", target_materialization.arm_value_fingerprint orelse return error.TargetMaterializationClaimMismatch, true);
    try writeStringMember(writer, "target_materialization_ref", target_materialization_ref, true);
    try writeRawMember(writer, "target_materialization_package_ref", target_package_ref, true);
    try writeRawMember(writer, "target_materialization_carrier_fingerprint", target_carrier_fingerprint, true);
    try writeStringMember(writer, "target_snapshot_fingerprint", snapshot_fingerprint, true);
    try writeStringMember(writer, "workspace_target_snapshot_fingerprint", snapshot_fingerprint, true);
    try writeRawMember(writer, "factor_materialization_ref", factor_ref, true);
    try writeRawMember(writer, "factor_materialization_fingerprint", factor_fingerprint, true);
    try writeRawMember(writer, "factor_materialization_archive_ref", factor_archive_ref, true);
    try writeRawMember(writer, "allowed_difference_roots", allowed_roots, true);
    try writeStringMember(writer, "runner_contract_fingerprint", try requiredString(view.execution, "runner_contract_fingerprint"), true);
    try writeStringMember(writer, "environment_fingerprint", try requiredString(view.execution, "environment_fingerprint"), true);
    try writeStringMember(writer, "replay_policy_fingerprint", try requiredString(view.execution, "replay_policy_fingerprint"), true);
    try writeStringMember(writer, "effect_policy_fingerprint", try requiredString(view.execution, "effect_policy_fingerprint"), true);
    try writeStringMember(writer, "model_configuration_fingerprint", try requiredString(view.execution, "model_policy_fingerprint"), true);
    try writer.print("\"maximum_lane_duration_ms\":{d},", .{try requiredU64(view.execution, "maximum_lane_duration_ms")});
    try writer.print("\"maximum_tokens_per_lane\":{d},", .{try requiredU64(view.execution, "maximum_tokens_per_lane")});
    try writeStringMember(writer, "lane_lease_digest", lease_digest, true);
    try writer.writeAll("\"hidden_reference_presented\":false,\"sibling_output_presented\":false}\n");
    return out.toOwnedSlice();
}

const ExecutorTermination = enum { exited, signaled, other };

const ExecutorRun = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    termination: ExecutorTermination,
};

const ExecutorPipe = struct {
    read_fd: ?std.posix.fd_t,
    write_fd: ?std.posix.fd_t,

    fn init() !ExecutorPipe {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.ExecutorPipeCreateFailed;
        var pipe = ExecutorPipe{ .read_fd = fds[0], .write_fd = fds[1] };
        errdefer pipe.deinit();
        if (fds[0] <= std.posix.STDERR_FILENO or fds[1] <= std.posix.STDERR_FILENO) {
            return error.ExecutorFdContainmentFailed;
        }
        try setFdCloseOnExec(fds[0]);
        try setFdCloseOnExec(fds[1]);
        try setFdNonBlocking(fds[0]);
        return pipe;
    }

    fn closeRead(self: *ExecutorPipe) void {
        if (self.read_fd) |fd| closeRawFd(fd);
        self.read_fd = null;
    }

    fn closeWrite(self: *ExecutorPipe) void {
        if (self.write_fd) |fd| closeRawFd(fd);
        self.write_fd = null;
    }

    fn deinit(self: *ExecutorPipe) void {
        self.closeRead();
        self.closeWrite();
    }
};

const ExecutorCaptureCarrier = struct {
    file: std.Io.File,
    device: std.c.dev_t,
    inode: std.c.ino_t,

    fn reserve(path: []const u8) !ExecutorCaptureCarrier {
        try durable_store.ensureDirectoryPathNoSymlinks(std.fs.path.dirname(path) orelse return error.InvalidPath);
        const file = try std.Io.Dir.cwd().createFile(defaultIo(), path, .{
            .exclusive = true,
            .read = true,
            .truncate = false,
            .permissions = .fromMode(0o600),
        });
        errdefer file.close(defaultIo());
        try file.setPermissions(defaultIo(), .fromMode(0o600));
        try file.sync(defaultIo());
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(file.handle, &stat) != 0 or !std.c.S.ISREG(stat.mode)) {
            return error.ExecutorOutputCarrierDrift;
        }
        return .{ .file = file, .device = stat.dev, .inode = stat.ino };
    }

    fn persist(self: *const ExecutorCaptureCarrier, path: []const u8, bytes: []const u8) !void {
        try self.file.setLength(defaultIo(), 0);
        try self.file.writePositionalAll(defaultIo(), bytes, 0);
        try self.file.setLength(defaultIo(), bytes.len);
        try self.file.setPermissions(defaultIo(), .fromMode(0o600));
        try self.file.sync(defaultIo());
        durable_store.rejectSymlinkComponents(path) catch return error.ExecutorOutputCarrierDrift;
        const reopened = std.Io.Dir.openFileAbsolute(defaultIo(), path, .{
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch return error.ExecutorOutputCarrierDrift;
        defer reopened.close(defaultIo());
        const reopened_stat = reopened.stat(defaultIo()) catch return error.ExecutorOutputCarrierDrift;
        var native_reopened: std.c.Stat = undefined;
        if (std.c.fstat(reopened.handle, &native_reopened) != 0 or
            reopened_stat.kind != .file or
            native_reopened.dev != self.device or
            native_reopened.ino != self.inode or
            reopened_stat.size != bytes.len or
            reopened_stat.permissions.toMode() & 0o777 != 0o600)
        {
            return error.ExecutorOutputCarrierDrift;
        }
    }

    fn deinit(self: *ExecutorCaptureCarrier) void {
        self.file.close(defaultIo());
    }
};

fn persistExecutorCaptureCarrier(
    carrier: *const ExecutorCaptureCarrier,
    path: []const u8,
    bytes: []const u8,
) !void {
    carrier.persist(path, bytes) catch |err| switch (err) {
        error.ExecutorOutputCarrierDrift => return err,
        else => return error.ExecutorOutputCaptureFailed,
    };
}

const ExecutorCaptureFailure = enum {
    none,
    timed_out,
    stdout_limit,
    stderr_limit,
    both_limits,
    capture_failed,
    wait_failed,
    process_group_failed,
};

const ExecutorSupervision = struct {
    stdout: []u8,
    stderr: []u8,
    status: c_int,
    failure: ExecutorCaptureFailure,

    fn deinit(self: ExecutorSupervision, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn closeRawFd(fd: std.posix.fd_t) void {
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(defaultIo());
}

fn setFdCloseOnExec(fd: std.posix.fd_t) !void {
    const descriptor_flags = std.c.fcntl(fd, std.c.F.GETFD);
    if (descriptor_flags < 0 or
        std.c.fcntl(fd, std.c.F.SETFD, descriptor_flags | std.c.FD_CLOEXEC) < 0)
    {
        return error.ExecutorPipeConfigurationFailed;
    }
}

fn setFdNonBlocking(fd: std.posix.fd_t) !void {
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return error.ExecutorPipeConfigurationFailed;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = true;
    if (std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags))) < 0) {
        return error.ExecutorPipeConfigurationFailed;
    }
}

fn runExecutor(
    allocator: std.mem.Allocator,
    executor: []const u8,
    request: []const u8,
    result: []const u8,
    cwd: []const u8,
    maximum_duration_ms: u64,
) !ExecutorRun {
    const executable_store = try std.fs.path.resolve(allocator, &.{ cwd, ".executables" });
    defer allocator.free(executable_store);
    const binding = try bindExecutableInStoreAlloc(allocator, executor, executable_store);
    defer binding.deinit(allocator);
    return runExecutorWithTempRootAndLimit(
        allocator,
        &binding,
        request,
        result,
        cwd,
        cwd,
        maximum_duration_ms,
        MaxInputBytes,
    );
}

fn runExecutorWithTempRoot(
    allocator: std.mem.Allocator,
    executor: *const ExecutableBinding,
    request: []const u8,
    result: []const u8,
    cwd: []const u8,
    temporary_root: []const u8,
    maximum_duration_ms: u64,
) !ExecutorRun {
    return runExecutorWithTempRootAndLimit(
        allocator,
        executor,
        request,
        result,
        cwd,
        temporary_root,
        maximum_duration_ms,
        MaxInputBytes,
    );
}

fn runExecutorWithTempRootAndLimit(
    allocator: std.mem.Allocator,
    executor: *const ExecutableBinding,
    request: []const u8,
    result: []const u8,
    cwd: []const u8,
    temporary_root: []const u8,
    maximum_duration_ms: u64,
    output_limit: usize,
) !ExecutorRun {
    var environment = try sanitizedExecutorEnvironmentWithTempRoot(allocator, cwd, temporary_root);
    defer environment.deinit();
    if (comptime builtin.os.tag != .macos) return error.CasTrialRequiresMacOS;
    return runExecutorMacOS(
        allocator,
        executor,
        request,
        result,
        cwd,
        maximum_duration_ms,
        output_limit,
        &environment,
    );
}

fn runExecutorForTrial(
    allocator: std.mem.Allocator,
    executor: *const ExecutableBinding,
    request: []const u8,
    result: []const u8,
    cwd: []const u8,
    executor_output_root: []const u8,
    maximum_duration_ms: u64,
    output_limit: usize,
) !ExecutorRun {
    return runExecutorWithTempRootAndLimit(
        allocator,
        executor,
        request,
        result,
        cwd,
        executor_output_root,
        maximum_duration_ms,
        output_limit,
    );
}

fn runExecutorMacOS(
    allocator: std.mem.Allocator,
    executor: *const ExecutableBinding,
    request: []const u8,
    result: []const u8,
    cwd: []const u8,
    maximum_duration_ms: u64,
    output_limit: usize,
    environment: *const std.process.Environ.Map,
) !ExecutorRun {
    _ = std.math.cast(i64, maximum_duration_ms) orelse return error.ExecutionBudgetInvalid;
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFileActionsFailed;
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    var attributes: std.c.posix_spawnattr_t = undefined;
    if (std.c.posix_spawnattr_init(&attributes) != 0) return error.SpawnAttributesFailed;
    defer _ = std.c.posix_spawnattr_destroy(&attributes);
    if (DarwinSpawn.posix_spawnattr_setpgroup(&attributes, 0) != 0 or
        std.c.posix_spawnattr_setflags(&attributes, .{
            .SETPGROUP = true,
            .CLOEXEC_DEFAULT = true,
        }) != 0)
    {
        return error.SpawnAttributesFailed;
    }

    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);
    if (std.c.posix_spawn_file_actions_addchdir_np(&actions, cwd_z.ptr) != 0) return error.SpawnFileActionsFailed;
    const stdout_path = try std.fmt.allocPrint(allocator, "{s}.stdout", .{result});
    defer allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(allocator, "{s}.stderr", .{result});
    defer allocator.free(stderr_path);
    var stdout_carrier = try ExecutorCaptureCarrier.reserve(stdout_path);
    defer stdout_carrier.deinit();
    var stderr_carrier = try ExecutorCaptureCarrier.reserve(stderr_path);
    defer stderr_carrier.deinit();
    var stdout_pipe = try ExecutorPipe.init();
    defer stdout_pipe.deinit();
    var stderr_pipe = try ExecutorPipe.init();
    defer stderr_pipe.deinit();
    if (std.c.posix_spawn_file_actions_adddup2(&actions, stdout_pipe.write_fd.?, std.posix.STDOUT_FILENO) != 0 or
        std.c.posix_spawn_file_actions_adddup2(&actions, stderr_pipe.write_fd.?, std.posix.STDERR_FILENO) != 0 or
        std.c.posix_spawn_file_actions_addclose(&actions, stdout_pipe.read_fd.?) != 0 or
        std.c.posix_spawn_file_actions_addclose(&actions, stderr_pipe.read_fd.?) != 0 or
        std.c.posix_spawn_file_actions_addclose(&actions, stdout_pipe.write_fd.?) != 0 or
        std.c.posix_spawn_file_actions_addclose(&actions, stderr_pipe.write_fd.?) != 0 or
        std.c.posix_spawn_file_actions_addclose(&actions, std.posix.STDIN_FILENO) != 0)
    {
        return error.SpawnFileActionsFailed;
    }

    const raw_args = [_][]const u8{
        executor.origin_path,
        "--request",
        request,
        "--result",
        result,
    };
    var argv = try allocator.allocSentinel(?[*:0]const u8, raw_args.len, null);
    defer allocator.free(argv);
    var storage = try allocator.alloc([:0]u8, raw_args.len);
    var initialized: usize = 0;
    defer {
        for (storage[0..initialized]) |entry| allocator.free(entry);
        allocator.free(storage);
    }
    for (raw_args, 0..) |arg, index| {
        storage[index] = try allocator.dupeZ(u8, arg);
        initialized += 1;
        argv[index] = storage[index].ptr;
    }
    const environment_block = try environment.createPosixBlock(allocator, .{});
    defer environment_block.deinit(allocator);
    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(environment_block.slice.ptr);
    try validateExecutableAtSpawn(allocator, executor);
    const spawn_path_z = try allocator.dupeZ(u8, executor.spawn_path);
    defer allocator.free(spawn_path_z);
    const spawn_result = std.c.posix_spawn(&pid, spawn_path_z.ptr, &actions, &attributes, argv.ptr, envp);
    stdout_pipe.closeWrite();
    stderr_pipe.closeWrite();
    if (spawn_result != 0) {
        validateExecutableAtSpawn(allocator, executor) catch |stage_error| {
            try persistExecutorCaptureCarrier(&stdout_carrier, stdout_path, "");
            try persistExecutorCaptureCarrier(&stderr_carrier, stderr_path, "");
            return stage_error;
        };
        try persistExecutorCaptureCarrier(&stdout_carrier, stdout_path, "");
        try persistExecutorCaptureCarrier(&stderr_carrier, stderr_path, "");
        return classifySpawnError(spawn_result);
    }
    const supervision = try superviseExecutorProcessAlloc(
        allocator,
        pid,
        &stdout_pipe,
        &stderr_pipe,
        maximum_duration_ms,
        output_limit,
    );
    defer supervision.deinit(allocator);
    validateExecutableAtSpawn(allocator, executor) catch |stage_error| {
        try persistExecutorCaptureCarrier(&stdout_carrier, stdout_path, supervision.stdout);
        try persistExecutorCaptureCarrier(&stderr_carrier, stderr_path, supervision.stderr);
        return stage_error;
    };
    try persistExecutorCaptureCarrier(&stdout_carrier, stdout_path, supervision.stdout);
    try persistExecutorCaptureCarrier(&stderr_carrier, stderr_path, supervision.stderr);
    switch (supervision.failure) {
        .none => {},
        .timed_out => return error.ExecutorTimedOut,
        .stdout_limit => return error.ExecutorStdoutLimitExceeded,
        .stderr_limit => return error.ExecutorStderrLimitExceeded,
        .both_limits => return error.ExecutorOutputLimitExceeded,
        .capture_failed => return error.ExecutorOutputCaptureFailed,
        .wait_failed => return error.ExecutorWaitFailed,
        .process_group_failed => return error.ExecutorGroupKillFailed,
    }
    const encoded_status: u32 = @bitCast(supervision.status);
    return .{
        .stdout = try allocator.dupe(u8, supervision.stdout),
        .stderr = try allocator.dupe(u8, supervision.stderr),
        .exit_code = statusToExitCode(encoded_status),
        .termination = if (std.posix.W.IFEXITED(encoded_status))
            .exited
        else if (std.posix.W.IFSIGNALED(encoded_status))
            .signaled
        else
            .other,
    };
}

const DarwinSpawn = struct {
    extern "c" fn posix_spawnattr_setpgroup(
        attr: *std.c.posix_spawnattr_t,
        pgroup: std.c.pid_t,
    ) c_int;
};

fn drainExecutorPipe(
    allocator: std.mem.Allocator,
    pipe: *ExecutorPipe,
    bytes: *std.ArrayList(u8),
    limit: usize,
) !bool {
    const fd = pipe.read_fd orelse return false;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const count = std.c.read(fd, &buffer, buffer.len);
        switch (std.posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) {
                    pipe.closeRead();
                    return false;
                }
                const count_usize: usize = @intCast(count);
                const available = limit -| bytes.items.len;
                const retained = @min(available, count_usize);
                try bytes.appendSlice(allocator, buffer[0..retained]);
                return retained != count_usize;
            },
            .INTR => continue,
            .AGAIN => return false,
            else => {
                pipe.closeRead();
                return error.ExecutorOutputCaptureFailed;
            },
        }
    }
}

fn drainExecutorPipeToBoundary(
    allocator: std.mem.Allocator,
    pipe: *ExecutorPipe,
    bytes: *std.ArrayList(u8),
    limit: usize,
) !bool {
    var overflow = false;
    var reads: usize = 0;
    while (pipe.read_fd != null and reads < 256) : (reads += 1) {
        const before = bytes.items.len;
        const read_overflow = try drainExecutorPipe(allocator, pipe, bytes, limit);
        overflow = read_overflow or overflow;
        if (pipe.read_fd == null) break;
        // No retained progress without overflow means the nonblocking pipe is
        // empty but still has a writer. Overflow can retain zero bytes while
        // still consuming pipe data, so continue for a bounded number of reads
        // to give a terminated writer's pipe a chance to reach EOF.
        if (!read_overflow and bytes.items.len == before) break;
    }
    return overflow;
}

fn superviseExecutorProcessAlloc(
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
    stdout_pipe: *ExecutorPipe,
    stderr_pipe: *ExecutorPipe,
    maximum_duration_ms: u64,
    output_limit: usize,
) !ExecutorSupervision {
    const duration_ms: i64 = std.math.cast(i64, maximum_duration_ms) orelse return error.ExecutionBudgetInvalid;
    const deadline = std.Io.Clock.awake.now(defaultIo()).addDuration(.fromMilliseconds(duration_ms));
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var stdout_overflow = false;
    var stderr_overflow = false;
    var status: c_int = 0;
    var failure: ExecutorCaptureFailure = .none;
    var child_reaped = false;
    var residual_group_terminated = false;
    var post_reap_deadline: ?@TypeOf(deadline) = null;
    while (true) {
        stdout_overflow = (drainExecutorPipe(allocator, stdout_pipe, &stdout, output_limit) catch blk: {
            failure = .capture_failed;
            break :blk false;
        }) or stdout_overflow;
        stderr_overflow = (drainExecutorPipe(allocator, stderr_pipe, &stderr, output_limit) catch blk: {
            failure = .capture_failed;
            break :blk false;
        }) or stderr_overflow;
        if (failure == .none and (stdout_overflow or stderr_overflow)) {
            failure = if (stdout_overflow and stderr_overflow)
                .both_limits
            else if (stdout_overflow)
                .stdout_limit
            else
                .stderr_limit;
        }

        if (!child_reaped) {
            const wait_result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
            switch (std.posix.errno(wait_result)) {
                .SUCCESS => {
                    if (wait_result == pid) child_reaped = true;
                },
                .INTR => {},
                else => failure = .wait_failed,
            }
        }

        const now = std.Io.Clock.awake.now(defaultIo());
        const deadline_reached = now.nanoseconds >= deadline.nanoseconds;
        if (failure == .none and deadline_reached and !child_reaped) failure = .timed_out;
        if (failure != .none and !child_reaped) {
            proveExecutorTerminationAfterFailure(allocator, pid) catch
                return error.ExecutorLivenessUnproved;
            child_reaped = true;
            residual_group_terminated = true;
        } else if (child_reaped and !residual_group_terminated) {
            proveResidualExecutorGroupQuiescent(allocator, pid) catch
                return error.ExecutorLivenessUnproved;
            residual_group_terminated = true;
        }
        if (child_reaped and post_reap_deadline == null) {
            post_reap_deadline = std.Io.Clock.awake.now(defaultIo()).addDuration(
                .fromMilliseconds(ExecutorPostReapDrainGraceMs),
            );
        }

        if (child_reaped and stdout_pipe.read_fd == null and stderr_pipe.read_fd == null) break;
        const post_reap_grace_reached = if (post_reap_deadline) |grace|
            std.Io.Clock.awake.now(defaultIo()).nanoseconds >= grace.nanoseconds
        else
            false;
        if (child_reaped and (deadline_reached or post_reap_grace_reached)) {
            stdout_overflow = (drainExecutorPipeToBoundary(
                allocator,
                stdout_pipe,
                &stdout,
                output_limit,
            ) catch blk: {
                failure = .capture_failed;
                break :blk false;
            }) or stdout_overflow;
            stderr_overflow = (drainExecutorPipeToBoundary(
                allocator,
                stderr_pipe,
                &stderr,
                output_limit,
            ) catch blk: {
                failure = .capture_failed;
                break :blk false;
            }) or stderr_overflow;
            if (stdout_pipe.read_fd != null or stderr_pipe.read_fd != null) {
                stdout_pipe.closeRead();
                stderr_pipe.closeRead();
                return error.ExecutorLivenessUnproved;
            }
            if (failure == .none and (stdout_overflow or stderr_overflow)) {
                failure = if (stdout_overflow and stderr_overflow)
                    .both_limits
                else if (stdout_overflow)
                    .stdout_limit
                else
                    .stderr_limit;
            }
            break;
        }

        var poll_fds = [_]std.c.pollfd{
            .{
                .fd = stdout_pipe.read_fd orelse -1,
                .events = @intCast(std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR),
                .revents = 0,
            },
            .{
                .fd = stderr_pipe.read_fd orelse -1,
                .events = @intCast(std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR),
                .revents = 0,
            },
        };
        const poll_result = std.c.poll(&poll_fds, poll_fds.len, @intCast(ExecutorPollIntervalMs));
        switch (std.posix.errno(poll_result)) {
            .SUCCESS, .INTR => {},
            else => failure = .capture_failed,
        }
        if (poll_fds[0].revents & std.c.POLL.NVAL != 0) {
            stdout_pipe.closeRead();
            failure = .capture_failed;
        }
        if (poll_fds[1].revents & std.c.POLL.NVAL != 0) {
            stderr_pipe.closeRead();
            failure = .capture_failed;
        }
    }
    const stdout_owned = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_owned);
    const stderr_owned = try stderr.toOwnedSlice(allocator);
    return .{
        .stdout = stdout_owned,
        .stderr = stderr_owned,
        .status = status,
        .failure = failure,
    };
}

const ExecutorTerminationFault = enum {
    none,
    group_stop_permission_denied,
};

const ExecutorTerminationProbe = struct {
    descendant_census_attempted: bool = false,
};

fn terminateAndReapExecutorGroup(allocator: std.mem.Allocator, pid: std.posix.pid_t) !void {
    return terminateAndReapExecutorGroupWithFault(allocator, pid, .none, null);
}

fn terminateAndReapExecutorGroupWithFault(
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
    fault: ExecutorTerminationFault,
    probe: ?*ExecutorTerminationProbe,
) !void {
    const stop_result = std.posix.system.kill(pid, .STOP);
    const direct_stop_succeeded = std.posix.errno(stop_result) == .SUCCESS;
    const group_stop_errno: std.posix.E = if (fault == .group_stop_permission_denied)
        .PERM
    else
        std.posix.errno(std.posix.system.kill(-pid, .STOP));
    const group_stop_succeeded = group_stop_errno == .SUCCESS;
    // STOP narrows the descendant-enumeration race, but it is preparatory: a
    // denial must not suppress mandatory kill, direct-child reap, and terminal
    // group-quiescence proof.
    var descendants: std.ArrayList(std.posix.pid_t) = .empty;
    defer descendants.deinit(allocator);
    if (direct_stop_succeeded and group_stop_succeeded) {
        if (probe) |termination_probe| termination_probe.descendant_census_attempted = true;
        collectDarwinDescendants(allocator, pid, &descendants, 0) catch {};
    }

    // Group and direct KILL are both attempted. Their syscall results are not
    // terminal observations; the bounded reap-and-quiescence proof below is.
    _ = std.posix.system.kill(-pid, .KILL);
    _ = std.posix.system.kill(pid, .KILL);
    var descendant_kill_failed = false;
    var descendant_index = descendants.items.len;
    while (descendant_index != 0) {
        descendant_index -= 1;
        const descendant_result = std.posix.system.kill(descendants.items[descendant_index], .KILL);
        switch (std.posix.errno(descendant_result)) {
            .SUCCESS, .SRCH => {},
            else => descendant_kill_failed = true,
        }
    }
    try waitExecutorChildReapedAndGroupQuiescent(allocator, pid);
    if (descendant_kill_failed) return error.ExecutorGroupKillFailed;
}

const ExecutorGroupObservation = enum {
    absent,
    terminal_zombies_only,
    live_members,
};

fn observeExecutorGroupAlloc(
    allocator: std.mem.Allocator,
    process_group_id: std.posix.pid_t,
) !ExecutorGroupObservation {
    std.c._errno().* = 0;
    const capacity_result = proc_listpgrppids(process_group_id, null, 0);
    if (capacity_result <= 0 or std.c._errno().* != 0) {
        return error.ExecutorProcessInspectionFailed;
    }
    const capacity: usize = @intCast(capacity_result);
    if (capacity > MaxExecutorGroupCensusPids) {
        return error.ExecutorProcessInspectionFailed;
    }
    const pids = try allocator.alloc(std.posix.pid_t, capacity);
    defer allocator.free(pids);
    const buffer_size = std.math.cast(c_int, std.math.mul(usize, capacity, @sizeOf(std.posix.pid_t)) catch
        return error.ExecutorProcessInspectionFailed) orelse
        return error.ExecutorProcessInspectionFailed;

    std.c._errno().* = 0;
    const count_result = proc_listpgrppids(process_group_id, pids.ptr, buffer_size);
    if (count_result < 0 or std.c._errno().* != 0) {
        return error.ExecutorProcessInspectionFailed;
    }
    const count: usize = @intCast(count_result);
    if (count > capacity or count == capacity) {
        return error.ExecutorProcessInspectionFailed;
    }
    if (count == 0) return .absent;

    for (pids[0..count]) |listed_pid| {
        if (listed_pid <= 0) return error.ExecutorProcessInspectionFailed;
        var process_info: DarwinProcessShortInfo = undefined;
        std.c._errno().* = 0;
        const info_size = proc_pidinfo(
            listed_pid,
            DarwinProcessShortInfoFlavor,
            1, // Search both the live and zombie process tables.
            &process_info,
            @sizeOf(DarwinProcessShortInfo),
        );
        if (info_size != @sizeOf(DarwinProcessShortInfo) or std.c._errno().* != 0) {
            return error.ExecutorProcessInspectionFailed;
        }
        if (process_info.pid != @as(u32, @intCast(listed_pid)) or
            process_info.process_group_id != @as(u32, @intCast(process_group_id)))
        {
            return error.ExecutorProcessInspectionFailed;
        }
        if (process_info.status != DarwinZombieProcessStatus) return .live_members;
    }
    return .terminal_zombies_only;
}

fn enforceExecutorGroupQuiescence(
    allocator: std.mem.Allocator,
    process_group_id: std.posix.pid_t,
) !bool {
    return switch (try observeExecutorGroupAlloc(allocator, process_group_id)) {
        .absent, .terminal_zombies_only => true,
        .live_members => blk: {
            // A shell can complete a fork after the first group-KILL snapshot.
            // Live members never satisfy the terminal observation: reissue the
            // group kill and require a later census to prove quiescence.
            try killExecutorGroup(process_group_id);
            break :blk false;
        },
    };
}

fn waitExecutorChildReapedAndGroupQuiescent(
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
) !void {
    const deadline = std.Io.Clock.awake.now(defaultIo()).addDuration(.fromMilliseconds(2_000));
    var child_reaped = false;
    var group_terminal = false;
    var child_wait_failed = false;
    var group_wait_failed = false;
    while (true) {
        if (!child_reaped) {
            var status: c_int = undefined;
            const wait_result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
            switch (std.posix.errno(wait_result)) {
                .SUCCESS => {
                    if (wait_result == pid) child_reaped = true;
                },
                .CHILD => child_reaped = true,
                .INTR => {},
                else => child_wait_failed = true,
            }
        }
        if (!group_terminal) {
            group_terminal = enforceExecutorGroupQuiescence(allocator, pid) catch blk: {
                group_wait_failed = true;
                break :blk false;
            };
        }
        if (child_reaped and group_terminal) return;
        if (std.Io.Clock.awake.now(defaultIo()).nanoseconds >= deadline.nanoseconds) {
            if (!child_reaped or child_wait_failed) return error.ExecutorWaitFailed;
            if (group_wait_failed) return error.ExecutorGroupWaitFailed;
            return error.ExecutorGroupStillAlive;
        }
        std.Io.sleep(defaultIo(), .fromMilliseconds(ExecutorPollIntervalMs), .awake) catch {};
    }
}

fn proveExecutorTerminationAfterFailure(allocator: std.mem.Allocator, pid: std.posix.pid_t) !void {
    const retry_deadline = std.Io.Clock.awake.now(defaultIo()).addDuration(.fromMilliseconds(2_000));
    while (true) {
        terminateAndReapExecutorGroup(allocator, pid) catch |termination_error| {
            if (termination_error == error.ExecutorGroupKillFailed) {
                return error.ExecutorLivenessUnproved;
            }
            if (std.Io.Clock.awake.now(defaultIo()).nanoseconds >= retry_deadline.nanoseconds) {
                return error.ExecutorLivenessUnproved;
            }
            std.Io.sleep(defaultIo(), .fromMilliseconds(ExecutorPollIntervalMs), .awake) catch {};
            continue;
        };
        return;
    }
}

fn collectDarwinDescendants(
    allocator: std.mem.Allocator,
    parent: std.posix.pid_t,
    descendants: *std.ArrayList(std.posix.pid_t),
    depth: usize,
) !void {
    if (depth >= 64) return error.ExecutorProcessTreeTooDeep;
    const parent_text = try std.fmt.allocPrint(allocator, "{d}", .{parent});
    defer allocator.free(parent_text);
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = &.{ "/usr/bin/pgrep", "-P", parent_text },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const exit_code = processExitCode(result.term);
    if (exit_code == 1) return;
    if (exit_code != 0) return error.ExecutorProcessInspectionFailed;
    var lines = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    while (lines.next()) |line| {
        const child = std.fmt.parseInt(std.posix.pid_t, line, 10) catch
            return error.ExecutorProcessInspectionFailed;
        const stop_result = std.posix.system.kill(child, .STOP);
        switch (std.posix.errno(stop_result)) {
            .SUCCESS => {},
            .SRCH => continue,
            else => return error.ExecutorProcessInspectionFailed,
        }
        try descendants.append(allocator, child);
        try collectDarwinDescendants(allocator, child, descendants, depth + 1);
    }
}

fn terminateResidualExecutorGroup(allocator: std.mem.Allocator, pid: std.posix.pid_t) !void {
    try killExecutorGroup(pid);
    try waitExecutorGroupQuiescent(allocator, pid);
}

fn proveResidualExecutorGroupQuiescent(allocator: std.mem.Allocator, pid: std.posix.pid_t) !void {
    const retry_deadline = std.Io.Clock.awake.now(defaultIo()).addDuration(.fromMilliseconds(2_000));
    while (true) {
        terminateResidualExecutorGroup(allocator, pid) catch {
            if (std.Io.Clock.awake.now(defaultIo()).nanoseconds >= retry_deadline.nanoseconds) {
                return error.ExecutorLivenessUnproved;
            }
            std.Io.sleep(defaultIo(), .fromMilliseconds(ExecutorPollIntervalMs), .awake) catch {};
            continue;
        };
        return;
    }
}

fn killExecutorGroup(pid: std.posix.pid_t) !void {
    const result = std.posix.system.kill(-pid, .KILL);
    switch (std.posix.errno(result)) {
        // A zombie-only Darwin process group can return PERM even though no
        // member can execute. The mandatory state observation below owns the
        // terminal decision and still rejects every live or unknown member.
        .SUCCESS, .SRCH, .PERM => {},
        else => return error.ExecutorGroupKillFailed,
    }
}

fn waitExecutorGroupQuiescent(allocator: std.mem.Allocator, pid: std.posix.pid_t) !void {
    const deadline = std.Io.Clock.awake.now(defaultIo()).addDuration(.fromMilliseconds(2_000));
    while (true) {
        if (enforceExecutorGroupQuiescence(allocator, pid) catch
            return error.ExecutorGroupWaitFailed) return;
        if (std.Io.Clock.awake.now(defaultIo()).nanoseconds >= deadline.nanoseconds) {
            return error.ExecutorGroupStillAlive;
        }
        std.Io.sleep(defaultIo(), .fromMilliseconds(ExecutorPollIntervalMs), .awake) catch {};
    }
}

fn sanitizedExecutorEnvironment(allocator: std.mem.Allocator, workspace: []const u8) !std.process.Environ.Map {
    return sanitizedExecutorEnvironmentWithTempRoot(allocator, workspace, workspace);
}

fn sanitizedExecutorEnvironmentWithTempRoot(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    temporary_root: []const u8,
) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(allocator);
    errdefer environment.deinit();
    const temporary = try std.fs.path.join(allocator, &.{ temporary_root, "tmp" });
    defer allocator.free(temporary);
    try durable_store.ensureDirectoryPathNoSymlinks(temporary);
    try environment.put("HOME", workspace);
    try environment.put("TMPDIR", temporary);
    try environment.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    try environment.put("LANG", "C");
    try environment.put("LC_ALL", "C");
    try environment.put("CAS_HCTP_ENVIRONMENT", "sanitized-v1");
    return environment;
}

fn classifySpawnError(code: c_int) anyerror {
    const spawn_errno: std.c.E = @enumFromInt(code);
    return switch (spawn_errno) {
        .ACCES => error.ExecutorSpawnAccessDenied,
        .NOENT => error.ExecutorNotFoundAtSpawn,
        .NOEXEC => error.ExecutorFormatInvalid,
        .NOMEM => error.ExecutorSpawnOutOfMemory,
        else => error.ExecutorSpawnFailed,
    };
}

fn statusToExitCode(status: u32) u8 {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    if (std.posix.W.IFSIGNALED(status)) {
        const signal: u32 = @intFromEnum(std.posix.W.TERMSIG(status));
        return @intCast(@min(@as(u32, 128) + signal, @as(u32, 255)));
    }
    return 1;
}

fn persistRunnerObservationAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    raw: []const u8,
) ![]u8 {
    const canonical = try canonicalJsonTextAlloc(allocator, raw);
    defer allocator.free(canonical);
    return persistExpectedSealedArtifactAlloc(allocator, path, canonical);
}

fn combinedRunnerLimitationsAlloc(
    allocator: std.mem.Allocator,
    executor_limitations: std.json.Array,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (executor_limitations.items, 0..) |limitation, index| {
        if (index != 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(try string(limitation), .{}, &out.writer);
    }
    if (executor_limitations.items.len != 0) try out.writer.writeByte(',');
    try std.json.Stringify.value(
        "CAS independently observes target and execution carriers plus process lifecycle; the attested executor mediates declared effects; hostile arbitrary native code is not OS-confined and can bypass that mediation",
        .{},
        &out.writer,
    );
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn createRunnerObservationsAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    paths: LanePaths,
    target_materialization: TargetMaterialization,
    target_package_observation: TargetPackageObservation,
    execution_tree_observed: ExecutionTreeObservation,
    executor_fingerprint: []const u8,
    runner_contract: RunnerContractValidation,
    executor_limitations: std.json.Array,
    reset_assertion: EvidenceFile,
    filesystem_assertion: EvidenceFile,
    network_assertion: EvidenceFile,
    external_effect_assertion: EvidenceFile,
) !RunnerObservationReceipts {
    const common_projection_observed = execution_tree_observed.common_projection_fingerprint;
    const assurance = try requiredString(try requiredObject(view.trial, "assurance"), "required_level");
    const sealed = std.mem.eql(u8, assurance, "sealed");
    const capability_identity = runner_contract.capability_seal;
    if (sealed != (capability_identity != null)) return error.CapabilitySealContractInvalid;

    const effect_policy_fingerprint = try requiredString(view.execution, "effect_policy_fingerprint");
    try validateFingerprint(effect_policy_fingerprint);
    const effect_policy_authenticated = target_materialization.effect_policy_fingerprint != null;
    if (target_materialization.effect_policy_fingerprint) |authenticated_policy| {
        if (!std.mem.eql(u8, authenticated_policy, effect_policy_fingerprint)) {
            return error.EffectPolicyFingerprintMismatch;
        }
    } else if (sealed) return error.EffectPolicyMissing;
    if (capability_identity) |identity| {
        if (!std.mem.eql(u8, identity.effect_policy_fingerprint, effect_policy_fingerprint)) {
            return error.EffectPolicyFingerprintMismatch;
        }
    }

    const expected_common = target_materialization.common_projection_fingerprint;
    if (expected_common) |expected| {
        const observed = common_projection_observed orelse return error.TargetCommonProjectionMutation;
        if (!std.mem.eql(u8, expected, observed)) return error.TargetCommonProjectionMutation;
    } else if (common_projection_observed != null) return error.TargetCommonProjectionMismatch;

    const target_package_observed =
        target_package_observation.before_fingerprint != null and
        target_package_observation.after_fingerprint != null;
    const target_package_unchanged = if (target_package_observation.before_fingerprint) |before|
        if (target_package_observation.after_fingerprint) |after| std.mem.eql(u8, before, after) else false
    else
        false;

    var reset: std.Io.Writer.Allocating = .init(allocator);
    defer reset.deinit();
    try reset.writer.writeByte('{');
    try writeStringMember(&reset.writer, "schema", "cas-reset-observation/v1", true);
    try writeStringMember(&reset.writer, "trial_id", view.trial_id, true);
    try writeStringMember(&reset.writer, "lane_id", view.lane_id, true);
    try writeStringMember(&reset.writer, "effect_policy_fingerprint", effect_policy_fingerprint, true);
    if (capability_identity) |identity| {
        try writeStringMember(&reset.writer, "capability_profile_id", identity.profile_id, true);
    }
    try writeStringMember(&reset.writer, "executor_assertion_ref", reset_assertion.ref, true);
    try writeStringMember(&reset.writer, "executor_assertion_fingerprint", reset_assertion.fingerprint, true);
    try reset.writer.writeAll("\"workspace\":{");
    try writeStringMember(&reset.writer, "ref", paths.workspace, true);
    try reset.writer.writeAll("\"absent_before_claim\":true,\"created_by_cas\":true,\"cwd_enforced\":true},\"process\":{");
    try writeStringMember(&reset.writer, "executor_binary_fingerprint", executor_fingerprint, true);
    try reset.writer.writeAll("\"fresh_process\":true,\"sanitized_environment\":true,\"standard_descriptors_only\":true,\"process_group_supervised\":true},\"thread\":{\"fresh_thread_independently_observed\":false,\"trusted_executor_claim_required\":true},\"target_cache\":{\"home_redirected\":true,\"temporary_directory_redirected\":true},\"capability_sealed\":");
    try reset.writer.writeAll(if (sealed) "true" else "false");
    try reset.writer.writeAll(",\"os_confinement\":false}");
    const reset_fingerprint = try persistRunnerObservationAlloc(allocator, paths.reset_observation, reset.written());
    errdefer allocator.free(reset_fingerprint);

    var filesystem: std.Io.Writer.Allocating = .init(allocator);
    defer filesystem.deinit();
    try filesystem.writer.writeByte('{');
    try writeStringMember(&filesystem.writer, "schema", "cas-filesystem-observation/v1", true);
    try writeStringMember(&filesystem.writer, "trial_id", view.trial_id, true);
    try writeStringMember(&filesystem.writer, "lane_id", view.lane_id, true);
    try writeStringMember(&filesystem.writer, "effect_policy_fingerprint", effect_policy_fingerprint, true);
    try writeStringMember(&filesystem.writer, "policy", "workspace_write", true);
    try writeStringMember(&filesystem.writer, "mediation_owner", "attested-executor", true);
    try writeStringMember(&filesystem.writer, "default_effect_decision", "deny", true);
    try writeStringMember(&filesystem.writer, "executor_assertion_ref", filesystem_assertion.ref, true);
    try writeStringMember(&filesystem.writer, "executor_assertion_fingerprint", filesystem_assertion.fingerprint, true);
    try filesystem.writer.writeAll("\"registered_policy_authenticated\":");
    try filesystem.writer.writeAll(if (effect_policy_authenticated) "true" else "false");
    try filesystem.writer.writeAll(",\"independently_enforced\":false,\"outside_workspace_write_denied\":false,\"evidence_refs_confined_to_workspace\":true,\"common_projection\":{");
    try writeOptionalStringMember(&filesystem.writer, "expected_fingerprint", expected_common, true);
    try writeOptionalStringMember(&filesystem.writer, "observed_fingerprint", common_projection_observed, true);
    try filesystem.writer.writeAll("\"post_execution_rehash\":true,\"match\":true},\"target_package\":{");
    try writeOptionalStringMember(&filesystem.writer, "before_fingerprint", target_package_observation.before_fingerprint, true);
    try writeOptionalStringMember(&filesystem.writer, "after_fingerprint", target_package_observation.after_fingerprint, true);
    try filesystem.writer.writeAll("\"observed\":");
    try filesystem.writer.writeAll(if (target_package_observed) "true" else "false");
    try filesystem.writer.writeAll(",\"match\":");
    try filesystem.writer.writeAll(if (target_package_unchanged) "true" else "false");
    try filesystem.writer.writeAll("},\"execution_tree\":{");
    try writeStringMember(&filesystem.writer, "enumeration", "no-follow/v1", true);
    try writeStringMember(&filesystem.writer, "addition_policy", "fixed-executor-evidence-paths/v1", true);
    try writeStringMember(&filesystem.writer, "observed_fingerprint", execution_tree_observed.exact_tree_fingerprint, true);
    try writeStringMember(&filesystem.writer, "output_carrier_fingerprint", execution_tree_observed.output_carrier_fingerprint, true);
    try filesystem.writer.writeAll("\"match\":true},\"os_confinement\":false}");
    const filesystem_fingerprint = try persistRunnerObservationAlloc(allocator, paths.filesystem_observation, filesystem.written());
    errdefer allocator.free(filesystem_fingerprint);

    var network: std.Io.Writer.Allocating = .init(allocator);
    defer network.deinit();
    try network.writer.writeByte('{');
    try writeStringMember(&network.writer, "schema", "cas-network-observation/v1", true);
    try writeStringMember(&network.writer, "trial_id", view.trial_id, true);
    try writeStringMember(&network.writer, "lane_id", view.lane_id, true);
    try writeStringMember(&network.writer, "effect_policy_fingerprint", effect_policy_fingerprint, true);
    try writeStringMember(&network.writer, "policy", "deny", true);
    try writeStringMember(&network.writer, "mediation_owner", "attested-executor", true);
    try writeStringMember(&network.writer, "default_effect_decision", "deny", true);
    try writeStringMember(&network.writer, "executor_assertion_ref", network_assertion.ref, true);
    try writeStringMember(&network.writer, "executor_assertion_fingerprint", network_assertion.fingerprint, true);
    try network.writer.writeAll("\"registered_policy_authenticated\":");
    try network.writer.writeAll(if (effect_policy_authenticated) "true" else "false");
    try network.writer.writeAll(",\"independently_enforced\":false,\"host_network_isolated\":false,\"os_confinement\":false}");
    const network_fingerprint = try persistRunnerObservationAlloc(allocator, paths.network_observation, network.written());
    errdefer allocator.free(network_fingerprint);

    var external_effect: std.Io.Writer.Allocating = .init(allocator);
    defer external_effect.deinit();
    try external_effect.writer.writeByte('{');
    try writeStringMember(&external_effect.writer, "schema", "cas-external-effect-observation/v1", true);
    try writeStringMember(&external_effect.writer, "trial_id", view.trial_id, true);
    try writeStringMember(&external_effect.writer, "lane_id", view.lane_id, true);
    try writeStringMember(&external_effect.writer, "effect_policy_fingerprint", effect_policy_fingerprint, true);
    try writeStringMember(&external_effect.writer, "policy", "deny", true);
    try writeStringMember(&external_effect.writer, "mediation_owner", "attested-executor", true);
    try writeStringMember(&external_effect.writer, "default_effect_decision", "deny", true);
    try writeStringMember(&external_effect.writer, "executor_assertion_ref", external_effect_assertion.ref, true);
    try writeStringMember(&external_effect.writer, "executor_assertion_fingerprint", external_effect_assertion.fingerprint, true);
    try external_effect.writer.writeAll("\"registered_policy_authenticated\":");
    try external_effect.writer.writeAll(if (effect_policy_authenticated) "true" else "false");
    try external_effect.writer.writeAll(",\"independently_enforced\":false,\"direct_native_effects_intercepted\":false,\"os_confinement\":false}");
    const external_effect_fingerprint = try persistRunnerObservationAlloc(
        allocator,
        paths.external_effect_observation,
        external_effect.written(),
    );
    errdefer allocator.free(external_effect_fingerprint);

    return .{
        .reset_fingerprint = reset_fingerprint,
        .filesystem_fingerprint = filesystem_fingerprint,
        .network_fingerprint = network_fingerprint,
        .external_effect_fingerprint = external_effect_fingerprint,
        .limitations = try combinedRunnerLimitationsAlloc(allocator, executor_limitations),
    };
}
fn buildRunReceiptAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    executor_result_text: []const u8,
    paths: LanePaths,
    registration_digest: []const u8,
    start_digest: []const u8,
    lease_digest: []const u8,
    input_path: []const u8,
    input_fingerprint: []const u8,
    executor: []const u8,
    executor_fingerprint: []const u8,
    runner_contract: RunnerContractValidation,
    producer_id: []const u8,
    producer_version: []const u8,
    producer_binary_fingerprint: []const u8,
    producer_key_id: []const u8,
    factor_materialization: FactorMaterialization,
    target_materialization: TargetMaterialization,
    target_package_observation: TargetPackageObservation,
    execution_tree_observed: ExecutionTreeObservation,
) ![]u8 {
    var result_parsed = try std.json.parseFromSlice(std.json.Value, allocator, executor_result_text, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer result_parsed.deinit();
    const result = try object(result_parsed.value);
    if (!std.mem.eql(u8, try requiredString(result, "schema"), "cas-trial-executor-result/v1") or
        !std.mem.eql(u8, try requiredString(result, "trial_id"), view.trial_id) or
        !std.mem.eql(u8, try requiredString(result, "lane_id"), view.lane_id))
    {
        return error.ExecutorResultInvalid;
    }
    if (!std.mem.eql(u8, try requiredString(result, "executor_binary_fingerprint"), executor_fingerprint)) {
        return error.ExecutorIdentityMismatch;
    }
    if (!std.mem.eql(u8, try requiredString(result, "presented_input_fingerprint_observed"), input_fingerprint) or
        !std.mem.eql(
            u8,
            try requiredString(result, "target_snapshot_fingerprint_observed"),
            target_materialization.snapshot_fingerprint orelse return error.TargetMaterializationClaimMismatch,
        ))
    {
        return error.MaterializationMismatch;
    }
    if (factor_materialization.present) {
        try validateFactorMaterializationObservation(result, factor_materialization);
        try archiveFileAtPath(
            allocator,
            factor_materialization.workspace_ref,
            factor_materialization.archive_ref,
            factor_materialization.fingerprint,
        );
    }
    if (target_materialization.present) {
        const expected = target_materialization.carrier_fingerprint orelse return error.TargetMaterializationMissing;
        if (!std.mem.eql(
            u8,
            try requiredString(result, "target_materialization_carrier_fingerprint_observed"),
            expected,
        )) return error.TargetMaterializationObservationMismatch;
        try verifyTargetMaterialization(allocator, target_materialization, paths.execution_root);
    }
    const isolation = try requiredObject(result, "isolation");
    const effects = try requiredObject(result, "effects");
    const terminal = try requiredObject(result, "terminal");
    const evidence = try requiredObject(result, "evidence");
    if (try requiredBool(result, "hidden_reference_presented")) return error.HiddenReferenceLeak;
    if (try requiredBool(result, "sibling_output_presented")) return error.SiblingOutputLeak;
    const runtime = try requiredObject(result, "runtime");
    inline for (.{
        .{ "environment_fingerprint", "environment_fingerprint" },
        .{ "replay_policy_fingerprint", "replay_policy_fingerprint" },
        .{ "effect_policy_fingerprint", "effect_policy_fingerprint" },
        .{ "model_configuration_fingerprint", "model_policy_fingerprint" },
    }) |mapping| {
        const observed = try requiredString(runtime, mapping[0]);
        try validateFingerprint(observed);
        if (!std.mem.eql(u8, observed, try requiredString(view.execution, mapping[1]))) return error.RuntimeDrift;
    }
    inline for (.{ "model_id", "model_provider", "runtime_version" }) |key| _ = try requiredString(runtime, key);
    const started_at = try requiredI64(runtime, "started_at_unix");
    const ended_at = try requiredI64(runtime, "ended_at_unix");
    if (ended_at < started_at) return error.RuntimeInvalid;
    const duration_ms = std.math.mul(u64, @intCast(ended_at - started_at), std.time.ms_per_s) catch return error.RuntimeInvalid;
    if (duration_ms > try requiredU64(view.execution, "maximum_lane_duration_ms")) return error.ExecutionBudgetExceeded;
    if (try requiredU64(runtime, "tokens_used") > try requiredU64(view.execution, "maximum_tokens_per_lane")) return error.ExecutionBudgetExceeded;
    inline for (.{ "fresh_thread", "fresh_workspace", "target_cache_cleared" }) |key| {
        if (!try requiredBool(isolation, key)) return error.IsolationInvalid;
    }
    if (try requiredBool(isolation, "shared_mutable_state_detected")) return error.IsolationInvalid;
    try validateFingerprint(try requiredString(isolation, "reset_receipt_fingerprint"));
    const policy_violations = try requiredArray(effects, "policy_violations");
    if (policy_violations.items.len != 0) return error.EffectPolicyViolation;
    inline for (.{ "filesystem_receipt_fingerprint", "network_receipt_fingerprint", "external_effect_receipt_fingerprint" }) |key| {
        try validateFingerprint(try requiredString(effects, key));
    }
    const filesystem_source = try verifyFingerprintedFileRef(allocator, effects, "filesystem_receipt_ref", "filesystem_receipt_fingerprint", paths.workspace);
    defer allocator.free(filesystem_source);
    const network_source = try verifyFingerprintedFileRef(allocator, effects, "network_receipt_ref", "network_receipt_fingerprint", paths.workspace);
    defer allocator.free(network_source);
    const external_source = try verifyFingerprintedFileRef(allocator, effects, "external_effect_receipt_ref", "external_effect_receipt_fingerprint", paths.workspace);
    defer allocator.free(external_source);
    const reset_source = try verifyFingerprintedFileRef(allocator, isolation, "reset_receipt_ref", "reset_receipt_fingerprint", paths.workspace);
    defer allocator.free(reset_source);
    const execution_audit_source = try verifyFingerprintedFileRef(allocator, result, "execution_audit_ref", "execution_audit_fingerprint", paths.workspace);
    defer allocator.free(execution_audit_source);
    try validateExecutionAudit(allocator, execution_audit_source, view);
    const status = try requiredString(terminal, "status");
    if (!oneOf(status, &.{ "completed", "failed", "blocked", "aborted", "invalid" })) return error.TerminalStatusInvalid;
    const output = try evidenceFile(allocator, evidence, "output_path", paths.workspace, status, true);
    defer output.deinit(allocator);
    const trace = try evidenceFile(allocator, evidence, "trace_path", paths.workspace, status, true);
    defer trace.deinit(allocator);
    const world = try evidenceFile(allocator, evidence, "world_state_path", paths.workspace, status, false);
    defer world.deinit(allocator);
    const metrics = try evidenceFile(allocator, evidence, "metrics_path", paths.workspace, status, false);
    defer metrics.deinit(allocator);
    const output_archive = try archivedEvidenceFile(allocator, output, paths.evidence, "output.json");
    defer output_archive.deinit(allocator);
    const trace_archive = try archivedEvidenceFile(allocator, trace, paths.evidence, "trace.json");
    defer trace_archive.deinit(allocator);
    const world_archive = try archivedEvidenceFile(allocator, world, paths.evidence, "world-state.json");
    defer world_archive.deinit(allocator);
    const metrics_archive = try archivedEvidenceFile(allocator, metrics, paths.evidence, "metrics.json");
    defer metrics_archive.deinit(allocator);
    const reset_archive = try archiveSourceEvidence(allocator, reset_source, try requiredString(isolation, "reset_receipt_fingerprint"), paths.evidence, "executor-reset-assertion.json");
    defer reset_archive.deinit(allocator);
    const filesystem_archive = try archiveSourceEvidence(allocator, filesystem_source, try requiredString(effects, "filesystem_receipt_fingerprint"), paths.evidence, "executor-filesystem-assertion.json");
    defer filesystem_archive.deinit(allocator);
    const network_archive = try archiveSourceEvidence(allocator, network_source, try requiredString(effects, "network_receipt_fingerprint"), paths.evidence, "executor-network-assertion.json");
    defer network_archive.deinit(allocator);
    const external_archive = try archiveSourceEvidence(allocator, external_source, try requiredString(effects, "external_effect_receipt_fingerprint"), paths.evidence, "executor-external-effect-assertion.json");
    defer external_archive.deinit(allocator);
    const execution_audit_archive = try archiveSourceEvidence(allocator, execution_audit_source, try requiredString(result, "execution_audit_fingerprint"), paths.evidence, "execution-audit.json");
    defer execution_audit_archive.deinit(allocator);
    const observations = try createRunnerObservationsAlloc(
        allocator,
        view,
        paths,
        target_materialization,
        target_package_observation,
        execution_tree_observed,
        executor_fingerprint,
        runner_contract,
        try requiredArray(isolation, "limitations"),
        reset_archive,
        filesystem_archive,
        network_archive,
        external_archive,
    );
    defer observations.deinit(allocator);
    const native = try nativeReceiptAlloc(
        allocator,
        view,
        result,
        lease_digest,
        status,
        executor,
        executor_fingerprint,
        paths.decision_context_archive,
        execution_audit_archive.ref,
        execution_audit_archive.fingerprint,
    );
    defer allocator.free(native.json);
    defer allocator.free(native.fingerprint);
    defer if (native.metadata) |metadata| allocator.free(metadata);
    try archiveBytesAtPath(allocator, native.json, paths.native_receipt, native.fingerprint);
    const violations = try canonicalFieldAlloc(allocator, effects.get("policy_violations").?);
    defer allocator.free(violations);
    const runtime_json = try canonicalFieldAlloc(allocator, result.get("runtime").?);
    defer allocator.free(runtime_json);
    const terminal_json = try canonicalFieldAlloc(allocator, result.get("terminal").?);
    defer allocator.free(terminal_json);
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try writeStringMember(writer, "schema", "hylo-run-receipt/v1", true);
    try writeStringMember(writer, "trial_id", view.trial_id, true);
    try writeStringMember(writer, "unit_id", view.unit_id, true);
    try writeStringMember(writer, "scenario_id", view.scenario_id, true);
    try writeStringMember(writer, "pair_id", view.pair_id, true);
    try writeStringMember(writer, "lane_id", view.lane_id, true);
    try writeStringMember(writer, "opaque_arm_id", view.arm_id, true);
    try writer.writeAll("\"lineage\":{");
    try writeStringMember(writer, "registration_event_digest", registration_digest, true);
    try writeStringMember(writer, "lane_started_event_digest", start_digest, true);
    try writeStringMember(writer, "lane_lease_digest", lease_digest, false);
    try writer.writeAll("},\"producer\":{");
    try writeStringMember(writer, "id", producer_id, true);
    try writeStringMember(writer, "version", producer_version, true);
    try writeStringMember(writer, "binary_fingerprint", producer_binary_fingerprint, true);
    try writeStringMember(writer, "key_id", producer_key_id, true);
    try writeStringMember(writer, "receiver_role", "runner", true);
    try writeStringMember(writer, "receiver_key_id", producer_key_id, false);
    try writer.writeAll("},\"materialization\":{");
    try writeStringMember(writer, "arm_value_fingerprint", target_materialization.arm_value_fingerprint orelse return error.TargetMaterializationClaimMismatch, true);
    try writeStringMember(writer, "target_snapshot_ref", target_materialization.snapshot_ref orelse return error.TargetMaterializationClaimMismatch, true);
    try writeStringMember(writer, "target_snapshot_fingerprint", target_materialization.snapshot_fingerprint orelse return error.TargetMaterializationClaimMismatch, true);
    try writeOptionalStringMember(writer, "target_materialization_archive_ref", if (target_materialization.present) target_materialization.archive_ref else null, true);
    try writeOptionalStringMember(writer, "target_materialization_archive_fingerprint", target_materialization.carrier_fingerprint, true);
    try writeOptionalStringMember(writer, "target_package_tree_before_fingerprint", target_package_observation.before_fingerprint, true);
    try writeOptionalStringMember(writer, "target_package_tree_after_fingerprint", target_package_observation.after_fingerprint, true);
    try writeOptionalStringMember(writer, "factor_materialization_ref", if (factor_materialization.present) factor_materialization.ref else null, true);
    try writeOptionalStringMember(writer, "factor_materialization_fingerprint", if (factor_materialization.present) factor_materialization.fingerprint else null, true);
    try writeOptionalStringMember(writer, "factor_materialization_archive_ref", if (factor_materialization.present) factor_materialization.archive_ref else null, true);
    try writeOptionalStringMember(writer, "factor_materialization_archive_fingerprint", if (factor_materialization.present) factor_materialization.fingerprint else null, true);
    _ = input_path;
    try writeStringMember(writer, "presented_input_ref", paths.presented_input_archive, true);
    try writeStringMember(writer, "presented_input_fingerprint", input_fingerprint, true);
    if (try sourceIdentity(view)) |identity| {
        try writeStringMember(writer, "source_episode_fingerprint", identity.episode_fingerprint, true);
        try writeStringMember(writer, "source_profile_fingerprint", identity.profile_fingerprint, true);
    }
    try writer.writeAll("\"hidden_reference_presented\":false,\"sibling_output_presented\":false},\"runtime\":");
    try writer.writeAll(runtime_json);
    try writer.writeAll(",\"isolation\":{\"fresh_thread\":true,\"fresh_workspace\":true,");
    try writeStringMember(writer, "reset_receipt_ref", paths.reset_observation, true);
    try writeStringMember(writer, "reset_receipt_fingerprint", observations.reset_fingerprint, true);
    try writer.writeAll("\"target_cache_cleared\":true,\"shared_mutable_state_detected\":false,\"limitations\":");
    try writer.writeAll(observations.limitations);
    try writeCapabilitySealMembers(writer, runner_contract.capability_seal);
    try writer.writeAll("},\"effects\":{");
    try writeStringMember(writer, "filesystem_receipt_ref", paths.filesystem_observation, true);
    try writeStringMember(writer, "filesystem_receipt_fingerprint", observations.filesystem_fingerprint, true);
    try writeStringMember(writer, "network_receipt_ref", paths.network_observation, true);
    try writeStringMember(writer, "network_receipt_fingerprint", observations.network_fingerprint, true);
    try writeStringMember(writer, "external_effect_receipt_ref", paths.external_effect_observation, true);
    try writeStringMember(writer, "external_effect_receipt_fingerprint", observations.external_effect_fingerprint, true);
    try writer.writeAll("\"policy_violations\":");
    try writer.writeAll(violations);
    try writer.writeAll("},\"terminal\":");
    try writer.writeAll(terminal_json);
    try writer.writeAll(",\"evidence\":{");
    try writeStringMember(writer, "output_ref", output_archive.ref, true);
    try writeStringMember(writer, "output_fingerprint", output_archive.fingerprint, true);
    try writeStringMember(writer, "trace_ref", trace_archive.ref, true);
    try writeStringMember(writer, "trace_fingerprint", trace_archive.fingerprint, true);
    try writeStringMember(writer, "world_state_ref", world_archive.ref, true);
    try writeStringMember(writer, "world_state_fingerprint", world_archive.fingerprint, true);
    try writeStringMember(writer, "metrics_ref", metrics_archive.ref, true);
    try writeStringMember(writer, "metrics_fingerprint", metrics_archive.fingerprint, false);
    try writer.writeAll("},\"native_receipt\":{");
    try writeStringMember(writer, "kind", native.kind, true);
    try writeStringMember(writer, "ref", paths.native_receipt, true);
    try writeStringMember(writer, "fingerprint", native.fingerprint, true);
    if (native.metadata) |metadata| {
        try writer.writeAll(metadata);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"receipt\":");
    try writer.writeAll(native.json);
    try writer.writeAll("},\"attestation\":null}");
    return out.toOwnedSlice();
}

fn validateFactorMaterializationObservation(
    result: std.json.ObjectMap,
    factor_materialization: FactorMaterialization,
) !void {
    if (!factor_materialization.present) return;
    if (!std.mem.eql(u8, try requiredString(result, "factor_materialization_ref_observed"), factor_materialization.ref) or
        !std.mem.eql(u8, try requiredString(result, "factor_materialization_fingerprint_observed"), factor_materialization.fingerprint))
    {
        return error.FactorMaterializationObservationMismatch;
    }
}

const NativeReceipt = struct {
    kind: []const u8,
    json: []u8,
    fingerprint: []u8,
    metadata: ?[]u8 = null,
};

fn nativeReceiptAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    result: std.json.ObjectMap,
    lease_digest: []const u8,
    status: []const u8,
    executor: []const u8,
    executor_fingerprint: []const u8,
    decision_context_ref: []const u8,
    execution_audit_ref: []const u8,
    execution_audit_fingerprint: []const u8,
) !NativeReceipt {
    const profile = try object(view.source_profile);
    const kind = try requiredString(profile, "kind");
    if (std.mem.eql(u8, kind, "historical_decision")) {
        if (try requiredU64(result, "target_instruction_count") != 1 or
            try requiredBool(result, "source_target_text_presented"))
        {
            return error.SourceTargetTextContamination;
        }
        const fir_value = result.get("fir_receipt") orelse return error.FirReceiptMissing;
        var profile_report = try adapter.validateHistoricalProfile(
            allocator,
            view.source_profile,
            std.mem.eql(u8, view.purpose, "promotion") or std.mem.eql(u8, view.purpose, "practice_repair"),
        );
        defer profile_report.deinit(allocator);
        var fir_report = try adapter.validateFirForHistoricalLane(
            allocator,
            fir_value,
            &profile_report,
            view.trial_id,
            view.lane_id,
            try requiredString(profile, "required_lineage"),
        );
        defer fir_report.deinit(allocator);
        const fir_json = try attestation.canonicalJsonAlloc(allocator, fir_value);
        defer allocator.free(fir_json);
        const metadata = try std.fmt.allocPrint(
            allocator,
            "\"source_governance_fingerprint\":{f},\"decision_context_ref\":{f},\"decision_context_fingerprint\":{f},\"source_target_text_policy\":{f},\"source_target_text_witness_fingerprint\":{f},\"episode_identity_fingerprint\":{f},\"target_instruction_count\":1,\"executor\":{f},\"executor_binary_fingerprint\":{f},\"execution_audit_ref\":{f},\"execution_audit_fingerprint\":{f}",
            .{
                std.json.fmt(try requiredString(profile, "source_governance_fingerprint"), .{}),
                std.json.fmt(decision_context_ref, .{}),
                std.json.fmt(try requiredString(profile, "decision_context_fingerprint"), .{}),
                std.json.fmt(try requiredString(profile, "source_target_text_policy"), .{}),
                std.json.fmt(profile_report.target_text_witness_fingerprint, .{}),
                std.json.fmt(fir_report.episode_identity_fingerprint.?, .{}),
                std.json.fmt(executor, .{}),
                std.json.fmt(executor_fingerprint, .{}),
                std.json.fmt(execution_audit_ref, .{}),
                std.json.fmt(execution_audit_fingerprint, .{}),
            },
        );
        return .{
            .kind = "FIR-v1",
            .fingerprint = try attestation.digestBytesAlloc(allocator, fir_json),
            .json = try allocator.dupe(u8, fir_json),
            .metadata = metadata,
        };
    }
    return casNativeReceiptAlloc(
        allocator,
        view,
        lease_digest,
        status,
        executor,
        executor_fingerprint,
        execution_audit_ref,
        execution_audit_fingerprint,
        true,
    );
}

fn casNativeReceiptAlloc(
    allocator: std.mem.Allocator,
    view: LaneView,
    lease_digest: []const u8,
    status: []const u8,
    executor: []const u8,
    executor_fingerprint: []const u8,
    execution_audit_ref: []const u8,
    execution_audit_fingerprint: []const u8,
    internal_execution_verified: bool,
) !NativeReceipt {
    const raw = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-trial-receipt/v1\",\"trial_id\":{f},\"lane_id\":{f},\"claim\":{{\"claim_id\":{f},\"atomic\":true,\"claimed_before_execution\":true,\"claim_count\":1,\"lane_lease_digest\":{f}}},\"execution\":{{\"handle_id\":{f},\"handle_count\":1,\"retry_count\":0,\"hidden_fork_count\":0,\"terminal_receipt_once\":true,\"observation_scope\":{f},\"internal_execution_verified\":{},\"execution_audit_ref\":{f},\"execution_audit_fingerprint\":{f},\"executor\":{f},\"executor_binary_fingerprint\":{f}}},\"terminal_status\":{f},\"runner_contract_fingerprint\":{f}}}",
        .{
            std.json.fmt(view.trial_id, .{}), std.json.fmt(view.lane_id, .{}), std.json.fmt(view.lane_id, .{}), std.json.fmt(lease_digest, .{}), std.json.fmt(view.lane_id, .{}), std.json.fmt(if (internal_execution_verified) "registered-executor-audit" else "cas-process-only", .{}), internal_execution_verified, std.json.fmt(execution_audit_ref, .{}), std.json.fmt(execution_audit_fingerprint, .{}), std.json.fmt(executor, .{}), std.json.fmt(executor_fingerprint, .{}), std.json.fmt(status, .{}), std.json.fmt(try requiredString(view.execution, "runner_contract_fingerprint"), .{}),
        },
    );
    defer allocator.free(raw);
    const json = try canonicalJsonTextAlloc(allocator, raw);
    return .{
        .kind = "cas-trial-receipt",
        .fingerprint = try attestation.digestBytesAlloc(allocator, json),
        .json = json,
    };
}

const EvidenceFile = struct {
    ref: []u8,
    fingerprint: []u8,
    present: bool,
    fn deinit(self: EvidenceFile, allocator: std.mem.Allocator) void {
        allocator.free(self.ref);
        allocator.free(self.fingerprint);
    }
};

fn evidenceFile(
    allocator: std.mem.Allocator,
    evidence: std.json.ObjectMap,
    key: []const u8,
    workspace: []const u8,
    status: []const u8,
    required_completed: bool,
) !EvidenceFile {
    const path = optionalString(evidence, key);
    if (path == null) {
        if (required_completed and std.mem.eql(u8, status, "completed")) return error.EvidenceMissing;
        return .{
            .ref = try allocator.dupe(u8, "unavailable"),
            .fingerprint = try attestation.digestBytesAlloc(allocator, ""),
            .present = false,
        };
    }
    const resolved = try resolveWorkspaceArtifactAlloc(allocator, workspace, path.?);
    errdefer allocator.free(resolved);
    return .{ .ref = resolved, .fingerprint = try fileFingerprintAlloc(allocator, resolved), .present = true };
}

fn validateSigningAuthority(allocator: std.mem.Allocator, trial: std.json.ObjectMap, producer_id: []const u8, key_id: []const u8, seed: [32]u8) !void {
    const assurance = try requiredObject(trial, "assurance");
    const trust = try requiredObject(assurance, "trust_policy");
    const keys = try requiredArray(trust, "keys");
    const public_key = try attestation.publicKeyBase64Alloc(allocator, seed);
    defer allocator.free(public_key);
    for (keys.items) |key_value| {
        const key = try object(key_value);
        if (!std.mem.eql(u8, try requiredString(key, "key_id"), key_id)) continue;
        if (!std.mem.eql(u8, try requiredString(key, "public_key_base64"), public_key)) return error.SigningKeyMismatch;
        if (!arrayContains(try requiredArray(key, "allowed_roles"), "runner") or
            !arrayContains(try requiredArray(key, "producer_ids"), producer_id))
        {
            return error.SigningKeyUnauthorized;
        }
        return;
    }
    return error.SigningKeyUnauthorized;
}

fn validateRunnerContract(
    allocator: std.mem.Allocator,
    trial: std.json.ObjectMap,
    execution: std.json.ObjectMap,
    runner_binary_fingerprint: []const u8,
    executor_fingerprint: []const u8,
    ledger_fingerprint: []const u8,
) !RunnerContractValidation {
    const contract_value = execution.get("runner_contract") orelse return error.RunnerContractMissing;
    const observed = try attestation.digestValueAlloc(allocator, contract_value);
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, try requiredString(execution, "runner_contract_fingerprint"))) {
        return error.RunnerContractFingerprintMismatch;
    }
    const contract = try object(contract_value);
    const assurance = try requiredObject(trial, "assurance");
    const assurance_level = try requiredString(assurance, "required_level");
    const sealed = std.mem.eql(u8, assurance_level, "sealed");
    if (!std.mem.eql(u8, try requiredString(contract, "schema"), "cas-hylo-runner/v1") or
        !std.mem.eql(u8, try requiredString(contract, "executor_binary_fingerprint"), executor_fingerprint) or
        !std.mem.eql(u8, try requiredString(contract, "ledger_binary_fingerprint"), ledger_fingerprint) or
        !try requiredBool(contract, "atomic_claim") or
        !try requiredBool(contract, "fresh_workspace") or
        !try requiredBool(contract, "fresh_thread") or
        !try requiredBool(contract, "materializes_opaque_arm") or
        try requiredU64(contract, "maximum_handles_per_lane") != 1 or
        try requiredU64(contract, "maximum_retries_per_lane") != 0)
    {
        return error.RunnerContractInvalid;
    }

    const runner_authority = try requiredObject(execution, "runner_authority");
    if (!std.mem.eql(u8, try requiredString(runner_authority, "binary_fingerprint"), runner_binary_fingerprint)) {
        return error.RunnerAuthorityInvalid;
    }
    const executor_authority = try requiredObject(contract, "executor_authority");
    if (!std.mem.eql(u8, try requiredString(executor_authority, "binary_fingerprint"), executor_fingerprint)) {
        return error.ExecutorAuthorityInvalid;
    }
    const authorized_observations = try requiredArray(executor_authority, "authorized_observations");
    inline for (.{
        "runtime",
        "isolation",
        "effects",
        "terminal",
        "evidence",
        "execution_audit",
        "native_receipt",
    }) |observation| {
        if (!arrayContains(authorized_observations, observation)) return error.ExecutorAuthorityInvalid;
    }
    const ledger_authority = try requiredObject(contract, "ledger_authority");
    if (!std.mem.eql(u8, try requiredString(ledger_authority, "binary_fingerprint"), ledger_fingerprint)) {
        return error.LedgerAuthorityInvalid;
    }
    const trust = try requiredObject(assurance, "trust_policy");
    try validateBinaryAuthority(trust, runner_authority, runner_binary_fingerprint, error.RunnerAuthorityUnauthorized);
    try validateBinaryAuthority(trust, executor_authority, executor_fingerprint, error.ExecutorAuthorityUnauthorized);
    try validateBinaryAuthority(trust, ledger_authority, ledger_fingerprint, error.LedgerAuthorityUnauthorized);

    if (!sealed) {
        if (contract.get("capability_seal") != null) return error.RunnerContractInvalid;
        return .{};
    }

    const capability_seal = try requiredObject(contract, "capability_seal");
    if (capability_seal.count() != 8 or
        !std.mem.eql(u8, try requiredString(capability_seal, "schema"), "cas-capability-seal/v1") or
        !std.mem.eql(u8, try requiredString(capability_seal, "profile_id"), "cas-capability-sealed-v1") or
        !std.mem.eql(u8, try requiredString(capability_seal, "target_data_mode"), "cas-content-addressed-pre-post-equality") or
        !std.mem.eql(u8, try requiredString(capability_seal, "effect_mediation"), "attested-executor") or
        !std.mem.eql(u8, try requiredString(capability_seal, "default_effect_decision"), "deny") or
        try requiredBool(capability_seal, "os_confinement"))
    {
        return error.CapabilitySealContractInvalid;
    }
    const effect_policy_fingerprint = try requiredString(capability_seal, "effect_policy_fingerprint");
    try validateFingerprint(effect_policy_fingerprint);
    if (!std.mem.eql(u8, effect_policy_fingerprint, try requiredString(execution, "effect_policy_fingerprint"))) {
        return error.EffectPolicyFingerprintMismatch;
    }
    try requireExactCapabilityObservations(
        try requiredArray(capability_seal, "cas_observations"),
        &.{ "target-package-tree", "execution-tree", "output-carrier", "process-group" },
    );
    return .{ .capability_seal = .{
        .profile_id = try requiredString(capability_seal, "profile_id"),
        .effect_policy_fingerprint = effect_policy_fingerprint,
    } };
}

fn requireExactCapabilityObservations(observed: std.json.Array, expected: []const []const u8) !void {
    if (observed.items.len != expected.len) return error.CapabilitySealContractInvalid;
    for (observed.items, expected) |value, expected_value| {
        if (!std.mem.eql(u8, try string(value), expected_value)) {
            return error.CapabilitySealContractInvalid;
        }
    }
}
fn validateBinaryAuthority(
    trust: std.json.ObjectMap,
    authority: std.json.ObjectMap,
    binary_fingerprint: []const u8,
    unauthorized: anyerror,
) !void {
    const authority_key_id = try requiredString(authority, "key_id");
    const authority_producer_id = try requiredString(authority, "producer_id");
    for ((try requiredArray(trust, "keys")).items) |key_value| {
        const key = try object(key_value);
        if (!std.mem.eql(u8, try requiredString(key, "key_id"), authority_key_id)) continue;
        if (!arrayContains(try requiredArray(key, "allowed_roles"), "runner") or
            !arrayContains(try requiredArray(key, "producer_ids"), authority_producer_id) or
            !arrayContains(try requiredArray(key, "producer_binary_fingerprints"), binary_fingerprint))
        {
            return unauthorized;
        }
        return;
    }
    return unauthorized;
}

fn verifyFingerprintedFileRef(
    allocator: std.mem.Allocator,
    object_value: std.json.ObjectMap,
    ref_key: []const u8,
    fingerprint_key: []const u8,
    workspace: []const u8,
) ![]u8 {
    const raw = try requiredString(object_value, ref_key);
    const resolved = try resolveWorkspaceArtifactAlloc(allocator, workspace, raw);
    errdefer allocator.free(resolved);
    const observed = try fileFingerprintAlloc(allocator, resolved);
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, try requiredString(object_value, fingerprint_key))) return error.ReceiptArtifactFingerprintMismatch;
    return resolved;
}

fn resolveWorkspaceArtifactAlloc(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    raw: []const u8,
) ![]u8 {
    const workspace_resolved = try std.fs.path.resolve(allocator, &.{workspace});
    defer allocator.free(workspace_resolved);
    const candidate = if (std.fs.path.isAbsolute(raw))
        try std.fs.path.resolve(allocator, &.{raw})
    else
        try std.fs.path.resolve(allocator, &.{ workspace_resolved, raw });
    errdefer allocator.free(candidate);
    if (!isStrictDescendant(workspace_resolved, candidate)) return error.EvidenceOutsideWorkspace;
    try ensurePathComponentsNoSymlink(allocator, workspace_resolved, candidate);
    return candidate;
}

fn isStrictDescendant(root: []const u8, candidate: []const u8) bool {
    return candidate.len > root.len and
        std.mem.startsWith(u8, candidate, root) and
        std.fs.path.isSep(candidate[root.len]);
}

fn ensurePathComponentsNoSymlink(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    candidate: []const u8,
) !void {
    const relative = candidate[workspace.len + 1 ..];
    var iterator = std.mem.splitScalar(u8, relative, std.fs.path.sep);
    var current = try allocator.dupe(u8, workspace);
    defer allocator.free(current);
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.EvidencePathInvalid;
        }
        const next = try std.fs.path.join(allocator, &.{ current, component });
        allocator.free(current);
        current = next;
        const stat = try std.Io.Dir.cwd().statFile(defaultIo(), current, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.EvidenceSymlinkForbidden;
        if (iterator.peek() == null and stat.kind != .file) return error.EvidenceNotRegularFile;
        if (iterator.peek() != null and stat.kind != .directory) return error.EvidencePathInvalid;
    }
}

fn archiveFileAtPath(
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
    expected_fingerprint: []const u8,
) !void {
    return archiveFileAtPathLimited(allocator, source, destination, expected_fingerprint, MaxInputBytes);
}

fn archiveFileAtPathLimited(
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
    expected_fingerprint: []const u8,
    limit: usize,
) !void {
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, source, limit);
    defer allocator.free(bytes);
    try requireBytesFingerprint(allocator, bytes, expected_fingerprint);
    try archiveBytesAtPathLimited(allocator, bytes, destination, expected_fingerprint, limit);
}

fn archiveBytesAtPath(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    destination: []const u8,
    expected_fingerprint: []const u8,
) !void {
    return archiveBytesAtPathLimited(allocator, bytes, destination, expected_fingerprint, MaxInputBytes);
}

fn archiveBytesAtPathLimited(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    destination: []const u8,
    expected_fingerprint: []const u8,
    limit: usize,
) !void {
    try requireBytesFingerprint(allocator, bytes, expected_fingerprint);
    durable_store.writeTextCreateNewAtomic(allocator, destination, bytes, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try durable_store.readRegularFileNoSymlink(allocator, destination, limit);
            defer allocator.free(existing);
            if (!std.mem.eql(u8, existing, bytes)) return error.ArchivedEvidenceConflict;
        },
        else => return err,
    };
    const archived = try durable_store.readRegularFileNoSymlink(allocator, destination, limit);
    defer allocator.free(archived);
    try requireBytesFingerprint(allocator, archived, expected_fingerprint);
    try makePathReadOnly(destination);
}

fn requireBytesFingerprint(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_fingerprint: []const u8,
) !void {
    const observed = try attestation.digestBytesAlloc(allocator, bytes);
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, expected_fingerprint)) return error.ArchivedEvidenceFingerprintMismatch;
}

fn makePathReadOnly(path: []const u8) !void {
    try durable_store.rejectSymlinkComponents(path);
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(defaultIo(), path, .{
            .allow_directory = false,
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openFile(defaultIo(), path, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
    defer file.close(defaultIo());
    try file.setPermissions(defaultIo(), .fromMode(0o400));
}

fn sealExistingControlArtifactAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
    defer allocator.free(bytes);
    const fingerprint = try attestation.digestBytesAlloc(allocator, bytes);
    errdefer allocator.free(fingerprint);
    try makePathReadOnly(path);
    try verifySealedControlArtifact(allocator, path, fingerprint);
    return fingerprint;
}

fn persistExpectedSealedArtifactAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
) ![]u8 {
    durable_store.writeTextCreateNewAtomic(allocator, path, bytes, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
            defer allocator.free(existing);
            if (!std.mem.eql(u8, existing, bytes)) return error.PersistedArtifactConflict;
        },
        else => return err,
    };
    return sealExistingControlArtifactAlloc(allocator, path);
}

fn persistSealedControlArtifactAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
) ![]u8 {
    return persistExpectedSealedArtifactAlloc(allocator, path, bytes);
}

fn verifySealedControlArtifact(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_fingerprint: []const u8,
) !void {
    try durable_store.rejectSymlinkComponents(path);
    const stat = try std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.permissions.toMode() & 0o777 != 0o400) {
        return error.ControlArtifactNotSealed;
    }
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
    defer allocator.free(bytes);
    try requireBytesFingerprint(allocator, bytes, expected_fingerprint);
}

fn archivedEvidenceFile(
    allocator: std.mem.Allocator,
    source: EvidenceFile,
    evidence_dir: []const u8,
    name: []const u8,
) !EvidenceFile {
    if (!source.present) return .{
        .ref = try allocator.dupe(u8, source.ref),
        .fingerprint = try allocator.dupe(u8, source.fingerprint),
        .present = false,
    };
    const destination = try std.fs.path.join(allocator, &.{ evidence_dir, name });
    errdefer allocator.free(destination);
    try archiveFileAtPath(allocator, source.ref, destination, source.fingerprint);
    return .{
        .ref = destination,
        .fingerprint = try allocator.dupe(u8, source.fingerprint),
        .present = true,
    };
}

fn archiveSourceEvidence(
    allocator: std.mem.Allocator,
    source: []const u8,
    fingerprint: []const u8,
    evidence_dir: []const u8,
    name: []const u8,
) !EvidenceFile {
    const destination = try std.fs.path.join(allocator, &.{ evidence_dir, name });
    errdefer allocator.free(destination);
    try archiveFileAtPath(allocator, source, destination, fingerprint);
    return .{
        .ref = destination,
        .fingerprint = try allocator.dupe(u8, fingerprint),
        .present = true,
    };
}

fn validateExecutionAudit(allocator: std.mem.Allocator, path: []const u8, view: LaneView) !void {
    const raw = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const audit = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(audit, "schema"), "cas-trial-execution-audit/v1") or
        !std.mem.eql(u8, try requiredString(audit, "trial_id"), view.trial_id) or
        !std.mem.eql(u8, try requiredString(audit, "lane_id"), view.lane_id) or
        try requiredU64(audit, "model_execution_count") != 1 or
        try requiredU64(audit, "retry_count") != 0 or
        try requiredU64(audit, "hidden_fork_count") != 0 or
        !try requiredBool(audit, "complete"))
    {
        return error.ExecutionAuditInvalid;
    }
}

fn readSigningSeed(fd: std.posix.fd_t) ![32]u8 {
    _ = try sensitiveInputEndpoint(fd);
    defer closeOwnedFd(fd);
    var raw: [33]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw);
    var used: usize = 0;
    while (used < raw.len) {
        const count = std.c.read(fd, raw[used..].ptr, raw.len - used);
        switch (std.posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) break;
                used += @intCast(count);
            },
            .INTR => continue,
            else => return error.SigningSeedInvalid,
        }
    }
    if (used != 32) return error.SigningSeedInvalid;
    return raw[0..32].*;
}

fn canonicalFieldAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return attestation.canonicalJsonAlloc(allocator, value);
}

fn digestJsonTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return attestation.digestValueAlloc(allocator, parsed.value);
}

fn canonicalJsonTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    return attestation.canonicalJsonAlloc(allocator, parsed.value);
}

fn readFdAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, limit: usize) ![]u8 {
    if (fd < 3) return error.InvalidFd;
    const raw = try readFdRawToEndAlloc(allocator, fd, limit);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return error.EmptyFd;
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return result;
}

fn readOwnedFdAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, limit: usize) ![]u8 {
    if (fd < 3) return error.InvalidFd;
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(defaultIo());
    return readFdAlloc(allocator, fd, limit);
}

fn readOwnedFdRawAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, limit: usize) ![]u8 {
    if (fd < 3) return error.InvalidFd;
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(defaultIo());
    return readFdRawToEndAlloc(allocator, fd, limit);
}

fn readFdRawToEndAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, limit: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = std.c.read(fd, &buffer, buffer.len);
        switch (std.posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) return bytes.toOwnedSlice(allocator);
                const count_usize: usize = @intCast(count);
                if (count_usize > limit -| bytes.items.len) return error.FdInputTooLarge;
                try bytes.appendSlice(allocator, buffer[0..count_usize]);
            },
            .INTR => continue,
            else => return error.FdReadFailed,
        }
    }
}

fn closeOwnedFd(fd: std.posix.fd_t) void {
    if (fd < 3) return;
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(defaultIo());
}

const SensitiveInputEndpoint = struct {
    fd: std.posix.fd_t,
    stat: std.c.Stat,
};

fn sameFdEndpoint(expected: std.c.Stat, fd: std.posix.fd_t) bool {
    var actual: std.c.Stat = undefined;
    if (std.c.fstat(fd, &actual) != 0) return false;
    return expected.dev == actual.dev and expected.ino == actual.ino;
}

fn sensitiveInputEndpoint(fd: std.posix.fd_t) !SensitiveInputEndpoint {
    if (fd < 3) return error.InvalidFd;
    var endpoint: std.c.Stat = undefined;
    if (std.c.fstat(fd, &endpoint) != 0) return error.InvalidFd;
    if (sameFdEndpoint(endpoint, std.posix.STDIN_FILENO) or
        sameFdEndpoint(endpoint, std.posix.STDOUT_FILENO) or
        sameFdEndpoint(endpoint, std.posix.STDERR_FILENO))
    {
        return error.SensitiveFdStandardStreamAlias;
    }
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return error.InvalidFd;
    const flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    if (!std.c.S.ISFIFO(endpoint.mode) or endpoint.nlink != 0 or flags.ACCMODE != .RDONLY) {
        return error.SensitiveFdEndpointUnbound;
    }
    return .{ .fd = fd, .stat = endpoint };
}

fn validateSensitiveInputFds(
    lease_fd: std.posix.fd_t,
    input_fd: std.posix.fd_t,
    source_profile_fd: ?std.posix.fd_t,
    signing_seed_fd: ?std.posix.fd_t,
) !void {
    var endpoints: [4]SensitiveInputEndpoint = undefined;
    var count: usize = 0;
    for ([_]?std.posix.fd_t{ lease_fd, input_fd, source_profile_fd, signing_seed_fd }) |maybe_fd| {
        const fd = maybe_fd orelse continue;
        endpoints[count] = try sensitiveInputEndpoint(fd);
        for (endpoints[0..count]) |prior| {
            if (prior.stat.dev == endpoints[count].stat.dev and
                prior.stat.ino == endpoints[count].stat.ino)
            {
                return error.SensitiveFdAliased;
            }
        }
        count += 1;
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(defaultIo(), path, .{});
    defer file.close(defaultIo());
    var reader = file.reader(defaultIo(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

fn fileFingerprintAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return fileFingerprintLimitedAlloc(allocator, path, MaxInputBytes);
}

const BoundedCaptureEvidence = struct {
    fingerprint: []u8,
    size: u64,
};

fn boundedRegularCaptureEvidenceAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
) !?BoundedCaptureEvidence {
    durable_store.rejectSymlinkComponents(path) catch return null;
    const file = std.Io.Dir.openFileAbsolute(defaultIo(), path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return null;
    defer file.close(defaultIo());
    const stat = file.stat(defaultIo()) catch return null;
    if (stat.kind != .file or stat.size > limit) return null;
    const size = std.math.cast(usize, stat.size) orelse return null;
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    const read = file.readPositionalAll(defaultIo(), bytes, 0) catch return null;
    if (read != size) return null;
    const after = file.stat(defaultIo()) catch return null;
    if (after.kind != .file or after.size != stat.size) return null;
    return .{
        .fingerprint = try attestation.digestBytesAlloc(allocator, bytes),
        .size = stat.size,
    };
}

fn fileFingerprintLimitedAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
) ![]u8 {
    const stat = try std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > limit) return error.FileTooBig;
    const read_limit = std.math.add(usize, limit, 1) catch return error.FileTooBig;
    const bytes = try readFileAlloc(allocator, path, read_limit);
    defer allocator.free(bytes);
    return attestation.digestBytesAlloc(allocator, bytes);
}

fn openFileFingerprintAlloc(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    size: u64,
) ![]u8 {
    const bytes = try readOpenFileBytesAlloc(allocator, file, size);
    defer allocator.free(bytes);
    return attestation.digestBytesAlloc(allocator, bytes);
}

fn readOpenFileBytesAlloc(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    size: u64,
) ![]u8 {
    if (size > MaxInputBytes) return error.ExecutableTooLarge;
    const byte_count = std.math.cast(usize, size) orelse return error.ExecutableTooLarge;
    const bytes = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(defaultIo(), bytes, 0) != byte_count) {
        return error.ExecutableReadIncomplete;
    }
    return bytes;
}

fn currentExecutableFingerprintAlloc(allocator: std.mem.Allocator) ![]u8 {
    const path = try std.process.executablePathAlloc(defaultIo(), allocator);
    defer allocator.free(path);
    return fileFingerprintAlloc(allocator, path);
}

const MachOEndian = enum { little, big };

fn executableU32(bytes: []const u8, offset: usize, endian: MachOEndian) !u32 {
    const end = std.math.add(usize, offset, 4) catch return error.ExecutableFormatInvalid;
    if (end > bytes.len) return error.ExecutableFormatInvalid;
    return switch (endian) {
        .little => std.mem.readInt(u32, bytes[offset..][0..4], .little),
        .big => std.mem.readInt(u32, bytes[offset..][0..4], .big),
    };
}

fn executableU64(bytes: []const u8, offset: usize, endian: MachOEndian) !u64 {
    const end = std.math.add(usize, offset, 8) catch return error.ExecutableFormatInvalid;
    if (end > bytes.len) return error.ExecutableFormatInvalid;
    return switch (endian) {
        .little => std.mem.readInt(u64, bytes[offset..][0..8], .little),
        .big => std.mem.readInt(u64, bytes[offset..][0..8], .big),
    };
}

fn executableSlice(bytes: []const u8, offset: u64, size: u64) ![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.ExecutableFormatInvalid;
    const length = std.math.cast(usize, size) orelse return error.ExecutableFormatInvalid;
    const end = std.math.add(usize, start, length) catch return error.ExecutableFormatInvalid;
    if (end > bytes.len) return error.ExecutableFormatInvalid;
    return bytes[start..end];
}

fn codeSignatureContainsPlatformCode(signature: []const u8) !bool {
    if (try executableU32(signature, 0, .big) != std.macho.CSMAGIC_EMBEDDED_SIGNATURE) {
        return error.ExecutableFormatInvalid;
    }
    const super_length = try executableU32(signature, 4, .big);
    const super_blob = try executableSlice(signature, 0, super_length);
    const count = try executableU32(super_blob, 8, .big);
    const index_bytes = std.math.mul(u64, count, @sizeOf(std.macho.BlobIndex)) catch
        return error.ExecutableFormatInvalid;
    _ = try executableSlice(super_blob, @sizeOf(std.macho.SuperBlob), index_bytes);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const index_offset = @as(usize, @sizeOf(std.macho.SuperBlob)) +
            @as(usize, index) * @sizeOf(std.macho.BlobIndex);
        const slot = try executableU32(super_blob, index_offset, .big);
        const is_code_directory = slot == std.macho.CSSLOT_CODEDIRECTORY or
            (slot >= std.macho.CSSLOT_ALTERNATE_CODEDIRECTORIES and
                slot < std.macho.CSSLOT_ALTERNATE_CODEDIRECTORY_LIMIT);
        if (!is_code_directory) continue;
        const blob_offset = try executableU32(super_blob, index_offset + 4, .big);
        const blob_header = try executableSlice(super_blob, blob_offset, 8);
        if (try executableU32(blob_header, 0, .big) != std.macho.CSMAGIC_CODEDIRECTORY) {
            return error.ExecutableFormatInvalid;
        }
        const blob_length = try executableU32(blob_header, 4, .big);
        const code_directory = try executableSlice(super_blob, blob_offset, blob_length);
        if (code_directory.len < 40) return error.ExecutableFormatInvalid;
        if (code_directory[38] != 0) return true;
    }
    return false;
}

fn thinMachOContainsPlatformCode(bytes: []const u8) !bool {
    if (bytes.len < 4) return false;
    const magic = try executableU32(bytes, 0, .little);
    const endian: MachOEndian = switch (magic) {
        std.macho.MH_MAGIC, std.macho.MH_MAGIC_64 => .little,
        std.macho.MH_CIGAM, std.macho.MH_CIGAM_64 => .big,
        else => return false,
    };
    const header_size: usize = if (magic == std.macho.MH_MAGIC_64 or magic == std.macho.MH_CIGAM_64) 32 else 28;
    if (bytes.len < header_size) return error.ExecutableFormatInvalid;
    const command_count = try executableU32(bytes, 16, endian);
    const command_bytes = try executableU32(bytes, 20, endian);
    const commands_end = std.math.add(usize, header_size, command_bytes) catch
        return error.ExecutableFormatInvalid;
    if (commands_end > bytes.len) return error.ExecutableFormatInvalid;
    var command_offset = header_size;
    var command_index: u32 = 0;
    while (command_index < command_count) : (command_index += 1) {
        const command = try executableU32(bytes, command_offset, endian);
        const command_size = try executableU32(bytes, command_offset + 4, endian);
        if (command_size < 8) return error.ExecutableFormatInvalid;
        const next_command = std.math.add(usize, command_offset, command_size) catch
            return error.ExecutableFormatInvalid;
        if (next_command > commands_end) return error.ExecutableFormatInvalid;
        if (command == @intFromEnum(std.macho.LC.CODE_SIGNATURE)) {
            if (command_size < 16) return error.ExecutableFormatInvalid;
            const signature_offset = try executableU32(bytes, command_offset + 8, endian);
            const signature_size = try executableU32(bytes, command_offset + 12, endian);
            if (try codeSignatureContainsPlatformCode(try executableSlice(bytes, signature_offset, signature_size))) {
                return true;
            }
        }
        command_offset = next_command;
    }
    return false;
}

fn executableBytesContainPlatformCode(bytes: []const u8) !bool {
    if (bytes.len < 4) return false;
    const fat_magic = try executableU32(bytes, 0, .big);
    const fat_endian: MachOEndian = switch (fat_magic) {
        std.macho.FAT_MAGIC, std.macho.FAT_MAGIC_64 => .big,
        std.macho.FAT_CIGAM, std.macho.FAT_CIGAM_64 => .little,
        else => return thinMachOContainsPlatformCode(bytes),
    };
    const is_fat_64 = fat_magic == std.macho.FAT_MAGIC_64 or fat_magic == std.macho.FAT_CIGAM_64;
    const architecture_count = try executableU32(bytes, 4, fat_endian);
    const architecture_size: usize = if (is_fat_64) 32 else 20;
    const table_size = std.math.mul(u64, architecture_count, architecture_size) catch
        return error.ExecutableFormatInvalid;
    _ = try executableSlice(bytes, 8, table_size);
    var architecture_index: u32 = 0;
    while (architecture_index < architecture_count) : (architecture_index += 1) {
        const architecture_offset = @as(usize, 8) + @as(usize, architecture_index) * architecture_size;
        const slice_offset = if (is_fat_64)
            try executableU64(bytes, architecture_offset + 8, fat_endian)
        else
            try executableU32(bytes, architecture_offset + 8, fat_endian);
        const slice_size = if (is_fat_64)
            try executableU64(bytes, architecture_offset + 16, fat_endian)
        else
            try executableU32(bytes, architecture_offset + 12, fat_endian);
        if (try thinMachOContainsPlatformCode(try executableSlice(bytes, slice_offset, slice_size))) return true;
    }
    return false;
}

fn ensurePrivateExecutableStore(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.ExecutableStorePathNotAbsolute;
    const existed = blk: {
        const stat = std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .directory) return error.ExecutableStoreNotDirectory;
        break :blk true;
    };
    try durable_store.ensureDirectoryPathNoSymlinks(path);
    var dir = try std.Io.Dir.openDirAbsolute(defaultIo(), path, .{ .follow_symlinks = false });
    defer dir.close(defaultIo());
    if (!existed and std.c.fchmod(dir.handle, ExecutableStoreMode) != 0) {
        return error.ExecutableStorePermissionsInvalid;
    }
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(dir.handle, &stat) != 0) return error.ExecutableStoreStatFailed;
    if (!std.c.S.ISDIR(stat.mode) or
        stat.uid != std.c.getuid() or
        stat.mode & 0o777 != ExecutableStoreMode)
    {
        return error.ExecutableStorePermissionsInvalid;
    }
}

fn materializeStagedExecutable(
    store_root: []const u8,
    spawn_path: []const u8,
    bytes: []const u8,
) !void {
    _ = store_root;
    writeCreateNewAtomicExactMode(spawn_path, bytes, StagedExecutableMode) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeCreateNewAtomicExactMode(
    path: []const u8,
    bytes: []const u8,
    mode: std.posix.mode_t,
) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(path);
    try durable_store.ensureDirectoryPathNoSymlinks(parent);
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(defaultIo(), parent, .{ .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(defaultIo(), parent, .{ .follow_symlinks = false });
    defer dir.close(defaultIo());
    var atomic_file = try dir.createFileAtomic(defaultIo(), base, .{
        .permissions = .fromMode(0o600),
        .replace = false,
    });
    defer atomic_file.deinit(defaultIo());
    try atomic_file.file.writeStreamingAll(defaultIo(), bytes);
    try atomic_file.file.setPermissions(defaultIo(), .fromMode(mode));
    try atomic_file.file.sync(defaultIo());
    try atomic_file.link(defaultIo());
}

fn validateStagedExecutableFile(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    expected_fingerprint: []const u8,
) !std.Io.File.Stat {
    const stat = try file.stat(defaultIo());
    var native_stat: std.c.Stat = undefined;
    if (std.c.fstat(file.handle, &native_stat) != 0) return error.ExecutableBindingDrift;
    if (stat.kind != .file or
        !std.c.S.ISREG(native_stat.mode) or
        native_stat.uid != std.c.getuid() or
        native_stat.nlink != 1 or
        stat.permissions.toMode() & 0o777 != StagedExecutableMode)
    {
        return error.ExecutableBindingDrift;
    }
    const fingerprint = try openFileFingerprintAlloc(allocator, file, stat.size);
    defer allocator.free(fingerprint);
    if (!std.mem.eql(u8, fingerprint, expected_fingerprint)) return error.ExecutableBindingDrift;
    return stat;
}

fn bindExecutableInStoreAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    store_root: []const u8,
) !ExecutableBinding {
    if (raw.len == 0) return error.MissingExecutor;
    if (!std.fs.path.isAbsolute(raw)) return error.ExecutablePathNotAbsolute;
    const origin_path = try std.fs.path.resolve(allocator, &.{raw});
    errdefer allocator.free(origin_path);
    if (!std.mem.eql(u8, origin_path, raw)) return error.ExecutablePathNotCanonical;
    try durable_store.rejectSymlinkComponents(origin_path);
    const origin_file = try std.Io.Dir.openFileAbsolute(defaultIo(), origin_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer origin_file.close(defaultIo());
    const origin_before = try origin_file.stat(defaultIo());
    if (origin_before.kind != .file) return error.ExecutableNotRegularFile;
    if (origin_before.permissions.toMode() & 0o111 == 0) return error.ExecutableNotExecutable;
    var native_origin_before: std.c.Stat = undefined;
    if (std.c.fstat(origin_file.handle, &native_origin_before) != 0) return error.ExecutableBindingDrift;
    if (native_origin_before.flags & MacOSRestrictedFileFlag != 0) {
        return error.UnsupportedPlatformExecutable;
    }
    const bytes = try readOpenFileBytesAlloc(allocator, origin_file, origin_before.size);
    defer allocator.free(bytes);
    if (try executableBytesContainPlatformCode(bytes)) return error.UnsupportedPlatformExecutable;
    const origin_after = try origin_file.stat(defaultIo());
    var native_origin_after: std.c.Stat = undefined;
    if (std.c.fstat(origin_file.handle, &native_origin_after) != 0) return error.ExecutableBindingDrift;
    if (origin_before.inode != origin_after.inode or
        origin_before.size != origin_after.size or
        origin_before.permissions.toMode() != origin_after.permissions.toMode() or
        origin_before.ctime.nanoseconds != origin_after.ctime.nanoseconds or
        native_origin_before.dev != native_origin_after.dev or
        native_origin_before.ino != native_origin_after.ino or
        native_origin_before.flags != native_origin_after.flags)
    {
        return error.ExecutableBindingDrift;
    }
    const fingerprint = try attestation.digestBytesAlloc(allocator, bytes);
    errdefer allocator.free(fingerprint);
    try ensurePrivateExecutableStore(store_root);
    const spawn_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.exec",
        .{ store_root, fingerprint["sha256:".len..] },
    );
    errdefer allocator.free(spawn_path);
    try materializeStagedExecutable(store_root, spawn_path, bytes);
    try durable_store.rejectSymlinkComponents(spawn_path);
    const staged_file = try std.Io.Dir.openFileAbsolute(defaultIo(), spawn_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    errdefer staged_file.close(defaultIo());
    const staged_stat = try validateStagedExecutableFile(allocator, staged_file, fingerprint);
    return .{
        .origin_path = origin_path,
        .spawn_path = spawn_path,
        .file = staged_file,
        .inode = staged_stat.inode,
        .size = staged_stat.size,
        .mode = staged_stat.permissions.toMode(),
        .ctime_nanoseconds = staged_stat.ctime.nanoseconds,
        .fingerprint = fingerprint,
    };
}

fn validateHeldExecutableAtSpawn(
    allocator: std.mem.Allocator,
    binding: *const ExecutableBinding,
) !void {
    const held_stat = try validateStagedExecutableFile(allocator, binding.file, binding.fingerprint);
    if (held_stat.kind != .file or
        held_stat.inode != binding.inode or
        held_stat.size != binding.size or
        held_stat.permissions.toMode() != binding.mode or
        held_stat.ctime.nanoseconds != binding.ctime_nanoseconds)
    {
        return error.ExecutableBindingDrift;
    }
}

fn validateExecutableAtSpawn(
    allocator: std.mem.Allocator,
    binding: *const ExecutableBinding,
) !void {
    try validateHeldExecutableAtSpawn(allocator, binding);
    try durable_store.rejectSymlinkComponents(binding.spawn_path);
    const reopened = try std.Io.Dir.openFileAbsolute(defaultIo(), binding.spawn_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer reopened.close(defaultIo());
    const reopened_stat = try validateStagedExecutableFile(allocator, reopened, binding.fingerprint);
    if (reopened_stat.kind != .file or
        reopened_stat.inode != binding.inode or
        reopened_stat.size != binding.size or
        reopened_stat.permissions.toMode() != binding.mode or
        reopened_stat.ctime.nanoseconds != binding.ctime_nanoseconds)
    {
        return error.ExecutableBindingDrift;
    }
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(defaultIo(), path, .{}) catch return false;
    return true;
}

fn deleteFileIfExists(path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(defaultIo(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn readLinkAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buffer: [4096]u8 = undefined;
    const length = try std.Io.Dir.readLinkAbsolute(defaultIo(), path, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn deleteTree(path: []const u8) !void {
    return std.Io.Dir.cwd().deleteTree(defaultIo(), path);
}

fn validatePathComponent(value: []const u8) !void {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return error.InvalidId;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return error.InvalidId;
}

fn validateFingerprint(value: []const u8) !void {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return error.InvalidFingerprint;
    for (value[7..]) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidFingerprint;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |value_object| value_object,
        else => error.ExpectedObject,
    };
}

fn requiredObject(parent: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(parent.get(key) orelse return error.MissingField);
}

fn requiredArray(parent: std.json.ObjectMap, key: []const u8) !std.json.Array {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .array => |array| array,
        else => error.ExpectedArray,
    };
}

fn requiredString(parent: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return optionalString(parent, key) orelse error.MissingField;
}

fn optionalString(parent: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = parent.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn requiredBool(parent: std.json.ObjectMap, key: []const u8) !bool {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.ExpectedBool,
    };
}

fn optionalBool(parent: std.json.ObjectMap, key: []const u8) ?bool {
    const value = parent.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn requiredU64(parent: std.json.ObjectMap, key: []const u8) !u64 {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.ExpectedUnsigned,
        .number_string => |raw| std.fmt.parseInt(u64, raw, 10),
        else => error.ExpectedUnsigned,
    };
}

fn requiredI64(parent: std.json.ObjectMap, key: []const u8) !i64 {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| integer,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10),
        else => error.ExpectedInteger,
    };
}

fn arrayContains(array: std.json.Array, wanted: []const u8) bool {
    for (array.items) |value| switch (value) {
        .string => |text| if (std.mem.eql(u8, text, wanted)) return true,
        else => {},
    };
    return false;
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

fn processExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(@as(u32, 128) + @intFromEnum(signal), @as(u32, 255))),
        .stopped, .unknown => 1,
    };
}

fn unixSeconds() i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(defaultIo()).nanoseconds, std.time.ns_per_s));
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn printJson(value: anytype) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &stdout_writer.interface);
    try stdout_writer.interface.writeByte('\n');
}

fn writeStringMember(writer: anytype, key: []const u8, value: []const u8, comma: bool) !void {
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
    if (comma) try writer.writeByte(',');
}

fn writeCapabilitySealMembers(writer: anytype, identity: ?CapabilitySealIdentity) !void {
    try writer.writeAll(",\"capability_sealed\":");
    try writer.writeAll(if (identity != null) "true" else "false");
    if (identity) |seal| {
        try writer.writeByte(',');
        try writeStringMember(writer, "capability_profile_id", seal.profile_id, true);
        try writeStringMember(writer, "capability_effect_policy_fingerprint", seal.effect_policy_fingerprint, true);
    } else {
        try writer.writeByte(',');
    }
    try writer.writeAll("\"os_confinement\":false");
}

fn writeRawMember(writer: anytype, key: []const u8, value: []const u8, comma: bool) !void {
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try writer.writeAll(value);
    if (comma) try writer.writeByte(',');
}

fn writeOptionalStringMember(
    writer: anytype,
    key: []const u8,
    value: ?[]const u8,
    comma: bool,
) !void {
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    if (comma) try writer.writeByte(',');
}

test "lane lookup preserves the opaque manifest binding" {
    const raw = hctp_fixtures.valid_null_trial;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "trial.json", .data = raw });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "trial.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var loaded = try loadLane(std.testing.allocator, path, "lane-null-a1");
    defer loaded.parsed.deinit();
    try std.testing.expectEqualStrings("pair-null-001", loaded.view.pair_id);
    try std.testing.expectEqualStrings("arm-1", loaded.view.arm_id);
}

fn factorTrialAlloc(
    allocator: std.mem.Allocator,
    materialization_ref: []const u8,
    materialization_fingerprint: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-trial/v1\",\"trial_id\":\"trial-factor\",\"purpose\":\"calibration_positive\",\"arms\":[{{\"arm_id\":\"arm-0\",\"value_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"materialization_ref\":{f},\"materialization_fingerprint\":{f}}},{{\"arm_id\":\"arm-1\",\"value_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"materialization_ref\":{f},\"materialization_fingerprint\":{f}}}],\"factor\":{{\"kind\":\"instruction_bundle\",\"allowed_difference_roots\":[]}},\"units\":[{{\"unit_id\":\"unit-factor\",\"scenario_id\":\"scenario-factor\",\"source_profile\":{{\"kind\":\"direct\"}},\"pairs\":[{{\"pair_id\":\"pair-factor\",\"shared_seed\":null,\"lanes\":{{\"arm-0\":{{\"lane_id\":\"lane-x\"}},\"arm-1\":{{\"lane_id\":\"lane-y\"}}}}}}]}}],\"execution\":{{\"runner_contract_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"environment_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\",\"replay_policy_fingerprint\":\"sha256:3333333333333333333333333333333333333333333333333333333333333333\",\"effect_policy_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\",\"model_policy_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\",\"maximum_lane_duration_ms\":1000,\"maximum_tokens_per_lane\":1000}}}}",
        .{
            std.json.fmt(materialization_ref, .{}),
            std.json.fmt(materialization_fingerprint, .{}),
            std.json.fmt(materialization_ref, .{}),
            std.json.fmt(materialization_fingerprint, .{}),
        },
    );
}

test "non-target factor resolves immutable Git JSON and archives canonical bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo);
    const factor_path = try std.fs.path.join(allocator, &.{ repo, "factor.json" });
    defer allocator.free(factor_path);
    try durable_store.writeTextAtomic(allocator, factor_path, "{\"z\":2,\"a\":1}\n");
    const init_output = try runGitStdoutAlloc(allocator, repo, &.{ "init", "-q" });
    allocator.free(init_output);
    const oid_raw = try runGitStdoutAlloc(allocator, repo, &.{ "hash-object", "-w", "factor.json" });
    defer allocator.free(oid_raw);
    const oid = std.mem.trim(u8, oid_raw, " \t\r\n");
    const ref = try std.fmt.allocPrint(allocator, "git-blob-json:{s}", .{oid});
    defer allocator.free(ref);
    const canonical = try canonicalJsonTextAlloc(allocator, "{\"z\":2,\"a\":1}\n");
    defer allocator.free(canonical);
    const fingerprint = try attestation.digestBytesAlloc(allocator, canonical);
    defer allocator.free(fingerprint);
    const trial = try factorTrialAlloc(allocator, ref, fingerprint);
    defer allocator.free(trial);
    const trial_path = try std.fs.path.join(allocator, &.{ repo, "trial.json" });
    defer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    var loaded = try loadLane(allocator, trial_path, "lane-x");
    defer loaded.parsed.deinit();
    const workspace = try std.fs.path.join(allocator, &.{ repo, "lane", "workspace" });
    defer allocator.free(workspace);
    const workspace_ref = try std.fs.path.join(allocator, &.{ workspace, "factor-materialization.json" });
    defer allocator.free(workspace_ref);
    const archive_ref = try std.fs.path.join(allocator, &.{ repo, "lane", "evidence", "factor-materialization.json" });
    defer allocator.free(archive_ref);
    const materialization = try resolveFactorMaterializationAlloc(
        allocator,
        loaded.view,
        repo,
        workspace_ref,
        archive_ref,
    );
    defer materialization.deinit(allocator);
    try std.testing.expect(materialization.present);
    try std.testing.expectEqualStrings("{\"a\":1,\"z\":2}", materialization.canonical_bytes.?);
    try durable_store.ensureDirectoryPathNoSymlinks(workspace);
    const evidence_dir = std.fs.path.dirname(archive_ref) orelse return error.TestPathInvalid;
    try durable_store.ensureDirectoryPathNoSymlinks(evidence_dir);
    try persistFactorMaterialization(allocator, materialization);
    const archived = try durable_store.readRegularFileNoSymlink(allocator, archive_ref, MaxInputBytes);
    defer allocator.free(archived);
    try std.testing.expectEqualStrings(materialization.canonical_bytes.?, archived);
    const archived_stat = try std.Io.Dir.cwd().statFile(defaultIo(), archive_ref, .{});
    try std.testing.expect(archived_stat.permissions.readOnly());

    const request = try buildExecutorRequestAlloc(
        allocator,
        loaded.view,
        workspace,
        "unused-decision-context.json",
        "presented-input.json",
        "sha256:6666666666666666666666666666666666666666666666666666666666666666",
        "sha256:7777777777777777777777777777777777777777777777777777777777777777",
        materialization,
        .{
            .present = false,
            .arm_value_fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .snapshot_ref = "artifact:baseline",
            .snapshot_fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .carrier_bytes = null,
            .carrier_fingerprint = null,
            .workspace_ref = "unused-target-carrier",
            .archive_ref = "unused-target-archive",
            .package_root = "unused-target-package",
        },
    );
    defer allocator.free(request);
    var request_parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer request_parsed.deinit();
    const request_root = try object(request_parsed.value);
    try std.testing.expectEqualStrings(workspace_ref, try requiredString(request_root, "target_materialization_ref"));
    try std.testing.expectEqualStrings(ref, try requiredString(request_root, "factor_materialization_ref"));
    try std.testing.expectEqualStrings(workspace_ref, try requiredString(request_root, "factor_materialization_archive_ref"));

    const null_trial = try std.mem.replaceOwned(
        u8,
        allocator,
        trial,
        "\"kind\":\"instruction_bundle\"",
        "\"kind\":\"null\"",
    );
    defer allocator.free(null_trial);
    const null_path = try std.fs.path.join(allocator, &.{ repo, "null-trial.json" });
    defer allocator.free(null_path);
    try durable_store.writeTextAtomic(allocator, null_path, null_trial);
    var null_loaded = try loadLane(allocator, null_path, "lane-x");
    defer null_loaded.parsed.deinit();
    const null_materialization = try resolveFactorMaterializationAlloc(
        allocator,
        null_loaded.view,
        repo,
        workspace_ref,
        archive_ref,
    );
    defer null_materialization.deinit(allocator);
    try std.testing.expect(null_materialization.present);
    try std.testing.expectEqualStrings(canonical, null_materialization.canonical_bytes.?);

    const observed = try std.fmt.allocPrint(
        allocator,
        "{{\"factor_materialization_ref_observed\":{f},\"factor_materialization_fingerprint_observed\":{f}}}",
        .{ std.json.fmt(ref, .{}), std.json.fmt(fingerprint, .{}) },
    );
    defer allocator.free(observed);
    var observed_parsed = try std.json.parseFromSlice(std.json.Value, allocator, observed, .{});
    defer observed_parsed.deinit();
    try validateFactorMaterializationObservation(try object(observed_parsed.value), materialization);
}

test "non-target factor rejects mutable refs missing objects and observed tampering" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo);
    const init_output = try runGitStdoutAlloc(allocator, repo, &.{ "init", "-q" });
    allocator.free(init_output);
    const fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const mutable_trial = try factorTrialAlloc(allocator, "artifact:mutable", fingerprint);
    defer allocator.free(mutable_trial);
    const mutable_path = try std.fs.path.join(allocator, &.{ repo, "mutable.json" });
    defer allocator.free(mutable_path);
    try durable_store.writeTextAtomic(allocator, mutable_path, mutable_trial);
    var mutable_loaded = try loadLane(allocator, mutable_path, "lane-x");
    defer mutable_loaded.parsed.deinit();
    try std.testing.expectError(
        error.FactorMaterializationReferenceUnsupported,
        resolveFactorMaterializationAlloc(allocator, mutable_loaded.view, repo, "workspace-factor.json", "archive-factor.json"),
    );

    const missing_ref = "git-blob-json:0000000000000000000000000000000000000000";
    const missing_trial = try factorTrialAlloc(allocator, missing_ref, fingerprint);
    defer allocator.free(missing_trial);
    const missing_path = try std.fs.path.join(allocator, &.{ repo, "missing.json" });
    defer allocator.free(missing_path);
    try durable_store.writeTextAtomic(allocator, missing_path, missing_trial);
    var missing_loaded = try loadLane(allocator, missing_path, "lane-x");
    defer missing_loaded.parsed.deinit();
    try std.testing.expectError(
        error.FactorMaterializationUnavailable,
        resolveFactorMaterializationAlloc(allocator, missing_loaded.view, repo, "workspace-factor.json", "archive-factor.json"),
    );

    const materialization = FactorMaterialization{
        .present = true,
        .ref = missing_ref,
        .fingerprint = fingerprint,
        .canonical_bytes = null,
        .workspace_ref = "workspace-factor.json",
        .archive_ref = "archive-factor.json",
    };
    var tampered = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"factor_materialization_ref_observed\":\"git-blob-json:1111111111111111111111111111111111111111\",\"factor_materialization_fingerprint_observed\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
        .{},
    );
    defer tampered.deinit();
    try std.testing.expectError(
        error.FactorMaterializationObservationMismatch,
        validateFactorMaterializationObservation(try object(tampered.value), materialization),
    );
}

test "runner-global claim rejects copied-store fresh-lease retry and admits independent registration" {
    const raw = hctp_fixtures.valid_null_trial;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const trial = try object(parsed.value);
    const arm = try object((try requiredArray(trial, "arms")).items[0]);
    const unit = try object((try requiredArray(trial, "units")).items[0]);
    const view = LaneView{
        .trial = trial,
        .trial_id = "trial-null-001",
        .purpose = "calibration_null",
        .unit_id = "unit-null-001",
        .scenario_id = "scenario-holdout",
        .pair_id = "pair-null-001",
        .pair = try object((try requiredArray(unit, "pairs")).items[0]),
        .lane_id = "lane-null-a0",
        .arm_id = "arm-0",
        .arm = arm,
        .source_profile = unit.get("source_profile").?,
        .execution = try requiredObject(trial, "execution"),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const claim_store = try std.fs.path.join(std.testing.allocator, &.{ root, "runner-claims" });
    defer std.testing.allocator.free(claim_store);
    const receipt_a = try std.fs.path.join(std.testing.allocator, &.{ root, "repo-copy-a", "receipts" });
    defer std.testing.allocator.free(receipt_a);
    const receipt_b = try std.fs.path.join(std.testing.allocator, &.{ root, "repo-copy-b", "receipts" });
    defer std.testing.allocator.free(receipt_b);
    const paths_a = try lanePathsAlloc(
        std.testing.allocator,
        receipt_a,
        claim_store,
        view.trial_id,
        view.lane_id,
    );
    defer paths_a.deinit(std.testing.allocator);
    const paths_b = try lanePathsAlloc(
        std.testing.allocator,
        receipt_b,
        claim_store,
        view.trial_id,
        view.lane_id,
    );
    defer paths_b.deinit(std.testing.allocator);
    const registration = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const start = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const lease = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const path = try claimPathAlloc(std.testing.allocator, paths_a.claim, registration);
    defer std.testing.allocator.free(path);
    try claimLane(std.testing.allocator, path, view, registration, start, lease);
    const fresh_start = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const fresh_lease = "sha256:9999999999999999999999999999999999999999999999999999999999999999";
    const copied_path = try claimPathAlloc(std.testing.allocator, paths_b.claim, registration);
    defer std.testing.allocator.free(copied_path);
    try std.testing.expectEqualStrings(path, copied_path);
    try std.testing.expectError(
        error.LaneAlreadyClaimed,
        claimLane(std.testing.allocator, copied_path, view, registration, fresh_start, fresh_lease),
    );
    const persisted_claim = try readFileAlloc(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(persisted_claim);
    var persisted = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, persisted_claim, .{});
    defer persisted.deinit();
    const persisted_root = try object(persisted.value);
    try std.testing.expectEqualStrings(start, try requiredString(persisted_root, "lane_started_event_digest"));
    try std.testing.expectEqualStrings(lease, try requiredString(persisted_root, "lane_lease_digest"));
    const independent_registration = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const independent_start = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const independent_path = try claimPathAlloc(std.testing.allocator, paths_b.claim, independent_registration);
    defer std.testing.allocator.free(independent_path);
    try std.testing.expect(!std.mem.eql(u8, path, independent_path));
    try claimLane(
        std.testing.allocator,
        independent_path,
        view,
        independent_registration,
        independent_start,
        lease,
    );
}

test "registration-keyed terminal payload lookup ignores independent lane history" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    const paths = try lanePathsAlloc(
        allocator,
        receipt_dir,
        root,
        "trial-registration-history",
        "lane-registration-history",
    );
    defer paths.deinit(allocator);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.claim);

    for (0..70) |index| {
        const registration_source = try std.fmt.allocPrint(allocator, "historical-registration-{d}", .{index});
        defer allocator.free(registration_source);
        const registration_digest = try attestation.digestBytesAlloc(allocator, registration_source);
        defer allocator.free(registration_digest);
        const receipt = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hylo-run-receipt/v1\",\"trial_id\":\"trial-registration-history\",\"lane_id\":\"lane-registration-history\",\"lineage\":{{\"registration_event_digest\":{f}}}}}",
            .{std.json.fmt(registration_digest, .{})},
        );
        defer allocator.free(receipt);
        try persistTerminalPayload(
            allocator,
            paths,
            "trial-registration-history",
            "lane-registration-history",
            registration_digest,
            receipt,
        );
    }

    const current_registration = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const current_receipt =
        "{\"schema\":\"hylo-run-receipt/v1\",\"trial_id\":\"trial-registration-history\",\"lane_id\":\"lane-registration-history\",\"lineage\":{\"registration_event_digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}";
    try persistTerminalPayload(
        allocator,
        paths,
        "trial-registration-history",
        "lane-registration-history",
        current_registration,
        current_receipt,
    );
    const current = try loadTerminalPayloadAlloc(
        allocator,
        paths,
        "trial-registration-history",
        "lane-registration-history",
        current_registration,
    );
    defer current.deinit(allocator);
    try std.testing.expectEqualStrings(current_registration, current.registration_digest);
    try std.testing.expectEqualStrings(current_receipt, current.receipt);
    try std.testing.expectError(
        error.ControlArtifactConflict,
        findUniqueRegistrationDigestAlloc(allocator, paths.claim, .terminal_payload),
    );
}

test "claim-only lane remains nonterminal and cleanup fails closed" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        hctp_fixtures.valid_null_trial,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const trial = try object(parsed.value);
    const unit = try object((try requiredArray(trial, "units")).items[0]);
    const view = LaneView{
        .trial = trial,
        .trial_id = "trial-null-001",
        .purpose = "calibration_null",
        .unit_id = "unit-null-001",
        .scenario_id = "scenario-holdout",
        .pair_id = "pair-null-001",
        .pair = try object((try requiredArray(unit, "pairs")).items[0]),
        .lane_id = "lane-null-a0",
        .arm_id = "arm-0",
        .arm = try object((try requiredArray(trial, "arms")).items[0]),
        .source_profile = unit.get("source_profile").?,
        .execution = try requiredObject(trial, "execution"),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    const paths = try lanePathsAlloc(allocator, receipt_dir, root, view.trial_id, view.lane_id);
    defer paths.deinit(allocator);
    const registration = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const claim_path = try claimPathAlloc(allocator, paths.claim, registration);
    defer allocator.free(claim_path);
    try claimLane(
        allocator,
        claim_path,
        view,
        registration,
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
    try std.testing.expect(try hasVerifiedClaimArtifactAlloc(allocator, paths, registration));
    try std.testing.expect(!try regularFileExistsNoFollow(paths.receipt));
    try std.testing.expect(!(try hasAnyControlArtifactAlloc(
        allocator,
        paths.claim,
        registration,
        .terminal_payload,
    )));
    try std.testing.expectError(error.CleanupBeforeTerminal, cmdCleanup(allocator, .{
        .command = .cleanup,
        .trial_id = view.trial_id,
        .lane_id = view.lane_id,
        .receipt_dir = receipt_dir,
        .claim_store_override = root,
    }));
    try std.testing.expect(!pathExists(paths.workspace));
}

fn bindTestRunnerContractAlloc(
    allocator: std.mem.Allocator,
    trial: []const u8,
    executor: []const u8,
    ledger: []const u8,
) ![]u8 {
    const runner_fingerprint = try currentExecutableFingerprintAlloc(allocator);
    defer allocator.free(runner_fingerprint);
    const executor_fingerprint = try fileFingerprintAlloc(allocator, executor);
    defer allocator.free(executor_fingerprint);
    const ledger_fingerprint = try fileFingerprintAlloc(allocator, ledger);
    defer allocator.free(ledger_fingerprint);
    const contract = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-hylo-runner/v1\",\"executor_binary_fingerprint\":{f},\"ledger_binary_fingerprint\":{f},\"executor_authority\":{{\"producer_id\":\"cas-trial-executor\",\"key_id\":\"runner-key\",\"binary_fingerprint\":{f},\"authorized_observations\":[\"runtime\",\"isolation\",\"effects\",\"terminal\",\"evidence\",\"execution_audit\",\"native_receipt\"]}},\"ledger_authority\":{{\"producer_id\":\"hylo-ledger\",\"key_id\":\"runner-key\",\"binary_fingerprint\":{f}}},\"atomic_claim\":true,\"fresh_workspace\":true,\"fresh_thread\":true,\"materializes_opaque_arm\":true,\"maximum_handles_per_lane\":1,\"maximum_retries_per_lane\":0}}",
        .{ std.json.fmt(executor_fingerprint, .{}), std.json.fmt(ledger_fingerprint, .{}), std.json.fmt(executor_fingerprint, .{}), std.json.fmt(ledger_fingerprint, .{}) },
    );
    defer allocator.free(contract);
    const contract_fingerprint = try digestJsonTextAlloc(allocator, contract);
    defer allocator.free(contract_fingerprint);
    const replacement = try std.fmt.allocPrint(
        allocator,
        "\"runner_contract_fingerprint\": {f},\n    \"runner_contract\": {s}",
        .{ std.json.fmt(contract_fingerprint, .{}), contract },
    );
    defer allocator.free(replacement);
    const needle = "\"runner_contract_fingerprint\": \"sha256:4444444444444444444444444444444444444444444444444444444444444444\"";
    if (std.mem.count(u8, trial, needle) != 1) return error.FixtureShapeChanged;
    const contract_bound = try std.mem.replaceOwned(u8, allocator, trial, needle, replacement);
    defer allocator.free(contract_bound);
    const authority_needle = "\"binary_fingerprint\": \"sha256:3333333333333333333333333333333333333333333333333333333333333333\",\n      \"key_id\": \"runner-key\"";
    const authority_replacement = try std.fmt.allocPrint(
        allocator,
        "\"binary_fingerprint\": {f},\n      \"key_id\": \"runner-key\"",
        .{std.json.fmt(runner_fingerprint, .{})},
    );
    defer allocator.free(authority_replacement);
    if (std.mem.count(u8, contract_bound, authority_needle) != 1) return error.FixtureShapeChanged;
    return std.mem.replaceOwned(u8, allocator, contract_bound, authority_needle, authority_replacement);
}

fn receiptBoundTestTrialAlloc(
    allocator: std.mem.Allocator,
    trial: []const u8,
    seed: [32]u8,
    executor: []const u8,
    ledger: []const u8,
) ![]u8 {
    const public_key = try attestation.publicKeyBase64Alloc(allocator, seed);
    defer allocator.free(public_key);
    const runner_fingerprint = try currentExecutableFingerprintAlloc(allocator);
    defer allocator.free(runner_fingerprint);
    const executor_fingerprint = try fileFingerprintAlloc(allocator, executor);
    defer allocator.free(executor_fingerprint);
    const ledger_fingerprint = try fileFingerprintAlloc(allocator, ledger);
    defer allocator.free(ledger_fingerprint);
    const trust = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"policy-cas-test\",\"keys\":[{{\"key_id\":\"runner-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"cas-trial\",\"cas-trial-executor\",\"hylo-ledger\"],\"producer_binary_fingerprints\":[{f},{f},{f}]}}],\"separation\":{{\"runner_and_pair_grader_distinct\":true,\"materializer_and_pair_grader_distinct\":true,\"human_confirmation_required_for_human_grade\":true}}}}",
        .{ std.json.fmt(public_key, .{}), std.json.fmt(runner_fingerprint, .{}), std.json.fmt(executor_fingerprint, .{}), std.json.fmt(ledger_fingerprint, .{}) },
    );
    defer allocator.free(trust);
    const trust_fingerprint = try digestJsonTextAlloc(allocator, trust);
    defer allocator.free(trust_fingerprint);
    const level_replaced = try std.mem.replaceOwned(
        u8,
        allocator,
        trial,
        "\"required_level\": \"precommitted\"",
        "\"required_level\": \"receipt_bound\"",
    );
    defer allocator.free(level_replaced);
    const replacement = try std.fmt.allocPrint(
        allocator,
        "\"trust_policy_fingerprint\": {f},\n    \"trust_policy\": {s},",
        .{ std.json.fmt(trust_fingerprint, .{}), trust },
    );
    defer allocator.free(replacement);
    const needle = "\"trust_policy_fingerprint\": \"sha256:7777777777777777777777777777777777777777777777777777777777777777\",";
    if (std.mem.count(u8, level_replaced, needle) != 1) return error.FixtureShapeChanged;
    return std.mem.replaceOwned(u8, allocator, level_replaced, needle, replacement);
}

fn testRunFailureOptions(
    trial_path: []const u8,
    receipt_dir: []const u8,
    executor: []const u8,
    ledger: []const u8,
    lease_fd: std.posix.fd_t,
    input_fd: std.posix.fd_t,
    input_fingerprint: []const u8,
    signing_seed_fd: ?std.posix.fd_t,
    claim_store: []const u8,
) Options {
    return .{
        .command = .run,
        .trial_path = trial_path,
        .lane_id = "lane-null-a0",
        .repo = std.fs.path.dirname(trial_path) orelse ".",
        .receipt_dir = receipt_dir,
        .registration_event_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .start_event_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .lease_fd = lease_fd,
        .input_fd = input_fd,
        .presented_input_fingerprint = input_fingerprint,
        .executor = executor,
        .ledger = ledger,
        .signing_seed_fd = signing_seed_fd,
        .producer_id = "cas-trial",
        .producer_key_id = "runner-key",
        .json = true,
        .claim_store_override = claim_store,
    };
}

fn testPipeWithBytes(bytes: []const u8) !std.posix.fd_t {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.TestFdSetupFailed;
    errdefer closeOwnedFd(pipe_fds[0]);
    const writer = std.Io.File{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } };
    errdefer writer.close(std.testing.io);
    try writer.writeStreamingAll(std.testing.io, bytes);
    writer.close(std.testing.io);
    return pipe_fds[0];
}

fn writeMockLaneMaterializationLedgerAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    raw_lease: []const u8,
) ![]u8 {
    const lease_digest = try attestation.digestBytesAlloc(allocator, raw_lease);
    defer allocator.free(lease_digest);
    const path = try std.fs.path.join(allocator, &.{ root, "mock-ledger.sh" });
    errdefer allocator.free(path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nrepo=\nwhile [ \"$#\" -gt 0 ]; do if [ \"$1\" = --repo ]; then repo=$2; shift 2; else shift; fi; done\ntrial_fingerprint=$(cat \"$repo/mock-trial-fingerprint\") || exit 9\ninput_fingerprint=$(cat \"$repo/mock-input-fingerprint\") || exit 9\nprintf '%s\\n' '{{\"schema\":\"hylo-lane-materialization-claim/v1\",\"campaign_id\":\"campaign-null-001\",\"trial_id\":\"trial-null-001\",\"trial_fingerprint\":\"'\"$trial_fingerprint\"'\",\"unit_id\":\"unit-null-001\",\"scenario_id\":\"scenario-holdout\",\"pair_id\":\"pair-null-001\",\"lane_id\":\"lane-null-a0\",\"opaque_arm_id\":\"arm-0\",\"registration_event_digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"lane_started_event_digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"lane_lease_digest\":\"{s}\",\"presented_input_fingerprint\":\"'\"$input_fingerprint\"'\",\"arm_materialization\":{{\"schema\":\"hylo-arm-materialization/v1\",\"arm_id\":\"arm-0\",\"value_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"materialization_ref\":\"artifact:baseline\",\"materialization_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"materialization\":null}}}}'\n",
        .{lease_digest},
    );
    defer allocator.free(script);
    try durable_store.writeTextAtomic(allocator, path, script);
    var file = try std.Io.Dir.cwd().openFile(defaultIo(), path, .{});
    defer file.close(defaultIo());
    try file.setPermissions(defaultIo(), .fromMode(0o500));
    return path;
}

fn writeMockTrialFingerprint(
    allocator: std.mem.Allocator,
    root: []const u8,
    trial: []const u8,
) !void {
    const fingerprint = try digestJsonTextAlloc(allocator, trial);
    defer allocator.free(fingerprint);
    const path = try std.fs.path.join(allocator, &.{ root, "mock-trial-fingerprint" });
    defer allocator.free(path);
    try durable_store.writeTextAtomic(allocator, path, fingerprint);
}

fn writeMockInputFingerprint(
    allocator: std.mem.Allocator,
    root: []const u8,
    fingerprint: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, "mock-input-fingerprint" });
    defer allocator.free(path);
    try durable_store.writeTextAtomic(allocator, path, fingerprint);
}

test "runner contract rejects a matching executor without independent binary authority" {
    const allocator = std.testing.allocator;
    const executor = "/usr/bin/false";
    const ledger = "/usr/bin/true";
    const bound = try bindTestRunnerContractAlloc(allocator, hctp_fixtures.valid_null_trial, executor, ledger);
    defer allocator.free(bound);
    const seed = [_]u8{0x71} ** 32;
    const trial = try receiptBoundTestTrialAlloc(allocator, bound, seed, executor, ledger);
    defer allocator.free(trial);
    const runner_fingerprint = try currentExecutableFingerprintAlloc(allocator);
    defer allocator.free(runner_fingerprint);
    const executor_fingerprint = try fileFingerprintAlloc(allocator, executor);
    defer allocator.free(executor_fingerprint);
    const ledger_fingerprint = try fileFingerprintAlloc(allocator, ledger);
    defer allocator.free(ledger_fingerprint);
    const authority_needle = try std.fmt.allocPrint(
        allocator,
        "\"producer_binary_fingerprints\":[{f},{f},{f}]",
        .{ std.json.fmt(runner_fingerprint, .{}), std.json.fmt(executor_fingerprint, .{}), std.json.fmt(ledger_fingerprint, .{}) },
    );
    defer allocator.free(authority_needle);
    const authority_replacement = try std.fmt.allocPrint(
        allocator,
        "\"producer_binary_fingerprints\":[{f},\"sha256:dededededededededededededededededededededededededededededededede\",{f}]",
        .{ std.json.fmt(runner_fingerprint, .{}), std.json.fmt(ledger_fingerprint, .{}) },
    );
    defer allocator.free(authority_replacement);
    const tampered = try std.mem.replaceOwned(u8, allocator, trial, authority_needle, authority_replacement);
    defer allocator.free(tampered);
    try std.testing.expect(!std.mem.eql(u8, tampered, trial));
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tampered, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    try std.testing.expectError(
        error.ExecutorAuthorityUnauthorized,
        validateRunnerContract(
            allocator,
            root,
            try requiredObject(root, "execution"),
            runner_fingerprint,
            executor_fingerprint,
            ledger_fingerprint,
        ),
    );
}

test "capability seal binds attested executor policy and CAS observations" {
    const allocator = std.testing.allocator;
    const runner_fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const executor_fingerprint = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const ledger_fingerprint = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const effect_policy_fingerprint = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const contract = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-hylo-runner/v1\",\"executor_binary_fingerprint\":{f},\"ledger_binary_fingerprint\":{f},\"executor_authority\":{{\"producer_id\":\"cas-trial-executor\",\"key_id\":\"runner-key\",\"binary_fingerprint\":{f},\"authorized_observations\":[\"runtime\",\"isolation\",\"effects\",\"terminal\",\"evidence\",\"execution_audit\",\"native_receipt\"]}},\"ledger_authority\":{{\"producer_id\":\"hylo-ledger\",\"key_id\":\"runner-key\",\"binary_fingerprint\":{f}}},\"capability_seal\":{{\"schema\":\"cas-capability-seal/v1\",\"profile_id\":\"cas-capability-sealed-v1\",\"target_data_mode\":\"cas-content-addressed-pre-post-equality\",\"effect_policy_fingerprint\":{f},\"effect_mediation\":\"attested-executor\",\"default_effect_decision\":\"deny\",\"cas_observations\":[\"target-package-tree\",\"execution-tree\",\"output-carrier\",\"process-group\"],\"os_confinement\":false}},\"atomic_claim\":true,\"fresh_workspace\":true,\"fresh_thread\":true,\"materializes_opaque_arm\":true,\"maximum_handles_per_lane\":1,\"maximum_retries_per_lane\":0}}",
        .{
            std.json.fmt(executor_fingerprint, .{}),
            std.json.fmt(ledger_fingerprint, .{}),
            std.json.fmt(executor_fingerprint, .{}),
            std.json.fmt(ledger_fingerprint, .{}),
            std.json.fmt(effect_policy_fingerprint, .{}),
        },
    );
    defer allocator.free(contract);
    const contract_fingerprint = try digestJsonTextAlloc(allocator, contract);
    defer allocator.free(contract_fingerprint);
    const raw = try std.fmt.allocPrint(
        allocator,
        "{{\"assurance\":{{\"required_level\":\"sealed\",\"trust_policy\":{{\"keys\":[{{\"key_id\":\"runner-key\",\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"cas-trial\",\"cas-trial-executor\",\"hylo-ledger\"],\"producer_binary_fingerprints\":[{f},{f},{f}]}}]}}}},\"execution\":{{\"runner_contract_fingerprint\":{f},\"runner_contract\":{s},\"runner_authority\":{{\"producer_id\":\"cas-trial\",\"key_id\":\"runner-key\",\"binary_fingerprint\":{f}}},\"effect_policy_fingerprint\":{f}}}}}",
        .{
            std.json.fmt(runner_fingerprint, .{}),
            std.json.fmt(executor_fingerprint, .{}),
            std.json.fmt(ledger_fingerprint, .{}),
            std.json.fmt(contract_fingerprint, .{}),
            contract,
            std.json.fmt(runner_fingerprint, .{}),
            std.json.fmt(effect_policy_fingerprint, .{}),
        },
    );
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    const validation = try validateRunnerContract(
        allocator,
        root,
        try requiredObject(root, "execution"),
        runner_fingerprint,
        executor_fingerprint,
        ledger_fingerprint,
    );
    const identity = validation.capability_seal orelse return error.CapabilitySealMissing;
    try std.testing.expectEqualStrings("cas-capability-sealed-v1", identity.profile_id);
    try std.testing.expectEqualStrings(effect_policy_fingerprint, identity.effect_policy_fingerprint);
}

test "executable staging rejects noncanonical origins and stage drift" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executable_path = try std.fs.path.join(allocator, &.{ root, "executor" });
    defer allocator.free(executable_path);
    const executable_store = try std.fs.path.join(allocator, &.{ root, ".executables" });
    defer allocator.free(executable_store);
    try durable_store.writeTextAtomic(allocator, executable_path, "#!/bin/sh\nexit 0\n");
    var executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), executable_path, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o500));
    executable_file.close(defaultIo());

    try std.testing.expectError(
        error.ExecutablePathNotAbsolute,
        bindExecutableInStoreAlloc(allocator, "executor", executable_store),
    );
    const link_path = try std.fs.path.join(allocator, &.{ root, "executor-link" });
    defer allocator.free(link_path);
    try std.Io.Dir.cwd().symLink(defaultIo(), executable_path, link_path, .{});
    try std.testing.expectError(
        error.SymlinkComponent,
        bindExecutableInStoreAlloc(allocator, link_path, executable_store),
    );

    const replacement_binding = try bindExecutableInStoreAlloc(allocator, executable_path, executable_store);
    defer replacement_binding.deinit(allocator);
    try tmp.dir.rename("executor", tmp.dir, "executor-original", defaultIo());
    try durable_store.writeTextAtomic(allocator, executable_path, "#!/bin/sh\nexit 0\n");
    executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), executable_path, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o500));
    executable_file.close(defaultIo());
    try validateExecutableAtSpawn(allocator, &replacement_binding);

    const mutable_path = try std.fs.path.join(allocator, &.{ root, "mutable-executor" });
    defer allocator.free(mutable_path);
    try durable_store.writeTextAtomic(allocator, mutable_path, "#!/bin/sh\nexit 0\n");
    executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), mutable_path, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o700));
    executable_file.close(defaultIo());
    const mutable_binding = try bindExecutableInStoreAlloc(allocator, mutable_path, executable_store);
    defer mutable_binding.deinit(allocator);
    var mutable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), mutable_path, .{ .mode = .read_write });
    defer mutable_file.close(defaultIo());
    try mutable_file.writePositionalAll(defaultIo(), "#!/bin/sh\nexit 1\n", 0);
    try validateExecutableAtSpawn(allocator, &mutable_binding);

    const staged_replacement = try allocator.dupe(u8, mutable_binding.spawn_path);
    defer allocator.free(staged_replacement);
    try std.Io.Dir.deleteFileAbsolute(defaultIo(), staged_replacement);
    try durable_store.writeTextAtomic(allocator, staged_replacement, "#!/bin/sh\nexit 1\n");
    var staged_file = try std.Io.Dir.openFileAbsolute(defaultIo(), staged_replacement, .{});
    try staged_file.setPermissions(defaultIo(), .fromMode(StagedExecutableMode));
    staged_file.close(defaultIo());
    try std.testing.expectError(
        error.ExecutableBindingDrift,
        validateExecutableAtSpawn(allocator, &mutable_binding),
    );
    const request = try std.fs.path.join(allocator, &.{ root, "drift-request.json" });
    defer allocator.free(request);
    const result = try std.fs.path.join(allocator, &.{ root, "drift-result.json" });
    defer allocator.free(result);
    try std.testing.expectError(
        error.ExecutableBindingDrift,
        runExecutorWithTempRoot(allocator, &mutable_binding, request, result, root, root, 1_000),
    );
}

test "restricted Apple platform executables are rejected before staging" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executable_store = try std.fs.path.join(allocator, &.{ root, ".executables" });
    defer allocator.free(executable_store);
    try std.testing.expectError(
        error.UnsupportedPlatformExecutable,
        bindExecutableInStoreAlloc(allocator, "/usr/bin/false", executable_store),
    );
    try std.testing.expect(!pathExists(executable_store));

    const platform_bytes = try readFileAlloc(allocator, "/usr/bin/false", MaxInputBytes);
    defer allocator.free(platform_bytes);
    const copied_platform = try std.fs.path.join(allocator, &.{ root, "copied-platform-executable" });
    defer allocator.free(copied_platform);
    try durable_store.writeTextAtomic(allocator, copied_platform, platform_bytes);
    var copied_file = try std.Io.Dir.openFileAbsolute(defaultIo(), copied_platform, .{});
    try copied_file.setPermissions(defaultIo(), .fromMode(0o500));
    var copied_stat: std.c.Stat = undefined;
    if (std.c.fstat(copied_file.handle, &copied_stat) != 0) return error.TestExecutableStatFailed;
    try std.testing.expect(copied_stat.flags & MacOSRestrictedFileFlag == 0);
    copied_file.close(defaultIo());
    try std.testing.expectError(
        error.UnsupportedPlatformExecutable,
        bindExecutableInStoreAlloc(allocator, copied_platform, executable_store),
    );
    try std.testing.expect(!pathExists(executable_store));
}

test "origin replacement after staging executes the admitted bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const origin = try std.fs.path.join(allocator, &.{ root, "executor.sh" });
    defer allocator.free(origin);
    const executable_store = try std.fs.path.join(allocator, &.{ root, ".executables" });
    defer allocator.free(executable_store);
    try durable_store.writeTextAtomic(allocator, origin, "#!/bin/sh\nprintf 'admitted-bytes'\n");
    var origin_file = try std.Io.Dir.openFileAbsolute(defaultIo(), origin, .{});
    try origin_file.setPermissions(defaultIo(), .fromMode(0o500));
    origin_file.close(defaultIo());
    const binding = try bindExecutableInStoreAlloc(allocator, origin, executable_store);
    defer binding.deinit(allocator);

    try std.Io.Dir.deleteFileAbsolute(defaultIo(), origin);
    try durable_store.writeTextAtomic(allocator, origin, "#!/bin/sh\nprintf 'replacement-bytes'\n");
    origin_file = try std.Io.Dir.openFileAbsolute(defaultIo(), origin, .{});
    try origin_file.setPermissions(defaultIo(), .fromMode(0o500));
    origin_file.close(defaultIo());

    const request = try std.fs.path.join(allocator, &.{ root, "request.json" });
    defer allocator.free(request);
    const result = try std.fs.path.join(allocator, &.{ root, "result.json" });
    defer allocator.free(result);
    const execution = try runExecutorWithTempRoot(allocator, &binding, request, result, root, root, 1_000);
    defer allocator.free(execution.stdout);
    defer allocator.free(execution.stderr);
    try std.testing.expectEqual(@as(u8, 0), execution.exit_code);
    try std.testing.expectEqualStrings("admitted-bytes", execution.stdout);
}

test "Ledger materialization executes staged bytes after origin replacement" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const origin = try std.fs.path.join(allocator, &.{ root, "ledger.sh" });
    defer allocator.free(origin);
    const executable_store = try std.fs.path.join(allocator, &.{ root, ".executables" });
    defer allocator.free(executable_store);
    try durable_store.writeTextAtomic(allocator, origin, "#!/bin/sh\nprintf 'admitted-ledger'\n");
    var origin_file = try std.Io.Dir.openFileAbsolute(defaultIo(), origin, .{});
    try origin_file.setPermissions(defaultIo(), .fromMode(0o500));
    origin_file.close(defaultIo());
    const binding = try bindExecutableInStoreAlloc(allocator, origin, executable_store);
    defer binding.deinit(allocator);

    try std.Io.Dir.deleteFileAbsolute(defaultIo(), origin);
    try durable_store.writeTextAtomic(allocator, origin, "#!/bin/sh\nprintf 'replacement-ledger'\nexit 99\n");
    origin_file = try std.Io.Dir.openFileAbsolute(defaultIo(), origin, .{});
    try origin_file.setPermissions(defaultIo(), .fromMode(0o500));
    origin_file.close(defaultIo());

    const materialization = try runLedgerLaneMaterializationAlloc(
        allocator,
        &binding,
        root,
        "trial",
        "lane",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
    defer allocator.free(materialization);
    try std.testing.expectEqualStrings("admitted-ledger", materialization);
    try std.testing.expect(std.mem.indexOf(u8, materialization, binding.spawn_path) == null);
}

test "invented HYL1 lease cannot create a claim against authenticated start state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executor = try std.fs.path.join(allocator, &.{ root, "false-executor.sh" });
    defer allocator.free(executor);
    try durable_store.writeTextAtomic(allocator, executor, "#!/bin/sh\nexit 1\n");
    var executor_file = try std.Io.Dir.openFileAbsolute(defaultIo(), executor, .{});
    try executor_file.setPermissions(defaultIo(), .fromMode(0o500));
    executor_file.close(defaultIo());
    const ledger = try writeMockLaneMaterializationLedgerAlloc(allocator, root, "HYL1-authorized-start");
    defer allocator.free(ledger);
    const bound = try bindTestRunnerContractAlloc(allocator, hctp_fixtures.valid_null_trial, executor, ledger);
    defer allocator.free(bound);
    const seed = [_]u8{0x73} ** 32;
    const trial = try receiptBoundTestTrialAlloc(allocator, bound, seed, executor, ledger);
    defer allocator.free(trial);
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    defer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    try writeMockTrialFingerprint(allocator, root, trial);
    const lease_path = try std.fs.path.join(allocator, &.{ root, "invented-lease" });
    defer allocator.free(lease_path);
    const input_path = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(input_path);
    const seed_path = try std.fs.path.join(allocator, &.{ root, "seed" });
    defer allocator.free(seed_path);
    const invented_lease = "HYL1-invented-private-retry";
    const input = "{\"request\":\"bounded\"}";
    try durable_store.writeTextAtomic(allocator, lease_path, invented_lease);
    try durable_store.writeTextAtomic(allocator, input_path, input);
    try durable_store.writeTextAtomic(allocator, seed_path, &seed);
    const input_fingerprint = try attestation.digestBytesAlloc(allocator, input);
    defer allocator.free(input_fingerprint);
    try writeMockInputFingerprint(allocator, root, input_fingerprint);
    const lease_fd = try testPipeWithBytes(invented_lease);
    const input_fd = try testPipeWithBytes(input);
    const seed_fd = try testPipeWithBytes(&seed);
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    try std.testing.expectError(
        error.TargetMaterializationClaimMismatch,
        cmdRun(allocator, testRunFailureOptions(
            trial_path,
            receipt_dir,
            executor,
            ledger,
            lease_fd,
            input_fd,
            input_fingerprint,
            seed_fd,
            root,
        )),
    );
    const claim_path = try claimPathAlloc(
        allocator,
        root,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    defer allocator.free(claim_path);
    try std.testing.expect(!pathExists(claim_path));
}

test "target carrier tamper is rejected before terminal receipt construction" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(workspace);
    const evidence = try std.fs.path.join(allocator, &.{ root, "evidence" });
    defer allocator.free(evidence);
    try durable_store.ensureDirectoryPathNoSymlinks(workspace);
    try durable_store.ensureDirectoryPathNoSymlinks(evidence);
    const workspace_ref = try std.fs.path.join(allocator, &.{ workspace, "target-materialization.json" });
    defer allocator.free(workspace_ref);
    const archive_ref = try std.fs.path.join(allocator, &.{ evidence, "target-materialization.json" });
    defer allocator.free(archive_ref);
    const package_root = try std.fs.path.join(allocator, &.{ workspace, "target-package" });
    defer allocator.free(package_root);
    const carrier = "{\"schema\":\"cas-target-materialization/v1\",\"files\":[]}";
    const carrier_fingerprint = try attestation.digestBytesAlloc(allocator, carrier);
    defer allocator.free(carrier_fingerprint);
    const materialization = TargetMaterialization{
        .present = true,
        .arm_value_fingerprint = try allocator.dupe(u8, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .snapshot_ref = try allocator.dupe(u8, "git-revision:INDEX"),
        .snapshot_fingerprint = try allocator.dupe(u8, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .carrier_bytes = try allocator.dupe(u8, carrier),
        .carrier_fingerprint = try allocator.dupe(u8, carrier_fingerprint),
        .workspace_ref = workspace_ref,
        .archive_ref = archive_ref,
        .package_root = package_root,
    };
    defer materialization.deinit(allocator);
    try persistTargetMaterialization(allocator, materialization);
    try durable_store.writeTextAtomic(allocator, workspace_ref, "{\"tampered\":true}");
    try std.testing.expectError(
        error.ArchivedEvidenceFingerprintMismatch,
        verifyTargetMaterialization(allocator, materialization, package_root),
    );
}

test "target package exact manifest rejects mode entry and symlink drift" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "package" });
    defer allocator.free(package_root);
    const nested_root = try std.fs.path.join(allocator, &.{ package_root, "nested" });
    defer allocator.free(nested_root);
    const target_path = try std.fs.path.join(allocator, &.{ nested_root, "target.txt" });
    defer allocator.free(target_path);
    try durable_store.ensureDirectoryPathNoSymlinks(nested_root);
    const target_bytes = "registered target bytes\n";
    try durable_store.writeTextCreateNewAtomic(allocator, target_path, target_bytes, .{});
    try setTargetFileReadOnly(target_path, "100644");
    var nested_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), nested_root, .{});
    try nested_dir.setPermissions(defaultIo(), .fromMode(0o500));
    nested_dir.close(defaultIo());
    var package_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), package_root, .{});
    try package_dir.setPermissions(defaultIo(), .fromMode(0o500));
    package_dir.close(defaultIo());
    const target_fingerprint = try attestation.digestBytesAlloc(allocator, target_bytes);
    defer allocator.free(target_fingerprint);
    const carrier = try std.fmt.allocPrint(
        allocator,
        "{{\"files\":[{{\"path\":\"nested/target.txt\",\"mode\":\"100644\",\"content_fingerprint\":{f}}}]}}",
        .{std.json.fmt(target_fingerprint, .{})},
    );
    defer allocator.free(carrier);
    const materialization: TargetMaterialization = .{
        .present = true,
        .arm_value_fingerprint = null,
        .snapshot_ref = null,
        .snapshot_fingerprint = null,
        .carrier_bytes = carrier,
        .carrier_fingerprint = null,
        .workspace_ref = "unused",
        .archive_ref = "unused",
        .package_root = package_root,
    };
    const baseline = (try captureTargetPackageBaselineAlloc(allocator, materialization)) orelse
        return error.TargetPackageTreeMutation;
    defer baseline.deinit(allocator);

    nested_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), nested_root, .{});
    try nested_dir.setPermissions(defaultIo(), .fromMode(0o700));
    nested_dir.close(defaultIo());
    try std.testing.expectError(
        error.TargetPackageTreeMutation,
        observeTargetPackageAfterExecutionAlloc(allocator, materialization, baseline),
    );
    nested_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), nested_root, .{});
    try nested_dir.setPermissions(defaultIo(), .fromMode(0o500));
    nested_dir.close(defaultIo());

    package_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), package_root, .{});
    try package_dir.setPermissions(defaultIo(), .fromMode(0o700));
    package_dir.close(defaultIo());
    const extra_path = try std.fs.path.join(allocator, &.{ package_root, "extra.txt" });
    defer allocator.free(extra_path);
    try durable_store.writeTextCreateNewAtomic(allocator, extra_path, "extra", .{});
    try setTargetFileReadOnly(extra_path, "100644");
    package_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), package_root, .{});
    try package_dir.setPermissions(defaultIo(), .fromMode(0o500));
    package_dir.close(defaultIo());
    try std.testing.expectError(
        error.TargetPackageTreeMutation,
        observeTargetPackageAfterExecutionAlloc(allocator, materialization, baseline),
    );

    package_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), package_root, .{});
    try package_dir.setPermissions(defaultIo(), .fromMode(0o700));
    package_dir.close(defaultIo());
    try deleteFileIfExists(extra_path);
    const link_path = try std.fs.path.join(allocator, &.{ package_root, "target-link" });
    defer allocator.free(link_path);
    try std.Io.Dir.cwd().symLink(defaultIo(), target_path, link_path, .{});
    package_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), package_root, .{});
    try package_dir.setPermissions(defaultIo(), .fromMode(0o500));
    package_dir.close(defaultIo());
    try std.testing.expectError(
        error.TargetPackageTreeMutation,
        observeTargetPackageAfterExecutionAlloc(allocator, materialization, baseline),
    );
    package_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), package_root, .{});
    try package_dir.setPermissions(defaultIo(), .fromMode(0o700));
    package_dir.close(defaultIo());
    try deleteFileIfExists(link_path);
    nested_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), nested_root, .{});
    try nested_dir.setPermissions(defaultIo(), .fromMode(0o700));
    nested_dir.close(defaultIo());
}

test "target and common projection remain registration-captured when INDEX mutates before execution" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "source-repo");
    const runner_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(runner_root);
    const repo = try tmp.dir.realPathFileAlloc(std.testing.io, "source-repo", allocator);
    defer allocator.free(repo);
    allocator.free(try runGitStdoutAlloc(allocator, repo, &.{ "init", "-q" }));
    allocator.free(try runGitStdoutAlloc(allocator, repo, &.{ "config", "user.name", "CAS Test" }));
    allocator.free(try runGitStdoutAlloc(allocator, repo, &.{ "config", "user.email", "cas@example.invalid" }));
    const target_path = try std.fs.path.join(allocator, &.{ repo, "target.txt" });
    defer allocator.free(target_path);
    const common_path = try std.fs.path.join(allocator, &.{ repo, "common.txt" });
    defer allocator.free(common_path);
    try durable_store.writeTextAtomic(allocator, target_path, "registered-bytes\n");
    const common_bytes = "common-baseline\n";
    try durable_store.writeTextAtomic(allocator, common_path, common_bytes);
    allocator.free(try runGitStdoutAlloc(allocator, repo, &.{ "add", "target.txt", "common.txt" }));
    allocator.free(try runGitStdoutAlloc(allocator, repo, &.{ "commit", "-q", "-m", "baseline" }));
    const baseline_revision_raw = try runGitStdoutAlloc(allocator, repo, &.{ "rev-parse", "HEAD" });
    defer allocator.free(baseline_revision_raw);
    const baseline_revision = std.mem.trim(u8, baseline_revision_raw, " \t\r\n");
    const object_id_raw = try runGitStdoutAlloc(allocator, repo, &.{ "rev-parse", ":target.txt" });
    defer allocator.free(object_id_raw);
    const object_id = std.mem.trim(u8, object_id_raw, " \t\r\n");
    const common_object_id_raw = try runGitStdoutAlloc(allocator, repo, &.{ "rev-parse", "HEAD:common.txt" });
    defer allocator.free(common_object_id_raw);
    const common_object_id = std.mem.trim(u8, common_object_id_raw, " \t\r\n");
    const common_content_fingerprint = try attestation.digestBytesAlloc(allocator, common_bytes);
    defer allocator.free(common_content_fingerprint);
    const common_projection = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-target-common-projection/v1\",\"verifier\":{{\"id\":\"git-target-common-projection\",\"version\":\"v1\"}},\"baseline_revision\":{f},\"excluded_roots\":[\"target.txt\"],\"entries\":[{{\"path\":\"common.txt\",\"mode\":\"100644\",\"object_type\":\"blob\",\"object_id\":{f},\"content_fingerprint\":{f}}}]}}",
        .{ std.json.fmt(baseline_revision, .{}), std.json.fmt(common_object_id, .{}), std.json.fmt(common_content_fingerprint, .{}) },
    );
    defer allocator.free(common_projection);
    const common_projection_fingerprint = try digestJsonTextAlloc(allocator, common_projection);
    defer allocator.free(common_projection_fingerprint);
    const snapshot = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-target-snapshot/v1\",\"roots\":[\"target.txt\"],\"entries\":[{{\"path\":\"target.txt\",\"mode\":\"100644\",\"object_id\":{f},\"object_type\":\"blob\"}}]}}",
        .{std.json.fmt(object_id, .{})},
    );
    defer allocator.free(snapshot);
    var snapshot_parsed = try std.json.parseFromSlice(std.json.Value, allocator, snapshot, .{});
    defer snapshot_parsed.deinit();
    const snapshot_fingerprint = try attestation.digestValueAlloc(allocator, snapshot_parsed.value);
    defer allocator.free(snapshot_fingerprint);
    const arms_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"arm_id\":\"arm-0\",\"value_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"materialization_ref\":\"git-revision:{s}\",\"materialization_fingerprint\":{f}}},{{\"arm_id\":\"arm-1\",\"value_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"materialization_ref\":\"git-revision:INDEX\",\"materialization_fingerprint\":{f}}}]",
        .{ baseline_revision, std.json.fmt(snapshot_fingerprint, .{}), std.json.fmt(snapshot_fingerprint, .{}) },
    );
    defer allocator.free(arms_json);
    const factor_json = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"target_snapshot\",\"common_projection_fingerprint\":{f},\"allowed_difference_roots\":[\"target.txt\"],\"target_common_projection\":{s},\"intervention_witness\":{{\"common_projection\":{{\"fingerprint\":{f}}}}}}}",
        .{ std.json.fmt(common_projection_fingerprint, .{}), common_projection, std.json.fmt(common_projection_fingerprint, .{}) },
    );
    defer allocator.free(factor_json);
    const trial = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-trial/v1\",\"trial_id\":\"trial-target\",\"purpose\":\"promotion\",\"arms\":{s},\"factor\":{s},\"units\":[{{\"unit_id\":\"unit-target\",\"scenario_id\":\"scenario-target\",\"source_profile\":{{\"kind\":\"direct\"}},\"pairs\":[{{\"pair_id\":\"pair-target\",\"shared_seed\":null,\"lanes\":{{\"arm-0\":{{\"lane_id\":\"lane-target-a0\"}},\"arm-1\":{{\"lane_id\":\"lane-target-a1\"}}}}}}]}}],\"execution\":{{\"runner_contract_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"environment_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\",\"replay_policy_fingerprint\":\"sha256:3333333333333333333333333333333333333333333333333333333333333333\",\"effect_policy_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\",\"model_policy_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\",\"maximum_lane_duration_ms\":1000,\"maximum_tokens_per_lane\":1000}}}}",
        .{ arms_json, factor_json },
    );
    defer allocator.free(trial);
    const trial_path = try std.fs.path.join(allocator, &.{ repo, "trial.json" });
    defer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    var loaded = try loadLane(allocator, trial_path, "lane-target-a0");
    defer loaded.parsed.deinit();
    const trial_fingerprint = try digestJsonTextAlloc(allocator, trial);
    defer allocator.free(trial_fingerprint);
    const registration_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const start_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const lease_digest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const input_fingerprint = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const claim = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-lane-materialization-claim/v1\",\"campaign_id\":\"cmp-target\",\"trial_id\":\"trial-target\",\"trial_fingerprint\":{f},\"unit_id\":\"unit-target\",\"scenario_id\":\"scenario-target\",\"pair_id\":\"pair-target\",\"lane_id\":\"lane-target-a0\",\"opaque_arm_id\":\"arm-0\",\"registration_event_digest\":{f},\"lane_started_event_digest\":{f},\"lane_lease_digest\":{f},\"presented_input_fingerprint\":{f},\"target_common_projection\":{s},\"arm_materialization\":{{\"schema\":\"hylo-arm-materialization/v1\",\"arm_id\":\"arm-0\",\"value_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"materialization_ref\":\"git-revision:{s}\",\"materialization_fingerprint\":{f},\"materialization\":{s}}}}}",
        .{ std.json.fmt(trial_fingerprint, .{}), std.json.fmt(registration_digest, .{}), std.json.fmt(start_digest, .{}), std.json.fmt(lease_digest, .{}), std.json.fmt(input_fingerprint, .{}), common_projection, baseline_revision, std.json.fmt(snapshot_fingerprint, .{}), snapshot },
    );
    defer allocator.free(claim);
    const claim_path = try std.fs.path.join(allocator, &.{ repo, "target-claim.json" });
    defer allocator.free(claim_path);
    const mismatched_common_projection = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-target-common-projection/v1\",\"verifier\":{{\"id\":\"git-target-common-projection\",\"version\":\"v1\"}},\"baseline_revision\":{f},\"excluded_roots\":[\"target.txt\"],\"entries\":[]}}",
        .{std.json.fmt(baseline_revision, .{})},
    );
    defer allocator.free(mismatched_common_projection);
    const mismatched_claim = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-lane-materialization-claim/v1\",\"campaign_id\":\"cmp-target\",\"trial_id\":\"trial-target\",\"trial_fingerprint\":{f},\"unit_id\":\"unit-target\",\"scenario_id\":\"scenario-target\",\"pair_id\":\"pair-target\",\"lane_id\":\"lane-target-a0\",\"opaque_arm_id\":\"arm-0\",\"registration_event_digest\":{f},\"lane_started_event_digest\":{f},\"lane_lease_digest\":{f},\"presented_input_fingerprint\":{f},\"target_common_projection\":{s},\"arm_materialization\":{{\"schema\":\"hylo-arm-materialization/v1\",\"arm_id\":\"arm-0\",\"value_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"materialization_ref\":\"git-revision:{s}\",\"materialization_fingerprint\":{f},\"materialization\":{s}}}}}",
        .{ std.json.fmt(trial_fingerprint, .{}), std.json.fmt(registration_digest, .{}), std.json.fmt(start_digest, .{}), std.json.fmt(lease_digest, .{}), std.json.fmt(input_fingerprint, .{}), mismatched_common_projection, baseline_revision, std.json.fmt(snapshot_fingerprint, .{}), snapshot },
    );
    defer allocator.free(mismatched_claim);
    try durable_store.writeTextAtomic(allocator, claim_path, mismatched_claim);
    const ledger = try std.fs.path.join(allocator, &.{ repo, "mock-ledger.sh" });
    defer allocator.free(ledger);
    try durable_store.writeTextAtomic(allocator, ledger, "#!/bin/sh\nrepo=\nwhile [ \"$#\" -gt 0 ]; do if [ \"$1\" = --repo ]; then repo=$2; shift 2; else shift; fi; done\ncat \"$repo/target-claim.json\"\n");
    var ledger_file = try std.Io.Dir.cwd().openFile(defaultIo(), ledger, .{});
    defer ledger_file.close(defaultIo());
    try ledger_file.setPermissions(defaultIo(), .fromMode(0o500));
    const executable_store = try std.fs.path.join(allocator, &.{ repo, ".executables" });
    defer allocator.free(executable_store);
    const ledger_binding = try bindExecutableInStoreAlloc(allocator, ledger, executable_store);
    defer ledger_binding.deinit(allocator);

    try std.testing.expectError(
        error.TargetCommonProjectionMismatch,
        resolveTargetMaterializationAlloc(
            allocator,
            loaded.view,
            repo,
            &ledger_binding,
            registration_digest,
            start_digest,
            lease_digest,
            input_fingerprint,
            "unused-target-workspace.json",
            "unused-target-archive.json",
            "unused-target-package",
        ),
    );
    try durable_store.writeTextAtomic(allocator, claim_path, claim);

    try durable_store.writeTextAtomic(allocator, target_path, "mutated-index-bytes\n");
    try durable_store.writeTextAtomic(allocator, common_path, "mutated-common-index-bytes\n");
    allocator.free(try runGitStdoutAlloc(allocator, repo, &.{ "add", "target.txt", "common.txt" }));
    const workspace = try std.fs.path.join(allocator, &.{ runner_root, "runner", "workspace" });
    defer allocator.free(workspace);
    const evidence = try std.fs.path.join(allocator, &.{ runner_root, "runner", "evidence" });
    defer allocator.free(evidence);
    try durable_store.ensureDirectoryPathNoSymlinks(workspace);
    try durable_store.ensureDirectoryPathNoSymlinks(evidence);
    const workspace_ref = try std.fs.path.join(allocator, &.{ workspace, "target-materialization.json" });
    defer allocator.free(workspace_ref);
    const archive_ref = try std.fs.path.join(allocator, &.{ evidence, "target-materialization.json" });
    defer allocator.free(archive_ref);
    const package_root = try std.fs.path.join(allocator, &.{ workspace, "target-package" });
    defer allocator.free(package_root);
    const materialization = try resolveTargetMaterializationAlloc(
        allocator,
        loaded.view,
        repo,
        &ledger_binding,
        registration_digest,
        start_digest,
        lease_digest,
        input_fingerprint,
        workspace_ref,
        archive_ref,
        package_root,
    );
    defer materialization.deinit(allocator);
    try persistTargetMaterialization(allocator, materialization);
    const execution_root = try std.fs.path.join(allocator, &.{ workspace, "runner-common-projection" });
    defer allocator.free(execution_root);
    try materializeExecutionProjection(allocator, loaded.view, repo, execution_root, materialization);
    const packaged_target = try std.fs.path.join(allocator, &.{ package_root, "target.txt" });
    defer allocator.free(packaged_target);
    const packaged_bytes = try durable_store.readRegularFileNoSymlink(allocator, packaged_target, MaxInputBytes);
    defer allocator.free(packaged_bytes);
    try std.testing.expectEqualStrings("registered-bytes\n", packaged_bytes);
    const projected_target = try std.fs.path.join(allocator, &.{ execution_root, "target.txt" });
    defer allocator.free(projected_target);
    const projected_target_bytes = try durable_store.readRegularFileNoSymlink(allocator, projected_target, MaxInputBytes);
    defer allocator.free(projected_target_bytes);
    try std.testing.expectEqualStrings("registered-bytes\n", projected_target_bytes);
    const projected_common = try std.fs.path.join(allocator, &.{ execution_root, "common.txt" });
    defer allocator.free(projected_common);
    const projected_common_bytes = try durable_store.readRegularFileNoSymlink(allocator, projected_common, MaxInputBytes);
    defer allocator.free(projected_common_bytes);
    try std.testing.expectEqualStrings(common_bytes, projected_common_bytes);
    const request = try buildExecutorRequestAlloc(
        allocator,
        loaded.view,
        execution_root,
        "unused-decision-context.json",
        "unused-presented-input.json",
        input_fingerprint,
        lease_digest,
        .{
            .present = false,
            .ref = "",
            .fingerprint = "",
            .canonical_bytes = null,
            .workspace_ref = "",
            .archive_ref = "",
        },
        materialization,
    );
    defer allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, repo) == null);
    var request_parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer request_parsed.deinit();
    const request_root = try object(request_parsed.value);
    try std.testing.expect(request_root.get("repo") == null);
    try std.testing.expectEqualStrings(execution_root, try requiredString(request_root, "workspace"));
    try std.testing.expectEqualStrings(
        common_projection_fingerprint,
        try requiredString(request_root, "common_projection_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        snapshot_fingerprint,
        try requiredString(request_root, "workspace_target_snapshot_fingerprint"),
    );
    const execution_tree_baseline = try captureExecutionTreeAlloc(allocator, execution_root);
    defer execution_tree_baseline.deinit(allocator);
    try verifyExecutionTreeBaseline(allocator, execution_tree_baseline, materialization);
    const observed_common_fingerprint = (try rehashRegisteredCommonProjectionAlloc(
        allocator,
        execution_root,
        materialization,
    )).?;
    defer allocator.free(observed_common_fingerprint);
    try std.testing.expectEqualStrings(common_projection_fingerprint, observed_common_fingerprint);
    try durable_store.writeTextAtomic(allocator, projected_common, "persistent-out-of-factor-mutation\n");
    {
        var observed = try captureExecutionTreeAlloc(allocator, execution_root);
        defer observed.deinit(allocator);
        var declared: std.ArrayList(DeclaredExecutionEvidence) = .empty;
        defer declared.deinit(allocator);
        try std.testing.expectError(
            error.TargetCommonProjectionMutation,
            verifyExecutionTreeTransition(execution_tree_baseline, observed, &declared),
        );
    }
    try durable_store.writeTextAtomic(allocator, projected_common, common_bytes);
    var restored_common_file = try std.Io.Dir.cwd().openFile(defaultIo(), projected_common, .{});
    try restored_common_file.setPermissions(defaultIo(), .fromMode(0o600));
    restored_common_file.close(defaultIo());
    {
        var mode_changed = try std.Io.Dir.cwd().openFile(defaultIo(), projected_common, .{});
        try mode_changed.setPermissions(defaultIo(), .fromMode(0o640));
        mode_changed.close(defaultIo());
        var observed = try captureExecutionTreeAlloc(allocator, execution_root);
        defer observed.deinit(allocator);
        var declared: std.ArrayList(DeclaredExecutionEvidence) = .empty;
        defer declared.deinit(allocator);
        try std.testing.expectError(
            error.TargetCommonProjectionMutation,
            verifyExecutionTreeTransition(execution_tree_baseline, observed, &declared),
        );
        var restore_mode = try std.Io.Dir.cwd().openFile(defaultIo(), projected_common, .{});
        try restore_mode.setPermissions(defaultIo(), .fromMode(0o600));
        restore_mode.close(defaultIo());
    }
    const undeclared = try std.fs.path.join(allocator, &.{ execution_root, "undeclared.txt" });
    defer allocator.free(undeclared);
    try durable_store.writeTextAtomic(allocator, undeclared, "undeclared\n");
    {
        var observed = try captureExecutionTreeAlloc(allocator, execution_root);
        defer observed.deinit(allocator);
        var declared: std.ArrayList(DeclaredExecutionEvidence) = .empty;
        defer declared.deinit(allocator);
        try std.testing.expectError(
            error.TargetCommonProjectionMutation,
            verifyExecutionTreeTransition(execution_tree_baseline, observed, &declared),
        );
    }
    try deleteFileIfExists(undeclared);
    try deleteFileIfExists(projected_common);
    try durable_store.ensureDirectoryPathNoSymlinks(projected_common);
    {
        var observed = try captureExecutionTreeAlloc(allocator, execution_root);
        defer observed.deinit(allocator);
        var declared: std.ArrayList(DeclaredExecutionEvidence) = .empty;
        defer declared.deinit(allocator);
        try std.testing.expectError(
            error.TargetCommonProjectionMutation,
            verifyExecutionTreeTransition(execution_tree_baseline, observed, &declared),
        );
    }
    try deleteTree(projected_common);
    try durable_store.writeTextAtomic(allocator, projected_common, common_bytes);
    restored_common_file = try std.Io.Dir.cwd().openFile(defaultIo(), projected_common, .{});
    try restored_common_file.setPermissions(defaultIo(), .fromMode(0o600));
    restored_common_file.close(defaultIo());
    try deleteFileIfExists(projected_common);
    try std.Io.Dir.cwd().symLink(defaultIo(), projected_target, projected_common, .{});
    try std.testing.expectError(
        error.TargetCommonProjectionMutation,
        captureExecutionTreeAlloc(allocator, execution_root),
    );
    try deleteFileIfExists(projected_common);
    try durable_store.writeTextAtomic(allocator, projected_common, common_bytes);
    restored_common_file = try std.Io.Dir.cwd().openFile(defaultIo(), projected_common, .{});
    try restored_common_file.setPermissions(defaultIo(), .fromMode(0o600));
    restored_common_file.close(defaultIo());
    var projected_file = try std.Io.Dir.cwd().openFile(defaultIo(), projected_target, .{});
    try projected_file.setPermissions(defaultIo(), .fromMode(0o600));
    projected_file.close(defaultIo());
    try durable_store.writeTextAtomic(allocator, projected_target, "tampered-execution-target\n");
    try std.testing.expectError(
        error.ArchivedEvidenceFingerprintMismatch,
        verifyExecutionTargetOverlay(allocator, execution_root, materialization),
    );
    var package_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), package_root, .{});
    try package_dir.setPermissions(defaultIo(), .fromMode(0o700));
    package_dir.close(defaultIo());
    try durable_store.writeTextAtomic(allocator, packaged_target, "tampered-package\n");
    try std.testing.expectError(
        error.ArchivedEvidenceFingerprintMismatch,
        verifyTargetMaterialization(allocator, materialization, package_root),
    );
}

test "exact execution tree admits only fixed CAS-bound evidence paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const execution_root = try std.fs.path.join(allocator, &.{ root, "common-projection" });
    defer allocator.free(execution_root);
    const output_root = try std.fs.path.join(allocator, &.{ root, "executor-output" });
    defer allocator.free(output_root);
    const result_path = try std.fs.path.join(allocator, &.{ output_root, "result.json" });
    defer allocator.free(result_path);
    try durable_store.ensureDirectoryPathNoSymlinks(execution_root);
    try durable_store.ensureDirectoryPathNoSymlinks(output_root);
    const baseline = try captureExecutionTreeAlloc(allocator, execution_root);
    defer baseline.deinit(allocator);
    const no_materialization = TargetMaterialization{
        .present = false,
        .arm_value_fingerprint = null,
        .snapshot_ref = null,
        .snapshot_fingerprint = null,
        .carrier_bytes = null,
        .carrier_fingerprint = null,
        .workspace_ref = "",
        .archive_ref = "",
        .package_root = "",
    };
    try verifyExecutionTreeBaseline(allocator, baseline, no_materialization);

    const evidence_files = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "execution-audit.json", .bytes = "{\"audit\":true}\n" },
        .{ .name = "reset.json", .bytes = "{\"fresh\":true}\n" },
        .{ .name = "filesystem.json", .bytes = "{\"violations\":[]}\n" },
        .{ .name = "network.json", .bytes = "{\"attempts\":0}\n" },
        .{ .name = "external.json", .bytes = "{\"effects\":[]}\n" },
        .{ .name = "output.json", .bytes = "{\"answer\":\"bounded\"}\n" },
        .{ .name = "trace.json", .bytes = "{\"events\":[]}\n" },
        .{ .name = "world.json", .bytes = "{\"state\":\"isolated\"}\n" },
        .{ .name = "metrics.json", .bytes = "{\"tokens\":1}\n" },
    };
    var bound_fingerprints: [5][]u8 = undefined;
    var bound_count: usize = 0;
    defer for (bound_fingerprints[0..bound_count]) |fingerprint| allocator.free(fingerprint);
    for (evidence_files, 0..) |fixture, index| {
        const path = try std.fs.path.join(allocator, &.{ execution_root, fixture.name });
        defer allocator.free(path);
        try durable_store.writeTextAtomic(allocator, path, fixture.bytes);
        if (index < bound_fingerprints.len) {
            bound_fingerprints[index] = try fileFingerprintAlloc(allocator, path);
            bound_count += 1;
        }
    }
    const executor_result = try std.fmt.allocPrint(
        allocator,
        "{{\"execution_audit_ref\":\"execution-audit.json\",\"execution_audit_fingerprint\":{f},\"isolation\":{{\"reset_receipt_ref\":\"reset.json\",\"reset_receipt_fingerprint\":{f}}},\"effects\":{{\"filesystem_receipt_ref\":\"filesystem.json\",\"filesystem_receipt_fingerprint\":{f},\"network_receipt_ref\":\"network.json\",\"network_receipt_fingerprint\":{f},\"external_effect_receipt_ref\":\"external.json\",\"external_effect_receipt_fingerprint\":{f}}},\"evidence\":{{\"output_path\":\"output.json\",\"trace_path\":\"trace.json\",\"world_state_path\":\"world.json\",\"metrics_path\":\"metrics.json\"}}}}",
        .{
            std.json.fmt(bound_fingerprints[0], .{}),
            std.json.fmt(bound_fingerprints[1], .{}),
            std.json.fmt(bound_fingerprints[2], .{}),
            std.json.fmt(bound_fingerprints[3], .{}),
            std.json.fmt(bound_fingerprints[4], .{}),
        },
    );
    defer allocator.free(executor_result);
    const temporary_path = try std.fs.path.join(allocator, &.{ output_root, "tmp" });
    defer allocator.free(temporary_path);
    try durable_store.ensureDirectoryPathNoSymlinks(temporary_path);
    try durable_store.writeTextAtomic(allocator, result_path, executor_result);
    inline for (.{ "result.json.stdout", "result.json.stderr" }) |name| {
        const path = try std.fs.path.join(allocator, &.{ output_root, name });
        defer allocator.free(path);
        try durable_store.writeTextAtomic(allocator, path, "");
        var file = try std.Io.Dir.cwd().openFile(defaultIo(), path, .{});
        try file.setPermissions(defaultIo(), .fromMode(0o600));
        file.close(defaultIo());
    }
    const output_carrier_fingerprint = try verifyExecutorOutputCarrierAlloc(allocator, output_root, result_path);
    defer allocator.free(output_carrier_fingerprint);
    const observation = try observeExecutionTreeAlloc(
        allocator,
        execution_root,
        baseline,
        no_materialization,
        executor_result,
        output_carrier_fingerprint,
    );
    defer observation.deinit(allocator);
    try std.testing.expect(observation.common_projection_fingerprint == null);
    try validateFingerprint(observation.exact_tree_fingerprint);
    try validateFingerprint(observation.output_carrier_fingerprint);

    const caller_selected = try std.mem.replaceOwned(
        u8,
        allocator,
        executor_result,
        "\"output_path\":\"output.json\"",
        "\"output_path\":\"caller-selected.json\"",
    );
    defer allocator.free(caller_selected);
    try std.testing.expectError(
        error.TargetCommonProjectionMutation,
        declaredExecutionEvidenceAlloc(allocator, execution_root, caller_selected),
    );
}

fn sanitizedHistoricalProfileForTestAlloc(
    allocator: std.mem.Allocator,
    contaminated: bool,
) ![]u8 {
    const context = try std.fmt.allocPrint(
        allocator,
        "{{\"decision_context_packet\":{{\"contamination\":{{\"injected_skill_blocks\":{},\"generated_reports\":false,\"current_audit_prompt\":false,\"quoted_material\":false}}}}}}",
        .{contaminated},
    );
    defer allocator.free(context);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, context, .{});
    defer parsed.deinit();
    const fingerprint = try attestation.digestValueAlloc(allocator, parsed.value);
    defer allocator.free(fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"historical_decision\",\"source_governance_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"decision_context_fingerprint\":{f},\"decision_context\":{s},\"temporal_horizon\":\"pre_decision\",\"source_target_text_policy\":\"strip_and_replace\",\"retrace_mode\":\"replay\",\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\",\"reconstructability\":\"transcript_only\",\"limitations\":[],\"source_target_text_witness\":{{\"sanitization\":{{\"applied\":true,\"sanitized_context_fingerprint\":{f}}}}}}}",
        .{ std.json.fmt(fingerprint, .{}), context, std.json.fmt(fingerprint, .{}) },
    );
}

test "strip-and-replace consumes only a fingerprint-bound clean context" {
    const clean_text = try sanitizedHistoricalProfileForTestAlloc(std.testing.allocator, false);
    defer std.testing.allocator.free(clean_text);
    var clean = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, clean_text, .{});
    defer clean.deinit();
    try validateSanitizedHistoricalProfile(std.testing.allocator, try object(clean.value));

    const contaminated_text = try sanitizedHistoricalProfileForTestAlloc(std.testing.allocator, true);
    defer std.testing.allocator.free(contaminated_text);
    var contaminated = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, contaminated_text, .{});
    defer contaminated.deinit();
    try std.testing.expectError(
        error.SourceTargetTextContamination,
        validateSanitizedHistoricalProfile(std.testing.allocator, try object(contaminated.value)),
    );
}

test "historical source-profile FD replaces the projected sealed profile" {
    const full_profile = try sanitizedHistoricalProfileForTestAlloc(std.testing.allocator, false);
    defer std.testing.allocator.free(full_profile);
    var full_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full_profile, .{});
    defer full_parsed.deinit();
    const fingerprint = try attestation.digestValueAlloc(std.testing.allocator, full_parsed.value);
    defer std.testing.allocator.free(fingerprint);
    const full_profile_root = try object(full_parsed.value);
    const witness_fingerprint = try attestation.digestValueAlloc(
        std.testing.allocator,
        full_profile_root.get("source_target_text_witness") orelse return error.SourceProfileInvalid,
    );
    defer std.testing.allocator.free(witness_fingerprint);
    const projected_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"kind\":\"historical_decision\",\"source_governance_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"decision_context_fingerprint\":{f},\"temporal_horizon\":\"pre_decision\",\"source_target_text_policy\":\"strip_and_replace\",\"retrace_mode\":\"replay\",\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\",\"reconstructability\":\"transcript_only\",\"limitations\":[],\"source_target_text_witness_fingerprint\":{f},\"source_profile_fingerprint\":{f},\"profile_body_delivery\":\"source_profile_fd\",\"sealed_payload\":true}}",
        .{ std.json.fmt(try requiredString(full_profile_root, "decision_context_fingerprint"), .{}), std.json.fmt(witness_fingerprint, .{}), std.json.fmt(fingerprint, .{}) },
    );
    defer std.testing.allocator.free(projected_text);
    var projected = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, projected_text, .{});
    defer projected.deinit();
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.TestFdSetupFailed;
    const writer = std.Io.File{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } };
    try writer.writeStreamingAll(std.testing.io, full_profile);
    writer.close(std.testing.io);
    var effective = try effectiveSourceProfile(std.testing.allocator, projected.value, pipe_fds[0]);
    defer effective.deinit();
    try std.testing.expectEqualStrings(
        "historical_decision",
        try requiredString(try object(effective.value), "kind"),
    );
    try std.testing.expect((try object(projected.value)).get("source_target_text_witness") == null);

    const tampered_text = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        projected_text,
        fingerprint,
        "sha256:dededededededededededededededededededededededededededededededede",
    );
    defer std.testing.allocator.free(tampered_text);
    var tampered = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tampered_text, .{});
    defer tampered.deinit();
    var tampered_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&tampered_fds) != 0) return error.TestFdSetupFailed;
    const tampered_writer = std.Io.File{ .handle = tampered_fds[1], .flags = .{ .nonblocking = false } };
    try tampered_writer.writeStreamingAll(std.testing.io, full_profile);
    tampered_writer.close(std.testing.io);
    try std.testing.expectError(
        error.SourceProfileFingerprintMismatch,
        effectiveSourceProfile(std.testing.allocator, tampered.value, tampered_fds[0]),
    );
}

test "historical post-claim failure preserves DCP lineage without impersonating FIR" {
    const allocator = std.testing.allocator;
    const profile = try sanitizedHistoricalProfileForTestAlloc(allocator, false);
    defer allocator.free(profile);
    const trial = try std.mem.replaceOwned(
        u8,
        allocator,
        hctp_fixtures.valid_null_trial,
        "{\"kind\": \"direct\"}",
        profile,
    );
    defer allocator.free(trial);
    try std.testing.expect(std.mem.indexOf(u8, trial, "historical_decision") != null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    defer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    var loaded = try loadLane(allocator, trial_path, "lane-null-a0");
    defer loaded.parsed.deinit();
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    const paths = try lanePathsAlloc(allocator, receipt_dir, root, loaded.view.trial_id, loaded.view.lane_id);
    defer paths.deinit(allocator);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.evidence);
    const audit_path = try std.fs.path.join(allocator, &.{ paths.evidence, "execution-audit.json" });
    defer allocator.free(audit_path);
    const audit = "{\"schema\":\"cas-trial-process-audit/v1\",\"executor_launch_count\":1}";
    try durable_store.writeTextCreateNewAtomic(allocator, audit_path, audit, .{});
    const audit_fingerprint = try fileFingerprintAlloc(allocator, audit_path);
    defer allocator.free(audit_fingerprint);
    try ensureHistoricalDecisionContextArchive(allocator, loaded.view, paths);
    const native = try historicalTerminalNativeReceiptAlloc(
        allocator,
        loaded.view,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .{ .status = "failed", .class = "executor_exit_nonzero" },
        "/usr/bin/false",
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        paths.decision_context_archive,
        audit_path,
        audit_fingerprint,
    );
    defer allocator.free(native.json);
    defer allocator.free(native.fingerprint);
    try std.testing.expectEqualStrings("cas-historical-terminal-receipt", native.kind);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, native.json, .{});
    defer parsed.deinit();
    const root_value = try object(parsed.value);
    try std.testing.expectEqualStrings(
        "cas-historical-terminal-receipt/v1",
        try requiredString(root_value, "schema"),
    );
    const source = try requiredObject(root_value, "source");
    try std.testing.expectEqualStrings("pre_decision", try requiredString(source, "temporal_horizon"));
    try std.testing.expectEqualStrings("FIR-v1", try requiredString(source, "required_fir_version"));
    const fir = try requiredObject(root_value, "fir");
    try std.testing.expectEqualStrings("unavailable", try requiredString(fir, "status"));
    try std.testing.expect(fir.get("receipt_ref").? == .null);
    try std.testing.expect(fir.get("receipt_fingerprint").? == .null);
    try std.testing.expectEqualStrings("executor_exit_nonzero", try requiredString(fir, "reason"));
    try std.testing.expect(pathExists(paths.decision_context_archive));
}

test "direct source-profile FD accepts only clean EOF" {
    var direct = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"direct\"}",
        .{},
    );
    defer direct.deinit();
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.TestFdSetupFailed;
    closeOwnedFd(pipe_fds[1]);
    var effective = try effectiveSourceProfile(std.testing.allocator, direct.value, pipe_fds[0]);
    defer effective.deinit();
    try std.testing.expectEqualStrings("direct", try requiredString(try object(effective.value), "kind"));
}

test "claimed executor failure persists one signed terminal receipt and cleanup preserves proof" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executor = try std.fs.path.join(allocator, &.{ root, "false-executor.sh" });
    defer allocator.free(executor);
    try durable_store.writeTextAtomic(allocator, executor, "#!/bin/sh\nexit 1\n");
    var executor_file = try std.Io.Dir.openFileAbsolute(defaultIo(), executor, .{});
    try executor_file.setPermissions(defaultIo(), .fromMode(0o500));
    executor_file.close(defaultIo());
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), receipt_dir);

    const raw_lease = "HYL1-test-secret-never-persist";
    const ledger = try writeMockLaneMaterializationLedgerAlloc(allocator, root, raw_lease);
    defer allocator.free(ledger);
    const bound = try bindTestRunnerContractAlloc(allocator, hctp_fixtures.valid_null_trial, executor, ledger);
    defer allocator.free(bound);
    const seed = [_]u8{0x52} ** 32;
    const trial = try receiptBoundTestTrialAlloc(allocator, bound, seed, executor, ledger);
    defer allocator.free(trial);
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    defer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    try writeMockTrialFingerprint(allocator, root, trial);
    const lease_path = try std.fs.path.join(allocator, &.{ root, "lease" });
    defer allocator.free(lease_path);
    const input_path = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(input_path);
    const seed_path = try std.fs.path.join(allocator, &.{ root, "seed" });
    defer allocator.free(seed_path);
    const input = "{\"request\":\"bounded\"}";
    try durable_store.writeTextAtomic(allocator, lease_path, raw_lease);
    try durable_store.writeTextAtomic(allocator, input_path, input);
    try durable_store.writeTextAtomic(allocator, seed_path, &seed);
    const input_fingerprint = try attestation.digestBytesAlloc(allocator, input);
    defer allocator.free(input_fingerprint);
    try writeMockInputFingerprint(allocator, root, input_fingerprint);

    const lease_fd = try testPipeWithBytes(raw_lease);
    const input_fd = try testPipeWithBytes(input);
    const seed_fd = try testPipeWithBytes(&seed);
    try cmdRun(allocator, testRunFailureOptions(
        trial_path,
        receipt_dir,
        executor,
        ledger,
        lease_fd,
        input_fd,
        input_fingerprint,
        seed_fd,
        root,
    ));

    const paths = try lanePathsAlloc(allocator, receipt_dir, root, "trial-null-001", "lane-null-a0");
    defer paths.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, paths.native_receipt, paths.failure_native_receipt));
    try std.testing.expect(!std.mem.eql(u8, paths.reset_observation, paths.failure_reset_observation));
    try std.testing.expect(!std.mem.eql(u8, paths.filesystem_observation, paths.failure_filesystem_observation));
    try std.testing.expect(!std.mem.eql(u8, paths.network_observation, paths.failure_network_observation));
    try std.testing.expect(!std.mem.eql(u8, paths.external_effect_observation, paths.failure_external_effect_observation));
    const receipt = try readFileAlloc(allocator, paths.receipt, MaxInputBytes);
    defer allocator.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{});
    defer parsed.deinit();
    const receipt_root = try object(parsed.value);
    const terminal = try requiredObject(receipt_root, "terminal");
    try std.testing.expectEqualStrings("failed", try requiredString(terminal, "status"));
    try std.testing.expectEqualStrings("executor_exit_nonzero", try requiredString(terminal, "failure_class"));
    const isolation = try requiredObject(receipt_root, "isolation");
    try std.testing.expect(!try requiredBool(isolation, "fresh_thread"));
    try std.testing.expect(try requiredBool(isolation, "fresh_workspace"));
    try std.testing.expect(!try requiredBool(isolation, "target_cache_cleared"));
    try std.testing.expect((try requiredArray(try requiredObject(receipt_root, "effects"), "policy_violations")).items.len == 1);
    const receipt_attestation = try object(receipt_root.get("attestation") orelse return error.AttestationMissing);
    try std.testing.expectEqualStrings("hylo-attestation/v1", try requiredString(receipt_attestation, "schema"));
    try std.testing.expectEqualStrings("runner", try requiredString(receipt_attestation, "role"));
    const subject_fingerprint = try attestation.subjectFingerprintAlloc(allocator, parsed.value);
    defer allocator.free(subject_fingerprint);
    try std.testing.expectEqualStrings(subject_fingerprint, try requiredString(receipt_attestation, "subject_fingerprint"));
    try std.testing.expect(std.mem.indexOf(u8, receipt, raw_lease) == null);
    try std.testing.expect(std.mem.indexOf(u8, receipt, &seed) == null);
    const native_receipt = try requiredObject(receipt_root, "native_receipt");
    try std.testing.expectEqualStrings(paths.failure_native_receipt, try requiredString(native_receipt, "ref"));
    const native_bytes = try readFileAlloc(allocator, paths.failure_native_receipt, MaxInputBytes);
    defer allocator.free(native_bytes);
    const native_fingerprint = try attestation.digestBytesAlloc(allocator, native_bytes);
    defer allocator.free(native_fingerprint);
    try std.testing.expectEqualStrings(
        native_fingerprint,
        try requiredString(native_receipt, "fingerprint"),
    );
    const native_stat = try std.Io.Dir.cwd().statFile(defaultIo(), paths.failure_native_receipt, .{});
    try std.testing.expect(native_stat.permissions.readOnly());
    const evidence_stat = try std.Io.Dir.cwd().statFile(defaultIo(), paths.evidence, .{});
    try std.testing.expect(evidence_stat.permissions.readOnly());
    const detail = try readFileAlloc(allocator, paths.failure_detail, MaxInputBytes);
    defer allocator.free(detail);
    try std.testing.expect(std.mem.indexOf(u8, detail, raw_lease) == null);
    try std.testing.expect(std.mem.indexOf(u8, detail, &seed) == null);
    const terminal_control = try verifyTerminalControlAlloc(
        allocator,
        paths,
        "trial-null-001",
        "lane-null-a0",
    );
    defer terminal_control.deinit(allocator);
    try std.testing.expect(!try verifyCleanupControlIfPresent(
        allocator,
        paths,
        "trial-null-001",
        "lane-null-a0",
        terminal_control,
    ));
    const claim_path = try claimPathAlloc(allocator, paths.claim, terminal_control.registration_digest);
    defer allocator.free(claim_path);
    for ([_][]const u8{ claim_path, paths.receipt, paths.failure_detail }) |sealed_path| {
        const stat = try std.Io.Dir.cwd().statFile(defaultIo(), sealed_path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o400), stat.permissions.toMode() & 0o777);
    }
    const terminal_control_path = (try findControlArtifactPathAlloc(
        allocator,
        paths.claim,
        terminal_control.registration_digest,
        .terminal,
    )) orelse return error.TerminalControlMissing;
    defer allocator.free(terminal_control_path);
    const terminal_control_stat = try std.Io.Dir.cwd().statFile(defaultIo(), terminal_control_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o400), terminal_control_stat.permissions.toMode() & 0o777);

    // A sealed terminal payload is the recovery anchor. Conflicting projections
    // are rejected, while a crash before receipt/control publication resumes
    // without another executor launch.
    try deleteFileIfExists(terminal_control_path);
    try durable_store.writeTextAtomic(allocator, paths.receipt, "{\"conflict\":true}");
    try std.testing.expectError(
        error.LaneAlreadyTerminal,
        reconcileTerminalProjectionAlloc(
            allocator,
            paths,
            "trial-null-001",
            "lane-null-a0",
            terminal_control.registration_digest,
        ),
    );
    try durable_store.writeTextAtomic(allocator, paths.receipt, receipt);
    try deleteFileIfExists(paths.receipt);
    const recovered_terminal = try reconcileTerminalProjectionAlloc(
        allocator,
        paths,
        "trial-null-001",
        "lane-null-a0",
        terminal_control.registration_digest,
    );
    defer recovered_terminal.deinit(allocator);
    const recovered_receipt = try readFileAlloc(allocator, paths.receipt, MaxInputBytes);
    defer allocator.free(recovered_receipt);
    try std.testing.expectEqualStrings(receipt, recovered_receipt);
    try std.testing.expectEqualStrings(
        terminal_control.terminal_control_fingerprint,
        recovered_terminal.terminal_control_fingerprint,
    );

    const original_receipt = try allocator.dupe(u8, receipt);
    defer allocator.free(original_receipt);
    const second_lease = try testPipeWithBytes(raw_lease);
    const second_input = try testPipeWithBytes(input);
    const second_seed = try testPipeWithBytes(&seed);
    try std.testing.expectError(error.LaneAlreadyClaimed, cmdRun(allocator, testRunFailureOptions(
        trial_path,
        receipt_dir,
        executor,
        ledger,
        second_lease,
        second_input,
        input_fingerprint,
        second_seed,
        root,
    )));
    const receipt_after_retry = try readFileAlloc(allocator, paths.receipt, MaxInputBytes);
    defer allocator.free(receipt_after_retry);
    try std.testing.expectEqualStrings(original_receipt, receipt_after_retry);

    const alternate_receipt_dir = try std.fs.path.join(allocator, &.{ root, "alternate-receipts" });
    defer allocator.free(alternate_receipt_dir);
    const third_lease = try testPipeWithBytes(raw_lease);
    const third_input = try testPipeWithBytes(input);
    const third_seed = try testPipeWithBytes(&seed);
    try std.testing.expectError(error.LaneAlreadyClaimed, cmdRun(allocator, testRunFailureOptions(
        trial_path,
        alternate_receipt_dir,
        executor,
        ledger,
        third_lease,
        third_input,
        input_fingerprint,
        third_seed,
        root,
    )));

    const cleanup_preview = try buildCleanupReceiptAlloc(
        allocator,
        paths,
        "trial-null-001",
        "lane-null-a0",
    );
    defer allocator.free(cleanup_preview);
    try persistCleanupIntent(
        allocator,
        paths,
        "trial-null-001",
        "lane-null-a0",
        recovered_terminal,
        cleanup_preview,
    );
    try deleteTree(paths.workspace);
    try cmdCleanup(allocator, .{
        .command = .cleanup,
        .trial_id = "trial-null-001",
        .lane_id = "lane-null-a0",
        .receipt_dir = receipt_dir,
        .claim_store_override = root,
    });
    try std.testing.expect(!pathExists(paths.workspace));
    try std.testing.expect(pathExists(paths.claim));
    try std.testing.expect(pathExists(paths.receipt));
    try std.testing.expect(pathExists(paths.failure_detail));
    try std.testing.expect(pathExists(paths.evidence));
    try std.testing.expect(pathExists(paths.presented_input_archive));
    try std.testing.expect(pathExists(paths.cleanup_receipt));
    try std.testing.expect(try verifyCleanupControlIfPresent(
        allocator,
        paths,
        "trial-null-001",
        "lane-null-a0",
        terminal_control,
    ));
    const cleanup_control_path = (try findControlArtifactPathAlloc(
        allocator,
        paths.claim,
        terminal_control.registration_digest,
        .cleanup,
    )) orelse return error.CleanupControlMismatch;
    defer allocator.free(cleanup_control_path);
    try deleteFileIfExists(cleanup_control_path);
    try durable_store.writeTextAtomic(allocator, paths.cleanup_receipt, "{\"conflict\":true}");
    try std.testing.expectError(error.CleanupArtifactConflict, cmdCleanup(allocator, .{
        .command = .cleanup,
        .trial_id = "trial-null-001",
        .lane_id = "lane-null-a0",
        .receipt_dir = receipt_dir,
        .claim_store_override = root,
    }));
    try durable_store.writeTextAtomic(allocator, paths.cleanup_receipt, cleanup_preview);
    try cmdCleanup(allocator, .{
        .command = .cleanup,
        .trial_id = "trial-null-001",
        .lane_id = "lane-null-a0",
        .receipt_dir = receipt_dir,
        .claim_store_override = root,
    });
    var cleanup_file = try std.Io.Dir.openFileAbsolute(defaultIo(), paths.cleanup_receipt, .{});
    try cleanup_file.setPermissions(defaultIo(), .fromMode(0o600));
    cleanup_file.close(defaultIo());
    try std.testing.expectError(
        error.ControlArtifactNotSealed,
        verifyCleanupControlIfPresent(
            allocator,
            paths,
            "trial-null-001",
            "lane-null-a0",
            terminal_control,
        ),
    );
}

test "claimed output overflow persists one signed bounded aborted receipt" {
    const allocator = std.testing.allocator;
    const output_limit = 8;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executor = try std.fs.path.join(allocator, &.{ root, "overflow-executor.sh" });
    defer allocator.free(executor);
    try durable_store.writeTextAtomic(
        allocator,
        executor,
        "#!/bin/sh\n(sleep 0.2; printf late > \"$4.late\") &\nprintf '123456789'\nsleep 5\n",
    );
    var executor_file = try std.Io.Dir.openFileAbsolute(defaultIo(), executor, .{});
    try executor_file.setPermissions(defaultIo(), .fromMode(0o500));
    executor_file.close(defaultIo());
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), receipt_dir);

    const raw_lease = "HYL1-output-limit-test";
    const ledger = try writeMockLaneMaterializationLedgerAlloc(allocator, root, raw_lease);
    defer allocator.free(ledger);
    const bound = try bindTestRunnerContractAlloc(allocator, hctp_fixtures.valid_null_trial, executor, ledger);
    defer allocator.free(bound);
    const seed = [_]u8{0x54} ** 32;
    const trial = try receiptBoundTestTrialAlloc(allocator, bound, seed, executor, ledger);
    defer allocator.free(trial);
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    defer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    try writeMockTrialFingerprint(allocator, root, trial);
    const input = "{\"request\":\"bounded-output\"}";
    const input_fingerprint = try attestation.digestBytesAlloc(allocator, input);
    defer allocator.free(input_fingerprint);
    try writeMockInputFingerprint(allocator, root, input_fingerprint);
    var run_options = testRunFailureOptions(
        trial_path,
        receipt_dir,
        executor,
        ledger,
        try testPipeWithBytes(raw_lease),
        try testPipeWithBytes(input),
        input_fingerprint,
        try testPipeWithBytes(&seed),
        root,
    );
    run_options.executor_output_limit_override = output_limit;
    try cmdRun(allocator, run_options);

    const paths = try lanePathsAlloc(allocator, receipt_dir, root, "trial-null-001", "lane-null-a0");
    defer paths.deinit(allocator);
    const receipt = try readFileAlloc(allocator, paths.receipt, MaxInputBytes);
    defer allocator.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{});
    defer parsed.deinit();
    const receipt_root = try object(parsed.value);
    try std.testing.expectEqualStrings("hylo-run-receipt/v1", try requiredString(receipt_root, "schema"));
    try std.testing.expect(std.mem.indexOf(u8, receipt, ".executables") == null);
    const terminal = try requiredObject(receipt_root, "terminal");
    try std.testing.expectEqualStrings("aborted", try requiredString(terminal, "status"));
    try std.testing.expectEqualStrings("executor_output_limit_exceeded", try requiredString(terminal, "failure_class"));
    const receipt_attestation = try requiredObject(receipt_root, "attestation");
    try std.testing.expectEqualStrings("hylo-attestation/v1", try requiredString(receipt_attestation, "schema"));
    const subject_fingerprint = try attestation.subjectFingerprintAlloc(allocator, parsed.value);
    defer allocator.free(subject_fingerprint);
    try std.testing.expectEqualStrings(subject_fingerprint, try requiredString(receipt_attestation, "subject_fingerprint"));

    const failure_detail = try readFileAlloc(allocator, paths.failure_detail, MaxInputBytes);
    defer allocator.free(failure_detail);
    var detail_parsed = try std.json.parseFromSlice(std.json.Value, allocator, failure_detail, .{});
    defer detail_parsed.deinit();
    const detail_root = try object(detail_parsed.value);
    try std.testing.expectEqualStrings(executor, try requiredString(detail_root, "executor"));
    try std.testing.expect(std.mem.indexOf(u8, failure_detail, ".executables") == null);
    const admitted_executor_fingerprint = try fileFingerprintAlloc(allocator, executor);
    defer allocator.free(admitted_executor_fingerprint);
    try std.testing.expectEqualStrings(
        admitted_executor_fingerprint,
        try requiredString(detail_root, "executor_binary_fingerprint"),
    );
    const capture = try requiredObject(detail_root, "output_capture");
    try std.testing.expectEqual(@as(u64, output_limit), try requiredU64(capture, "limit_bytes_per_stream"));
    try std.testing.expectEqual(@as(u64, output_limit), try requiredU64(capture, "stdout_bytes_persisted"));
    try std.testing.expect(!(try requiredBool(capture, "stdout_complete")));
    try std.testing.expect(try requiredBool(capture, "stdout_truncated"));
    const stdout_stat = try std.Io.Dir.cwd().statFile(defaultIo(), paths.executor_stdout, .{});
    const stderr_stat = try std.Io.Dir.cwd().statFile(defaultIo(), paths.executor_stderr, .{});
    try std.testing.expectEqual(@as(u64, output_limit), stdout_stat.size);
    try std.testing.expect(stderr_stat.size <= output_limit);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stdout_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stderr_stat.permissions.toMode() & 0o777);
    const stdout_fingerprint = try fileFingerprintAlloc(allocator, paths.executor_stdout);
    defer allocator.free(stdout_fingerprint);
    const stderr_fingerprint = try fileFingerprintAlloc(allocator, paths.executor_stderr);
    defer allocator.free(stderr_fingerprint);
    try std.testing.expectEqualStrings(stdout_fingerprint, try requiredString(detail_root, "executor_stdout_fingerprint"));
    try std.testing.expectEqualStrings(stderr_fingerprint, try requiredString(detail_root, "executor_stderr_fingerprint"));
    const native_receipt = try readFileAlloc(allocator, paths.failure_native_receipt, MaxInputBytes);
    defer allocator.free(native_receipt);
    try std.testing.expect(std.mem.indexOf(u8, native_receipt, executor) != null);
    try std.testing.expect(std.mem.indexOf(u8, native_receipt, ".executables") == null);
    const receipt_stat = try std.Io.Dir.cwd().statFile(defaultIo(), paths.receipt, .{});
    const detail_stat = try std.Io.Dir.cwd().statFile(defaultIo(), paths.failure_detail, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o400), receipt_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o400), detail_stat.permissions.toMode() & 0o777);
    std.Io.sleep(std.testing.io, .fromMilliseconds(400), .awake) catch {};
    const late_path = try std.fmt.allocPrint(allocator, "{s}.late", .{paths.executor_result});
    defer allocator.free(late_path);
    try std.testing.expect(!pathExists(late_path));
}

test "claimed carrier replacement persists one signed invalid receipt without substitute evidence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executor = try std.fs.path.join(allocator, &.{ root, "replace-carrier-executor.sh" });
    defer allocator.free(executor);
    try durable_store.writeTextAtomic(
        allocator,
        executor,
        "#!/bin/sh\nrm -f \"$4.stdout\"\nprintf substitute > \"$4.stdout\"\nprintf output\n",
    );
    var executor_file = try std.Io.Dir.openFileAbsolute(defaultIo(), executor, .{});
    try executor_file.setPermissions(defaultIo(), .fromMode(0o500));
    executor_file.close(defaultIo());
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), receipt_dir);

    const raw_lease = "HYL1-carrier-replacement-test";
    const ledger = try writeMockLaneMaterializationLedgerAlloc(allocator, root, raw_lease);
    defer allocator.free(ledger);
    const bound = try bindTestRunnerContractAlloc(allocator, hctp_fixtures.valid_null_trial, executor, ledger);
    defer allocator.free(bound);
    const seed = [_]u8{0x72} ** 32;
    const trial = try receiptBoundTestTrialAlloc(allocator, bound, seed, executor, ledger);
    defer allocator.free(trial);
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    defer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    try writeMockTrialFingerprint(allocator, root, trial);
    const input = "{\"request\":\"replace-carrier\"}";
    const input_fingerprint = try attestation.digestBytesAlloc(allocator, input);
    defer allocator.free(input_fingerprint);
    try writeMockInputFingerprint(allocator, root, input_fingerprint);
    try cmdRun(allocator, testRunFailureOptions(
        trial_path,
        receipt_dir,
        executor,
        ledger,
        try testPipeWithBytes(raw_lease),
        try testPipeWithBytes(input),
        input_fingerprint,
        try testPipeWithBytes(&seed),
        root,
    ));

    const paths = try lanePathsAlloc(allocator, receipt_dir, root, "trial-null-001", "lane-null-a0");
    defer paths.deinit(allocator);
    const receipt = try readFileAlloc(allocator, paths.receipt, MaxInputBytes);
    defer allocator.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{});
    defer parsed.deinit();
    const terminal = try requiredObject(try object(parsed.value), "terminal");
    try std.testing.expectEqualStrings("invalid", try requiredString(terminal, "status"));
    try std.testing.expectEqualStrings("runner_output_capture_failure", try requiredString(terminal, "failure_class"));

    const failure_detail = try readFileAlloc(allocator, paths.failure_detail, MaxInputBytes);
    defer allocator.free(failure_detail);
    var detail_parsed = try std.json.parseFromSlice(std.json.Value, allocator, failure_detail, .{});
    defer detail_parsed.deinit();
    const detail = try object(detail_parsed.value);
    try std.testing.expectEqualStrings("ExecutorOutputCarrierDrift", try requiredString(detail, "runner_error"));
    try std.testing.expect(detail.get("executor_stdout_ref").? == .null);
    try std.testing.expect(detail.get("executor_stdout_fingerprint").? == .null);
    try std.testing.expect(detail.get("executor_stderr_ref").? == .null);
    try std.testing.expect(detail.get("executor_stderr_fingerprint").? == .null);
    const substitute = try readFileAlloc(allocator, paths.executor_stdout, MaxInputBytes);
    defer allocator.free(substitute);
    try std.testing.expectEqualStrings("substitute", substitute);
    const capture = try requiredObject(detail, "output_capture");
    try std.testing.expect(!(try requiredBool(capture, "stdout_complete")));
    try std.testing.expect(!(try requiredBool(capture, "stderr_complete")));
}

test "crash-like executor termination maps to an aborted terminal disposition" {
    const disposition = failureDisposition(error.ExecutorAborted);
    try std.testing.expectEqualStrings("aborted", disposition.status);
    try std.testing.expectEqualStrings("executor_terminated_by_signal", disposition.class);
    try std.testing.expectEqual(@as(u8, 143), statusToExitCode(@bitCast(@as(c_int, 15))));
}

test "terminal receipt persistence is create-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "terminal.json" });
    defer std.testing.allocator.free(path);
    try persistTerminalReceipt(std.testing.allocator, path, "{\"status\":\"failed\"}");
    try std.testing.expectError(
        error.LaneAlreadyTerminal,
        persistTerminalReceipt(std.testing.allocator, path, "{\"status\":\"completed\"}"),
    );
    const bytes = try readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"status\":\"failed\"}", bytes);
}

test "owned secret descriptor is closed before executor launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret", .data = "HYL1-secret" });
    const file = try tmp.dir.openFile(std.testing.io, "secret", .{});
    const fd = file.handle;
    const secret = try readOwnedFdAlloc(std.testing.allocator, fd, 256);
    defer std.testing.allocator.free(secret);
    try std.testing.expectEqualStrings("HYL1-secret", secret);
    const result = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
    try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(result));
}

test "sensitive inputs require anonymous read-only pipes outside standard streams" {
    var accepted: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&accepted) != 0) return error.TestFdSetupFailed;
    closeOwnedFd(accepted[1]);
    _ = try sensitiveInputEndpoint(accepted[0]);
    closeOwnedFd(accepted[0]);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "regular", .data = "secret" });
    const regular = try tmp.dir.openFile(std.testing.io, "regular", .{});
    defer regular.close(std.testing.io);
    try std.testing.expectError(error.SensitiveFdEndpointUnbound, sensitiveInputEndpoint(regular.handle));

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const fifo_path = try std.fs.path.join(std.testing.allocator, &.{ root, "named-fifo" });
    defer std.testing.allocator.free(fifo_path);
    const mkfifo = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "mkfifo", fifo_path },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer std.testing.allocator.free(mkfifo.stdout);
    defer std.testing.allocator.free(mkfifo.stderr);
    if (processExitCode(mkfifo.term) != 0) return error.TestFdSetupFailed;
    const fifo_path_z = try std.testing.allocator.dupeZ(u8, fifo_path);
    defer std.testing.allocator.free(fifo_path_z);
    const named_fifo_fd = std.c.open(fifo_path_z.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true });
    if (named_fifo_fd < 0) return error.TestFdSetupFailed;
    defer closeOwnedFd(named_fifo_fd);
    try std.testing.expectError(error.SensitiveFdEndpointUnbound, sensitiveInputEndpoint(named_fifo_fd));

    var wrong_direction: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&wrong_direction) != 0) return error.TestFdSetupFailed;
    defer closeOwnedFd(wrong_direction[0]);
    defer closeOwnedFd(wrong_direction[1]);
    try std.testing.expectError(error.SensitiveFdEndpointUnbound, sensitiveInputEndpoint(wrong_direction[1]));

    const standard_alias = std.c.dup(std.posix.STDOUT_FILENO);
    if (standard_alias < 0) return error.TestFdSetupFailed;
    defer closeOwnedFd(standard_alias);
    try std.testing.expectError(error.SensitiveFdStandardStreamAlias, sensitiveInputEndpoint(standard_alias));
}

test "sensitive inputs reject aliases by endpoint identity" {
    var lease_pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&lease_pipe) != 0) return error.TestFdSetupFailed;
    defer closeOwnedFd(lease_pipe[0]);
    defer closeOwnedFd(lease_pipe[1]);
    const alias = std.c.dup(lease_pipe[0]);
    if (alias < 0) return error.TestFdSetupFailed;
    defer closeOwnedFd(alias);
    try std.testing.expectError(
        error.SensitiveFdAliased,
        validateSensitiveInputFds(lease_pipe[0], alias, null, null),
    );
}

test "signing seed is exactly 32 raw bytes followed by EOF" {
    const expected = [_]u8{0x5a} ** 32;
    const exact_fd = try testPipeWithBytes(&expected);
    var actual = try readSigningSeed(exact_fd);
    defer std.crypto.secureZero(u8, &actual);
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    var trailing = [_]u8{0x5a} ** 33;
    defer std.crypto.secureZero(u8, &trailing);
    try std.testing.expectError(error.SigningSeedInvalid, readSigningSeed(try testPipeWithBytes(&trailing)));

    const encoded = "WlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlo=";
    try std.testing.expectError(error.SigningSeedInvalid, readSigningSeed(try testPipeWithBytes(encoded)));
}

test "executor inherits only standard allowlisted descriptors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret", .data = "controller-only" });
    const secret = try tmp.dir.openFile(std.testing.io, "secret", .{});
    defer secret.close(std.testing.io);
    const leaked_fd: std.posix.fd_t = 100;
    if (std.c.dup2(secret.handle, leaked_fd) < 0) return error.TestFdSetupFailed;
    defer closeOwnedFd(leaked_fd);
    _ = std.posix.system.fcntl(leaked_fd, std.posix.F.SETFD, @as(usize, 0));

    var script = try tmp.dir.createFile(std.testing.io, "fd-check.sh", .{ .read = true, .truncate = true });
    var script_writer = script.writer(std.testing.io, &.{});
    try script_writer.interface.print(
        "#!/bin/sh\nif [ -r /dev/fd/{d} ]; then exit 91; fi\nexit 0\n",
        .{leaked_fd},
    );
    try script.setPermissions(std.testing.io, .fromMode(0o700));
    script.close(std.testing.io);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const executable = try tmp.dir.realPathFileAlloc(std.testing.io, "fd-check.sh", std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const request = try std.fs.path.join(std.testing.allocator, &.{ root, "request.json" });
    defer std.testing.allocator.free(request);
    const result = try std.fs.path.join(std.testing.allocator, &.{ root, "result.json" });
    defer std.testing.allocator.free(result);
    const execution = try runExecutor(std.testing.allocator, executable, request, result, root, 1_000);
    defer std.testing.allocator.free(execution.stdout);
    defer std.testing.allocator.free(execution.stderr);
    try std.testing.expectEqual(@as(u8, 0), execution.exit_code);
    const descriptor_flags = std.posix.system.fcntl(leaked_fd, std.posix.F.GETFD, @as(usize, 0));
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(descriptor_flags));
}

test "executor runs in the requested isolated cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var script = try tmp.dir.createFile(std.testing.io, "cwd-check.sh", .{ .read = true, .truncate = true });
    try script.writeStreamingAll(std.testing.io, "#!/bin/sh\npwd > \"$4.cwd\"\nexit 0\n");
    try script.setPermissions(std.testing.io, .fromMode(0o700));
    script.close(std.testing.io);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const executable = try tmp.dir.realPathFileAlloc(std.testing.io, "cwd-check.sh", std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const request = try std.fs.path.join(std.testing.allocator, &.{ root, "request.json" });
    defer std.testing.allocator.free(request);
    const result = try std.fs.path.join(std.testing.allocator, &.{ root, "result.json" });
    defer std.testing.allocator.free(result);
    const execution = try runExecutor(std.testing.allocator, executable, request, result, root, 1_000);
    defer std.testing.allocator.free(execution.stdout);
    defer std.testing.allocator.free(execution.stderr);
    try std.testing.expectEqual(@as(u8, 0), execution.exit_code);
    const cwd_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.cwd", .{result});
    defer std.testing.allocator.free(cwd_path);
    const observed_raw = try readFileAlloc(std.testing.allocator, cwd_path, 4096);
    defer std.testing.allocator.free(observed_raw);
    try std.testing.expectEqualStrings(root, std.mem.trim(u8, observed_raw, " \t\r\n"));
}

test "runner receipts cite CAS observations and disclose capability limits" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    defer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, hctp_fixtures.valid_null_trial);
    var loaded = try loadLane(allocator, trial_path, "lane-null-a0");
    defer loaded.parsed.deinit();
    const paths = try lanePathsAlloc(allocator, root, root, loaded.view.trial_id, loaded.view.lane_id);
    defer paths.deinit(allocator);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.evidence);
    var limits = try std.json.parseFromSlice(std.json.Value, allocator, "{\"limitations\":[]}", .{});
    defer limits.deinit();
    const executor_assertion = EvidenceFile{
        .ref = try allocator.dupe(u8, "executor-assertion.json"),
        .fingerprint = try allocator.dupe(u8, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .present = true,
    };
    defer executor_assertion.deinit(allocator);
    const execution_tree_observation = ExecutionTreeObservation{
        .common_projection_fingerprint = null,
        .exact_tree_fingerprint = try allocator.dupe(u8, "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        .output_carrier_fingerprint = try allocator.dupe(u8, "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
    };
    defer execution_tree_observation.deinit(allocator);
    const observations = try createRunnerObservationsAlloc(
        allocator,
        loaded.view,
        paths,
        .{
            .present = false,
            .arm_value_fingerprint = null,
            .snapshot_ref = null,
            .snapshot_fingerprint = null,
            .carrier_bytes = null,
            .carrier_fingerprint = null,
            .workspace_ref = "",
            .archive_ref = "",
            .package_root = "",
        },
        .{
            .before_fingerprint = null,
            .after_fingerprint = null,
        },
        execution_tree_observation,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .{},
        try requiredArray(try object(limits.value), "limitations"),
        executor_assertion,
        executor_assertion,
        executor_assertion,
        executor_assertion,
    );
    defer observations.deinit(allocator);
    inline for (.{
        .{ paths.reset_observation, observations.reset_fingerprint, "cas-reset-observation/v1" },
        .{ paths.filesystem_observation, observations.filesystem_fingerprint, "cas-filesystem-observation/v1" },
        .{ paths.network_observation, observations.network_fingerprint, "cas-network-observation/v1" },
        .{ paths.external_effect_observation, observations.external_effect_fingerprint, "cas-external-effect-observation/v1" },
    }) |expected| {
        const observed_fingerprint = try fileFingerprintAlloc(allocator, expected[0]);
        defer allocator.free(observed_fingerprint);
        try std.testing.expectEqualStrings(expected[1], observed_fingerprint);
        const raw = try readFileAlloc(allocator, expected[0], MaxInputBytes);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(expected[2], try requiredString(try object(parsed.value), "schema"));
    }
    const network_raw = try readFileAlloc(allocator, paths.network_observation, MaxInputBytes);
    defer allocator.free(network_raw);
    var network = try std.json.parseFromSlice(std.json.Value, allocator, network_raw, .{});
    defer network.deinit();
    const network_observation = try object(network.value);
    try std.testing.expect(!try requiredBool(network_observation, "independently_enforced"));
    try std.testing.expect(!try requiredBool(network_observation, "os_confinement"));
    try std.testing.expect(std.mem.indexOf(
        u8,
        observations.limitations,
        "hostile arbitrary native code is not OS-confined",
    ) != null);
}

test "executor environment is deterministic and excludes controller secrets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(workspace);
    var environment = try sanitizedExecutorEnvironment(std.testing.allocator, workspace);
    defer environment.deinit();
    try std.testing.expectEqualStrings(workspace, environment.get("HOME").?);
    try std.testing.expectEqualStrings("sanitized-v1", environment.get("CAS_HCTP_ENVIRONMENT").?);
    try std.testing.expect(environment.get("HYLO_LANE_LEASE") == null);
    try std.testing.expect(environment.get("OPENAI_API_KEY") == null);
    try std.testing.expect(environment.get("CODEX_HOME") == null);
}

test "evidence references cannot escape the workspace or traverse symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace/inside.json", .data = "{}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.json", .data = "{}" });
    try tmp.dir.symLink(std.testing.io, "../outside.json", "workspace/link.json", .{});
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(workspace);
    const outside = try tmp.dir.realPathFileAlloc(std.testing.io, "outside.json", std.testing.allocator);
    defer std.testing.allocator.free(outside);
    const inside = try resolveWorkspaceArtifactAlloc(std.testing.allocator, workspace, "inside.json");
    defer std.testing.allocator.free(inside);
    try std.testing.expect(std.mem.endsWith(u8, inside, "workspace/inside.json"));
    try std.testing.expectError(
        error.EvidenceOutsideWorkspace,
        resolveWorkspaceArtifactAlloc(std.testing.allocator, workspace, outside),
    );
    try std.testing.expectError(
        error.EvidenceOutsideWorkspace,
        resolveWorkspaceArtifactAlloc(std.testing.allocator, workspace, "../outside.json"),
    );
    try std.testing.expectError(
        error.EvidenceSymlinkForbidden,
        resolveWorkspaceArtifactAlloc(std.testing.allocator, workspace, "link.json"),
    );
}

fn expectExecutorLimitTermination(
    allocator: std.mem.Allocator,
    pid_path: []const u8,
    natural_completion_path: []const u8,
) !void {
    const raw_pid = try readFileAlloc(allocator, pid_path, 64);
    defer allocator.free(raw_pid);
    const pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, raw_pid, " \t\r\n"),
        10,
    );
    var status: c_int = undefined;
    try std.testing.expectEqual(
        std.posix.E.CHILD,
        std.posix.errno(std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG)),
    );
    const group_observation = try observeExecutorGroupAlloc(allocator, pid);
    try std.testing.expect(group_observation != .live_members);
    try std.testing.expect(!pathExists(natural_completion_path));
}

test "bounded executor capture accepts the exact limit and rejects one extra byte per stream" {
    const allocator = std.testing.allocator;
    const output_limit = 8;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executable_store = try std.fs.path.join(allocator, &.{ root, ".executables" });
    defer allocator.free(executable_store);
    const request = try std.fs.path.join(allocator, &.{ root, "request.json" });
    defer allocator.free(request);

    const exact_origin = try std.fs.path.join(allocator, &.{ root, "exact.sh" });
    defer allocator.free(exact_origin);
    try durable_store.writeTextAtomic(
        allocator,
        exact_origin,
        "#!/bin/sh\nprintf '12345678'\nprintf 'abcdefgh' >&2\n",
    );
    var executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), exact_origin, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o500));
    executable_file.close(defaultIo());
    const exact_binding = try bindExecutableInStoreAlloc(allocator, exact_origin, executable_store);
    defer exact_binding.deinit(allocator);
    const exact_result = try std.fs.path.join(allocator, &.{ root, "exact-result.json" });
    defer allocator.free(exact_result);
    const exact = try runExecutorWithTempRootAndLimit(
        allocator,
        &exact_binding,
        request,
        exact_result,
        root,
        root,
        1_000,
        output_limit,
    );
    defer allocator.free(exact.stdout);
    defer allocator.free(exact.stderr);
    try std.testing.expectEqualStrings("12345678", exact.stdout);
    try std.testing.expectEqualStrings("abcdefgh", exact.stderr);
    const exact_stdout_path = try std.fmt.allocPrint(allocator, "{s}.stdout", .{exact_result});
    defer allocator.free(exact_stdout_path);
    const exact_stderr_path = try std.fmt.allocPrint(allocator, "{s}.stderr", .{exact_result});
    defer allocator.free(exact_stderr_path);
    const exact_stdout_stat = try std.Io.Dir.cwd().statFile(defaultIo(), exact_stdout_path, .{});
    const exact_stderr_stat = try std.Io.Dir.cwd().statFile(defaultIo(), exact_stderr_path, .{});
    try std.testing.expectEqual(@as(u64, output_limit), exact_stdout_stat.size);
    try std.testing.expectEqual(@as(u64, output_limit), exact_stderr_stat.size);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), exact_stdout_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), exact_stderr_stat.permissions.toMode() & 0o777);

    const stdout_origin = try std.fs.path.join(allocator, &.{ root, "stdout-overflow.sh" });
    defer allocator.free(stdout_origin);
    try durable_store.writeTextAtomic(
        allocator,
        stdout_origin,
        "#!/bin/sh\nprintf '%s' \"$$\" > \"$4.stdout-pid\"\ni=0\nwhile [ \"$i\" -lt 1024 ]; do printf 'poisonpoison' >> \"$4.stdout\"; i=$((i + 1)); done\n(sleep 0.2; printf late > \"$4.stdout-late\") &\nprintf '123456789'\nsleep 5\nprintf natural > \"$4.stdout-natural\"\n",
    );
    executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), stdout_origin, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o500));
    executable_file.close(defaultIo());
    const stdout_binding = try bindExecutableInStoreAlloc(allocator, stdout_origin, executable_store);
    defer stdout_binding.deinit(allocator);
    const stdout_result = try std.fs.path.join(allocator, &.{ root, "stdout-result.json" });
    defer allocator.free(stdout_result);
    try std.testing.expectError(
        error.ExecutorStdoutLimitExceeded,
        runExecutorWithTempRootAndLimit(
            allocator,
            &stdout_binding,
            request,
            stdout_result,
            root,
            root,
            1_000,
            output_limit,
        ),
    );
    const stdout_pid_path = try std.fmt.allocPrint(allocator, "{s}.stdout-pid", .{stdout_result});
    defer allocator.free(stdout_pid_path);
    const stdout_natural_path = try std.fmt.allocPrint(allocator, "{s}.stdout-natural", .{stdout_result});
    defer allocator.free(stdout_natural_path);
    try expectExecutorLimitTermination(allocator, stdout_pid_path, stdout_natural_path);
    const stdout_path = try std.fmt.allocPrint(allocator, "{s}.stdout", .{stdout_result});
    defer allocator.free(stdout_path);
    const stdout_stat = try std.Io.Dir.cwd().statFile(defaultIo(), stdout_path, .{});
    try std.testing.expectEqual(@as(u64, output_limit), stdout_stat.size);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stdout_stat.permissions.toMode() & 0o777);
    const stdout_prefix = try readFileAlloc(allocator, stdout_path, output_limit + 1);
    defer allocator.free(stdout_prefix);
    try std.testing.expectEqualStrings("12345678", stdout_prefix);
    const stdout_fingerprint = try fileFingerprintLimitedAlloc(allocator, stdout_path, output_limit);
    defer allocator.free(stdout_fingerprint);
    try validateFingerprint(stdout_fingerprint);

    const stderr_origin = try std.fs.path.join(allocator, &.{ root, "stderr-overflow.sh" });
    defer allocator.free(stderr_origin);
    try durable_store.writeTextAtomic(
        allocator,
        stderr_origin,
        "#!/bin/sh\nprintf '%s' \"$$\" > \"$4.stderr-pid\"\n(sleep 0.2; printf late > \"$4.stderr-late\") &\nprintf 'abcdefghi' >&2\nsleep 5\nprintf natural > \"$4.stderr-natural\"\n",
    );
    executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), stderr_origin, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o500));
    executable_file.close(defaultIo());
    const stderr_binding = try bindExecutableInStoreAlloc(allocator, stderr_origin, executable_store);
    defer stderr_binding.deinit(allocator);
    const stderr_result = try std.fs.path.join(allocator, &.{ root, "stderr-result.json" });
    defer allocator.free(stderr_result);
    try std.testing.expectError(
        error.ExecutorStderrLimitExceeded,
        runExecutorWithTempRootAndLimit(
            allocator,
            &stderr_binding,
            request,
            stderr_result,
            root,
            root,
            1_000,
            output_limit,
        ),
    );
    const stderr_pid_path = try std.fmt.allocPrint(allocator, "{s}.stderr-pid", .{stderr_result});
    defer allocator.free(stderr_pid_path);
    const stderr_natural_path = try std.fmt.allocPrint(allocator, "{s}.stderr-natural", .{stderr_result});
    defer allocator.free(stderr_natural_path);
    try expectExecutorLimitTermination(allocator, stderr_pid_path, stderr_natural_path);
    const stderr_path = try std.fmt.allocPrint(allocator, "{s}.stderr", .{stderr_result});
    defer allocator.free(stderr_path);
    const stderr_stat = try std.Io.Dir.cwd().statFile(defaultIo(), stderr_path, .{});
    try std.testing.expectEqual(@as(u64, output_limit), stderr_stat.size);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stderr_stat.permissions.toMode() & 0o777);
    const stderr_prefix = try readFileAlloc(allocator, stderr_path, output_limit + 1);
    defer allocator.free(stderr_prefix);
    try std.testing.expectEqualStrings("abcdefgh", stderr_prefix);

    const output_limit_disposition = failureDisposition(error.ExecutorStdoutLimitExceeded);
    try std.testing.expectEqualStrings("aborted", output_limit_disposition.status);
    try std.testing.expectEqualStrings("executor_output_limit_exceeded", output_limit_disposition.class);
    const stdout_late = try std.fmt.allocPrint(allocator, "{s}.stdout-late", .{stdout_result});
    defer allocator.free(stdout_late);
    const stderr_late = try std.fmt.allocPrint(allocator, "{s}.stderr-late", .{stderr_result});
    defer allocator.free(stderr_late);
    try std.testing.expect(!pathExists(stdout_late));
    try std.testing.expect(!pathExists(stderr_late));
}

test "bounded capture evidence rejects directories symlinks and oversized files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const regular = try std.fs.path.join(allocator, &.{ root, "regular" });
    defer allocator.free(regular);
    const oversized = try std.fs.path.join(allocator, &.{ root, "oversized" });
    defer allocator.free(oversized);
    const directory = try std.fs.path.join(allocator, &.{ root, "directory" });
    defer allocator.free(directory);
    const symlink = try std.fs.path.join(allocator, &.{ root, "symlink" });
    defer allocator.free(symlink);
    try durable_store.writeTextAtomic(allocator, regular, "12345678");
    try durable_store.writeTextAtomic(allocator, oversized, "123456789");
    try std.Io.Dir.cwd().createDirPath(defaultIo(), directory);
    try std.Io.Dir.cwd().symLink(defaultIo(), regular, symlink, .{});
    const evidence = (try boundedRegularCaptureEvidenceAlloc(allocator, regular, 8)).?;
    defer allocator.free(evidence.fingerprint);
    try std.testing.expectEqual(@as(u64, 8), evidence.size);
    try std.testing.expect((try boundedRegularCaptureEvidenceAlloc(allocator, oversized, 8)) == null);
    try std.testing.expect((try boundedRegularCaptureEvidenceAlloc(allocator, directory, 8)) == null);
    try std.testing.expect((try boundedRegularCaptureEvidenceAlloc(allocator, symlink, 8)) == null);
}

test "executor carrier path replacement is typed as incomplete capture evidence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executable_store = try std.fs.path.join(allocator, &.{ root, ".executables" });
    defer allocator.free(executable_store);
    const origin = try std.fs.path.join(allocator, &.{ root, "replace-carrier.sh" });
    defer allocator.free(origin);
    try durable_store.writeTextAtomic(
        allocator,
        origin,
        "#!/bin/sh\nrm -f \"$4.stdout\"\nmkdir \"$4.stdout\"\nprintf output\n",
    );
    var executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), origin, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o500));
    executable_file.close(defaultIo());
    const binding = try bindExecutableInStoreAlloc(allocator, origin, executable_store);
    defer binding.deinit(allocator);
    const request = try std.fs.path.join(allocator, &.{ root, "request.json" });
    defer allocator.free(request);
    const result = try std.fs.path.join(allocator, &.{ root, "result.json" });
    defer allocator.free(result);
    try std.testing.expectError(
        error.ExecutorOutputCarrierDrift,
        runExecutorWithTempRootAndLimit(allocator, &binding, request, result, root, root, 1_000, 8),
    );
    const disposition = failureDisposition(error.ExecutorOutputCarrierDrift);
    try std.testing.expectEqualStrings("invalid", disposition.status);
    try std.testing.expectEqualStrings("runner_output_capture_failure", disposition.class);
    try std.testing.expect(executorCaptureWasForcedIncomplete(error.ExecutorOutputCarrierDrift));
    const stdout_path = try std.fmt.allocPrint(allocator, "{s}.stdout", .{result});
    defer allocator.free(stdout_path);
    try std.testing.expect((try boundedRegularCaptureEvidenceAlloc(allocator, stdout_path, 8)) == null);
}

test "executor carrier distrust dominates simultaneous executable drift" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executable_store = try std.fs.path.join(allocator, &.{ root, ".executables" });
    defer allocator.free(executable_store);
    const origin = try std.fs.path.join(allocator, &.{ root, "replace-carrier-and-executable.sh" });
    defer allocator.free(origin);
    try durable_store.writeTextAtomic(
        allocator,
        origin,
        "#!/bin/sh\nspawn_path=$(cat \"$2\") || exit 9\nrm -f \"$4.stdout\"\nprintf substitute > \"$4.stdout\"\nrm -f \"$spawn_path\"\nprintf output\n",
    );
    var executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), origin, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o500));
    executable_file.close(defaultIo());
    const binding = try bindExecutableInStoreAlloc(allocator, origin, executable_store);
    defer binding.deinit(allocator);
    const request = try std.fs.path.join(allocator, &.{ root, "request.txt" });
    defer allocator.free(request);
    try durable_store.writeTextAtomic(allocator, request, binding.spawn_path);
    const result = try std.fs.path.join(allocator, &.{ root, "result.json" });
    defer allocator.free(result);
    try std.testing.expectError(
        error.ExecutorOutputCarrierDrift,
        runExecutorWithTempRootAndLimit(allocator, &binding, request, result, root, root, 1_000, 64),
    );
    const stdout_path = try std.fmt.allocPrint(allocator, "{s}.stdout", .{result});
    defer allocator.free(stdout_path);
    const substitute = try readFileAlloc(allocator, stdout_path, 64);
    defer allocator.free(substitute);
    try std.testing.expectEqualStrings("substitute", substitute);
}

test "executor carrier distrust survives target observation failure" {
    try std.testing.expect(
        preserveOutputCarrierDistrust(
            error.ExecutorOutputCarrierDrift,
            error.TargetPackageTreeMutation,
        ) == error.ExecutorOutputCarrierDrift,
    );
    try std.testing.expect(
        preserveOutputCarrierDistrust(
            error.ExecutableBindingDrift,
            error.TargetPackageTreeMutation,
        ) == error.TargetPackageTreeMutation,
    );
}

test "executor capture deadline bounds an escaped pipe holder after child reap" {
    const allocator = std.testing.allocator;
    var stdout_pipe = try ExecutorPipe.init();
    defer stdout_pipe.deinit();
    var stderr_pipe = try ExecutorPipe.init();
    defer stderr_pipe.deinit();
    var ready_pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&ready_pipe) != 0) return error.TestFdSetupFailed;
    var pid_pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pid_pipe) != 0) {
        closeRawFd(ready_pipe[0]);
        closeRawFd(ready_pipe[1]);
        return error.TestFdSetupFailed;
    }

    const child_pid = std.c.fork();
    if (child_pid < 0) return error.TestForkFailed;
    if (child_pid == 0) {
        _ = std.c.close(pid_pipe[0]);
        _ = std.c.setpgid(0, 0);
        const escaped_pid = std.c.fork();
        if (escaped_pid < 0) std.c._exit(91);
        if (escaped_pid == 0) {
            _ = std.c.close(pid_pipe[1]);
            _ = std.c.close(ready_pipe[0]);
            _ = std.c.close(stdout_pipe.read_fd.?);
            _ = std.c.close(stderr_pipe.read_fd.?);
            if (std.c.setsid() < 0) std.c._exit(92);
            var ready = [_]u8{1};
            if (std.c.write(ready_pipe[1], &ready, ready.len) != ready.len) std.c._exit(95);
            _ = std.c.close(ready_pipe[1]);
            while (true) {
                const sleep_time = std.c.timespec{ .sec = 1, .nsec = 0 };
                _ = std.c.nanosleep(&sleep_time, null);
            }
        }
        _ = std.c.close(stdout_pipe.read_fd.?);
        _ = std.c.close(stdout_pipe.write_fd.?);
        _ = std.c.close(stderr_pipe.read_fd.?);
        _ = std.c.close(stderr_pipe.write_fd.?);
        _ = std.c.close(ready_pipe[1]);
        var ready: [1]u8 = undefined;
        if (std.c.read(ready_pipe[0], &ready, ready.len) != ready.len) std.c._exit(93);
        _ = std.c.close(ready_pipe[0]);
        var child = escaped_pid;
        const child_bytes = std.mem.asBytes(&child);
        if (std.c.write(pid_pipe[1], child_bytes.ptr, child_bytes.len) != child_bytes.len) std.c._exit(94);
        _ = std.c.close(pid_pipe[1]);
        std.c._exit(0);
    }

    closeRawFd(ready_pipe[0]);
    closeRawFd(ready_pipe[1]);
    closeRawFd(pid_pipe[1]);
    stdout_pipe.closeWrite();
    stderr_pipe.closeWrite();
    var escaped_pid: std.c.pid_t = undefined;
    const escaped_bytes = std.mem.asBytes(&escaped_pid);
    if (std.c.read(pid_pipe[0], escaped_bytes.ptr, escaped_bytes.len) != escaped_bytes.len) {
        return error.TestFdSetupFailed;
    }
    closeRawFd(pid_pipe[0]);
    defer _ = std.posix.system.kill(escaped_pid, .KILL);

    try std.testing.expectError(
        error.ExecutorLivenessUnproved,
        superviseExecutorProcessAlloc(
            allocator,
            child_pid,
            &stdout_pipe,
            &stderr_pipe,
            5_000,
            8,
        ),
    );
    try std.testing.expectEqual(
        std.posix.E.SUCCESS,
        std.posix.errno(std.c.kill(escaped_pid, @enumFromInt(0))),
    );
}

test "executor rejects an unrepresentable duration before reserving carriers or spawning" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executable_store = try std.fs.path.join(allocator, &.{ root, ".executables" });
    defer allocator.free(executable_store);
    const origin = try std.fs.path.join(allocator, &.{ root, "must-not-launch.sh" });
    defer allocator.free(origin);
    try durable_store.writeTextAtomic(allocator, origin, "#!/bin/sh\nprintf launched > \"$4.launched\"\n");
    var executable_file = try std.Io.Dir.openFileAbsolute(defaultIo(), origin, .{});
    try executable_file.setPermissions(defaultIo(), .fromMode(0o500));
    executable_file.close(defaultIo());
    const binding = try bindExecutableInStoreAlloc(allocator, origin, executable_store);
    defer binding.deinit(allocator);
    const request = try std.fs.path.join(allocator, &.{ root, "request.json" });
    defer allocator.free(request);
    const result = try std.fs.path.join(allocator, &.{ root, "result.json" });
    defer allocator.free(result);
    const excessive_duration = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    try std.testing.expectError(
        error.ExecutionBudgetInvalid,
        runExecutorWithTempRootAndLimit(
            allocator,
            &binding,
            request,
            result,
            root,
            root,
            excessive_duration,
            8,
        ),
    );
    const launched = try std.fmt.allocPrint(allocator, "{s}.launched", .{result});
    defer allocator.free(launched);
    const stdout_path = try std.fmt.allocPrint(allocator, "{s}.stdout", .{result});
    defer allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(allocator, "{s}.stderr", .{result});
    defer allocator.free(stderr_path);
    try std.testing.expect(!pathExists(launched));
    try std.testing.expect(!pathExists(stdout_path));
    try std.testing.expect(!pathExists(stderr_path));
}

test "executor deadline kills and reaps a hung child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var script = try tmp.dir.createFile(std.testing.io, "hang.sh", .{ .read = true, .truncate = true });
    try script.writeStreamingAll(
        std.testing.io,
        "#!/bin/sh\n(sleep 0.2; echo survived > \"$4.late\") &\nsleep 5\n",
    );
    try script.setPermissions(std.testing.io, .fromMode(0o700));
    script.close(std.testing.io);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const executable = try tmp.dir.realPathFileAlloc(std.testing.io, "hang.sh", std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const request = try std.fs.path.join(std.testing.allocator, &.{ root, "request.json" });
    defer std.testing.allocator.free(request);
    const result = try std.fs.path.join(std.testing.allocator, &.{ root, "result.json" });
    defer std.testing.allocator.free(result);
    const before = std.Io.Clock.awake.now(defaultIo());
    try std.testing.expectError(
        error.ExecutorTimedOut,
        runExecutor(std.testing.allocator, executable, request, result, root, 25),
    );
    const elapsed = before.durationTo(std.Io.Clock.awake.now(defaultIo())).toMilliseconds();
    try std.testing.expect(elapsed < 2000);
    std.Io.sleep(std.testing.io, .fromMilliseconds(400), .awake) catch {};
    const late = try std.fmt.allocPrint(std.testing.allocator, "{s}.late", .{result});
    defer std.testing.allocator.free(late);
    try std.testing.expect(!pathExists(late));
}

test "zombie-only executor group is terminal after direct child reap" {
    var leader_ready_pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&leader_ready_pipe) != 0) return error.TestFdSetupFailed;
    var leader_release_pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&leader_release_pipe) != 0) {
        closeRawFd(leader_ready_pipe[0]);
        closeRawFd(leader_ready_pipe[1]);
        return error.TestFdSetupFailed;
    }

    const leader_pid = std.c.fork();
    if (leader_pid < 0) {
        closeRawFd(leader_ready_pipe[0]);
        closeRawFd(leader_ready_pipe[1]);
        closeRawFd(leader_release_pipe[0]);
        closeRawFd(leader_release_pipe[1]);
        return error.TestForkFailed;
    }
    if (leader_pid == 0) {
        _ = std.c.close(leader_ready_pipe[0]);
        _ = std.c.close(leader_release_pipe[1]);
        if (std.c.setpgid(0, 0) != 0) std.c._exit(91);
        var ready = [_]u8{1};
        if (std.c.write(leader_ready_pipe[1], &ready, ready.len) != ready.len) std.c._exit(92);
        _ = std.c.close(leader_ready_pipe[1]);
        if (std.c.read(leader_release_pipe[0], &ready, ready.len) != ready.len) std.c._exit(93);
        _ = std.c.close(leader_release_pipe[0]);
        std.c._exit(0);
    }

    closeRawFd(leader_ready_pipe[1]);
    closeRawFd(leader_release_pipe[0]);
    var leader_reaped = false;
    var zombie_pid: std.posix.pid_t = -1;
    var zombie_reaped = false;
    defer {
        if (leader_ready_pipe[0] >= 0) closeRawFd(leader_ready_pipe[0]);
        if (leader_release_pipe[1] >= 0) closeRawFd(leader_release_pipe[1]);
        if (!leader_reaped) {
            _ = std.posix.system.kill(-leader_pid, .KILL);
            _ = std.posix.system.kill(leader_pid, .KILL);
            var status: c_int = undefined;
            _ = std.posix.system.waitpid(leader_pid, &status, 0);
        }
        if (zombie_pid > 0 and !zombie_reaped) {
            var status: c_int = undefined;
            _ = std.posix.system.waitpid(zombie_pid, &status, 0);
        }
    }

    var ready: [1]u8 = undefined;
    if (std.c.read(leader_ready_pipe[0], &ready, ready.len) != ready.len) {
        return error.TestFdSetupFailed;
    }
    closeRawFd(leader_ready_pipe[0]);
    leader_ready_pipe[0] = -1;

    zombie_pid = std.c.fork();
    if (zombie_pid < 0) return error.TestForkFailed;
    if (zombie_pid == 0) {
        _ = std.c.close(leader_release_pipe[1]);
        if (std.c.setpgid(0, leader_pid) != 0) std.c._exit(94);
        std.c._exit(0);
    }

    // The zombie must first be observed in the leader's group; otherwise an
    // absent group could make the terminal observation vacuously pass.
    const zombie_deadline = std.Io.Clock.awake.now(defaultIo()).addDuration(.fromMilliseconds(1_000));
    var zombie_observed = false;
    while (!zombie_observed) {
        var process_info: DarwinProcessShortInfo = undefined;
        std.c._errno().* = 0;
        const info_size = proc_pidinfo(
            zombie_pid,
            DarwinProcessShortInfoFlavor,
            1,
            &process_info,
            @sizeOf(DarwinProcessShortInfo),
        );
        zombie_observed = info_size == @sizeOf(DarwinProcessShortInfo) and
            std.c._errno().* == 0 and
            process_info.process_group_id == @as(u32, @intCast(leader_pid)) and
            process_info.status == DarwinZombieProcessStatus;
        if (zombie_observed) break;
        if (std.Io.Clock.awake.now(defaultIo()).nanoseconds >= zombie_deadline.nanoseconds) {
            return error.TestZombieObservationFailed;
        }
        std.Io.sleep(defaultIo(), .fromMilliseconds(ExecutorPollIntervalMs), .awake) catch {};
    }
    try std.testing.expectEqual(
        ExecutorGroupObservation.live_members,
        try observeExecutorGroupAlloc(std.testing.allocator, leader_pid),
    );

    if (std.c.write(leader_release_pipe[1], &ready, ready.len) != ready.len) {
        return error.TestFdSetupFailed;
    }
    closeRawFd(leader_release_pipe[1]);
    leader_release_pipe[1] = -1;
    try waitExecutorChildReapedAndGroupQuiescent(std.testing.allocator, leader_pid);
    leader_reaped = true;
    try std.testing.expectEqual(
        ExecutorGroupObservation.terminal_zombies_only,
        try observeExecutorGroupAlloc(std.testing.allocator, leader_pid),
    );

    // Model the fork race from a shell executor: the initial KILL observes a
    // zombie-only group, then a same-session child joins that retained group.
    // The wait loop must re-KILL the late live member rather than merely watch
    // it until the deadline.
    try killExecutorGroup(leader_pid);
    var late_ready_pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&late_ready_pipe) != 0) return error.TestFdSetupFailed;
    const late_pid = std.c.fork();
    if (late_pid < 0) {
        closeRawFd(late_ready_pipe[0]);
        closeRawFd(late_ready_pipe[1]);
        return error.TestForkFailed;
    }
    if (late_pid == 0) {
        _ = std.c.close(late_ready_pipe[0]);
        if (std.c.setpgid(0, leader_pid) != 0) std.c._exit(95);
        if (std.c.write(late_ready_pipe[1], &ready, ready.len) != ready.len) std.c._exit(96);
        _ = std.c.close(late_ready_pipe[1]);
        const sleep_time = std.c.timespec{ .sec = 5, .nsec = 0 };
        _ = std.c.nanosleep(&sleep_time, null);
        std.c._exit(0);
    }
    closeRawFd(late_ready_pipe[1]);
    var late_reaped = false;
    defer if (!late_reaped) {
        _ = std.posix.system.kill(late_pid, .KILL);
        var status: c_int = undefined;
        _ = std.posix.system.waitpid(late_pid, &status, 0);
    };
    if (std.c.read(late_ready_pipe[0], &ready, ready.len) != ready.len) {
        closeRawFd(late_ready_pipe[0]);
        return error.TestFdSetupFailed;
    }
    closeRawFd(late_ready_pipe[0]);
    try std.testing.expectEqual(
        ExecutorGroupObservation.live_members,
        try observeExecutorGroupAlloc(std.testing.allocator, leader_pid),
    );
    try waitExecutorGroupQuiescent(std.testing.allocator, leader_pid);
    var late_status: c_int = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(late_pid, &late_status, 0))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.TestLateMemberReapFailed,
    };
    late_reaped = true;
    const encoded_late_status: u32 = @bitCast(late_status);
    try std.testing.expect(std.posix.W.IFSIGNALED(encoded_late_status));
    try std.testing.expectEqual(std.posix.SIG.KILL, std.posix.W.TERMSIG(encoded_late_status));
    try std.testing.expectEqual(
        ExecutorGroupObservation.terminal_zombies_only,
        try observeExecutorGroupAlloc(std.testing.allocator, leader_pid),
    );
    try proveResidualExecutorGroupQuiescent(std.testing.allocator, leader_pid);

    var zombie_status: c_int = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(zombie_pid, &zombie_status, 0))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.TestZombieReapFailed,
    };
    zombie_reaped = true;
    try std.testing.expectEqual(
        ExecutorGroupObservation.absent,
        try observeExecutorGroupAlloc(std.testing.allocator, leader_pid),
    );
}

test "advisory group STOP permission failure skips census and still proves kill reap and absence" {
    var ready_pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&ready_pipe) != 0) return error.TestFdSetupFailed;
    const child_pid = std.c.fork();
    if (child_pid < 0) {
        closeRawFd(ready_pipe[0]);
        closeRawFd(ready_pipe[1]);
        return error.TestForkFailed;
    }
    if (child_pid == 0) {
        _ = std.c.close(ready_pipe[0]);
        if (std.c.setpgid(0, 0) != 0) std.c._exit(91);
        var ready = [_]u8{1};
        if (std.c.write(ready_pipe[1], &ready, ready.len) != ready.len) std.c._exit(92);
        _ = std.c.close(ready_pipe[1]);
        const sleep_time = std.c.timespec{ .sec = 5, .nsec = 0 };
        _ = std.c.nanosleep(&sleep_time, null);
        std.c._exit(0);
    }

    closeRawFd(ready_pipe[1]);
    var termination_complete = false;
    defer if (!termination_complete) {
        _ = std.posix.system.kill(-child_pid, .KILL);
        _ = std.posix.system.kill(child_pid, .KILL);
        var status: c_int = undefined;
        while (true) switch (std.posix.errno(std.posix.system.waitpid(child_pid, &status, 0))) {
            .SUCCESS, .CHILD => break,
            .INTR => continue,
            else => break,
        };
    };
    var ready: [1]u8 = undefined;
    if (std.c.read(ready_pipe[0], &ready, ready.len) != ready.len) {
        closeRawFd(ready_pipe[0]);
        return error.TestFdSetupFailed;
    }
    closeRawFd(ready_pipe[0]);

    var termination_probe: ExecutorTerminationProbe = .{};
    try terminateAndReapExecutorGroupWithFault(
        std.testing.allocator,
        child_pid,
        .group_stop_permission_denied,
        &termination_probe,
    );
    termination_complete = true;
    try std.testing.expect(!termination_probe.descendant_census_attempted);
    var status: c_int = undefined;
    try std.testing.expectEqual(
        std.posix.E.CHILD,
        std.posix.errno(std.posix.system.waitpid(child_pid, &status, std.posix.W.NOHANG)),
    );
    try std.testing.expectEqual(
        std.posix.E.SRCH,
        std.posix.errno(std.c.kill(-child_pid, @enumFromInt(0))),
    );
}

test "nonzero executor preserves the directly supervised terminal observation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var script = try tmp.dir.createFile(std.testing.io, "fail-with-child.sh", .{ .read = true, .truncate = true });
    try script.writeStreamingAll(
        std.testing.io,
        "#!/bin/sh\nexit 7\n",
    );
    try script.setPermissions(std.testing.io, .fromMode(0o700));
    script.close(std.testing.io);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const executable = try tmp.dir.realPathFileAlloc(std.testing.io, "fail-with-child.sh", std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const request = try std.fs.path.join(std.testing.allocator, &.{ root, "request.json" });
    defer std.testing.allocator.free(request);
    const result = try std.fs.path.join(std.testing.allocator, &.{ root, "result.json" });
    defer std.testing.allocator.free(result);
    const execution = try runExecutor(std.testing.allocator, executable, request, result, root, 1_000);
    defer std.testing.allocator.free(execution.stdout);
    defer std.testing.allocator.free(execution.stderr);
    try std.testing.expectEqual(@as(u8, 7), execution.exit_code);
    try std.testing.expectEqual(ExecutorTermination.exited, execution.termination);
}

test "claimed executor timeout persists one signed aborted receipt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var script = try tmp.dir.createFile(std.testing.io, "hang.sh", .{ .read = true, .truncate = true });
    try script.writeStreamingAll(std.testing.io, "#!/bin/sh\nsleep 5\n");
    try script.setPermissions(std.testing.io, .fromMode(0o700));
    script.close(std.testing.io);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const executor = try tmp.dir.realPathFileAlloc(std.testing.io, "hang.sh", allocator);
    defer allocator.free(executor);
    const raw_lease = "HYL1-timeout-secret";
    const ledger = try writeMockLaneMaterializationLedgerAlloc(allocator, root, raw_lease);
    defer allocator.free(ledger);
    const bound = try bindTestRunnerContractAlloc(allocator, hctp_fixtures.valid_null_trial, executor, ledger);
    defer allocator.free(bound);
    const bounded = try std.mem.replaceOwned(
        u8,
        allocator,
        bound,
        "\"maximum_lane_duration_ms\": 1800000",
        "\"maximum_lane_duration_ms\": 25",
    );
    defer allocator.free(bounded);
    const seed = [_]u8{0x62} ** 32;
    const trial = try receiptBoundTestTrialAlloc(allocator, bounded, seed, executor, ledger);
    defer allocator.free(trial);
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    defer allocator.free(trial_path);
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    const lease_path = try std.fs.path.join(allocator, &.{ root, "lease" });
    defer allocator.free(lease_path);
    const input_path = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(input_path);
    const seed_path = try std.fs.path.join(allocator, &.{ root, "seed" });
    defer allocator.free(seed_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    try writeMockTrialFingerprint(allocator, root, trial);
    try durable_store.writeTextAtomic(allocator, lease_path, raw_lease);
    const input = "{\"request\":\"bounded\"}";
    try durable_store.writeTextAtomic(allocator, input_path, input);
    try durable_store.writeTextAtomic(allocator, seed_path, &seed);
    const input_fingerprint = try attestation.digestBytesAlloc(allocator, input);
    defer allocator.free(input_fingerprint);
    try writeMockInputFingerprint(allocator, root, input_fingerprint);
    const lease_fd = try testPipeWithBytes(raw_lease);
    const input_fd = try testPipeWithBytes(input);
    const seed_fd = try testPipeWithBytes(&seed);
    try cmdRun(allocator, testRunFailureOptions(
        trial_path,
        receipt_dir,
        executor,
        ledger,
        lease_fd,
        input_fd,
        input_fingerprint,
        seed_fd,
        root,
    ));
    const paths = try lanePathsAlloc(allocator, receipt_dir, root, "trial-null-001", "lane-null-a0");
    defer paths.deinit(allocator);
    const receipt = try readFileAlloc(allocator, paths.receipt, MaxInputBytes);
    defer allocator.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{});
    defer parsed.deinit();
    const terminal = try requiredObject(try object(parsed.value), "terminal");
    try std.testing.expectEqualStrings("aborted", try requiredString(terminal, "status"));
    try std.testing.expectEqualStrings("executor_deadline_exceeded", try requiredString(terminal, "failure_class"));
    const receipt_attestation = try object((try object(parsed.value)).get("attestation") orelse return error.AttestationMissing);
    try std.testing.expectEqualStrings("runner", try requiredString(receipt_attestation, "role"));
}

test "authoritative claim store derives from runner identity rather than HOME" {
    const original_home = try std.testing.allocator.dupeZ(
        u8,
        std.Io.Threaded.global_single_threaded.environString("HOME") orelse return error.HomeMissing,
    );
    defer std.testing.allocator.free(original_home);
    defer _ = setenv("HOME", original_home.ptr, 1);
    try std.testing.expectEqual(@as(c_int, 0), setenv("HOME", "/tmp/home-a", 1));
    const root_a = try authoritativeClaimStoreAlloc(std.testing.allocator);
    defer std.testing.allocator.free(root_a);
    try std.testing.expectEqual(@as(c_int, 0), setenv("HOME", "/tmp/home-b", 1));
    const root_b = try authoritativeClaimStoreAlloc(std.testing.allocator);
    defer std.testing.allocator.free(root_b);
    try std.testing.expectEqualStrings(root_a, root_b);
    const lane_root_a = try std.fs.path.join(std.testing.allocator, &.{ root_a, "trial-home-proof", "lane-home-proof" });
    defer std.testing.allocator.free(lane_root_a);
    const lane_root_b = try std.fs.path.join(std.testing.allocator, &.{ root_b, "trial-home-proof", "lane-home-proof" });
    defer std.testing.allocator.free(lane_root_b);
    const registration_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const claim_a = try claimPathAlloc(std.testing.allocator, lane_root_a, registration_digest);
    defer std.testing.allocator.free(claim_a);
    const claim_b = try claimPathAlloc(std.testing.allocator, lane_root_b, registration_digest);
    defer std.testing.allocator.free(claim_b);
    try std.testing.expectEqualStrings(claim_a, claim_b);
    try std.testing.expect(std.fs.path.isAbsolute(root_a));
    try std.testing.expect(!std.mem.startsWith(u8, root_a, "/tmp/home-a/"));
    try std.testing.expect(!std.mem.startsWith(u8, root_a, "/tmp/home-b/"));
    try std.testing.expect(std.mem.endsWith(u8, root_a, "/.codex/cas/hctp-claims-v1"));
}
