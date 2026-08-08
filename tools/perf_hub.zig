const std = @import("std");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
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
const driver_overlay_path = "tools/perf_hub.zig";
const legacy_generic_driver_v1 = DriverSourceIdentity{
    .revision = "ddf201901391ea625e4ac9b0c9649570bc56e58f",
    .tree = "59fcca22a691bbc98a4e38e50c6d642116611b43",
    .locator = driver_overlay_path,
    .sha256 = "0be169c43deebf30f95954b63d334d4e66bde47e0f4a503e4f6b1ac8e5b15a5f",
};
const active_seq_replay_driver_v1 = DriverSourceIdentity{
    .revision = "f2ba9a2fbb3759229984f0431d2889e616f1174c",
    .tree = "165f85af6ff4f64d714fafc1b0497b7e48c9c074",
    .locator = "tools/perf_hub.zig#sealed_seq_replay_driver_source",
    .sha256 = "e5d06b290c19f23af281213ba04b43c7c68962b0906b4c1658c981e624b24053",
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
const deep_measurement_schema = "perf-deep-measurement/v1";
const deep_comparison_method = "balanced-round-median-ratio/v1";
const ratio_scale: u64 = 1_000_000;
const resource_tolerance_pct: f64 = 2.0;
const git_binary = "/usr/bin/git";
var process_environment: ?*const std.process.Environ.Map = null;
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
    perf_report_help,
    perf_report_render,
    lift_bench_stats_driver,
    cas_wrapper_smoke,
    cas_smoke_check_help,
    cas_instance_runner_help,
    cas_review_session_help,
    cas_review_session_version,
    cas_budget_governor_driver,
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
    .{ .case_id = "bench-stats-help", .binary = "bench_stats", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "bench-stats-parse", .binary = "bench_stats", .family = "parse", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "perf-report-help", .binary = "perf_report", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "perf-report-render", .binary = "perf_report", .family = "render", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "lift-bench-stats-driver", .binary = "bench_stats", .family = "driver", .case_kind = .driver, .measurement_mode = .latency_alloc, .compat_case = true },
    .{ .case_id = "cas-wrapper-smoke", .binary = "cas", .family = "wrapper", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-smoke-check-help", .binary = "cas_smoke_check", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-instance-runner-help", .binary = "cas_instance_runner", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-review-session-help", .binary = "cas_review_session", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-review-session-version", .binary = "cas_review_session", .family = "version", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-budget-governor-driver", .binary = "cas", .family = "driver", .case_kind = .driver, .measurement_mode = .latency_alloc, .compat_case = true },
};

const MiscCoverages = [_]perf_contract.CommandCoverage{
    .{ .family = "utilities", .coverage = .shallow, .reason = "current utility matrix" },
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
    .{ .descriptor = MiscCases[0], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/bench_stats", .setup = .bench_stats_help, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[1], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/bench_stats", .setup = .bench_stats_parse, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[2], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/perf_report", .setup = .perf_report_help, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[3], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/perf_report", .setup = .perf_report_render, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[4], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/lift-perf-bench-stats", .setup = .lift_bench_stats_driver, .tolerance_pct = 150.0 },
    .{ .descriptor = MiscCases[5], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas", .setup = .cas_wrapper_smoke, .tolerance_pct = 120.0 },
    .{ .descriptor = MiscCases[6], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas_smoke_check", .setup = .cas_smoke_check_help, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[7], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas_instance_runner", .setup = .cas_instance_runner_help, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[8], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas_review_session", .setup = .cas_review_session_help, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[9], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas_review_session", .setup = .cas_review_session_version, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[10], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas-perf-budget-governor", .setup = .cas_budget_governor_driver, .tolerance_pct = 45.0 },
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
    .{ .descriptor = CasAutomationCases[2], .setup = .cas_automation_show, .tolerance_pct = 200.0 },
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
};

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
        .{ .binary = "seq", .coverages = &SeqCoverages, .datasets = &SeqDatasets, .cases = &SeqCases },
        .{ .binary = "ledger", .coverages = &LedgerCoverages, .cases = &LedgerCases },
        .{ .binary = "cas", .coverages = &CasAutomationCoverages, .cases = &CasAutomationCases },
        .{ .binary = "misc", .coverages = &MiscCoverages, .cases = &MiscCases },
    };
}

const ParsedArgs = struct {
    command: Command,
    target: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    process_environment = init.environ_map;
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;
    const parsed = parseArgs(argv[1..]) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    switch (parsed.command) {
        .list => try cmdList(parsed.target),
        .manifest => try cmdManifest(allocator),
        .audit => try cmdAudit(),
        .compare => try cmdCompare(allocator, parsed.target),
        .doctor => try cmdDoctor(allocator, parsed.target),
        .report => try cmdReport(allocator),
    }
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

fn cmdList(target: ?[]const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        const case_desc = case_cfg.descriptor;
        try stdout.print("{s}\t{s}\t{s}\n", .{
            case_desc.case_id,
            case_desc.binary,
            case_desc.measurement_mode.asString(),
        });
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        try stdout.print("{s}\t{s}\t{s}\n", .{
            case_cfg.descriptor.case_id,
            case_cfg.descriptor.binary,
            case_cfg.descriptor.measurement_mode.asString(),
        });
    }
}

fn cmdManifest(allocator: std.mem.Allocator) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try perf_contract.writeManifestJson(allocator, &stdout_writer.interface, allManifests());
    try stdout_writer.interface.flush();
}

fn cmdAudit() !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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
            .path = try allocator.dupeZ(u8, self.path),
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

    fn clone(
        self: CompilerEvidence,
        allocator: std.mem.Allocator,
    ) !CompilerEvidence {
        const approved_path = try allocator.dupeZ(u8, self.approved_path);
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

fn cmdDoctor(allocator: std.mem.Allocator, target: ?[]const u8) !void {
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const current_dir = try std.fs.path.join(allocator, &.{ ".perf-local", machine_name });
    defer allocator.free(current_dir);

    var count: usize = 0;
    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        count += 1;
        const binary_path = resolveBinaryPath(allocator, case_cfg) catch return error.InvalidData;
        allocator.free(binary_path);
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        count += 1;
    }
    if (count == 0) return error.NoMatchingPerfCases;

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("machine_id={s}\n", .{machine_name});
    try stdout.print("cases={d}\n", .{count});
    try stdout.print("machine_dir={s}\n", .{current_dir});
}

fn invalidateCurrentCapsule(
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
) !void {
    const reports_dir = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "reports" },
    );
    defer allocator.free(reports_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(reports_dir);
    const locator_path = try std.fs.path.join(
        allocator,
        &.{ reports_dir, "current-capsule.json" },
    );
    defer allocator.free(locator_path);
    try writeEvidenceFileAtomic(
        allocator,
        locator_path,
        "{\"schema\":\"performance-capsule-ref/v1\"," ++
            "\"capsule\":null,\"status\":\"incomplete\"}\n",
        0o600,
    );
}

