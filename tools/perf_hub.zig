const std = @import("std");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const core_perf = @import("core_perf");
const cas_automation_cli = @import("cas_automation_cli");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const perf_contract = @import("perf_contract");

const Version = "0.0.0-dev";
const paired_comparison_rounds: usize = 8;
const DriverSourceIdentity = struct {
    revision: []const u8,
    tree: []const u8,
    locator: []const u8,
    sha256: []const u8,
};
const DriverKind = enum { seq_replay, optimization };
const seq_replay_driver_source = @embedFile("seq_replay_driver.zig");
const seq_replay_driver_sha256 = comptimeDigest(seq_replay_driver_source);
const seq_replay_driver_locator = "tools/seq_replay_driver.zig";
const seq_replay_driver_tree_sha256 = seqReplayDriverTreeDigest();
const active_seq_replay_driver_v2 = DriverSourceIdentity{
    .revision = &seq_replay_driver_sha256,
    .tree = &seq_replay_driver_tree_sha256,
    .locator = seq_replay_driver_locator,
    .sha256 = &seq_replay_driver_sha256,
};

// Readback-only identity from the driver before sort-once summaries.
const legacy_seq_replay_driver_v2 = DriverSourceIdentity{
    .revision = "d9424914631366021224bffd105cc5f3ac62b35a6487b9198dd383fff27a73de",
    .tree = "2e85cc190900f3d3cfb9cc1e76ef6f8c901fe998823e08788ca259a7b2d89426",
    .locator = "tools/seq_replay_driver.zig",
    .sha256 = "d9424914631366021224bffd105cc5f3ac62b35a6487b9198dd383fff27a73de",
};

// Readback-only identity after summary optimization, before explicit I/O.
const legacy_summary_seq_replay_driver_v2 = DriverSourceIdentity{
    .revision = "d1095289a81312b2a0416933338ec43546958db683afa2c0bac8d5770d44495d",
    .tree = "db995f54f027506b001468b9734ae6d2fcb30f739cd63e422c8bc42b4c9997cc",
    .locator = "tools/seq_replay_driver.zig",
    .sha256 = "d1095289a81312b2a0416933338ec43546958db683afa2c0bac8d5770d44495d",
};

fn seqReplayDriverTreeDigest() [64]u8 {
    @setEvalBranchQuota(4_000_000);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("seq-replay-driver-tree/v2\x00");
    hasher.update(seq_replay_driver_locator);
    hasher.update("\x00");
    hasher.update(&seq_replay_driver_sha256);
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

const optimization_driver_source = @embedFile("optimization_driver.zig");
const optimization_build_source =
    \\pub fn build(b: *std.Build) void {
    \\    @import("build_product.zig").build(b);
    \\    addOptimizationDriver(b);
    \\}
    \\
++ @embedFile("optimization_build.zig");
const optimization_driver_sha256 = comptimeDigest(optimization_driver_source);
const optimization_build_sha256 = comptimeDigest(optimization_build_source);
const optimization_source_tree_sha256 = optimizationSourceTreeDigest();
const active_optimization_driver_v1 = DriverSourceIdentity{
    .revision = &optimization_driver_sha256,
    .tree = &optimization_source_tree_sha256,
    .locator = "tools/optimization_driver.zig",
    .sha256 = &optimization_driver_sha256,
};
// Readback-only identity from the driver before sort-once summaries.
const legacy_optimization_summary_driver_v1 = DriverSourceIdentity{
    .revision = "6f6bd121d3da945cefec99f0c90b7424c9a4c10c2643d4d4962834f7e2e33775",
    .tree = "1ce85c7567b3c4df5eca4ae9137158cd911adc15de222eedb7524fd87de53f95",
    .locator = "tools/optimization_driver.zig",
    .sha256 = "6f6bd121d3da945cefec99f0c90b7424c9a4c10c2643d4d4962834f7e2e33775",
};
const legacy_optimization_summary_build_sha256 =
    "6b2f3185ac7b80960fb6740a9aa1fbccef9db68385be56a97c80bfd830e79458";

// Readback-only identity after summary optimization, before explicit I/O.
const legacy_summary_optimization_driver_v1 = DriverSourceIdentity{
    .revision = "8678cf4213ac4ea434998bfc5386f9a4258f24f22a3c8a4d9983c7928748a52a",
    .tree = "3f3a0ff9fa83a0d5660b78bdd6e4c1ad1bbcda1e86edcd92fe0bb8a56439937f",
    .locator = "tools/optimization_driver.zig",
    .sha256 = "8678cf4213ac4ea434998bfc5386f9a4258f24f22a3c8a4d9983c7928748a52a",
};

// Readback-only identity from the pre-migration source at 9c4a5584608e23cfe3b5c125b9b1e1df38b53aa2.
const legacy_optimization_driver_v1 = DriverSourceIdentity{
    .revision = "5ba1b03b38b1bc72f7735931324f75679af43907d01338bb7c017b9b1f060925",
    .tree = "4eb77ac0c61b57e3d739be6a1d9a5a2f023e28855f06fd78eac94c0a4e9ba9dd",
    .locator = "tools/optimization_driver.zig",
    .sha256 = "5ba1b03b38b1bc72f7735931324f75679af43907d01338bb7c017b9b1f060925",
};
const legacy_optimization_build_sha256 =
    "5eaae873185f3f472269a7dcc1d2c41c61f56fbfbc13542f941acc98ef082769";

fn comptimeDigest(comptime source: []const u8) [64]u8 {
    @setEvalBranchQuota(4_000_000);
    return evidenceDigest(source);
}

fn optimizationSourceTreeDigest() [64]u8 {
    @setEvalBranchQuota(4_000_000);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("performance-optimization-source/v1\x00");
    hasher.update(&optimization_driver_sha256);
    hasher.update("\x00");
    hasher.update(&optimization_build_sha256);
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

fn driverIdentity(kind: DriverKind) DriverSourceIdentity {
    return switch (kind) {
        .seq_replay => active_seq_replay_driver_v2,
        .optimization => active_optimization_driver_v1,
    };
}

fn driverSourceBytes(kind: DriverKind) []const u8 {
    return switch (kind) {
        .seq_replay => seq_replay_driver_source,
        .optimization => optimization_driver_source,
    };
}

fn driverKindForCase(descriptor: perf_contract.CaseDescriptor) DriverKind {
    return if (std.mem.eql(u8, descriptor.family, "optimization")) .optimization else .seq_replay;
}

const driver_overlay_path = "tools/perf_hub.zig";
const legacy_generic_driver_v1 = DriverSourceIdentity{
    .revision = "ddf201901391ea625e4ac9b0c9649570bc56e58f",
    .tree = "59fcca22a691bbc98a4e38e50c6d642116611b43",
    .locator = driver_overlay_path,
    .sha256 = "0be169c43deebf30f95954b63d334d4e66bde47e0f4a503e4f6b1ac8e5b15a5f",
};
const sealed_seq_replay_driver_locator =
    "tools/perf_hub.zig#sealed_seq_replay_driver_source";
const sealed_seq_replay_driver_sha256 =
    "e5d06b290c19f23af281213ba04b43c7c68962b0906b4c1658c981e624b24053";
const legacy_seq_replay_driver_v1 = DriverSourceIdentity{
    .revision = sealed_seq_replay_driver_sha256,
    .tree = "118e358ab6c6b74bded7dc77d3932c9b8b289a83904604e82e8221109458fe9b",
    .locator = sealed_seq_replay_driver_locator,
    .sha256 = sealed_seq_replay_driver_sha256,
};
const sealed_seq_replay_driver_source =
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\const core_perf = @import("core_perf");
    \\const definition_core = @import("definition_core");
    \\const seq_v1 = @import("seq_v1_core");
    \\
    \\const case_id = "seq-observe-deep-batch8";
    \\const binary = "seq";
    \\const warmup_count: usize = 3;
    \\const sample_count: usize = 30;
    \\const batch_iterations: usize = 8;
    \\
    \\const Metrics = struct {
    \\    samples_ns: [sample_count]u64,
    \\    p50_ns: u64,
    \\    p95_ns: u64,
    \\    p50_alloc_calls: u64,
    \\};
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    const allocator = init.gpa;
    \\    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    \\    try requireCaptureArgs(argv);
    \\    const metrics = try measure(allocator);
    \\    try writeArtifact(allocator, metrics);
    \\
    \\    var stdout_writer = std.Io.File.stdout().writer(
    \\        std.Io.Threaded.global_single_threaded.io(),
    \\        &.{},
    \\    );
    \\    try stdout_writer.interface.print(
    \\        "PASS\t{s}\tcaptured\n",
    \\        .{case_id},
    \\    );
    \\}
    \\
    \\fn requireCaptureArgs(argv: []const []const u8) !void {
    \\    if (argv.len != 4 or
    \\        !std.mem.eql(u8, argv[1], "capture") or
    \\        !std.mem.eql(u8, argv[2], "--target") or
    \\        !std.mem.eql(u8, argv[3], case_id))
    \\    {
    \\        return error.InvalidCommand;
    \\    }
    \\}
    \\
    \\fn measure(allocator: std.mem.Allocator) !Metrics {
    \\    var warmup_index: usize = 0;
    \\    while (warmup_index < warmup_count) : (warmup_index += 1) {
    \\        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    \\        defer arena.deinit();
    \\        var counting = core_perf.CountingAllocator.init(arena.allocator());
    \\        try executeBatch(counting.allocator());
    \\    }
    \\
    \\    var samples_ns: [sample_count]u64 = undefined;
    \\    var allocation_calls: [sample_count]u64 = undefined;
    \\    for (0..sample_count) |sample_index| {
    \\        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    \\        defer arena.deinit();
    \\        var counting = core_perf.CountingAllocator.init(arena.allocator());
    \\        const start_ns = std.Io.Clock.awake.now(
    \\            std.Io.Threaded.global_single_threaded.io(),
    \\        ).nanoseconds;
    \\        try executeBatch(counting.allocator());
    \\        samples_ns[sample_index] = @intCast(@max(
    \\            std.Io.Clock.awake.now(
    \\                std.Io.Threaded.global_single_threaded.io(),
    \\            ).nanoseconds - start_ns,
    \\            1,
    \\        ));
    \\        allocation_calls[sample_index] = counting.stats.totalCalls();
    \\    }
    \\
    \\    _ = allocator;
    \\    return .{
    \\        .samples_ns = samples_ns,
    \\        .p50_ns = percentile(samples_ns, 50),
    \\        .p95_ns = percentile(samples_ns, 95),
    \\        .p50_alloc_calls = percentile(allocation_calls, 50),
    \\    };
    \\}
    \\
    \\fn percentile(values: [sample_count]u64, percent: usize) u64 {
    \\    var sorted = values;
    \\    std.mem.sort(u64, sorted[0..], {}, struct {
    \\        fn less(_: void, left: u64, right: u64) bool {
    \\            return left < right;
    \\        }
    \\    }.less);
    \\    return sorted[((sorted.len - 1) * percent) / 100];
    \\}
    \\
    \\fn executeBatch(allocator: std.mem.Allocator) !void {
    \\    for (0..batch_iterations) |_| try executeSeqObserve(allocator);
    \\}
    \\
    \\fn executeSeqObserve(allocator: std.mem.Allocator) !void {
    \\    const cwd = try std.process.currentPathAlloc(
    \\        std.Io.Threaded.global_single_threaded.io(),
    \\        allocator,
    \\    );
    \\    defer allocator.free(cwd);
    \\    const definition_root = try std.fs.path.join(
    \\        allocator,
    \\        &.{ cwd, "apps/seq/src/v1/fixtures" },
    \\    );
    \\    defer allocator.free(definition_root);
    \\    const projection_names = [_][]const u8{"rows"};
    \\    var plans = try seq_v1.compiled_plan.load(
    \\        allocator,
    \\        definition_root,
    \\        "message-observation.json",
    \\        .{ .projection_names = &projection_names },
    \\        "1.0.0",
    \\        "seq-source-adapter/v1",
    \\        .{},
    \\    );
    \\    defer plans.deinit(allocator);
    \\    const parameter_inputs = [_]definition_core.parameters.Input{.{
    \\        .name = "needle",
    \\        .raw_value = "failure",
    \\    }};
    \\    var parameters = try definition_core.parameters.bind(
    \\        allocator,
    \\        &plans.definition_plan.parameter_declarations,
    \\        &parameter_inputs,
    \\    );
    \\    defer parameters.deinit(allocator);
    \\    var program = try seq_v1.execution.compile(
    \\        allocator,
    \\        &plans.definition_plan,
    \\        &plans.native_plan,
    \\        &parameters,
    \\        "rows",
    \\    );
    \\    defer program.deinit(allocator);
    \\    const output_cells = try std.math.mul(
    \\        usize,
    \\        program.max_rows,
    \\        program.output_field_indices.len,
    \\    );
    \\    const output = try allocator.alloc(seq_v1.execution.Value, output_cells);
    \\    defer allocator.free(output);
    \\    const trace_path = try std.fs.path.join(
    \\        allocator,
    \\        &.{ definition_root, "rollout.jsonl" },
    \\    );
    \\    defer allocator.free(trace_path);
    \\    var observation = try seq_v1.trace_adapter.observeFile(
    \\        allocator,
    \\        &program,
    \\        trace_path,
    \\        .{
    \\            .max_input_bytes = plans.definition_plan.bounds.max_input_bytes,
    \\        },
    \\        output,
    \\    );
    \\    defer observation.deinit(allocator);
    \\    if (observation.result.row_count != 1 or
    \\        observation.metrics.bytes_read == 0)
    \\    {
    \\        return error.InvalidPerfObservation;
    \\    }
    \\}
    \\
    \\fn writeArtifact(allocator: std.mem.Allocator, metrics: Metrics) !void {
    \\    const machine_name = try currentMachineDirName(allocator);
    \\    defer allocator.free(machine_name);
    \\    const baseline_dir = try std.fs.path.join(
    \\        allocator,
    \\        &.{ ".perf-local", machine_name, "baselines", binary },
    \\    );
    \\    defer allocator.free(baseline_dir);
    \\    try std.Io.Dir.cwd().createDirPath(
    \\        std.Io.Threaded.global_single_threaded.io(),
    \\        baseline_dir,
    \\    );
    \\    const artifact_name = case_id ++ ".json";
    \\    const artifact_path = try std.fs.path.join(
    \\        allocator,
    \\        &.{ baseline_dir, artifact_name },
    \\    );
    \\    defer allocator.free(artifact_path);
    \\
    \\    var output: std.Io.Writer.Allocating = .init(allocator);
    \\    defer output.deinit();
    \\    const writer = &output.writer;
    \\    try writer.print(
    \\        "{{\"schema_version\":1,\"machine_id\":\"{s}\"," ++
    \\            "\"git_sha\":\"unknown\",\"zig_version\":\"{s}\"," ++
    \\            "\"binary\":\"{s}\",\"case_id\":\"{s}\"," ++
    \\            "\"case_kind\":\"native\",\"tolerance_pct\":3.00," ++
    \\            "\"metrics\":{{\"samples_ns\":[",
    \\        .{ machine_name, builtin.zig_version_string, binary, case_id },
    \\    );
    \\    for (metrics.samples_ns, 0..) |sample, index| {
    \\        if (index > 0) try writer.writeByte(',');
    \\        try writer.print("{d}", .{sample});
    \\    }
    \\    try writer.print(
    \\        "],\"p50_ns\":{d},\"p95_ns\":{d}," ++
    \\            "\"p50_alloc_calls\":{d}}}," ++
    \\            "\"compare_status\":\"capture\"," ++
    \\            "\"compare_detail\":\"captured\"}}\n",
    \\        .{ metrics.p50_ns, metrics.p95_ns, metrics.p50_alloc_calls },
    \\    );
    \\    try std.Io.Dir.cwd().writeFile(
    \\        std.Io.Threaded.global_single_threaded.io(),
    \\        .{ .sub_path = artifact_path, .data = output.written() },
    \\    );
    \\}
    \\
    \\fn currentMachineDirName(allocator: std.mem.Allocator) ![]u8 {
    \\    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    \\    const host_full = try std.posix.gethostname(&host_buf);
    \\    const host = host_full[0 .. std.mem.indexOfScalar(u8, host_full, '.') orelse
    \\        host_full.len];
    \\    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-zig{s}", .{
    \\        switch (builtin.target.os.tag) {
    \\            .macos => "darwin",
    \\            else => @tagName(builtin.target.os.tag),
    \\        },
    \\        switch (builtin.target.cpu.arch) {
    \\            .aarch64 => "arm64",
    \\            else => @tagName(builtin.target.cpu.arch),
    \\        },
    \\        host,
    \\        builtin.zig_version_string,
    \\    });
    \\}
;

fn sealedSeqReplayDriverDigest() [64]u8 {
    return evidenceDigest(sealed_seq_replay_driver_source);
}

fn sealedSeqReplayDriverTreeDigest() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("cas-sealed-seq-replay-driver-tree/v1");
    hasher.update(&.{0});
    hasher.update(sealed_seq_replay_driver_locator);
    hasher.update(&.{0});
    hasher.update(sealed_seq_replay_driver_sha256);
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}
const deep_measurement_schema = "perf-deep-measurement/v1";
const deep_comparison_method = "balanced-round-median-ratio/v1";
const ratio_scale: u64 = 1_000_000;
const resource_tolerance_pct: f64 = 2.0;
const git_binary = "/usr/bin/git";
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "perf_hub",
    .help_text = UsageText,
};
const UsageText =
    \\perf_hub
    \\
    \\Native control plane for local perf evidence.
    \\
    \\Usage:
    \\  perf_hub <command> [options]
    \\
    \\Commands:
    \\  list                  List known perf cases
    \\  manifest              Emit the native perf manifest as JSON
    \\  audit                 Print coverage audit summary
    \\  compare               Run a sealed paired comparison
    \\  doctor                Validate native local perf setup
    \\  report                Verify and summarize the current capsule
    \\
    \\Options:
    \\  --target TEXT         Filter by binary/case substring where supported
    \\  --help                Show help
    \\  --version             Show version
    \\  version               Show version
    \\
    \\Base-binary overrides:
    \\  PERF_SEQ_BINARY       Candidate Seq binary
    \\  PERF_LEDGER_BINARY    Candidate Ledger binary
    \\  PERF_SEQ_BASE_BINARY  Pair this Seq base binary with the candidate
    \\  PERF_LEDGER_BASE_BINARY
    \\                        Pair this Ledger base binary with the candidate
    \\  PERF_EXPECT_BASE_SHA  Required baseline SHA for compare/report
    \\  PERF_EXPECT_CANDIDATE_SHA
    \\                        Required candidate SHA for compare/report
    \\  PERF_ZIG_BINARY       Approved absolute Zig compiler for paired drivers
;

const Command = enum {
    list,
    manifest,
    audit,
    compare,
    doctor,
    report,
};

const CompatBuilder = enum {
    root,
};

const CompatSetup = enum {
    seq_definition_check,
    seq_observe,
    seq_sessions,
    seq_query,
    ledger_definition_check,
    ledger_validate,
    ledger_materialize,
    ledger_transact,
    ledger_project,
    ledger_doctor,
    bench_stats_help,
    bench_stats_parse,
    cas_wrapper_smoke,
    cas_smoke_check_help,
    cas_instance_runner_help,
    cas_review_session_help,
    cas_review_session_version,
    cas_automation_help,
    cas_automation_list,
};

const CompatCase = struct {
    descriptor: perf_contract.CaseDescriptor,
    builder: CompatBuilder,
    build_step: ?[]const u8,
    binary_path: []const u8,
    setup: CompatSetup,
    warmups: usize = 1,
    samples: usize = 5,
    tolerance_pct: f64 = 15.0,
    require_streamed_projection: bool = false,
};

const DeepSetup = enum {
    optimization,
    seq_observe,
    cas_automation_show,
    cas_automation_create,
    cas_automation_update,
    cas_automation_enable,
    cas_automation_disable,
    cas_automation_run_now,
    cas_automation_delete,
    cas_automation_run_due,
};

const DeepCase = struct {
    driver_kind: DriverKind = .seq_replay,
    primary_optimization: bool = false,
    descriptor: perf_contract.CaseDescriptor,
    setup: DeepSetup,
    tolerance_pct: f64 = 20.0,
    warmups: usize = 1,
    samples: usize = 5,
    batch_iterations: usize = 1,
};

fn latencyCase(
    case_id: []const u8,
    binary: []const u8,
    family: []const u8,
) perf_contract.CaseDescriptor {
    return .{
        .case_id = case_id,
        .binary = binary,
        .family = family,
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
    };
}

fn shallowCoverage(
    family: []const u8,
    reason: []const u8,
) perf_contract.CommandCoverage {
    return .{ .family = family, .coverage = .shallow, .reason = reason };
}

fn rootCompat(
    descriptor: perf_contract.CaseDescriptor,
    build_step: []const u8,
    binary_path: []const u8,
    setup: CompatSetup,
) CompatCase {
    return rootCompatSamples(
        descriptor,
        build_step,
        binary_path,
        setup,
        100,
    );
}

fn rootCompatSamples(
    descriptor: perf_contract.CaseDescriptor,
    build_step: []const u8,
    binary_path: []const u8,
    setup: CompatSetup,
    samples: usize,
) CompatCase {
    return .{
        .descriptor = descriptor,
        .builder = .root,
        .build_step = build_step,
        .binary_path = binary_path,
        .setup = setup,
        .warmups = 3,
        .samples = samples,
        .tolerance_pct = 5.0,
    };
}

fn rootStreamingProject(
    descriptor: perf_contract.CaseDescriptor,
) CompatCase {
    var result = rootCompat(
        descriptor,
        "build-ledger",
        "zig-out/bin/ledger",
        .ledger_project,
    );
    result.require_streamed_projection = true;
    return result;
}

const SeqCases = [_]perf_contract.CaseDescriptor{
    latencyCase("seq-definition-check", "seq", "definition"),
    latencyCase("seq-observe", "seq", "observe"),
    latencyCase("seq-sessions", "seq", "sessions"),
    latencyCase("seq-query", "seq", "query"),
    .{
        .case_id = "seq-observe-deep-batch8",
        .binary = "seq",
        .family = "observe",
        .case_kind = .native,
        .measurement_mode = .latency_alloc,
    },
};

const SeqCoverages = [_]perf_contract.CommandCoverage{
    shallowCoverage("definition", "definition compilation case"),
    .{
        .family = "observe",
        .coverage = .deep,
        .reason = "native compiled-plan plus physical trace execution case",
    },
    .{
        .family = "explain",
        .coverage = .deep,
        .reason = "shares the measured definition compiler",
    },
    shallowCoverage("sessions", "physical corpus case"),
    shallowCoverage("turns", "physical trace case"),
    shallowCoverage("session-detail", "physical trace case"),
    shallowCoverage("tool-lifecycle", "physical trace case"),
    shallowCoverage("session-graph", "physical trace case"),
    shallowCoverage("tail", "physical trace case"),
    shallowCoverage("find-session", "physical corpus case"),
    shallowCoverage("datasets", "static physical catalog"),
    shallowCoverage("dataset-schema", "static physical catalog"),
    shallowCoverage("query", "generic query case"),
    shallowCoverage("index", "physical index smoke lane"),
    shallowCoverage("capabilities", "command-surface gate"),
    shallowCoverage("version", "command-surface gate"),
};
const SeqDatasets = [_]perf_contract.DataSurface{
    .{ .name = "sessions", .coverage = .shallow, .reason = "physical corpus case" },
    .{ .name = "turns", .coverage = .shallow, .reason = "physical trace case" },
    .{ .name = "messages", .coverage = .shallow, .reason = "compiled observation case" },
    .{
        .name = "structured_values",
        .coverage = .shallow,
        .reason = "generic structured evidence lane",
    },
};

const LedgerCases = [_]perf_contract.CaseDescriptor{
    latencyCase("ledger-definition-check", "ledger", "definition"),
    latencyCase("ledger-validate", "ledger", "validate"),
    latencyCase("ledger-materialize", "ledger", "materialize"),
    latencyCase("ledger-transact", "ledger", "transact"),
    latencyCase("ledger-project", "ledger", "project"),
    latencyCase("ledger-doctor", "ledger", "doctor"),
};
const ledger_perf_record_count: usize = 16_384;
const ledger_perf_max_records: usize = 32_768;
const ledger_perf_max_store_bytes: usize = 8 * 1024 * 1024;
const seq_perf_corpus =
    "{\"timestamp\":\"2026-07-26T10:00:00Z\",\"type\":\"session_meta\"," ++
    "\"payload\":{\"id\":\"fixture-session\",\"model\":\"gpt-test\"," ++
    "\"cwd\":\"/repo\"}}\n" ++
    "{\"timestamp\":\"2026-07-26T10:00:01Z\",\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-1\"}}\n" ++
    "{\"timestamp\":\"2026-07-26T10:00:02Z\",\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"agent_message\"," ++
    "\"message\":\"Observed FAILURE evidence\"}}\n" ++
    "{\"timestamp\":\"2026-07-26T10:00:03Z\",\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-1\"}}\n";

const LedgerCoverages = [_]perf_contract.CommandCoverage{
    shallowCoverage("definition", "definition compilation case"),
    shallowCoverage("validate", "compiled validation case"),
    shallowCoverage("materialize", "canonicalization and identity case"),
    shallowCoverage("transact", "measured ReleaseFast append transaction case"),
    shallowCoverage("project", "measured ReleaseFast streaming projection case"),
    shallowCoverage("doctor", "measured ReleaseFast streaming replay case"),
    shallowCoverage("capabilities", "command-surface gate"),
    shallowCoverage("version", "command-surface gate"),
};

