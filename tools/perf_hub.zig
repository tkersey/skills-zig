const std = @import("std");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const core_perf = @import("core_perf");
const cron_cli = @import("cron_cli");
const definition_core = @import("definition_core");
const perf_contract = @import("perf_contract");
const seq_v1 = @import("seq_v1_core");

const Version = "0.0.0-dev";
const paired_comparison_rounds: usize = 4;
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
    \\  capture               Run native preserved-matrix baseline capture
    \\  compare               Run native preserved-matrix comparison
    \\  doctor                Validate native local perf setup
    \\  report                Summarize the last native compare artifact and emit cutover status
    \\  accept                Snapshot current baselines into an accepted ledger
    \\
    \\Options:
    \\  --target TEXT         Filter by binary/case substring where supported
    \\  --help                Show help
    \\  --version             Show version
    \\  version               Show version
    \\
    \\Base-binary overrides:
    \\  PERF_SEQ_BINARY       Use this Seq binary for capture or comparison
    \\  PERF_LEDGER_BINARY    Use this Ledger binary for capture or comparison
    \\  PERF_SEQ_BASE_BINARY  Pair this Seq base binary with the candidate
    \\  PERF_LEDGER_BASE_BINARY
    \\                        Pair this Ledger base binary with the candidate
    \\  PERF_EXPECT_BASE_SHA  Required source SHA for a paired baseline
    \\  PERF_EXPECT_CANDIDATE_SHA
    \\                        Required source SHA for the paired candidate
;

const Command = enum {
    list,
    manifest,
    audit,
    capture,
    compare,
    doctor,
    report,
    accept,
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
    cron_help,
    cron_list,
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
    cron_show,
    cron_create,
    cron_update,
    cron_enable,
    cron_disable,
    cron_run_now,
    cron_delete,
    cron_run_due,
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

const CronCases = [_]perf_contract.CaseDescriptor{
    .{ .case_id = "cron-help", .binary = "cron", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cron-list", .binary = "cron", .family = "list", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cron-show-deep", .binary = "cron", .family = "show", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-create-deep", .binary = "cron", .family = "create", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-update-deep", .binary = "cron", .family = "update", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-enable-deep", .binary = "cron", .family = "enable", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-disable-deep", .binary = "cron", .family = "disable", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-run-now-deep", .binary = "cron", .family = "run-now", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-delete-deep", .binary = "cron", .family = "delete", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-run-due-deep", .binary = "cron", .family = "run-due", .case_kind = .driver, .measurement_mode = .latency_alloc },
};

const CronCoverages = buildCronCoverages();

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
    .{ .descriptor = CronCases[0], .builder = .root, .build_step = "build-cron", .binary_path = "zig-out/bin/cron", .setup = .cron_help, .tolerance_pct = 25.0 },
    .{ .descriptor = CronCases[1], .builder = .root, .build_step = "build-cron", .binary_path = "zig-out/bin/cron", .setup = .cron_list, .tolerance_pct = 35.0 },
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
    .{ .descriptor = CronCases[2], .setup = .cron_show, .tolerance_pct = 200.0 },
    .{ .descriptor = CronCases[3], .setup = .cron_create, .tolerance_pct = 25.0 },
    .{ .descriptor = CronCases[4], .setup = .cron_update, .tolerance_pct = 25.0 },
    .{ .descriptor = CronCases[5], .setup = .cron_enable, .tolerance_pct = 250.0 },
    .{ .descriptor = CronCases[6], .setup = .cron_disable, .tolerance_pct = 100.0 },
    .{ .descriptor = CronCases[7], .setup = .cron_run_now, .tolerance_pct = 70.0 },
    .{ .descriptor = CronCases[8], .setup = .cron_delete, .tolerance_pct = 60.0 },
    .{ .descriptor = CronCases[9], .setup = .cron_run_due, .tolerance_pct = 125.0 },
};

fn buildCronCoverages() [cron_cli.commandDefinitions().len]perf_contract.CommandCoverage {
    var out: [cron_cli.commandDefinitions().len]perf_contract.CommandCoverage = undefined;
    for (cron_cli.commandDefinitions(), 0..) |def, idx| {
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
        .{ .binary = "cron", .coverages = &CronCoverages, .cases = &CronCases },
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
        .capture => try cmdCapture(allocator, parsed.target),
        .compare => try cmdCompare(allocator, parsed.target),
        .doctor => try cmdDoctor(allocator, parsed.target),
        .report => try cmdReport(allocator),
        .accept => try cmdAccept(allocator),
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
    return .{ .command = command, .target = target };
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "list")) return .list;
    if (std.mem.eql(u8, raw, "manifest")) return .manifest;
    if (std.mem.eql(u8, raw, "audit")) return .audit;
    if (std.mem.eql(u8, raw, "capture")) return .capture;
    if (std.mem.eql(u8, raw, "compare")) return .compare;
    if (std.mem.eql(u8, raw, "doctor")) return .doctor;
    if (std.mem.eql(u8, raw, "report")) return .report;
    if (std.mem.eql(u8, raw, "accept")) return .accept;
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

const BuiltState = struct {
    keys: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) BuiltState {
        return .{ .keys = std.StringHashMap(void).init(allocator) };
    }

    fn deinit(self: *BuiltState) void {
        var it = self.keys.keyIterator();
        while (it.next()) |key| self.keys.allocator.free(key.*);
        self.keys.deinit();
    }
};

const CommandRun = struct {
    cwd: []const u8,
    argv: []const []const u8,
};

const Metrics = struct {
    samples: std.ArrayList(u64),
    alloc_samples: std.ArrayList(u64),
    p50_ns: u64,
    p95_ns: u64,
    p50_alloc_calls: u64,

    fn deinit(self: *Metrics, allocator: std.mem.Allocator) void {
        self.samples.deinit(allocator);
        self.alloc_samples.deinit(allocator);
    }
};

const CompareRow = struct {
    status: []const u8,
    case_id: []const u8,
    binary: []const u8,
    detail: []const u8,
    tuple_bound: bool = false,
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

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("machine_id={s}\n", .{machine_name});
    try stdout.print("cases={d}\n", .{count});
    try stdout.print("machine_dir={s}\n", .{current_dir});
}

fn cmdCapture(allocator: std.mem.Allocator, target: ?[]const u8) !void {
    const machine_dir = try ensureCurrentMachineDir(allocator);
    defer allocator.free(machine_dir);
    var built = BuiltState.init(allocator);
    defer built.deinit();

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        try ensureBuilt(allocator, &built, case_cfg);
        const detail = try captureCompatCase(allocator, machine_dir, case_cfg);
        try stdout.print("PASS\t{s}\t{s}\n", .{ case_cfg.descriptor.case_id, detail });
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        const detail = try captureDeepCase(allocator, machine_dir, case_cfg);
        try stdout.print("PASS\t{s}\t{s}\n", .{ case_cfg.descriptor.case_id, detail });
    }
}