fn cmdCompare(allocator: std.mem.Allocator, target: ?[]const u8) !void {
    const expected_rows = matchingCaseCount(target);
    if (expected_rows == 0) return error.NoMatchingPerfCases;
    const machine_dir = try ensureCurrentMachineDir(allocator);
    defer allocator.free(machine_dir);
    try invalidateCurrentCapsule(allocator, machine_dir);
    var built = BuiltState.init(allocator);
    defer built.deinit();

    var rows: std.ArrayList(CompareRow) = .empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    var any_fail = false;

    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        const result = try compareCompatCase(
            allocator,
            machine_dir,
            case_cfg,
            &built,
        );
        try rows.append(allocator, result);
        try stdout.print("{s}\t{s}\t{s}\n", .{ result.status, result.case_id, result.detail });
        if (comparisonStatusFailed(result.status)) any_fail = true;
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        const result = try compareDeepCase(
            allocator,
            machine_dir,
            case_cfg,
            &built,
        );
        try rows.append(allocator, result);
        try stdout.print("{s}\t{s}\t{s}\n", .{ result.status, result.case_id, result.detail });
        if (comparisonStatusFailed(result.status)) any_fail = true;
    }
    if (!comparisonSummaryComplete(
        target,
        expected_rows,
        rows.items,
    )) any_fail = true;
    try writeCompareSummaryRows(
        allocator,
        machine_dir,
        target,
        expected_rows,
        rows.items,
    );
    if (any_fail) std.process.exit(1);
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
    allocator: std.mem.Allocator,
    _: []const u8,
    case_cfg: CompatCase,
    built: *BuiltState,
) !CompareRow {
    const base_binary = baseBinaryOverride(case_cfg) orelse
        return error.PairedBinaryRequired;
    if (case_cfg.descriptor.case_kind == .driver) {
        return error.PairedBinaryRequired;
    }
    const base_exec = try absolutePathForCwdRelative(
        allocator,
        base_binary,
    );
    defer allocator.free(base_exec);
    var base_case = case_cfg;
    base_case.binary_path = base_exec;
    base_case.require_streamed_projection = false;
    var baseline_evidence = try binaryEvidence(
        allocator,
        built,
        base_case,
    );
    defer baseline_evidence.deinit(allocator);
    var candidate_evidence = try binaryEvidence(
        allocator,
        built,
        case_cfg,
    );
    defer candidate_evidence.deinit(allocator);
    try requireExpectedPairedSources(
        baseline_evidence,
        candidate_evidence,
    );
    if (std.mem.eql(
        u8,
        &baseline_evidence.file.sha256,
        &candidate_evidence.file.sha256,
    )) {
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
    try requireBinaryUnchanged(baseline_evidence);
    try requireBinaryUnchanged(candidate_evidence);
    var paired = try runPairedMeasuredCases(
        allocator,
        base_case,
        candidate_case,
    );
    defer paired.deinit(allocator);
    try requireBinaryUnchanged(baseline_evidence);
    try requireBinaryUnchanged(candidate_evidence);
    const compare = try compareMeasuredMetrics(
        case_cfg,
        paired.baseline,
        paired.candidate,
    );
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
    allocator: std.mem.Allocator,
    _: []const u8,
    case_cfg: DeepCase,
    built: *BuiltState,
) !CompareRow {
    if (!std.mem.eql(u8, case_cfg.descriptor.binary, "seq")) {
        return error.PairedBinaryRequired;
    }
    var compat_case = rootCompat(
        case_cfg.descriptor,
        "build-seq",
        "zig-out/bin/seq",
        .seq_observe,
    );
    compat_case.warmups = case_cfg.warmups;
    compat_case.samples = case_cfg.samples;
    compat_case.tolerance_pct = case_cfg.tolerance_pct;
    const base_binary = baseBinaryOverride(compat_case) orelse
        return error.PairedBinaryRequired;
    const base_exec = try absolutePathForCwdRelative(
        allocator,
        base_binary,
    );
    defer allocator.free(base_exec);
    var base_case = compat_case;
    base_case.binary_path = base_exec;
    var baseline_evidence = try binaryEvidence(
        allocator,
        built,
        base_case,
    );
    defer baseline_evidence.deinit(allocator);
    var candidate_evidence = try binaryEvidence(
        allocator,
        built,
        compat_case,
    );
    defer candidate_evidence.deinit(allocator);
    try requireExpectedPairedSources(
        baseline_evidence,
        candidate_evidence,
    );
    if (isPreCutoverBinary(baseline_evidence.version)) {
        return error.IncompatibleBaseSurface;
    }
    var paired = try runPairedDeepCases(
        allocator,
        built,
        case_cfg,
        baseline_evidence,
        candidate_evidence,
    );
    defer paired.deinit(allocator);
    const driver_warmups = try std.math.mul(
        usize,
        case_cfg.warmups,
        paired_comparison_rounds + 1,
    );
    const effective_warmups = try std.math.add(
        usize,
        driver_warmups,
        case_cfg.samples,
    );
    const comparison_case = CompatCase{
        .descriptor = case_cfg.descriptor,
        .builder = .root,
        .build_step = "build-seq",
        .binary_path = "zig-out/bin/seq",
        .setup = .seq_observe,
        .warmups = effective_warmups,
        .samples = paired.candidate.samples.items.len,
        .tolerance_pct = case_cfg.tolerance_pct,
    };
    const compare = try compareBalancedDeepMetrics(
        case_cfg,
        paired.baseline,
        paired.candidate,
    );
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
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(reports_dir);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(
        "{\"schema\":\"performance-capsule/v1\",\"target\":",
    );
    if (target) |selected| {
        try std.json.Stringify.value(selected, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"expected_base_sha\":");
    const environment = process_environment;
    if (environment) |values| {
        if (values.get("PERF_EXPECT_BASE_SHA")) |sha| {
            try std.json.Stringify.value(sha, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"expected_candidate_sha\":");
    if (environment) |values| {
        if (values.get("PERF_EXPECT_CANDIDATE_SHA")) |sha| {
            try std.json.Stringify.value(sha, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"expected_rows\":");
    try writer.print("{d}", .{expected_rows});
    try writer.writeAll(",\"complete\":");
    try writer.writeAll(if (comparisonSummaryComplete(
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
    var parsed = try std.json.parseFromSlice(
        PerformanceCapsule,
        allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();
    _ = try validatePerformanceCapsule(
        allocator,
        parsed.value,
        false,
    );
    var capsule = try sealEvidenceBytes(
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
        allocator,
        locator_path,
        locator_output.written(),
        0o600,
    );
}

fn comparisonSummaryComplete(
    target: ?[]const u8,
    expected_rows: usize,
    rows: []const CompareRow,
) bool {
    if (expected_rows != rows.len) return false;
    const selected = target orelse return true;
    if (!std.mem.eql(u8, selected, "seq") and
        !std.mem.eql(u8, selected, "ledger") and
        !std.mem.eql(u8, selected, "cutover"))
    {
        return true;
    }
    const environment = process_environment orelse return false;
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
    extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    extern fn sqlite3_exec(
        db: *sqlite3,
        sql: [*:0]const u8,
        callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int,
        arg: ?*anyopaque,
        errmsg: ?*?[*:0]u8,
    ) c_int;
};

fn matchesTarget(case_id: []const u8, binary: []const u8, target: ?[]const u8) bool {
    const needle = target orelse return true;
    if (std.mem.eql(u8, needle, "cutover")) {
        return std.mem.eql(u8, binary, "seq") or
            std.mem.eql(u8, binary, "ledger");
    }
    if (std.mem.eql(u8, needle, "cas")) return std.mem.startsWith(u8, case_id, "cas-");
    if (isKnownBinaryName(needle)) return std.mem.eql(u8, binary, needle);
    if (std.mem.eql(u8, binary, needle)) return true;
    return std.mem.indexOf(u8, case_id, needle) != null;
}

fn ensureCurrentMachineDir(allocator: std.mem.Allocator) ![]u8 {
    const current_name = try currentMachineDirName(allocator);
    defer allocator.free(current_name);
    const dir_path = try std.fs.path.join(allocator, &.{ ".perf-local", current_name });
    errdefer allocator.free(dir_path);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(".perf-local");
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(dir_path);
    return dir_path;
}

fn resolveBinaryPath(allocator: std.mem.Allocator, case_cfg: CompatCase) ![]u8 {
    _ = case_cfg.builder;
    if (std.fs.path.isAbsolute(case_cfg.binary_path)) {
        return allocator.dupe(u8, case_cfg.binary_path);
    }
    const environment = process_environment;
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

fn resolveBinaryExecPath(allocator: std.mem.Allocator, case_cfg: CompatCase) ![]u8 {
    return resolveBinaryPath(allocator, case_cfg);
}

fn baseBinaryOverride(case_cfg: CompatCase) ?[]const u8 {
    const environment = process_environment orelse return null;
    if (std.mem.eql(u8, case_cfg.descriptor.binary, "seq")) {
        return environment.get("PERF_SEQ_BASE_BINARY");
    }
    if (std.mem.eql(u8, case_cfg.descriptor.binary, "ledger")) {
        return environment.get("PERF_LEDGER_BASE_BINARY");
    }
    return null;
}

fn requireExpectedPairedSources(
    baseline: BinaryEvidence,
    candidate: BinaryEvidence,
) !void {
    const environment = process_environment orelse
        return error.ExpectedSourceShaRequired;
    try requireExpectedSourceShas(
        environment,
        baseline.source_sha,
        candidate.source_sha,
    );
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
        allocator.free(self.product_source_sha);
        allocator.free(self.product_source_tree_sha);
        self.compiler.deinit(allocator);
        self.* = undefined;
    }
};

fn binaryEvidence(
    allocator: std.mem.Allocator,
    built: *BuiltState,
    case_cfg: CompatCase,
) !BinaryEvidence {
    const resolved = try resolveBinaryExecPath(allocator, case_cfg);
    defer allocator.free(resolved);
    const original_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        resolved,
        allocator,
    );
    defer allocator.free(original_path);
    const source_root = try sourceRootForBinaryAlloc(
        allocator,
        original_path,
    );
    errdefer allocator.free(source_root);
    try requireCleanSourceRoot(allocator, source_root);
    const source_sha = try sourceShaForRootAlloc(
        allocator,
        source_root,
    );
    errdefer allocator.free(source_sha);
    const source_tree_sha = try sourceTreeShaForRootAlloc(
        allocator,
        source_root,
    );
    errdefer allocator.free(source_tree_sha);
    const isolated = try ensureSourceBuilt(
        allocator,
        built,
        source_root,
        source_sha,
    );
    if (!std.mem.eql(u8, isolated.source_tree_sha, source_tree_sha)) {
        return error.ProductSourceChanged;
    }
    var file = try (try isolated.executable(
        case_cfg.descriptor.binary,
    )).clone(allocator);
    errdefer file.deinit(allocator);
    var source_archive = try isolated.source_archive.clone(allocator);
    errdefer source_archive.deinit(allocator);
    var compiler = try isolated.compiler.clone(allocator);
    errdefer compiler.deinit(allocator);
    const original_sha = try sha256BuildOutput(original_path);
    if (!std.mem.eql(u8, &original_sha, &file.sha256)) {
        return error.ProductBinaryChanged;
    }
    const result = try runChildCaptureOutput(
        allocator,
        ".",
        &.{ file.path, "version" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BinaryVersionFailed;
    const version = try allocator.dupe(
        u8,
        std.mem.trim(u8, result.stdout, " \t\r\n"),
    );
    errdefer allocator.free(version);
    const current_original_sha = try sha256BuildOutput(original_path);
    if (!std.mem.eql(u8, &current_original_sha, &file.sha256)) {
        return error.ProductBinaryChanged;
    }
    try requireCleanSourceRoot(allocator, source_root);
    const current_source_sha = try sourceShaForRootAlloc(
        allocator,
        source_root,
    );
    defer allocator.free(current_source_sha);
    const current_tree_sha = try sourceTreeShaForRootAlloc(
        allocator,
        source_root,
    );
    defer allocator.free(current_tree_sha);
    if (!std.mem.eql(u8, current_source_sha, source_sha) or
        !std.mem.eql(u8, current_tree_sha, source_tree_sha))
    {
        return error.ProductSourceChanged;
    }
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

fn driverEvidence(
    allocator: std.mem.Allocator,
    built: BuiltSource,
) !DriverEvidence {
    var file = try built.perf_hub.clone(allocator);
    errdefer file.deinit(allocator);
    const source_tree_sha = try allocator.dupe(
        u8,
        built.driver_source_tree_sha,
    );
    errdefer allocator.free(source_tree_sha);
    var source_file = try built.driver_source_file.clone(allocator);
    errdefer source_file.deinit(allocator);
    const product_source_sha = try allocator.dupe(u8, built.source_sha);
    errdefer allocator.free(product_source_sha);
    const product_source_tree_sha = try allocator.dupe(
        u8,
        built.source_tree_sha,
    );
    errdefer allocator.free(product_source_tree_sha);
    var compiler = try built.compiler.clone(allocator);
    errdefer compiler.deinit(allocator);
    return .{
        .file = file,
        .source_sha = active_seq_replay_driver_v1.revision,
        .source_tree_sha = source_tree_sha,
        .source_file = source_file,
        .product_source_sha = product_source_sha,
        .product_source_tree_sha = product_source_tree_sha,
        .product_source_archive_sha256 = built.source_archive.sha256,
        .compiler = compiler,
    };
}

fn requireDriverUnchanged(driver: DriverEvidence) !void {
    verifySealedFile(driver.file) catch return error.DriverBinaryChanged;
}

fn requireBinaryUnchanged(evidence: BinaryEvidence) !void {
    verifySealedFile(evidence.file) catch return error.ProductBinaryChanged;
}

fn requireCompilerDigestAtPath(
    path: []const u8,
    expected_digest: []const u8,
) !void {
    if (expected_digest.len != 64) return error.CompilerBinaryChanged;
    const observed = try sha256FileBounded(path, 64 * 1024 * 1024);
    if (!std.mem.eql(u8, &observed, expected_digest)) {
        return error.CompilerBinaryChanged;
    }
}

fn approvedCompilerEvidence(
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
) !CompilerEvidence {
    const environment = process_environment orelse
        return error.ApprovedZigBinaryRequired;
    const configured = environment.get("PERF_ZIG_BINARY") orelse
        return error.ApprovedZigBinaryRequired;
    if (!std.fs.path.isAbsolute(configured)) {
        return error.ApprovedZigBinaryRequired;
    }
    const approved_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        configured,
        allocator,
    );
    errdefer allocator.free(approved_path);
    var file = try sealEvidenceFile(
        allocator,
        machine_dir,
        "zig",
        approved_path,
        64 * 1024 * 1024,
        0o500,
    );
    errdefer file.deinit(allocator);
    const result = try runChildCaptureOutput(
        allocator,
        ".",
        &.{ approved_path, "version" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CompilerVersionFailed;
    const approved_digest = try sha256FileBounded(
        approved_path,
        64 * 1024 * 1024,
    );
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

fn sha256File(path: []const u8) ![64]u8 {
    return sha256FileBounded(path, 16 * 1024 * 1024);
}

fn sha256FileBounded(path: []const u8, max_bytes: usize) ![64]u8 {
    const bytes = try readRegularFileAlloc(
        std.heap.page_allocator,
        path,
        max_bytes,
    );
    defer std.heap.page_allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn sha256BuildOutput(path: []const u8) ![64]u8 {
    const bytes = try readBuildOutputAlloc(
        std.heap.page_allocator,
        path,
        16 * 1024 * 1024,
    );
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
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(blob_dir);
    const blob_path = try std.fs.path.join(
        allocator,
        &.{ blob_dir, label },
    );
    defer allocator.free(blob_path);
    if (pathExists(blob_path)) {
        const retained = try sha256FileBounded(
            blob_path,
            max_sealed_evidence_bytes,
        );
        if (!std.mem.eql(u8, &retained, &digest)) {
            return error.PerfEvidenceDigestMismatch;
        }
    } else {
        try writeEvidenceFileAtomic(allocator, blob_path, bytes, mode);
    }
    const real_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        blob_path,
        allocator,
    );
    defer allocator.free(real_path);
    return .{
        .path = try allocator.dupeZ(u8, real_path),
        .sha256 = digest,
    };
}

fn sealEvidenceFile(
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
    const bytes = try readStableFileAlloc(
        allocator,
        path,
        max_bytes,
        false,
    );
    defer allocator.free(bytes);
    return sealEvidenceBytes(allocator, machine_dir, label, bytes, mode);
}

fn verifySealedFile(file: SealedFile) !void {
    const retained = try sha256FileBounded(
        file.path,
        64 * 1024 * 1024,
    );
    if (!std.mem.eql(u8, &retained, &file.sha256)) {
        return error.PerfEvidenceDigestMismatch;
    }
}

fn readRegularFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return readStableFileAlloc(allocator, path, max_bytes, true);
}

fn readBuildOutputAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return readStableFileAlloc(allocator, path, max_bytes, false);
}

fn readStableFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
    require_single_link: bool,
) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        )
    else
        try std.Io.Dir.cwd().openFile(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        );
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    const before = try file.stat(std.Io.Threaded.global_single_threaded.io());
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
        std.Io.Threaded.global_single_threaded.io(),
        bytes,
        0,
    );
    if (count != size) return error.PerfEvidenceFileChanged;
    const after = try file.stat(std.Io.Threaded.global_single_threaded.io());
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
            if (isDeepCaseId(case_cfg.descriptor.case_id))
                DeepCases[0].batch_iterations
            else
                0,
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
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn sourceRootForBinaryAlloc(
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
        const found = pathExists(marker);
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
    allocator: std.mem.Allocator,
    source_root: []const u8,
) !void {
    const result = try runChildCaptureOutput(
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
    allocator: std.mem.Allocator,
    source_root: []const u8,
) ![]u8 {
    const result = try runChildCaptureOutput(
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
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(@tagName(case_cfg.setup));
    hasher.update(&.{0});
    try hashObservedCommand(
        allocator,
        case_cfg,
        temp_root,
        &hasher,
    );
    var root = try std.Io.Dir.openDirAbsolute(
        std.Io.Threaded.global_single_threaded.io(),
        temp_root,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer root.close(std.Io.Threaded.global_single_threaded.io());
    var walker = try root.walk(allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    while (try walker.next(
        std.Io.Threaded.global_single_threaded.io(),
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
    var buffer: [64 * 1024]u8 = undefined;
    for (paths.items) |path| {
        hasher.update(if (isObservedBindingPath(path))
            "ledger-repo/.ledger/.bindings/<definition>.jsonl"
        else
            path);
        hasher.update(&.{0});
        if (isObservedBindingPath(path)) {
            try hashObservedBinding(
                allocator,
                &root,
                path,
                &hasher,
            );
            hasher.update(&.{0xff});
            continue;
        }
        var file = try root.openFile(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        );
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        var reader = file.reader(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        while (true) { // tiger: event-loop -- bounded by observed bytes.
            const count = try reader.interface.readSliceShort(&buffer);
            if (count == 0) break;
            total_bytes = std.math.add(
                usize,
                total_bytes,
                count,
            ) catch return error.PerfWorkloadTooLarge;
            if (total_bytes > 128 * 1024 * 1024) {
                return error.PerfWorkloadTooLarge;
            }
            hasher.update(buffer[0..count]);
        }
        hasher.update(&.{0xff});
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashObservedCommand(
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
    hasher: *std.crypto.hash.sha2.Sha256,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const run = try renderCompatRun(
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
            try hashObservedExternalArgument(allocator, arg, hasher);
        }
    }
}

fn hashObservedExternalArgument(
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
        !pathExists(candidate))
    {
        return;
    }
    const stat = std.Io.Dir.cwd().statFile(
        std.Io.Threaded.global_single_threaded.io(),
        candidate,
        .{ .follow_symlinks = false },
    ) catch return;
    if (stat.kind != .file or stat.size > 4 * 1024 * 1024) return;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
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

fn observedWorkloadPath(
    setup: CompatSetup,
    path: []const u8,
) bool {
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
    allocator: std.mem.Allocator,
    root: *std.Io.Dir,
    path: []const u8,
    hasher: *std.crypto.hash.sha2.Sha256,
) !void {
    const raw = try root.readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
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
        try hashObservedBindingRecord(
            allocator,
            payload,
            hasher,
        );
        hasher.update(&.{0xfe});
    }
    if (records == 0) return error.PerfWorkloadBindingInvalid;
}

fn hashObservedBindingRecord(
    allocator: std.mem.Allocator,
    raw: []const u8,
    hasher: *std.crypto.hash.sha2.Sha256,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw,
        .{},
    );
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

fn runPairedMeasuredCases(
    allocator: std.mem.Allocator,
    baseline_case: CompatCase,
    candidate_case: CompatCase,
) !PairedMetrics {
    if (baseline_case.samples != candidate_case.samples or
        baseline_case.warmups != candidate_case.warmups)
    {
        return error.MismatchedPairedPerfCase;
    }
    const baseline_root = try makeTempRoot(
        allocator,
        "paired-baseline",
    );
    defer releaseTempRoot(allocator, baseline_root, retainPairedWorkloads());
    const candidate_root = try makeTempRoot(
        allocator,
        "paired-candidate",
    );
    defer releaseTempRoot(allocator, candidate_root, retainPairedWorkloads());
    try prepareCompatCase(allocator, baseline_case, baseline_root);
    try prepareCompatCase(allocator, candidate_case, candidate_root);
    const baseline_execution = try measuredOutputEvidenceOnce(
        allocator,
        baseline_case,
        baseline_root,
    );
    const candidate_execution = try measuredOutputEvidenceOnce(
        allocator,
        candidate_case,
        candidate_root,
    );
    try requireExecutionParity(
        baseline_execution,
        candidate_execution,
    );
    const baseline_workload = try observedWorkloadDigest(
        allocator,
        baseline_case,
        baseline_root,
    );
    const candidate_workload = try observedWorkloadDigest(
        allocator,
        candidate_case,
        candidate_root,
    );
    if (!std.mem.eql(u8, &baseline_workload, &candidate_workload)) {
        var stderr_writer = std.Io.File.stderr().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        try stderr_writer.interface.print(
            "paired workload mismatch: baseline=sha256:{s} " ++
                "candidate=sha256:{s} baseline_root={s} " ++
                "candidate_root={s}\n",
            .{
                baseline_workload,
                candidate_workload,
                baseline_root,
                candidate_root,
            },
        );
        return error.PerfWorkloadMismatch;
    }

    var baseline_samples: std.ArrayList(u64) = .empty;
    errdefer baseline_samples.deinit(allocator);
    var baseline_allocs: std.ArrayList(u64) = .empty;
    errdefer baseline_allocs.deinit(allocator);
    var baseline_rss: std.ArrayList(u64) = .empty;
    errdefer baseline_rss.deinit(allocator);
    var candidate_samples: std.ArrayList(u64) = .empty;
    errdefer candidate_samples.deinit(allocator);
    var candidate_allocs: std.ArrayList(u64) = .empty;
    errdefer candidate_allocs.deinit(allocator);
    var candidate_rss: std.ArrayList(u64) = .empty;
    errdefer candidate_rss.deinit(allocator);
    const measured_samples = std.math.mul(
        usize,
        baseline_case.samples,
        paired_comparison_rounds,
    ) catch return error.PerfSampleCountOverflow;
    try baseline_samples.ensureTotalCapacity(
        allocator,
        measured_samples,
    );
    try baseline_allocs.ensureTotalCapacity(
        allocator,
        measured_samples,
    );
    try candidate_samples.ensureTotalCapacity(
        allocator,
        measured_samples,
    );
    try candidate_allocs.ensureTotalCapacity(
        allocator,
        measured_samples,
    );
    try baseline_rss.ensureTotalCapacity(allocator, measured_samples);
    try candidate_rss.ensureTotalCapacity(allocator, measured_samples);

    var warmup_idx: usize = 0;
    while (warmup_idx < baseline_case.warmups) : (warmup_idx += 1) {
        try runCompatWarmup(
            allocator,
            baseline_case,
            baseline_root,
        );
        try runCompatWarmup(
            allocator,
            candidate_case,
            candidate_root,
        );
    }
    var sample_idx: usize = 0;
    while (sample_idx < measured_samples) : (sample_idx += 1) {
        if (sample_idx % 2 == 0) {
            try appendCompatSample(
                allocator,
                baseline_case,
                baseline_root,
                &baseline_samples,
                &baseline_allocs,
                &baseline_rss,
            );
            try appendCompatSample(
                allocator,
                candidate_case,
                candidate_root,
                &candidate_samples,
                &candidate_allocs,
                &candidate_rss,
            );
        } else {
            try appendCompatSample(
                allocator,
                candidate_case,
                candidate_root,
                &candidate_samples,
                &candidate_allocs,
                &candidate_rss,
            );
            try appendCompatSample(
                allocator,
                baseline_case,
                baseline_root,
                &baseline_samples,
                &baseline_allocs,
                &baseline_rss,
            );
        }
    }
    var baseline = try metricsFromSamples(
        allocator,
        baseline_samples,
        baseline_allocs,
        baseline_rss,
    );
    baseline_samples = .empty;
    baseline_allocs = .empty;
    baseline_rss = .empty;
    errdefer baseline.deinit(allocator);
    const candidate = try metricsFromSamples(
        allocator,
        candidate_samples,
        candidate_allocs,
        candidate_rss,
    );
    candidate_samples = .empty;
    candidate_allocs = .empty;
    candidate_rss = .empty;
    return .{
        .baseline = baseline,
        .candidate = candidate,
        .workload_digest = baseline_workload,
        .baseline_execution = baseline_execution,
        .candidate_execution = candidate_execution,
    };
}

fn runPairedDeepCases(
    allocator: std.mem.Allocator,
    built: *BuiltState,
    case_cfg: DeepCase,
    baseline_evidence: BinaryEvidence,
    candidate_evidence: BinaryEvidence,
) !PairedMetrics {
    const baseline_root = baseline_evidence.source_root;
    const candidate_root = candidate_evidence.source_root;
    try requireBinaryUnchanged(baseline_evidence);
    try requireBinaryUnchanged(candidate_evidence);
    const baseline_built = ensureSourceBuilt(
        allocator,
        built,
        baseline_root,
        baseline_evidence.source_sha,
    ) catch |err| return deepStageError("baseline-driver-build", err);
    var baseline_driver = try driverEvidence(
        allocator,
        baseline_built.*,
    );
    errdefer baseline_driver.deinit(allocator);
    const candidate_built = ensureSourceBuilt(
        allocator,
        built,
        candidate_root,
        candidate_evidence.source_sha,
    ) catch |err| return deepStageError("candidate-driver-build", err);
    var candidate_driver = try driverEvidence(
        allocator,
        candidate_built.*,
    );
    errdefer candidate_driver.deinit(allocator);
    try requireBinaryUnchanged(baseline_evidence);
    try requireBinaryUnchanged(candidate_evidence);
    const baseline_workload = deepWorkloadDigestForRoot(
        allocator,
        baseline_root,
        case_cfg,
    ) catch |err| return deepStageError("baseline-workload", err);
    const candidate_workload = deepWorkloadDigestForRoot(
        allocator,
        candidate_root,
        case_cfg,
    ) catch |err| return deepStageError("candidate-workload", err);
    if (!std.mem.eql(u8, &baseline_workload, &candidate_workload)) {
        return error.PerfWorkloadMismatch;
    }
    // Each product is measured against its co-located immutable driver and
    // source tree. The cross-product digest normalizes only the absolute-path
    // component of a separately verified physical source-event identity.
    const baseline_semantic = productDeepSemanticOutputEvidence(
        allocator,
        baseline_evidence.file.path,
        baseline_root,
    ) catch |err| return deepStageError("baseline-semantic", err);
    const candidate_semantic = productDeepSemanticOutputEvidence(
        allocator,
        candidate_evidence.file.path,
        candidate_root,
    ) catch |err| return deepStageError("candidate-semantic", err);
    if (!std.mem.eql(
        u8,
        &baseline_semantic.output_sha256,
        &candidate_semantic.output_sha256,
    )) {
        return error.PerfSemanticOutputMismatch;
    }

    var baseline_samples: std.ArrayList(u64) = .empty;
    errdefer baseline_samples.deinit(allocator);
    var baseline_allocs: std.ArrayList(u64) = .empty;
    errdefer baseline_allocs.deinit(allocator);
    var baseline_rss: std.ArrayList(u64) = .empty;
    errdefer baseline_rss.deinit(allocator);
    var candidate_samples: std.ArrayList(u64) = .empty;
    errdefer candidate_samples.deinit(allocator);
    var candidate_allocs: std.ArrayList(u64) = .empty;
    errdefer candidate_allocs.deinit(allocator);
    var candidate_rss: std.ArrayList(u64) = .empty;
    errdefer candidate_rss.deinit(allocator);
    const measured_samples = std.math.mul(
        usize,
        case_cfg.samples,
        paired_comparison_rounds,
    ) catch return error.PerfSampleCountOverflow;
    try baseline_samples.ensureTotalCapacity(allocator, measured_samples);
    try candidate_samples.ensureTotalCapacity(allocator, measured_samples);
    try candidate_allocs.ensureTotalCapacity(allocator, measured_samples);
    try baseline_rss.ensureTotalCapacity(
        allocator,
        paired_comparison_rounds,
    );
    try candidate_rss.ensureTotalCapacity(
        allocator,
        paired_comparison_rounds,
    );
    try baseline_allocs.ensureTotalCapacity(
        allocator,
        paired_comparison_rounds,
    );
    primeSourceDeepCase(
        allocator,
        baseline_root,
        case_cfg,
        baseline_driver,
    ) catch |err| return deepStageError("baseline-prime", err);
    primeSourceDeepCase(
        allocator,
        candidate_root,
        case_cfg,
        candidate_driver,
    ) catch |err| return deepStageError("candidate-prime", err);

    var round: usize = 0;
    while (round < paired_comparison_rounds) : (round += 1) {
        if (round % 2 == 0) {
            try appendSourceDeepMetrics(
                allocator,
                baseline_root,
                case_cfg,
                baseline_driver,
                &baseline_samples,
                &baseline_allocs,
                &baseline_rss,
            );
            try appendSourceDeepMetrics(
                allocator,
                candidate_root,
                case_cfg,
                candidate_driver,
                &candidate_samples,
                &candidate_allocs,
                &candidate_rss,
            );
        } else {
            try appendSourceDeepMetrics(
                allocator,
                candidate_root,
                case_cfg,
                candidate_driver,
                &candidate_samples,
                &candidate_allocs,
                &candidate_rss,
            );
            try appendSourceDeepMetrics(
                allocator,
                baseline_root,
                case_cfg,
                baseline_driver,
                &baseline_samples,
                &baseline_allocs,
                &baseline_rss,
            );
        }
    }
    var baseline = try metricsFromSamples(
        allocator,
        baseline_samples,
        baseline_allocs,
        baseline_rss,
    );
    baseline_samples = .empty;
    baseline_allocs = .empty;
    baseline_rss = .empty;
    errdefer baseline.deinit(allocator);
    const candidate = try metricsFromSamples(
        allocator,
        candidate_samples,
        candidate_allocs,
        candidate_rss,
    );
    candidate_samples = .empty;
    candidate_allocs = .empty;
    candidate_rss = .empty;
    try requireBinaryUnchanged(baseline_evidence);
    try requireBinaryUnchanged(candidate_evidence);
    const final_baseline_workload = deepWorkloadDigestForRoot(
        allocator,
        baseline_root,
        case_cfg,
    ) catch |err| return deepStageError("baseline-workload-final", err);
    const final_candidate_workload = deepWorkloadDigestForRoot(
        allocator,
        candidate_root,
        case_cfg,
    ) catch |err| return deepStageError("candidate-workload-final", err);
    if (!std.mem.eql(u8, &baseline_workload, &final_baseline_workload) or
        !std.mem.eql(u8, &candidate_workload, &final_candidate_workload))
    {
        return error.PerfWorkloadChanged;
    }
    return .{
        .baseline = baseline,
        .candidate = candidate,
        .workload_digest = baseline_workload,
        .baseline_execution = baseline_semantic,
        .candidate_execution = candidate_semantic,
        .baseline_driver = baseline_driver,
        .candidate_driver = candidate_driver,
    };
}

fn deepStageError(stage: []const u8, err: anyerror) anyerror {
    std.debug.print(
        "perf_hub deep stage={s} error={s}\n",
        .{ stage, @errorName(err) },
    );
    return err;
}

fn primeSourceDeepCase(
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
    allocator: std.mem.Allocator,
    built: *BuiltState,
    source_root: []const u8,
    expected_source_sha: []const u8,
) !*const BuiltSource {
    if (!validFullRevision(expected_source_sha)) {
        return error.DriverSourceRevisionMismatch;
    }
    const key = try std.fmt.allocPrint(
        allocator,
        "{s}:isolated-source",
        .{source_root},
    );
    defer allocator.free(key);
    if (built.sources.getPtr(key)) |driver| {
        if (!std.mem.eql(
            u8,
            driver.source_sha,
            expected_source_sha,
        )) return error.DriverSourceRevisionMismatch;
        return driver;
    }
    try requireCleanSourceRoot(allocator, source_root);
    const observed_source_sha = try sourceShaForRootAlloc(
        allocator,
        source_root,
    );
    defer allocator.free(observed_source_sha);
    if (!std.mem.eql(
        u8,
        observed_source_sha,
        expected_source_sha,
    )) return error.DriverSourceRevisionMismatch;
    const source_tree_sha = try sourceTreeShaForRootAlloc(
        allocator,
        source_root,
    );
    defer allocator.free(source_tree_sha);

    const machine_dir_relative = try ensureCurrentMachineDir(allocator);
    defer allocator.free(machine_dir_relative);
    const machine_dir = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        machine_dir_relative,
        allocator,
    );
    defer allocator.free(machine_dir);
    const driver_source_tree_sha = active_seq_replay_driver_v1.tree;
    const driver_source_bytes = try seqReplayDriverSourceBytesAlloc(allocator);
    defer allocator.free(driver_source_bytes);
    const driver_source_digest = evidenceDigest(driver_source_bytes);
    if (!std.mem.eql(
        u8,
        &driver_source_digest,
        active_seq_replay_driver_v1.sha256,
    )) return error.DriverSourceRevisionMismatch;
    var driver_source_file = try sealEvidenceBytes(
        allocator,
        machine_dir,
        "perf_hub.zig",
        driver_source_bytes,
        0o400,
    );
    var driver_source_file_owned = true;
    defer if (driver_source_file_owned) {
        driver_source_file.deinit(allocator);
    };
    const staging_root = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "capsules", "staging" },
    );
    defer allocator.free(staging_root);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(staging_root);
    const nonce = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{std.Io.Clock.awake.now(
            std.Io.Threaded.global_single_threaded.io(),
        ).nanoseconds},
    );
    defer allocator.free(nonce);
    const staging_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/.build-{s}-{s}",
        .{
            staging_root,
            expected_source_sha[0..@min(expected_source_sha.len, 12)],
            nonce,
        },
    );
    defer allocator.free(staging_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(staging_dir);
    defer std.Io.Dir.cwd().deleteTree(
        std.Io.Threaded.global_single_threaded.io(),
        staging_dir,
    ) catch |err| {
        std.debug.print(
            "perf_hub warning: remove staging directory: {s}\n",
            .{@errorName(err)},
        );
    };
    var compiler = try approvedCompilerEvidence(allocator, machine_dir);
    var compiler_owned = true;
    defer if (compiler_owned) compiler.deinit(allocator);
    const archive_path = try std.fs.path.join(
        allocator,
        &.{ staging_dir, "source.tar" },
    );
    defer allocator.free(archive_path);
    const source_snapshot = try std.fs.path.join(
        allocator,
        &.{ staging_dir, "source" },
    );
    defer allocator.free(source_snapshot);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(source_snapshot);
    const archive_result = try runChildCapture(
        allocator,
        source_root,
        &.{
            git_binary,
            "archive",
            "--format=tar",
            "--output",
            archive_path,
            expected_source_sha,
        },
    );
    defer allocator.free(archive_result.stdout);
    defer allocator.free(archive_result.stderr);
    if (archive_result.exit_code != 0) return error.SourceSnapshotFailed;
    var source_archive = try sealEvidenceFile(
        allocator,
        machine_dir,
        "source.tar",
        archive_path,
        max_sealed_evidence_bytes,
        0o600,
    );
    var source_archive_owned = true;
    defer if (source_archive_owned) source_archive.deinit(allocator);
    const extract_result = try runChildCapture(
        allocator,
        staging_dir,
        &.{
            "/usr/bin/tar",
            "-xf",
            source_archive.path,
            "-C",
            source_snapshot,
        },
    );
    defer allocator.free(extract_result.stdout);
    defer allocator.free(extract_result.stderr);
    if (extract_result.exit_code != 0) return error.SourceSnapshotFailed;
    const prefix_dir = try std.fs.path.join(
        allocator,
        &.{ source_snapshot, "zig-out" },
    );
    defer allocator.free(prefix_dir);
    const cache_dir = try std.fs.path.join(
        allocator,
        &.{ staging_dir, "cache" },
    );
    defer allocator.free(cache_dir);
    const global_cache_dir = try std.fs.path.join(
        allocator,
        &.{ staging_dir, "global-cache" },
    );
    defer allocator.free(global_cache_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(prefix_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(cache_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(global_cache_dir);
    const result = try runChildCapture(
        allocator,
        source_snapshot,
        &.{
            compiler.approved_path,
            "build",
            "-Doptimize=ReleaseFast",
            "--prefix",
            prefix_dir,
            "--cache-dir",
            cache_dir,
            "--global-cache-dir",
            global_cache_dir,
        },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BuildFailed;
    try requireCleanSourceRoot(allocator, source_root);
    const post_source_sha = try sourceShaForRootAlloc(
        allocator,
        source_root,
    );
    defer allocator.free(post_source_sha);
    const post_tree_sha = try sourceTreeShaForRootAlloc(
        allocator,
        source_root,
    );
    defer allocator.free(post_tree_sha);
    if (!std.mem.eql(u8, post_source_sha, expected_source_sha) or
        !std.mem.eql(u8, post_tree_sha, source_tree_sha))
    {
        return error.DriverSourceChangedDuringBuild;
    }
    try verifySealedFile(compiler.file);
    try requireCompilerDigestAtPath(
        compiler.approved_path,
        &compiler.file.sha256,
    );
    var executables: [3]SealedFile = undefined;
    var executable_count: usize = 0;
    defer for (executables[0..executable_count]) |*file| {
        file.deinit(allocator);
    };
    for ([_][]const u8{ "seq", "ledger" }, 0..) |name, index| {
        const built_path = try std.fs.path.join(
            allocator,
            &.{ prefix_dir, "bin", name },
        );
        defer allocator.free(built_path);
        executables[index] = try sealEvidenceFile(
            allocator,
            machine_dir,
            name,
            built_path,
            16 * 1024 * 1024,
            0o500,
        );
        executable_count += 1;
    }
    const driver_source_path = try std.fs.path.join(
        allocator,
        &.{ source_snapshot, driver_overlay_path },
    );
    defer allocator.free(driver_source_path);
    try writeEvidenceFileAtomic(
        allocator,
        driver_source_path,
        driver_source_bytes,
        0o400,
    );
    const overlaid_driver_source_sha = try sha256FileBounded(
        driver_source_path,
        max_sealed_evidence_bytes,
    );
    if (!std.mem.eql(
        u8,
        &overlaid_driver_source_sha,
        &driver_source_file.sha256,
    )) return error.DriverSourceChangedDuringBuild;
    const driver_cache_dir = try std.fs.path.join(
        allocator,
        &.{ staging_dir, "driver-cache" },
    );
    defer allocator.free(driver_cache_dir);
    const driver_global_cache_dir = try std.fs.path.join(
        allocator,
        &.{ staging_dir, "driver-global-cache" },
    );
    defer allocator.free(driver_global_cache_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(
        driver_cache_dir,
    );
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(
        driver_global_cache_dir,
    );
    const driver_build = try runChildCapture(
        allocator,
        source_snapshot,
        &.{
            compiler.approved_path,
            "build",
            "-Doptimize=ReleaseFast",
            "--prefix",
            prefix_dir,
            "--cache-dir",
            driver_cache_dir,
            "--global-cache-dir",
            driver_global_cache_dir,
        },
    );
    defer allocator.free(driver_build.stdout);
    defer allocator.free(driver_build.stderr);
    if (driver_build.exit_code != 0) return error.BuildFailed;
    try verifySealedFile(driver_source_file);
    try requireCompilerDigestAtPath(
        compiler.approved_path,
        &compiler.file.sha256,
    );
    const built_driver_path = try std.fs.path.join(
        allocator,
        &.{ prefix_dir, "bin", "perf_hub" },
    );
    defer allocator.free(built_driver_path);
    executables[2] = try sealEvidenceFile(
        allocator,
        machine_dir,
        "perf_hub",
        built_driver_path,
        16 * 1024 * 1024,
        0o500,
    );
    executable_count += 1;
    try requireCleanSourceRoot(allocator, source_root);
    const final_source_sha = try sourceShaForRootAlloc(
        allocator,
        source_root,
    );
    defer allocator.free(final_source_sha);
    const final_tree_sha = try sourceTreeShaForRootAlloc(
        allocator,
        source_root,
    );
    defer allocator.free(final_tree_sha);
    if (!std.mem.eql(u8, final_source_sha, expected_source_sha) or
        !std.mem.eql(u8, final_tree_sha, source_tree_sha))
    {
        return error.DriverSourceChangedDuringBuild;
    }
    try verifySealedFile(compiler.file);
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_source_sha = try allocator.dupe(
        u8,
        expected_source_sha,
    );
    errdefer allocator.free(owned_source_sha);
    const owned_source_tree_sha = try allocator.dupe(
        u8,
        source_tree_sha,
    );
    errdefer allocator.free(owned_source_tree_sha);
    const owned_driver_source_tree_sha = try allocator.dupe(
        u8,
        driver_source_tree_sha,
    );
    errdefer allocator.free(owned_driver_source_tree_sha);
    const owned_source: BuiltSource = .{
        .seq = executables[0],
        .ledger = executables[1],
        .perf_hub = executables[2],
        .source_sha = owned_source_sha,
        .source_tree_sha = owned_source_tree_sha,
        .source_archive = source_archive,
        .driver_source_tree_sha = owned_driver_source_tree_sha,
        .driver_source_file = driver_source_file,
        .compiler = compiler,
    };
    try built.sources.put(owned_key, owned_source);
    executable_count = 0;
    source_archive_owned = false;
    driver_source_file_owned = false;
    compiler_owned = false;
    return built.sources.getPtr(key) orelse unreachable;
}

fn validFullRevision(revision: []const u8) bool {
    if (revision.len != 40 and revision.len != 64) return false;
    for (revision) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn sourceTreeShaForRootAlloc(
    allocator: std.mem.Allocator,
    source_root: []const u8,
) ![]u8 {
    return revisionTreeShaForRootAlloc(
        allocator,
        source_root,
        "HEAD",
    );
}

fn revisionTreeShaForRootAlloc(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    revision: []const u8,
) ![]u8 {
    const tree_revision = try std.fmt.allocPrint(
        allocator,
        "{s}^{{tree}}",
        .{revision},
    );
    defer allocator.free(tree_revision);
    const result = try runChildCaptureOutput(
        allocator,
        ".",
        &.{ git_binary, "-C", source_root, "rev-parse", tree_revision },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BinarySourceUnavailable;
    const tree = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!validFullRevision(tree)) return error.BinarySourceUnavailable;
    return allocator.dupe(
        u8,
        tree,
    );
}

fn seqReplayDriverSourceBytesAlloc(
    allocator: std.mem.Allocator,
) ![]u8 {
    return allocator.dupe(u8, sealed_seq_replay_driver_source);
}

fn deepWorkloadDigestForRoot(
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
        const path = try std.fs.path.join(
            allocator,
            &.{ source_root, relative_path },
        );
        defer allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
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
    allocator: std.mem.Allocator,
    source_root: []const u8,
    case_cfg: DeepCase,
    driver: DriverEvidence,
    samples: *std.ArrayList(u64),
    alloc_samples: *std.ArrayList(u64),
    rss_samples: *std.ArrayList(u64),
) !void {
    requireDriverUnchanged(driver) catch |err|
        return deepStageError("driver-preflight", err);
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const artifact_name = try std.fmt.allocPrint(
        allocator,
        "{s}.json",
        .{case_cfg.descriptor.case_id},
    );
    defer allocator.free(artifact_name);
    const artifact_path = try std.fs.path.join(
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
    defer allocator.free(artifact_path);
    std.Io.Dir.cwd().deleteFile(
        std.Io.Threaded.global_single_threaded.io(),
        artifact_path,
    ) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const result = runChildCaptureOutput(
        allocator,
        source_root,
        &.{
            driver.file.path,
            "capture",
            "--target",
            case_cfg.descriptor.case_id,
        },
    ) catch |err| return deepStageError("driver-spawn", err);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
    validateCaptureAcknowledgment(
        allocator,
        result.stdout,
        case_cfg.descriptor.case_id,
    ) catch |err| return deepStageError("driver-acknowledgment", err);
    requireDriverUnchanged(driver) catch |err|
        return deepStageError("driver-postflight", err);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        artifact_path,
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{},
    );
    defer parsed.deinit();
    try validateSharedDriverArtifact(
        parsed.value,
        case_cfg,
        driver.product_source_sha,
    );
    const metrics = parsed.value.object.get("metrics") orelse
        return error.InvalidData;
    const raw_samples = metrics.object.get("samples_ns") orelse
        return error.InvalidData;
    if (raw_samples.array.items.len != case_cfg.samples) {
        return error.DeepMeasurementSampleCountMismatch;
    }
    for (raw_samples.array.items) |raw| {
        try samples.append(
            allocator,
            try jsonValueU64(raw, "samples_ns"),
        );
    }
    const batch_allocs = try jsonFieldU64(
        metrics.object,
        "p50_alloc_calls",
    );
    try alloc_samples.append(
        allocator,
        batch_allocs / case_cfg.batch_iterations,
    );
    try rss_samples.append(
        allocator,
        result.peak_rss_bytes orelse return error.MissingPeakRss,
    );
}

fn validateCaptureAcknowledgment(
    allocator: std.mem.Allocator,
    raw: []const u8,
    case_id: []const u8,
) !void {
    const expected = try std.fmt.allocPrint(
        allocator,
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
        (git_sha.len > 0 and std.mem.startsWith(
            u8,
            product_source_sha,
            git_sha,
        ));
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
    allocator: std.mem.Allocator,
    binary_path: []const u8,
    source_root: []const u8,
) !MeasuredOutputEvidence {
    const result = try runChildCaptureOutput(
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
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        rendered,
        .{},
    );
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

fn expectedSourceEventId(
    path: []const u8,
    line_number: usize,
    ordinal: usize,
) [71]u8 {
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

fn retainPairedWorkloads() bool {
    const environment = process_environment orelse return false;
    return environment.get("PERF_RETAIN_PAIRED_ROOTS") != null;
}

fn runCompatWarmup(
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) !void {
    var run_arena = std.heap.ArenaAllocator.init(allocator);
    defer run_arena.deinit();
    const run = try renderCompatRun(
        run_arena.allocator(),
        case_cfg,
        temp_root,
    );
    const result = try runChildCapture(allocator, run.cwd, run.argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
}

fn appendCompatSample(
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
        run_arena.allocator(),
        case_cfg,
        temp_root,
    );
    const start_ns = std.Io.Clock.awake.now(
        std.Io.Threaded.global_single_threaded.io(),
    ).nanoseconds;
    const result = try runChildCapture(allocator, run.cwd, run.argv);
    const elapsed: u64 = @intCast(@max(
        std.Io.Clock.awake.now(
            std.Io.Threaded.global_single_threaded.io(),
        ).nanoseconds - start_ns,
        1,
    ));
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
    try samples.append(allocator, elapsed);
    try alloc_samples.append(allocator, 0);
    try rss_samples.append(
        allocator,
        result.peak_rss_bytes orelse return error.MissingPeakRss,
    );
}

fn validateMeasuredOutput(
    case_cfg: CompatCase,
    raw: []const u8,
) !void {
    if (!case_cfg.require_streamed_projection) return;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        raw,
        .{},
    );
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
    try requireOptionalEqual(
        baseline.records_emitted,
        candidate.records_emitted,
    );
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

fn requireOptionalNonIncreasing(
    baseline: ?u64,
    candidate: ?u64,
) !void {
    if (baseline == null and candidate == null) return;
    if (baseline == null or candidate == null or
        candidate.? > baseline.?)
    {
        return error.PerfExecutionTopologyMismatch;
    }
}

fn measuredOutputEvidenceOnce(
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) !MeasuredOutputEvidence {
    var run_arena = std.heap.ArenaAllocator.init(allocator);
    defer run_arena.deinit();
    const run = try renderCompatRun(
        run_arena.allocator(),
        case_cfg,
        temp_root,
    );
    const result = try runChildCaptureOutput(
        allocator,
        run.cwd,
        run.argv,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
    try validateMeasuredOutput(case_cfg, result.stdout);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.stdout, &digest, .{});
    var evidence: MeasuredOutputEvidence = .{
        .output_sha256 = std.fmt.bytesToHex(digest, .lower),
        .semantic_output_sha256 = try semanticOutputDigest(
            allocator,
            result.stdout,
            temp_root,
        ),
    };
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        result.stdout,
        .{},
    ) catch return evidence;
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
    ) catch return evidenceDigest(raw);
    defer parsed.deinit();
    try normalizeSemanticOutput(&parsed.value);
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

fn normalizeSemanticOutput(value: *std.json.Value) !void {
    switch (value.*) {
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "stats")) {
                    switch (entry.value_ptr.*) {
                        .object => entry.value_ptr.* = .null,
                        else => return error.InvalidPerfSemanticOutput,
                    }
                    continue;
                }
                if (std.mem.eql(u8, entry.key_ptr.*, "definition")) {
                    const definition = switch (entry.value_ptr.*) {
                        .object => |*nested| nested,
                        else => return error.InvalidPerfSemanticOutput,
                    };
                    const digest = definition.getPtr("digest") orelse
                        return error.InvalidPerfSemanticOutput;
                    const encoded = switch (digest.*) {
                        .string => |string| string,
                        else => return error.InvalidPerfSemanticOutput,
                    };
                    if (!validSha256Identity(encoded)) {
                        return error.InvalidPerfSemanticOutput;
                    }
                    digest.* = .{ .string = normalized_source_event_id };
                }
                if (std.mem.eql(u8, entry.key_ptr.*, "compile_ns") or
                    std.mem.eql(u8, entry.key_ptr.*, "execution_ns") or
                    std.mem.eql(u8, entry.key_ptr.*, "output_bytes"))
                {
                    entry.value_ptr.* = .{ .integer = 0 };
                    continue;
                }
                if (std.mem.eql(u8, entry.key_ptr.*, "source_event_id")) {
                    const encoded = switch (entry.value_ptr.*) {
                        .string => |string| string,
                        else => return error.InvalidPerfSemanticOutput,
                    };
                    if (!validSha256Identity(encoded)) {
                        return error.InvalidPerfSourceEventIdentity;
                    }
                    entry.value_ptr.* = .{
                        .string = normalized_source_event_id,
                    };
                    continue;
                }
                if (std.mem.eql(u8, entry.key_ptr.*, "transaction_id")) {
                    switch (entry.value_ptr.*) {
                        .string => |string| if (string.len == 0) {
                            return error.InvalidPerfSemanticOutput;
                        },
                        .null => continue,
                        else => return error.InvalidPerfSemanticOutput,
                    }
                    entry.value_ptr.* = .{
                        .string = normalized_transaction_id,
                    };
                    continue;
                }
                try normalizeSemanticOutput(entry.value_ptr);
            }
        },
        .array => |*array| for (array.items) |*item| {
            try normalizeSemanticOutput(item);
        },
        else => {},
    }
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
    return .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .rss_samples = rss_samples,
        .p50_ns = try percentileU64(allocator, samples.items, 50),
        .p95_ns = try percentileU64(allocator, samples.items, 95),
        .p50_alloc_calls = try percentileU64(
            allocator,
            alloc_samples.items,
            50,
        ),
        .p95_rss_bytes = try percentileU64(
            allocator,
            rss_samples.items,
            95,
        ),
    };
}

fn canonicalDataDigest(
    allocator: std.mem.Allocator,
    rendered: []const u8,
) ![64]u8 {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        rendered,
        .{},
    );
    defer parsed.deinit();
    const data = parsed.value.object.get("data") orelse
        return error.InvalidPerfSemanticOutput;
    return canonicalValueDigest(allocator, data);
}

fn canonicalValueDigest(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![64]u8 {
    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        value,
    );
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
    const allowed_rss = try observableRssUpperBound(
        baseline.p95_rss_bytes,
        resource_tolerance_pct,
    );
    if (candidate.p95_rss_bytes > allowed_rss) {
        return .{
            .status = "FAIL",
            .detail = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "paired p95_rss_bytes candidate={d} base={d} allowed={d}",
                .{
                    candidate.p95_rss_bytes,
                    baseline.p95_rss_bytes,
                    allowed_rss,
                },
            ),
        };
    }
    const allowed_p50 = allowedUpperBoundWithTolerance(
        baseline.p50_ns,
        case_cfg.tolerance_pct,
    );
    const allowed_p95 = allowedUpperBoundWithTolerance(
        baseline.p95_ns,
        case_cfg.tolerance_pct,
    );
    if (candidate.p50_ns > allowed_p50) {
        return .{
            .status = "FAIL",
            .detail = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "paired p50 candidate={d} base={d} allowed={d}",
                .{ candidate.p50_ns, baseline.p50_ns, allowed_p50 },
            ),
        };
    }
    if (candidate.p95_ns > allowed_p95) {
        return .{
            .status = "FAIL",
            .detail = try std.fmt.allocPrint(
                std.heap.page_allocator,
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
                .detail = try std.fmt.allocPrint(
                    std.heap.page_allocator,
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
        @intFromEnum(std.c._SC.PAGESIZE),
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
    const expected_samples = try std.math.mul(
        usize,
        case_cfg.samples,
        paired_comparison_rounds,
    );
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
        p50_ratios[round] = try quantileRatioPpm(
            baseline_latency[start..end],
            candidate_latency[start..end],
            50,
        );
        p95_ratios[round] = try quantileRatioPpm(
            baseline_latency[start..end],
            candidate_latency[start..end],
            95,
        );
        allocation_ratios[round] = try ratioPpm(
            baseline_allocations[round],
            candidate_allocations[round],
        );
        rss_ratios[round] = try ratioPpm(
            baseline_rss[round],
            candidate_rss[round],
        );
    }
    const p50_ratio = medianRatioPpm(&p50_ratios);
    const p95_ratio = medianRatioPpm(&p95_ratios);
    const allocation_ratio = medianRatioPpm(&allocation_ratios);
    const rss_ratio = medianRatioPpm(&rss_ratios);
    const allowed_ratio: u64 = @intFromFloat(std.math.ceil(
        @as(f64, @floatFromInt(ratio_scale)) *
            (1.0 + case_cfg.tolerance_pct / 100.0),
    ));
    if (p50_ratio > allowed_ratio) {
        return .{
            .status = "FAIL",
            .detail = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "balanced round p50 ratio_ppm={d} > {d}",
                .{ p50_ratio, allowed_ratio },
            ),
        };
    }
    if (p95_ratio > allowed_ratio) {
        return .{
            .status = "FAIL",
            .detail = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "balanced round p95 ratio_ppm={d} > {d}",
                .{ p95_ratio, allowed_ratio },
            ),
        };
    }
    if (allocation_ratio > allowed_ratio) {
        return .{
            .status = "FAIL",
            .detail = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "balanced round allocation ratio_ppm={d} > {d}",
                .{ allocation_ratio, allowed_ratio },
            ),
        };
    }
    const allowed_rss_ratio: u64 = @intFromFloat(std.math.ceil(
        @as(f64, @floatFromInt(ratio_scale)) *
            (1.0 + resource_tolerance_pct / 100.0),
    ));
    if (rss_ratio > allowed_rss_ratio) {
        return .{
            .status = "FAIL",
            .detail = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "balanced round rss ratio_ppm={d} > {d}",
                .{ rss_ratio, allowed_rss_ratio },
            ),
        };
    }
    return .{
        .status = "PASS",
        .detail = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "balanced round ratios p50_ppm={d} p95_ppm={d} " ++
                "allocation_ppm={d} rss_ppm={d}",
            .{ p50_ratio, p95_ratio, allocation_ratio, rss_ratio },
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

fn quantileRatioPpm(
    baseline: []const u64,
    candidate: []const u64,
    percentile: usize,
) !u64 {
    const base = try percentileU64(
        std.heap.page_allocator,
        baseline,
        percentile,
    );
    const current = try percentileU64(
        std.heap.page_allocator,
        candidate,
        percentile,
    );
    return ratioPpm(base, current);
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

fn writeMetricsObject(
    writer: *std.Io.Writer,
    metrics: Metrics,
    include_allocations: bool,
) !void {
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

fn writeSealedFile(
    writer: *std.Io.Writer,
    file: SealedFile,
) !void {
    try writer.writeAll("{\"label\":");
    try writeJsonString(writer, std.fs.path.basename(file.path));
    try writer.writeAll(",\"sha256\":\"sha256:");
    try writer.writeAll(&file.sha256);
    try writer.writeAll("\"}");
}

fn writeBinaryEvidence(
    writer: *std.Io.Writer,
    evidence: BinaryEvidence,
) !void {
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

fn writeCompilerEvidence(
    writer: *std.Io.Writer,
    compiler: CompilerEvidence,
) !void {
    try writer.writeAll("{\"approved_path\":");
    try writeJsonString(writer, compiler.approved_path);
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, compiler.version);
    try writer.writeAll(",\"file\":");
    try writeSealedFile(writer, compiler.file);
    try writer.writeByte('}');
}

fn writeDriverEvidence(
    writer: *std.Io.Writer,
    evidence: DriverEvidence,
) !void {
    try writer.writeAll("{\"file\":");
    try writeSealedFile(writer, evidence.file);
    try writer.writeAll(",\"source\":{\"revision\":");
    try writeJsonString(writer, evidence.source_sha);
    try writer.writeAll(",\"tree\":");
    try writeJsonString(writer, evidence.source_tree_sha);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, active_seq_replay_driver_v1.locator);
    try writer.writeAll(",\"file\":");
    try writeSealedFile(writer, evidence.source_file);
    try writer.writeAll("},\"product_source\":{\"revision\":");
    try writeJsonString(writer, evidence.product_source_sha);
    try writer.writeAll(",\"tree\":");
    try writeJsonString(writer, evidence.product_source_tree_sha);
    try writer.writeAll(",\"archive_sha256\":\"sha256:");
    try writer.writeAll(&evidence.product_source_archive_sha256);
    try writer.writeByte('"');
    try writer.writeAll("},\"compiler\":");
    try writeCompilerEvidence(writer, evidence.compiler);
    try writer.writeAll(
        ",\"build\":{\"optimize\":\"ReleaseFast\",\"step\":\"install\"," ++
            "\"repo_local_prefix\":true,\"isolated_caches\":true," ++
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
    try writer.writeAll(",\"baseline\":{\"binary\":");
    try writeBinaryEvidence(writer, baseline_evidence);
    if (baseline_driver) |driver| {
        try writer.writeAll(",\"driver\":");
        try writeDriverEvidence(writer, driver);
    }
    try writer.writeAll(",\"metrics\":");
    try writeMetricsObject(
        writer,
        baseline,
        case_cfg.descriptor.measurement_mode == .latency_alloc,
    );
    try writer.writeAll(",\"execution\":");
    try writeMeasuredOutputEvidence(writer, baseline_execution);
    try writer.writeAll("},\"candidate\":{\"binary\":");
    try writeBinaryEvidence(writer, candidate_evidence);
    if (candidate_driver) |driver| {
        try writer.writeAll(",\"driver\":");
        try writeDriverEvidence(writer, driver);
    }
    try writer.writeAll(",\"metrics\":");
    try writeMetricsObject(
        writer,
        candidate,
        case_cfg.descriptor.measurement_mode == .latency_alloc,
    );
    try writer.writeAll(",\"execution\":");
    try writeMeasuredOutputEvidence(writer, candidate_execution);
    try writer.writeAll("},\"compare_status\":");
    try writeJsonString(writer, compare_status);
    try writer.writeAll(",\"compare_detail\":");
    try writeJsonString(writer, compare_detail);
    try writer.writeAll("}\n");
    return output.toOwnedSlice();
}

fn writeMeasuredOutputEvidence(
    writer: *std.Io.Writer,
    evidence: MeasuredOutputEvidence,
) !void {
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

fn writeOptionalU64(
    writer: *std.Io.Writer,
    field: []const u8,
    value: ?u64,
) !void {
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
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
    temp_root: []const u8,
) !void {
    switch (case_cfg.setup) {
        .seq_sessions, .seq_query => {
            return prepareSeqPerfCorpus(allocator, temp_root);
        },
        .ledger_transact, .ledger_project, .ledger_doctor => {},
        else => return,
    }
    const repo_path = try std.fs.path.join(
        allocator,
        &.{ temp_root, "ledger-repo" },
    );
    defer allocator.free(repo_path);
    try makeRepoAwarePath(allocator, repo_path);
    const definition_path = try prepareLedgerPerfDefinition(
        allocator,
        temp_root,
    );
    defer allocator.free(definition_path);
    try prepareLedgerPerfStore(
        allocator,
        repo_path,
        definition_path,
        case_cfg,
    );
}

fn prepareSeqPerfCorpus(
    allocator: std.mem.Allocator,
    temp_root: []const u8,
) !void {
    const session_dir = try std.fs.path.join(
        allocator,
        &.{ temp_root, "seq-sessions/2026/07/26" },
    );
    defer allocator.free(session_dir);
    try makeRepoAwarePath(allocator, session_dir);
    const session_path = try std.fs.path.join(
        allocator,
        &.{
            session_dir,
            "rollout-2026-07-26T10-00-00-fixture-session.jsonl",
        },
    );
    defer allocator.free(session_path);
    try std.Io.Dir.cwd().writeFile(
        std.Io.Threaded.global_single_threaded.io(),
        .{ .sub_path = session_path, .data = seq_perf_corpus },
    );
}

fn prepareLedgerPerfDefinition(
    allocator: std.mem.Allocator,
    temp_root: []const u8,
) ![]u8 {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "apps/ledger/src/v1/fixtures/event-definition.json",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(source);
    const store_bytes = try std.fmt.allocPrint(
        allocator,
        "\"max_bytes\":{d}",
        .{ledger_perf_max_store_bytes},
    );
    defer allocator.free(store_bytes);
    const max_store_bytes = try std.fmt.allocPrint(
        allocator,
        "\"max_store_bytes\":{d}",
        .{ledger_perf_max_store_bytes},
    );
    defer allocator.free(max_store_bytes);
    const max_records = try std.fmt.allocPrint(
        allocator,
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
    try std.Io.Dir.cwd().writeFile(
        std.Io.Threaded.global_single_threaded.io(),
        .{ .sub_path = definition_path, .data = expanded_records },
    );
    return definition_path;
}

fn prepareLedgerPerfStore(
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
    try makeRepoAwarePath(allocator, event_dir);
    const event_path = try std.fs.path.join(
        allocator,
        &.{ event_dir, "events.jsonl" },
    );
    defer allocator.free(event_path);
    var file = try std.Io.Dir.cwd().createFile(
        std.Io.Threaded.global_single_threaded.io(),
        event_path,
        .{},
    );
    {
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        var writer = file.writer(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        var index: usize = 0;
        while (index < ledger_perf_record_count) : (index += 1) {
            try writer.interface.writeAll("{\"kind\":\"one\",\"value\":1}\n");
        }
    }
    const binary_path = try resolveBinaryExecPath(allocator, case_cfg);
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
    const result = try runChildCapture(allocator, ".", &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.PerfSetupFailed;
}

fn renderCompatRun(allocator: std.mem.Allocator, case_cfg: CompatCase, temp_root: []const u8) !CommandRun {
    const binary_path = try resolveBinaryExecPath(allocator, case_cfg);
    errdefer allocator.free(binary_path);
    _ = case_cfg.builder;
    const cwd = try allocator.dupe(u8, ".");
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    switch (case_cfg.setup) {
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
        .seq_sessions => {
            const root = try std.fs.path.join(
                allocator,
                &.{ temp_root, "seq-sessions" },
            );
            try args.appendSlice(allocator, &.{
                binary_path,
                "sessions",
                "--root",
                root,
                "--format",
                "json",
            });
        },
        .seq_query => {
            const root = try std.fs.path.join(
                allocator,
                &.{ temp_root, "seq-sessions" },
            );
            try args.appendSlice(allocator, &.{
                binary_path,
                "query",
                "--root",
                root,
                "--spec",
                "{\"dataset\":\"messages\",\"where\":[" ++
                    "{\"field\":\"text\",\"op\":\"contains\"," ++
                    "\"value\":\"failure\",\"case_insensitive\":true}]," ++
                    "\"select\":[\"session_id\",\"role\",\"text\"]," ++
                    "\"limit\":5,\"format\":\"json\"}",
            });
        },
        .ledger_definition_check => try args.appendSlice(allocator, &.{
            binary_path,
            "definition",
            "check",
            "--definition",
            "apps/ledger/src/v1/fixtures/record-definition.json",
            "--format",
            "json",
        }),
        .ledger_validate => try args.appendSlice(allocator, &.{
            binary_path,
            "validate",
            "--definition",
            "apps/ledger/src/v1/fixtures/record-definition.json",
            "--input",
            "record=apps/ledger/src/v1/fixtures/record-valid.json",
            "--format",
            "json",
        }),
        .ledger_materialize => try args.appendSlice(allocator, &.{
            binary_path,
            "materialize",
            "--definition",
            "apps/ledger/src/v1/fixtures/record-definition.json",
            "--input",
            "record=apps/ledger/src/v1/fixtures/record-valid.json",
            "--format",
            "json",
        }),
        .ledger_transact => {
            const repo_path = try std.fs.path.join(
                allocator,
                &.{ temp_root, "ledger-repo" },
            );
            const definition_path = try std.fs.path.join(
                allocator,
                &.{ temp_root, "ledger-event-definition.json" },
            );
            try args.appendSlice(allocator, &.{
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
            });
        },
        .ledger_project => {
            const repo_path = try std.fs.path.join(
                allocator,
                &.{ temp_root, "ledger-repo" },
            );
            const definition_path = try std.fs.path.join(
                allocator,
                &.{ temp_root, "ledger-event-definition.json" },
            );
            try args.appendSlice(allocator, &.{
                binary_path,
                "project",
                "--definition",
                definition_path,
                "--projection",
                "all",
                "--repo",
                repo_path,
                "--format",
                "json",
            });
        },
        .ledger_doctor => {
            const repo_path = try std.fs.path.join(
                allocator,
                &.{ temp_root, "ledger-repo" },
            );
            const definition_path = try std.fs.path.join(
                allocator,
                &.{ temp_root, "ledger-event-definition.json" },
            );
            try args.appendSlice(allocator, &.{
                binary_path,
                "doctor",
                "--definition",
                definition_path,
                "--repo",
                repo_path,
                "--format",
                "json",
            });
        },
        .bench_stats_help,
        .perf_report_help,
        .cas_smoke_check_help,
        .cas_instance_runner_help,
        .cas_review_session_help,
        => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
        .cas_automation_help => try args.appendSlice(
            allocator,
            &.{ binary_path, "automation", "--help" },
        ),
        .cas_review_session_version => try args.appendSlice(allocator, &.{ binary_path, "--version" }),
        .bench_stats_parse => {
            const input_path = try std.fs.path.join(allocator, &.{ ".", "apps/lift/perf/fixtures/bench_stats_input.txt" });
            try args.appendSlice(allocator, &.{ binary_path, "--input", input_path, "--json" });
        },
        .perf_report_render => {
            const output_path = try std.fs.path.join(allocator, &.{ temp_root, "perf-report.md" });
            try args.appendSlice(allocator, &.{ binary_path, "--title", "Perf", "--owner", "tk", "--system", "skills-zig", "--output", output_path });
        },
        .cas_wrapper_smoke => {
            const wrapper_dir = try std.fs.path.join(allocator, &.{ temp_root, "cas-wrapper" });
            try makeRepoAwarePath(allocator, wrapper_dir);
            const wrapper_binary = try std.fs.path.join(allocator, &.{ wrapper_dir, "cas" });
            const source_binary = try absolutePathForCwdRelative(allocator, binary_path);
            defer allocator.free(source_binary);
            try std.Io.Dir.copyFileAbsolute(source_binary, wrapper_binary, std.Io.Threaded.global_single_threaded.io(), .{});
            try makeExecutable(wrapper_binary);
            const stub_path = try std.fs.path.join(allocator, &.{ wrapper_dir, "cas_smoke_check" });
            try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = stub_path, .data = "#!/usr/bin/env bash\nexit 0\n" });
            try makeExecutable(stub_path);
            return .{ .cwd = cwd, .argv = try allocator.dupe([]const u8, &.{ wrapper_binary, "smoke_check" }) };
        },
        .cas_automation_list => {
            const db_name = try std.fmt.allocPrint(allocator, "codex-dev-{d}.db", .{@divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000)});
            const db_path = try std.fs.path.join(allocator, &.{ temp_root, db_name });
            try seedCasAutomationDb(allocator, db_path);
            try args.appendSlice(
                allocator,
                &.{ binary_path, "automation", "--db", db_path, "list" },
            );
        },
        else => return error.InvalidCommand,
    }
    return .{ .cwd = cwd, .argv = try args.toOwnedSlice(allocator) };
}

const ChildResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    peak_rss_bytes: ?u64 = null,
};

fn runChildCapture(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !ChildResult {
    if (builtin.os.tag == .macos) {
        return runChildCapturePosixSpawn(allocator, cwd, argv, false);
    }

    const result = try std.process.run(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
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
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) !ChildResult {
    if (builtin.os.tag == .macos) {
        return runChildCapturePosixSpawn(allocator, cwd, argv, true);
    }
    return runChildCapture(allocator, cwd, argv);
}

fn runChildCapturePosixSpawn(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    capture_stdout: bool,
) !ChildResult {
    if (argv.len == 0) return error.FileNotFound;

    var argv_buf = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    defer allocator.free(argv_buf);

    var arg_storage = try allocator.alloc([:0]u8, argv.len);
    var arg_count: usize = 0;
    defer {
        for (arg_storage[0..arg_count]) |arg| allocator.free(arg);
        allocator.free(arg_storage);
    }
    for (argv, 0..) |arg, idx| {
        arg_storage[idx] = try allocator.dupeZ(u8, arg);
        arg_count += 1;
        argv_buf[idx] = arg_storage[idx].ptr;
    }

    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);

    var actions: std.c.posix_spawn_file_actions_t = undefined;
    const init_rc = std.c.posix_spawn_file_actions_init(&actions);
    if (init_rc != 0) return posixSpawnError(init_rc);
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);

    const capture_root = if (capture_stdout)
        try makeTempRoot(allocator, "capture")
    else
        null;
    defer if (capture_root) |path| releaseTempRoot(allocator, path, false);
    const capture_path = if (capture_root) |root|
        try std.fs.path.join(allocator, &.{ root, "stdout" })
    else
        null;
    defer if (capture_path) |path| allocator.free(path);
    const capture_path_z = if (capture_path) |path|
        try allocator.dupeZ(u8, path)
    else
        null;
    defer if (capture_path_z) |path| allocator.free(path);
    const dev_null = "/dev/null";
    const dev_null_flags: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .WRONLY })));
    const stdout_flags: c_int = @intCast(@as(u32, @bitCast(std.c.O{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    })));
    const stdout_rc = std.c.posix_spawn_file_actions_addopen(
        &actions,
        1,
        if (capture_path_z) |path| path else dev_null,
        if (capture_stdout) stdout_flags else dev_null_flags,
        if (capture_stdout) 0o600 else 0,
    );
    if (stdout_rc != 0) return posixSpawnError(stdout_rc);
    const stderr_rc = std.c.posix_spawn_file_actions_addopen(
        &actions,
        2,
        dev_null,
        dev_null_flags,
        0,
    );
    if (stderr_rc != 0) return posixSpawnError(stderr_rc);
    const chdir_rc = std.c.posix_spawn_file_actions_addchdir_np(&actions, cwd_z);
    if (chdir_rc != 0) return posixSpawnError(chdir_rc);

    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const spawn_rc = std.c.posix_spawnp(&pid, argv_buf[0].?, &actions, null, argv_buf.ptr, envp);
    if (spawn_rc != 0) return posixSpawnError(spawn_rc);

    var status: if (builtin.link_libc) c_int else u32 = undefined;
    var usage: std.posix.rusage = undefined;
    while (true) switch (std.posix.errno( // tiger: event-loop -- bounded by child exit.
        std.posix.system.wait4(pid, &status, 0, &usage),
    )) {
        .SUCCESS => {
            const stdout = if (capture_path) |path|
                try std.Io.Dir.cwd().readFileAlloc(
                    std.Io.Threaded.global_single_threaded.io(),
                    path,
                    allocator,
                    .limited(8 * 1024 * 1024),
                )
            else
                try allocator.dupe(u8, "");
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
    const err: std.c.E = @enumFromInt(@as(u16, @intCast(rc)));
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
        const signal: u32 = @intFromEnum(std.posix.W.TERMSIG(status));
        return @intCast(@min(@as(u32, 128) + signal, @as(u32, 255)));
    }
    return 1;
}

fn makeTempRoot(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    const stamp = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    const base = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/perf-hub/{d}-{s}", .{ cwd, stamp, label });
    try makeRepoAwarePath(allocator, base);
    return base;
}

fn releaseTempRoot(
    allocator: std.mem.Allocator,
    path: []u8,
    retain: bool,
) void {
    if (!retain) {
        std.Io.Dir.cwd().deleteTree(
            std.Io.Threaded.global_single_threaded.io(),
            path,
        ) catch |err| {
            std.log.warn(
                "temp-root cleanup failed path={s} error={s}",
                .{ path, @errorName(err) },
            );
        };
    }
    allocator.free(path);
}

fn makeExecutable(path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .mode = .read_write });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    try file.setPermissions(std.Io.Threaded.global_single_threaded.io(), @enumFromInt(0o755));
}

fn absolutePathForCwdRelative(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn seedCasAutomationDb(allocator: std.mem.Allocator, db_path: []const u8) !void {
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    var db_opt: ?*Sqlite.sqlite3 = null;
    if (Sqlite.sqlite3_open(db_path_z, &db_opt) != Sqlite.SQLITE_OK or db_opt == null) return error.InvalidData;
    defer _ = Sqlite.sqlite3_close(db_opt.?);

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
    const schema_z = try allocator.dupeZ(u8, schema);
    defer allocator.free(schema_z);
    var err_msg: ?[*:0]u8 = null;
    if (Sqlite.sqlite3_exec(db_opt.?, schema_z, null, null, &err_msg) != Sqlite.SQLITE_OK) {
        if (err_msg) |msg| {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try stderr_writer.interface.print(
                "seedCasAutomationDb sqlite error: {s}\n",
                .{std.mem.sliceTo(msg, 0)},
            );
        }
        return error.InvalidData;
    }
}

fn percentileU64(allocator: std.mem.Allocator, samples: []const u64, p: usize) !u64 {
    const copy = try allocator.dupe(u64, samples);
    defer allocator.free(copy);
    std.mem.sort(u64, copy, {}, struct {
        fn less(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.less);
    const idx = ((copy.len - 1) * p) / 100;
    return copy[idx];
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
        .float => |v| if (v >= 0) @intFromFloat(v) else error.InvalidData,
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

fn cmdReport(allocator: std.mem.Allocator) !void {
    const machine_dir = try resolveMachineDir(allocator, ".perf-local");
    defer allocator.free(machine_dir);
    const locator_path = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "reports", "current-capsule.json" },
    );
    defer allocator.free(locator_path);
    const locator_data = readRegularFileAlloc(
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
    const data = try loadCapsuleFileAlloc(
        allocator,
        locator.value.capsule orelse return error.MissingCompareSummary,
        4 * 1024 * 1024,
    );
    defer allocator.free(data);
    var parsed = std.json.parseFromSlice(
        PerformanceCapsule,
        allocator,
        data,
        .{},
    ) catch return error.InvalidCompareSummary;
    defer parsed.deinit();
    try validatePerformanceCapsule(allocator, parsed.value, true);
    const cutover = parsed.value.target != null and
        std.mem.eql(u8, parsed.value.target.?, "cutover");
    if (cutover) {
        const value = ReportTuple{
            .base_sha = parsed.value.expected_base_sha,
            .candidate_sha = parsed.value.expected_candidate_sha,
        };
        const environment = process_environment orelse
            return error.ExpectedSourceShaRequired;
        const current_sha = try sourceShaForRootAlloc(allocator, ".");
        defer allocator.free(current_sha);
        try requireCutoverReportTuple(environment, value, current_sha);
        try requireCleanSourceRoot(allocator, ".");
    }
    var totals = std.StringHashMap(ReportCounts).init(allocator);
    defer totals.deinit();
    for (parsed.value.rows) |row| {
        const entry = try totals.getOrPutValue(row.binary, .{});
        if (std.mem.eql(u8, row.status, "PASS")) {
            entry.value_ptr.pass += 1;
        } else {
            entry.value_ptr.fail += 1;
        }
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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
            allocator,
            row,
            capsule.expected_base_sha,
            capsule.expected_candidate_sha,
        );
    }
}

fn validatePairedEvidence(
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
    try validateProductEvidence(
        allocator,
        evidence.baseline.binary,
        expected_base,
    );
    try validateProductEvidence(
        allocator,
        evidence.candidate.binary,
        expected_candidate,
    );
    if (!std.mem.eql(
        u8,
        evidence.baseline.binary.compiler.file.sha256,
        evidence.candidate.binary.compiler.file.sha256,
    )) return error.CompilerBinaryChanged;
    const deep = isDeepCaseId(row.case_id);
    if (deep) {
        const baseline_driver = evidence.baseline.driver orelse
            return error.IncompletePerfDriverEvidence;
        const candidate_driver = evidence.candidate.driver orelse
            return error.IncompletePerfDriverEvidence;
        try validateDriverEvidence(
            allocator,
            baseline_driver,
            evidence.baseline.binary,
        );
        try validateDriverEvidence(
            allocator,
            candidate_driver,
            evidence.candidate.binary,
        );
        try validateRetainedDeepWorkload(
            allocator,
            evidence.workload_digest,
            evidence.baseline.binary.source.revision,
            evidence.candidate.binary.source.revision,
        );
        if (!std.mem.eql(
            u8,
            baseline_driver.source.file.sha256,
            candidate_driver.source.file.sha256,
        ) or !std.mem.eql(
            u8,
            baseline_driver.source.revision,
            candidate_driver.source.revision,
        )) return error.PerfDriverSourceMismatch;
    } else if (evidence.baseline.driver != null or
        evidence.candidate.driver != null)
    {
        return error.InvalidPerfEvidenceFile;
    }
    try validateRetainedMetrics(
        allocator,
        evidence.baseline.metrics,
        config,
        deep,
    );
    try validateRetainedMetrics(
        allocator,
        evidence.candidate.metrics,
        config,
        deep,
    );
    try validateExecution(evidence.baseline.execution);
    try validateExecution(evidence.candidate.execution);
    try requireExecutionParity(
        try executionEvidence(evidence.baseline.execution),
        try executionEvidence(evidence.candidate.execution),
    );
    const computed = if (deep)
        try compareBalancedDeepMetrics(
            DeepCases[0],
            evidence.baseline.metrics,
            evidence.candidate.metrics,
        )
    else
        try compareMeasuredMetrics(
            config,
            evidence.baseline.metrics,
            evidence.candidate.metrics,
        );
    if (!std.mem.eql(u8, computed.status, evidence.compare_status) or
        !std.mem.eql(u8, evidence.compare_status, row.status))
    {
        return error.PerfVerdictMismatch;
    }
}

fn validateRetainedDeepWorkload(
    allocator: std.mem.Allocator,
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
        hasher.update(DeepCases[0].descriptor.case_id);
        hasher.update(&.{0});
        hasher.update(@tagName(DeepCases[0].setup));
        hasher.update(&.{0});
        var encoded: [32]u8 = undefined;
        hasher.update(try std.fmt.bufPrint(
            &encoded,
            "{d}",
            .{DeepCases[0].batch_iterations},
        ));
        for ([_][]const u8{
            "apps/seq/src/v1/fixtures/message-observation.json",
            "apps/seq/src/v1/fixtures/rollout.jsonl",
        }) |path| {
            const object = try std.fmt.allocPrint(
                allocator,
                "{s}:{s}",
                .{ revision, path },
            );
            defer allocator.free(object);
            const result = try runChildCaptureOutput(
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
        if (std.mem.eql(
            u8,
            config.descriptor.case_id,
            case_id,
        )) return config;
    }
    for (DeepCases) |deep| {
        if (!std.mem.eql(
            u8,
            deep.descriptor.case_id,
            case_id,
        )) continue;
        var config = rootCompat(
            deep.descriptor,
            "build-seq",
            "zig-out/bin/seq",
            .seq_observe,
        );
        config.samples = deep.samples;
        config.warmups = deep.warmups;
        config.tolerance_pct = deep.tolerance_pct;
        return config;
    }
    return null;
}

fn validateProductEvidence(
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
    try verifyCapsuleFile(allocator, product.file);
    try verifyCapsuleFile(allocator, product.source.archive);
    try validateCompilerEvidence(allocator, product.compiler);
    try validateIsolatedBuild(product.build);
}

fn validateDriverEvidence(
    allocator: std.mem.Allocator,
    driver: CapsuleDriver,
    product: CapsuleProduct,
) !void {
    try validateDriverSourceMetadata(driver.source);
    if (!std.mem.eql(
        u8,
        driver.product_source.revision,
        product.source.revision,
    ) or !std.mem.eql(
        u8,
        driver.product_source.tree,
        product.source.tree,
    ) or !std.mem.eql(
        u8,
        driver.product_source.archive_sha256,
        product.source.archive.sha256,
    )) {
        return error.PerfEvidenceIdentityMismatch;
    }
    try verifyCapsuleFile(allocator, driver.file);
    try verifyCapsuleFile(allocator, driver.source.file);
    try validateCompilerEvidence(allocator, driver.compiler);
    if (!std.mem.eql(
        u8,
        driver.compiler.file.sha256,
        product.compiler.file.sha256,
    )) return error.CompilerBinaryChanged;
    try validateIsolatedBuild(driver.build);
}

fn validateDriverSourceMetadata(source: CapsuleDriverSource) !void {
    if (driverSourceMatchesIdentity(source, active_seq_replay_driver_v1) or
        driverSourceMatchesIdentity(source, legacy_generic_driver_v1))
    {
        return;
    }
    return error.PerfEvidenceIdentityMismatch;
}

fn driverSourceMatchesIdentity(
    source: CapsuleDriverSource,
    identity: DriverSourceIdentity,
) bool {
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
    allocator: std.mem.Allocator,
    compiler: CapsuleCompiler,
) !void {
    if (!std.fs.path.isAbsolute(compiler.approved_path) or
        compiler.version.len == 0)
    {
        return error.InvalidPerfEvidenceFile;
    }
    try verifyCapsuleFile(allocator, compiler.file);
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
    if (metrics.p50_ns !=
        try percentileU64(allocator, metrics.samples_ns, 50) or
        metrics.p95_ns !=
            try percentileU64(allocator, metrics.samples_ns, 95) or
        metrics.p95_rss_bytes !=
            try percentileU64(
                allocator,
                metrics.rss_samples_bytes,
                95,
            ) or
        (deep and metrics.p50_alloc_calls !=
            try percentileU64(
                allocator,
                metrics.allocation_samples,
                50,
            )))
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
    for (DeepCases) |case_cfg| {
        if (std.mem.eql(
            u8,
            case_id,
            case_cfg.descriptor.case_id,
        )) return case_cfg.descriptor.binary;
    }
    return null;
}

fn isDeepCaseId(case_id: []const u8) bool {
    for (DeepCases) |case_cfg| {
        if (std.mem.eql(u8, case_id, case_cfg.descriptor.case_id)) {
            return true;
        }
    }
    return false;
}

fn loadCapsuleFileAlloc(
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
    const machine_dir_relative = try resolveMachineDir(
        allocator,
        ".perf-local",
    );
    defer allocator.free(machine_dir_relative);
    durable_store.rejectSymlinkComponents(machine_dir_relative) catch |err| switch (err) {
        error.SymlinkComponent => return error.PerfEvidencePathOutsideCapsule,
        else => return err,
    };
    const machine_stat = try std.Io.Dir.cwd().statFile(
        std.Io.Threaded.global_single_threaded.io(),
        machine_dir_relative,
        .{ .follow_symlinks = false },
    );
    if (machine_stat.kind == .sym_link or
        machine_stat.kind != .directory)
    {
        return error.PerfEvidencePathOutsideCapsule;
    }
    const machine_dir = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        machine_dir_relative,
        allocator,
    );
    defer allocator.free(machine_dir);
    const capsules_root = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "capsules" },
    );
    defer allocator.free(capsules_root);
    const capsules_stat = try std.Io.Dir.cwd().statFile(
        std.Io.Threaded.global_single_threaded.io(),
        capsules_root,
        .{ .follow_symlinks = false },
    );
    if (capsules_stat.kind == .sym_link or
        capsules_stat.kind != .directory)
    {
        return error.PerfEvidencePathOutsideCapsule;
    }
    const blobs_root = try std.fs.path.join(
        allocator,
        &.{ capsules_root, "blobs" },
    );
    defer allocator.free(blobs_root);
    const blobs_stat = try std.Io.Dir.cwd().statFile(
        std.Io.Threaded.global_single_threaded.io(),
        blobs_root,
        .{ .follow_symlinks = false },
    );
    if (blobs_stat.kind == .sym_link or
        blobs_stat.kind != .directory)
    {
        return error.PerfEvidencePathOutsideCapsule;
    }
    const digest = file.sha256["sha256:".len..];
    var root = try std.Io.Dir.openDirAbsolute(
        std.Io.Threaded.global_single_threaded.io(),
        blobs_root,
        .{ .follow_symlinks = false },
    );
    defer root.close(std.Io.Threaded.global_single_threaded.io());
    const digest_stat = try root.statFile(
        std.Io.Threaded.global_single_threaded.io(),
        digest,
        .{ .follow_symlinks = false },
    );
    if (digest_stat.kind == .sym_link or digest_stat.kind != .directory) {
        return error.PerfEvidencePathOutsideCapsule;
    }
    const relative_path = try std.fs.path.join(
        allocator,
        &.{ digest, file.label },
    );
    defer allocator.free(relative_path);
    var opened = try root.openFile(
        std.Io.Threaded.global_single_threaded.io(),
        relative_path,
        .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        },
    );
    defer opened.close(std.Io.Threaded.global_single_threaded.io());
    const before = try opened.stat(
        std.Io.Threaded.global_single_threaded.io(),
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
        std.Io.Threaded.global_single_threaded.io(),
        data,
        0,
    );
    if (count != size) return error.PerfEvidenceFileChanged;
    const after = try opened.stat(
        std.Io.Threaded.global_single_threaded.io(),
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
        file.sha256["sha256:".len..],
    )) return error.PerfEvidenceDigestMismatch;
    return data;
}

fn verifyCapsuleFile(
    allocator: std.mem.Allocator,
    file: CapsuleFile,
) !void {
    const data = try loadCapsuleFileAlloc(
        allocator,
        file,
        max_sealed_evidence_bytes,
    );
    allocator.free(data);
}

fn requireCutoverReportTuple(
    environment: *const std.process.Environ.Map,
    tuple: ReportTuple,
    current_sha: []const u8,
) !void {
    try requireExpectedSourceShas(
        environment,
        tuple.base_sha,
        tuple.candidate_sha,
    );
    if (!std.mem.eql(u8, current_sha, tuple.candidate_sha)) {
        return error.CandidateSourceShaMismatch;
    }
}

fn resolveMachineDir(allocator: std.mem.Allocator, perf_root: []const u8) ![]u8 {
    const current_name = try currentMachineDirName(allocator);
    defer allocator.free(current_name);
    const preferred = try std.fs.path.join(allocator, &.{ perf_root, current_name });
    errdefer allocator.free(preferred);
    if (!pathExists(preferred)) return error.MissingMachineDir;
    return preferred;
}

fn currentMachineDirName(allocator: std.mem.Allocator) ![]u8 {
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host_full = try std.posix.gethostname(&host_buf);
    const host = host_full[0 .. std.mem.indexOfScalar(u8, host_full, '.') orelse host_full.len];
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-zig{s}", .{
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

fn inferBinary(case_id: []const u8) []const u8 {
    if (std.mem.startsWith(u8, case_id, "seq-")) return "seq";
    if (std.mem.startsWith(u8, case_id, "ledger-")) return "ledger";
    if (std.mem.startsWith(u8, case_id, "cas-automation-")) return "cas";
    if (std.mem.startsWith(u8, case_id, "bench-stats")) return "bench_stats";
    if (std.mem.startsWith(u8, case_id, "lift-bench-stats")) return "bench_stats";
    if (std.mem.startsWith(u8, case_id, "perf-report")) return "perf_report";
    if (std.mem.startsWith(u8, case_id, "cas-")) return "cas";
    return "unknown";
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

fn makeRepoAwarePath(allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    if (std.fs.path.isAbsolute(path) and std.mem.startsWith(u8, path, cwd)) {
        const rel = if (path.len == cwd.len) "." else path[cwd.len + 1 ..];
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), rel);
        return;
    }
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path);
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
    allocator: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    mode: u32,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or
        std.mem.eql(u8, base, ".."))
    {
        return error.InvalidPerfEvidencePath;
    }
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(parent);
    try requireReplaceableEvidenceTarget(path);
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(
            io,
            parent,
            .{ .follow_symlinks = false },
        )
    else
        try std.Io.Dir.cwd().openDir(
            io,
            parent,
            .{ .follow_symlinks = false },
        );
    defer dir.close(io);
    const tag = std.Io.Clock.awake.now(io).nanoseconds;
    const temp_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.{d}.tmp",
        .{ base, tag },
    );
    defer allocator.free(temp_name);
    var file = try dir.createFile(io, temp_name, .{
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
    var file_open = true;
    errdefer if (file_open) file.close(io);
    errdefer dir.deleteFile(io, temp_name) catch |err| {
        std.debug.print(
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
    try requireReplaceableEvidenceTarget(path);
    try dir.rename(temp_name, dir, base, io);
    var dir_file = try dir.openFile(io, ".", .{
        .allow_directory = true,
        .follow_symlinks = false,
        .path_only = false,
    });
    defer dir_file.close(io);
    try dir_file.sync(io);
}

fn requireReplaceableEvidenceTarget(path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(
        std.Io.Threaded.global_single_threaded.io(),
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
        resolveMachineDir(alloc, ".perf-local"),
    );
}

test "capsule files are digest-addressed beneath the current machine root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd_before = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_before);
    try std.process.setCurrentDir(io, tmp.dir);
    defer restoreTestCwd(io, cwd_before);
    const tmp_root = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(tmp_root);

    const machine_dir = try ensureCurrentMachineDir(allocator);
    defer allocator.free(machine_dir);
    var sealed = try sealEvidenceBytes(
        allocator,
        machine_dir,
        "payload",
        "bound",
        0o600,
    );
    defer sealed.deinit(allocator);
    const identity = try std.fmt.allocPrint(
        allocator,
        "sha256:{s}",
        .{sealed.sha256},
    );
    defer allocator.free(identity);
    const valid = CapsuleFile{
        .label = "payload",
        .sha256 = identity,
    };
    const bytes = try loadCapsuleFileAlloc(allocator, valid, 64);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("bound", bytes);

    try tmp.dir.rename(
        ".perf-local",
        tmp.dir,
        "external-perf-local",
        io,
    );
    try tmp.dir.symLink(
        io,
        "external-perf-local",
        ".perf-local",
        .{ .is_directory = true },
    );
    try std.testing.expectError(
        error.PerfEvidencePathOutsideCapsule,
        loadCapsuleFileAlloc(allocator, valid, 64),
    );
    try tmp.dir.deleteFile(io, ".perf-local");
    try tmp.dir.rename(
        "external-perf-local",
        tmp.dir,
        ".perf-local",
        io,
    );

    try std.testing.expectError(
        error.PerfEvidencePathOutsideCapsule,
        loadCapsuleFileAlloc(
            allocator,
            .{ .label = "../payload", .sha256 = identity },
            64,
        ),
    );

    var symlinked = try sealEvidenceBytes(
        allocator,
        machine_dir,
        "payload",
        "external",
        0o600,
    );
    defer symlinked.deinit(allocator);
    const symlink_identity = try std.fmt.allocPrint(
        allocator,
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
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(external_dir);
    const external_path = try std.fs.path.join(
        allocator,
        &.{ external_dir, "payload" },
    );
    defer allocator.free(external_path);
    try writeEvidenceFileAtomic(
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
        .revision = active_seq_replay_driver_v1.revision,
        .tree = active_seq_replay_driver_v1.tree,
        .path = active_seq_replay_driver_v1.locator,
        .file = .{
            .label = "perf_hub.zig",
            .sha256 = "sha256:" ++ active_seq_replay_driver_v1.sha256,
        },
    };
    try validateDriverSourceMetadata(source);

    source.revision = legacy_generic_driver_v1.revision;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source.revision = active_seq_replay_driver_v1.revision;
    source.tree = legacy_generic_driver_v1.tree;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source.tree = active_seq_replay_driver_v1.tree;
    source.path = legacy_generic_driver_v1.locator;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
    source.path = active_seq_replay_driver_v1.locator;
    source.file.sha256 = "sha256:" ++ legacy_generic_driver_v1.sha256;
    try std.testing.expectError(
        error.PerfEvidenceIdentityMismatch,
        validateDriverSourceMetadata(source),
    );
}

test "sealed Seq replay driver source is capture-only and dependency-minimal" {
    const digest = sealedSeqReplayDriverDigest();
    try std.testing.expectEqualStrings(
        active_seq_replay_driver_v1.sha256,
        &digest,
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
            compiler_path,
            &approved_digest,
        ),
    );
}

test "report errors clearly when compare summary is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), alloc);
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(std.Io.Threaded.global_single_threaded.io(), tmp.dir);
    defer std.process.setCurrentPath(std.Io.Threaded.global_single_threaded.io(), cwd_before) catch {};

    const current_name = try currentMachineDirName(alloc);
    defer alloc.free(current_name);
    const reports_path = try std.fmt.allocPrint(alloc, ".perf-local/{s}/reports", .{current_name});
    defer alloc.free(reports_path);
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), reports_path);

    try std.testing.expectError(error.MissingCompareSummary, cmdReport(alloc));
}

test "unmatched comparison target preserves prior evidence artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        allocator,
    );
    defer allocator.free(cwd_before);
    try std.process.setCurrentDir(
        std.Io.Threaded.global_single_threaded.io(),
        tmp.dir,
    );
    defer std.process.setCurrentPath(
        std.Io.Threaded.global_single_threaded.io(),
        cwd_before,
    ) catch |err| {
        std.debug.panic("restore working directory: {s}", .{@errorName(err)});
    };

    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const reports_path = try std.fs.path.join(
        allocator,
        &.{ ".perf-local", machine_name, "reports" },
    );
    defer allocator.free(reports_path);
    try tmp.dir.createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
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
        std.Io.Threaded.global_single_threaded.io(),
        .{ .sub_path = locator_path, .data = sentinel },
    );
    try std.testing.expectError(
        error.NoMatchingPerfCases,
        cmdCompare(allocator, "definitely-no-such-case"),
    );
    const bytes = try tmp.dir.readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
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
    defer std.process.setCurrentPath(
        std.testing.io,
        cwd_before,
    ) catch |err| {
        std.debug.panic("restore working directory: {s}", .{@errorName(err)});
    };
    const machine_dir = try ensureCurrentMachineDir(allocator);
    defer allocator.free(machine_dir);
    try invalidateCurrentCapsule(allocator, machine_dir);
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
        std.Io.Threaded.global_single_threaded.io(),
        alloc,
    );
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(
        std.Io.Threaded.global_single_threaded.io(),
        tmp.dir,
    );
    defer std.process.setCurrentPath(
        std.Io.Threaded.global_single_threaded.io(),
        cwd_before,
    ) catch |err| {
        std.debug.panic("restore working directory: {s}", .{@errorName(err)});
    };

    const current_name = try currentMachineDirName(alloc);
    defer alloc.free(current_name);
    const reports_path = try std.fmt.allocPrint(
        alloc,
        ".perf-local/{s}/reports",
        .{current_name},
    );
    defer alloc.free(reports_path);
    try tmp.dir.createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        reports_path,
    );
    const machine_dir = std.fs.path.dirname(reports_path).?;
    var capsule = try sealEvidenceBytes(
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
        alloc,
        locator_path,
        locator.written(),
        0o600,
    );

    try std.testing.expectError(error.InvalidCompareSummary, cmdReport(alloc));
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
    defer std.process.setCurrentPath(
        std.testing.io,
        cwd_before,
    ) catch |err| {
        std.debug.panic(
            "restore working directory: {s}",
            .{@errorName(err)},
        );
    };

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
    var baseline_samples: std.ArrayList(u64) = .empty;
    var candidate_samples: std.ArrayList(u64) = .empty;
    var baseline_allocs: std.ArrayList(u64) = .empty;
    var candidate_allocs: std.ArrayList(u64) = .empty;
    var baseline_rss: std.ArrayList(u64) = .empty;
    var candidate_rss: std.ArrayList(u64) = .empty;
    const case_cfg = DeepCases[0];
    const sample_count = case_cfg.samples * paired_comparison_rounds;
    for (0..sample_count) |index| {
        try baseline_samples.append(alloc, 100);
        try candidate_samples.append(
            alloc,
            if (index < case_cfg.samples) 110 else 100,
        );
    }
    for (0..paired_comparison_rounds) |_| {
        try baseline_allocs.append(alloc, 100);
        try candidate_allocs.append(alloc, 100);
        try baseline_rss.append(alloc, 100);
        try candidate_rss.append(alloc, 100);
    }
    var baseline = try metricsFromSamples(
        alloc,
        baseline_samples,
        baseline_allocs,
        baseline_rss,
    );
    defer baseline.deinit(alloc);
    var candidate = try metricsFromSamples(
        alloc,
        candidate_samples,
        candidate_allocs,
        candidate_rss,
    );
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

test "rss tolerance rounds only to the observable page quantum" {
    const allowed = try observableRssUpperBound(2_637_824, 2.0);
    try std.testing.expect(allowed >= 2_690_581);
    const page_size: u64 = @intCast(C.sysconf(
        @intFromEnum(std.c._SC.PAGESIZE),
    ));
    try std.testing.expect(allowed - 2_690_581 < page_size);
}

test "shared deep artifact identity is exact" {
    const case_cfg = DeepCases[0];
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
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
    try std.testing.expectError(
        error.DeepArtifactIdentityMismatch,
        validateSharedDriverArtifact(
            parsed.value,
            case_cfg,
            product_source_sha,
        ),
    );
    parsed.value.object.getPtr("git_sha").?.* = .{ .string = "unknown" };
    parsed.value.object.getPtr("case_id").?.* = .{ .string = "other" };
    try std.testing.expectError(
        error.DeepArtifactIdentityMismatch,
        validateSharedDriverArtifact(
            parsed.value,
            case_cfg,
            product_source_sha,
        ),
    );
    parsed.value.object.getPtr("case_id").?.* = .{
        .string = case_cfg.descriptor.case_id,
    };
    parsed.value.object.getPtr("binary").?.* = .{ .string = "other" };
    try std.testing.expectError(
        error.DeepArtifactIdentityMismatch,
        validateSharedDriverArtifact(
            parsed.value,
            case_cfg,
            product_source_sha,
        ),
    );
    parsed.value.object.getPtr("binary").?.* = .{
        .string = case_cfg.descriptor.binary,
    };
    parsed.value.object.getPtr("schema_version").?.* = .{ .integer = 2 };
    try std.testing.expectError(
        error.DeepArtifactIdentityMismatch,
        validateSharedDriverArtifact(
            parsed.value,
            case_cfg,
            product_source_sha,
        ),
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
        const rendered = try std.fmt.allocPrint(
            allocator,
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
    const wrong_rendered = try std.fmt.allocPrint(
        allocator,
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
        .path = try std.testing.allocator.dupeZ(u8, real_path),
        .sha256 = try sha256File(real_path),
    };
    defer file.deinit(std.testing.allocator);
    try verifySealedFile(file);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "perf_hub",
        .data = "second",
    });
    try std.testing.expectError(
        error.PerfEvidenceDigestMismatch,
        verifySealedFile(file),
    );
}

test "temp-root release deletes storage before freeing its path" {
    const root = try makeTempRoot(std.testing.allocator, "release-order");
    const observed_root = try std.testing.allocator.dupe(u8, root);
    defer std.testing.allocator.free(observed_root);
    releaseTempRoot(std.testing.allocator, root, false);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, observed_root, .{}),
    );
}