const CasAutomationCases = [_]perf_contract.CaseDescriptor{
    .{
        .case_id = "cas-automation-help",
        .binary = "cas",
        .family = "help",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
    .{
        .case_id = "cas-automation-list",
        .binary = "cas",
        .family = "list",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
    .{
        .case_id = "cas-automation-show-deep",
        .binary = "cas",
        .family = "show",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    },
    .{
        .case_id = "cas-automation-create-deep",
        .binary = "cas",
        .family = "create",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    },
    .{
        .case_id = "cas-automation-update-deep",
        .binary = "cas",
        .family = "update",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    },
    .{
        .case_id = "cas-automation-enable-deep",
        .binary = "cas",
        .family = "enable",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    },
    .{
        .case_id = "cas-automation-disable-deep",
        .binary = "cas",
        .family = "disable",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    },
    .{
        .case_id = "cas-automation-run-now-deep",
        .binary = "cas",
        .family = "run-now",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    },
    .{
        .case_id = "cas-automation-delete-deep",
        .binary = "cas",
        .family = "delete",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    },
    .{
        .case_id = "cas-automation-run-due-deep",
        .binary = "cas",
        .family = "run-due",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    },
};

const CasAutomationCoverages = buildCasAutomationCoverages();

const MiscCases = [_]perf_contract.CaseDescriptor{
    .{
        .case_id = "bench-stats-help",
        .binary = "bench_stats",
        .family = "help",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
    .{
        .case_id = "bench-stats-parse",
        .binary = "bench_stats",
        .family = "parse",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
    .{
        .case_id = "cas-wrapper-smoke",
        .binary = "cas",
        .family = "wrapper",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
    .{
        .case_id = "cas-smoke-check-help",
        .binary = "cas_smoke_check",
        .family = "help",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
    .{
        .case_id = "cas-instance-runner-help",
        .binary = "cas_instance_runner",
        .family = "help",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
    .{
        .case_id = "cas-review-session-help",
        .binary = "cas_review_session",
        .family = "help",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
    .{
        .case_id = "cas-review-session-version",
        .binary = "cas_review_session",
        .family = "version",
        .case_kind = .subprocess,
        .measurement_mode = .latency_only,
        .compat_case = true,
    },
};

const MiscCoverages = [_]perf_contract.CommandCoverage{
    .{
        .family = "utilities",
        .coverage = .shallow,
        .reason = "current utility matrix",
    },
};

const CompatCases = [_]CompatCase{
    rootCompat(
        SeqCases[0],
        "build-seq",
        "zig-out/bin/seq",
        .seq_definition_check,
    ),
    rootCompat(SeqCases[1], "build-seq", "zig-out/bin/seq", .seq_observe),
    rootCompat(SeqCases[2], "build-seq", "zig-out/bin/seq", .seq_sessions),
    rootCompat(SeqCases[3], "build-seq", "zig-out/bin/seq", .seq_query),
    rootCompat(
        LedgerCases[0],
        "build-ledger",
        "zig-out/bin/ledger",
        .ledger_definition_check,
    ),
    rootCompat(
        LedgerCases[1],
        "build-ledger",
        "zig-out/bin/ledger",
        .ledger_validate,
    ),
    rootCompat(
        LedgerCases[2],
        "build-ledger",
        "zig-out/bin/ledger",
        .ledger_materialize,
    ),
    rootCompatSamples(
        LedgerCases[3],
        "build-ledger",
        "zig-out/bin/ledger",
        .ledger_transact,
        60,
    ),
    rootStreamingProject(LedgerCases[4]),
    rootCompat(
        LedgerCases[5],
        "build-ledger",
        "zig-out/bin/ledger",
        .ledger_doctor,
    ),
    .{
        .descriptor = MiscCases[0],
        .builder = .root,
        .build_step = "build-lift",
        .binary_path = "zig-out/bin/bench_stats",
        .setup = .bench_stats_help,
        .tolerance_pct = 25.0,
    },
    .{
        .descriptor = MiscCases[1],
        .builder = .root,
        .build_step = "build-lift",
        .binary_path = "zig-out/bin/bench_stats",
        .setup = .bench_stats_parse,
        .tolerance_pct = 25.0,
    },
    .{
        .descriptor = MiscCases[2],
        .builder = .root,
        .build_step = "build-cas",
        .binary_path = "zig-out/bin/cas",
        .setup = .cas_wrapper_smoke,
        .tolerance_pct = 120.0,
    },
    .{
        .descriptor = MiscCases[3],
        .builder = .root,
        .build_step = "build-cas",
        .binary_path = "zig-out/bin/cas_smoke_check",
        .setup = .cas_smoke_check_help,
        .tolerance_pct = 100.0,
    },
    .{
        .descriptor = MiscCases[4],
        .builder = .root,
        .build_step = "build-cas",
        .binary_path = "zig-out/bin/cas_instance_runner",
        .setup = .cas_instance_runner_help,
        .tolerance_pct = 100.0,
    },
    .{
        .descriptor = MiscCases[5],
        .builder = .root,
        .build_step = "build-cas",
        .binary_path = "zig-out/bin/cas_review_session",
        .setup = .cas_review_session_help,
        .tolerance_pct = 100.0,
    },
    .{
        .descriptor = MiscCases[6],
        .builder = .root,
        .build_step = "build-cas",
        .binary_path = "zig-out/bin/cas_review_session",
        .setup = .cas_review_session_version,
        .tolerance_pct = 100.0,
    },
    .{
        .descriptor = CasAutomationCases[0],
        .builder = .root,
        .build_step = "build-cas",
        .binary_path = "zig-out/bin/cas",
        .setup = .cas_automation_help,
        .tolerance_pct = 25.0,
    },
    .{
        .descriptor = CasAutomationCases[1],
        .builder = .root,
        .build_step = "build-cas",
        .binary_path = "zig-out/bin/cas",
        .setup = .cas_automation_list,
        .tolerance_pct = 35.0,
    },
};

const DeepCases = [_]DeepCase{
    .{
        .descriptor = SeqCases[4],
        .setup = .seq_observe,
        .tolerance_pct = 3.0,
        .warmups = 3,
        .samples = 30,
        .batch_iterations = 8,
    },
    .{
        .descriptor = CasAutomationCases[2],
        .setup = .cas_automation_show,
        .tolerance_pct = 200.0,
    },
    .{
        .descriptor = CasAutomationCases[3],
        .setup = .cas_automation_create,
        .tolerance_pct = 25.0,
    },
    .{
        .descriptor = CasAutomationCases[4],
        .setup = .cas_automation_update,
        .tolerance_pct = 25.0,
    },
    .{
        .descriptor = CasAutomationCases[5],
        .setup = .cas_automation_enable,
        .tolerance_pct = 250.0,
    },
    .{
        .descriptor = CasAutomationCases[6],
        .setup = .cas_automation_disable,
        .tolerance_pct = 100.0,
    },
    .{
        .descriptor = CasAutomationCases[7],
        .setup = .cas_automation_run_now,
        .tolerance_pct = 70.0,
    },
    .{
        .descriptor = CasAutomationCases[8],
        .setup = .cas_automation_delete,
        .tolerance_pct = 60.0,
    },
    .{
        .descriptor = CasAutomationCases[9],
        .setup = .cas_automation_run_due,
        .tolerance_pct = 125.0,
    },
} ++ OptimizationDeepCases;

const OptimizationCases = [_]perf_contract.CaseDescriptor{
    optimizationCase("ledger-topk-16384-k100", "ledger"),
    optimizationCase("ledger-topk-16384-k1", "ledger"),
    optimizationCase("ledger-topk-16384-k10", "ledger"),
    optimizationCase("ledger-topk-16384-k1000", "ledger"),
    optimizationCase("ledger-topk-32-k10", "ledger"),
    optimizationCase("trace-full-1024", "seq"),
    optimizationCase("trace-full-8", "seq"),
    optimizationCase("trace-summary-1024", "seq"),
    optimizationCase("trace-summary-8", "seq"),
};
const OptimizationDeepCases = optimizationDeepCases();
const OptimizationCoverages = [_]perf_contract.CommandCoverage{.{
    .family = "optimization",
    .coverage = .deep,
    .reason = "bounded top-K and full/summary trace workloads",
}};

fn optimizationCase(id: []const u8, binary: []const u8) perf_contract.CaseDescriptor {
    return .{
        .case_id = id,
        .binary = binary,
        .family = "optimization",
        .case_kind = .driver,
        .measurement_mode = .latency_alloc,
    };
}

fn optimizationDeepCases() [OptimizationCases.len]DeepCase {
    var result: [OptimizationCases.len]DeepCase = undefined;
    for (OptimizationCases, 0..) |descriptor, index| result[index] = .{
        .descriptor = descriptor,
        .driver_kind = .optimization,
        .primary_optimization = index == 0 or index == 5,
        .setup = .optimization,
        .tolerance_pct = 3.0,
        .warmups = 3,
        .samples = 30,
        .batch_iterations = 1,
    };
    return result;
}

fn deepCaseForId(id: []const u8) ?DeepCase {
    for (DeepCases) |case| {
        if (std.mem.eql(u8, case.descriptor.case_id, id)) return case;
    }
    return null;
}

const CasAutomationCoverageArray =
    [cas_automation_cli.commandDefinitions().len]perf_contract.CommandCoverage;

fn buildCasAutomationCoverages() CasAutomationCoverageArray {
    var out: [cas_automation_cli.commandDefinitions().len]perf_contract.CommandCoverage = undefined;
    for (cas_automation_cli.commandDefinitions(), 0..) |def, idx| {
        const coverage, const reason = if (def.command == .list)
            .{ perf_contract.CoverageKind.shallow, "compat subprocess case exists" }
        else if (def.command == .scheduler)
            .{ perf_contract.CoverageKind.excluded, "external-like scheduler surfaces deferred" }
        else
            .{ perf_contract.CoverageKind.deep, "native deep case landed" };
        out[idx] = .{ .family = def.name, .coverage = coverage, .reason = reason };
    }
    return out;
}

fn allManifests() []const perf_contract.BinaryManifest {
    return &.{
        .{
            .binary = "seq",
            .coverages = &SeqCoverages,
            .datasets = &SeqDatasets,
            .cases = &SeqCases,
        },
        .{ .binary = "ledger", .coverages = &LedgerCoverages, .cases = &LedgerCases },
        .{ .binary = "cas", .coverages = &CasAutomationCoverages, .cases = &CasAutomationCases },
        .{ .binary = "misc", .coverages = &MiscCoverages, .cases = &MiscCases },
        .{
            .binary = "optimization",
            .coverages = &OptimizationCoverages,
            .cases = &OptimizationCases,
        },
    };
}

const ParsedArgs = struct {
    command: Command,
    target: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const code = try runCommand(init);
    if (code != 0) std.process.exit(code);
}

fn runCommand(init: std.process.Init) !u8 {
    const environ = init.environ_map;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(
        &stdout_writer.interface,
        argv,
        HelpSurface,
        Version,
    )) return 0;
    const parsed = parseArgs(argv[1..]) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(init.io, &.{});
        core_cli.printUsageFailureWithHelp(
            &stderr_writer.interface,
            HelpSurface,
            Version,
            @errorName(err),
            null,
        ) catch return 1;
        return 2;
    };
    switch (parsed.command) {
        .list => try cmdList(init.io, parsed.target),
        .manifest => try cmdManifest(init.io, allocator),
        .audit => try cmdAudit(init.io),
        .doctor => try cmdDoctor(init.io, environ, allocator, parsed.target),
        .compare, .report => {
            var root_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer root_dir.close(init.io);
            const fs = durable_store.Fs.init(init.io, root_dir);
            if (parsed.command == .compare) {
                return cmdCompare(fs, environ, allocator, parsed.target);
            } else {
                try cmdReport(fs, environ, allocator);
            }
        },
    }
    return 0;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    if (args.len == 0) return error.MissingCommand;
    const command = parseCommand(args[0]) orelse return error.InvalidCommand;
    var target: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            target = args[i];
            continue;
        }
        return error.UnknownArgument;
    }
    if (target != null and switch (command) {
        .list, .compare, .doctor => false,
        .manifest, .audit, .report => true,
    }) return error.UnsupportedArgument;
    return .{
        .command = command,
        .target = target,
    };
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "list")) return .list;
    if (std.mem.eql(u8, raw, "manifest")) return .manifest;
    if (std.mem.eql(u8, raw, "audit")) return .audit;
    if (std.mem.eql(u8, raw, "compare")) return .compare;
    if (std.mem.eql(u8, raw, "doctor")) return .doctor;
    if (std.mem.eql(u8, raw, "report")) return .report;
    return null;
}

fn cmdList(io: std.Io, target: ?[]const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(
        io,
        &.{},
    );
    const stdout = &stdout_writer.interface;
    for (CompatCases) |case_cfg| {
        if (!matchesDescriptorTarget(case_cfg.descriptor, target)) continue;
        const case_desc = case_cfg.descriptor;
        try stdout.print("{s}\t{s}\t{s}\n", .{
            case_desc.case_id,
            case_desc.binary,
            case_desc.measurement_mode.asString(),
        });
    }
    for (DeepCases) |case_cfg| {
        if (!matchesDescriptorTarget(case_cfg.descriptor, target)) continue;
        try stdout.print("{s}\t{s}\t{s}\n", .{
            case_cfg.descriptor.case_id,
            case_cfg.descriptor.binary,
            case_cfg.descriptor.measurement_mode.asString(),
        });
    }
}

fn cmdManifest(io: std.Io, allocator: std.mem.Allocator) !void {
    var stdout_writer = std.Io.File.stdout().writer(
        io,
        &.{},
    );
    try perf_contract.writeManifestJson(allocator, &stdout_writer.interface, allManifests());
    try stdout_writer.interface.flush();
}

fn cmdAudit(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writer(
        io,
        &.{},
    );
    const stdout = &stdout_writer.interface;
    for (allManifests()) |manifest| {
        for (manifest.coverages) |coverage| {
            try stdout.print("{s}\t{s}\t{s}\t{s}\n", .{
                manifest.binary,
                coverage.family,
                coverage.coverage.asString(),
                coverage.reason,
            });
        }
        for (manifest.datasets) |dataset| {
            try stdout.print("{s}\tdataset:{s}\t{s}\t{s}\n", .{
                manifest.binary,
                dataset.name,
                dataset.coverage.asString(),
                dataset.reason,
            });
        }
    }
}

const SealedFile = struct {
    path: [:0]u8,
    sha256: [64]u8,

    fn clone(self: SealedFile, allocator: std.mem.Allocator) !SealedFile {
        return .{
            .path = try allocator.dupeSentinel(u8, self.path, 0),
            .sha256 = self.sha256,
        };
    }

    fn deinit(self: *SealedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const CompilerEvidence = struct {
    approved_path: [:0]u8,
    file: SealedFile,
    version: []u8,

    fn clone(self: CompilerEvidence, allocator: std.mem.Allocator) !CompilerEvidence {
        const approved_path = try allocator.dupeSentinel(u8, self.approved_path, 0);
        errdefer allocator.free(approved_path);
        var file = try self.file.clone(allocator);
        errdefer file.deinit(allocator);
        const version = try allocator.dupe(u8, self.version);
        return .{
            .approved_path = approved_path,
            .file = file,
            .version = version,
        };
    }

    fn deinit(self: *CompilerEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.approved_path);
        self.file.deinit(allocator);
        allocator.free(self.version);
        self.* = undefined;
    }
};

const BuiltSource = struct {
    driver_kind: DriverKind = .seq_replay,
    driver_build_source_file: ?SealedFile = null,
    seq: SealedFile,
    ledger: SealedFile,
    perf_hub: SealedFile,
    source_sha: []u8,
    source_tree_sha: []u8,
    source_archive: SealedFile,
    driver_source_tree_sha: []u8,
    driver_source_file: SealedFile,
    compiler: CompilerEvidence,

    fn executable(self: BuiltSource, binary: []const u8) !SealedFile {
        if (std.mem.eql(u8, binary, "seq")) return self.seq;
        if (std.mem.eql(u8, binary, "ledger")) return self.ledger;
        if (std.mem.eql(u8, binary, "perf_hub")) return self.perf_hub;
        return error.UnsupportedIsolatedProduct;
    }

    fn deinit(self: *BuiltSource, allocator: std.mem.Allocator) void {
        self.seq.deinit(allocator);
        self.ledger.deinit(allocator);
        self.perf_hub.deinit(allocator);
        allocator.free(self.source_sha);
        allocator.free(self.source_tree_sha);
        self.source_archive.deinit(allocator);
        allocator.free(self.driver_source_tree_sha);
        self.driver_source_file.deinit(allocator);
        if (self.driver_build_source_file) |*file| file.deinit(allocator);
        self.compiler.deinit(allocator);
        self.* = undefined;
    }
};

const BuiltState = struct {
    sources: std.StringHashMap(BuiltSource),

    fn init(allocator: std.mem.Allocator) BuiltState {
        return .{ .sources = std.StringHashMap(BuiltSource).init(allocator) };
    }

    fn deinit(self: *BuiltState) void {
        var sources = self.sources.iterator();
        while (sources.next()) |entry| {
            self.sources.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.sources.allocator);
        }
        self.sources.deinit();
    }
};

const CommandRun = struct {
    cwd: []const u8,
    argv: []const []const u8,
};

const Metrics = struct {
    samples: std.ArrayList(u64),
    alloc_samples: std.ArrayList(u64),
    rss_samples: std.ArrayList(u64),
    p50_ns: u64,
    p95_ns: u64,
    p50_alloc_calls: u64,
    p95_rss_bytes: u64,

    fn deinit(self: *Metrics, allocator: std.mem.Allocator) void {
        self.samples.deinit(allocator);
        self.alloc_samples.deinit(allocator);
        self.rss_samples.deinit(allocator);
    }
};

const CompareRow = struct {
    status: []const u8,
    case_id: []const u8,
    binary: []const u8,
    detail: []const u8,
    tuple_bound: bool = false,
    evidence_json: ?[]u8 = null,

    fn deinit(self: *CompareRow, allocator: std.mem.Allocator) void {
        if (self.evidence_json) |json| allocator.free(json);
        self.evidence_json = null;
    }
};

const ReportCounts = struct {
    pass: usize = 0,
    fail: usize = 0,
};

fn cmdDoctor(
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    target: ?[]const u8,
) !void {
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const current_dir = try std.fs.path.join(allocator, &.{ ".perf-local", machine_name });
    defer allocator.free(current_dir);

    var count: usize = 0;
    for (CompatCases) |case_cfg| {
        if (!matchesDescriptorTarget(case_cfg.descriptor, target)) continue;
        count += 1;
        const binary_path = resolveBinaryPath(
            environ,
            allocator,
            case_cfg,
        ) catch return error.InvalidData;
        allocator.free(binary_path);
    }
    for (DeepCases) |case_cfg| {
        if (!matchesDescriptorTarget(case_cfg.descriptor, target)) continue;
        count += 1;
    }
    if (count == 0) return error.NoMatchingPerfCases;

    var stdout_writer = std.Io.File.stdout().writer(
        io,
        &.{},
    );
    const stdout = &stdout_writer.interface;
    try stdout.print("machine_id={s}\n", .{machine_name});
    try stdout.print("cases={d}\n", .{count});
    try stdout.print("machine_dir={s}\n", .{current_dir});
}

fn invalidateCurrentCapsule(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
) !void {
    const reports_dir = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "reports" },
    );
    defer allocator.free(reports_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, reports_dir);
    const locator_path = try std.fs.path.join(
        allocator,
        &.{ reports_dir, "current-capsule.json" },
    );
    defer allocator.free(locator_path);
    try writeEvidenceFileAtomic(
        fs,
        allocator,
        locator_path,
        "{\"schema\":\"performance-capsule-ref/v1\"," ++
            "\"capsule\":null,\"status\":\"incomplete\"}\n",
        0o600,
    );
}

fn cmdCompare(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    target: ?[]const u8,
) !u8 {
    const expected_rows = matchingCaseCount(target);
    if (expected_rows == 0) return error.NoMatchingPerfCases;
    const machine_dir = try ensureCurrentMachineDir(fs, allocator);
    defer allocator.free(machine_dir);
    try invalidateCurrentCapsule(fs, allocator, machine_dir);
    var built = BuiltState.init(allocator);
    defer built.deinit();

    var rows: std.ArrayList(CompareRow) = .empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var stdout_writer = std.Io.File.stdout().writer(
        fs.io,
        &.{},
    );
    const stdout = &stdout_writer.interface;
    var any_fail = false;

    for (CompatCases) |case_cfg| {
        if (!matchesDescriptorTarget(case_cfg.descriptor, target)) continue;
        const result = try compareCompatCase(fs, environ, allocator, machine_dir, case_cfg, &built);
        try rows.append(allocator, result);
        try stdout.print("{s}\t{s}\t{s}\n", .{ result.status, result.case_id, result.detail });
        if (comparisonStatusFailed(result.status)) any_fail = true;
    }
    for (DeepCases) |case_cfg| {
        if (!matchesDescriptorTarget(case_cfg.descriptor, target)) continue;
        const result = try compareDeepCase(fs, environ, allocator, machine_dir, case_cfg, &built);
        try rows.append(allocator, result);
        try stdout.print("{s}\t{s}\t{s}\n", .{ result.status, result.case_id, result.detail });
        if (comparisonStatusFailed(result.status)) any_fail = true;
    }
    if (!comparisonSummaryComplete(environ, target, expected_rows, rows.items)) any_fail = true;
    try writeCompareSummaryRows(
        fs,
        environ,
        allocator,
        machine_dir,
        target,
        expected_rows,
        rows.items,
    );
    return if (any_fail) 1 else 0;
}

fn comparisonStatusFailed(status: []const u8) bool {
    return !std.mem.eql(u8, status, "PASS");
}

fn matchingCaseCount(target: ?[]const u8) usize {
    var count: usize = 0;
    for (CompatCases) |case_cfg| {
        if (matchesTarget(
            case_cfg.descriptor.case_id,
            case_cfg.descriptor.binary,
            target,
        )) count += 1;
    }
    for (DeepCases) |case_cfg| {
        if (matchesTarget(
            case_cfg.descriptor.case_id,
            case_cfg.descriptor.binary,
            target,
        )) count += 1;
    }
    return count;
}

fn compareCompatCase(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    _: []const u8,
    case_cfg: CompatCase,
    built: *BuiltState,
) !CompareRow {
    const base_binary = baseBinaryOverride(environ, case_cfg) orelse
        return error.PairedBinaryRequired;
    if (case_cfg.descriptor.case_kind == .driver) {
        return error.PairedBinaryRequired;
    }
    const base_exec = try absolutePathForCwdRelative(fs, allocator, base_binary);
    defer allocator.free(base_exec);
    var base_case = case_cfg;
    base_case.binary_path = base_exec;
    base_case.require_streamed_projection = false;
    var baseline_evidence = try binaryEvidence(fs, environ, allocator, built, base_case);
    defer baseline_evidence.deinit(allocator);
    var candidate_evidence = try binaryEvidence(fs, environ, allocator, built, case_cfg);
    defer candidate_evidence.deinit(allocator);
    try requireExpectedPairedSources(environ, baseline_evidence, candidate_evidence);
    if (std.mem.eql(u8, &baseline_evidence.file.sha256, &candidate_evidence.file.sha256)) {
        return error.ByteIdenticalPerfProducts;
    }
    if (isPreCutoverBinary(baseline_evidence.version) and
        !preCutoverCaseCompatible(case_cfg.setup))
    {
        return error.IncompatibleBaseSurface;
    }
    base_case.binary_path = baseline_evidence.file.path;
    var candidate_case = case_cfg;
    candidate_case.binary_path = candidate_evidence.file.path;
    try requireBinaryUnchanged(fs, baseline_evidence);
    try requireBinaryUnchanged(fs, candidate_evidence);
    var paired = try runPairedMeasuredCases(fs, environ, allocator, base_case, candidate_case);
    defer paired.deinit(allocator);
    try requireBinaryUnchanged(fs, baseline_evidence);
    try requireBinaryUnchanged(fs, candidate_evidence);
    const compare = try compareMeasuredMetrics(case_cfg, paired.baseline, paired.candidate);
    var evidence_case = case_cfg;
    evidence_case.samples = paired.candidate.samples.items.len;
    const evidence = try writePairedMetricsArtifact(
        allocator,
        evidence_case,
        baseline_evidence,
        candidate_evidence,
        null,
        null,
        paired.baseline,
        paired.candidate,
        paired.workload_digest,
        paired.baseline_execution,
        paired.candidate_execution,
        compare.status,
        compare.detail,
    );
    return .{
        .status = compare.status,
        .case_id = case_cfg.descriptor.case_id,
        .binary = case_cfg.descriptor.binary,
        .detail = compare.detail,
        .tuple_bound = true,
        .evidence_json = evidence,
    };
}

fn isPreCutoverBinary(version: []const u8) bool {
    return std.mem.startsWith(u8, version, "0.") or
        std.mem.indexOf(u8, version, " 0.") != null;
}

fn preCutoverCaseCompatible(setup: CompatSetup) bool {
    return setup == .seq_sessions or setup == .seq_query;
}

fn compareDeepCase(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    _: []const u8,
    case_cfg: DeepCase,
    built: *BuiltState,
) !CompareRow {
    if (!std.mem.eql(u8, case_cfg.descriptor.binary, "seq") and
        case_cfg.driver_kind != .optimization) return error.PairedBinaryRequired;
    const compat_case = evidenceCaseConfig(case_cfg.descriptor.case_id) orelse
        return error.InvalidPerfCase;
    const base_binary = baseBinaryOverride(environ, compat_case) orelse
        return error.PairedBinaryRequired;
    const base_exec = try absolutePathForCwdRelative(fs, allocator, base_binary);
    defer allocator.free(base_exec);
    var base_case = compat_case;
    base_case.binary_path = base_exec;
    var baseline_evidence = try binaryEvidence(fs, environ, allocator, built, base_case);
    defer baseline_evidence.deinit(allocator);
    var candidate_evidence = try binaryEvidence(fs, environ, allocator, built, compat_case);
    defer candidate_evidence.deinit(allocator);
    try requireExpectedPairedSources(environ, baseline_evidence, candidate_evidence);
    if (isPreCutoverBinary(baseline_evidence.version)) {
        return error.IncompatibleBaseSurface;
    }
    var paired = try runPairedDeepCases(
        fs,
        environ,
        allocator,
        built,
        case_cfg,
        baseline_evidence,
        candidate_evidence,
    );
    defer paired.deinit(allocator);
    return deepComparisonRow(allocator, case_cfg, baseline_evidence, candidate_evidence, paired);
}

fn deepComparisonRow(
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    baseline_evidence: BinaryEvidence,
    candidate_evidence: BinaryEvidence,
    paired: PairedMetrics,
) !CompareRow {
    const comparison_case = evidenceCaseConfig(case_cfg.descriptor.case_id) orelse
        return error.InvalidPerfCase;
    const compare = try compareBalancedDeepMetrics(case_cfg, paired.baseline, paired.candidate);
    const evidence = try writePairedMetricsArtifact(
        allocator,
        comparison_case,
        baseline_evidence,
        candidate_evidence,
        paired.baseline_driver,
        paired.candidate_driver,
        paired.baseline,
        paired.candidate,
        paired.workload_digest,
        paired.baseline_execution,
        paired.candidate_execution,
        compare.status,
        compare.detail,
    );
    return .{
        .status = compare.status,
        .case_id = case_cfg.descriptor.case_id,
        .binary = case_cfg.descriptor.binary,
        .detail = compare.detail,
        .tuple_bound = true,
        .evidence_json = evidence,
    };
}

fn writeCompareSummaryRows(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    target: ?[]const u8,
    expected_rows: usize,
    rows: []const CompareRow,
) !void {
    const reports_dir = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "reports" },
    );
    defer allocator.free(reports_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, reports_dir);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writeComparisonCapsule(environ, writer, target, expected_rows, rows);
    var parsed = try std.json.parseFromSlice(
        PerformanceCapsule,
        allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();
    _ = try validatePerformanceCapsule(fs, environ, allocator, parsed.value, false);
    var capsule = try sealEvidenceBytes(
        fs,
        allocator,
        machine_dir,
        "capsule.json",
        output.written(),
        0o600,
    );
    defer capsule.deinit(allocator);
    var locator_output: std.Io.Writer.Allocating = .init(allocator);
    defer locator_output.deinit();
    try locator_output.writer.writeAll(
        "{\"schema\":\"performance-capsule-ref/v1\",\"capsule\":",
    );
    try writeSealedFile(&locator_output.writer, capsule);
    try locator_output.writer.writeAll("}\n");
    const locator_path = try std.fs.path.join(
        allocator,
        &.{ reports_dir, "current-capsule.json" },
    );
    defer allocator.free(locator_path);
    try writeEvidenceFileAtomic(
        fs,
        allocator,
        locator_path,
        locator_output.written(),
        0o600,
    );
}

fn writeComparisonCapsule(
    environ: ?*const std.process.Environ.Map,
    writer: *std.Io.Writer,
    target: ?[]const u8,
    expected_rows: usize,
    rows: []const CompareRow,
) !void {
    try writer.writeAll(
        "{\"schema\":\"performance-capsule/v1\",\"target\":",
    );
    if (target) |selected| {
        try std.json.Stringify.value(selected, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"expected_base_sha\":");
    try writeEnvironmentString(environ, writer, "PERF_EXPECT_BASE_SHA");
    try writer.writeAll(",\"expected_candidate_sha\":");
    try writeEnvironmentString(environ, writer, "PERF_EXPECT_CANDIDATE_SHA");
    try writer.writeAll(",\"expected_rows\":");
    try writer.print("{d}", .{expected_rows});
    try writer.writeAll(",\"complete\":");
    try writer.writeAll(if (comparisonSummaryComplete(
        environ,
        target,
        expected_rows,
        rows,
    )) "true" else "false");
    try writer.writeAll(",\"rows\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"case_id\":");
        try writeJsonString(writer, row.case_id);
        try writer.writeAll(",\"binary\":");
        try writeJsonString(writer, row.binary);
        try writer.writeAll(",\"status\":");
        try writeJsonString(writer, row.status);
        try writer.print(
            ",\"tuple_bound\":{},\"detail\":",
            .{row.tuple_bound},
        );
        try writeJsonString(writer, row.detail);
        try writer.writeAll(",\"evidence\":");
        if (row.evidence_json) |json| {
            if (json.len == 0) return error.IncompletePerfEvidence;
            try writer.writeAll(json);
        } else {
            if (row.tuple_bound) return error.IncompletePerfEvidence;
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn writeEnvironmentString(
    environ: ?*const std.process.Environ.Map,
    writer: *std.Io.Writer,
    name: []const u8,
) !void {
    if (environ) |environment| {
        if (environment.get(name)) |value| {
            return std.json.Stringify.value(value, .{}, writer);
        }
    }
    try writer.writeAll("null");
}

fn comparisonSummaryComplete(
    environ: ?*const std.process.Environ.Map,
    target: ?[]const u8,
    expected_rows: usize,
    rows: []const CompareRow,
) bool {
    if (expected_rows != rows.len) return false;
    const selected = target orelse return true;
    if (!std.mem.eql(u8, selected, "seq") and
        !std.mem.eql(u8, selected, "ledger") and
        !std.mem.eql(u8, selected, "cutover") and
        !std.mem.eql(u8, selected, "optimization"))
    {
        return true;
    }
    const environment = environ orelse return false;
    if (environment.get("PERF_EXPECT_BASE_SHA") == null or
        environment.get("PERF_EXPECT_CANDIDATE_SHA") == null)
    {
        return false;
    }
    for (rows) |row| {
        if (!row.tuple_bound) return false;
    }
    return true;
}

const StatusDetail = struct {
    status: []const u8,
    detail: []const u8,
};

const Sqlite = struct {
    pub const sqlite3 = opaque {};
    pub const SQLITE_OK: c_int = 0;

    extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
    extern fn sqlite3_close(db: *sqlite3) c_int;
    extern fn sqlite3_free(ptr: ?*anyopaque) void;
    extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    extern fn sqlite3_exec(
        db: *sqlite3,
        sql: [*:0]const u8,
        callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int,
        arg: ?*anyopaque,
        errmsg: ?*?[*:0]u8,
    ) c_int;
};

fn matchesDescriptorTarget(descriptor: perf_contract.CaseDescriptor, target: ?[]const u8) bool {
    return matchesTarget(descriptor.case_id, descriptor.binary, target);
}

fn matchesTarget(case_id: []const u8, binary: []const u8, target: ?[]const u8) bool {
    const needle = target orelse return true;
    if (std.mem.eql(u8, needle, "optimization")) {
        const case = deepCaseForId(case_id) orelse return false;
        return case.driver_kind == .optimization;
    }
    if (std.mem.eql(u8, needle, "cutover")) {
        if (deepCaseForId(case_id)) |case| {
            if (case.driver_kind == .optimization) return false;
        }
        return std.mem.eql(u8, binary, "seq") or
            std.mem.eql(u8, binary, "ledger");
    }
    if (std.mem.eql(u8, needle, "cas")) return std.mem.startsWith(u8, case_id, "cas-");
    if (isKnownBinaryName(needle)) return std.mem.eql(u8, binary, needle);
    if (std.mem.eql(u8, binary, needle)) return true;
    return std.mem.indexOf(u8, case_id, needle) != null;
}

fn ensureCurrentMachineDir(fs: durable_store.Fs, allocator: std.mem.Allocator) ![]u8 {
    const current_name = try currentMachineDirName(allocator);
    defer allocator.free(current_name);
    const dir_path = try std.fs.path.join(allocator, &.{ ".perf-local", current_name });
    errdefer allocator.free(dir_path);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, ".perf-local");
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, dir_path);
    return dir_path;
}

fn resolveBinaryPath(
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
) ![]u8 {
    _ = case_cfg.builder;
    if (std.fs.path.isAbsolute(case_cfg.binary_path)) {
        return allocator.dupe(u8, case_cfg.binary_path);
    }
    const environment = environ;
    const override = if (environment != null and std.mem.eql(
        u8,
        case_cfg.descriptor.binary,
        "seq",
    ))
        environment.?.get("PERF_SEQ_BINARY")
    else if (environment != null and std.mem.eql(
        u8,
        case_cfg.descriptor.binary,
        "ledger",
    ))
        environment.?.get("PERF_LEDGER_BINARY")
    else
        null;
    if (override) |path| return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ ".", case_cfg.binary_path });
}

fn resolveBinaryExecPath(
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
) ![]u8 {
    return resolveBinaryPath(environ, allocator, case_cfg);
}

fn baseBinaryOverride(environ: ?*const std.process.Environ.Map, case_cfg: CompatCase) ?[]const u8 {
    const environment = environ orelse return null;
    if (std.mem.eql(u8, case_cfg.descriptor.binary, "seq")) {
        return environment.get("PERF_SEQ_BASE_BINARY");
    }
    if (std.mem.eql(u8, case_cfg.descriptor.binary, "ledger")) {
        return environment.get("PERF_LEDGER_BASE_BINARY");
    }
    return null;
}

fn requireExpectedPairedSources(
    environ: ?*const std.process.Environ.Map,
    baseline: BinaryEvidence,
    candidate: BinaryEvidence,
) !void {
    const environment = environ orelse
        return error.ExpectedSourceShaRequired;
    try requireExpectedSourceShas(environment, baseline.source_sha, candidate.source_sha);
}

fn requireExpectedSourceShas(
    environment: *const std.process.Environ.Map,
    baseline_source_sha: []const u8,
    candidate_source_sha: []const u8,
) !void {
    const expected_base = environment.get("PERF_EXPECT_BASE_SHA") orelse
        return error.ExpectedSourceShaRequired;
    const expected_candidate = environment.get(
        "PERF_EXPECT_CANDIDATE_SHA",
    ) orelse return error.ExpectedSourceShaRequired;
    if (!std.mem.eql(u8, expected_base, baseline_source_sha)) {
        return error.BaselineSourceShaMismatch;
    }
    if (!std.mem.eql(u8, expected_candidate, candidate_source_sha)) {
        return error.CandidateSourceShaMismatch;
    }
}

const PairedMetrics = struct {
    baseline: Metrics,
    candidate: Metrics,
    workload_digest: [64]u8,
    baseline_execution: MeasuredOutputEvidence,
    candidate_execution: MeasuredOutputEvidence,
    baseline_driver: ?DriverEvidence = null,
    candidate_driver: ?DriverEvidence = null,

    fn deinit(self: *PairedMetrics, allocator: std.mem.Allocator) void {
        self.baseline.deinit(allocator);
        self.candidate.deinit(allocator);
        if (self.baseline_driver) |*driver| driver.deinit(allocator);
        if (self.candidate_driver) |*driver| driver.deinit(allocator);
        self.* = undefined;
    }
};

const MeasuredOutputEvidence = struct {
    output_sha256: [64]u8,
    semantic_output_sha256: [64]u8,
    local_output_sha256: ?[64]u8 = null,
    streamed: ?bool = null,
    records_scanned: ?u64 = null,
    records_emitted: ?u64 = null,
    physical_passes: ?u64 = null,
    files_opened: ?u64 = null,
    bytes_read: ?u64 = null,
    rows_materialized: ?u64 = null,
    compile_ns: ?u64 = null,
    execution_ns: ?u64 = null,
};

const BinaryEvidence = struct {
    file: SealedFile,
    version: []u8,
    source_sha: []u8,
    source_tree_sha: []u8,
    source_root: []u8,
    source_archive: SealedFile,
    compiler: CompilerEvidence,
    build_step: []const u8,

    fn deinit(self: *BinaryEvidence, allocator: std.mem.Allocator) void {
        self.file.deinit(allocator);
        allocator.free(self.version);
        allocator.free(self.source_sha);
        allocator.free(self.source_tree_sha);
        allocator.free(self.source_root);
        self.source_archive.deinit(allocator);
        self.compiler.deinit(allocator);
        self.* = undefined;
    }
};

const DriverEvidence = struct {
    kind: DriverKind = .seq_replay,
    build_source_file: ?SealedFile = null,
    file: SealedFile,
    source_sha: []const u8,
    source_tree_sha: []u8,
    source_file: SealedFile,
    product_source_sha: []u8,
    product_source_tree_sha: []u8,
    product_source_archive_sha256: [64]u8,
    compiler: CompilerEvidence,

    fn deinit(self: *DriverEvidence, allocator: std.mem.Allocator) void {
        self.file.deinit(allocator);
        allocator.free(self.source_tree_sha);
        self.source_file.deinit(allocator);
        if (self.build_source_file) |*file| file.deinit(allocator);
        allocator.free(self.product_source_sha);
        allocator.free(self.product_source_tree_sha);
        self.compiler.deinit(allocator);
        self.* = undefined;
    }
};