fn cmdCompare(allocator: std.mem.Allocator, target: ?[]const u8) !void {
    const machine_dir = try ensureCurrentMachineDir(allocator);
    defer allocator.free(machine_dir);
    try invalidateCompareSummary(allocator, machine_dir);
    var built = BuiltState.init(allocator);
    defer built.deinit();

    var rows: std.ArrayList(CompareRow) = .empty;
    defer rows.deinit(allocator);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    var any_fail = false;

    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        try ensureBuilt(allocator, &built, case_cfg);
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

    const expected_rows = expectedComparisonCount(target);
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

fn invalidateCompareSummary(
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
) !void {
    const latest_path = try std.fs.path.join(
        allocator,
        &.{ machine_dir, "reports", "latest-compare.json" },
    );
    defer allocator.free(latest_path);
    std.Io.Dir.cwd().deleteFile(
        std.Io.Threaded.global_single_threaded.io(),
        latest_path,
    ) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn comparisonStatusFailed(status: []const u8) bool {
    return !std.mem.eql(u8, status, "PASS");
}

fn expectedComparisonCount(target: ?[]const u8) ?usize {
    const selected = target orelse return null;
    if (std.mem.eql(u8, selected, "seq")) return SeqCases.len;
    if (std.mem.eql(u8, selected, "ledger")) return LedgerCases.len;
    if (std.mem.eql(u8, selected, "cutover")) {
        return SeqCases.len + LedgerCases.len;
    }
    return null;
}

fn captureCompatCase(allocator: std.mem.Allocator, machine_dir: []const u8, case_cfg: CompatCase) ![]const u8 {
    switch (case_cfg.descriptor.case_kind) {
        .driver => {
            const raw_json = try runDriverCase(allocator, case_cfg, true, null);
            defer allocator.free(raw_json);
            const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
            defer allocator.free(baseline_path);
            try writeDriverArtifact(allocator, baseline_path, case_cfg, raw_json, "capture", "captured");
        },
        .subprocess, .native => {
            var metrics = try runMeasuredCase(allocator, case_cfg);
            defer metrics.deinit(allocator);
            const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
            defer allocator.free(baseline_path);
            try writeMetricsArtifact(allocator, baseline_path, case_cfg, metrics, "capture", "captured");
        },
    }
    return "captured";
}

fn captureDeepCase(allocator: std.mem.Allocator, machine_dir: []const u8, case_cfg: DeepCase) ![]const u8 {
    var metrics = try runDeepMeasuredCase(allocator, case_cfg);
    defer metrics.deinit(allocator);
    const baseline_path = try compatBaselinePath(
        allocator,
        machine_dir,
        case_cfg.descriptor.binary,
        case_cfg.descriptor.case_id,
        false,
    );
    defer allocator.free(baseline_path);
    try writeMetricsArtifact(allocator, baseline_path, .{
        .descriptor = case_cfg.descriptor,
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .warmups = case_cfg.warmups,
        .samples = case_cfg.samples,
        .tolerance_pct = case_cfg.tolerance_pct,
    }, metrics, "capture", "captured");
    return "captured";
}

fn compareCompatCase(
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    case_cfg: CompatCase,
    built: *BuiltState,
) !CompareRow {
    const baseline_path = try compatBaselinePath(
        allocator,
        machine_dir,
        case_cfg.descriptor.binary,
        case_cfg.descriptor.case_id,
        false,
    );
    defer allocator.free(baseline_path);
    const latest_path = try compatBaselinePath(
        allocator,
        machine_dir,
        case_cfg.descriptor.binary,
        case_cfg.descriptor.case_id,
        true,
    );
    defer allocator.free(latest_path);
    if (baseBinaryOverride(case_cfg)) |base_binary| {
        if (case_cfg.descriptor.case_kind == .subprocess or
            case_cfg.descriptor.case_kind == .native)
        {
            const base_exec = try absolutePathForCwdRelative(
                allocator,
                base_binary,
            );
            defer allocator.free(base_exec);
            var base_case = case_cfg;
            base_case.binary_path = base_exec;
            base_case.require_streamed_projection = false;
            try ensureOverrideBuilt(
                allocator,
                built,
                base_case,
            );
            var baseline_evidence = try binaryEvidence(
                allocator,
                base_case,
            );
            defer baseline_evidence.deinit(allocator);
            var candidate_evidence = try binaryEvidence(
                allocator,
                case_cfg,
            );
            defer candidate_evidence.deinit(allocator);
            try requireExpectedPairedSources(
                baseline_evidence,
                candidate_evidence,
            );
            if (std.mem.eql(
                u8,
                &baseline_evidence.sha256,
                &candidate_evidence.sha256,
            )) {
                return .{
                    .status = "FAIL",
                    .case_id = case_cfg.descriptor.case_id,
                    .binary = case_cfg.descriptor.binary,
                    .detail = "base and candidate binaries are byte-identical",
                    .tuple_bound = true,
                };
            }
            if (isPreCutoverBinary(baseline_evidence.version) and
                !preCutoverCaseCompatible(case_cfg.setup))
            {
                try writeIncompatiblePairedArtifact(
                    allocator,
                    latest_path,
                    case_cfg,
                    baseline_evidence,
                    candidate_evidence,
                );
                return .{
                    .status = "INCOMPATIBLE",
                    .case_id = case_cfg.descriptor.case_id,
                    .binary = case_cfg.descriptor.binary,
                    .detail = "incompatible-base-surface",
                    .tuple_bound = true,
                };
            }
            var paired = try runPairedMeasuredCases(
                allocator,
                base_case,
                case_cfg,
            );
            defer paired.deinit(allocator);
            const compare = try compareMeasuredMetrics(
                case_cfg,
                paired.baseline,
                paired.candidate,
            );
            var evidence_case = case_cfg;
            evidence_case.samples = paired.candidate.samples.items.len;
            try writePairedMetricsArtifact(
                allocator,
                latest_path,
                evidence_case,
                baseline_evidence,
                candidate_evidence,
                paired.baseline,
                paired.candidate,
                paired.workload_digest,
                paired.baseline_execution,
                paired.candidate_execution,
                if (std.mem.eql(u8, compare.status, "PASS"))
                    "pass"
                else
                    "fail",
                compare.detail,
            );
            return .{
                .status = compare.status,
                .case_id = case_cfg.descriptor.case_id,
                .binary = case_cfg.descriptor.binary,
                .detail = compare.detail,
                .tuple_bound = true,
            };
        }
    }
    if (!pathExists(baseline_path)) {
        return .{ .status = "FAIL", .case_id = case_cfg.descriptor.case_id, .binary = case_cfg.descriptor.binary, .detail = "missing baseline" };
    }

    const baseline_data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), baseline_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(baseline_data);
    var baseline = try std.json.parseFromSlice(std.json.Value, allocator, baseline_data, .{});
    defer baseline.deinit();

    var status: []const u8 = "PASS";
    var detail: []const u8 = "ok";
    switch (case_cfg.descriptor.case_kind) {
        .driver => {
            const current_raw = try runDriverCase(allocator, case_cfg, false, null);
            defer allocator.free(current_raw);
            const compare = try compareDriverRaw(allocator, case_cfg, baseline.value, current_raw);
            status = compare.status;
            detail = compare.detail;
            try writeDriverArtifact(allocator, latest_path, case_cfg, current_raw, if (std.mem.eql(u8, status, "PASS")) "pass" else "fail", detail);
        },
        .subprocess, .native => {
            var metrics = try runMeasuredCase(allocator, case_cfg);
            defer metrics.deinit(allocator);
            const compare = try compareLatencyMetrics(case_cfg, baseline.value, metrics);
            status = compare.status;
            detail = compare.detail;
            try writeMetricsArtifact(allocator, latest_path, case_cfg, metrics, if (std.mem.eql(u8, status, "PASS")) "pass" else "fail", detail);
        },
    }

    return .{
        .status = status,
        .case_id = case_cfg.descriptor.case_id,
        .binary = case_cfg.descriptor.binary,
        .detail = detail,
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
    machine_dir: []const u8,
    case_cfg: DeepCase,
    built: *BuiltState,
) !CompareRow {
    if (std.mem.eql(u8, case_cfg.descriptor.binary, "seq")) {
        var compat_case = rootCompat(
            case_cfg.descriptor,
            "build-seq",
            "zig-out/bin/seq",
            .seq_observe,
        );
        compat_case.warmups = case_cfg.warmups;
        compat_case.samples = case_cfg.samples;
        compat_case.tolerance_pct = case_cfg.tolerance_pct;
        try ensureBuilt(allocator, built, compat_case);
        if (baseBinaryOverride(compat_case)) |base_binary| {
            const base_exec = try absolutePathForCwdRelative(
                allocator,
                base_binary,
            );
            defer allocator.free(base_exec);
            var base_case = compat_case;
            base_case.binary_path = base_exec;
            try ensureOverrideBuilt(allocator, built, base_case);
            var baseline_evidence = try binaryEvidence(
                allocator,
                base_case,
            );
            defer baseline_evidence.deinit(allocator);
            var candidate_evidence = try binaryEvidence(
                allocator,
                compat_case,
            );
            defer candidate_evidence.deinit(allocator);
            try requireExpectedPairedSources(
                baseline_evidence,
                candidate_evidence,
            );
            if (isPreCutoverBinary(baseline_evidence.version)) {
                const latest_path = try compatBaselinePath(
                    allocator,
                    machine_dir,
                    case_cfg.descriptor.binary,
                    case_cfg.descriptor.case_id,
                    true,
                );
                defer allocator.free(latest_path);
                try writeIncompatiblePairedArtifact(
                    allocator,
                    latest_path,
                    compat_case,
                    baseline_evidence,
                    candidate_evidence,
                );
                return .{
                    .status = "INCOMPATIBLE",
                    .case_id = case_cfg.descriptor.case_id,
                    .binary = case_cfg.descriptor.binary,
                    .detail = "incompatible-base-surface",
                    .tuple_bound = true,
                };
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
            const compare = try compareMeasuredMetrics(
                comparison_case,
                paired.baseline,
                paired.candidate,
            );
            const latest_path = try compatBaselinePath(
                allocator,
                machine_dir,
                case_cfg.descriptor.binary,
                case_cfg.descriptor.case_id,
                true,
            );
            defer allocator.free(latest_path);
            try writePairedMetricsArtifact(
                allocator,
                latest_path,
                comparison_case,
                baseline_evidence,
                candidate_evidence,
                paired.baseline,
                paired.candidate,
                paired.workload_digest,
                paired.baseline_execution,
                paired.candidate_execution,
                if (std.mem.eql(u8, compare.status, "PASS"))
                    "pass"
                else
                    "fail",
                compare.detail,
            );
            return .{
                .status = compare.status,
                .case_id = case_cfg.descriptor.case_id,
                .binary = case_cfg.descriptor.binary,
                .detail = compare.detail,
                .tuple_bound = true,
            };
        }
    }
    const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
    defer allocator.free(baseline_path);
    if (!pathExists(baseline_path)) {
        return .{ .status = "FAIL", .case_id = case_cfg.descriptor.case_id, .binary = case_cfg.descriptor.binary, .detail = "missing baseline" };
    }
    const baseline_data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), baseline_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(baseline_data);
    var baseline = try std.json.parseFromSlice(std.json.Value, allocator, baseline_data, .{});
    defer baseline.deinit();

    var metrics = try runDeepMeasuredCase(allocator, case_cfg);
    defer metrics.deinit(allocator);
    const comparison_case: CompatCase = .{
        .descriptor = case_cfg.descriptor,
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .warmups = case_cfg.warmups,
        .samples = case_cfg.samples,
        .tolerance_pct = case_cfg.tolerance_pct,
    };
    const compare = try compareLatencyMetrics(
        comparison_case,
        baseline.value,
        metrics,
    );

    const latest_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, true);
    defer allocator.free(latest_path);
    try writeMetricsArtifact(
        allocator,
        latest_path,
        comparison_case,
        metrics,
        if (std.mem.eql(u8, compare.status, "PASS")) "pass" else "fail",
        compare.detail,
    );

    return .{
        .status = compare.status,
        .case_id = case_cfg.descriptor.case_id,
        .binary = case_cfg.descriptor.binary,
        .detail = compare.detail,
    };
}

fn writeCompareSummaryRows(
    allocator: std.mem.Allocator,
    machine_dir: []const u8,
    target: ?[]const u8,
    expected_rows: ?usize,
    rows: []const CompareRow,
) !void {
    const reports_dir = try std.fs.path.join(allocator, &.{ machine_dir, "reports" });
    defer allocator.free(reports_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), reports_dir);
    const latest_path = try std.fs.path.join(allocator, &.{ reports_dir, "latest-compare.json" });
    defer allocator.free(latest_path);

    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), latest_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try writer.interface.writeAll("{\"target\":");
    if (target) |selected| {
        try std.json.Stringify.value(selected, .{}, &writer.interface);
    } else {
        try writer.interface.writeAll("null");
    }
    try writer.interface.writeAll(",\"expected_base_sha\":");
    const environment = process_environment;
    if (environment) |values| {
        if (values.get("PERF_EXPECT_BASE_SHA")) |sha| {
            try std.json.Stringify.value(sha, .{}, &writer.interface);
        } else {
            try writer.interface.writeAll("null");
        }
    } else {
        try writer.interface.writeAll("null");
    }
    try writer.interface.writeAll(",\"expected_candidate_sha\":");
    if (environment) |values| {
        if (values.get("PERF_EXPECT_CANDIDATE_SHA")) |sha| {
            try std.json.Stringify.value(sha, .{}, &writer.interface);
        } else {
            try writer.interface.writeAll("null");
        }
    } else {
        try writer.interface.writeAll("null");
    }
    try writer.interface.writeAll(",\"expected_rows\":");
    if (expected_rows) |count| {
        try writer.interface.print("{d}", .{count});
    } else {
        try writer.interface.writeAll("null");
    }
    try writer.interface.writeAll(",\"complete\":");
    try writer.interface.writeAll(if (comparisonSummaryComplete(
        target,
        expected_rows,
        rows,
    )) "true" else "false");
    try writer.interface.writeAll(",\"rows\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.interface.writeByte(',');
        try writer.interface.print(
            "{{\"case_id\":\"{s}\",\"binary\":\"{s}\"," ++
                "\"status\":\"{s}\",\"tuple_bound\":{}," ++
                "\"detail\":",
            .{ row.case_id, row.binary, row.status, row.tuple_bound },
        );
        try std.json.Stringify.value(row.detail, .{}, &writer.interface);
        try writer.interface.writeByte('}');
    }
    try writer.interface.writeAll("]}\n");
}

