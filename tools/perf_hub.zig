const std = @import("std");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const core_perf = @import("core_perf");
const cron_cli = @import("cron_cli");
const perf_contract = @import("perf_contract");

const Version = "0.0.0-dev";
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
    seq_help,
    seq_definition_check,
    seq_observe,
    seq_sessions,
    seq_query,
    ledger_help,
    ledger_definition_check,
    ledger_validate,
    ledger_materialize,
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
};

const DeepSetup = enum {
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
};

const SeqCases = [_]perf_contract.CaseDescriptor{
    .{ .case_id = "seq-help", .binary = "seq", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only },
    .{ .case_id = "seq-definition-check", .binary = "seq", .family = "definition", .case_kind = .subprocess, .measurement_mode = .latency_only },
    .{ .case_id = "seq-observe", .binary = "seq", .family = "observe", .case_kind = .subprocess, .measurement_mode = .latency_only },
    .{ .case_id = "seq-sessions", .binary = "seq", .family = "sessions", .case_kind = .subprocess, .measurement_mode = .latency_only },
    .{ .case_id = "seq-query", .binary = "seq", .family = "query", .case_kind = .subprocess, .measurement_mode = .latency_only },
};

const SeqCoverages = [_]perf_contract.CommandCoverage{
    .{ .family = "definition", .coverage = .shallow, .reason = "definition compilation case" },
    .{ .family = "observe", .coverage = .shallow, .reason = "compiled observation case" },
    .{ .family = "explain", .coverage = .shallow, .reason = "shares definition compiler" },
    .{ .family = "sessions", .coverage = .shallow, .reason = "physical corpus case" },
    .{ .family = "turns", .coverage = .shallow, .reason = "physical trace case" },
    .{ .family = "session-detail", .coverage = .shallow, .reason = "physical trace case" },
    .{ .family = "tool-lifecycle", .coverage = .shallow, .reason = "physical trace case" },
    .{ .family = "session-graph", .coverage = .shallow, .reason = "physical trace case" },
    .{ .family = "tail", .coverage = .shallow, .reason = "physical trace case" },
    .{ .family = "find-session", .coverage = .shallow, .reason = "physical corpus case" },
    .{ .family = "datasets", .coverage = .shallow, .reason = "static physical catalog" },
    .{ .family = "dataset-schema", .coverage = .shallow, .reason = "static physical catalog" },
    .{ .family = "query", .coverage = .shallow, .reason = "generic query case" },
    .{ .family = "index", .coverage = .shallow, .reason = "physical index smoke lane" },
    .{ .family = "capabilities", .coverage = .shallow, .reason = "command-surface gate" },
    .{ .family = "version", .coverage = .shallow, .reason = "command-surface gate" },
};
const SeqDatasets = [_]perf_contract.DataSurface{
    .{ .name = "sessions", .coverage = .shallow, .reason = "physical corpus case" },
    .{ .name = "turns", .coverage = .shallow, .reason = "physical trace case" },
    .{ .name = "messages", .coverage = .shallow, .reason = "compiled observation case" },
    .{ .name = "structured_values", .coverage = .shallow, .reason = "generic structured evidence lane" },
};

const LedgerCases = [_]perf_contract.CaseDescriptor{
    .{ .case_id = "ledger-help", .binary = "ledger", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only },
    .{ .case_id = "ledger-definition-check", .binary = "ledger", .family = "definition", .case_kind = .subprocess, .measurement_mode = .latency_only },
    .{ .case_id = "ledger-validate", .binary = "ledger", .family = "validate", .case_kind = .subprocess, .measurement_mode = .latency_only },
    .{ .case_id = "ledger-materialize", .binary = "ledger", .family = "materialize", .case_kind = .subprocess, .measurement_mode = .latency_only },
};