fn binaryEvidence(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    built: *BuiltState,
    case_cfg: CompatCase,
) !BinaryEvidence {
    const resolved = try resolveBinaryExecPath(environ, allocator, case_cfg);
    defer allocator.free(resolved);
    const original_path = try fs.directory().realPathFileAlloc(fs.io, resolved, allocator);
    defer allocator.free(original_path);
    const source_root = try sourceRootForBinaryAlloc(fs, allocator, original_path);
    errdefer allocator.free(source_root);
    try requireCleanSourceRoot(fs, environ, allocator, source_root);
    const source_sha = try sourceShaForRootAlloc(fs, environ, allocator, source_root);
    errdefer allocator.free(source_sha);
    const source_tree_sha = try sourceTreeShaForRootAlloc(fs, environ, allocator, source_root);
    errdefer allocator.free(source_tree_sha);
    const isolated = try ensureSourceBuilt(
        fs,
        environ,
        allocator,
        built,
        source_root,
        source_sha,
        driverKindForCase(case_cfg.descriptor),
    );
    if (!std.mem.eql(u8, isolated.source_tree_sha, source_tree_sha))
        return error.ProductSourceChanged;
    var file = try (try isolated.executable(case_cfg.descriptor.binary)).clone(allocator);
    errdefer file.deinit(allocator);
    var source_archive = try isolated.source_archive.clone(allocator);
    errdefer source_archive.deinit(allocator);
    var compiler = try isolated.compiler.clone(allocator);
    errdefer compiler.deinit(allocator);
    const original_sha = try sha256BuildOutput(fs, original_path);
    if (!std.mem.eql(u8, &original_sha, &file.sha256)) return error.ProductBinaryChanged;
    const result = try runChildCaptureOutput(
        fs,
        environ,
        allocator,
        ".",
        &.{ file.path, "version" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BinaryVersionFailed;
    const version = try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    errdefer allocator.free(version);
    const current_original_sha = try sha256BuildOutput(fs, original_path);
    if (!std.mem.eql(u8, &current_original_sha, &file.sha256)) return error.ProductBinaryChanged;
    try requireSourceIdentityUnchanged(
        fs,
        environ,
        allocator,
        source_root,
        source_sha,
        source_tree_sha,
    );
    return .{
        .file = file,
        .version = version,
        .source_sha = source_sha,
        .source_tree_sha = source_tree_sha,
        .source_root = source_root,
        .source_archive = source_archive,
        .compiler = compiler,
        .build_step = "install",
    };
}

fn requireSourceIdentityUnchanged(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    source_sha: []const u8,
    source_tree_sha: []const u8,
) !void {
    try requireCleanSourceRoot(fs, environ, allocator, source_root);
    const current_source_sha = try sourceShaForRootAlloc(fs, environ, allocator, source_root);
    defer allocator.free(current_source_sha);
    const current_tree_sha = try sourceTreeShaForRootAlloc(fs, environ, allocator, source_root);
    defer allocator.free(current_tree_sha);
    if (!std.mem.eql(u8, current_source_sha, source_sha) or
        !std.mem.eql(u8, current_tree_sha, source_tree_sha))
    {
        return error.ProductSourceChanged;
    }
}

fn driverEvidence(allocator: std.mem.Allocator, built: BuiltSource) !DriverEvidence {
    var file = try built.perf_hub.clone(allocator);
    errdefer file.deinit(allocator);
    const source_tree_sha = try allocator.dupe(u8, built.driver_source_tree_sha);
    errdefer allocator.free(source_tree_sha);
    var source_file = try built.driver_source_file.clone(allocator);
    errdefer source_file.deinit(allocator);
    const product_source_sha = try allocator.dupe(u8, built.source_sha);
    errdefer allocator.free(product_source_sha);
    const product_source_tree_sha = try allocator.dupe(u8, built.source_tree_sha);
    errdefer allocator.free(product_source_tree_sha);
    var compiler = try built.compiler.clone(allocator);
    errdefer compiler.deinit(allocator);
    var build_file = if (built.driver_build_source_file) |source_build|
        try source_build.clone(allocator)
    else
        null;
    errdefer if (build_file) |*source_build| source_build.deinit(allocator);
    return .{
        .file = file,
        .kind = built.driver_kind,
        .build_source_file = build_file,
        .source_sha = driverIdentity(built.driver_kind).revision,
        .source_tree_sha = source_tree_sha,
        .source_file = source_file,
        .product_source_sha = product_source_sha,
        .product_source_tree_sha = product_source_tree_sha,
        .product_source_archive_sha256 = built.source_archive.sha256,
        .compiler = compiler,
    };
}

fn requireDriverUnchanged(fs: durable_store.Fs, driver: DriverEvidence) !void {
    verifySealedFile(fs, driver.file) catch return error.DriverBinaryChanged;
    try verifySealedFile(fs, driver.source_file);
    if (driver.build_source_file) |file| try verifySealedFile(fs, file);
}

fn requireBinaryUnchanged(fs: durable_store.Fs, evidence: BinaryEvidence) !void {
    verifySealedFile(fs, evidence.file) catch return error.ProductBinaryChanged;
}

fn requireCompilerDigestAtPath(
    fs: durable_store.Fs,
    path: []const u8,
    expected_digest: []const u8,
) !void {
    if (expected_digest.len != 64) return error.CompilerBinaryChanged;
    const observed = try sha256FileBounded(fs, path, 64 * 1024 * 1024);
    if (!std.mem.eql(u8, &observed, expected_digest)) {
        return error.CompilerBinaryChanged;
    }
}

fn approvedCompilerEvidence(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
) !CompilerEvidence {
    const environment = environ orelse
        return error.ApprovedZigBinaryRequired;
    const configured = environment.get("PERF_ZIG_BINARY") orelse
        return error.ApprovedZigBinaryRequired;
    if (!std.fs.path.isAbsolute(configured)) {
        return error.ApprovedZigBinaryRequired;
    }
    const approved_path = try fs.directory().realPathFileAlloc(
        fs.io,
        configured,
        allocator,
    );
    errdefer allocator.free(approved_path);
    var file = try sealEvidenceFile(
        fs,
        allocator,
        machine_dir,
        "zig",
        approved_path,
        64 * 1024 * 1024,
        0o500,
    );
    errdefer file.deinit(allocator);
    const result = try runChildCaptureOutput(
        fs,
        environ,
        allocator,
        ".",
        &.{ approved_path, "version" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CompilerVersionFailed;
    const approved_digest = try sha256FileBounded(fs, approved_path, 64 * 1024 * 1024);
    if (!std.mem.eql(u8, &approved_digest, &file.sha256)) {
        return error.CompilerBinaryChanged;
    }
    const version = try allocator.dupe(
        u8,
        std.mem.trim(u8, result.stdout, " \t\r\n"),
    );
    errdefer allocator.free(version);
    if (!std.mem.eql(u8, version, builtin.zig_version_string)) {
        return error.CompilerVersionMismatch;
    }
    return .{
        .approved_path = approved_path,
        .file = file,
        .version = version,
    };
}

fn sha256File(fs: durable_store.Fs, path: []const u8) ![64]u8 {
    return sha256FileBounded(fs, path, 16 * 1024 * 1024);
}

fn sha256FileBounded(fs: durable_store.Fs, path: []const u8, max_bytes: usize) ![64]u8 {
    const bytes = try readRegularFileAlloc(fs, std.heap.page_allocator, path, max_bytes);
    defer std.heap.page_allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn sha256BuildOutput(fs: durable_store.Fs, path: []const u8) ![64]u8 {
    const bytes = try readBuildOutputAlloc(fs, std.heap.page_allocator, path, 16 * 1024 * 1024);
    defer std.heap.page_allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const max_sealed_evidence_bytes = 64 * 1024 * 1024;

fn evidenceDigest(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

fn sealEvidenceBytes(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    label: []const u8,
    bytes: []const u8,
    mode: u32,
) !SealedFile {
    if (bytes.len == 0 or bytes.len > max_sealed_evidence_bytes or
        label.len == 0 or
        !std.mem.eql(u8, label, std.fs.path.basename(label)) or
        std.mem.eql(u8, label, ".") or std.mem.eql(u8, label, ".."))
    {
        return error.InvalidPerfEvidenceFile;
    }
    const digest = evidenceDigest(bytes);
    const blob_dir = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "capsules", "blobs", &digest },
    );
    defer allocator.free(blob_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, blob_dir);
    const blob_path = try std.fs.path.join(allocator, &.{ blob_dir, label });
    defer allocator.free(blob_path);
    if (pathExists(fs, blob_path)) {
        const retained = try sha256FileBounded(fs, blob_path, max_sealed_evidence_bytes);
        if (!std.mem.eql(u8, &retained, &digest)) {
            return error.PerfEvidenceDigestMismatch;
        }
    } else {
        try writeEvidenceFileAtomic(fs, allocator, blob_path, bytes, mode);
    }
    const real_path = try fs.directory().realPathFileAlloc(
        fs.io,
        blob_path,
        allocator,
    );
    defer allocator.free(real_path);
    return .{
        .path = try allocator.dupeSentinel(u8, real_path, 0),
        .sha256 = digest,
    };
}

fn sealEvidenceFile(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    label: []const u8,
    path: []const u8,
    max_bytes: usize,
    mode: u32,
) !SealedFile {
    if (max_bytes > max_sealed_evidence_bytes) {
        return error.InvalidPerfEvidenceFile;
    }
    const bytes = try readStableFileAlloc(fs, allocator, path, max_bytes, false);
    defer allocator.free(bytes);
    return sealEvidenceBytes(fs, allocator, machine_dir, label, bytes, mode);
}

fn verifySealedFile(fs: durable_store.Fs, file: SealedFile) !void {
    const retained = try sha256FileBounded(fs, file.path, 64 * 1024 * 1024);
    if (!std.mem.eql(u8, &retained, &file.sha256)) {
        return error.PerfEvidenceDigestMismatch;
    }
}

fn readRegularFileAlloc(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return readStableFileAlloc(fs, allocator, path, max_bytes, true);
}

fn readBuildOutputAlloc(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return readStableFileAlloc(fs, allocator, path, max_bytes, false);
}

fn readStableFileAlloc(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
    require_single_link: bool,
) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(
            fs.io,
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        )
    else
        try fs.directory().openFile(
            fs.io,
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        );
    defer file.close(fs.io);
    const before = try file.stat(fs.io);
    if (before.kind != .file or
        (require_single_link and before.nlink != 1) or
        before.size > max_bytes)
    {
        return error.InvalidPerfEvidenceFile;
    }
    const size = std.math.cast(usize, before.size) orelse
        return error.InvalidPerfEvidenceFile;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    const count = try file.readPositionalAll(
        fs.io,
        bytes,
        0,
    );
    if (count != size) return error.PerfEvidenceFileChanged;
    const after = try file.stat(fs.io);
    if (after.kind != .file or
        (require_single_link and after.nlink != 1) or
        after.size != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds)
    {
        return error.PerfEvidenceFileChanged;
    }
    return bytes;
}

fn caseConfigurationDigest(case_cfg: CompatCase) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{
        "perf-case-configuration/v1",
        case_cfg.descriptor.case_id,
        case_cfg.descriptor.binary,
        case_cfg.descriptor.case_kind.asString(),
        @tagName(case_cfg.descriptor.measurement_mode),
        @tagName(case_cfg.setup),
        "ReleaseFast",
    }) |value| {
        hasher.update(value);
        hasher.update(&.{0});
    }
    var encoded: [128]u8 = undefined;
    const numeric = try std.fmt.bufPrint(
        &encoded,
        "{d}:{d}:{d}:{d}:{d:.6}:{d:.6}",
        .{
            case_cfg.warmups,
            case_cfg.samples,
            if (deepCaseForId(case_cfg.descriptor.case_id)) |deep| deep.batch_iterations else 0,
            paired_comparison_rounds,
            case_cfg.tolerance_pct,
            resource_tolerance_pct,
        },
    );
    hasher.update(numeric);
    if (isDeepCaseId(case_cfg.descriptor.case_id)) {
        hasher.update(deep_measurement_schema);
        hasher.update(&.{0});
        hasher.update(deep_comparison_method);
    }
    if (deepCaseForId(case_cfg.descriptor.case_id)) |deep| {
        if (deep.driver_kind == .optimization) {
            hasher.update("optimization-native/v1\x00");
            hasher.update(if (deep.primary_optimization) "primary-p50-0.80" else "p50-1.03");
            hasher.update("\x00p95-1.03\x00allocations-1.00\x00rss-1.02");
            hasher.update("\x00target-aarch64-macos\x00cpu-baseline");
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn sourceRootForBinaryAlloc(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    binary_path: []const u8,
) ![]u8 {
    var cursor = std.fs.path.dirname(binary_path) orelse
        return error.BinarySourceUnavailable;
    for (0..16) |_| {
        const marker = try std.fs.path.join(
            allocator,
            &.{ cursor, ".git" },
        );
        const found = pathExists(fs, marker);
        allocator.free(marker);
        if (found) {
            return allocator.dupe(u8, cursor);
        }
        const parent = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, parent, cursor)) break;
        cursor = parent;
    }
    return error.BinarySourceUnavailable;
}

fn requireCleanSourceRoot(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
) !void {
    const result = try runChildCaptureOutput(
        fs,
        environ,
        allocator,
        ".",
        &.{
            git_binary,
            "-C",
            source_root,
            "status",
            "--porcelain",
            "--untracked-files=no",
        },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BinarySourceUnavailable;
    if (std.mem.trim(u8, result.stdout, " \t\r\n").len != 0) {
        return error.BinarySourceDirty;
    }
}

fn sourceShaForRootAlloc(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
) ![]u8 {
    const result = try runChildCaptureOutput(
        fs,
        environ,
        allocator,
        ".",
        &.{ git_binary, "-C", source_root, "rev-parse", "HEAD" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        return error.BinarySourceUnavailable;
    }
    return allocator.dupe(
        u8,
        std.mem.trim(u8, result.stdout, " \t\r\n"),
    );
}

fn observedWorkloadDigest(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(@tagName(case_cfg.setup));
    hasher.update(&.{0});
    try hashObservedCommand(fs, environ, allocator, case_cfg, temp_root, &hasher);
    var root = try std.Io.Dir.openDirAbsolute(
        fs.io,
        temp_root,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer root.close(fs.io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    while (try walker.next(
        fs.io,
    )) |entry| {
        if (entry.kind == .sym_link) return error.PerfWorkloadSymlink;
        if (entry.kind != .file or
            pathContainsGitComponent(entry.path) or
            !observedWorkloadPath(case_cfg.setup, entry.path))
        {
            continue;
        }
        if (paths.items.len == 1024) return error.PerfWorkloadTooLarge;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort(
        []u8,
        paths.items,
        {},
        struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan,
    );
    var total_bytes: usize = 0;
    for (paths.items) |path| {
        hasher.update(if (isObservedBindingPath(path))
            "ledger-repo/.ledger/.bindings/<definition>.jsonl"
        else
            path);
        hasher.update(&.{0});
        if (isObservedBindingPath(path)) {
            try hashObservedBinding(fs.io, allocator, &root, path, &hasher);
            hasher.update(&.{0xff});
            continue;
        }
        try hashObservedFile(fs.io, &root, path, &hasher, &total_bytes);
        hasher.update(&.{0xff});
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashObservedFile(
    io: std.Io,
    root: *std.Io.Dir,
    path: []const u8,
    hasher: *std.crypto.hash.sha2.Sha256,
    total_bytes: *usize,
) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var file = try root.openFile(
        io,
        path,
        .{ .allow_directory = false, .follow_symlinks = false },
    );
    defer file.close(io);
    var reader = file.reader(
        io,
        &.{},
    );
    while (total_bytes.* <= 128 * 1024 * 1024) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        total_bytes.* = std.math.add(
            usize,
            total_bytes.*,
            count,
        ) catch return error.PerfWorkloadTooLarge;
        if (total_bytes.* > 128 * 1024 * 1024) {
            return error.PerfWorkloadTooLarge;
        }
        hasher.update(buffer[0..count]);
    }
}

fn hashObservedCommand(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
    hasher: *std.crypto.hash.sha2.Sha256,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const run = try renderCompatRun(
        fs,
        environ,
        arena.allocator(),
        case_cfg,
        temp_root,
    );
    for (run.argv, 0..) |arg, index| {
        if (index == 0) {
            hasher.update("<binary>");
        } else if (std.mem.indexOf(u8, arg, temp_root)) |offset| {
            hasher.update(arg[0..offset]);
            hasher.update("<workload-root>");
            hasher.update(arg[offset + temp_root.len ..]);
        } else if (std.mem.startsWith(u8, arg, "request=perf-")) {
            hasher.update("request=perf-<sample>");
        } else {
            hasher.update(arg);
        }
        hasher.update(&.{0});
        if (index != 0) {
            try hashObservedExternalArgument(fs, allocator, arg, hasher);
        }
    }
}

fn hashObservedExternalArgument(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    argument: []const u8,
    hasher: *std.crypto.hash.sha2.Sha256,
) !void {
    const candidate = if (std.mem.indexOfScalar(u8, argument, '=')) |index|
        argument[index + 1 ..]
    else
        argument;
    if (candidate.len == 0 or
        std.fs.path.isAbsolute(candidate) or
        !pathExists(fs, candidate))
    {
        return;
    }
    const stat = fs.directory().statFile(
        fs.io,
        candidate,
        .{ .follow_symlinks = false },
    ) catch return;
    if (stat.kind != .file or stat.size > 4 * 1024 * 1024) return;
    const bytes = try fs.directory().readFileAlloc(
        fs.io,
        candidate,
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    hasher.update("<external-file>");
    hasher.update(candidate);
    hasher.update(&.{0});
    hasher.update(bytes);
    hasher.update(&.{0xff});
}

fn observedWorkloadPath(setup: CompatSetup, path: []const u8) bool {
    return switch (setup) {
        .seq_sessions, .seq_query => std.mem.startsWith(
            u8,
            path,
            "seq-sessions/",
        ),
        .ledger_transact, .ledger_project, .ledger_doctor => std.mem.eql(
            u8,
            path,
            "ledger-event-definition.json",
        ) or
            std.mem.eql(
                u8,
                path,
                "ledger-repo/.ledger/example/events.jsonl",
            ) or
            std.mem.startsWith(
                u8,
                path,
                "ledger-repo/.ledger/.bindings/",
            ) and std.mem.endsWith(u8, path, ".jsonl"),
        else => true,
    };
}

fn isObservedBindingPath(path: []const u8) bool {
    return std.mem.startsWith(
        u8,
        path,
        "ledger-repo/.ledger/.bindings/",
    ) and std.mem.endsWith(u8, path, ".jsonl");
}

fn hashObservedBinding(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: *std.Io.Dir,
    path: []const u8,
    hasher: *std.crypto.hash.sha2.Sha256,
) !void {
    const raw = try root.readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var records: usize = 0;
    while (lines.next()) |line| {
        const payload = std.mem.trim(u8, line, " \t\r");
        if (payload.len == 0) continue;
        records += 1;
        if (records > 1024) return error.PerfWorkloadTooLarge;
        try hashObservedBindingRecord(allocator, payload, hasher);
        hasher.update(&.{0xfe});
    }
    if (records == 0) return error.PerfWorkloadBindingInvalid;
}

fn hashObservedBindingRecord(
    allocator: std.mem.Allocator,
    raw: []const u8,
    hasher: *std.crypto.hash.sha2.Sha256,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.PerfWorkloadBindingInvalid,
    };
    const fields = [_][]const u8{
        "abi",
        "definition_id",
        "logical_path",
        "slot",
        "revision_after",
        "record_end",
        "extent_end",
    };
    for (fields) |field| {
        const value = object.get(field) orelse
            return error.PerfWorkloadBindingInvalid;
        hasher.update(field);
        hasher.update(&.{0});
        var encoded: std.Io.Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        try std.json.Stringify.value(value, .{}, &encoded.writer);
        hasher.update(encoded.written());
        hasher.update(&.{0});
    }
}

fn pathContainsGitComponent(path: []const u8) bool {
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".git")) return true;
    }
    return false;
}

const MetricSamples = struct {
    times: std.ArrayList(u64) = .empty,
    allocations: std.ArrayList(u64) = .empty,
    rss: std.ArrayList(u64) = .empty,

    fn init(allocator: std.mem.Allocator, count: usize, allocs: usize, rss: usize) !MetricSamples {
        var result: MetricSamples = .{};
        errdefer result.deinit(allocator);
        try result.times.ensureTotalCapacity(allocator, count);
        try result.allocations.ensureTotalCapacity(allocator, allocs);
        try result.rss.ensureTotalCapacity(allocator, rss);
        return result;
    }

    fn deinit(self: *MetricSamples, allocator: std.mem.Allocator) void {
        self.times.deinit(allocator);
        self.allocations.deinit(allocator);
        self.rss.deinit(allocator);
    }

    fn finish(self: *MetricSamples, allocator: std.mem.Allocator) !Metrics {
        const result = try metricsFromSamples(allocator, self.times, self.allocations, self.rss);
        self.* = .{};
        return result;
    }

    fn appendCompat(
        self: *MetricSamples,
        fs: durable_store.Fs,
        environ: ?*const std.process.Environ.Map,
        allocator: std.mem.Allocator,
        case_cfg: CompatCase,
        root: []const u8,
    ) !void {
        try appendCompatSample(
            fs,
            environ,
            allocator,
            case_cfg,
            root,
            &self.times,
            &self.allocations,
            &self.rss,
        );
    }

    fn appendDeep(
        self: *MetricSamples,
        fs: durable_store.Fs,
        environ: ?*const std.process.Environ.Map,
        allocator: std.mem.Allocator,
        case_cfg: DeepCase,
        root: []const u8,
        driver: DriverEvidence,
    ) !void {
        try appendSourceDeepMetrics(
            fs,
            environ,
            allocator,
            root,
            case_cfg,
            driver,
            &self.times,
            &self.allocations,
            &self.rss,
        );
    }
};

const MeasuredPair = struct {
    baseline: Metrics,
    candidate: Metrics,

    fn deinit(self: *MeasuredPair, allocator: std.mem.Allocator) void {
        self.baseline.deinit(allocator);
        self.candidate.deinit(allocator);
    }
};

fn runPairedMeasuredCases(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    baseline_case: CompatCase,
    candidate_case: CompatCase,
) !PairedMetrics {
    if (baseline_case.samples != candidate_case.samples or
        baseline_case.warmups != candidate_case.warmups)
    {
        return error.MismatchedPairedPerfCase;
    }
    const baseline_root = try makeTempRoot(fs, allocator, "paired-baseline");
    defer releaseTempRoot(fs, allocator, baseline_root, retainPairedWorkloads(environ));
    const candidate_root = try makeTempRoot(fs, allocator, "paired-candidate");
    defer releaseTempRoot(fs, allocator, candidate_root, retainPairedWorkloads(environ));
    try prepareCompatCase(fs, environ, allocator, baseline_case, baseline_root);
    try prepareCompatCase(fs, environ, allocator, candidate_case, candidate_root);
    const baseline_execution = try measuredOutputEvidenceOnce(
        fs,
        environ,
        allocator,
        baseline_case,
        baseline_root,
    );
    const candidate_execution = try measuredOutputEvidenceOnce(
        fs,
        environ,
        allocator,
        candidate_case,
        candidate_root,
    );
    try requireExecutionParity(baseline_execution, candidate_execution);
    const baseline_workload =
        try observedWorkloadDigest(fs, environ, allocator, baseline_case, baseline_root);
    const candidate_workload = try observedWorkloadDigest(
        fs,
        environ,
        allocator,
        candidate_case,
        candidate_root,
    );
    try requirePairedWorkload(
        fs.io,
        baseline_workload,
        candidate_workload,
        baseline_root,
        candidate_root,
    );
    const measured = try measureCompatPair(
        fs,
        environ,
        allocator,
        baseline_case,
        candidate_case,
        baseline_root,
        candidate_root,
    );
    return .{
        .baseline = measured.baseline,
        .candidate = measured.candidate,
        .workload_digest = baseline_workload,
        .baseline_execution = baseline_execution,
        .candidate_execution = candidate_execution,
    };
}

fn requirePairedWorkload(
    io: std.Io,
    baseline: [64]u8,
    candidate: [64]u8,
    baseline_root: []const u8,
    candidate_root: []const u8,
) !void {
    if (std.mem.eql(u8, &baseline, &candidate)) return;
    var stderr_writer = std.Io.File.stderr().writer(
        io,
        &.{},
    );
    try stderr_writer.interface.print(
        "paired workload mismatch: baseline=sha256:{s} " ++
            "candidate=sha256:{s} baseline_root={s} candidate_root={s}\n",
        .{ baseline, candidate, baseline_root, candidate_root },
    );
    return error.PerfWorkloadMismatch;
}

fn measureCompatPair(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    baseline_case: CompatCase,
    candidate_case: CompatCase,
    baseline_root: []const u8,
    candidate_root: []const u8,
) !MeasuredPair {
    const count = std.math.mul(usize, baseline_case.samples, paired_comparison_rounds) catch
        return error.PerfSampleCountOverflow;
    var baseline_samples = try MetricSamples.init(allocator, count, count, count);
    defer baseline_samples.deinit(allocator);
    var candidate_samples = try MetricSamples.init(allocator, count, count, count);
    defer candidate_samples.deinit(allocator);
    for (0..baseline_case.warmups) |_| {
        try runCompatWarmup(fs, environ, allocator, baseline_case, baseline_root);
        try runCompatWarmup(fs, environ, allocator, candidate_case, candidate_root);
    }
    for (0..count) |sample_idx| {
        if (sample_idx % 2 == 0) {
            try baseline_samples.appendCompat(fs, environ, allocator, baseline_case, baseline_root);
            try candidate_samples.appendCompat(
                fs,
                environ,
                allocator,
                candidate_case,
                candidate_root,
            );
        } else {
            try candidate_samples.appendCompat(
                fs,
                environ,
                allocator,
                candidate_case,
                candidate_root,
            );
            try baseline_samples.appendCompat(fs, environ, allocator, baseline_case, baseline_root);
        }
    }
    var baseline = try baseline_samples.finish(allocator);
    errdefer baseline.deinit(allocator);
    return .{ .baseline = baseline, .candidate = try candidate_samples.finish(allocator) };
}

fn runPairedDeepCases(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    built: *BuiltState,
    case_cfg: DeepCase,
    baseline_evidence: BinaryEvidence,
    candidate_evidence: BinaryEvidence,
) !PairedMetrics {
    try requireBinaryUnchanged(fs, baseline_evidence);
    try requireBinaryUnchanged(fs, candidate_evidence);
    var baseline_driver = try loadDeepDriver(
        fs,
        environ,
        allocator,
        built,
        baseline_evidence,
        case_cfg.driver_kind,
        "baseline",
    );
    errdefer baseline_driver.deinit(allocator);
    var candidate_driver = try loadDeepDriver(
        fs,
        environ,
        allocator,
        built,
        candidate_evidence,
        case_cfg.driver_kind,
        "candidate",
    );
    errdefer candidate_driver.deinit(allocator);
    try requireBinaryUnchanged(fs, baseline_evidence);
    try requireBinaryUnchanged(fs, candidate_evidence);
    if (case_cfg.driver_kind == .optimization) return runOptimizationMeasurements(
        fs,
        environ,
        allocator,
        case_cfg,
        baseline_evidence,
        candidate_evidence,
        baseline_driver,
        candidate_driver,
    );
    return runSeqReplayMeasurements(
        fs,
        environ,
        allocator,
        case_cfg,
        baseline_evidence,
        candidate_evidence,
        baseline_driver,
        candidate_driver,
    );
}

fn runSeqReplayMeasurements(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    baseline_evidence: BinaryEvidence,
    candidate_evidence: BinaryEvidence,
    baseline_driver: DriverEvidence,
    candidate_driver: DriverEvidence,
) !PairedMetrics {
    const baseline_root = baseline_evidence.source_root;
    const candidate_root = candidate_evidence.source_root;
    const baseline_workload = deepWorkloadDigestForRoot(
        fs,
        allocator,
        baseline_root,
        case_cfg,
    ) catch |err|
        return deepStageError(fs.io, "baseline-workload", err);
    const candidate_workload = deepWorkloadDigestForRoot(
        fs,
        allocator,
        candidate_root,
        case_cfg,
    ) catch |err|
        return deepStageError(fs.io, "candidate-workload", err);
    if (!std.mem.eql(u8, &baseline_workload, &candidate_workload)) {
        return error.PerfWorkloadMismatch;
    }
    const semantics = try deepSemanticPair(
        fs,
        environ,
        allocator,
        baseline_evidence,
        candidate_evidence,
    );
    var measured = try measureDeepPair(
        fs,
        environ,
        allocator,
        case_cfg,
        baseline_root,
        candidate_root,
        baseline_driver,
        candidate_driver,
    );
    errdefer measured.deinit(allocator);
    try requireBinaryUnchanged(fs, baseline_evidence);
    try requireBinaryUnchanged(fs, candidate_evidence);
    try requireFinalDeepWorkloads(
        fs,
        allocator,
        case_cfg,
        baseline_root,
        candidate_root,
        baseline_workload,
        candidate_workload,
    );
    return .{
        .baseline = measured.baseline,
        .candidate = measured.candidate,
        .workload_digest = baseline_workload,
        .baseline_execution = semantics[0],
        .candidate_execution = semantics[1],
        .baseline_driver = baseline_driver,
        .candidate_driver = candidate_driver,
    };
}

fn loadDeepDriver(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    built: *BuiltState,
    evidence: BinaryEvidence,
    kind: DriverKind,
    comptime side: []const u8,
) !DriverEvidence {
    const source = ensureSourceBuilt(
        fs,
        environ,
        allocator,
        built,
        evidence.source_root,
        evidence.source_sha,
        kind,
    ) catch |err| return deepStageError(fs.io, side ++ "-driver-build", err);
    return driverEvidence(allocator, source.*);
}

const OptimizationOracle = struct {
    workload_digest: [64]u8,
    execution: MeasuredOutputEvidence,
};

const OptimizationOracleWire = struct {
    case_id: []const u8,
    workload_sha256: []const u8,
    output_sha256: []const u8,
};

fn optimizationOracle(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    driver_file: SealedFile,
    case_id: []const u8,
) !OptimizationOracle {
    try verifySealedFile(fs, driver_file);
    const result = try runChildCaptureOutput(
        fs,
        environ,
        allocator,
        ".",
        &.{ driver_file.path, "oracle", "--target", case_id },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.OptimizationOracleFailed;
    var parsed = try std.json.parseFromSlice(OptimizationOracleWire, allocator, result.stdout, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, case_id, parsed.value.case_id)) return error.DeepArtifactIdentityMismatch;
    const workload = try rawSha256Digest(parsed.value.workload_sha256);
    const output = try rawSha256Digest(parsed.value.output_sha256);
    try verifySealedFile(fs, driver_file);
    return .{
        .workload_digest = workload,
        .execution = .{ .output_sha256 = output, .semantic_output_sha256 = output },
    };
}

fn rawSha256Digest(raw: []const u8) ![64]u8 {
    if (raw.len != 64) return error.InvalidPerfEvidenceFile;
    for (raw) |byte| if (!std.ascii.isHex(byte)) return error.InvalidPerfEvidenceFile;
    var digest: [64]u8 = undefined;
    @memcpy(&digest, raw);
    return digest;
}

fn runOptimizationMeasurements(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    baseline_evidence: BinaryEvidence,
    candidate_evidence: BinaryEvidence,
    baseline_driver: DriverEvidence,
    candidate_driver: DriverEvidence,
) !PairedMetrics {
    if (builtin.target.os.tag != .macos or builtin.target.cpu.arch != .aarch64) {
        return error.UnsupportedOptimizationMeasurement;
    }
    const baseline = try optimizationOracle(
        fs,
        environ,
        allocator,
        baseline_driver.file,
        case_cfg.descriptor.case_id,
    );
    const candidate = try optimizationOracle(
        fs,
        environ,
        allocator,
        candidate_driver.file,
        case_cfg.descriptor.case_id,
    );
    try requireOptimizationParity(baseline, candidate);
    var measured = try measureDeepPair(
        fs,
        environ,
        allocator,
        case_cfg,
        baseline_evidence.source_root,
        candidate_evidence.source_root,
        baseline_driver,
        candidate_driver,
    );
    errdefer measured.deinit(allocator);
    try requireBinaryUnchanged(fs, baseline_evidence);
    try requireBinaryUnchanged(fs, candidate_evidence);
    try requireOptimizationUnchanged(fs, environ, allocator, case_cfg, baseline_driver, baseline);
    try requireOptimizationUnchanged(fs, environ, allocator, case_cfg, candidate_driver, candidate);
    return .{
        .baseline = measured.baseline,
        .candidate = measured.candidate,
        .workload_digest = baseline.workload_digest,
        .baseline_execution = baseline.execution,
        .candidate_execution = candidate.execution,
        .baseline_driver = baseline_driver,
        .candidate_driver = candidate_driver,
    };
}

fn requireOptimizationParity(baseline: OptimizationOracle, candidate: OptimizationOracle) !void {
    if (!std.mem.eql(u8, &baseline.workload_digest, &candidate.workload_digest)) {
        return error.PerfWorkloadMismatch;
    }
    try requireExecutionParity(baseline.execution, candidate.execution);
}

fn requireOptimizationUnchanged(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    driver: DriverEvidence,
    original: OptimizationOracle,
) !void {
    try requireDriverUnchanged(fs, driver);
    const current = try optimizationOracle(
        fs,
        environ,
        allocator,
        driver.file,
        case_cfg.descriptor.case_id,
    );
    try requireOptimizationParity(original, current);
    try requireDriverUnchanged(fs, driver);
}

fn deepSemanticPair(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    baseline: BinaryEvidence,
    candidate: BinaryEvidence,
) ![2]MeasuredOutputEvidence {
    // Verify each physical identity before normalizing its absolute-path component.
    const baseline_semantic = productDeepSemanticOutputEvidence(
        fs,
        environ,
        allocator,
        baseline.file.path,
        baseline.source_root,
    ) catch |err| return deepStageError(fs.io, "baseline-semantic", err);
    const candidate_semantic = productDeepSemanticOutputEvidence(
        fs,
        environ,
        allocator,
        candidate.file.path,
        candidate.source_root,
    ) catch |err| return deepStageError(fs.io, "candidate-semantic", err);
    if (!std.mem.eql(u8, &baseline_semantic.output_sha256, &candidate_semantic.output_sha256)) {
        return error.PerfSemanticOutputMismatch;
    }
    return .{ baseline_semantic, candidate_semantic };
}

fn requireFinalDeepWorkloads(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    baseline_root: []const u8,
    candidate_root: []const u8,
    baseline_workload: [64]u8,
    candidate_workload: [64]u8,
) !void {
    const baseline = deepWorkloadDigestForRoot(fs, allocator, baseline_root, case_cfg) catch |err|
        return deepStageError(fs.io, "baseline-workload-final", err);
    const candidate = deepWorkloadDigestForRoot(fs, allocator, candidate_root, case_cfg) catch |err|
        return deepStageError(fs.io, "candidate-workload-final", err);
    if (!std.mem.eql(u8, &baseline_workload, &baseline) or
        !std.mem.eql(u8, &candidate_workload, &candidate)) return error.PerfWorkloadChanged;
}

fn measureDeepPair(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    baseline_root: []const u8,
    candidate_root: []const u8,
    baseline_driver: DriverEvidence,
    candidate_driver: DriverEvidence,
) !MeasuredPair {
    const count = std.math.mul(usize, case_cfg.samples, paired_comparison_rounds) catch
        return error.PerfSampleCountOverflow;
    const rounds = paired_comparison_rounds;
    var baseline_samples = try MetricSamples.init(allocator, count, rounds, rounds);
    defer baseline_samples.deinit(allocator);
    var candidate_samples = try MetricSamples.init(allocator, count, count, rounds);
    defer candidate_samples.deinit(allocator);
    try primeDeepPair(
        fs,
        environ,
        allocator,
        case_cfg,
        baseline_root,
        candidate_root,
        baseline_driver,
        candidate_driver,
    );
    for (0..rounds) |round| {
        if (round % 2 == 0) {
            try baseline_samples.appendDeep(
                fs,
                environ,
                allocator,
                case_cfg,
                baseline_root,
                baseline_driver,
            );
            try candidate_samples.appendDeep(
                fs,
                environ,
                allocator,
                case_cfg,
                candidate_root,
                candidate_driver,
            );
        } else {
            try candidate_samples.appendDeep(
                fs,
                environ,
                allocator,
                case_cfg,
                candidate_root,
                candidate_driver,
            );
            try baseline_samples.appendDeep(
                fs,
                environ,
                allocator,
                case_cfg,
                baseline_root,
                baseline_driver,
            );
        }
    }
    var baseline = try baseline_samples.finish(allocator);
    errdefer baseline.deinit(allocator);
    return .{ .baseline = baseline, .candidate = try candidate_samples.finish(allocator) };
}

fn primeDeepPair(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    baseline_root: []const u8,
    candidate_root: []const u8,
    baseline_driver: DriverEvidence,
    candidate_driver: DriverEvidence,
) !void {
    primeSourceDeepCase(
        fs,
        environ,
        allocator,
        baseline_root,
        case_cfg,
        baseline_driver,
    ) catch |err|
        return deepStageError(fs.io, "baseline-prime", err);
    primeSourceDeepCase(
        fs,
        environ,
        allocator,
        candidate_root,
        case_cfg,
        candidate_driver,
    ) catch |err|
        return deepStageError(fs.io, "candidate-prime", err);
}

fn deepStageError(io: std.Io, stage: []const u8, err: anyerror) anyerror {
    printDiagnostic(
        io,
        "perf_hub deep stage={s} error={s}\n",
        .{ stage, @errorName(err) },
    );
    return err;
}

fn primeSourceDeepCase(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    case_cfg: DeepCase,
    driver: DriverEvidence,
) !void {
    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(allocator);
    var alloc_samples: std.ArrayList(u64) = .empty;
    defer alloc_samples.deinit(allocator);
    var rss_samples: std.ArrayList(u64) = .empty;
    defer rss_samples.deinit(allocator);
    try appendSourceDeepMetrics(
        fs,
        environ,
        allocator,
        source_root,
        case_cfg,
        driver,
        &samples,
        &alloc_samples,
        &rss_samples,
    );
}

fn ensureSourceBuilt(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    built: *BuiltState,
    source_root: []const u8,
    expected_source_sha: []const u8,
    kind: DriverKind,
) !*const BuiltSource {
    if (!validFullRevision(expected_source_sha)) return error.DriverSourceRevisionMismatch;
    const key = try allocator.print(
        "{s}:isolated-source:{s}",
        .{ source_root, @tagName(kind) },
    );
    defer allocator.free(key);
    if (built.sources.getPtr(key)) |driver| {
        if (!std.mem.eql(u8, driver.source_sha, expected_source_sha)) {
            return error.DriverSourceRevisionMismatch;
        }
        return driver;
    }
    try requireCleanSourceRoot(fs, environ, allocator, source_root);
    const observed_source_sha = try sourceShaForRootAlloc(fs, environ, allocator, source_root);
    defer allocator.free(observed_source_sha);
    if (!std.mem.eql(u8, observed_source_sha, expected_source_sha)) {
        return error.DriverSourceRevisionMismatch;
    }
    const source_tree_sha = try sourceTreeShaForRootAlloc(fs, environ, allocator, source_root);
    defer allocator.free(source_tree_sha);
    var source = try buildIsolatedSource(
        fs,
        environ,
        allocator,
        source_root,
        expected_source_sha,
        source_tree_sha,
        kind,
    );
    errdefer source.deinit(allocator);
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try built.sources.put(owned_key, source);
    return built.sources.getPtr(key) orelse unreachable;
}

fn buildIsolatedSource(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    root: []const u8,
    revision: []const u8,
    tree: []const u8,
    kind: DriverKind,
) !BuiltSource {
    const machine = try absoluteMachineDir(fs, allocator);
    defer allocator.free(machine);
    const driver_bytes = driverSourceBytes(kind);
    var driver_file = try sealDriverSource(fs, allocator, machine, driver_bytes, kind);
    errdefer driver_file.deinit(allocator);
    var build_file = try sealDriverBuildSource(fs, allocator, machine, kind);
    errdefer if (build_file) |*file| file.deinit(allocator);
    const staging = try sourceStagingDir(fs, allocator, machine, revision);
    defer allocator.free(staging);
    defer removeBuildStaging(fs, staging);
    var compiler = try approvedCompilerEvidence(fs, environ, allocator, machine);
    errdefer compiler.deinit(allocator);
    const snapshot = try std.fs.path.join(allocator, &.{ staging, "source" });
    defer allocator.free(snapshot);
    var archive = try snapshotProductSource(
        fs,
        environ,
        allocator,
        root,
        revision,
        machine,
        staging,
        snapshot,
    );
    errdefer archive.deinit(allocator);
    const prefix = try std.fs.path.join(allocator, &.{ snapshot, "zig-out" });
    defer allocator.free(prefix);
    const zig = compiler.approved_path;
    try runIsolatedBuild(fs, environ, allocator, snapshot, staging, prefix, zig, "", kind);
    try requireBuildSourceUnchanged(fs, environ, allocator, root, revision, tree);
    try verifySealedFile(fs, compiler.file);
    try requireCompilerDigestAtPath(fs, compiler.approved_path, &compiler.file.sha256);
    var seq = try sealBuiltExecutable(fs, allocator, machine, prefix, "seq");
    errdefer seq.deinit(allocator);
    var ledger = try sealBuiltExecutable(fs, allocator, machine, prefix, "ledger");
    errdefer ledger.deinit(allocator);
    try overlayReplayDriver(fs, allocator, snapshot, driver_bytes, driver_file);
    if (build_file) |file| try overlayDriverBuild(fs, allocator, snapshot, file);
    try runIsolatedBuild(fs, environ, allocator, snapshot, staging, prefix, zig, "driver-", kind);
    try verifySealedFile(fs, driver_file);
    if (build_file) |file| try verifySealedFile(fs, file);
    try requireCompilerDigestAtPath(fs, compiler.approved_path, &compiler.file.sha256);
    var driver = try sealBuiltExecutable(fs, allocator, machine, prefix, "perf_hub");
    errdefer driver.deinit(allocator);
    try requireBuildSourceUnchanged(fs, environ, allocator, root, revision, tree);
    try verifySealedFile(fs, compiler.file);
    return ownBuiltSource(
        allocator,
        revision,
        tree,
        seq,
        ledger,
        driver,
        archive,
        driver_file,
        compiler,
        kind,
        build_file,
    );
}

fn absoluteMachineDir(fs: durable_store.Fs, allocator: std.mem.Allocator) ![:0]u8 {
    const relative = try ensureCurrentMachineDir(fs, allocator);
    defer allocator.free(relative);
    return fs.directory().realPathFileAlloc(
        fs.io,
        relative,
        allocator,
    );
}

fn sealDriverSource(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    bytes: []const u8,
    kind: DriverKind,
) !SealedFile {
    const digest = evidenceDigest(bytes);
    if (!std.mem.eql(u8, &digest, driverIdentity(kind).sha256)) {
        return error.DriverSourceRevisionMismatch;
    }
    return sealEvidenceBytes(fs, allocator, machine_dir, "perf_hub.zig", bytes, 0o400);
}

fn sealDriverBuildSource(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    kind: DriverKind,
) !?SealedFile {
    if (kind != .optimization) return null;
    return try sealEvidenceBytes(
        fs,
        allocator,
        machine_dir,
        "optimization_build.zig",
        optimization_build_source,
        0o400,
    );
}

fn overlayDriverBuild(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    snapshot: []const u8,
    build_file: SealedFile,
) !void {
    const path = try std.fs.path.join(allocator, &.{ snapshot, "build.zig" });
    defer allocator.free(path);
    const original = try readRegularFileAlloc(
        fs,
        allocator,
        path,
        max_sealed_evidence_bytes,
    );
    defer allocator.free(original);
    const product_path = try std.fs.path.join(allocator, &.{ snapshot, "build_product.zig" });
    defer allocator.free(product_path);
    try writeEvidenceFileAtomic(fs, allocator, product_path, original, 0o400);
    const product_digest = try sha256FileBounded(fs, product_path, max_sealed_evidence_bytes);
    const original_digest = evidenceDigest(original);
    if (!std.mem.eql(u8, &product_digest, &original_digest)) {
        return error.DriverSourceChangedDuringBuild;
    }
    try verifySealedFile(fs, build_file);
    try writeEvidenceFileAtomic(fs, allocator, path, optimization_build_source, 0o400);
    const digest = try sha256FileBounded(fs, path, max_sealed_evidence_bytes);
    if (!std.mem.eql(u8, &digest, &build_file.sha256)) return error.DriverSourceChangedDuringBuild;
}

fn sourceStagingDir(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    source_sha: []const u8,
) ![]u8 {
    const root = try std.fs.path.join(allocator, &.{ machine_dir, "capsules", "staging" });
    defer allocator.free(root);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, root);
    const now = std.Io.Clock.awake.now(fs.io).nanoseconds;
    const staging = try allocator.print(
        "{s}/.build-{s}-{d}",
        .{ root, source_sha[0..@min(source_sha.len, 12)], now },
    );
    errdefer allocator.free(staging);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, staging);
    return staging;
}

fn removeBuildStaging(fs: durable_store.Fs, staging: []const u8) void {
    fs.directory().deleteTree(fs.io, staging) catch |err| {
        printDiagnostic(
            fs.io,
            "perf_hub warning: remove staging directory: {s}\n",
            .{@errorName(err)},
        );
    };
}

fn snapshotProductSource(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    source_sha: []const u8,
    machine_dir: []const u8,
    staging_dir: []const u8,
    snapshot: []const u8,
) !SealedFile {
    const archive_path = try std.fs.path.join(allocator, &.{ staging_dir, "source.tar" });
    defer allocator.free(archive_path);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, snapshot);
    const result = try runChildCapture(
        fs,
        environ,
        allocator,
        source_root,
        &.{ git_binary, "archive", "--format=tar", "--output", archive_path, source_sha },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.SourceSnapshotFailed;
    var archive = try sealEvidenceFile(
        fs,
        allocator,
        machine_dir,
        "source.tar",
        archive_path,
        max_sealed_evidence_bytes,
        0o600,
    );
    errdefer archive.deinit(allocator);
    const extract = try runChildCapture(
        fs,
        environ,
        allocator,
        staging_dir,
        &.{ "/usr/bin/tar", "-xf", archive.path, "-C", snapshot },
    );
    defer allocator.free(extract.stdout);
    defer allocator.free(extract.stderr);
    if (extract.exit_code != 0) return error.SourceSnapshotFailed;
    return archive;
}

fn runIsolatedBuild(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    snapshot: []const u8,
    staging_dir: []const u8,
    prefix: []const u8,
    compiler_path: []const u8,
    comptime cache_prefix: []const u8,
    kind: DriverKind,
) !void {
    const cache = try std.fs.path.join(allocator, &.{ staging_dir, cache_prefix ++ "cache" });
    defer allocator.free(cache);
    const global = try std.fs.path.join(
        allocator,
        &.{ staging_dir, cache_prefix ++ "global-cache" },
    );
    defer allocator.free(global);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, prefix);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, cache);
    const packages = try std.fs.path.join(
        allocator,
        &.{ staging_dir, cache_prefix ++ "packages" },
    );
    defer allocator.free(packages);
    const global_tmp = try std.fs.path.join(allocator, &.{ global, "tmp" });
    defer allocator.free(global_tmp);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, global_tmp);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, packages);
    const global_env = try allocator.print("ZIG_GLOBAL_CACHE_DIR={s}", .{global});
    defer allocator.free(global_env);
    const packages_env = try allocator.print("ZIG_LOCAL_PKG_DIR={s}", .{packages});
    defer allocator.free(packages_env);
    const argv = [_][]const u8{
        "/usr/bin/env",
        global_env,
        packages_env,
        compiler_path,
        "build",
        "-Doptimize=fast",
        "--prefix",
        prefix,
        "--cache-dir",
        cache,
    };
    const driver_argv = argv ++ [_][]const u8{
        "optimization-driver", "-Dtarget=aarch64-macos", "-Dcpu=baseline",
    };
    const command = if (kind == .optimization and cache_prefix.len != 0) &driver_argv else &argv;
    const result = try runChildCapture(fs, environ, allocator, snapshot, command);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BuildFailed;
}