fn comparisonSummaryComplete(
    target: ?[]const u8,
    expected_rows: ?usize,
    rows: []const CompareRow,
) bool {
    const expected = expected_rows orelse return true;
    if (expected != rows.len) return false;
    const selected = target orelse return false;
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
    const baseline_dir = try std.fs.path.join(allocator, &.{ dir_path, "baselines" });
    defer allocator.free(baseline_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), baseline_dir);
    return dir_path;
}

fn ensureBuilt(allocator: std.mem.Allocator, built: *BuiltState, case_cfg: CompatCase) !void {
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{
        "root",
        case_cfg.build_step orelse "default",
    });
    defer allocator.free(key);
    if (!built.keys.contains(key)) {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(allocator);
        try args.append(allocator, "zig");
        try args.append(allocator, "build");
        if (case_cfg.build_step) |step| try args.append(allocator, step);
        try args.append(allocator, "-Doptimize=ReleaseFast");
        const result = try runChildCapture(allocator, ".", args.items);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.exit_code != 0) return error.BuildFailed;
        try built.keys.put(try allocator.dupe(u8, key), {});
    }
    const source_root = try std.process.currentPathAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        allocator,
    );
    defer allocator.free(source_root);
    try requireCanonicalBuildOutput(
        allocator,
        source_root,
        case_cfg,
    );
}

fn ensureOverrideBuilt(
    allocator: std.mem.Allocator,
    built: *BuiltState,
    case_cfg: CompatCase,
) !void {
    const binary_path = try resolveBinaryExecPath(allocator, case_cfg);
    defer allocator.free(binary_path);
    const source_root = try sourceRootForBinaryAlloc(
        allocator,
        binary_path,
    );
    defer allocator.free(source_root);
    try requireCleanSourceRoot(allocator, source_root);
    const key = try std.fmt.allocPrint(
        allocator,
        "{s}:{s}",
        .{ source_root, case_cfg.build_step orelse "default" },
    );
    defer allocator.free(key);
    if (!built.keys.contains(key)) {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(allocator);
        try args.appendSlice(allocator, &.{ "zig", "build" });
        if (case_cfg.build_step) |step| try args.append(allocator, step);
        try args.append(allocator, "-Doptimize=ReleaseFast");
        const result = try runChildCapture(
            allocator,
            source_root,
            args.items,
        );
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.exit_code != 0) return error.BuildFailed;
        try built.keys.put(try allocator.dupe(u8, key), {});
    }
    try requireCanonicalBuildOutput(allocator, source_root, case_cfg);
}

fn requireCanonicalBuildOutput(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    case_cfg: CompatCase,
) !void {
    const canonical_output = try canonicalBuildOutputPathAlloc(
        allocator,
        source_root,
        case_cfg.descriptor.binary,
    );
    defer allocator.free(canonical_output);
    const binary_path = try resolveBinaryExecPath(allocator, case_cfg);
    defer allocator.free(binary_path);
    const supplied_real = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        binary_path,
        allocator,
    );
    defer allocator.free(supplied_real);
    const canonical_real = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        canonical_output,
        allocator,
    );
    defer allocator.free(canonical_real);
    if (!std.mem.eql(u8, supplied_real, canonical_real)) {
        return error.BinaryBuildOutputMismatch;
    }
}

fn canonicalBuildOutputPathAlloc(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    binary: []const u8,
) ![]u8 {
    return std.fs.path.join(
        allocator,
        &.{ source_root, "zig-out", "bin", binary },
    );
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

fn compatBaselinePath(allocator: std.mem.Allocator, machine_dir: []const u8, binary: []const u8, case_id: []const u8, latest: bool) ![]u8 {
    const dir_path = try std.fs.path.join(allocator, &.{ machine_dir, "baselines", binary });
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir_path);
    allocator.free(dir_path);
    const file_name = if (latest)
        try std.fmt.allocPrint(allocator, "{s}.latest.json", .{case_id})
    else
        try std.fmt.allocPrint(allocator, "{s}.json", .{case_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ machine_dir, "baselines", binary, file_name });
}

fn runDriverCase(allocator: std.mem.Allocator, case_cfg: CompatCase, capture: bool, _: ?std.json.Value) ![]u8 {
    const temp_root = try makeTempRoot(allocator, case_cfg.descriptor.case_id);
    defer cleanupTempRoot(temp_root);
    defer allocator.free(temp_root);
    const artifact_path = try std.fs.path.join(allocator, &.{ temp_root, "artifact.json" });
    defer allocator.free(artifact_path);
    const binary_path = try resolveBinaryPath(allocator, case_cfg);
    defer allocator.free(binary_path);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, binary_path);
    switch (case_cfg.setup) {
        .lift_bench_stats_driver => {
            try args.appendSlice(allocator, &.{ "--config", "apps/lift/perf/bench_stats/workload_config.json", "--artifact", artifact_path, "--report-only" });
            const result = try runChildCapture(allocator, ".", args.items);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.exit_code != 0) return error.DriverFailed;
        },
        .cas_budget_governor_driver => {
            try args.appendSlice(allocator, &.{ "--config", "apps/cas/perf/budget_governor/workload_config.json", "--artifact", artifact_path, "--report-only" });
            const result = try runChildCapture(allocator, ".", args.items);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.exit_code != 0) return error.DriverFailed;
        },
        else => return error.InvalidCommand,
    }
    _ = capture;
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), artifact_path, allocator, .limited(1024 * 1024));
}

fn runMeasuredCase(allocator: std.mem.Allocator, case_cfg: CompatCase) !Metrics {
    const temp_root = try makeTempRoot(allocator, case_cfg.descriptor.case_id);
    defer cleanupTempRoot(temp_root);
    defer allocator.free(temp_root);
    try prepareCompatCase(allocator, case_cfg, temp_root);
    if (case_cfg.require_streamed_projection) {
        _ = try measuredOutputEvidenceOnce(
            allocator,
            case_cfg,
            temp_root,
        );
    }
    var samples: std.ArrayList(u64) = .empty;
    var alloc_samples: std.ArrayList(u64) = .empty;
    try samples.ensureTotalCapacity(allocator, case_cfg.samples);
    try alloc_samples.ensureTotalCapacity(allocator, case_cfg.samples);

    var warmup_idx: usize = 0;
    while (warmup_idx < case_cfg.warmups) : (warmup_idx += 1) {
        var run_arena = std.heap.ArenaAllocator.init(allocator);
        defer run_arena.deinit();
        const run = try renderCompatRun(run_arena.allocator(), case_cfg, temp_root);
        const result = try runChildCapture(allocator, run.cwd, run.argv);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.exit_code != 0) {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try stderr_writer.interface.print("case warmup failed: {s} exit={d}\n{s}\n", .{
                case_cfg.descriptor.case_id,
                result.exit_code,
                result.stderr,
            });
            return error.CaseFailed;
        }
    }

    var sample_idx: usize = 0;
    while (sample_idx < case_cfg.samples) : (sample_idx += 1) {
        var run_arena = std.heap.ArenaAllocator.init(allocator);
        defer run_arena.deinit();
        const run = try renderCompatRun(run_arena.allocator(), case_cfg, temp_root);
        const start_ns = std.Io.Clock.awake.now(
            std.Io.Threaded.global_single_threaded.io(),
        ).nanoseconds;
        const result = try runChildCapture(allocator, run.cwd, run.argv);
        const elapsed: u64 = @intCast(@max(std.Io.Clock.awake.now(
            std.Io.Threaded.global_single_threaded.io(),
        ).nanoseconds - start_ns, 1));
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.exit_code != 0) {
            var stderr_writer = std.Io.File.stderr().writer(
                std.Io.Threaded.global_single_threaded.io(),
                &.{},
            );
            try stderr_writer.interface.print("case sample failed: {s} exit={d}\n{s}\n", .{
                case_cfg.descriptor.case_id,
                result.exit_code,
                result.stderr,
            });
            return error.CaseFailed;
        }
        try samples.append(allocator, elapsed);
        try alloc_samples.append(allocator, 0);
    }

    return .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .p50_ns = try percentileU64(allocator, samples.items, 50),
        .p95_ns = try percentileU64(allocator, samples.items, 95),
        .p50_alloc_calls = 0,
    };
}