test "compiler evidence retains sentinel path ownership" {
    const allocator = std.testing.allocator;
    const approved_path = try allocator.dupeZ(u8, "/tmp/zig");
    errdefer allocator.free(approved_path);
    const file_path = try allocator.dupeZ(u8, "/tmp/sealed-zig");
    errdefer allocator.free(file_path);
    const version = try allocator.dupe(u8, "0.16.0");
    var evidence = CompilerEvidence{
        .approved_path = approved_path,
        .file = .{ .path = file_path, .sha256 = undefined },
        .version = version,
    };
    evidence.deinit(allocator);
}

test "inferBinary maps lift driver case to bench_stats" {
    try std.testing.expectEqualStrings("bench_stats", inferBinary("lift-bench-stats-driver"));
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
        SeqCases.len,
        matchingCaseCount("seq"),
    );
    try std.testing.expectEqual(
        LedgerCases.len,
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
    const prior = process_environment;
    defer process_environment = prior;
    process_environment = null;
    try std.testing.expect(!comparisonSummaryComplete(
        "cutover",
        SeqCases.len + LedgerCases.len,
        &rows,
    ));
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PERF_EXPECT_BASE_SHA", "base");
    try environment.put("PERF_EXPECT_CANDIDATE_SHA", "candidate");
    process_environment = &environment;
    try std.testing.expect(comparisonSummaryComplete(
        "cutover",
        SeqCases.len + LedgerCases.len,
        &rows,
    ));
    rows[0].tuple_bound = false;
    try std.testing.expect(!comparisonSummaryComplete(
        "cutover",
        SeqCases.len + LedgerCases.len,
        &rows,
    ));
}

test "paired baseline path outranks candidate environment override" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PERF_LEDGER_BINARY", "/candidate/ledger");
    const prior = process_environment;
    defer process_environment = prior;
    process_environment = &environment;
    var baseline_case = CompatCases[4];
    baseline_case.binary_path = "/base/ledger";
    const resolved = try resolveBinaryPath(
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