fn requireBuildSourceUnchanged(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    source_sha: []const u8,
    source_tree_sha: []const u8,
) !void {
    requireSourceIdentityUnchanged(
        fs,
        environ,
        allocator,
        source_root,
        source_sha,
        source_tree_sha,
    ) catch |err| {
        return if (err == error.ProductSourceChanged) error.DriverSourceChangedDuringBuild else err;
    };
}

fn sealBuiltExecutable(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    prefix: []const u8,
    name: []const u8,
) !SealedFile {
    const path = try std.fs.path.join(allocator, &.{ prefix, "bin", name });
    defer allocator.free(path);
    return sealEvidenceFile(fs, allocator, machine_dir, name, path, 16 * 1024 * 1024, 0o500);
}

fn overlayReplayDriver(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    snapshot: []const u8,
    bytes: []const u8,
    source: SealedFile,
) !void {
    const path = try std.fs.path.join(allocator, &.{ snapshot, driver_overlay_path });
    defer allocator.free(path);
    try writeEvidenceFileAtomic(fs, allocator, path, bytes, 0o400);
    const digest = try sha256FileBounded(fs, path, max_sealed_evidence_bytes);
    if (!std.mem.eql(u8, &digest, &source.sha256)) return error.DriverSourceChangedDuringBuild;
}

fn ownBuiltSource(
    allocator: std.mem.Allocator,
    source_sha: []const u8,
    source_tree_sha: []const u8,
    seq: SealedFile,
    ledger: SealedFile,
    driver: SealedFile,
    archive: SealedFile,
    driver_source: SealedFile,
    compiler: CompilerEvidence,
    kind: DriverKind,
    build_file: ?SealedFile,
) !BuiltSource {
    const owned_sha = try allocator.dupe(u8, source_sha);
    errdefer allocator.free(owned_sha);
    const owned_tree = try allocator.dupe(u8, source_tree_sha);
    errdefer allocator.free(owned_tree);
    const driver_tree = try allocator.dupe(u8, driverIdentity(kind).tree);
    errdefer allocator.free(driver_tree);
    return .{
        .driver_kind = kind,
        .driver_build_source_file = build_file,
        .seq = seq,
        .ledger = ledger,
        .perf_hub = driver,
        .source_sha = owned_sha,
        .source_tree_sha = owned_tree,
        .source_archive = archive,
        .driver_source_tree_sha = driver_tree,
        .driver_source_file = driver_source,
        .compiler = compiler,
    };
}

fn validFullRevision(revision: []const u8) bool {
    if (revision.len != 40 and revision.len != 64) return false;
    for (revision) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn sourceTreeShaForRootAlloc(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
) ![]u8 {
    return revisionTreeShaForRootAlloc(
        fs,
        environ,
        allocator,
        source_root,
        "HEAD",
    );
}

fn revisionTreeShaForRootAlloc(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    revision: []const u8,
) ![]u8 {
    const tree_revision = try allocator.print(
        "{s}^{{tree}}",
        .{revision},
    );
    defer allocator.free(tree_revision);
    const result = try runChildCaptureOutput(
        fs,
        environ,
        allocator,
        ".",
        &.{ git_binary, "-C", source_root, "rev-parse", tree_revision },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BinarySourceUnavailable;
    const tree = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!validFullRevision(tree)) return error.BinarySourceUnavailable;
    return allocator.dupe(u8, tree);
}

fn deepWorkloadDigestForRoot(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    case_cfg: DeepCase,
) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(case_cfg.descriptor.case_id);
    hasher.update(&.{0});
    hasher.update(@tagName(case_cfg.setup));
    hasher.update(&.{0});
    var encoded: [32]u8 = undefined;
    const batch_text = try std.fmt.bufPrint(
        &encoded,
        "{d}",
        .{case_cfg.batch_iterations},
    );
    hasher.update(batch_text);
    for ([_][]const u8{
        "apps/seq/src/v1/fixtures/message-observation.json",
        "apps/seq/src/v1/fixtures/rollout.jsonl",
    }) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ source_root, relative_path });
        defer allocator.free(path);
        const bytes = try fs.directory().readFileAlloc(
            fs.io,
            path,
            allocator,
            .limited(4 * 1024 * 1024),
        );
        defer allocator.free(bytes);
        hasher.update(&.{0});
        hasher.update(relative_path);
        hasher.update(&.{0});
        hasher.update(bytes);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn appendSourceDeepMetrics(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    source_root: []const u8,
    case_cfg: DeepCase,
    driver: DriverEvidence,
    samples: *std.ArrayList(u64),
    alloc_samples: *std.ArrayList(u64),
    rss_samples: *std.ArrayList(u64),
) !void {
    requireDriverUnchanged(fs, driver) catch |err|
        return deepStageError(fs.io, "driver-preflight", err);
    const artifact_path = try sourceDeepArtifactPath(allocator, source_root, case_cfg);
    defer allocator.free(artifact_path);
    fs.directory().deleteFile(
        fs.io,
        artifact_path,
    ) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const result = runChildCaptureOutput(
        fs,
        environ,
        allocator,
        source_root,
        &.{
            driver.file.path,
            "capture",
            "--target",
            case_cfg.descriptor.case_id,
        },
    ) catch |err| return deepStageError(fs.io, "driver-spawn", err);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
    validateCaptureAcknowledgment(
        allocator,
        result.stdout,
        case_cfg.descriptor.case_id,
    ) catch |err| return deepStageError(fs.io, "driver-acknowledgment", err);
    requireDriverUnchanged(fs, driver) catch |err|
        return deepStageError(fs.io, "driver-postflight", err);
    const bytes = try fs.directory().readFileAlloc(
        fs.io,
        artifact_path,
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try validateSharedDriverArtifact(parsed.value, case_cfg, driver.product_source_sha);
    const metrics = try captureMetricsObject(parsed.value);
    const raw_samples = switch (metrics.get("samples_ns") orelse return error.InvalidData) {
        .array => |value| value.items,
        else => return error.InvalidData,
    };
    if (raw_samples.len != case_cfg.samples) return error.DeepMeasurementSampleCountMismatch;
    if (case_cfg.driver_kind == .optimization) {
        try validateOptimizationCapture(fs, environ, allocator, parsed.value, case_cfg, driver);
    }
    for (raw_samples) |raw| try samples.append(allocator, try jsonValueU64(raw, "samples_ns"));
    const batch_allocs = try jsonFieldU64(metrics, "p50_alloc_calls");
    try alloc_samples.append(allocator, batch_allocs / case_cfg.batch_iterations);
    try rss_samples.append(allocator, result.peak_rss_bytes orelse return error.MissingPeakRss);
}

fn captureMetricsObject(artifact: std.json.Value) !std.json.ObjectMap {
    const object = switch (artifact) {
        .object => |value| value,
        else => return error.InvalidData,
    };
    return switch (object.get("metrics") orelse return error.InvalidData) {
        .object => |value| value,
        else => return error.InvalidData,
    };
}

fn validateOptimizationCapture(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    artifact: std.json.Value,
    case_cfg: DeepCase,
    driver: DriverEvidence,
) !void {
    const oracle = try optimizationOracle(
        fs,
        environ,
        allocator,
        driver.file,
        case_cfg.descriptor.case_id,
    );
    const workload = try artifactDigest(artifact, "workload_sha256");
    const output = try artifactDigest(artifact, "output_sha256");
    if (!std.mem.eql(u8, &workload, &oracle.workload_digest) or
        !std.mem.eql(u8, &output, &oracle.execution.output_sha256))
    {
        return error.PerfSemanticOutputMismatch;
    }
    try requireDriverUnchanged(fs, driver);
}

fn artifactDigest(artifact: std.json.Value, name: []const u8) ![64]u8 {
    const object = switch (artifact) {
        .object => |value| value,
        else => return error.InvalidData,
    };
    const raw = switch (object.get(name) orelse return error.InvalidData) {
        .string => |value| value,
        else => return error.InvalidData,
    };
    return rawSha256Digest(raw);
}

fn sourceDeepArtifactPath(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    case_cfg: DeepCase,
) ![]u8 {
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const artifact_name = try allocator.print(
        "{s}.json",
        .{case_cfg.descriptor.case_id},
    );
    defer allocator.free(artifact_name);
    return std.fs.path.join(
        allocator,
        &.{
            source_root,
            ".perf-local",
            machine_name,
            "baselines",
            case_cfg.descriptor.binary,
            artifact_name,
        },
    );
}

fn validateCaptureAcknowledgment(
    allocator: std.mem.Allocator,
    raw: []const u8,
    case_id: []const u8,
) !void {
    const expected = try allocator.print(
        "PASS\t{s}\tcaptured",
        .{case_id},
    );
    defer allocator.free(expected);
    if (std.mem.eql(u8, raw, expected)) return;
    if (raw.len == expected.len + 1 and raw[expected.len] == '\n' and
        std.mem.eql(u8, raw[0..expected.len], expected)) return;
    if (raw.len == expected.len + 2 and
        std.mem.eql(u8, raw[expected.len..], "\r\n") and
        std.mem.eql(u8, raw[0..expected.len], expected)) return;
    return error.InvalidPerfCaptureAcknowledgment;
}

fn validateSharedDriverArtifact(
    artifact: std.json.Value,
    case_cfg: DeepCase,
    product_source_sha: []const u8,
) !void {
    const object = switch (artifact) {
        .object => |value| value,
        else => return error.InvalidDeepArtifactIdentity,
    };
    const case_id = switch (object.get("case_id") orelse
        return error.InvalidDeepArtifactIdentity) {
        .string => |value| value,
        else => return error.InvalidDeepArtifactIdentity,
    };
    const binary = switch (object.get("binary") orelse
        return error.InvalidDeepArtifactIdentity) {
        .string => |value| value,
        else => return error.InvalidDeepArtifactIdentity,
    };
    const git_sha = switch (object.get("git_sha") orelse
        return error.InvalidDeepArtifactIdentity) {
        .string => |value| value,
        else => return error.InvalidDeepArtifactIdentity,
    };
    const schema_version = try jsonFieldU64(
        object,
        "schema_version",
    );
    const source_matches = std.mem.eql(u8, git_sha, "unknown") or
        (git_sha.len > 0 and std.mem.startsWith(u8, product_source_sha, git_sha));
    if (!std.mem.eql(u8, case_id, case_cfg.descriptor.case_id) or
        !std.mem.eql(u8, binary, case_cfg.descriptor.binary) or
        !source_matches or schema_version != 1)
    {
        return error.DeepArtifactIdentityMismatch;
    }
}

const normalized_source_event_id =
    "sha256:0000000000000000000000000000000000000000000000000000000000000000";
const normalized_transaction_id = "DTX-normalized";

fn productDeepSemanticOutputEvidence(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    binary_path: []const u8,
    source_root: []const u8,
) !MeasuredOutputEvidence {
    const result = try runChildCaptureOutput(
        fs,
        environ,
        allocator,
        source_root,
        &.{
            binary_path,
            "observe",
            "--definition",
            "apps/seq/src/v1/fixtures/message-observation.json",
            "--projection",
            "rows",
            "--path",
            "apps/seq/src/v1/fixtures/rollout.jsonl",
            "--param",
            "needle=failure",
            "--format",
            "json",
        },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
    return canonicalDeepDataEvidence(allocator, result.stdout, source_root);
}

fn canonicalDeepDataEvidence(
    allocator: std.mem.Allocator,
    rendered: []const u8,
    source_root: []const u8,
) !MeasuredOutputEvidence {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |*value| value,
        else => return error.InvalidPerfSemanticOutput,
    };
    const data = root.getPtr("data") orelse
        return error.InvalidPerfSemanticOutput;
    const local_digest = try canonicalValueDigest(allocator, data.*);
    const data_object = switch (data.*) {
        .object => |*value| value,
        else => return error.InvalidPerfSemanticOutput,
    };
    const rows_value = data_object.getPtr("rows") orelse
        return error.InvalidPerfSemanticOutput;
    const rows = switch (rows_value.*) {
        .array => |*value| value,
        else => return error.InvalidPerfSemanticOutput,
    };
    if (rows.items.len != 1) return error.InvalidPerfSemanticOutput;
    const row = switch (rows.items[0]) {
        .object => |*value| value,
        else => return error.InvalidPerfSemanticOutput,
    };
    const source_event_id = row.getPtr("source_event_id") orelse
        return error.MissingPerfSourceEventIdentity;
    const encoded = switch (source_event_id.*) {
        .string => |value| value,
        else => return error.InvalidPerfSourceEventIdentity,
    };
    const fixture_path = try std.fs.path.join(
        allocator,
        &.{ source_root, "apps/seq/src/v1/fixtures/rollout.jsonl" },
    );
    defer allocator.free(fixture_path);
    const expected = expectedSourceEventId(fixture_path, 3, 2);
    if (!std.mem.eql(u8, encoded, &expected)) {
        return error.PerfSourceEventIdentityMismatch;
    }
    source_event_id.* = .{ .string = normalized_source_event_id };
    const normalized_digest = try canonicalValueDigest(allocator, data.*);
    return .{
        .output_sha256 = normalized_digest,
        .semantic_output_sha256 = normalized_digest,
        .local_output_sha256 = local_digest,
    };
}

fn expectedSourceEventId(path: []const u8, line_number: usize, ordinal: usize) [71]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("trace-source-event/v1\x00");
    hasher.update(path);
    var number: [8]u8 = undefined;
    std.mem.writeInt(u64, &number, @intCast(line_number), .big);
    hasher.update(&number);
    std.mem.writeInt(u64, &number, @intCast(ordinal), .big);
    hasher.update(&number);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var identity: [71]u8 = undefined;
    @memcpy(identity[0..7], "sha256:");
    @memcpy(identity[7..], &hex);
    return identity;
}

fn retainPairedWorkloads(environ: ?*const std.process.Environ.Map) bool {
    const environment = environ orelse return false;
    return environment.get("PERF_RETAIN_PAIRED_ROOTS") != null;
}

fn runCompatWarmup(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) !void {
    var run_arena = std.heap.ArenaAllocator.init(allocator);
    defer run_arena.deinit();
    const run = try renderCompatRun(
        fs,
        environ,
        run_arena.allocator(),
        case_cfg,
        temp_root,
    );
    const result = try runChildCapture(fs, environ, allocator, run.cwd, run.argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
}

fn appendCompatSample(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
    samples: *std.ArrayList(u64),
    alloc_samples: *std.ArrayList(u64),
    rss_samples: *std.ArrayList(u64),
) !void {
    var run_arena = std.heap.ArenaAllocator.init(allocator);
    defer run_arena.deinit();
    const run = try renderCompatRun(
        fs,
        environ,
        run_arena.allocator(),
        case_cfg,
        temp_root,
    );
    const start_ns = std.Io.Clock.awake.now(
        fs.io,
    ).nanoseconds;
    const result = try runChildCapture(fs, environ, allocator, run.cwd, run.argv);
    const elapsed: u64 = @intCast(@max(
        std.Io.Clock.awake.now(
            fs.io,
        ).nanoseconds - start_ns,
        1,
    ));
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
    try samples.append(allocator, elapsed);
    try alloc_samples.append(allocator, 0);
    try rss_samples.append(allocator, result.peak_rss_bytes orelse return error.MissingPeakRss);
}

fn validateMeasuredOutput(case_cfg: CompatCase, raw: []const u8) !void {
    if (!case_cfg.require_streamed_projection) return;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.PerfProjectionNotStreamed,
    };
    const stats = switch (root.get("stats") orelse
        return error.PerfProjectionNotStreamed) {
        .object => |value| value,
        else => return error.PerfProjectionNotStreamed,
    };
    const streamed = switch (stats.get("streamed") orelse
        return error.PerfProjectionNotStreamed) {
        .bool => |value| value,
        else => return error.PerfProjectionNotStreamed,
    };
    if (!streamed) return error.PerfProjectionNotStreamed;
}

fn requireExecutionParity(
    baseline: MeasuredOutputEvidence,
    candidate: MeasuredOutputEvidence,
) !void {
    if (!std.mem.eql(
        u8,
        &baseline.semantic_output_sha256,
        &candidate.semantic_output_sha256,
    )) return error.PerfSemanticOutputMismatch;
    if (baseline.streamed == true and candidate.streamed != true) {
        return error.PerfExecutionTopologyMismatch;
    }
    try requireOptionalEqual(baseline.records_emitted, candidate.records_emitted);
    for ([_][2]?u64{
        .{ baseline.records_scanned, candidate.records_scanned },
        .{ baseline.physical_passes, candidate.physical_passes },
        .{ baseline.files_opened, candidate.files_opened },
        .{ baseline.bytes_read, candidate.bytes_read },
        .{ baseline.rows_materialized, candidate.rows_materialized },
    }) |pair| {
        try requireOptionalNonIncreasing(pair[0], pair[1]);
    }
}

fn requireOptionalEqual(baseline: ?u64, candidate: ?u64) !void {
    if (baseline == null and candidate == null) return;
    if (baseline == null or candidate == null or
        baseline.? != candidate.?)
    {
        return error.PerfExecutionTopologyMismatch;
    }
}

fn requireOptionalNonIncreasing(baseline: ?u64, candidate: ?u64) !void {
    if (baseline == null and candidate == null) return;
    if (baseline == null or candidate == null or
        candidate.? > baseline.?)
    {
        return error.PerfExecutionTopologyMismatch;
    }
}

fn measuredOutputEvidenceOnce(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) !MeasuredOutputEvidence {
    var run_arena = std.heap.ArenaAllocator.init(allocator);
    defer run_arena.deinit();
    const run = try renderCompatRun(
        fs,
        environ,
        run_arena.allocator(),
        case_cfg,
        temp_root,
    );
    const result = try runChildCaptureOutput(fs, environ, allocator, run.cwd, run.argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
    try validateMeasuredOutput(case_cfg, result.stdout);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.stdout, &digest, .{});
    var evidence: MeasuredOutputEvidence = .{
        .output_sha256 = std.fmt.bytesToHex(digest, .lower),
        .semantic_output_sha256 = try semanticOutputDigest(allocator, result.stdout, temp_root),
    };
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        result.stdout,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return evidence,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return evidence,
    };
    const stats = switch (root.get("stats") orelse return evidence) {
        .object => |value| value,
        else => return evidence,
    };
    evidence.streamed = if (stats.get("streamed")) |value|
        switch (value) {
            .bool => |boolean| boolean,
            else => null,
        }
    else
        null;
    evidence.records_scanned = optionalU64(stats, "records_scanned");
    evidence.records_emitted = optionalU64(stats, "records_emitted");
    evidence.physical_passes = optionalU64(stats, "physical_passes");
    evidence.files_opened = optionalU64(stats, "files_opened");
    evidence.bytes_read = optionalU64(stats, "bytes_read");
    evidence.rows_materialized = optionalU64(stats, "rows_materialized");
    evidence.compile_ns = optionalU64(stats, "compile_ns");
    evidence.execution_ns = optionalU64(stats, "execution_ns");
    return evidence;
}

fn optionalU64(object: std.json.ObjectMap, field: []const u8) ?u64 {
    const value = object.get(field) orelse return null;
    return jsonValueU64(value, field) catch null;
}

fn semanticOutputDigest(
    allocator: std.mem.Allocator,
    raw: []const u8,
    temp_root: []const u8,
) ![64]u8 {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return evidenceDigest(raw),
    };
    defer parsed.deinit();
    try normalizeSemanticOutput(allocator, &parsed.value, raw.len);
    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        parsed.value,
    );
    defer allocator.free(canonical);
    const normalized = try std.mem.replaceOwned(
        u8,
        allocator,
        canonical,
        temp_root,
        "$PERF_ROOT",
    );
    defer allocator.free(normalized);
    return evidenceDigest(normalized);
}

const SemanticFrame = struct {
    value: *std.json.Value,
    next_index: usize = 0,
};

fn normalizeSemanticOutput(
    allocator: std.mem.Allocator,
    value: *std.json.Value,
    source_bytes: usize,
) !void {
    // A parsed tree has fewer nesting frames than source bytes. Each child is visited once.
    var frames: std.ArrayList(SemanticFrame) = .empty;
    defer frames.deinit(allocator);
    if (source_bytes == 0) return error.InvalidPerfSemanticOutput;
    try frames.append(allocator, .{ .value = value });
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (try nextSemanticChild(frame)) |child| {
            if (frames.items.len >= source_bytes) return error.InvalidPerfSemanticOutput;
            try frames.append(allocator, .{ .value = child });
        } else {
            frames.items.len -= 1;
        }
    }
}

fn nextSemanticChild(frame: *SemanticFrame) !?*std.json.Value {
    switch (frame.value.*) {
        .object => |*object| {
            while (frame.next_index < object.count()) {
                const index = frame.next_index;
                frame.next_index += 1;
                const child = &object.values()[index];
                if (try normalizeSemanticEntry(object.keys()[index], child)) return child;
            }
        },
        .array => |*array| {
            if (frame.next_index < array.items.len) {
                const index = frame.next_index;
                frame.next_index += 1;
                return &array.items[index];
            }
        },
        else => {},
    }
    return null;
}