const LedgerCoverages = [_]perf_contract.CommandCoverage{
    .{ .family = "definition", .coverage = .shallow, .reason = "definition compilation case" },
    .{ .family = "validate", .coverage = .shallow, .reason = "compiled validation case" },
    .{ .family = "materialize", .coverage = .shallow, .reason = "canonicalization and identity case" },
    .{ .family = "transact", .coverage = .shallow, .reason = "durable protocol qualification lane" },
    .{ .family = "project", .coverage = .shallow, .reason = "durable protocol qualification lane" },
    .{ .family = "doctor", .coverage = .shallow, .reason = "durable protocol qualification lane" },
    .{ .family = "capabilities", .coverage = .shallow, .reason = "command-surface gate" },
    .{ .family = "version", .coverage = .shallow, .reason = "command-surface gate" },
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
    .{ .descriptor = SeqCases[0], .builder = .root, .build_step = "build-seq", .binary_path = "zig-out/bin/seq", .setup = .seq_help },
    .{ .descriptor = SeqCases[1], .builder = .root, .build_step = "build-seq", .binary_path = "zig-out/bin/seq", .setup = .seq_definition_check },
    .{ .descriptor = SeqCases[2], .builder = .root, .build_step = "build-seq", .binary_path = "zig-out/bin/seq", .setup = .seq_observe },
    .{ .descriptor = SeqCases[3], .builder = .root, .build_step = "build-seq", .binary_path = "zig-out/bin/seq", .setup = .seq_sessions },
    .{ .descriptor = SeqCases[4], .builder = .root, .build_step = "build-seq", .binary_path = "zig-out/bin/seq", .setup = .seq_query },
    .{ .descriptor = LedgerCases[0], .builder = .root, .build_step = "build-ledger", .binary_path = "zig-out/bin/ledger", .setup = .ledger_help },
    .{ .descriptor = LedgerCases[1], .builder = .root, .build_step = "build-ledger", .binary_path = "zig-out/bin/ledger", .setup = .ledger_definition_check },
    .{ .descriptor = LedgerCases[2], .builder = .root, .build_step = "build-ledger", .binary_path = "zig-out/bin/ledger", .setup = .ledger_validate },
    .{ .descriptor = LedgerCases[3], .builder = .root, .build_step = "build-ledger", .binary_path = "zig-out/bin/ledger", .setup = .ledger_materialize },
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
    const machine_dir = try resolveMachineDir(allocator, ".perf-local");
    defer allocator.free(machine_dir);
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
        const result = try compareCompatCase(allocator, machine_dir, case_cfg);
        try rows.append(allocator, result);
        try stdout.print("{s}\t{s}\t{s}\n", .{ result.status, result.case_id, result.detail });
        if (std.mem.eql(u8, result.status, "FAIL")) any_fail = true;
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        const result = try compareDeepCase(allocator, machine_dir, case_cfg);
        try rows.append(allocator, result);
        try stdout.print("{s}\t{s}\t{s}\n", .{ result.status, result.case_id, result.detail });
        if (std.mem.eql(u8, result.status, "FAIL")) any_fail = true;
    }

    try writeCompareSummaryRows(allocator, machine_dir, rows.items);
    if (any_fail) std.process.exit(1);
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
    const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
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

fn compareCompatCase(allocator: std.mem.Allocator, machine_dir: []const u8, case_cfg: CompatCase) !CompareRow {
    const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
    defer allocator.free(baseline_path);
    if (!pathExists(baseline_path)) {
        return .{ .status = "FAIL", .case_id = case_cfg.descriptor.case_id, .binary = case_cfg.descriptor.binary, .detail = "missing baseline" };
    }

    const baseline_data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), baseline_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(baseline_data);
    var baseline = try std.json.parseFromSlice(std.json.Value, allocator, baseline_data, .{});
    defer baseline.deinit();

    const latest_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, true);
    defer allocator.free(latest_path);

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

fn compareDeepCase(allocator: std.mem.Allocator, machine_dir: []const u8, case_cfg: DeepCase) !CompareRow {
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
    const compare = try compareLatencyMetrics(.{
        .descriptor = case_cfg.descriptor,
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .warmups = case_cfg.warmups,
        .samples = case_cfg.samples,
        .tolerance_pct = case_cfg.tolerance_pct,
    }, baseline.value, metrics);

    const latest_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, true);
    defer allocator.free(latest_path);
    try writeMetricsArtifact(allocator, latest_path, .{
        .descriptor = case_cfg.descriptor,
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .warmups = case_cfg.warmups,
        .samples = case_cfg.samples,
        .tolerance_pct = case_cfg.tolerance_pct,
    }, metrics, if (std.mem.eql(u8, compare.status, "PASS")) "pass" else "fail", compare.detail);

    return .{
        .status = compare.status,
        .case_id = case_cfg.descriptor.case_id,
        .binary = case_cfg.descriptor.binary,
        .detail = compare.detail,
    };
}