const PairedMetrics = struct {
    baseline: Metrics,
    candidate: Metrics,
    workload_digest: [64]u8,
    baseline_execution: MeasuredOutputEvidence,
    candidate_execution: MeasuredOutputEvidence,

    fn deinit(self: *PairedMetrics, allocator: std.mem.Allocator) void {
        self.baseline.deinit(allocator);
        self.candidate.deinit(allocator);
        self.* = undefined;
    }
};

const MeasuredOutputEvidence = struct {
    output_sha256: [64]u8,
    streamed: ?bool = null,
    records_scanned: ?u64 = null,
    records_emitted: ?u64 = null,
};

const BinaryEvidence = struct {
    path: [:0]u8,
    sha256: [64]u8,
    version: []u8,
    source_sha: []u8,
    build_step: []const u8,

    fn deinit(self: *BinaryEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.version);
        allocator.free(self.source_sha);
        self.* = undefined;
    }
};

fn binaryEvidence(
    allocator: std.mem.Allocator,
    case_cfg: CompatCase,
) !BinaryEvidence {
    const resolved = try resolveBinaryExecPath(allocator, case_cfg);
    defer allocator.free(resolved);
    const path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        resolved,
        allocator,
    );
    errdefer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        allocator,
        .limited(16 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha256 = std.fmt.bytesToHex(digest, .lower);
    const source_root = try sourceRootForBinaryAlloc(allocator, path);
    defer allocator.free(source_root);
    try requireCleanSourceRoot(allocator, source_root);
    const source_sha = try sourceShaForRootAlloc(
        allocator,
        source_root,
    );
    errdefer allocator.free(source_sha);
    const result = try runChildCaptureOutput(
        allocator,
        ".",
        &.{ path, "version" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BinaryVersionFailed;
    return .{
        .path = path,
        .sha256 = sha256,
        .version = try allocator.dupe(
            u8,
            std.mem.trim(u8, result.stdout, " \t\r\n"),
        ),
        .source_sha = source_sha,
        .build_step = case_cfg.build_step orelse "default",
    };
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
            "git",
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
        &.{ "git", "-C", source_root, "rev-parse", "HEAD" },
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
    defer if (!retainPairedWorkloads()) cleanupTempRoot(baseline_root);
    defer allocator.free(baseline_root);
    const candidate_root = try makeTempRoot(
        allocator,
        "paired-candidate",
    );
    defer if (!retainPairedWorkloads()) cleanupTempRoot(candidate_root);
    defer allocator.free(candidate_root);
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
    var candidate_samples: std.ArrayList(u64) = .empty;
    errdefer candidate_samples.deinit(allocator);
    var candidate_allocs: std.ArrayList(u64) = .empty;
    errdefer candidate_allocs.deinit(allocator);
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
            );
            try appendCompatSample(
                allocator,
                candidate_case,
                candidate_root,
                &candidate_samples,
                &candidate_allocs,
            );
        } else {
            try appendCompatSample(
                allocator,
                candidate_case,
                candidate_root,
                &candidate_samples,
                &candidate_allocs,
            );
            try appendCompatSample(
                allocator,
                baseline_case,
                baseline_root,
                &baseline_samples,
                &baseline_allocs,
            );
        }
    }
    var baseline = try metricsFromSamples(
        allocator,
        baseline_samples,
        baseline_allocs,
    );
    baseline_samples = .empty;
    baseline_allocs = .empty;
    errdefer baseline.deinit(allocator);
    const candidate = try metricsFromSamples(
        allocator,
        candidate_samples,
        candidate_allocs,
    );
    candidate_samples = .empty;
    candidate_allocs = .empty;
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
    const baseline_root = try sourceRootForBinaryAlloc(
        allocator,
        baseline_evidence.path,
    );
    defer allocator.free(baseline_root);
    const candidate_root = try sourceRootForBinaryAlloc(
        allocator,
        candidate_evidence.path,
    );
    defer allocator.free(candidate_root);
    try ensureSourcePerfHubBuilt(allocator, built, baseline_root);
    try ensureSourcePerfHubBuilt(allocator, built, candidate_root);
    const baseline_workload = try deepWorkloadDigestForRoot(
        allocator,
        baseline_root,
        case_cfg,
    );
    const candidate_workload = try deepWorkloadDigestForRoot(
        allocator,
        candidate_root,
        case_cfg,
    );
    if (!std.mem.eql(u8, &baseline_workload, &candidate_workload)) {
        return error.PerfWorkloadMismatch;
    }

    var baseline_samples: std.ArrayList(u64) = .empty;
    errdefer baseline_samples.deinit(allocator);
    var baseline_allocs: std.ArrayList(u64) = .empty;
    errdefer baseline_allocs.deinit(allocator);
    var candidate_samples: std.ArrayList(u64) = .empty;
    errdefer candidate_samples.deinit(allocator);
    var candidate_allocs: std.ArrayList(u64) = .empty;
    errdefer candidate_allocs.deinit(allocator);
    const measured_samples = std.math.mul(
        usize,
        case_cfg.samples,
        paired_comparison_rounds,
    ) catch return error.PerfSampleCountOverflow;
    try baseline_samples.ensureTotalCapacity(allocator, measured_samples);
    try candidate_samples.ensureTotalCapacity(allocator, measured_samples);
    try candidate_allocs.ensureTotalCapacity(allocator, measured_samples);
    try baseline_allocs.ensureTotalCapacity(
        allocator,
        paired_comparison_rounds,
    );

    try primeSourceDeepCase(allocator, baseline_root, case_cfg);
    try primeSourceDeepCase(allocator, candidate_root, case_cfg);

    var round: usize = 0;
    while (round < paired_comparison_rounds) : (round += 1) {
        if (round % 2 == 0) {
            try appendSourceDeepMetrics(
                allocator,
                baseline_root,
                case_cfg,
                &baseline_samples,
                &baseline_allocs,
            );
            try appendSourceDeepMetrics(
                allocator,
                candidate_root,
                case_cfg,
                &candidate_samples,
                &candidate_allocs,
            );
        } else {
            try appendSourceDeepMetrics(
                allocator,
                candidate_root,
                case_cfg,
                &candidate_samples,
                &candidate_allocs,
            );
            try appendSourceDeepMetrics(
                allocator,
                baseline_root,
                case_cfg,
                &baseline_samples,
                &baseline_allocs,
            );
        }
    }
    var baseline = try metricsFromSamples(
        allocator,
        baseline_samples,
        baseline_allocs,
    );
    baseline_samples = .empty;
    baseline_allocs = .empty;
    errdefer baseline.deinit(allocator);
    const candidate = try metricsFromSamples(
        allocator,
        candidate_samples,
        candidate_allocs,
    );
    candidate_samples = .empty;
    candidate_allocs = .empty;
    return .{
        .baseline = baseline,
        .candidate = candidate,
        .workload_digest = baseline_workload,
        .baseline_execution = .{
            .output_sha256 = baseline_workload,
        },
        .candidate_execution = .{
            .output_sha256 = candidate_workload,
        },
    };
}

fn primeSourceDeepCase(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    case_cfg: DeepCase,
) !void {
    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(allocator);
    var alloc_samples: std.ArrayList(u64) = .empty;
    defer alloc_samples.deinit(allocator);
    try appendSourceDeepMetrics(
        allocator,
        source_root,
        case_cfg,
        &samples,
        &alloc_samples,
    );
}