fn normalizeSemanticEntry(key: []const u8, value: *std.json.Value) !bool {
    if (std.mem.eql(u8, key, "stats")) {
        switch (value.*) {
            .object => value.* = .null,
            else => return error.InvalidPerfSemanticOutput,
        }
        return false;
    }
    if (std.mem.eql(u8, key, "definition")) try normalizeDefinitionDigest(value);
    if (std.mem.eql(u8, key, "compile_ns") or
        std.mem.eql(u8, key, "execution_ns") or
        std.mem.eql(u8, key, "output_bytes"))
    {
        value.* = .{ .integer = 0 };
        return false;
    }
    if (std.mem.eql(u8, key, "source_event_id")) {
        const encoded = switch (value.*) {
            .string => |string| string,
            else => return error.InvalidPerfSemanticOutput,
        };
        if (!validSha256Identity(encoded)) return error.InvalidPerfSourceEventIdentity;
        value.* = .{ .string = normalized_source_event_id };
        return false;
    }
    if (std.mem.eql(u8, key, "transaction_id")) {
        switch (value.*) {
            .string => |string| if (string.len == 0) return error.InvalidPerfSemanticOutput,
            .null => return false,
            else => return error.InvalidPerfSemanticOutput,
        }
        value.* = .{ .string = normalized_transaction_id };
        return false;
    }
    return true;
}

fn normalizeDefinitionDigest(value: *std.json.Value) !void {
    const definition = switch (value.*) {
        .object => |*object| object,
        else => return error.InvalidPerfSemanticOutput,
    };
    const digest = definition.getPtr("digest") orelse return error.InvalidPerfSemanticOutput;
    const encoded = switch (digest.*) {
        .string => |string| string,
        else => return error.InvalidPerfSemanticOutput,
    };
    if (!validSha256Identity(encoded)) return error.InvalidPerfSemanticOutput;
    digest.* = .{ .string = normalized_source_event_id };
}

fn validSha256Identity(encoded: []const u8) bool {
    if (encoded.len != 71 or
        !std.mem.startsWith(u8, encoded, "sha256:"))
    {
        return false;
    }
    for (encoded["sha256:".len..]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn metricsFromSamples(
    allocator: std.mem.Allocator,
    samples: std.ArrayList(u64),
    alloc_samples: std.ArrayList(u64),
    rss_samples: std.ArrayList(u64),
) !Metrics {
    const latency = try core_perf.percentilesU64(allocator, samples.items, &.{ 50, 95 });
    return .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .rss_samples = rss_samples,
        .p50_ns = latency[0],
        .p95_ns = latency[1],
        .p50_alloc_calls = try core_perf.percentileU64(allocator, alloc_samples.items, 50),
        .p95_rss_bytes = try core_perf.percentileU64(allocator, rss_samples.items, 95),
    };
}

fn canonicalDataDigest(allocator: std.mem.Allocator, rendered: []const u8) ![64]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data") orelse
        return error.InvalidPerfSemanticOutput;
    return canonicalValueDigest(allocator, data);
}

fn canonicalValueDigest(allocator: std.mem.Allocator, value: std.json.Value) ![64]u8 {
    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(allocator, value);
    defer allocator.free(canonical);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn compareMeasuredMetrics(
    case_cfg: CompatCase,
    baseline: anytype,
    candidate: anytype,
) !StatusDetail {
    const allowed_rss = try observableRssUpperBound(baseline.p95_rss_bytes, resource_tolerance_pct);
    if (candidate.p95_rss_bytes > allowed_rss) {
        return .{
            .status = "FAIL",
            .detail = try std.heap.page_allocator.print(
                "paired p95_rss_bytes candidate={d} base={d} allowed={d}",
                .{
                    candidate.p95_rss_bytes,
                    baseline.p95_rss_bytes,
                    allowed_rss,
                },
            ),
        };
    }
    const allowed_p50 = allowedUpperBoundWithTolerance(baseline.p50_ns, case_cfg.tolerance_pct);
    const allowed_p95 = allowedUpperBoundWithTolerance(baseline.p95_ns, case_cfg.tolerance_pct);
    if (candidate.p50_ns > allowed_p50) {
        return .{
            .status = "FAIL",
            .detail = try std.heap.page_allocator.print(
                "paired p50 candidate={d} base={d} allowed={d}",
                .{ candidate.p50_ns, baseline.p50_ns, allowed_p50 },
            ),
        };
    }
    if (candidate.p95_ns > allowed_p95) {
        return .{
            .status = "FAIL",
            .detail = try std.heap.page_allocator.print(
                "paired p95 candidate={d} base={d} allowed={d}",
                .{ candidate.p95_ns, baseline.p95_ns, allowed_p95 },
            ),
        };
    }
    if (case_cfg.descriptor.measurement_mode == .latency_alloc) {
        const allowed_alloc = allowedUpperBoundWithTolerance(
            baseline.p50_alloc_calls,
            case_cfg.tolerance_pct,
        );
        if (candidate.p50_alloc_calls > allowed_alloc) {
            return .{
                .status = "FAIL",
                .detail = try std.heap.page_allocator.print(
                    "paired p50_alloc_calls candidate={d} base={d} allowed={d}",
                    .{
                        candidate.p50_alloc_calls,
                        baseline.p50_alloc_calls,
                        allowed_alloc,
                    },
                ),
            };
        }
    }
    return .{ .status = "PASS", .detail = "paired base/candidate ok" };
}

fn observableRssUpperBound(base: u64, tolerance_pct: f64) !u64 {
    const raw = allowedUpperBoundWithTolerance(base, tolerance_pct);
    const page_size: u64 = @intCast(C.sysconf(
        @backingInt(std.c._SC.PAGESIZE),
    ));
    if (page_size == 0 or !std.math.isPowerOfTwo(page_size)) {
        return error.UnsupportedPeakRss;
    }
    const rounded = std.math.add(u64, raw, page_size - 1) catch
        return error.InvalidPerfMeasurement;
    return @divFloor(rounded, page_size) * page_size;
}

const C = struct {
    extern "c" fn sysconf(name: c_int) c_long;
};

fn compareBalancedDeepMetrics(
    case_cfg: DeepCase,
    baseline: anytype,
    candidate: anytype,
) !StatusDetail {
    const baseline_latency = latencySamples(baseline);
    const candidate_latency = latencySamples(candidate);
    const baseline_allocations = allocationSamples(baseline);
    const candidate_allocations = allocationSamples(candidate);
    const baseline_rss = rssSamples(baseline);
    const candidate_rss = rssSamples(candidate);
    const expected_samples = try std.math.mul(usize, case_cfg.samples, paired_comparison_rounds);
    if (baseline_latency.len != expected_samples or
        candidate_latency.len != expected_samples)
    {
        return error.DeepMeasurementSampleCountMismatch;
    }
    if (baseline_allocations.len != paired_comparison_rounds or
        candidate_allocations.len != paired_comparison_rounds)
    {
        return error.DeepMeasurementAllocationCountMismatch;
    }
    if (baseline_rss.len != paired_comparison_rounds or
        candidate_rss.len != paired_comparison_rounds)
    {
        return error.DeepMeasurementRssCountMismatch;
    }
    var p50_ratios: [paired_comparison_rounds]u64 = undefined;
    var p95_ratios: [paired_comparison_rounds]u64 = undefined;
    var allocation_ratios: [paired_comparison_rounds]u64 = undefined;
    var rss_ratios: [paired_comparison_rounds]u64 = undefined;
    for (0..paired_comparison_rounds) |round| {
        const start = round * case_cfg.samples;
        const end = start + case_cfg.samples;
        const base = try core_perf.percentilesU64(
            std.heap.page_allocator,
            baseline_latency[start..end],
            &.{ 50, 95 },
        );
        const current = try core_perf.percentilesU64(
            std.heap.page_allocator,
            candidate_latency[start..end],
            &.{ 50, 95 },
        );
        p50_ratios[round] = try ratioPpm(base[0], current[0]);
        p95_ratios[round] = try ratioPpm(base[1], current[1]);
        allocation_ratios[round] = try ratioPpm(
            baseline_allocations[round],
            candidate_allocations[round],
        );
        rss_ratios[round] = try ratioPpm(baseline_rss[round], candidate_rss[round]);
    }
    return compareBalancedRatios(case_cfg, .{
        .p50 = medianRatioPpm(&p50_ratios),
        .p95 = medianRatioPpm(&p95_ratios),
        .allocations = medianRatioPpm(&allocation_ratios),
        .rss = medianRatioPpm(&rss_ratios),
    });
}

const BalancedRatios = struct { p50: u64, p95: u64, allocations: u64, rss: u64 };

fn compareBalancedRatios(case_cfg: DeepCase, ratios: BalancedRatios) !StatusDetail {
    const allowed_ratio: u64 = @intFromFloat(std.math.ceil(
        @as(f64, @floatFromInt(ratio_scale)) *
            (1.0 + case_cfg.tolerance_pct / 100.0),
    ));
    const allowed_p50 = if (case_cfg.primary_optimization) 800_000 else allowed_ratio;
    const allowed_allocations = if (case_cfg.driver_kind == .optimization)
        ratio_scale
    else
        allowed_ratio;
    if (ratios.p50 > allowed_p50) {
        return .{
            .status = "FAIL",
            .detail = try std.heap.page_allocator.print(
                "balanced round p50 ratio_ppm={d} > {d}",
                .{ ratios.p50, allowed_p50 },
            ),
        };
    }
    if (ratios.p95 > allowed_ratio) {
        return .{
            .status = "FAIL",
            .detail = try std.heap.page_allocator.print(
                "balanced round p95 ratio_ppm={d} > {d}",
                .{ ratios.p95, allowed_ratio },
            ),
        };
    }
    if (ratios.allocations > allowed_allocations) {
        return .{
            .status = "FAIL",
            .detail = try std.heap.page_allocator.print(
                "balanced round allocation ratio_ppm={d} > {d}",
                .{ ratios.allocations, allowed_allocations },
            ),
        };
    }
    const allowed_rss_ratio: u64 = @intFromFloat(std.math.ceil(
        @as(f64, @floatFromInt(ratio_scale)) *
            (1.0 + resource_tolerance_pct / 100.0),
    ));
    if (ratios.rss > allowed_rss_ratio) {
        return .{
            .status = "FAIL",
            .detail = try std.heap.page_allocator.print(
                "balanced round rss ratio_ppm={d} > {d}",
                .{ ratios.rss, allowed_rss_ratio },
            ),
        };
    }
    return .{
        .status = "PASS",
        .detail = try std.heap.page_allocator.print(
            "balanced round ratios p50_ppm={d} p95_ppm={d} " ++
                "allocation_ppm={d} rss_ppm={d}",
            .{ ratios.p50, ratios.p95, ratios.allocations, ratios.rss },
        ),
    };
}

fn latencySamples(metrics: anytype) []const u64 {
    return if (@hasField(@TypeOf(metrics), "samples_ns"))
        metrics.samples_ns
    else
        metrics.samples.items;
}

fn allocationSamples(metrics: anytype) []const u64 {
    return if (@hasField(@TypeOf(metrics), "allocation_samples"))
        metrics.allocation_samples
    else
        metrics.alloc_samples.items;
}

fn rssSamples(metrics: anytype) []const u64 {
    return if (@hasField(@TypeOf(metrics), "rss_samples_bytes"))
        metrics.rss_samples_bytes
    else
        metrics.rss_samples.items;
}

fn ratioPpm(base: u64, current: u64) !u64 {
    if (base == 0) return error.InvalidDeepMeasurementContract;
    const numerator = @as(u128, current) * ratio_scale + base - 1;
    return @intCast(numerator / base);
}

fn medianRatioPpm(ratios: *[paired_comparison_rounds]u64) u64 {
    std.mem.sort(u64, ratios, {}, std.sort.asc(u64));
    const upper = ratios[paired_comparison_rounds / 2];
    const lower = ratios[paired_comparison_rounds / 2 - 1];
    return lower + (upper - lower + 1) / 2;
}

fn writeMetricsObject(writer: *std.Io.Writer, metrics: Metrics, include_allocations: bool) !void {
    try writer.writeAll("{\"samples_ns\":[");
    for (metrics.samples.items, 0..) |sample, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{d}", .{sample});
    }
    try writer.print(
        "],\"p50_ns\":{d},\"p95_ns\":{d}",
        .{ metrics.p50_ns, metrics.p95_ns },
    );
    try writer.writeAll(",\"rss_samples_bytes\":[");
    for (metrics.rss_samples.items, 0..) |sample, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{d}", .{sample});
    }
    try writer.print(
        "],\"p95_rss_bytes\":{d}",
        .{metrics.p95_rss_bytes},
    );
    if (include_allocations) {
        try writer.writeAll(",\"allocation_samples\":[");
        for (metrics.alloc_samples.items, 0..) |sample, idx| {
            if (idx > 0) try writer.writeByte(',');
            try writer.print("{d}", .{sample});
        }
        try writer.print(
            "],\"p50_alloc_calls\":{d}",
            .{metrics.p50_alloc_calls},
        );
    }
    try writer.writeByte('}');
}

fn writeSealedFile(writer: *std.Io.Writer, file: SealedFile) !void {
    try writer.writeAll("{\"label\":");
    try writeJsonString(writer, std.fs.path.basename(file.path));
    try writer.writeAll(",\"sha256\":\"sha256:");
    try writer.writeAll(&file.sha256);
    try writer.writeAll("\"}");
}

fn writeBinaryEvidence(writer: *std.Io.Writer, evidence: BinaryEvidence) !void {
    try writer.writeAll("{\"file\":");
    try writeSealedFile(writer, evidence.file);
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, evidence.version);
    try writer.writeAll(",\"source\":{\"revision\":");
    try writeJsonString(writer, evidence.source_sha);
    try writer.writeAll(",\"tree\":");
    try writeJsonString(writer, evidence.source_tree_sha);
    try writer.writeAll(",\"root\":");
    try writeJsonString(writer, evidence.source_root);
    try writer.writeAll(",\"clean\":true,\"archive\":");
    try writeSealedFile(writer, evidence.source_archive);
    try writer.writeAll("},\"compiler\":");
    try writeCompilerEvidence(writer, evidence.compiler);
    try writer.writeAll(
        ",\"build\":{\"optimize\":\"ReleaseFast\"," ++
            "\"repo_local_prefix\":true,\"isolated_caches\":true," ++
            "\"product_output_isolated\":true,\"step\":",
    );
    try writeJsonString(writer, evidence.build_step);
    try writer.writeAll("}}");
}

fn writeCompilerEvidence(writer: *std.Io.Writer, compiler: CompilerEvidence) !void {
    try writer.writeAll("{\"approved_path\":");
    try writeJsonString(writer, compiler.approved_path);
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, compiler.version);
    try writer.writeAll(",\"file\":");
    try writeSealedFile(writer, compiler.file);
    try writer.writeByte('}');
}

fn writeDriverEvidence(writer: *std.Io.Writer, evidence: DriverEvidence) !void {
    try writer.writeAll("{\"file\":");
    try writeSealedFile(writer, evidence.file);
    try writer.writeAll(",\"source\":{\"revision\":");
    try writeJsonString(writer, evidence.source_sha);
    try writer.writeAll(",\"tree\":");
    try writeJsonString(writer, evidence.source_tree_sha);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, driverIdentity(evidence.kind).locator);
    try writer.writeAll(",\"file\":");
    try writeSealedFile(writer, evidence.source_file);
    if (evidence.build_source_file) |build_file| {
        try writer.writeAll(",\"build_file\":");
        try writeSealedFile(writer, build_file);
    }
    try writer.writeAll("},\"product_source\":{\"revision\":");
    try writeJsonString(writer, evidence.product_source_sha);
    try writer.writeAll(",\"tree\":");
    try writeJsonString(writer, evidence.product_source_tree_sha);
    try writer.writeAll(",\"archive_sha256\":\"sha256:");
    try writer.writeAll(&evidence.product_source_archive_sha256);
    try writer.writeByte('"');
    try writer.writeAll("},\"compiler\":");
    try writeCompilerEvidence(writer, evidence.compiler);
    try writer.writeAll(",\"build\":{\"optimize\":\"ReleaseFast\",\"step\":");
    try writeJsonString(writer, switch (evidence.kind) {
        .seq_replay => "install",
        .optimization => "optimization-driver",
    });
    if (evidence.kind == .optimization) {
        try writer.writeAll(",\"target\":\"aarch64-macos\",\"cpu\":\"baseline\"");
    }
    try writer.writeAll(
        ",\"repo_local_prefix\":true,\"isolated_caches\":true," ++
            "\"product_output_isolated\":true}}",
    );
}

fn writePairedMetricsArtifact(
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    baseline_evidence: BinaryEvidence,
    candidate_evidence: BinaryEvidence,
    baseline_driver: ?DriverEvidence,
    candidate_driver: ?DriverEvidence,
    baseline: Metrics,
    candidate: Metrics,
    workload_digest: [64]u8,
    baseline_execution: MeasuredOutputEvidence,
    candidate_execution: MeasuredOutputEvidence,
    compare_status: []const u8,
    compare_detail: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const configuration_digest = try caseConfigurationDigest(
        evidenceCaseConfig(case_cfg.descriptor.case_id) orelse
            return error.InvalidPerfEvidenceFile,
    );
    try writer.print(
        "{{\"schema_version\":3,\"evidence_kind\":\"paired\"," ++
            "\"machine_id\":\"{s}\",\"binary\":\"{s}\"," ++
            "\"case_id\":\"{s}\",\"configuration_digest\":\"sha256:{s}\"," ++
            "\"workload_digest\":\"sha256:{s}\"",
        .{
            machine_name,
            case_cfg.descriptor.binary,
            case_cfg.descriptor.case_id,
            configuration_digest,
            workload_digest,
        },
    );
    if ((baseline_driver == null) != (candidate_driver == null)) {
        return error.IncompletePerfDriverEvidence;
    }
    const include_allocations = case_cfg.descriptor.measurement_mode == .latency_alloc;
    try writer.writeAll(",\"baseline\":");
    try writePairedSide(
        writer,
        baseline_evidence,
        baseline_driver,
        baseline,
        baseline_execution,
        include_allocations,
    );
    try writer.writeAll(",\"candidate\":");
    try writePairedSide(
        writer,
        candidate_evidence,
        candidate_driver,
        candidate,
        candidate_execution,
        include_allocations,
    );
    try writer.writeAll(",\"compare_status\":");
    try writeJsonString(writer, compare_status);
    try writer.writeAll(",\"compare_detail\":");
    try writeJsonString(writer, compare_detail);
    try writer.writeAll("}\n");
    return output.toOwnedSlice();
}

fn writePairedSide(
    writer: *std.Io.Writer,
    binary: BinaryEvidence,
    driver: ?DriverEvidence,
    metrics: Metrics,
    execution: MeasuredOutputEvidence,
    include_allocations: bool,
) !void {
    try writer.writeAll("{\"binary\":");
    try writeBinaryEvidence(writer, binary);
    if (driver) |evidence| {
        try writer.writeAll(",\"driver\":");
        try writeDriverEvidence(writer, evidence);
    }
    try writer.writeAll(",\"metrics\":");
    try writeMetricsObject(writer, metrics, include_allocations);
    try writer.writeAll(",\"execution\":");
    try writeMeasuredOutputEvidence(writer, execution);
    try writer.writeAll("}");
}

fn writeMeasuredOutputEvidence(writer: *std.Io.Writer, evidence: MeasuredOutputEvidence) !void {
    try writer.writeAll("{\"output_sha256\":\"sha256:");
    try writer.writeAll(&evidence.output_sha256);
    try writer.writeAll("\",\"semantic_output_sha256\":\"sha256:");
    try writer.writeAll(&evidence.semantic_output_sha256);
    try writer.writeAll("\",\"local_output_sha256\":");
    if (evidence.local_output_sha256) |digest| {
        try writer.writeAll("\"sha256:");
        try writer.writeAll(&digest);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"streamed\":");
    if (evidence.streamed) |value| {
        try writer.writeAll(if (value) "true" else "false");
    } else {
        try writer.writeAll("null");
    }
    try writeOptionalU64(
        writer,
        "records_scanned",
        evidence.records_scanned,
    );
    try writeOptionalU64(
        writer,
        "records_emitted",
        evidence.records_emitted,
    );
    try writeOptionalU64(
        writer,
        "physical_passes",
        evidence.physical_passes,
    );
    try writeOptionalU64(writer, "files_opened", evidence.files_opened);
    try writeOptionalU64(writer, "bytes_read", evidence.bytes_read);
    try writeOptionalU64(
        writer,
        "rows_materialized",
        evidence.rows_materialized,
    );
    try writeOptionalU64(writer, "compile_ns", evidence.compile_ns);
    try writeOptionalU64(writer, "execution_ns", evidence.execution_ns);
    try writer.writeByte('}');
}

fn writeOptionalU64(writer: *std.Io.Writer, field: []const u8, value: ?u64) !void {
    try writer.writeAll(",\"");
    try writer.writeAll(field);
    try writer.writeAll("\":");
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn prepareCompatCase(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) !void {
    switch (case_cfg.setup) {
        .seq_sessions, .seq_query => {
            return prepareSeqPerfCorpus(fs, allocator, temp_root);
        },
        .ledger_transact, .ledger_project, .ledger_doctor => {},
        else => return,
    }
    const repo_path = try std.fs.path.join(
        allocator,
        &.{ temp_root, "ledger-repo" },
    );
    defer allocator.free(repo_path);
    try makeRepoAwarePath(fs, allocator, repo_path);
    const definition_path = try prepareLedgerPerfDefinition(fs, allocator, temp_root);
    defer allocator.free(definition_path);
    try prepareLedgerPerfStore(fs, environ, allocator, repo_path, definition_path, case_cfg);
}

fn prepareSeqPerfCorpus(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    temp_root: []const u8,
) !void {
    const session_dir = try std.fs.path.join(
        allocator,
        &.{ temp_root, "seq-sessions/2026/07/26" },
    );
    defer allocator.free(session_dir);
    try makeRepoAwarePath(fs, allocator, session_dir);
    const session_path = try std.fs.path.join(
        allocator,
        &.{
            session_dir,
            "rollout-2026-07-26T10-00-00-fixture-session.jsonl",
        },
    );
    defer allocator.free(session_path);
    try fs.directory().writeFile(
        fs.io,
        .{ .sub_path = session_path, .data = seq_perf_corpus },
    );
}

fn prepareLedgerPerfDefinition(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    temp_root: []const u8,
) ![]u8 {
    const source = try fs.directory().readFileAlloc(
        fs.io,
        "apps/ledger/src/v1/fixtures/event-definition.json",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(source);
    const store_bytes = try allocator.print(
        "\"max_bytes\":{d}",
        .{ledger_perf_max_store_bytes},
    );
    defer allocator.free(store_bytes);
    const max_store_bytes = try allocator.print(
        "\"max_store_bytes\":{d}",
        .{ledger_perf_max_store_bytes},
    );
    defer allocator.free(max_store_bytes);
    const max_records = try allocator.print(
        "\"max_records\":{d}",
        .{ledger_perf_max_records},
    );
    defer allocator.free(max_records);
    const expanded_store = try std.mem.replaceOwned(
        u8,
        allocator,
        source,
        "\"max_bytes\":65536",
        store_bytes,
    );
    defer allocator.free(expanded_store);
    const expanded_bounds = try std.mem.replaceOwned(
        u8,
        allocator,
        expanded_store,
        "\"max_store_bytes\":65536",
        max_store_bytes,
    );
    defer allocator.free(expanded_bounds);
    const expanded_records = try std.mem.replaceOwned(
        u8,
        allocator,
        expanded_bounds,
        "\"max_records\":100",
        max_records,
    );
    defer allocator.free(expanded_records);
    const definition_path = try std.fs.path.join(
        allocator,
        &.{ temp_root, "ledger-event-definition.json" },
    );
    errdefer allocator.free(definition_path);
    try fs.directory().writeFile(
        fs.io,
        .{ .sub_path = definition_path, .data = expanded_records },
    );
    return definition_path;
}

fn prepareLedgerPerfStore(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    definition_path: []const u8,
    case_cfg: CompatCase,
) !void {
    const event_dir = try std.fs.path.join(
        allocator,
        &.{ repo_path, ".ledger/example" },
    );
    defer allocator.free(event_dir);
    try makeRepoAwarePath(fs, allocator, event_dir);
    const event_path = try std.fs.path.join(
        allocator,
        &.{ event_dir, "events.jsonl" },
    );
    defer allocator.free(event_path);
    var file = try fs.directory().createFile(
        fs.io,
        event_path,
        .{},
    );
    {
        defer file.close(fs.io);
        var writer = file.writer(
            fs.io,
            &.{},
        );
        var index: usize = 0;
        while (index < ledger_perf_record_count) : (index += 1) {
            try writer.interface.writeAll("{\"kind\":\"one\",\"value\":1}\n");
        }
    }
    const binary_path = try resolveBinaryExecPath(environ, allocator, case_cfg);
    defer allocator.free(binary_path);
    const argv = [_][]const u8{
        binary_path,
        "transact",
        "--definition",
        definition_path,
        "--operation",
        "bind-existing",
        "--repo",
        repo_path,
        "--format",
        "json",
    };
    const result = try runChildCapture(fs, environ, allocator, ".", &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.PerfSetupFailed;
}

fn renderCompatRun(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) !CommandRun {
    const binary_path = try resolveBinaryExecPath(environ, allocator, case_cfg);
    errdefer allocator.free(binary_path);
    _ = case_cfg.builder;
    const cwd = try allocator.dupe(u8, ".");
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    switch (case_cfg.setup) {
        .seq_definition_check,
        .seq_observe,
        .seq_sessions,
        .seq_query,
        => try appendSeqCompatArgs(allocator, &args, case_cfg.setup, binary_path, temp_root),
        .ledger_definition_check,
        .ledger_validate,
        .ledger_materialize,
        => try appendLedgerRecordArgs(allocator, &args, case_cfg.setup, binary_path),
        .ledger_transact,
        .ledger_project,
        .ledger_doctor,
        => try appendLedgerStoreArgs(allocator, &args, case_cfg.setup, binary_path, temp_root),
        .cas_wrapper_smoke => return renderCasWrapperSmoke(
            fs,
            allocator,
            binary_path,
            temp_root,
            cwd,
        ),
        .cas_automation_list => try appendCasAutomationListArgs(
            fs.io,
            allocator,
            &args,
            binary_path,
            temp_root,
        ),
        else => try appendMiscCompatArgs(allocator, &args, case_cfg.setup, binary_path),
    }
    return .{ .cwd = cwd, .argv = try args.toOwnedSlice(allocator) };
}

fn appendSeqCompatArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    setup: CompatSetup,
    binary_path: []const u8,
    temp_root: []const u8,
) !void {
    switch (setup) {
        .seq_definition_check => try args.appendSlice(allocator, &.{
            binary_path,
            "definition",
            "check",
            "--definition",
            "apps/seq/src/v1/fixtures/message-observation.json",
            "--format",
            "json",
        }),
        .seq_observe => try args.appendSlice(allocator, &.{
            binary_path,
            "observe",
            "--definition",
            "apps/seq/src/v1/fixtures/message-observation.json",
            "--projection",
            "rows",
            "--path",
            "apps/seq/src/v1/fixtures/rollout.jsonl",
            "--param",
            "needle=failure",
            "--format",
            "json",
        }),
        .seq_sessions, .seq_query => {
            const root = try std.fs.path.join(allocator, &.{ temp_root, "seq-sessions" });
            if (setup == .seq_sessions) {
                try args.appendSlice(allocator, &.{
                    binary_path, "sessions", "--root", root, "--format", "json",
                });
            } else {
                try args.appendSlice(allocator, &.{
                    binary_path, "query", "--root", root, "--spec",
                    "{\"dataset\":\"messages\",\"where\":[" ++
                        "{\"field\":\"text\",\"op\":\"contains\"," ++
                        "\"value\":\"failure\",\"case_insensitive\":true}]," ++
                        "\"select\":[\"session_id\",\"role\",\"text\"]," ++
                        "\"limit\":5,\"format\":\"json\"}",
                });
            }
        },
        else => return error.InvalidCommand,
    }
}

fn appendLedgerRecordArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    setup: CompatSetup,
    binary_path: []const u8,
) !void {
    switch (setup) {
        .ledger_definition_check => try args.appendSlice(allocator, &.{
            binary_path,
            "definition",
            "check",
            "--definition",
            "apps/ledger/src/v1/fixtures/record-definition.json",
            "--format",
            "json",
        }),
        .ledger_validate, .ledger_materialize => try args.appendSlice(allocator, &.{
            binary_path,
            if (setup == .ledger_validate) "validate" else "materialize",
            "--definition",
            "apps/ledger/src/v1/fixtures/record-definition.json",
            "--input",
            "record=apps/ledger/src/v1/fixtures/record-valid.json",
            "--format",
            "json",
        }),
        else => return error.InvalidCommand,
    }
}

fn appendLedgerStoreArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    setup: CompatSetup,
    binary_path: []const u8,
    temp_root: []const u8,
) !void {
    const repo_path = try std.fs.path.join(allocator, &.{ temp_root, "ledger-repo" });
    const definition_path = try std.fs.path.join(
        allocator,
        &.{ temp_root, "ledger-event-definition.json" },
    );
    switch (setup) {
        .ledger_transact => try args.appendSlice(allocator, &.{
            binary_path,
            "transact",
            "--definition",
            definition_path,
            "--operation",
            "append",
            "--repo",
            repo_path,
            "--input",
            "event=apps/ledger/src/v1/fixtures/event-one.json",
            "--param",
            "request=perf",
            "--format",
            "json",
        }),
        .ledger_project => try args.appendSlice(allocator, &.{
            binary_path,    "project", "--definition", definition_path,
            "--projection", "all",     "--repo",       repo_path,
            "--format",     "json",
        }),
        .ledger_doctor => try args.appendSlice(allocator, &.{
            binary_path, "doctor",  "--definition", definition_path,
            "--repo",    repo_path, "--format",     "json",
        }),
        else => return error.InvalidCommand,
    }
}

fn appendMiscCompatArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    setup: CompatSetup,
    binary_path: []const u8,
) !void {
    switch (setup) {
        .bench_stats_help,
        .cas_smoke_check_help,
        .cas_instance_runner_help,
        .cas_review_session_help,
        => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
        .cas_automation_help => try args.appendSlice(
            allocator,
            &.{ binary_path, "automation", "--help" },
        ),
        .cas_review_session_version => try args.appendSlice(
            allocator,
            &.{ binary_path, "--version" },
        ),
        .bench_stats_parse => {
            const input_path = try std.fs.path.join(
                allocator,
                &.{ ".", "apps/lift/perf/fixtures/bench_stats_input.txt" },
            );
            try args.appendSlice(allocator, &.{ binary_path, "--input", input_path, "--json" });
        },
        else => return error.InvalidCommand,
    }
}

fn renderCasWrapperSmoke(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    binary_path: []const u8,
    temp_root: []const u8,
    cwd: []const u8,
) !CommandRun {
    const io = fs.io;
    const wrapper_dir = try std.fs.path.join(allocator, &.{ temp_root, "cas-wrapper" });
    try makeRepoAwarePath(fs, allocator, wrapper_dir);
    const wrapper_binary = try std.fs.path.join(allocator, &.{ wrapper_dir, "cas" });
    const source_binary = try absolutePathForCwdRelative(fs, allocator, binary_path);
    defer allocator.free(source_binary);
    try std.Io.Dir.copyFileAbsolute(source_binary, wrapper_binary, io, .{});
    try makeExecutable(fs, wrapper_binary);
    const stub_path = try std.fs.path.join(allocator, &.{ wrapper_dir, "cas_smoke_check" });
    try fs.directory().writeFile(io, .{
        .sub_path = stub_path,
        .data = "#!/usr/bin/env bash\nexit 0\n",
    });
    try makeExecutable(fs, stub_path);
    return .{
        .cwd = cwd,
        .argv = try allocator.dupe([]const u8, &.{ wrapper_binary, "smoke_check" }),
    };
}

fn appendCasAutomationListArgs(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    binary_path: []const u8,
    temp_root: []const u8,
) !void {
    const stamp_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
    const db_name = try allocator.print("codex-dev-{d}.db", .{stamp_ms});
    const db_path = try std.fs.path.join(allocator, &.{ temp_root, db_name });
    try seedCasAutomationDb(io, allocator, db_path);
    try args.appendSlice(allocator, &.{ binary_path, "automation", "--db", db_path, "list" });
}

const ChildResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    peak_rss_bytes: ?u64 = null,
};

fn runChildCapture(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) !ChildResult {
    if (builtin.target.os.tag == .macos) {
        return runChildCapturePosixSpawn(fs, environ, allocator, cwd, argv, false);
    }

    const io = fs.io;
    const environment = environ orelse return error.ProcessEnvironmentRequired;
    var child_dir = try fs.directory().openDir(io, cwd, .{});
    defer child_dir.close(io);
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = child_dir },
        .environ_map = environment,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
    });
    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            .signal, .stopped, .unknown => 1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
        .peak_rss_bytes = null,
    };
}

fn runChildCaptureOutput(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) !ChildResult {
    if (builtin.target.os.tag == .macos) {
        return runChildCapturePosixSpawn(fs, environ, allocator, cwd, argv, true);
    }
    return runChildCapture(fs, environ, allocator, cwd, argv);
}