fn writeCompareSummaryRows(allocator: std.mem.Allocator, machine_dir: []const u8, rows: []const CompareRow) !void {
    const reports_dir = try std.fs.path.join(allocator, &.{ machine_dir, "reports" });
    defer allocator.free(reports_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), reports_dir);
    const latest_path = try std.fs.path.join(allocator, &.{ reports_dir, "latest-compare.json" });
    defer allocator.free(latest_path);

    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), latest_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try writer.interface.writeAll("{\"rows\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.interface.writeByte(',');
        try writer.interface.print(
            "{{\"case_id\":\"{s}\",\"binary\":\"{s}\",\"status\":\"{s}\",\"detail\":",
            .{ row.case_id, row.binary, row.status },
        );
        try std.json.Stringify.value(row.detail, .{}, &writer.interface);
        try writer.interface.writeByte('}');
    }
    try writer.interface.writeAll("]}\n");
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
    if (built.keys.contains(key)) return;

    const cwd = ".";

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "zig");
    try args.append(allocator, "build");
    if (case_cfg.build_step) |step| try args.append(allocator, step);
    try args.append(allocator, "-Doptimize=ReleaseFast");
    const result = try runChildCapture(allocator, cwd, args.items);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BuildFailed;
    try built.keys.put(try allocator.dupe(u8, key), {});
}

fn resolveBinaryPath(allocator: std.mem.Allocator, case_cfg: CompatCase) ![]u8 {
    _ = case_cfg.builder;
    return std.fs.path.join(allocator, &.{ ".", case_cfg.binary_path });
}

fn resolveBinaryExecPath(allocator: std.mem.Allocator, case_cfg: CompatCase) ![]u8 {
    _ = case_cfg.builder;
    return std.fs.path.join(allocator, &.{ ".", case_cfg.binary_path });
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
        const start_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
        const result = try runChildCapture(allocator, run.cwd, run.argv);
        const elapsed: u64 = @intCast(@max(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds - start_ns, 1));
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.exit_code != 0) {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        try executeDeepCase(counting.allocator(), case_cfg.setup, temp_root);
    }

    var sample_idx: usize = 0;
    while (sample_idx < case_cfg.samples) : (sample_idx += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        const start_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
        try executeDeepCase(counting.allocator(), case_cfg.setup, temp_root);
        try samples.append(allocator, @intCast(@max(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds - start_ns, 1)));
        try alloc_samples.append(allocator, counting.stats.totalCalls());
    }

    return .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .p50_ns = try percentileU64(allocator, samples.items, 50),
        .p95_ns = try percentileU64(allocator, samples.items, 95),
        .p50_alloc_calls = try percentileU64(allocator, alloc_samples.items, 50),
    };
}