fn ensureSourcePerfHubBuilt(
    allocator: std.mem.Allocator,
    built: *BuiltState,
    source_root: []const u8,
) !void {
    const key = try std.fmt.allocPrint(
        allocator,
        "{s}:perf-hub",
        .{source_root},
    );
    defer allocator.free(key);
    if (built.keys.contains(key)) return;
    const result = try runChildCapture(
        allocator,
        source_root,
        &.{ "zig", "build", "-Doptimize=ReleaseFast" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BuildFailed;
    const perf_hub_path = try canonicalBuildOutputPathAlloc(
        allocator,
        source_root,
        "perf_hub",
    );
    defer allocator.free(perf_hub_path);
    std.Io.Dir.cwd().access(
        std.Io.Threaded.global_single_threaded.io(),
        perf_hub_path,
        .{},
    ) catch
        return error.BuildFailed;
    try built.keys.put(try allocator.dupe(u8, key), {});
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
    samples: *std.ArrayList(u64),
    alloc_samples: *std.ArrayList(u64),
) !void {
    const perf_hub_path = try canonicalBuildOutputPathAlloc(
        allocator,
        source_root,
        "perf_hub",
    );
    defer allocator.free(perf_hub_path);
    const result = try runChildCapture(
        allocator,
        source_root,
        &.{
            perf_hub_path,
            "capture",
            "--target",
            case_cfg.descriptor.case_id,
        },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.CaseFailed;
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
    const metrics = parsed.value.object.get("metrics") orelse
        return error.InvalidData;
    const raw_samples = metrics.object.get("samples_ns") orelse
        return error.InvalidData;
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
    evidence.streamed = switch (stats.get("streamed") orelse
        return evidence) {
        .bool => |value| value,
        else => null,
    };
    evidence.records_scanned = jsonValueU64(
        stats.get("records_scanned") orelse return evidence,
        "records_scanned",
    ) catch null;
    evidence.records_emitted = jsonValueU64(
        stats.get("records_emitted") orelse return evidence,
        "records_emitted",
    ) catch null;
    return evidence;
}

fn metricsFromSamples(
    allocator: std.mem.Allocator,
    samples: std.ArrayList(u64),
    alloc_samples: std.ArrayList(u64),
) !Metrics {
    return .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .p50_ns = try percentileU64(allocator, samples.items, 50),
        .p95_ns = try percentileU64(allocator, samples.items, 95),
        .p50_alloc_calls = try percentileU64(
            allocator,
            alloc_samples.items,
            50,
        ),
    };
}

fn runDeepMeasuredCase(allocator: std.mem.Allocator, case_cfg: DeepCase) !Metrics {
    const temp_root = try makeTempRoot(allocator, case_cfg.descriptor.case_id);
    defer cleanupTempRoot(temp_root);
    defer allocator.free(temp_root);
    var samples: std.ArrayList(u64) = .empty;
    var alloc_samples: std.ArrayList(u64) = .empty;
    try samples.ensureTotalCapacity(allocator, case_cfg.samples);
    try alloc_samples.ensureTotalCapacity(allocator, case_cfg.samples);

    var warmup_idx: usize = 0;
    while (warmup_idx < case_cfg.warmups) : (warmup_idx += 1) {
        _ = try executeDeepBatchFresh(
            case_cfg,
            temp_root,
        );
    }

    var sample_idx: usize = 0;
    while (sample_idx < case_cfg.samples) : (sample_idx += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        const start_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
        try executeDeepBatch(
            counting.allocator(),
            case_cfg,
            temp_root,
        );
        try samples.append(allocator, @intCast(@max(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds - start_ns, 1)));
        try alloc_samples.append(
            allocator,
            counting.stats.totalCalls(),
        );
    }

    return .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .p50_ns = try percentileU64(allocator, samples.items, 50),
        .p95_ns = try percentileU64(allocator, samples.items, 95),
        .p50_alloc_calls = try percentileU64(allocator, alloc_samples.items, 50),
    };
}

fn executeDeepBatchFresh(
    case_cfg: DeepCase,
    temp_root: []const u8,
) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var counting = core_perf.CountingAllocator.init(arena.allocator());
    try executeDeepBatch(
        counting.allocator(),
        case_cfg,
        temp_root,
    );
    return counting.stats.totalCalls();
}

fn executeDeepBatch(
    allocator: std.mem.Allocator,
    case_cfg: DeepCase,
    temp_root: []const u8,
) !void {
    var index: usize = 0;
    while (index < case_cfg.batch_iterations) : (index += 1) {
        try executeDeepCase(allocator, case_cfg.setup, temp_root);
    }
}

fn executeDeepCase(allocator: std.mem.Allocator, setup: DeepSetup, temp_root: []const u8) !void {
    switch (setup) {
        .seq_observe => try executeSeqObserveDeep(allocator),
        .cron_show => try cron_cli.runPerfCase(allocator, .show, temp_root),
        .cron_create => try cron_cli.runPerfCase(allocator, .create, temp_root),
        .cron_update => try cron_cli.runPerfCase(allocator, .update, temp_root),
        .cron_enable => try cron_cli.runPerfCase(allocator, .enable, temp_root),
        .cron_disable => try cron_cli.runPerfCase(allocator, .disable, temp_root),
        .cron_run_now => try cron_cli.runPerfCase(allocator, .run_now, temp_root),
        .cron_delete => try cron_cli.runPerfCase(allocator, .delete, temp_root),
        .cron_run_due => try cron_cli.runPerfCase(allocator, .run_due, temp_root),
    }
}

fn executeSeqObserveDeep(allocator: std.mem.Allocator) !void {
    const cwd = try std.process.currentPathAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        allocator,
    );
    defer allocator.free(cwd);
    const definition_root = try std.fs.path.join(
        allocator,
        &.{ cwd, "apps/seq/src/v1/fixtures" },
    );
    defer allocator.free(definition_root);
    const projection_names = [_][]const u8{"rows"};
    var plans = try seq_v1.compiled_plan.load(
        allocator,
        definition_root,
        "message-observation.json",
        .{ .projection_names = &projection_names },
        "1.0.0",
        "seq-source-adapter/v1",
        .{},
    );
    defer plans.deinit(allocator);
    const parameter_inputs = [_]definition_core.parameters.Input{.{
        .name = "needle",
        .raw_value = "failure",
    }};
    var parameters = try definition_core.parameters.bind(
        allocator,
        &plans.definition_plan.parameter_declarations,
        &parameter_inputs,
    );
    defer parameters.deinit(allocator);
    var program = try seq_v1.execution.compile(
        allocator,
        &plans.definition_plan,
        &plans.native_plan,
        &parameters,
        "rows",
    );
    defer program.deinit(allocator);
    const output_cells = try std.math.mul(
        usize,
        program.max_rows,
        program.output_field_indices.len,
    );
    const output = try allocator.alloc(seq_v1.execution.Value, output_cells);
    defer allocator.free(output);
    const trace_path = try std.fs.path.join(
        allocator,
        &.{ definition_root, "rollout.jsonl" },
    );
    defer allocator.free(trace_path);
    var observation = try seq_v1.trace_adapter.observeFile(
        allocator,
        &program,
        trace_path,
        .{
            .max_input_bytes = plans.definition_plan.bounds.max_input_bytes,
        },
        output,
    );
    defer observation.deinit(allocator);
    if (observation.result.row_count != 1 or
        observation.metrics.bytes_read == 0)
    {
        return error.InvalidPerfObservation;
    }
}

fn compareLatencyMetrics(
    case_cfg: CompatCase,
    baseline: std.json.Value,
    metrics: Metrics,
) !StatusDetail {
    const root = baseline.object;
    const baseline_metrics = root.get("metrics") orelse return error.InvalidData;
    const metric_obj = baseline_metrics.object;
    if (case_cfg.descriptor.measurement_mode == .latency_alloc and
        baseline_metrics.object.get("p50_alloc_calls") == null)
    {
        return .{
            .status = "FAIL",
            .detail = "baseline missing allocation metrics; recapture baseline",
        };
    }
    const base_p50 = try jsonFieldU64(metric_obj, "p50_ns");
    const base_p95 = try jsonFieldU64(metric_obj, "p95_ns");
    const allowed_p50 = allowedUpperBoundWithTolerance(base_p50, case_cfg.tolerance_pct);
    const allowed_p95 = allowedUpperBoundWithTolerance(base_p95, case_cfg.tolerance_pct);
    if (metrics.p50_ns > allowed_p50) {
        return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(std.heap.page_allocator, "p50 {d} > {d}", .{ metrics.p50_ns, allowed_p50 }) };
    }
    if (metrics.p95_ns > allowed_p95) {
        return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(std.heap.page_allocator, "p95 {d} > {d}", .{ metrics.p95_ns, allowed_p95 }) };
    }
    if (case_cfg.descriptor.measurement_mode == .latency_alloc) {
        const base_alloc = try jsonFieldU64(metric_obj, "p50_alloc_calls");
        const allowed_alloc = allowedUpperBoundWithTolerance(base_alloc, case_cfg.tolerance_pct);
        if (metrics.p50_alloc_calls > allowed_alloc) {
            return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(std.heap.page_allocator, "p50_alloc_calls {d} > {d}", .{ metrics.p50_alloc_calls, allowed_alloc }) };
        }
    }
    return .{ .status = "PASS", .detail = "ok" };
}