fn runChildCapturePosixSpawn(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    capture_stdout: bool,
) !ChildResult {
    if (argv.len == 0) return error.FileNotFound;
    var arguments = try SpawnArguments.init(allocator, argv);
    defer arguments.deinit(allocator);
    var child_dir = try fs.directory().openDir(fs.io, cwd, .{});
    defer child_dir.close(fs.io);
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    const init_rc = std.c.posix_spawn_file_actions_init(&actions);
    if (init_rc != 0) return posixSpawnError(init_rc);
    defer destroySpawnActions(fs.io, &actions);
    const capture_root = if (capture_stdout)
        try makeTempRoot(fs, allocator, "capture")
    else
        null;
    defer if (capture_root) |path| releaseTempRoot(fs, allocator, path, false);
    const capture_path = if (capture_root) |root|
        try std.fs.path.join(allocator, &.{ root, "stdout" })
    else
        null;
    defer if (capture_path) |path| allocator.free(path);
    const capture_path_z = if (capture_path) |path|
        try allocator.dupeSentinel(u8, path, 0)
    else
        null;
    defer if (capture_path_z) |path| allocator.free(path);
    try configureSpawnActions(&actions, child_dir, capture_path_z);

    var pid: std.c.pid_t = undefined;
    const environment = environ orelse return error.ProcessEnvironmentRequired;
    // Zig 0.17's partial POSIX-block cleanup frees the pointer array using
    // its initialized length. Give that temporary graph one arena owner so
    // failure cleanup cannot free a truncated allocation extent.
    var environment_arena = std.heap.ArenaAllocator.init(allocator);
    defer environment_arena.deinit();
    const block = try environment.createPosixBlock(environment_arena.allocator(), .{});
    const spawn_rc = std.c.posix_spawnp(
        &pid,
        arguments.pointers[0].?,
        &actions,
        null,
        arguments.pointers.ptr,
        block.slice.ptr,
    );
    if (spawn_rc != 0) return posixSpawnError(spawn_rc);
    return waitForCapturedChild(fs, allocator, pid, capture_path);
}

const SpawnArguments = struct {
    pointers: [:null]?[*:0]const u8,
    storage: [][:0]u8,
    count: usize = 0,

    fn init(allocator: std.mem.Allocator, argv: []const []const u8) !SpawnArguments {
        const pointers = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
        errdefer allocator.free(pointers);
        const storage = try allocator.alloc([:0]u8, argv.len);
        errdefer allocator.free(storage);
        var result = SpawnArguments{ .pointers = pointers, .storage = storage };
        errdefer for (storage[0..result.count]) |arg| allocator.free(arg);
        for (argv, 0..) |arg, idx| {
            storage[idx] = try allocator.dupeSentinel(u8, arg, 0);
            result.count += 1;
            pointers[idx] = storage[idx].ptr;
        }
        return result;
    }

    fn deinit(self: *SpawnArguments, allocator: std.mem.Allocator) void {
        for (self.storage[0..self.count]) |arg| allocator.free(arg);
        allocator.free(self.storage);
        allocator.free(self.pointers);
    }
};

fn destroySpawnActions(io: std.Io, actions: *std.c.posix_spawn_file_actions_t) void {
    const rc = std.c.posix_spawn_file_actions_destroy(actions);
    if (rc != 0) {
        warnDiagnostic(
            io,
            "spawn action cleanup failed error={s}",
            .{@errorName(posixSpawnError(rc))},
        );
    }
}

fn configureSpawnActions(
    actions: *std.c.posix_spawn_file_actions_t,
    cwd: std.Io.Dir,
    capture_path: ?[:0]const u8,
) !void {
    const dev_null = "/dev/null";
    const dev_null_flags: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .WRONLY })));
    const stdout_flags: c_int = @intCast(@as(u32, @bitCast(std.c.O{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    })));
    const stdout_rc = std.c.posix_spawn_file_actions_addopen(
        actions,
        1,
        if (capture_path) |path| path else dev_null,
        if (capture_path != null) stdout_flags else dev_null_flags,
        if (capture_path != null) 0o600 else 0,
    );
    if (stdout_rc != 0) return posixSpawnError(stdout_rc);
    const stderr_rc = std.c.posix_spawn_file_actions_addopen(
        actions,
        2,
        dev_null,
        dev_null_flags,
        0,
    );
    if (stderr_rc != 0) return posixSpawnError(stderr_rc);
    const chdir_rc = std.c.posix_spawn_file_actions_addfchdir_np(actions, cwd.handle);
    if (chdir_rc != 0) return posixSpawnError(chdir_rc);
}

fn waitForCapturedChild(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    pid: std.c.pid_t,
    capture_path: ?[]const u8,
) !ChildResult {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    var usage: std.posix.rusage = undefined;
    while (true) switch (std.posix.errno( // tiger: event-loop -- bounded by child exit.
        std.posix.system.wait4(pid, &status, 0, &usage),
    )) {
        .SUCCESS => {
            const stdout = if (capture_path) |path|
                try fs.directory().readFileAlloc(
                    fs.io,
                    path,
                    allocator,
                    .limited(8 * 1024 * 1024),
                )
            else
                try allocator.dupe(u8, "");
            errdefer allocator.free(stdout);
            return .{
                .exit_code = statusToExitCode(@bitCast(status)),
                .stdout = stdout,
                .stderr = try allocator.dupe(u8, ""),
                .peak_rss_bytes = @intCast(usage.maxrss),
            };
        },
        .INTR => continue,
        .CHILD => return error.NoChildProcess,
        else => return error.WaitFailed,
    };
}

fn posixSpawnError(rc: c_int) anyerror {
    const err: std.c.E = @fromBackingInt(@intCast(@as(u16, @intCast(rc))));
    return switch (err) {
        .NOMEM, .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOEXEC => error.InvalidExe,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        else => error.SpawnFailed,
    };
}

fn statusToExitCode(status: u32) u8 {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    if (std.posix.W.IFSIGNALED(status)) {
        const signal: u32 = @backingInt(std.posix.W.TERMSIG(status));
        return @intCast(@min(@as(u32, 128) + signal, @as(u32, 255)));
    }
    return 1;
}

fn makeTempRoot(fs: durable_store.Fs, allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    const cwd = try fs.directory().realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(cwd);
    const stamp = std.Io.Clock.awake.now(fs.io).nanoseconds;
    const base = try allocator.print(
        "{s}/.zig-cache/perf-hub/{d}-{s}",
        .{ cwd, stamp, label },
    );
    errdefer allocator.free(base);
    try makeRepoAwarePath(fs, allocator, base);
    return base;
}

fn releaseTempRoot(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    path: []u8,
    retain: bool,
) void {
    if (!retain) {
        fs.directory().deleteTree(
            fs.io,
            path,
        ) catch |err| {
            warnDiagnostic(
                fs.io,
                "temp-root cleanup failed path={s} error={s}",
                .{ path, @errorName(err) },
            );
        };
    }
    allocator.free(path);
}

fn makeExecutable(fs: durable_store.Fs, path: []const u8) !void {
    var file = try fs.directory().openFile(
        fs.io,
        path,
        .{ .mode = .read_write },
    );
    defer file.close(fs.io);
    try file.setPermissions(
        fs.io,
        @fromBackingInt(@intCast(0o755)),
    );
}

fn absolutePathForCwdRelative(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try fs.directory().realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn seedCasAutomationDb(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8) !void {
    const db_path_z = try allocator.dupeSentinel(u8, db_path, 0);
    defer allocator.free(db_path_z);
    var db_opt: ?*Sqlite.sqlite3 = null;
    const open_rc = Sqlite.sqlite3_open(db_path_z, &db_opt);
    defer if (db_opt) |db| closeAutomationDb(io, db);
    if (open_rc != Sqlite.SQLITE_OK or db_opt == null) {
        return error.InvalidData;
    }

    const schema =
        \\create table automations (
        \\  id text primary key,
        \\  name text not null,
        \\  prompt text not null,
        \\  status text not null,
        \\  next_run_at integer,
        \\  last_run_at integer,
        \\  cwds text not null,
        \\  rrule text not null,
        \\  created_at integer not null,
        \\  updated_at integer not null
        \\);
        \\create table automation_runs (
        \\  thread_id text primary key,
        \\  automation_id text not null,
        \\  status text not null,
        \\  read_at integer,
        \\  thread_title text,
        \\  source_cwd text,
        \\  inbox_title text,
        \\  inbox_summary text,
        \\  created_at integer not null,
        \\  updated_at integer not null,
        \\  archived_user_message text,
        \\  archived_assistant_message text,
        \\  archived_reason text
        \\);
        \\insert into automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) values ('cron-001', 'Daily Summary', 'Summarize recent runs', 'ACTIVE', null, null, '[]', 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=15', 1772469600000, 1772469600000);
    ;
    const schema_z = try allocator.dupeSentinel(u8, schema, 0);
    defer allocator.free(schema_z);
    var err_msg: ?[*:0]u8 = null;
    defer if (err_msg) |message| Sqlite.sqlite3_free(@ptrCast(message));
    if (Sqlite.sqlite3_exec(db_opt.?, schema_z, null, null, &err_msg) != Sqlite.SQLITE_OK) {
        if (err_msg) |msg| try reportAutomationDbError(io, msg);
        return error.InvalidData;
    }
}

fn reportAutomationDbError(io: std.Io, message: [*:0]const u8) !void {
    var stderr_writer = std.Io.File.stderr().writer(
        io,
        &.{},
    );
    try stderr_writer.interface.print(
        "seedCasAutomationDb sqlite error: {s}\n",
        .{std.mem.sliceTo(message, 0)},
    );
}

fn closeAutomationDb(io: std.Io, db: *Sqlite.sqlite3) void {
    const rc = Sqlite.sqlite3_close(db);
    if (rc != Sqlite.SQLITE_OK) warnDiagnostic(
        io,
        "automation database cleanup failed code={d}",
        .{rc},
    );
}

fn allowedUpperBoundWithTolerance(base: u64, tolerance_pct: f64) u64 {
    if (base == 0) return 1;
    const factor = 1.0 + @max(tolerance_pct, 0.0) / 100.0;
    return @intFromFloat(std.math.ceil(@as(f64, @floatFromInt(base)) * factor));
}

fn jsonFieldU64(obj: std.json.ObjectMap, key: []const u8) !u64 {
    return jsonValueU64(obj.get(key) orelse return error.InvalidData, key);
}

fn jsonValueU64(value: std.json.Value, _: []const u8) !u64 {
    return switch (value) {
        .integer => |v| if (v >= 0) @intCast(v) else error.InvalidData,
        .float => |v| if (v >= 0 and v < 0x1p64) @intFromFloat(v) else error.InvalidData,
        else => error.InvalidData,
    };
}

const CapsuleFile = struct { label: []const u8, sha256: []const u8 };
const CapsuleSource = struct {
    revision: []const u8,
    tree: []const u8,
    root: ?[]const u8 = null,
    clean: bool,
    archive: CapsuleFile,
};
const CapsuleCompiler = struct {
    approved_path: []const u8,
    version: []const u8,
    file: CapsuleFile,
};
const CapsuleBuild = struct {
    optimize: []const u8,
    step: []const u8,
    target: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
    repo_local_prefix: bool,
    isolated_caches: bool,
    product_output_isolated: bool,
};
const CapsuleProduct = struct {
    file: CapsuleFile,
    version: []const u8,
    source: CapsuleSource,
    compiler: CapsuleCompiler,
    build: CapsuleBuild,
};
const CapsuleDriverSource = struct {
    revision: []const u8,
    tree: []const u8,
    path: []const u8,
    file: CapsuleFile,
    build_file: ?CapsuleFile = null,
};
const CapsuleDriverProductSource = struct {
    revision: []const u8,
    tree: []const u8,
    archive_sha256: []const u8,
};
const CapsuleDriver = struct {
    file: CapsuleFile,
    source: CapsuleDriverSource,
    product_source: CapsuleDriverProductSource,
    compiler: CapsuleCompiler,
    build: CapsuleBuild,
};
const CapsuleMetrics = struct {
    samples_ns: []const u64,
    p50_ns: u64,
    p95_ns: u64,
    rss_samples_bytes: []const u64,
    p95_rss_bytes: u64,
    allocation_samples: []const u64 = &.{},
    p50_alloc_calls: u64 = 0,
};
const CapsuleExecution = struct {
    output_sha256: []const u8,
    semantic_output_sha256: []const u8,
    local_output_sha256: ?[]const u8,
    streamed: ?bool,
    records_scanned: ?u64,
    records_emitted: ?u64,
    physical_passes: ?u64,
    files_opened: ?u64,
    bytes_read: ?u64,
    rows_materialized: ?u64,
    compile_ns: ?u64,
    execution_ns: ?u64,
};
const CapsuleSide = struct {
    binary: CapsuleProduct,
    driver: ?CapsuleDriver = null,
    metrics: CapsuleMetrics,
    execution: CapsuleExecution,
};
const CapsuleEvidence = struct {
    schema_version: u64,
    evidence_kind: []const u8,
    machine_id: []const u8,
    binary: []const u8,
    case_id: []const u8,
    configuration_digest: []const u8,
    workload_digest: []const u8,
    baseline: CapsuleSide,
    candidate: CapsuleSide,
    compare_status: []const u8,
    compare_detail: []const u8,
};
const CapsuleRow = struct {
    case_id: []const u8,
    binary: []const u8,
    status: []const u8,
    tuple_bound: bool,
    detail: []const u8,
    evidence: CapsuleEvidence,
};
const PerformanceCapsule = struct {
    schema: []const u8,
    target: ?[]const u8,
    expected_base_sha: []const u8,
    expected_candidate_sha: []const u8,
    expected_rows: u64,
    complete: bool,
    rows: []const CapsuleRow,
};
const CapsuleLocator = struct {
    schema: []const u8,
    capsule: ?CapsuleFile,
    status: ?[]const u8 = null,
};

fn cmdReport(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
) !void {
    const data = try loadReportCapsuleBytes(fs, allocator);
    defer allocator.free(data);
    var parsed = std.json.parseFromSlice(
        PerformanceCapsule,
        allocator,
        data,
        .{},
    ) catch return error.InvalidCompareSummary;
    defer parsed.deinit();
    try validatePerformanceCapsule(fs, environ, allocator, parsed.value, true);
    try validateCutoverReportSource(fs, environ, allocator, parsed.value);
    try renderReportTotals(fs.io, allocator, parsed.value.rows);
}

fn loadReportCapsuleBytes(fs: durable_store.Fs, allocator: std.mem.Allocator) ![]u8 {
    const machine_dir = try resolveMachineDir(fs, allocator, ".perf-local");
    defer allocator.free(machine_dir);
    const locator_path = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "reports", "current-capsule.json" },
    );
    defer allocator.free(locator_path);
    const locator_data = readRegularFileAlloc(
        fs,
        allocator,
        locator_path,
        64 * 1024,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCompareSummary,
        else => return err,
    };
    defer allocator.free(locator_data);
    var locator = std.json.parseFromSlice(
        CapsuleLocator,
        allocator,
        locator_data,
        .{},
    ) catch return error.InvalidCompareSummary;
    defer locator.deinit();
    if (!std.mem.eql(
        u8,
        locator.value.schema,
        "performance-capsule-ref/v1",
    )) return error.InvalidCompareSummary;
    return loadCapsuleFileAlloc(
        fs,
        allocator,
        locator.value.capsule orelse return error.MissingCompareSummary,
        4 * 1024 * 1024,
    );
}

fn validateCutoverReportSource(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    capsule: PerformanceCapsule,
) !void {
    const target = capsule.target orelse return;
    if (!std.mem.eql(u8, target, "cutover")) return;
    const value = ReportTuple{
        .base_sha = capsule.expected_base_sha,
        .candidate_sha = capsule.expected_candidate_sha,
    };
    const environment = environ orelse return error.ExpectedSourceShaRequired;
    const current_sha = try sourceShaForRootAlloc(fs, environ, allocator, ".");
    defer allocator.free(current_sha);
    try requireCutoverReportTuple(environment, value, current_sha);
    try requireCleanSourceRoot(fs, environ, allocator, ".");
}

fn renderReportTotals(io: std.Io, allocator: std.mem.Allocator, rows: []const CapsuleRow) !void {
    var totals = std.StringHashMap(ReportCounts).init(allocator);
    defer totals.deinit();
    for (rows) |row| {
        const entry = try totals.getOrPutValue(row.binary, .{});
        if (std.mem.eql(u8, row.status, "PASS")) {
            entry.value_ptr.pass += 1;
        } else {
            entry.value_ptr.fail += 1;
        }
    }

    var stdout_writer = std.Io.File.stdout().writer(
        io,
        &.{},
    );
    const stdout = &stdout_writer.interface;
    var row_keys: std.ArrayList([]const u8) = .empty;
    defer row_keys.deinit(allocator);
    var it = totals.iterator();
    while (it.next()) |entry| {
        try row_keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, row_keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (row_keys.items) |key| {
        const counts = totals.get(key).?;
        try stdout.print("{s}\tpass={d}\tfail={d}\n", .{ key, counts.pass, counts.fail });
    }
}

const ReportTuple = struct {
    base_sha: []const u8,
    candidate_sha: []const u8,
};

fn validatePerformanceCapsule(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    capsule: PerformanceCapsule,
    require_pass: bool,
) !void {
    if (!std.mem.eql(u8, capsule.schema, "performance-capsule/v1") or
        !validFullRevision(capsule.expected_base_sha) or
        !validFullRevision(capsule.expected_candidate_sha) or
        !capsule.complete or capsule.expected_rows == 0 or
        capsule.expected_rows != capsule.rows.len or
        capsule.expected_rows != matchingCaseCount(capsule.target))
    {
        return error.IncompleteComparison;
    }
    for (capsule.rows, 0..) |row, index| {
        if (row.case_id.len == 0 or row.binary.len == 0 or
            row.detail.len == 0 or
            !matchesTarget(row.case_id, row.binary, capsule.target))
        {
            return error.UnexpectedPerfCase;
        }
        const expected_binary = expectedBinaryForCase(row.case_id) orelse
            return error.InvalidCompareSummary;
        if (!std.mem.eql(u8, row.binary, expected_binary)) {
            return error.InvalidCompareSummary;
        }
        for (capsule.rows[0..index]) |prior| {
            if (std.mem.eql(u8, prior.case_id, row.case_id)) {
                return error.DuplicatePerfCase;
            }
        }
        if (require_pass and !std.mem.eql(u8, row.status, "PASS")) {
            return error.PerformanceRegression;
        }
        if (!row.tuple_bound) return error.UnboundCutoverComparison;
        try validatePairedEvidence(
            fs,
            environ,
            allocator,
            row,
            capsule.expected_base_sha,
            capsule.expected_candidate_sha,
        );
    }
}

fn validatePairedEvidence(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    row: CapsuleRow,
    expected_base: []const u8,
    expected_candidate: []const u8,
) !void {
    const evidence = row.evidence;
    if (evidence.schema_version != 3 or
        !std.mem.eql(u8, evidence.evidence_kind, "paired") or
        evidence.machine_id.len == 0)
    {
        return error.InvalidPerfEvidenceFile;
    }
    if (!std.mem.eql(u8, evidence.case_id, row.case_id) or
        !std.mem.eql(u8, evidence.binary, row.binary))
    {
        return error.PerfEvidenceIdentityMismatch;
    }
    const config = evidenceCaseConfig(row.case_id) orelse
        return error.InvalidPerfEvidenceFile;
    const configuration_digest = try caseConfigurationDigest(config);
    if (evidence.configuration_digest.len != "sha256:".len + 64 or
        !std.mem.eql(
            u8,
            evidence.configuration_digest["sha256:".len..],
            &configuration_digest,
        ))
    {
        return error.PerfDriverConfigurationMismatch;
    }
    try requireDigestIdentity(evidence.workload_digest);
    try validateProductEvidence(fs, allocator, evidence.baseline.binary, expected_base);
    try validateProductEvidence(fs, allocator, evidence.candidate.binary, expected_candidate);
    if (!std.mem.eql(
        u8,
        evidence.baseline.binary.compiler.file.sha256,
        evidence.candidate.binary.compiler.file.sha256,
    )) return error.CompilerBinaryChanged;
    const deep = isDeepCaseId(row.case_id);
    if (deep) {
        try validatePairedDeepDrivers(fs, environ, allocator, evidence);
    } else if (evidence.baseline.driver != null or
        evidence.candidate.driver != null)
    {
        return error.InvalidPerfEvidenceFile;
    }
    try validateRetainedMetrics(allocator, evidence.baseline.metrics, config, deep);
    try validateRetainedMetrics(allocator, evidence.candidate.metrics, config, deep);
    try validateExecution(evidence.baseline.execution);
    try validateExecution(evidence.candidate.execution);
    try requireExecutionParity(
        try executionEvidence(evidence.baseline.execution),
        try executionEvidence(evidence.candidate.execution),
    );
    const computed = if (deep)
        try compareBalancedDeepMetrics(
            deepCaseForId(row.case_id) orelse return error.InvalidPerfEvidenceFile,
            evidence.baseline.metrics,
            evidence.candidate.metrics,
        )
    else
        try compareMeasuredMetrics(config, evidence.baseline.metrics, evidence.candidate.metrics);
    if (!std.mem.eql(u8, computed.status, evidence.compare_status) or
        !std.mem.eql(u8, evidence.compare_status, row.status))
    {
        return error.PerfVerdictMismatch;
    }
}

fn validatePairedDeepDrivers(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    evidence: CapsuleEvidence,
) !void {
    const case_cfg = deepCaseForId(evidence.case_id) orelse
        return error.InvalidPerfEvidenceFile;
    const baseline_driver = evidence.baseline.driver orelse
        return error.IncompletePerfDriverEvidence;
    const candidate_driver = evidence.candidate.driver orelse
        return error.IncompletePerfDriverEvidence;
    try validateDriverEvidence(fs, allocator, baseline_driver, evidence.baseline.binary);
    try validateDriverEvidence(fs, allocator, candidate_driver, evidence.candidate.binary);
    for ([_]CapsuleDriver{ baseline_driver, candidate_driver }) |driver| {
        const optimization = isOptimizationDriverSource(driver.source);
        if (optimization != (case_cfg.driver_kind == .optimization)) {
            return error.PerfDriverSourceMismatch;
        }
    }
    if (case_cfg.driver_kind == .optimization) {
        try validateRetainedOptimization(
            fs,
            environ,
            allocator,
            case_cfg,
            evidence.workload_digest,
            evidence.baseline,
        );
        try validateRetainedOptimization(
            fs,
            environ,
            allocator,
            case_cfg,
            evidence.workload_digest,
            evidence.candidate,
        );
    } else {
        try validateRetainedDeepWorkload(
            fs,
            environ,
            allocator,
            case_cfg,
            evidence.workload_digest,
            evidence.baseline.binary.source.revision,
            evidence.candidate.binary.source.revision,
        );
    }
    if (!std.mem.eql(
        u8,
        baseline_driver.source.file.sha256,
        candidate_driver.source.file.sha256,
    ) or !std.mem.eql(
        u8,
        baseline_driver.source.revision,
        candidate_driver.source.revision,
    )) return error.PerfDriverSourceMismatch;
}

fn validateRetainedOptimization(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    workload_identity: []const u8,
    side: CapsuleSide,
) !void {
    const driver = side.driver orelse return error.IncompletePerfDriverEvidence;
    var retained_driver = try capsuleSealedFile(fs, allocator, driver.file);
    defer retained_driver.deinit(allocator);
    const oracle = try optimizationOracle(
        fs,
        environ,
        allocator,
        retained_driver,
        case_cfg.descriptor.case_id,
    );
    try verifyCapsuleFile(fs, allocator, driver.source.file);
    try verifyCapsuleFile(
        fs,
        allocator,
        driver.source.build_file orelse return error.PerfDriverSourceMismatch,
    );
    try validateOptimizationObservation(oracle, workload_identity, side.execution);
}

fn validateOptimizationObservation(
    oracle: OptimizationOracle,
    workload_identity: []const u8,
    retained_execution: CapsuleExecution,
) !void {
    const workload = try digestBytes(workload_identity);
    if (!std.mem.eql(u8, &workload, &oracle.workload_digest)) return error.PerfWorkloadMismatch;
    const execution = try executionEvidence(retained_execution);
    if (!std.mem.eql(u8, &execution.output_sha256, &oracle.execution.output_sha256) or
        !std.mem.eql(
            u8,
            &execution.semantic_output_sha256,
            &oracle.execution.semantic_output_sha256,
        ))
    {
        return error.PerfSemanticOutputMismatch;
    }
}

fn validateRetainedDeepWorkload(
    fs: durable_store.Fs,
    environ: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    identity: []const u8,
    baseline_revision: []const u8,
    candidate_revision: []const u8,
) !void {
    if (identity.len != "sha256:".len + 64) {
        return error.PerfWorkloadMismatch;
    }
    for ([_][]const u8{
        baseline_revision,
        candidate_revision,
    }) |revision| {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(case_cfg.descriptor.case_id);
        hasher.update(&.{0});
        hasher.update(@tagName(case_cfg.setup));
        hasher.update(&.{0});
        var encoded: [32]u8 = undefined;
        hasher.update(try std.fmt.bufPrint(
            &encoded,
            "{d}",
            .{case_cfg.batch_iterations},
        ));
        for ([_][]const u8{
            "apps/seq/src/v1/fixtures/message-observation.json",
            "apps/seq/src/v1/fixtures/rollout.jsonl",
        }) |path| {
            const object = try allocator.print(
                "{s}:{s}",
                .{ revision, path },
            );
            defer allocator.free(object);
            const result = try runChildCaptureOutput(
                fs,
                environ,
                allocator,
                ".",
                &.{ git_binary, "show", object },
            );
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.exit_code != 0) return error.PerfWorkloadMismatch;
            hasher.update(&.{0});
            hasher.update(path);
            hasher.update(&.{0});
            hasher.update(result.stdout);
        }
        var raw: [32]u8 = undefined;
        hasher.final(&raw);
        const digest = std.fmt.bytesToHex(raw, .lower);
        if (!std.mem.eql(u8, identity["sha256:".len..], &digest)) {
            return error.PerfWorkloadMismatch;
        }
    }
}

fn evidenceCaseConfig(case_id: []const u8) ?CompatCase {
    for (CompatCases) |config| {
        if (std.mem.eql(u8, config.descriptor.case_id, case_id)) return config;
    }
    if (deepCaseForId(case_id)) |deep| {
        const ledger_case = std.mem.eql(u8, deep.descriptor.binary, "ledger");
        var config = rootCompat(
            deep.descriptor,
            if (ledger_case) "build-ledger" else "build-seq",
            if (ledger_case) "zig-out/bin/ledger" else "zig-out/bin/seq",
            if (ledger_case) .ledger_project else .seq_observe,
        );
        config.samples = deep.samples;
        config.warmups = deep.warmups;
        config.tolerance_pct = deep.tolerance_pct;
        return config;
    }
    return null;
}

fn validateProductEvidence(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    product: CapsuleProduct,
    expected_revision: []const u8,
) !void {
    if (product.version.len == 0 or
        !std.mem.eql(u8, product.source.revision, expected_revision) or
        !validFullRevision(product.source.tree) or !product.source.clean or
        product.source.root == null or product.source.root.?.len == 0)
    {
        return error.PerfEvidenceIdentityMismatch;
    }
    try verifyCapsuleFile(fs, allocator, product.file);
    try verifyCapsuleFile(fs, allocator, product.source.archive);
    try validateCompilerEvidence(fs, allocator, product.compiler);
    try validateIsolatedBuild(product.build);
}

fn validateDriverEvidence(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    driver: CapsuleDriver,
    product: CapsuleProduct,
) !void {
    try validateDriverSourceMetadata(driver.source);
    if (isOptimizationDriverSource(driver.source)) {
        try validateOptimizationDriverBuild(driver.build);
    }
    if (!std.mem.eql(u8, driver.product_source.revision, product.source.revision) or !std.mem.eql(
        u8,
        driver.product_source.tree,
        product.source.tree,
    ) or !std.mem.eql(u8, driver.product_source.archive_sha256, product.source.archive.sha256)) {
        return error.PerfEvidenceIdentityMismatch;
    }
    try verifyCapsuleFile(fs, allocator, driver.file);
    try verifyCapsuleFile(fs, allocator, driver.source.file);
    if (driver.source.build_file) |build_file| {
        try verifyCapsuleFile(fs, allocator, build_file);
    }
    try validateCompilerEvidence(fs, allocator, driver.compiler);
    if (!std.mem.eql(
        u8,
        driver.compiler.file.sha256,
        product.compiler.file.sha256,
    )) return error.CompilerBinaryChanged;
    try validateIsolatedBuild(driver.build);
}

fn validateOptimizationDriverBuild(build: CapsuleBuild) !void {
    if (!std.mem.eql(u8, build.step, "optimization-driver") or
        !std.mem.eql(u8, build.target orelse "", "aarch64-macos") or
        !std.mem.eql(u8, build.cpu orelse "", "baseline"))
    {
        return error.InvalidPerfEvidenceFile;
    }
}

fn isOptimizationDriverSource(source: CapsuleDriverSource) bool {
    return driverSourceMatchesIdentity(source, active_optimization_driver_v1) or
        driverSourceMatchesIdentity(source, legacy_optimization_summary_driver_v1) or
        driverSourceMatchesIdentity(source, legacy_summary_optimization_driver_v1) or
        driverSourceMatchesIdentity(source, legacy_optimization_driver_v1);
}

fn validateDriverSourceMetadata(source: CapsuleDriverSource) !void {
    if (source.build_file) |build_file| {
        if (driverSourceMatchesIdentity(source, active_optimization_driver_v1) and
            std.mem.eql(u8, build_file.sha256, "sha256:" ++ optimization_build_sha256))
        {
            return;
        }
        if ((driverSourceMatchesIdentity(source, legacy_optimization_summary_driver_v1) or
            driverSourceMatchesIdentity(source, legacy_summary_optimization_driver_v1)) and
            std.mem.eql(
                u8,
                build_file.sha256,
                "sha256:" ++ legacy_optimization_summary_build_sha256,
            ))
        {
            return;
        }
        if (driverSourceMatchesIdentity(source, legacy_optimization_driver_v1) and
            std.mem.eql(u8, build_file.sha256, "sha256:" ++ legacy_optimization_build_sha256))
        {
            return;
        }
    } else if (driverSourceMatchesIdentity(source, active_seq_replay_driver_v2) or
        driverSourceMatchesIdentity(source, legacy_seq_replay_driver_v2) or
        driverSourceMatchesIdentity(source, legacy_summary_seq_replay_driver_v2) or
        driverSourceMatchesIdentity(source, legacy_seq_replay_driver_v1) or
        driverSourceMatchesIdentity(source, legacy_generic_driver_v1))
    {
        return;
    }
    return error.PerfEvidenceIdentityMismatch;
}

fn driverSourceMatchesIdentity(source: CapsuleDriverSource, identity: DriverSourceIdentity) bool {
    if (!std.mem.eql(u8, source.revision, identity.revision) or
        !std.mem.eql(u8, source.tree, identity.tree) or
        !std.mem.eql(u8, source.path, identity.locator) or
        source.file.sha256.len != "sha256:".len + identity.sha256.len)
    {
        return false;
    }
    return std.mem.eql(u8, source.file.sha256[0.."sha256:".len], "sha256:") and
        std.mem.eql(
            u8,
            source.file.sha256["sha256:".len..],
            identity.sha256,
        );
}

fn validateCompilerEvidence(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    compiler: CapsuleCompiler,
) !void {
    if (!std.fs.path.isAbsolute(compiler.approved_path) or
        compiler.version.len == 0)
    {
        return error.InvalidPerfEvidenceFile;
    }
    try verifyCapsuleFile(fs, allocator, compiler.file);
    if (compiler.file.sha256.len != "sha256:".len + 64 or
        !std.mem.eql(
            u8,
            compiler.file.sha256[0.."sha256:".len],
            "sha256:",
        ))
    {
        return error.CompilerBinaryChanged;
    }
    try requireCompilerDigestAtPath(
        fs,
        compiler.approved_path,
        compiler.file.sha256["sha256:".len..],
    );
}

fn validateIsolatedBuild(build: CapsuleBuild) !void {
    if (!std.mem.eql(u8, build.optimize, "ReleaseFast") or
        build.step.len == 0 or !build.repo_local_prefix or
        !build.isolated_caches or !build.product_output_isolated)
    {
        return error.InvalidPerfEvidenceFile;
    }
}

fn validateRetainedMetrics(
    allocator: std.mem.Allocator,
    metrics: CapsuleMetrics,
    config: CompatCase,
    deep: bool,
) !void {
    const expected_latency = config.samples * paired_comparison_rounds;
    const expected_resources = if (deep)
        paired_comparison_rounds
    else
        expected_latency;
    if (metrics.samples_ns.len != expected_latency or
        metrics.rss_samples_bytes.len != expected_resources or
        metrics.allocation_samples.len !=
            (if (deep) paired_comparison_rounds else 0))
    {
        return error.InvalidPerfMeasurementCount;
    }
    const latency = try core_perf.percentilesU64(allocator, metrics.samples_ns, &.{ 50, 95 });
    if (metrics.p50_ns !=
        latency[0] or
        metrics.p95_ns !=
            latency[1] or
        metrics.p95_rss_bytes !=
            try core_perf.percentileU64(allocator, metrics.rss_samples_bytes, 95) or
        (deep and metrics.p50_alloc_calls !=
            try core_perf.percentileU64(allocator, metrics.allocation_samples, 50)))
    {
        return error.InvalidPerfDerivedMetric;
    }
}