fn executeDeepCase(allocator: std.mem.Allocator, setup: DeepSetup, temp_root: []const u8) !void {
    switch (setup) {
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

fn compareLatencyMetrics(case_cfg: CompatCase, baseline: std.json.Value, metrics: Metrics) !StatusDetail {
    const root = baseline.object;
    const baseline_metrics = root.get("metrics") orelse return error.InvalidData;
    const metric_obj = baseline_metrics.object;
    if (case_cfg.descriptor.measurement_mode == .latency_alloc and baseline_metrics.object.get("p50_alloc_calls") == null) {
        return .{ .status = "FAIL", .detail = "baseline missing allocation metrics; recapture baseline" };
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

fn renderCompatRun(allocator: std.mem.Allocator, case_cfg: CompatCase, temp_root: []const u8) !CommandRun {
    const binary_path = try resolveBinaryExecPath(allocator, case_cfg);
    errdefer allocator.free(binary_path);
    _ = case_cfg.builder;
    const cwd = try allocator.dupe(u8, ".");
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    switch (case_cfg.setup) {
        .seq_help => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
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
        .seq_sessions => try args.appendSlice(allocator, &.{
            binary_path,
            "sessions",
            "--root",
            "apps/seq/src/v1/fixtures",
            "--format",
            "json",
        }),
        .seq_query => try args.appendSlice(allocator, &.{
            binary_path,
            "query",
            "--root",
            "apps/seq/src/v1/fixtures",
            "--spec",
            "{\"dataset\":\"messages\",\"where\":[{\"field\":\"text\",\"op\":\"contains\",\"value\":\"failure\",\"case_insensitive\":true}],\"select\":[\"session_id\",\"role\",\"text\"],\"limit\":5,\"format\":\"json\"}",
        }),
        .ledger_help => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
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
        .bench_stats_help, .perf_report_help, .cas_smoke_check_help, .cas_instance_runner_help, .cas_review_session_help, .cron_help => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
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
    if (builtin.os.tag == .macos) return runChildCapturePosixSpawn(allocator, cwd, argv);

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

fn runChildCapturePosixSpawn(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !ChildResult {
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

    const dev_null = "/dev/null";
    const dev_null_flags: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .WRONLY })));
    for ([_]std.c.fd_t{ 1, 2 }) |fd| {
        const open_rc = std.c.posix_spawn_file_actions_addopen(&actions, fd, dev_null, dev_null_flags, 0);
        if (open_rc != 0) return posixSpawnError(open_rc);
    }
    const chdir_rc = std.c.posix_spawn_file_actions_addchdir_np(&actions, cwd_z);
    if (chdir_rc != 0) return posixSpawnError(chdir_rc);

    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const spawn_rc = std.c.posix_spawnp(&pid, argv_buf[0].?, &actions, null, argv_buf.ptr, envp);
    if (spawn_rc != 0) return posixSpawnError(spawn_rc);

    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
        .SUCCESS => return .{
            .exit_code = statusToExitCode(@bitCast(status)),
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
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

fn jsonValueF64(value: std.json.Value, _: []const u8) !f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => error.InvalidData,
    };
}

fn jsonObjectFieldF64(value: std.json.Value, key: []const u8) !f64 {
    return jsonValueF64(value.object.get(key) orelse return error.InvalidData, key);
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
    try writeLatestReport(allocator, latest_report_path, row_keys.items, totals);

    const cutover_path = try std.fs.path.join(allocator, &.{ reports_dir, "cutover-status.json" });
    defer allocator.free(cutover_path);
    try writeCutoverStatus(allocator, cutover_path, rows);
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
) !void {
    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeAll("{\"rows\":[");
    for (row_keys, 0..) |key, idx| {
        const counts = totals.get(key).?;
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"binary\":\"{s}\",\"pass\":{d},\"fail\":{d}}}", .{ key, counts.pass, counts.fail });
    }
    try writer.writeAll("]}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
}

fn writeCutoverStatus(allocator: std.mem.Allocator, path: []const u8, rows: std.json.Array) !void {
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
    try writer.print(
        "{{\"native_public_ownership\":true,\"all_cases_pass\":{s},\"seq_status\":\"{s}\",\"ledger_status\":\"{s}\",\"cron_status\":\"{s}\",\"residuals\":[",
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

test "inferBinary maps lift driver case to bench_stats" {
    try std.testing.expectEqualStrings("bench_stats", inferBinary("lift-bench-stats-driver"));
}

test "coverageStatusFor reflects current manifest coverage" {
    try std.testing.expectEqualStrings("qualified", coverageStatusFor("seq"));
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
    try std.testing.expectEqualStrings("baseline missing allocation metrics; recapture baseline", result.detail);
}

test "doctor counts compat and deep cases" {
    var count: usize = 0;
    for (CompatCases) |_| count += 1;
    for (DeepCases) |_| count += 1;
    try std.testing.expectEqual(CompatCases.len + DeepCases.len, count);
}