fn compareMeasuredMetrics(
    case_cfg: CompatCase,
    baseline: Metrics,
    candidate: Metrics,
) !StatusDetail {
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

fn compareDriverRaw(allocator: std.mem.Allocator, case_cfg: CompatCase, baseline: std.json.Value, current_raw_json: []const u8) !StatusDetail {
    var current = try std.json.parseFromSlice(std.json.Value, allocator, current_raw_json, .{});
    defer current.deinit();
    const baseline_raw = baseline.object.get("raw_artifact") orelse return error.InvalidData;
    const current_raw = current.value;
    switch (case_cfg.setup) {
        .lift_bench_stats_driver => {
            if (try compareUpperBoundField(allocator, current_raw, baseline_raw, "p95_ns_per_line", case_cfg.tolerance_pct)) |detail| {
                return .{ .status = "FAIL", .detail = detail };
            }
            if (try compareUpperBoundField(allocator, current_raw, baseline_raw, "p50_alloc_calls_per_round", case_cfg.tolerance_pct)) |detail| {
                return .{ .status = "FAIL", .detail = detail };
            }
        },
        .cas_budget_governor_driver => {
            if (try compareUpperBoundField(allocator, current_raw, baseline_raw, "p95_ns_per_eval", case_cfg.tolerance_pct)) |detail| {
                return .{ .status = "FAIL", .detail = detail };
            }
            if (try compareUpperBoundField(allocator, current_raw, baseline_raw, "p50_alloc_calls_per_eval", case_cfg.tolerance_pct)) |detail| {
                return .{ .status = "FAIL", .detail = detail };
            }
        },
        else => return error.InvalidCommand,
    }
    return .{ .status = "PASS", .detail = "driver compare passed" };
}

fn compareUpperBoundField(allocator: std.mem.Allocator, current: std.json.Value, baseline: std.json.Value, field: []const u8, tolerance_pct: f64) !?[]const u8 {
    const current_value = try jsonObjectFieldU64(current, field);
    const baseline_value = try jsonObjectFieldU64(baseline, field);
    const allowed = allowedUpperBoundWithTolerance(baseline_value, tolerance_pct);
    if (current_value > allowed) {
        return try std.fmt.allocPrint(allocator, "{s} {d} > {d}", .{ field, current_value, allowed });
    }
    return null;
}

fn writeMetricsArtifact(allocator: std.mem.Allocator, path: []const u8, case_cfg: CompatCase, metrics: Metrics, compare_status: []const u8, compare_detail: []const u8) !void {
    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const sha = try gitShaAlloc(allocator);
    defer allocator.free(sha);
    try writer.print(
        "{{\"schema_version\":1,\"machine_id\":\"{s}\",\"git_sha\":\"{s}\",\"zig_version\":\"{s}\",\"binary\":\"{s}\",\"case_id\":\"{s}\",\"case_kind\":\"{s}\",\"tolerance_pct\":{d:.2},\"metrics\":{{\"samples_ns\":[",
        .{ machine_name, sha, builtin.zig_version_string, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, case_cfg.descriptor.case_kind.asString(), case_cfg.tolerance_pct },
    );
    for (metrics.samples.items, 0..) |sample, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{d}", .{sample});
    }
    try writer.print("],\"p50_ns\":{d},\"p95_ns\":{d}", .{ metrics.p50_ns, metrics.p95_ns });
    if (case_cfg.descriptor.measurement_mode == .latency_alloc) {
        try writer.print(",\"p50_alloc_calls\":{d}", .{metrics.p50_alloc_calls});
    }
    try writer.print("}},\"compare_status\":\"{s}\",\"compare_detail\":", .{compare_status});
    try writeJsonString(writer, compare_detail);
    try writer.writeAll("}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
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
    if (include_allocations) {
        try writer.print(
            ",\"p50_alloc_calls\":{d}",
            .{metrics.p50_alloc_calls},
        );
    }
    try writer.writeByte('}');
}

fn writeBinaryEvidence(
    writer: *std.Io.Writer,
    evidence: BinaryEvidence,
) !void {
    try writer.writeAll("{\"path\":");
    try writeJsonString(writer, evidence.path);
    try writer.writeAll(",\"sha256\":\"sha256:");
    try writer.writeAll(&evidence.sha256);
    try writer.writeAll("\",\"version\":");
    try writeJsonString(writer, evidence.version);
    try writer.writeAll(",\"source_sha\":");
    try writeJsonString(writer, evidence.source_sha);
    try writer.writeAll(",\"source_clean\":true,\"zig_version\":");
    try writeJsonString(writer, builtin.zig_version_string);
    try writer.writeAll(",\"optimize\":\"ReleaseFast\",\"build_step\":");
    try writeJsonString(writer, evidence.build_step);
    try writer.writeByte('}');
}

fn writePairedMetricsArtifact(
    allocator: std.mem.Allocator,
    path: []const u8,
    case_cfg: CompatCase,
    baseline_evidence: BinaryEvidence,
    candidate_evidence: BinaryEvidence,
    baseline: Metrics,
    candidate: Metrics,
    workload_digest: [64]u8,
    baseline_execution: MeasuredOutputEvidence,
    candidate_execution: MeasuredOutputEvidence,
    compare_status: []const u8,
    compare_detail: []const u8,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const git_sha = try gitShaAlloc(allocator);
    defer allocator.free(git_sha);
    try writer.print(
        "{{\"schema_version\":2,\"evidence_kind\":\"paired\"," ++
            "\"machine_id\":\"{s}\",\"git_sha\":\"{s}\"," ++
            "\"zig_version\":\"{s}\",\"binary\":\"{s}\"," ++
            "\"case_id\":\"{s}\",\"case_kind\":\"{s}\"," ++
            "\"warmups\":{d},\"samples\":{d},\"tolerance_pct\":{d:.2}," ++
            "\"workload\":{{\"setup\":\"{s}\",\"digest\":\"sha256:{s}\"," ++
            "\"ledger_seed_records\":{d}}},\"baseline\":{{\"binary\":",
        .{
            machine_name,
            git_sha,
            builtin.zig_version_string,
            case_cfg.descriptor.binary,
            case_cfg.descriptor.case_id,
            case_cfg.descriptor.case_kind.asString(),
            case_cfg.warmups,
            case_cfg.samples,
            case_cfg.tolerance_pct,
            @tagName(case_cfg.setup),
            workload_digest,
            if (case_cfg.setup == .ledger_transact or
                case_cfg.setup == .ledger_project or
                case_cfg.setup == .ledger_doctor)
                ledger_perf_record_count
            else
                0,
        },
    );
    try writeBinaryEvidence(writer, baseline_evidence);
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
    try std.Io.Dir.cwd().writeFile(
        std.Io.Threaded.global_single_threaded.io(),
        .{ .sub_path = path, .data = output.written() },
    );
}

fn writeMeasuredOutputEvidence(
    writer: *std.Io.Writer,
    evidence: MeasuredOutputEvidence,
) !void {
    try writer.writeAll("{\"output_sha256\":\"sha256:");
    try writer.writeAll(&evidence.output_sha256);
    try writer.writeAll("\",\"streamed\":");
    if (evidence.streamed) |value| {
        try writer.writeAll(if (value) "true" else "false");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"records_scanned\":");
    if (evidence.records_scanned) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"records_emitted\":");
    if (evidence.records_emitted) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeIncompatiblePairedArtifact(
    allocator: std.mem.Allocator,
    path: []const u8,
    case_cfg: CompatCase,
    baseline_evidence: BinaryEvidence,
    candidate_evidence: BinaryEvidence,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(
        "{\"schema_version\":2,\"evidence_kind\":" ++
            "\"paired-disposition\",\"disposition\":" ++
            "\"incompatible-base-surface\",\"case_id\":",
    );
    try writeJsonString(writer, case_cfg.descriptor.case_id);
    try writer.writeAll(",\"binary\":");
    try writeJsonString(writer, case_cfg.descriptor.binary);
    try writer.writeAll(",\"build_step\":");
    if (case_cfg.build_step) |step| {
        try writeJsonString(writer, step);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"baseline\":");
    try writeBinaryEvidence(writer, baseline_evidence);
    try writer.writeAll(",\"candidate\":");
    try writeBinaryEvidence(writer, candidate_evidence);
    try writer.writeAll("}\n");
    try std.Io.Dir.cwd().writeFile(
        std.Io.Threaded.global_single_threaded.io(),
        .{ .sub_path = path, .data = output.written() },
    );
}

fn writeDriverArtifact(allocator: std.mem.Allocator, path: []const u8, case_cfg: CompatCase, raw_json: []const u8, compare_status: []const u8, compare_detail: []const u8) !void {
    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const sha = try gitShaAlloc(allocator);
    defer allocator.free(sha);
    try writer.print(
        "{{\"schema_version\":1,\"machine_id\":\"{s}\",\"git_sha\":\"{s}\",\"zig_version\":\"{s}\",\"binary\":\"{s}\",\"case_id\":\"{s}\",\"case_kind\":\"{s}\",\"tolerance_pct\":{d:.2},\"raw_artifact\":",
        .{ machine_name, sha, builtin.zig_version_string, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, case_cfg.descriptor.case_kind.asString(), case_cfg.tolerance_pct },
    );
    try writer.writeAll(raw_json);
    try writer.print(",\"compare_status\":\"{s}\",\"compare_detail\":", .{compare_status});
    try writeJsonString(writer, compare_detail);
    try writer.writeAll("}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
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
            const stamp = std.Io.Clock.awake.now(
                std.Io.Threaded.global_single_threaded.io(),
            ).nanoseconds;
            const repo_path = try std.fs.path.join(
                allocator,
                &.{ temp_root, "ledger-repo" },
            );
            const definition_path = try std.fs.path.join(
                allocator,
                &.{ temp_root, "ledger-event-definition.json" },
            );
            const request = try std.fmt.allocPrint(
                allocator,
                "request=perf-{d}",
                .{stamp},
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
                request,
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
        .cron_help,
        => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
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
        .cron_list => {
            const db_name = try std.fmt.allocPrint(allocator, "codex-dev-{d}.db", .{@divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000)});
            const db_path = try std.fs.path.join(allocator, &.{ temp_root, db_name });
            try seedCronDb(allocator, db_path);
            try args.appendSlice(allocator, &.{ binary_path, "--db", db_path, "list" });
        },
        else => return error.InvalidCommand,
    }
    return .{ .cwd = cwd, .argv = try args.toOwnedSlice(allocator) };
}

const ChildResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
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
    defer if (capture_root) |path| {
        cleanupTempRoot(path);
        allocator.free(path);
    };
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
    while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
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

fn cleanupTempRoot(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
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

fn seedCronDb(allocator: std.mem.Allocator, db_path: []const u8) !void {
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
            try stderr_writer.interface.print("seedCronDb sqlite error: {s}\n", .{std.mem.sliceTo(msg, 0)});
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

fn jsonObjectFieldU64(value: std.json.Value, key: []const u8) !u64 {
    return jsonFieldU64(value.object, key);
}

fn jsonValueU64(value: std.json.Value, _: []const u8) !u64 {
    return switch (value) {
        .integer => |v| if (v >= 0) @intCast(v) else error.InvalidData,
        .float => |v| if (v >= 0) @intFromFloat(v) else error.InvalidData,
        else => error.InvalidData,
    };
}

fn cmdReport(allocator: std.mem.Allocator) !void {
    const machine_dir = try resolveMachineDir(allocator, ".perf-local");
    defer allocator.free(machine_dir);
    const reports_dir = try std.fs.path.join(allocator, &.{ machine_dir, "reports" });
    defer allocator.free(reports_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), reports_dir);
    const latest_path = try std.fs.path.join(allocator, &.{ machine_dir, "reports", "latest-compare.json" });
    defer allocator.free(latest_path);
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), latest_path, .{}) catch return error.MissingCompareSummary;
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), latest_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const tuple = try validateCutoverCompareSummary(parsed.value);
    const environment = process_environment orelse
        return error.ExpectedSourceShaRequired;
    const current_sha = try sourceShaForRootAlloc(allocator, ".");
    defer allocator.free(current_sha);
    try requireCutoverReportTuple(environment, tuple, current_sha);
    try requireCleanSourceRoot(allocator, ".");
    const rows_val = parsed.value.object.get("rows") orelse return error.InvalidData;
    const rows = rows_val.array;

    var totals = std.StringHashMap(ReportCounts).init(allocator);
    defer totals.deinit();
    for (rows.items) |row| {
        const obj = row.object;
        const binary = obj.get("binary").?.string;
        const status = obj.get("status").?.string;
        const entry = try totals.getOrPutValue(binary, .{});
        if (std.mem.eql(u8, status, "PASS")) entry.value_ptr.pass += 1 else entry.value_ptr.fail += 1;
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

    const latest_report_path = try std.fs.path.join(allocator, &.{ reports_dir, "latest-report.json" });
    defer allocator.free(latest_report_path);
    try writeLatestReport(
        allocator,
        latest_report_path,
        row_keys.items,
        totals,
        tuple,
    );

    const cutover_path = try std.fs.path.join(allocator, &.{ reports_dir, "cutover-status.json" });
    defer allocator.free(cutover_path);
    try writeCutoverStatus(allocator, cutover_path, rows, tuple);
}