fn validateExecution(value: CapsuleExecution) !void {
    try requireDigestIdentity(value.output_sha256);
    try requireDigestIdentity(value.semantic_output_sha256);
    if (value.local_output_sha256) |digest| {
        try requireDigestIdentity(digest);
    }
}

fn executionEvidence(value: CapsuleExecution) !MeasuredOutputEvidence {
    return .{
        .output_sha256 = try digestBytes(value.output_sha256),
        .semantic_output_sha256 = try digestBytes(value.semantic_output_sha256),
        .local_output_sha256 = if (value.local_output_sha256) |digest|
            try digestBytes(digest)
        else
            null,
        .streamed = value.streamed,
        .records_scanned = value.records_scanned,
        .records_emitted = value.records_emitted,
        .physical_passes = value.physical_passes,
        .files_opened = value.files_opened,
        .bytes_read = value.bytes_read,
        .rows_materialized = value.rows_materialized,
        .compile_ns = value.compile_ns,
        .execution_ns = value.execution_ns,
    };
}

fn requireDigestIdentity(encoded: []const u8) !void {
    _ = try digestBytes(encoded);
}

fn digestBytes(encoded: []const u8) ![64]u8 {
    if (!validSha256Identity(encoded)) {
        return error.InvalidPerfEvidenceFile;
    }
    var digest: [64]u8 = undefined;
    @memcpy(&digest, encoded["sha256:".len..]);
    return digest;
}

fn expectedBinaryForCase(case_id: []const u8) ?[]const u8 {
    for (CompatCases) |case_cfg| {
        if (std.mem.eql(
            u8,
            case_id,
            case_cfg.descriptor.case_id,
        )) return case_cfg.descriptor.binary;
    }
    if (deepCaseForId(case_id)) |case_cfg| return case_cfg.descriptor.binary;
    return null;
}

fn isDeepCaseId(case_id: []const u8) bool {
    return deepCaseForId(case_id) != null;
}

fn loadCapsuleFileAlloc(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    file: CapsuleFile,
    max_bytes: usize,
) ![]u8 {
    try requireDigestIdentity(file.sha256);
    if (file.label.len == 0 or
        !std.mem.eql(u8, file.label, std.fs.path.basename(file.label)) or
        std.mem.eql(u8, file.label, ".") or
        std.mem.eql(u8, file.label, ".."))
    {
        return error.PerfEvidencePathOutsideCapsule;
    }
    const blobs_root = try resolveCapsuleBlobsRoot(fs, allocator);
    defer allocator.free(blobs_root);
    const digest = file.sha256["sha256:".len..];
    var root = try std.Io.Dir.openDirAbsolute(
        fs.io,
        blobs_root,
        .{ .follow_symlinks = false },
    );
    defer root.close(fs.io);
    const digest_stat = try root.statFile(
        fs.io,
        digest,
        .{ .follow_symlinks = false },
    );
    if (digest_stat.kind == .sym_link or digest_stat.kind != .directory) {
        return error.PerfEvidencePathOutsideCapsule;
    }
    const relative_path = try std.fs.path.join(allocator, &.{ digest, file.label });
    defer allocator.free(relative_path);
    var opened = try root.openFile(
        fs.io,
        relative_path,
        .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        },
    );
    defer opened.close(fs.io);
    return readVerifiedCapsuleFileAlloc(fs.io, allocator, opened, file.sha256, max_bytes);
}

fn resolveCapsuleBlobsRoot(fs: durable_store.Fs, allocator: std.mem.Allocator) ![]u8 {
    const machine_dir_relative = try resolveMachineDir(
        fs,
        allocator,
        ".perf-local",
    );
    defer allocator.free(machine_dir_relative);
    durable_store.rejectSymlinkComponents(fs, machine_dir_relative) catch |err| switch (err) {
        error.SymlinkComponent => return error.PerfEvidencePathOutsideCapsule,
        else => return err,
    };
    try requireCapsuleDirectory(fs, machine_dir_relative);
    const machine_dir = try fs.directory().realPathFileAlloc(
        fs.io,
        machine_dir_relative,
        allocator,
    );
    defer allocator.free(machine_dir);
    const capsules_root = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "capsules" },
    );
    defer allocator.free(capsules_root);
    try requireCapsuleDirectory(fs, capsules_root);
    const blobs_root = try std.fs.path.join(
        allocator,
        &.{ capsules_root, "blobs" },
    );
    errdefer allocator.free(blobs_root);
    try requireCapsuleDirectory(fs, blobs_root);
    return blobs_root;
}

fn requireCapsuleDirectory(fs: durable_store.Fs, path: []const u8) !void {
    const stat = try fs.directory().statFile(
        fs.io,
        path,
        .{ .follow_symlinks = false },
    );
    if (stat.kind == .sym_link or stat.kind != .directory) {
        return error.PerfEvidencePathOutsideCapsule;
    }
}

fn readVerifiedCapsuleFileAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    opened: std.Io.File,
    sha256: []const u8,
    max_bytes: usize,
) ![]u8 {
    const before = try opened.stat(
        io,
    );
    if (before.kind != .file or before.nlink != 1 or
        before.size > max_bytes)
    {
        return error.InvalidPerfEvidenceFile;
    }
    const size = std.math.cast(usize, before.size) orelse
        return error.InvalidPerfEvidenceFile;
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    const count = try opened.readPositionalAll(
        io,
        data,
        0,
    );
    if (count != size) return error.PerfEvidenceFileChanged;
    const after = try opened.stat(
        io,
    );
    if (after.kind != .file or after.nlink != 1 or
        after.size != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds)
    {
        return error.PerfEvidenceFileChanged;
    }
    const observed = evidenceDigest(data);
    if (!std.mem.eql(
        u8,
        &observed,
        sha256["sha256:".len..],
    )) return error.PerfEvidenceDigestMismatch;
    return data;
}

fn verifyCapsuleFile(fs: durable_store.Fs, allocator: std.mem.Allocator, file: CapsuleFile) !void {
    const data = try loadCapsuleFileAlloc(fs, allocator, file, max_sealed_evidence_bytes);
    allocator.free(data);
}

fn capsuleSealedFile(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    file: CapsuleFile,
) !SealedFile {
    try verifyCapsuleFile(fs, allocator, file);
    const blobs_root = try resolveCapsuleBlobsRoot(fs, allocator);
    defer allocator.free(blobs_root);
    const digest = try digestBytes(file.sha256);
    const path = try std.fs.path.join(allocator, &.{ blobs_root, &digest, file.label });
    defer allocator.free(path);
    return .{ .path = try allocator.dupeSentinel(u8, path, 0), .sha256 = digest };
}

fn requireCutoverReportTuple(
    environment: *const std.process.Environ.Map,
    tuple: ReportTuple,
    current_sha: []const u8,
) !void {
    try requireExpectedSourceShas(environment, tuple.base_sha, tuple.candidate_sha);
    if (!std.mem.eql(u8, current_sha, tuple.candidate_sha)) {
        return error.CandidateSourceShaMismatch;
    }
}

fn resolveMachineDir(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    perf_root: []const u8,
) ![]u8 {
    const current_name = try currentMachineDirName(allocator);
    defer allocator.free(current_name);
    const preferred = try std.fs.path.join(allocator, &.{ perf_root, current_name });
    errdefer allocator.free(preferred);
    if (!pathExists(fs, preferred)) return error.MissingMachineDir;
    return preferred;
}

fn currentMachineDirName(allocator: std.mem.Allocator) ![]u8 {
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host_full = try std.posix.gethostname(&host_buf);
    const host = host_full[0 .. std.mem.indexOfScalar(u8, host_full, '.') orelse host_full.len];
    return allocator.print("{s}-{s}-{s}-zig{s}", .{
        switch (builtin.target.os.tag) {
            .macos => "darwin",
            else => @tagName(builtin.target.os.tag),
        },
        switch (builtin.target.cpu.arch) {
            .aarch64 => "arm64",
            else => @tagName(builtin.target.cpu.arch),
        },
        host,
        builtin.zig_version_string,
    });
}

fn pathExists(fs: durable_store.Fs, path: []const u8) bool {
    fs.directory().access(
        fs.io,
        path,
        .{},
    ) catch return false;
    return true;
}

fn makeRepoAwarePath(fs: durable_store.Fs, allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = try fs.directory().realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(cwd);
    if (std.fs.path.isAbsolute(path) and std.mem.startsWith(u8, path, cwd)) {
        const rel = if (path.len == cwd.len) "." else path[cwd.len + 1 ..];
        try fs.directory().createDirPath(fs.io, rel);
        return;
    }
    try fs.directory().createDirPath(fs.io, path);
}

fn isKnownBinaryName(text: []const u8) bool {
    for (allManifests()) |manifest| {
        if (std.mem.eql(u8, manifest.binary, text)) return true;
        for (manifest.cases) |case_desc| {
            if (std.mem.eql(u8, case_desc.binary, text)) return true;
        }
    }
    return false;
}

fn writeEvidenceFileAtomic(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    mode: u32,
) !void {
    const io = fs.io;
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or
        std.mem.eql(u8, base, ".."))
    {
        return error.InvalidPerfEvidencePath;
    }
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, parent);
    try requireReplaceableEvidenceTarget(fs, path);
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(io, parent, .{ .follow_symlinks = false })
    else
        try fs.directory().openDir(io, parent, .{ .follow_symlinks = false });
    defer dir.close(io);
    const tag = std.Io.Clock.awake.now(io).nanoseconds;
    const temp_name = try allocator.print(
        ".{s}.{d}.tmp",
        .{ base, tag },
    );
    defer allocator.free(temp_name);
    var file = try createEvidenceTempFile(dir, io, temp_name, mode);
    var file_open = true;
    errdefer if (file_open) file.close(io);
    errdefer dir.deleteFile(io, temp_name) catch |err| {
        printDiagnostic(
            fs.io,
            "perf_hub warning: remove temporary evidence: {s}\n",
            .{@errorName(err)},
        );
    };
    const before = try file.stat(io);
    if (before.kind != .file or before.nlink != 1) {
        return error.InvalidPerfEvidenceFile;
    }
    try file.writeStreamingAll(io, data);
    try file.sync(io);
    const after = try file.stat(io);
    if (after.kind != .file or after.nlink != 1 or
        after.size != data.len)
    {
        return error.InvalidPerfEvidenceFile;
    }
    file.close(io);
    file_open = false;
    try requireReplaceableEvidenceTarget(fs, path);
    try dir.rename(temp_name, dir, base, io);
    var dir_file = try dir.openFile(io, ".", .{
        .allow_directory = true,
        .follow_symlinks = false,
        .path_only = false,
    });
    defer dir_file.close(io);
    try dir_file.sync(io);
}

fn createEvidenceTempFile(
    dir: std.Io.Dir,
    io: std.Io,
    temp_name: []const u8,
    mode: u32,
) !std.Io.File {
    return dir.createFile(io, temp_name, .{
        .exclusive = true,
        .read = true,
        .truncate = false,
        .permissions = if (@hasDecl(
            std.Io.File.Permissions,
            "fromMode",
        ))
            std.Io.File.Permissions.fromMode(
                @as(std.posix.mode_t, @intCast(mode)),
            )
        else
            .default_file,
    });
}

fn requireReplaceableEvidenceTarget(fs: durable_store.Fs, path: []const u8) !void {
    const stat = fs.directory().statFile(
        fs.io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.PerfEvidenceSymlink;
    if (stat.kind != .file or stat.nlink != 1) {
        return error.InvalidPerfEvidenceFile;
    }
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

fn printDiagnostic(io: std.Io, comptime format: []const u8, args: anytype) void {
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    var buffer: [64]u8 = undefined;
    const stderr = io.lockStderr(&buffer, null) catch return;
    defer io.unlockStderr();
    stderr.file_writer.interface.print(format, args) catch return;
}

fn warnDiagnostic(io: std.Io, comptime format: []const u8, args: anytype) void {
    if (comptime !std.log.logEnabled(.warn, .default)) return;
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    var buffer: [64]u8 = undefined;
    const stderr = (io.lockStderr(&buffer, null) catch return).terminal();
    defer io.unlockStderr();
    std.log.defaultLogFileTerminal(.warn, .default, format, args, stderr) catch return;
}

fn restoreTestCwd(io: std.Io, path: []const u8) void {
    std.process.setCurrentPath(io, path) catch |err| {
        std.debug.panic("restore test cwd: {s}", .{@errorName(err)});
    };
}

test "resolveMachineDir rejects a legacy-only directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd_before = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(io, tmp.dir);
    defer restoreTestCwd(io, cwd_before);

    try tmp.dir.createDirPath(io, ".perf-local/legacy-only");
    try std.testing.expectError(
        error.MissingMachineDir,
        resolveMachineDir(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            alloc,
            ".perf-local",
        ),
    );
}

test "capsule files are digest-addressed beneath the current machine root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fs = durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd_before = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_before);
    try std.process.setCurrentDir(io, tmp.dir);
    defer restoreTestCwd(io, cwd_before);
    const tmp_root = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(tmp_root);

    const machine_dir = try ensureCurrentMachineDir(
        fs,
        allocator,
    );
    defer allocator.free(machine_dir);
    const absolute_machine_dir =
        try absoluteMachineDir(fs, allocator);
    defer allocator.free(absolute_machine_dir);
    try std.testing.expect(std.fs.path.isAbsolute(absolute_machine_dir));
    var sealed = try sealEvidenceBytes(
        fs,
        allocator,
        machine_dir,
        "payload",
        "bound",
        0o600,
    );
    defer sealed.deinit(allocator);
    const identity = try allocator.print("sha256:{s}", .{sealed.sha256});
    defer allocator.free(identity);
    const valid = CapsuleFile{
        .label = "payload",
        .sha256 = identity,
    };
    const bytes =
        try loadCapsuleFileAlloc(fs, allocator, valid, 64);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("bound", bytes);
    var reopened = try capsuleSealedFile(
        fs,
        allocator,
        valid,
    );
    defer reopened.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &sealed.sha256, &reopened.sha256);
    try verifySealedFile(fs, reopened);

    try expectCapsuleRejectsLinkedRoot(
        fs,
        tmp.dir,
        valid,
    );
    try std.testing.expectError(
        error.PerfEvidencePathOutsideCapsule,
        loadCapsuleFileAlloc(
            fs,
            allocator,
            .{ .label = "../payload", .sha256 = identity },
            64,
        ),
    );
    try expectCapsuleRejectsLinkedBlob(
        fs,
        machine_dir,
        tmp_root,
    );
}

fn expectCapsuleRejectsLinkedRoot(fs: durable_store.Fs, dir: std.Io.Dir, valid: CapsuleFile) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try dir.rename(
        ".perf-local",
        dir,
        "external-perf-local",
        io,
    );
    try dir.symLink(
        io,
        "external-perf-local",
        ".perf-local",
        .{ .is_directory = true },
    );
    try std.testing.expectError(
        error.PerfEvidencePathOutsideCapsule,
        loadCapsuleFileAlloc(fs, allocator, valid, 64),
    );
    try dir.deleteFile(io, ".perf-local");
    try dir.rename(
        "external-perf-local",
        dir,
        ".perf-local",
        io,
    );
}

fn expectCapsuleRejectsLinkedBlob(
    fs: durable_store.Fs,
    machine_dir: []const u8,
    tmp_root: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var symlinked = try sealEvidenceBytes(
        fs,
        allocator,
        machine_dir,
        "payload",
        "external",
        0o600,
    );
    defer symlinked.deinit(allocator);
    const symlink_identity = try allocator.print(
        "sha256:{s}",
        .{symlinked.sha256},
    );
    defer allocator.free(symlink_identity);
    const symlink_blob_dir = std.fs.path.dirname(symlinked.path).?;
    try std.Io.Dir.deleteFileAbsolute(io, symlinked.path);
    try std.Io.Dir.deleteDirAbsolute(io, symlink_blob_dir);
    const external_dir = try std.fs.path.join(
        allocator,
        &.{ tmp_root, "capsule-symlink-target" },
    );
    defer allocator.free(external_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(fs, external_dir);
    const external_path = try std.fs.path.join(
        allocator,
        &.{ external_dir, "payload" },
    );
    defer allocator.free(external_path);
    try writeEvidenceFileAtomic(
        fs,
        allocator,
        external_path,
        "external",
        0o600,
    );
    try std.Io.Dir.symLinkAbsolute(
        io,
        external_dir,
        symlink_blob_dir,
        .{ .is_directory = true },
    );
    try std.testing.expectError(
        error.PerfEvidencePathOutsideCapsule,
        loadCapsuleFileAlloc(
            fs,
            allocator,
            .{
                .label = "payload",
                .sha256 = symlink_identity,
            },
            64,
        ),
    );
}

test "driver source metadata accepts active and legacy tuples only" {
    var source = CapsuleDriverSource{
        .revision = legacy_generic_driver_v1.revision,
        .tree = legacy_generic_driver_v1.tree,
        .path = legacy_generic_driver_v1.locator,
        .file = .{
            .label = "perf_hub.zig",
            .sha256 = "sha256:" ++
                legacy_generic_driver_v1.sha256,
        },
    };
    try validateDriverSourceMetadata(source);
    source = .{
        .revision = legacy_seq_replay_driver_v1.revision,
        .tree = legacy_seq_replay_driver_v1.tree,
        .path = legacy_seq_replay_driver_v1.locator,
        .file = .{
            .label = "perf_hub.zig",
            .sha256 = "sha256:" ++ legacy_seq_replay_driver_v1.sha256,
        },
    };
    try validateDriverSourceMetadata(source);

    source.revision = legacy_generic_driver_v1.revision;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source.revision = legacy_seq_replay_driver_v1.revision;
    source.tree = legacy_generic_driver_v1.tree;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source.tree = legacy_seq_replay_driver_v1.tree;
    source.path = legacy_generic_driver_v1.locator;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source.path = legacy_seq_replay_driver_v1.locator;
    source.file.sha256 = "sha256:" ++ legacy_generic_driver_v1.sha256;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
}

fn testOptimizationDriverSource() CapsuleDriverSource {
    return .{
        .revision = active_optimization_driver_v1.revision,
        .tree = active_optimization_driver_v1.tree,
        .path = active_optimization_driver_v1.locator,
        .file = .{
            .label = "optimization_driver.zig",
            .sha256 = "sha256:" ++ active_optimization_driver_v1.sha256,
        },
        .build_file = .{
            .label = "optimization_build.zig",
            .sha256 = "sha256:" ++ optimization_build_sha256,
        },
    };
}

test "pre-migration optimization evidence retains its exact source and build tuple" {
    var source = CapsuleDriverSource{
        .revision = "5ba1b03b38b1bc72f7735931324f75679af43907d01338bb7c017b9b1f060925",
        .tree = "4eb77ac0c61b57e3d739be6a1d9a5a2f023e28855f06fd78eac94c0a4e9ba9dd",
        .path = "tools/optimization_driver.zig",
        .file = .{
            .label = "perf_hub.zig",
            .sha256 = "sha256:5ba1b03b38b1bc72f7735931324f75679af43907d01338bb7c017b9b1f060925",
        },
        .build_file = .{
            .label = "build.zig",
            .sha256 = "sha256:5eaae873185f3f472269a7dcc1d2c41c61f56fbfbc13542f941acc98ef082769",
        },
    };
    try validateDriverSourceMetadata(source);
    const historical = source;
    source.build_file = testOptimizationDriverSource().build_file;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source = testOptimizationDriverSource();
    source.build_file = historical.build_file;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source = historical;
    source.build_file = null;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
}

test "active Seq driver identity is distinct from immutable historical evidence" {
    const active = driverIdentity(.seq_replay);
    const bytes = driverSourceBytes(.seq_replay);
    const digest = evidenceDigest(bytes);
    try std.testing.expectEqualStrings(active.sha256, &digest);
    try std.testing.expect(!std.mem.eql(u8, bytes, sealed_seq_replay_driver_source));
    var source = CapsuleDriverSource{
        .revision = active.revision,
        .tree = active.tree,
        .path = active.locator,
        .file = .{
            .label = "perf_hub.zig",
            .sha256 = "sha256:" ++ seq_replay_driver_sha256,
        },
    };
    try validateDriverSourceMetadata(source);
    var mixed: [4]CapsuleDriverSource = @splat(source);
    mixed[0].revision = legacy_seq_replay_driver_v1.revision;
    mixed[1].tree = legacy_seq_replay_driver_v1.tree;
    mixed[2].path = legacy_seq_replay_driver_v1.locator;
    mixed[3].file.sha256 = "sha256:" ++ legacy_seq_replay_driver_v1.sha256;
    for (mixed) |candidate| {
        try std.testing.expectError(
            error.PerfEvidenceIdentityMismatch,
            validateDriverSourceMetadata(candidate),
        );
    }
    source.build_file = testOptimizationDriverSource().build_file;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
}

const isolated_build_fixture =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    _ = b.standardTargetOptions(.{});
    \\    _ = b.standardOptimizeOption(.{});
    \\    const env = b.graph.environ_map;
    \\    const contents = b.fmt("{s}\n{s}\n", .{
    \\        env.get("ZIG_GLOBAL_CACHE_DIR") orelse "missing-global-cache",
    \\        env.get("ZIG_LOCAL_PKG_DIR") orelse "missing-package-cache",
    \\    });
    \\    const file = b.addWriteFiles().add("cache-environment", contents);
    \\    b.getInstallStep().dependOn(&b.addInstallFile(file, "cache-environment").step);
    \\    b.step("optimization-driver", "Check driver invocation").dependOn(b.getInstallStep());
    \\}
;

test "isolated product and driver builds use supported private compiler caches" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = isolated_build_fixture });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const prefix = try std.fs.path.join(allocator, &.{ root, "zig-out" });
    defer allocator.free(prefix);
    var environment = try std.testing.environ.createMap(allocator);
    defer environment.deinit();
    const configured = try std.testing.environ.getAlloc(allocator, "PERF_TEST_ZIG");
    defer allocator.free(configured);
    const observed_path = try std.fs.path.join(allocator, &.{ prefix, "cache-environment" });
    defer allocator.free(observed_path);
    inline for (.{ "", "driver-" }) |cache_prefix| {
        const kind: DriverKind = if (cache_prefix.len == 0) .seq_replay else .optimization;
        try runIsolatedBuild(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            &environment,
            allocator,
            root,
            root,
            prefix,
            configured,
            cache_prefix,
            kind,
        );
        const observed = try std.Io.Dir.cwd().readFileAlloc(
            io,
            observed_path,
            allocator,
            .limited(8192),
        );
        defer allocator.free(observed);
        const expected = try allocator.print("{s}/{s}global-cache\n{s}/{s}packages\n", .{
            root, cache_prefix, root, cache_prefix,
        });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, observed);
    }
}

test "optimization driver build requires the exact step target and cpu" {
    const valid = CapsuleBuild{
        .optimize = "ReleaseFast",
        .step = "optimization-driver",
        .target = "aarch64-macos",
        .cpu = "baseline",
        .repo_local_prefix = true,
        .isolated_caches = true,
        .product_output_isolated = true,
    };
    try validateOptimizationDriverBuild(valid);
    var changed = [_]CapsuleBuild{ valid, valid, valid, valid, valid };
    changed[0].step = "install";
    changed[1].target = null;
    changed[2].target = "x86_64-linux";
    changed[3].cpu = null;
    changed[4].cpu = "native";
    for (changed) |build| {
        try std.testing.expectError(
            error.InvalidPerfEvidenceFile,
            validateOptimizationDriverBuild(build),
        );
    }
}

test "optimization driver source requires the exact build source identity" {
    var source = testOptimizationDriverSource();
    try validateDriverSourceMetadata(source);
    source.build_file = null;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    for ([_][]const u8{
        "",
        "sha256:" ++ &@as([64]u8, @splat('0')),
        "sha257:" ++ optimization_build_sha256,
        "sha256:" ++ optimization_build_sha256 ++ "0",
    }) |wrong_digest| {
        source.build_file = .{ .label = "optimization_build.zig", .sha256 = wrong_digest };
        try std.testing.expectError(
            error.PerfEvidenceIdentityMismatch,
            validateDriverSourceMetadata(source),
        );
    }
}

test "optimization driver source rejects mixed source tuples" {
    const valid = testOptimizationDriverSource();
    var sources = [_]CapsuleDriverSource{ valid, valid, valid, valid };
    sources[0].revision = legacy_seq_replay_driver_v1.revision;
    sources[1].tree = legacy_seq_replay_driver_v1.tree;
    sources[2].path = legacy_seq_replay_driver_v1.locator;
    sources[3].file.sha256 = "sha256:" ++ legacy_seq_replay_driver_v1.sha256;
    for (sources) |source| {
        try std.testing.expectError(
            error.PerfEvidenceIdentityMismatch,
            validateDriverSourceMetadata(source),
        );
    }
}

test "Seq replay and legacy sources reject optimization build evidence" {
    var source = CapsuleDriverSource{
        .revision = legacy_seq_replay_driver_v1.revision,
        .tree = legacy_seq_replay_driver_v1.tree,
        .path = legacy_seq_replay_driver_v1.locator,
        .file = .{
            .label = "perf_hub.zig",
            .sha256 = "sha256:" ++ legacy_seq_replay_driver_v1.sha256,
        },
        .build_file = testOptimizationDriverSource().build_file,
    };
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source.revision = legacy_generic_driver_v1.revision;
    source.tree = legacy_generic_driver_v1.tree;
    source.path = legacy_generic_driver_v1.locator;
    source.file.sha256 = "sha256:" ++ legacy_generic_driver_v1.sha256;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
}

test "sealed Seq replay driver source is capture-only and dependency-minimal" {
    const digest = sealedSeqReplayDriverDigest();
    try std.testing.expectEqualStrings(
        legacy_seq_replay_driver_v1.sha256,
        &digest,
    );
    try std.testing.expectEqualStrings(
        legacy_seq_replay_driver_v1.revision,
        legacy_seq_replay_driver_v1.sha256,
    );
    const tree_digest = sealedSeqReplayDriverTreeDigest();
    try std.testing.expectEqualStrings(
        legacy_seq_replay_driver_v1.tree,
        &tree_digest,
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        std.mem.count(u8, sealed_seq_replay_driver_source, "@import("),
    );
    for ([_][]const u8{
        "@import(\"std\")",
        "@import(\"builtin\")",
        "@import(\"core_perf\")",
        "@import(\"definition_core\")",
        "@import(\"seq_v1_core\")",
        "const warmup_count: usize = 3;",
        "const sample_count: usize = 30;",
        "const batch_iterations: usize = 8;",
        "\\\"schema_version\\\":1",
        "\"PASS\\t{s}\\tcaptured\\n\"",
        "&.{ \".perf-local\", machine_name, \"baselines\", binary }",
    }) |required| {
        try std.testing.expect(
            std.mem.indexOf(u8, sealed_seq_replay_driver_source, required) !=
                null,
        );
    }
    for ([_][]const u8{
        "@import(\"core_cli\")",
        "@import(\"durable_store\")",
        "@import(\"perf_contract\")",
        "@import(\"cas_automation_cli\")",
        "@import(\"cron_" ++ "cli\")",
        "cas_automation",
        "cron-",
    }) |forbidden| {
        try std.testing.expect(
            std.mem.indexOf(u8, sealed_seq_replay_driver_source, forbidden) ==
                null,
        );
    }
}

test "compiler digest check rejects mutation between builds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "zig",
        .data = "approved",
    });
    const compiler_path = try tmp.dir.realPathFileAlloc(
        io,
        "zig",
        allocator,
    );
    defer allocator.free(compiler_path);
    const approved_digest = evidenceDigest("approved");
    try requireCompilerDigestAtPath(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
        compiler_path,
        &approved_digest,
    );
    try tmp.dir.writeFile(io, .{
        .sub_path = "zig",
        .data = "replaced",
    });
    try std.testing.expectError(
        error.CompilerBinaryChanged,
        requireCompilerDigestAtPath(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            compiler_path,
            &approved_digest,
        ),
    );
}

test "report errors clearly when compare summary is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd_before = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(io, tmp.dir);
    defer restoreTestCwd(io, cwd_before);

    const current_name = try currentMachineDirName(alloc);
    defer alloc.free(current_name);
    const reports_path = try alloc.print(".perf-local/{s}/reports", .{current_name});
    defer alloc.free(reports_path);
    try tmp.dir.createDirPath(std.testing.io, reports_path);

    try std.testing.expectError(
        error.MissingCompareSummary,
        cmdReport(durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()), null, alloc),
    );
}

test "unmatched comparison target preserves prior evidence artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(
        std.testing.io,
        allocator,
    );
    defer allocator.free(cwd_before);
    try std.process.setCurrentDir(
        std.testing.io,
        tmp.dir,
    );
    defer restoreTestCwd(std.testing.io, cwd_before);

    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const reports_path = try std.fs.path.join(
        allocator,
        &.{ ".perf-local", machine_name, "reports" },
    );
    defer allocator.free(reports_path);
    try tmp.dir.createDirPath(
        std.testing.io,
        reports_path,
    );
    const sentinel = "{\"sentinel\":true}\n";
    const locator_path = try std.fs.path.join(
        allocator,
        &.{
            ".perf-local",
            machine_name,
            "reports",
            "current-capsule.json",
        },
    );
    defer allocator.free(locator_path);
    try tmp.dir.writeFile(
        std.testing.io,
        .{ .sub_path = locator_path, .data = sentinel },
    );
    try std.testing.expectError(
        error.NoMatchingPerfCases,
        cmdCompare(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            null,
            allocator,
            "definitely-no-such-case",
        ),
    );
    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        locator_path,
        allocator,
        .limited(sentinel.len + 1),
    );
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(sentinel, bytes);
}

test "matching comparison invalidation retires stale locator authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(
        std.testing.io,
        allocator,
    );
    defer allocator.free(cwd_before);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreTestCwd(std.testing.io, cwd_before);
    const machine_dir = try ensureCurrentMachineDir(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
        allocator,
    );
    defer allocator.free(machine_dir);
    try invalidateCurrentCapsule(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
        allocator,
        machine_dir,
    );
    const locator_path = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "reports", "current-capsule.json" },
    );
    defer allocator.free(locator_path);
    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        locator_path,
        allocator,
        .limited(256),
    );
    defer allocator.free(bytes);
    try std.testing.expect(
        std.mem.indexOf(u8, bytes, "\"capsule\":null") != null,
    );
}

test "report rejects malformed rows in a verified capsule" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(
        std.testing.io,
        alloc,
    );
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(
        std.testing.io,
        tmp.dir,
    );
    defer restoreTestCwd(std.testing.io, cwd_before);

    const current_name = try currentMachineDirName(alloc);
    defer alloc.free(current_name);
    const reports_path = try alloc.print(
        ".perf-local/{s}/reports",
        .{current_name},
    );
    defer alloc.free(reports_path);
    try tmp.dir.createDirPath(
        std.testing.io,
        reports_path,
    );
    const machine_dir = std.fs.path.dirname(reports_path).?;
    var capsule = try sealEvidenceBytes(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
        alloc,
        machine_dir,
        "capsule.json",
        "{\"schema\":\"performance-capsule/v1\"," ++
            "\"target\":\"seq-definition-check\"," ++
            "\"expected_base_sha\":null," ++
            "\"expected_candidate_sha\":null,\"expected_rows\":1," ++
            "\"complete\":true,\"rows\":[{" ++
            "\"case_id\":\"seq-definition-check\"," ++
            "\"binary\":7,\"status\":\"PASS\",\"tuple_bound\":false," ++
            "\"detail\":\"bad\",\"evidence\":null}]}\n",
        0o600,
    );
    defer capsule.deinit(alloc);
    var locator: std.Io.Writer.Allocating = .init(alloc);
    defer locator.deinit();
    try locator.writer.writeAll(
        "{\"schema\":\"performance-capsule-ref/v1\",\"capsule\":",
    );
    try writeSealedFile(&locator.writer, capsule);
    try locator.writer.writeAll("}\n");
    const locator_path = try std.fs.path.join(
        alloc,
        &.{ reports_path, "current-capsule.json" },
    );
    defer alloc.free(locator_path);
    try writeEvidenceFileAtomic(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
        alloc,
        locator_path,
        locator.written(),
        0o600,
    );

    try std.testing.expectError(
        error.InvalidCompareSummary,
        cmdReport(durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()), null, alloc),
    );
}

test "capsule completeness and pass status are recomputed" {
    var row: CapsuleRow = undefined;
    row.case_id = "seq-definition-check";
    row.binary = "seq";
    row.status = "PASS";
    row.detail = "synthetic";
    row.tuple_bound = true;
    var capsule = PerformanceCapsule{
        .schema = "performance-capsule/v1",
        .target = "seq-definition-check",
        .expected_base_sha = "0000000000000000000000000000000000000000",
        .expected_candidate_sha = "1111111111111111111111111111111111111111",
        .expected_rows = 1,
        .complete = false,
        .rows = (&[_]CapsuleRow{row})[0..],
    };
    try std.testing.expectError(
        error.IncompleteComparison,
        validatePerformanceCapsule(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            null,
            std.testing.allocator,
            capsule,
            true,
        ),
    );
    capsule.complete = true;
    capsule.expected_rows = 2;
    try std.testing.expectError(
        error.IncompleteComparison,
        validatePerformanceCapsule(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            null,
            std.testing.allocator,
            capsule,
            true,
        ),
    );
    capsule.expected_rows = 1;
    row.status = "FAIL";
    capsule.rows = (&[_]CapsuleRow{row})[0..];
    try std.testing.expectError(
        error.PerformanceRegression,
        validatePerformanceCapsule(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            null,
            std.testing.allocator,
            capsule,
            true,
        ),
    );
}