const ReportTuple = struct {
    base_sha: []const u8,
    candidate_sha: []const u8,
};

fn validateCutoverCompareSummary(value: std.json.Value) !ReportTuple {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidCompareSummary,
    };
    const target = switch (object.get("target") orelse
        return error.InvalidCompareSummary) {
        .string => |target| target,
        else => return error.InvalidCompareSummary,
    };
    if (!std.mem.eql(u8, target, "cutover")) {
        return error.IncompleteCutoverComparison;
    }
    const expected_base = switch (object.get("expected_base_sha") orelse
        return error.InvalidCompareSummary) {
        .string => |sha| sha,
        else => return error.InvalidCompareSummary,
    };
    const expected_candidate = switch (object.get(
        "expected_candidate_sha",
    ) orelse return error.InvalidCompareSummary) {
        .string => |sha| sha,
        else => return error.InvalidCompareSummary,
    };
    if (expected_base.len != 40 or expected_candidate.len != 40) {
        return error.InvalidCompareSummary;
    }
    const expected_rows = switch (object.get("expected_rows") orelse
        return error.InvalidCompareSummary) {
        .integer => |count| count,
        else => return error.InvalidCompareSummary,
    };
    if (expected_rows != SeqCases.len + LedgerCases.len) {
        return error.IncompleteCutoverComparison;
    }
    const complete = switch (object.get("complete") orelse
        return error.InvalidCompareSummary) {
        .bool => |complete| complete,
        else => return error.InvalidCompareSummary,
    };
    if (!complete) return error.IncompleteCutoverComparison;
    const rows = switch (object.get("rows") orelse
        return error.InvalidCompareSummary) {
        .array => |rows| rows,
        else => return error.InvalidCompareSummary,
    };
    if (rows.items.len != SeqCases.len + LedgerCases.len) {
        return error.IncompleteCutoverComparison;
    }
    for (rows.items, 0..) |row_value, index| {
        const row = switch (row_value) {
            .object => |row| row,
            else => return error.InvalidCompareSummary,
        };
        const tuple_bound = switch (row.get("tuple_bound") orelse
            return error.InvalidCompareSummary) {
            .bool => |bound| bound,
            else => return error.InvalidCompareSummary,
        };
        if (!tuple_bound) return error.UnboundCutoverComparison;
        const case_id = switch (row.get("case_id") orelse
            return error.InvalidCompareSummary) {
            .string => |case_id| case_id,
            else => return error.InvalidCompareSummary,
        };
        for (rows.items[0..index]) |prior_value| {
            const prior = prior_value.object.get("case_id").?.string;
            if (std.mem.eql(u8, prior, case_id)) {
                return error.DuplicateCutoverCase;
            }
        }
        if (!isExpectedCutoverCase(case_id)) {
            return error.UnexpectedCutoverCase;
        }
    }
    return .{
        .base_sha = expected_base,
        .candidate_sha = expected_candidate,
    };
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

fn isExpectedCutoverCase(case_id: []const u8) bool {
    for (SeqCases) |descriptor| {
        if (std.mem.eql(u8, descriptor.case_id, case_id)) return true;
    }
    for (LedgerCases) |descriptor| {
        if (std.mem.eql(u8, descriptor.case_id, case_id)) return true;
    }
    return false;
}

fn cmdAccept(allocator: std.mem.Allocator) !void {
    const machine_dir = try resolveMachineDir(allocator, ".perf-local");
    defer allocator.free(machine_dir);
    const baselines_dir = try std.fs.path.join(allocator, &.{ machine_dir, "baselines" });
    defer allocator.free(baselines_dir);
    const accepted_dir = try std.fs.path.join(allocator, &.{ machine_dir, "accepted" });
    defer allocator.free(accepted_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), accepted_dir);

    const sha = try gitShaAlloc(allocator);
    defer allocator.free(sha);
    const ts = try nowTagAlloc(allocator);
    defer allocator.free(ts);
    const snapshot_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ ts, sha });
    defer allocator.free(snapshot_name);
    const snapshot_path = try std.fs.path.join(allocator, &.{ accepted_dir, snapshot_name });
    defer allocator.free(snapshot_path);
    try copyTree(std.Io.Dir.cwd(), baselines_dir, snapshot_path);

    const active_path = try std.fs.path.join(allocator, &.{ machine_dir, "active-baseline.json" });
    defer allocator.free(active_path);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), active_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try writer.interface.print(
        "{{\"accepted_at\":\"{s}\",\"git_sha\":\"{s}\",\"snapshot_path\":\"{s}\"}}\n",
        .{ ts, sha, snapshot_path },
    );
}

fn resolveMachineDir(allocator: std.mem.Allocator, perf_root: []const u8) ![]u8 {
    const current_name = try currentMachineDirName(allocator);
    defer allocator.free(current_name);

    const preferred = try std.fs.path.join(allocator, &.{ perf_root, current_name });
    errdefer allocator.free(preferred);
    if (pathExists(preferred)) return preferred;

    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), perf_root, .{ .iterate = true });
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var it = dir.iterate();
    var fallback: ?[]u8 = null;
    while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .directory) continue;
        if (fallback != null) return error.AmbiguousMachineDir;
        fallback = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ perf_root, entry.name });
    }
    if (fallback) |value| {
        allocator.free(preferred);
        return value;
    }
    return error.MissingMachineDir;
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
    if (std.mem.startsWith(u8, case_id, "cron-")) return "cron";
    if (std.mem.startsWith(u8, case_id, "bench-stats")) return "bench_stats";
    if (std.mem.startsWith(u8, case_id, "lift-bench-stats")) return "bench_stats";
    if (std.mem.startsWith(u8, case_id, "perf-report")) return "perf_report";
    if (std.mem.startsWith(u8, case_id, "cas-")) return "cas";
    return "unknown";
}

fn gitShaAlloc(allocator: std.mem.Allocator) ![]u8 {
    const head_data = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".git/HEAD", allocator, .limited(1024)) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(head_data);
    const head = std.mem.trim(u8, head_data, " \t\r\n");
    if (std.mem.startsWith(u8, head, "ref: ")) {
        const ref_path = std.mem.trim(u8, head["ref: ".len..], " \t\r\n");
        const loose_path = try std.fs.path.join(allocator, &.{ ".git", ref_path });
        defer allocator.free(loose_path);
        if (std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), loose_path, allocator, .limited(1024))) |ref_data| {
            defer allocator.free(ref_data);
            return shortShaAlloc(allocator, std.mem.trim(u8, ref_data, " \t\r\n"));
        } else |_| {}

        if (std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".git/packed-refs", allocator, .limited(1024 * 1024))) |packed_data| {
            defer allocator.free(packed_data);
            var lines = std.mem.splitScalar(u8, packed_data, '\n');
            while (lines.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r\n");
                if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
                var parts = std.mem.splitScalar(u8, line, ' ');
                const sha = parts.next() orelse continue;
                const name = parts.next() orelse continue;
                if (std.mem.eql(u8, name, ref_path)) return shortShaAlloc(allocator, sha);
            }
        } else |_| {}
        return allocator.dupe(u8, "unknown");
    }
    return shortShaAlloc(allocator, head);
}

fn shortShaAlloc(allocator: std.mem.Allocator, sha: []const u8) ![]u8 {
    return allocator.dupe(u8, sha[0..@min(sha.len, 12)]);
}

fn nowTagAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000)));
    return std.fmt.allocPrint(allocator, "{d}", .{now});
}

fn copyTree(cwd: std.Io.Dir, source: []const u8, dest: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try cwd.createDirPath(io, dest);
    var src = try cwd.openDir(io, source, .{ .iterate = true });
    defer src.close(io);
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        const src_path = try std.fs.path.join(std.heap.page_allocator, &.{ source, entry.name });
        defer std.heap.page_allocator.free(src_path);
        const dest_path = try std.fs.path.join(std.heap.page_allocator, &.{ dest, entry.name });
        defer std.heap.page_allocator.free(dest_path);
        switch (entry.kind) {
            .directory => try copyTree(cwd, src_path, dest_path),
            .file => try cwd.copyFile(src_path, cwd, dest_path, io, .{}),
            else => {},
        }
    }
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

fn writeLatestReport(
    allocator: std.mem.Allocator,
    path: []const u8,
    row_keys: []const []const u8,
    totals: std.StringHashMap(ReportCounts),
    tuple: ReportTuple,
) !void {
    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeAll("{\"expected_base_sha\":");
    try writeJsonString(writer, tuple.base_sha);
    try writer.writeAll(",\"expected_candidate_sha\":");
    try writeJsonString(writer, tuple.candidate_sha);
    try writer.writeAll(",\"rows\":[");
    for (row_keys, 0..) |key, idx| {
        const counts = totals.get(key).?;
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"binary\":\"{s}\",\"pass\":{d},\"fail\":{d}}}", .{ key, counts.pass, counts.fail });
    }
    try writer.writeAll("]}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
}

fn writeCutoverStatus(
    allocator: std.mem.Allocator,
    path: []const u8,
    rows: std.json.Array,
    tuple: ReportTuple,
) !void {
    var all_cases_pass = true;
    for (rows.items) |row| {
        if (!std.mem.eql(u8, row.object.get("status").?.string, "PASS")) {
            all_cases_pass = false;
            break;
        }
    }

    const seq_status = coverageStatusFor("seq");
    const ledger_status = coverageStatusFor("ledger");
    const cron_status = coverageStatusFor("cron");

    var residuals = std.ArrayList([]const u8).empty;
    defer {
        for (residuals.items) |item| allocator.free(item);
        residuals.deinit(allocator);
    }
    for (allManifests()) |manifest| {
        for (manifest.coverages) |coverage| {
            if (coverage.coverage == .missing) {
                try residuals.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}", .{ manifest.binary, coverage.family }));
            }
        }
        for (manifest.datasets) |dataset| {
            if (dataset.coverage == .missing) {
                try residuals.append(allocator, try std.fmt.allocPrint(allocator, "{s}:dataset:{s}", .{ manifest.binary, dataset.name }));
            }
        }
    }

    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeAll("{\"expected_base_sha\":");
    try writeJsonString(writer, tuple.base_sha);
    try writer.writeAll(",\"expected_candidate_sha\":");
    try writeJsonString(writer, tuple.candidate_sha);
    try writer.print(
        ",\"native_public_ownership\":true,\"all_cases_pass\":{s}," ++
            "\"seq_status\":\"{s}\",\"ledger_status\":\"{s}\"," ++
            "\"cron_status\":\"{s}\",\"residuals\":[",
        .{
            if (all_cases_pass) "true" else "false",
            seq_status,
            ledger_status,
            cron_status,
        },
    );
    for (residuals.items, 0..) |item, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeAll("]}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
}

fn coverageStatusFor(binary: []const u8) []const u8 {
    for (allManifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.binary, binary)) continue;
        var saw_deep = false;
        var saw_shallow = false;
        for (manifest.coverages) |coverage| {
            switch (coverage.coverage) {
                .missing => return if (saw_deep) "partial" else "not_landed",
                .deep => saw_deep = true,
                .shallow => saw_shallow = true,
                .excluded => {},
            }
        }
        return if (saw_deep) "landed" else if (saw_shallow) "qualified" else "not_landed";
    }
    return "unknown";
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

test "resolveMachineDir prefers current machine directory when multiple directories exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), alloc);
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(std.Io.Threaded.global_single_threaded.io(), tmp.dir);
    defer std.process.setCurrentPath(std.Io.Threaded.global_single_threaded.io(), cwd_before) catch {};

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".perf-local");
    const current_name = try currentMachineDirName(alloc);
    defer alloc.free(current_name);
    const current_path = try std.fmt.allocPrint(alloc, ".perf-local/{s}", .{current_name});
    defer alloc.free(current_path);
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), current_path);
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".perf-local/other-machine");

    const resolved = try resolveMachineDir(alloc, ".perf-local");
    defer alloc.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, current_name));
}

test "resolveMachineDir falls back to a single legacy directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), alloc);
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(std.Io.Threaded.global_single_threaded.io(), tmp.dir);
    defer std.process.setCurrentPath(std.Io.Threaded.global_single_threaded.io(), cwd_before) catch {};

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".perf-local/legacy-only");
    const resolved = try resolveMachineDir(alloc, ".perf-local");
    defer alloc.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "legacy-only"));
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

test "comparison invalidates a prior summary before measurement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        ".",
        alloc,
    );
    defer alloc.free(root);
    const machine_dir = try std.fs.path.join(
        alloc,
        &.{ root, "machine" },
    );
    defer alloc.free(machine_dir);
    const reports_dir = try std.fs.path.join(
        alloc,
        &.{ machine_dir, "reports" },
    );
    defer alloc.free(reports_dir);
    try std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        reports_dir,
    );
    const latest_path = try std.fs.path.join(
        alloc,
        &.{ reports_dir, "latest-compare.json" },
    );
    defer alloc.free(latest_path);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = latest_path,
        .data = "{}\n",
    });
    try invalidateCompareSummary(alloc, machine_dir);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(
            std.Io.Threaded.global_single_threaded.io(),
            latest_path,
            .{},
        ),
    );
}

test "inferBinary maps lift driver case to bench_stats" {
    try std.testing.expectEqualStrings("bench_stats", inferBinary("lift-bench-stats-driver"));
}

test "incompatible paired comparisons fail closed" {
    try std.testing.expect(!comparisonStatusFailed("PASS"));
    try std.testing.expect(comparisonStatusFailed("FAIL"));
    try std.testing.expect(comparisonStatusFailed("INCOMPATIBLE"));
}

test "coverageStatusFor reflects current manifest coverage" {
    try std.testing.expectEqualStrings("landed", coverageStatusFor("seq"));
    try std.testing.expectEqualStrings("qualified", coverageStatusFor("ledger"));
    try std.testing.expectEqualStrings("landed", coverageStatusFor("cron"));
}

test "compareLatencyMetrics fails closed for incomplete allocation baselines" {
    const alloc = std.testing.allocator;
    const baseline_json =
        \\{"metrics":{"p50_ns":100,"p95_ns":200}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, baseline_json, .{});
    defer parsed.deinit();

    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(alloc);
    var alloc_samples: std.ArrayList(u64) = .empty;
    defer alloc_samples.deinit(alloc);

    const result = try compareLatencyMetrics(.{
        .descriptor = .{
            .case_id = "synthetic-allocation-case",
            .binary = "seq",
            .family = "query",
            .case_kind = .native,
            .measurement_mode = .latency_alloc,
        },
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .tolerance_pct = 25.0,
    }, parsed.value, .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .p50_ns = 100,
        .p95_ns = 200,
        .p50_alloc_calls = 10,
    });

    try std.testing.expectEqualStrings("FAIL", result.status);
    try std.testing.expectEqualStrings(
        "baseline missing allocation metrics; recapture baseline",
        result.detail,
    );
}

test "doctor counts compat and deep cases" {
    var count: usize = 0;
    for (CompatCases) |_| count += 1;
    for (DeepCases) |_| count += 1;
    try std.testing.expectEqual(CompatCases.len + DeepCases.len, count);
}

test "cutover comparison requires the complete Seq and Ledger matrix" {
    try std.testing.expectEqual(
        @as(?usize, SeqCases.len),
        expectedComparisonCount("seq"),
    );
    try std.testing.expectEqual(
        @as(?usize, LedgerCases.len),
        expectedComparisonCount("ledger"),
    );
    try std.testing.expectEqual(
        @as(?usize, SeqCases.len + LedgerCases.len),
        expectedComparisonCount("cutover"),
    );
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

test "override builds bind to the canonical product output" {
    const path = try canonicalBuildOutputPathAlloc(
        std.testing.allocator,
        "/repo",
        "ledger",
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(
        "/repo/zig-out/bin/ledger",
        path,
    );
    try std.testing.expectEqual(@as(usize, 4), paired_comparison_rounds);
}