test "manifest serialization emits parseable output" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try perf_contract.writeManifestJson(
        std.testing.allocator,
        &output.writer,
        allManifests(),
    );
    try std.testing.expect(output.written().len > 0);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("binaries") != null);
}

test "evidence writer rejects symlink targets without changing referent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(
        std.testing.io,
        allocator,
    );
    defer allocator.free(cwd_before);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreTestCwd(std.testing.io, cwd_before);

    try tmp.dir.createDirPath(std.testing.io, "reports");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sentinel",
        .data = "unchanged",
    });
    const sentinel = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "sentinel",
        allocator,
    );
    defer allocator.free(sentinel);
    try tmp.dir.symLink(
        std.testing.io,
        sentinel,
        "reports/current-capsule.json",
        .{},
    );
    try std.testing.expectError(
        error.PerfEvidenceSymlink,
        writeEvidenceFileAtomic(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            allocator,
            "reports/current-capsule.json",
            "{}\n",
            0o600,
        ),
    );
    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        "sentinel",
        allocator,
        .limited(64),
    );
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("unchanged", bytes);
}

test "balanced round ratios reject repeatable regressions not one noisy round" {
    const alloc = std.testing.allocator;
    const case_cfg = DeepCases[0];
    var baseline = try makeTestRoundMetrics(case_cfg, 100);
    defer baseline.deinit(alloc);
    var candidate = try makeTestRoundMetrics(case_cfg, 110);
    defer candidate.deinit(alloc);
    const null_control = try compareBalancedDeepMetrics(
        case_cfg,
        baseline,
        candidate,
    );
    try std.testing.expectEqualStrings("PASS", null_control.status);
    for (candidate.samples.items) |*sample| sample.* = 104;
    const regression = try compareBalancedDeepMetrics(
        case_cfg,
        baseline,
        candidate,
    );
    try std.testing.expectEqualStrings("FAIL", regression.status);
    for (candidate.samples.items) |*sample| sample.* = 100;
    candidate.alloc_samples.items[0] = 110;
    const one_noisy_allocation_round = try compareBalancedDeepMetrics(
        case_cfg,
        baseline,
        candidate,
    );
    try std.testing.expectEqualStrings(
        "PASS",
        one_noisy_allocation_round.status,
    );
    for (1..paired_comparison_rounds / 2) |round| {
        candidate.alloc_samples.items[round] = 110;
    }
    const repeated_allocation_regression = try compareBalancedDeepMetrics(
        case_cfg,
        baseline,
        candidate,
    );
    try std.testing.expectEqualStrings(
        "FAIL",
        repeated_allocation_regression.status,
    );
    for (candidate.alloc_samples.items) |*sample| sample.* = 100;
    candidate.rss_samples.items[0] = 110;
    const one_noisy_rss_round = try compareBalancedDeepMetrics(
        case_cfg,
        baseline,
        candidate,
    );
    try std.testing.expectEqualStrings("PASS", one_noisy_rss_round.status);
    for (1..paired_comparison_rounds / 2) |round| {
        candidate.rss_samples.items[round] = 110;
    }
    const repeated_rss_regression = try compareBalancedDeepMetrics(
        case_cfg,
        baseline,
        candidate,
    );
    try std.testing.expectEqualStrings("FAIL", repeated_rss_regression.status);
}

fn makeTestRoundMetrics(case_cfg: DeepCase, first_round_ns: u64) !Metrics {
    const allocator = std.testing.allocator;
    var samples: std.ArrayList(u64) = .empty;
    errdefer samples.deinit(allocator);
    var allocations: std.ArrayList(u64) = .empty;
    errdefer allocations.deinit(allocator);
    var rss: std.ArrayList(u64) = .empty;
    errdefer rss.deinit(allocator);
    const sample_count = case_cfg.samples * paired_comparison_rounds;
    for (0..sample_count) |index| {
        try samples.append(
            allocator,
            if (index < case_cfg.samples) first_round_ns else 100,
        );
    }
    for (0..paired_comparison_rounds) |_| {
        try allocations.append(allocator, 100);
        try rss.append(allocator, 100);
    }
    return metricsFromSamples(allocator, samples, allocations, rss);
}

test "rss tolerance rounds only to the observable page quantum" {
    const allowed = try observableRssUpperBound(2_637_824, 2.0);
    try std.testing.expect(allowed >= 2_690_581);
    const page_size: u64 = @intCast(C.sysconf(
        @backingInt(std.c._SC.PAGESIZE),
    ));
    try std.testing.expect(allowed - 2_690_581 < page_size);
}

test "shared deep artifact identity is exact" {
    const case_cfg = DeepCases[0];
    const raw = try std.testing.allocator.print(
        "{{\"schema_version\":1,\"case_id\":\"{s}\",\"binary\":\"{s}\"," ++
            "\"git_sha\":\"unknown\"}}",
        .{
            case_cfg.descriptor.case_id,
            case_cfg.descriptor.binary,
        },
    );
    defer std.testing.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        raw,
        .{},
    );
    defer parsed.deinit();
    const product_source_sha =
        "abcdef0123456789abcdef0123456789abcdef01";
    try validateSharedDriverArtifact(
        parsed.value,
        case_cfg,
        product_source_sha,
    );
    parsed.value.object.getPtr("git_sha").?.* = .{
        .string = product_source_sha[0..12],
    };
    try validateSharedDriverArtifact(
        parsed.value,
        case_cfg,
        product_source_sha,
    );
    parsed.value.object.getPtr("git_sha").?.* = .{ .string = "other" };
    try expectSharedArtifactMismatch(parsed.value, case_cfg, product_source_sha);
    parsed.value.object.getPtr("git_sha").?.* = .{ .string = "unknown" };
    parsed.value.object.getPtr("case_id").?.* = .{ .string = "other" };
    try expectSharedArtifactMismatch(parsed.value, case_cfg, product_source_sha);
    parsed.value.object.getPtr("case_id").?.* = .{
        .string = case_cfg.descriptor.case_id,
    };
    parsed.value.object.getPtr("binary").?.* = .{ .string = "other" };
    try expectSharedArtifactMismatch(parsed.value, case_cfg, product_source_sha);
    parsed.value.object.getPtr("binary").?.* = .{
        .string = case_cfg.descriptor.binary,
    };
    parsed.value.object.getPtr("schema_version").?.* = .{ .integer = 2 };
    try expectSharedArtifactMismatch(parsed.value, case_cfg, product_source_sha);
}

fn expectSharedArtifactMismatch(
    value: std.json.Value,
    case_cfg: DeepCase,
    product_source_sha: []const u8,
) !void {
    try std.testing.expectError(
        error.DeepArtifactIdentityMismatch,
        validateSharedDriverArtifact(value, case_cfg, product_source_sha),
    );
}

test "deep capture acknowledgment is exact and single-line" {
    try validateCaptureAcknowledgment(
        std.testing.allocator,
        "PASS\tseq-observe-deep\tcaptured\n",
        "seq-observe-deep",
    );
    for ([_][]const u8{
        "",
        "PASS\tother\tcaptured\n",
        "PASS\tseq-observe-deep\tcaptured\nPASS\tother\tcaptured\n",
    }) |raw| {
        try std.testing.expectError(
            error.InvalidPerfCaptureAcknowledgment,
            validateCaptureAcknowledgment(
                std.testing.allocator,
                raw,
                "seq-observe-deep",
            ),
        );
    }
}

test "deep semantic evidence verifies local identity before relocation normalization" {
    const allocator = std.testing.allocator;
    const roots = [_][]const u8{ "/tmp/perf-root-a", "/tmp/perf-root-b" };
    var evidence: [2]MeasuredOutputEvidence = undefined;
    for (roots, 0..) |root, index| {
        const fixture_path = try std.fs.path.join(
            allocator,
            &.{ root, "apps/seq/src/v1/fixtures/rollout.jsonl" },
        );
        defer allocator.free(fixture_path);
        const identity = expectedSourceEventId(fixture_path, 3, 2);
        const rendered = try allocator.print(
            "{{\"data\":{{\"schema\":\"example-message-rows/v1\"," ++
                "\"rows\":[{{\"session_id\":\"fixture-session\"," ++
                "\"role\":\"assistant\",\"text\":\"Observed FAILURE evidence\"," ++
                "\"source_event_id\":\"{s}\"}}]}}}}",
            .{identity},
        );
        defer allocator.free(rendered);
        evidence[index] = try canonicalDeepDataEvidence(
            allocator,
            rendered,
            root,
        );
    }
    try std.testing.expectEqualSlices(
        u8,
        &evidence[0].output_sha256,
        &evidence[1].output_sha256,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &(evidence[0].local_output_sha256.?),
        &(evidence[1].local_output_sha256.?),
    ));
    const wrong_fixture = try std.fs.path.join(
        allocator,
        &.{ roots[0], "apps/seq/src/v1/fixtures/rollout.jsonl" },
    );
    defer allocator.free(wrong_fixture);
    const wrong_identity = expectedSourceEventId(wrong_fixture, 3, 2);
    const wrong_rendered = try allocator.print(
        "{{\"data\":{{\"rows\":[{{\"source_event_id\":\"{s}\"}}]}}}}",
        .{wrong_identity},
    );
    defer allocator.free(wrong_rendered);
    try std.testing.expectError(
        error.PerfSourceEventIdentityMismatch,
        canonicalDeepDataEvidence(allocator, wrong_rendered, roots[1]),
    );
}

test "semantic evidence hashes canonical observation data" {
    const first = try canonicalDataDigest(
        std.testing.allocator,
        "{\"data\":{\"rows\":[{\"value\":1}],\"schema\":\"x/v1\"}}",
    );
    const reordered = try canonicalDataDigest(
        std.testing.allocator,
        "{\"data\":{\"schema\":\"x/v1\",\"rows\":[{\"value\":1}]}}",
    );
    const changed = try canonicalDataDigest(
        std.testing.allocator,
        "{\"data\":{\"schema\":\"x/v1\",\"rows\":[{\"value\":2}]}}",
    );
    try std.testing.expectEqualSlices(u8, &first, &reordered);
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "semantic output normalization preserves data and removes locality" {
    const first = try semanticOutputDigest(
        std.testing.allocator,
        "{\"stats\":{\"compile_ns\":10,\"physical_passes\":1}," ++
            "\"data\":{\"path\":\"/tmp/a/input\"," ++
            "\"source_event_id\":\"sha256:" ++
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}",
        "/tmp/a",
    );
    const second = try semanticOutputDigest(
        std.testing.allocator,
        "{\"data\":{\"source_event_id\":\"sha256:" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
            "\"path\":\"/tmp/b/input\"}," ++
            "\"stats\":{\"physical_passes\":0,\"compile_ns\":999," ++
            "\"streamed\":true}}",
        "/tmp/b",
    );
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expectError(
        error.InvalidPerfSourceEventIdentity,
        semanticOutputDigest(
            std.testing.allocator,
            "{\"source_event_id\":\"invalid\"}",
            "/tmp/a",
        ),
    );
}

test "sealed evidence rejects content substitution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "perf_hub",
        .data = "first",
    });
    const real_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "perf_hub",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(real_path);
    var file: SealedFile = .{
        .path = try std.testing.allocator.dupeSentinel(u8, real_path, 0),
        .sha256 = try sha256File(
            durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
            real_path,
        ),
    };
    defer file.deinit(std.testing.allocator);
    try verifySealedFile(durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()), file);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "perf_hub",
        .data = "second",
    });
    try std.testing.expectError(
        error.PerfEvidenceDigestMismatch,
        verifySealedFile(durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()), file),
    );
}

test "temp-root release deletes storage before freeing its path" {
    const root = try makeTempRoot(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
        std.testing.allocator,
        "release-order",
    );
    const observed_root = try std.testing.allocator.dupe(u8, root);
    defer std.testing.allocator.free(observed_root);
    releaseTempRoot(
        durable_store.Fs.init(std.testing.io, std.Io.Dir.cwd()),
        std.testing.allocator,
        root,
        false,
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, observed_root, .{}),
    );
}

test "compiler evidence retains sentinel path ownership" {
    const allocator = std.testing.allocator;
    const approved_path = try allocator.dupeSentinel(u8, "/tmp/zig", 0);
    errdefer allocator.free(approved_path);
    const file_path = try allocator.dupeSentinel(u8, "/tmp/sealed-zig", 0);
    errdefer allocator.free(file_path);
    const version = try allocator.dupe(u8, "0.16.0");
    var evidence = CompilerEvidence{
        .approved_path = approved_path,
        .file = .{ .path = file_path, .sha256 = undefined },
        .version = version,
    };
    evidence.deinit(allocator);
}

test "retained utility cases preserve executable and setup pairing" {
    const expected = [_]struct {
        id: []const u8,
        binary: []const u8,
        setup: CompatSetup,
    }{
        .{ .id = "bench-stats-help", .binary = "bench_stats", .setup = .bench_stats_help },
        .{ .id = "bench-stats-parse", .binary = "bench_stats", .setup = .bench_stats_parse },
        .{ .id = "cas-wrapper-smoke", .binary = "cas", .setup = .cas_wrapper_smoke },
        .{ .id = "cas-smoke-check-help", .binary = "cas_smoke_check", .setup = .cas_smoke_check_help },
        .{ .id = "cas-instance-runner-help", .binary = "cas_instance_runner", .setup = .cas_instance_runner_help },
        .{ .id = "cas-review-session-help", .binary = "cas_review_session", .setup = .cas_review_session_help },
        .{ .id = "cas-review-session-version", .binary = "cas_review_session", .setup = .cas_review_session_version },
    };
    try std.testing.expectEqual(expected.len, MiscCases.len);
    for (expected) |item| {
        var matches: usize = 0;
        for (CompatCases) |case| {
            if (!std.mem.eql(u8, item.id, case.descriptor.case_id)) continue;
            matches += 1;
            try std.testing.expectEqualStrings(item.binary, case.descriptor.binary);
            try std.testing.expectEqualStrings(item.binary, std.fs.path.basename(case.binary_path));
            try std.testing.expectEqual(item.setup, case.setup);
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
}

test "incompatible paired comparisons fail closed" {
    try std.testing.expect(!comparisonStatusFailed("PASS"));
    try std.testing.expect(comparisonStatusFailed("FAIL"));
    try std.testing.expect(comparisonStatusFailed("INCOMPATIBLE"));
}

test "doctor counts compat and deep cases" {
    var count: usize = 0;
    for (CompatCases) |_| count += 1;
    for (DeepCases) |_| count += 1;
    try std.testing.expectEqual(CompatCases.len + DeepCases.len, count);
}

test "cutover comparison requires the complete Seq and Ledger matrix" {
    try std.testing.expectEqual(
        SeqCases.len + 4,
        matchingCaseCount("seq"),
    );
    try std.testing.expectEqual(
        LedgerCases.len + 5,
        matchingCaseCount("ledger"),
    );
    try std.testing.expectEqual(
        SeqCases.len + LedgerCases.len,
        matchingCaseCount("cutover"),
    );
    try std.testing.expectEqual(@as(usize, 0), matchingCaseCount("no-match"));
    var rows: [SeqCases.len + LedgerCases.len]CompareRow = undefined;
    var index: usize = 0;
    for (SeqCases) |descriptor| {
        rows[index] = .{
            .status = "PASS",
            .case_id = descriptor.case_id,
            .binary = descriptor.binary,
            .detail = "paired",
            .tuple_bound = true,
        };
        index += 1;
    }
    for (LedgerCases) |descriptor| {
        rows[index] = .{
            .status = "PASS",
            .case_id = descriptor.case_id,
            .binary = descriptor.binary,
            .detail = "paired",
            .tuple_bound = true,
        };
        index += 1;
    }
    try std.testing.expect(!comparisonSummaryComplete(
        null,
        "cutover",
        SeqCases.len + LedgerCases.len,
        &rows,
    ));
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PERF_EXPECT_BASE_SHA", "base");
    try environment.put("PERF_EXPECT_CANDIDATE_SHA", "candidate");
    try std.testing.expect(comparisonSummaryComplete(
        &environment,
        "cutover",
        SeqCases.len + LedgerCases.len,
        &rows,
    ));
    rows[0].tuple_bound = false;
    try std.testing.expect(!comparisonSummaryComplete(
        &environment,
        "cutover",
        SeqCases.len + LedgerCases.len,
        &rows,
    ));
}

test "paired baseline path outranks candidate environment override" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PERF_LEDGER_BINARY", "/candidate/ledger");
    var baseline_case = CompatCases[4];
    baseline_case.binary_path = "/base/ledger";
    const resolved = try resolveBinaryPath(
        &environment,
        std.testing.allocator,
        baseline_case,
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("/base/ledger", resolved);
}

test "paired evidence requires the requested source tuple" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectError(
        error.ExpectedSourceShaRequired,
        requireExpectedSourceShas(&environment, "base", "candidate"),
    );
    try environment.put("PERF_EXPECT_BASE_SHA", "base");
    try environment.put("PERF_EXPECT_CANDIDATE_SHA", "candidate");
    try requireExpectedSourceShas(&environment, "base", "candidate");
    try std.testing.expectError(
        error.BaselineSourceShaMismatch,
        requireExpectedSourceShas(&environment, "other", "candidate"),
    );
    try std.testing.expectError(
        error.CandidateSourceShaMismatch,
        requireExpectedSourceShas(&environment, "base", "other"),
    );
}

test "cutover report tuple must match the request and current source" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put(
        "PERF_EXPECT_BASE_SHA",
        "0000000000000000000000000000000000000000",
    );
    try environment.put(
        "PERF_EXPECT_CANDIDATE_SHA",
        "1111111111111111111111111111111111111111",
    );
    const tuple = ReportTuple{
        .base_sha = "0000000000000000000000000000000000000000",
        .candidate_sha = "1111111111111111111111111111111111111111",
    };
    try requireCutoverReportTuple(
        &environment,
        tuple,
        "1111111111111111111111111111111111111111",
    );
    try std.testing.expectError(
        error.CandidateSourceShaMismatch,
        requireCutoverReportTuple(
            &environment,
            tuple,
            "2222222222222222222222222222222222222222",
        ),
    );
}

test "measurement integers reject floats outside the representable range" {
    for ([_]f64{ -1, std.math.inf(f64), std.math.nan(f64), 0x1p64 }) |value| {
        try std.testing.expectError(error.InvalidData, jsonValueU64(.{ .float = value }, "test"));
    }
    try std.testing.expectEqual(@as(u64, 1), try jsonValueU64(.{ .float = 1.75 }, "test"));
    try std.testing.expectEqual(
        @as(u64, 18_446_744_073_709_549_568),
        try jsonValueU64(.{ .float = 18_446_744_073_709_549_568.0 }, "test"),
    );
}

test "semantic normalization traverses deep arrays and preserves error precedence" {
    try expectDeepSemanticNormalization(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidPerfSourceEventIdentity,
        semanticOutputDigest(
            std.testing.allocator,
            "{\"nested\":[{\"source_event_id\":\"invalid\"}],\"stats\":7}",
            "/tmp/unused",
        ),
    );
    try std.testing.expectError(
        error.InvalidPerfSemanticOutput,
        semanticOutputDigest(
            std.testing.allocator,
            "{\"stats\":7,\"nested\":[{\"source_event_id\":\"invalid\"}]}",
            "/tmp/unused",
        ),
    );
}

test "semantic normalization propagates allocation failure without leaking" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        expectDeepSemanticNormalization,
        .{},
    );
}

fn expectDeepSemanticNormalization(allocator: std.mem.Allocator) !void {
    const depth = 512;
    const payload =
        "{\"source_event_id\":\"sha256:" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"stats\":{\"source_event_id\":\"ignored\"}}";
    const raw = try allocator.alloc(u8, depth * 2 + payload.len);
    defer allocator.free(raw);
    @memset(raw[0..depth], '[');
    @memcpy(raw[depth..][0..payload.len], payload);
    @memset(raw[depth + payload.len ..], ']');
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    try normalizeSemanticOutput(allocator, &parsed.value, raw.len);
    var leaf = &parsed.value;
    for (0..depth) |_| {
        try std.testing.expect(leaf.* == .array);
        leaf = &leaf.array.items[0];
    }
    try std.testing.expectEqualStrings(
        normalized_source_event_id,
        leaf.object.get("source_event_id").?.string,
    );
    try std.testing.expect(leaf.object.get("stats").? == .null);
}

test "metric sample ownership transfers only after all percentile allocations succeed" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        expectMetricSampleTransfer,
        .{},
    );
}

fn expectMetricSampleTransfer(allocator: std.mem.Allocator) !void {
    var samples = try MetricSamples.init(allocator, 3, 3, 3);
    defer samples.deinit(allocator);
    const times = [_]u64{ 30, 10, 20 };
    const allocations = [_]u64{ 2, 4, 6 };
    const rss = [_]u64{ 100, 200, 300 };
    try samples.times.appendSlice(allocator, &times);
    try samples.allocations.appendSlice(allocator, &allocations);
    try samples.rss.appendSlice(allocator, &rss);
    var metrics = samples.finish(allocator) catch |err| {
        try std.testing.expectEqualSlices(u64, &times, samples.times.items);
        try std.testing.expectEqualSlices(u64, &allocations, samples.allocations.items);
        try std.testing.expectEqualSlices(u64, &rss, samples.rss.items);
        return err;
    };
    defer metrics.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), samples.times.items.len);
    try std.testing.expectEqual(@as(usize, 0), samples.allocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), samples.rss.items.len);
    try std.testing.expectEqualSlices(u64, &times, metrics.samples.items);
    try std.testing.expectEqualSlices(u64, &allocations, metrics.alloc_samples.items);
    try std.testing.expectEqualSlices(u64, &rss, metrics.rss_samples.items);
}

test "optimization readback uses each case's product and sample configuration" {
    const ledger = evidenceCaseConfig("ledger-topk-16384-k100").?;
    const trace = evidenceCaseConfig("trace-full-1024").?;
    try std.testing.expectEqualStrings("build-ledger", ledger.build_step.?);
    try std.testing.expectEqualStrings("zig-out/bin/ledger", ledger.binary_path);
    try std.testing.expectEqual(CompatSetup.ledger_project, ledger.setup);
    try std.testing.expectEqualStrings("build-seq", trace.build_step.?);
    try std.testing.expectEqualStrings("zig-out/bin/seq", trace.binary_path);
    try std.testing.expectEqual(CompatSetup.seq_observe, trace.setup);
    try std.testing.expectEqual(@as(usize, 30), ledger.samples);
    try std.testing.expectEqual(@as(usize, 30), trace.samples);
    try std.testing.expectEqual(@as(usize, 3), ledger.warmups);
    try std.testing.expectEqual(@as(usize, 3), trace.warmups);
}

test "optimization target includes the complete workload and regression matrix" {
    const ids = [_][]const u8{
        "ledger-topk-16384-k100",
        "ledger-topk-16384-k1",
        "ledger-topk-16384-k10",
        "ledger-topk-16384-k1000",
        "ledger-topk-32-k10",
        "trace-full-1024",
        "trace-full-8",
        "trace-summary-1024",
        "trace-summary-8",
    };
    try std.testing.expectEqual(ids.len, matchingCaseCount("optimization"));
    for (ids) |id| {
        const case = deepCaseForId(id).?;
        try std.testing.expect(matchesTarget(id, case.descriptor.binary, "optimization"));
        try std.testing.expect(!matchesTarget(id, case.descriptor.binary, "cutover"));
    }
}

test "optimization primary and secondary budgets reject each over-budget metric" {
    const limit = BalancedRatios{
        .p50 = 800_000,
        .p95 = 1_030_000,
        .allocations = 1_000_000,
        .rss = 1_020_000,
    };
    for ([_][]const u8{ "ledger-topk-16384-k100", "trace-full-1024" }) |id| {
        const primary = deepCaseForId(id).?;
        try expectBalancedStatus(primary, limit, "PASS");
        inline for (@typeInfo(BalancedRatios).@"struct".field_names) |field_name| {
            var exceeded = limit;
            @field(exceeded, field_name) += 1;
            try expectBalancedStatus(primary, exceeded, "FAIL");
        }
    }
    for (OptimizationCases) |descriptor| {
        const case = deepCaseForId(descriptor.case_id).?;
        const primary = std.mem.eql(u8, descriptor.case_id, "ledger-topk-16384-k100") or
            std.mem.eql(u8, descriptor.case_id, "trace-full-1024");
        try std.testing.expectEqual(primary, case.primary_optimization);
        if (primary) continue;
        var regression = limit;
        regression.p50 = 1_030_000;
        try expectBalancedStatus(case, regression, "PASS");
        regression.p50 += 1;
        try expectBalancedStatus(case, regression, "FAIL");
    }
}

fn expectBalancedStatus(case: DeepCase, ratios: BalancedRatios, expected: []const u8) !void {
    const result = try compareBalancedRatios(case, ratios);
    defer if (std.mem.eql(u8, result.status, "FAIL")) std.heap.page_allocator.free(result.detail);
    try std.testing.expectEqualStrings(expected, result.status);
}

test "optimization readback recomputes workload and output identities" {
    const workload = "sha256:" ++ &@as([64]u8, @splat('a'));
    const output = "sha256:" ++ &@as([64]u8, @splat('b'));
    const changed = "sha256:" ++ &@as([64]u8, @splat('c'));
    const output_digest = try digestBytes(output);
    const oracle = OptimizationOracle{
        .workload_digest = try digestBytes(workload),
        .execution = .{
            .output_sha256 = output_digest,
            .semantic_output_sha256 = output_digest,
        },
    };
    var execution = CapsuleExecution{
        .output_sha256 = output,
        .semantic_output_sha256 = output,
        .local_output_sha256 = null,
        .streamed = null,
        .records_scanned = null,
        .records_emitted = null,
        .physical_passes = null,
        .files_opened = null,
        .bytes_read = null,
        .rows_materialized = null,
        .compile_ns = null,
        .execution_ns = null,
    };
    try validateOptimizationObservation(oracle, workload, execution);
    try std.testing.expectError(
        error.PerfWorkloadMismatch,
        validateOptimizationObservation(oracle, changed, execution),
    );
    execution.output_sha256 = changed;
    try std.testing.expectError(
        error.PerfSemanticOutputMismatch,
        validateOptimizationObservation(oracle, workload, execution),
    );
    execution.output_sha256 = output;
    execution.semantic_output_sha256 = changed;
    try std.testing.expectError(
        error.PerfSemanticOutputMismatch,
        validateOptimizationObservation(oracle, workload, execution),
    );
}

test "sort-once summaries retain pre-change driver identities for capsule readback" {
    const seq_source = CapsuleDriverSource{
        .revision = legacy_seq_replay_driver_v2.revision,
        .tree = legacy_seq_replay_driver_v2.tree,
        .path = legacy_seq_replay_driver_v2.locator,
        .file = .{
            .label = "seq_replay_driver.zig",
            .sha256 = "sha256:" ++ legacy_seq_replay_driver_v2.sha256,
        },
    };
    const optimization_source = CapsuleDriverSource{
        .revision = legacy_optimization_summary_driver_v1.revision,
        .tree = legacy_optimization_summary_driver_v1.tree,
        .path = legacy_optimization_summary_driver_v1.locator,
        .file = .{
            .label = "optimization_driver.zig",
            .sha256 = "sha256:" ++ legacy_optimization_summary_driver_v1.sha256,
        },
        .build_file = .{
            .label = "optimization_build.zig",
            .sha256 = "sha256:" ++ legacy_optimization_summary_build_sha256,
        },
    };
    try validateDriverSourceMetadata(seq_source);
    try validateDriverSourceMetadata(optimization_source);
    try std.testing.expect(!isOptimizationDriverSource(seq_source));
    try std.testing.expect(isOptimizationDriverSource(optimization_source));
    try std.testing.expect(
        !std.mem.eql(u8, seq_source.revision, active_seq_replay_driver_v2.revision),
    );
    try std.testing.expect(
        !std.mem.eql(u8, optimization_source.revision, active_optimization_driver_v1.revision),
    );
    try std.testing.expectEqualStrings(
        legacy_optimization_summary_build_sha256,
        &optimization_build_sha256,
    );
    var mixed_seq = seq_source;
    mixed_seq.tree = active_seq_replay_driver_v2.tree;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(mixed_seq),
    );
    var mixed_optimization = optimization_source;
    mixed_optimization.tree = active_optimization_driver_v1.tree;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(mixed_optimization),
    );
    mixed_optimization = optimization_source;
    mixed_optimization.build_file = null;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(mixed_optimization),
    );
}

test "capsule readback preserves legacy percentile summaries and chronological samples" {
    var times: [240]u64 = undefined;
    for (&times, 0..) |*sample, index| sample.* = @intCast((index * 37) % times.len);
    const captured_times = times;
    const allocations = [_]u64{ 3, 2, 5, 8, 4, 1, 7, 6 };
    const rss = [_]u64{ 300, 200, 500, 800, 400, 100, 700, 600 };
    var metrics = CapsuleMetrics{
        .samples_ns = &times,
        .p50_ns = 119,
        .p95_ns = 227,
        .rss_samples_bytes = &rss,
        .p95_rss_bytes = 700,
        .allocation_samples = &allocations,
        .p50_alloc_calls = 4,
    };
    const config = evidenceCaseConfig("seq-observe-deep-batch8").?;
    var counting = core_perf.CountingAllocator.init(std.testing.allocator);
    try validateRetainedMetrics(counting.allocator(), metrics, config, true);
    try std.testing.expectEqual(@as(u64, 3), counting.stats.alloc_calls);
    try std.testing.expectEqual(@as(u64, 3), counting.stats.free_calls);
    try std.testing.expectEqualSlices(u64, &captured_times, &times);
    metrics.p95_ns = 228;
    try std.testing.expectError(
        error.InvalidPerfDerivedMetric,
        validateRetainedMetrics(std.testing.allocator, metrics, config, true),
    );
}

test "child capture keeps supplied filesystem and environment authority" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    try first.dir.writeFile(io, .{ .sub_path = "marker", .data = "first\n" });
    try second.dir.writeFile(io, .{ .sub_path = "marker", .data = "second\n" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    for ([_]std.Io.Dir{ first.dir, second.dir }, [_][]const u8{ "first", "second" }) |dir, label| {
        try environment.put("PERF_TEST_AUTHORITY", label);
        const result = try runChildCaptureOutput(
            durable_store.Fs.init(io, dir),
            &environment,
            allocator,
            ".",
            &.{
                "/bin/sh",
                "-c",
                "IFS= read -r marker < marker; printf '%s|%s' \"$PERF_TEST_AUTHORITY\" \"$marker\"",
            },
        );
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const expected = try allocator.print("{s}|{s}", .{ label, label });
        defer allocator.free(expected);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expectEqualStrings(expected, result.stdout);
    }
}

test "evidence operations use supplied I/O and retain independently admitted roots" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    const first_fs = durable_store.Fs.init(io, first.dir);
    const second_fs = durable_store.Fs.init(io, second.dir);
    try writeEvidenceFileAtomic(first_fs, allocator, "evidence", "first", 0o600);
    try writeEvidenceFileAtomic(second_fs, allocator, "evidence", "second", 0o600);
    const first_bytes = try readRegularFileAlloc(first_fs, allocator, "evidence", 64);
    defer allocator.free(first_bytes);
    const second_bytes = try readRegularFileAlloc(second_fs, allocator, "evidence", 64);
    defer allocator.free(second_bytes);
    try std.testing.expectEqualStrings("first", first_bytes);
    try std.testing.expectEqualStrings("second", second_bytes);

    const Canceled = struct {
        fn openFile(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.OpenFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            return error.Canceled;
        }
    };
    var vtable = io.vtable.*;
    vtable.dirOpenFile = Canceled.openFile;
    const canceled_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(
        error.Canceled,
        readRegularFileAlloc(
            durable_store.Fs.init(canceled_io, first.dir),
            allocator,
            "evidence",
            64,
        ),
    );
}

test "explicit I/O driver migration retains preceding summary source tuples" {
    inline for (.{
        legacy_summary_seq_replay_driver_v2,
        legacy_summary_optimization_driver_v1,
    }) |identity| {
        const optimization = std.mem.eql(u8, identity.locator, "tools/optimization_driver.zig");
        const source = CapsuleDriverSource{
            .revision = identity.revision,
            .tree = identity.tree,
            .path = identity.locator,
            .file = .{ .label = "driver.zig", .sha256 = "sha256:" ++ identity.sha256 },
            .build_file = if (optimization) .{
                .label = "build.zig",
                .sha256 = "sha256:" ++ legacy_optimization_summary_build_sha256,
            } else null,
        };
        try validateDriverSourceMetadata(source);
        try std.testing.expectEqual(optimization, isOptimizationDriverSource(source));
    }
}

test "child capture releases directory and environment resources on allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PERF_TEST_AUTHORITY", "supplied");
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        expectChildCaptureAuthority,
        .{ tmp.dir, &environment },
    );
}

fn expectChildCaptureAuthority(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    environment: *const std.process.Environ.Map,
) !void {
    const result = try runChildCaptureOutput(
        durable_store.Fs.init(std.testing.io, dir),
        environment,
        allocator,
        ".",
        &.{ "/bin/sh", "-c", "printf '%s' \"$PERF_TEST_AUTHORITY\"" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("supplied", result.stdout);
}
