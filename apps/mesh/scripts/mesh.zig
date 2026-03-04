const std = @import("std");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);

const UsageText =
    \\mesh.zig
    \\
    \\Marker: mesh.zig
    \\
    \\Plan-driven orchestration helpers for streaming batch contracts, budget clamps, and event-only ledgers.
    \\
    \\usage: mesh {budget,plan_sync,slice,wave,run_csv,ledger,replay,orchplan_to_units,prepare_crfip_batch,doctor,lane_completeness_lint,contract_drift_lint,migration_gate} [options]
    \\
    \\commands:
    \\  budget      Compute active-unit clamp from 5-hour + weekly remaining percentages
    \\  plan_sync   Summarize update_plan payload shape
    \\  slice       Derive atomic units from plan steps
    \\  wave        Emit a streaming batch CSV from sliced units
    \\  run_csv     Validate a streaming batch CSV, enforce optional floor/deadlock gates, and prepare output CSV path safely
    \\  ledger      Filter a ledger object down to occurred events only
    \\  replay      Simulate budget + wave sizing without execution
    \\  orchplan_to_units      Convert OrchPlan (json/yaml) into units.json payloads
    \\  prepare_crfip_batch    Emit durable CRFIP candidate CSV + output CSV skeleton
    \\  doctor                 Run mesh postmortem gates (mesh-truth, artifacts, lane checks)
    \\  lane_completeness_lint Lint candidate/full/crfip lane completeness fail-closed
    \\  contract_drift_lint    Assert required mesh contract snippets across docs/config
    \\  migration_gate         Composite fail-closed migration closeout gate
    \\
    \\global options:
    \\  -h, --help                 Show help
    \\  -V, --version | version    Show version
;

const RequiredCsvHeaders = [_][]const u8{
    "id",
    "objective",
    "unit_scope",
    "write_scope",
    "constraints",
    "invariants",
    "proof_command",
    "risk_tier",
    "candidate_id",
    "triplet_index",
    "lane",
    "base_sha",
    "delivery_mode",
    "attempt",
    "variant",
    "budget_tier",
};

const Command = enum {
    budget,
    plan_sync,
    slice,
    wave,
    run_csv,
    ledger,
    replay,
    orchplan_to_units,
    prepare_crfip_batch,
    doctor,
    lane_completeness_lint,
    contract_drift_lint,
    migration_gate,
};

const BudgetMode = enum {
    full_fanout,
    linear_clamp,
    single_agent,
};

const BudgetDecision = struct {
    remaining_five_hour: f64,
    remaining_weekly: f64,
    remaining_strict: f64,
    linear_start_threshold: f64,
    single_agent_threshold: f64,
    scaleout_threshold: f64,
    max_threads: usize,
    max_active_units: usize,
    mode: BudgetMode,
    cas_scaleout_allowed: bool,
    triplet_width: usize,
    triplet_degrade_reason: []const u8,
    triplet_restored: bool,
};

const Lane = enum {
    coder,
    reducer,
    locksmith,
    applier,
    prover,
    fixer,
    integrator,
};

const TripletDecision = struct {
    width: usize,
    degrade_reason: []const u8,
    restored: bool,
};

const PlanStep = struct {
    step: []const u8,
    status: []const u8,
};

const SliceUnit = struct {
    id: []const u8,
    objective: []const u8,
    unit_scope: []const u8,
    write_scope: []const u8,
    constraints: []const u8,
    invariants: []const u8,
    proof_command: []const u8,
    risk_tier: []const u8,
    base_sha: []const u8,
    delivery_mode: []const u8,
    attempt: []const u8,
    variant: []const u8,
    budget_tier: []const u8,
};

const RunCsvFloorDecision = struct {
    effective_peak: usize,
    applicable: bool,
    result: []const u8,
};

const DepRow = struct {
    id: []const u8,
    deps_raw: []const u8,
    interactive_lead: bool,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len <= 1) {
        try printHelp();
        return;
    }

    if (core_cli.isHelpArg(argv[1])) {
        try printHelp();
        return;
    }

    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        try printVersion();
        return;
    }

    const cmd = resolveCommand(argv[1]) orelse {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("Unknown command: {s}\n", .{argv[1]});
        try core_cli.printHelpWithVersion(stderr, UsageText, Version);
        std.process.exit(2);
    };

    if (argv.len >= 3 and core_cli.isHelpArg(argv[2])) {
        try printHelp();
        return;
    }

    switch (cmd) {
        .budget => try cmdBudget(argv[2..]),
        .plan_sync => try cmdPlanSync(allocator, argv[2..]),
        .slice => try cmdSlice(allocator, argv[2..]),
        .wave => try cmdWave(allocator, argv[2..]),
        .run_csv => try cmdRunCsv(allocator, argv[2..]),
        .ledger => try cmdLedger(allocator, argv[2..]),
        .replay => try cmdReplay(argv[2..]),
        .orchplan_to_units => try cmdOrchplanToUnits(allocator, argv[2..]),
        .prepare_crfip_batch => try cmdPrepareCrfipBatch(allocator, argv[2..]),
        .doctor => try cmdDoctor(allocator, argv[2..]),
        .lane_completeness_lint => try cmdLaneCompletenessLint(allocator, argv[2..]),
        .contract_drift_lint => try cmdContractDriftLint(allocator, argv[2..]),
        .migration_gate => try cmdMigrationGate(allocator, argv[2..]),
    }
}

fn resolveCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "budget")) return .budget;
    if (std.mem.eql(u8, raw, "plan_sync") or std.mem.eql(u8, raw, "plan-sync")) return .plan_sync;
    if (std.mem.eql(u8, raw, "slice")) return .slice;
    if (std.mem.eql(u8, raw, "wave")) return .wave;
    if (std.mem.eql(u8, raw, "run_csv") or std.mem.eql(u8, raw, "run-csv")) return .run_csv;
    if (std.mem.eql(u8, raw, "ledger")) return .ledger;
    if (std.mem.eql(u8, raw, "replay")) return .replay;
    if (std.mem.eql(u8, raw, "orchplan_to_units") or std.mem.eql(u8, raw, "orchplan-to-units")) return .orchplan_to_units;
    if (std.mem.eql(u8, raw, "prepare_crfip_batch") or std.mem.eql(u8, raw, "prepare-crfip-batch")) return .prepare_crfip_batch;
    if (std.mem.eql(u8, raw, "doctor")) return .doctor;
    if (std.mem.eql(u8, raw, "lane_completeness_lint") or std.mem.eql(u8, raw, "lane-completeness-lint") or std.mem.eql(u8, raw, "lane_lint")) return .lane_completeness_lint;
    if (std.mem.eql(u8, raw, "contract_drift_lint") or std.mem.eql(u8, raw, "contract-drift-lint")) return .contract_drift_lint;
    if (std.mem.eql(u8, raw, "migration_gate") or std.mem.eql(u8, raw, "migration-gate")) return .migration_gate;
    return null;
}

fn printHelp() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try core_cli.printHelpWithVersion(stdout, UsageText, Version);
}

fn printVersion() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try core_cli.printVersion(stdout, Version);
}

fn cmdBudget(args: []const []const u8) !void {
    var remaining_five_hour: ?f64 = null;
    var remaining_weekly: ?f64 = null;
    var max_threads: usize = 12;
    var single_agent_threshold: f64 = 10;
    var linear_start_threshold: f64 = 33;
    var scaleout_threshold: f64 = 25;
    var previous_triplet_width: usize = 3;
    var prior_wave_instability = false;
    var consecutive_unstable_waves: usize = 0;
    var consecutive_clean_waves: usize = 0;
    var format_json = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--remaining-five-hour")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            remaining_five_hour = try std.fmt.parseFloat(f64, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--remaining-weekly")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            remaining_weekly = try std.fmt.parseFloat(f64, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-threads")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            max_threads = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--single-agent-threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            single_agent_threshold = try std.fmt.parseFloat(f64, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--linear-start-threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            linear_start_threshold = try std.fmt.parseFloat(f64, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--scaleout-threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            scaleout_threshold = try std.fmt.parseFloat(f64, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--previous-triplet-width")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            previous_triplet_width = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--prior-wave-instability")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            prior_wave_instability = try parseBool(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--consecutive-unstable-waves")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            consecutive_unstable_waves = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--consecutive-clean-waves")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            consecutive_clean_waves = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            format_json = std.mem.eql(u8, args[i], "json");
            continue;
        }
        return error.UnknownFlag;
    }

    if (remaining_five_hour == null or remaining_weekly == null) {
        return error.MissingRequiredOption;
    }

    const decision = computeBudgetDecision(
        remaining_five_hour.?,
        remaining_weekly.?,
        max_threads,
        linear_start_threshold,
        single_agent_threshold,
        scaleout_threshold,
        previous_triplet_width,
        prior_wave_instability,
        consecutive_unstable_waves,
        consecutive_clean_waves,
    );

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    if (!format_json) {
        try stdout.print(
            "mode={s} strict_remaining={d:.2} max_active_units={d} cas_scaleout_allowed={s} triplet_width={d} triplet_degrade_reason={s} triplet_restored={s}\n",
            .{
                budgetModeString(decision.mode),
                decision.remaining_strict,
                decision.max_active_units,
                if (decision.cas_scaleout_allowed) "true" else "false",
                decision.triplet_width,
                decision.triplet_degrade_reason,
                if (decision.triplet_restored) "true" else "false",
            },
        );
        return;
    }

    try stdout.print(
        "{{\"command\":\"budget\",\"remaining_five_hour\":{d:.4},\"remaining_weekly\":{d:.4},\"remaining_strict\":{d:.4},\"linear_start_threshold\":{d:.4},\"single_agent_threshold\":{d:.4},\"scaleout_threshold\":{d:.4},\"max_threads\":{d},\"max_active_units\":{d},\"mode\":\"{s}\",\"cas_scaleout_allowed\":{s},\"triplet_width\":{d},\"triplet_degrade_reason\":",
        .{
            decision.remaining_five_hour,
            decision.remaining_weekly,
            decision.remaining_strict,
            decision.linear_start_threshold,
            decision.single_agent_threshold,
            decision.scaleout_threshold,
            decision.max_threads,
            decision.max_active_units,
            budgetModeString(decision.mode),
            if (decision.cas_scaleout_allowed) "true" else "false",
            decision.triplet_width,
        },
    );
    try std.json.Stringify.value(decision.triplet_degrade_reason, .{}, stdout);
    try stdout.print(",\"triplet_restored\":{s}}}\n", .{if (decision.triplet_restored) "true" else "false"});
}

fn cmdReplay(args: []const []const u8) !void {
    var remaining_five_hour: ?f64 = null;
    var remaining_weekly: ?f64 = null;
    var max_threads: usize = 12;
    var ready_units: ?usize = null;
    var previous_triplet_width: usize = 3;
    var prior_wave_instability = false;
    var consecutive_unstable_waves: usize = 0;
    var consecutive_clean_waves: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--remaining-five-hour")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            remaining_five_hour = try std.fmt.parseFloat(f64, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--remaining-weekly")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            remaining_weekly = try std.fmt.parseFloat(f64, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-threads")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            max_threads = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--ready-units")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            ready_units = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--previous-triplet-width")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            previous_triplet_width = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--prior-wave-instability")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            prior_wave_instability = try parseBool(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--consecutive-unstable-waves")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            consecutive_unstable_waves = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--consecutive-clean-waves")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            consecutive_clean_waves = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        return error.UnknownFlag;
    }

    if (remaining_five_hour == null or remaining_weekly == null or ready_units == null) {
        return error.MissingRequiredOption;
    }

    const decision = computeBudgetDecision(
        remaining_five_hour.?,
        remaining_weekly.?,
        max_threads,
        33,
        10,
        25,
        previous_triplet_width,
        prior_wave_instability,
        consecutive_unstable_waves,
        consecutive_clean_waves,
    );
    const per_wave = @max(@as(usize, 1), decision.max_active_units);
    var remaining = ready_units.?;
    var wave_sizes: std.ArrayList(usize) = .empty;
    defer wave_sizes.deinit(std.heap.page_allocator);

    while (remaining > 0) {
        const n = @min(remaining, per_wave);
        try wave_sizes.append(std.heap.page_allocator, n);
        remaining -= n;
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.print(
        "{{\"command\":\"replay\",\"mode\":\"{s}\",\"max_active_units\":{d},\"triplet_width\":{d},\"triplet_degrade_reason\":",
        .{ budgetModeString(decision.mode), decision.max_active_units, decision.triplet_width },
    );
    try std.json.Stringify.value(decision.triplet_degrade_reason, .{}, stdout);
    try stdout.print(",\"triplet_restored\":{s},\"ready_units\":{d},\"wave_count\":{d},\"waves\":[", .{
        if (decision.triplet_restored) "true" else "false",
        ready_units.?,
        wave_sizes.items.len,
    });
    for (wave_sizes.items, 0..) |n, idx| {
        if (idx > 0) try stdout.print(",", .{});
        try stdout.print("{d}", .{n});
    }
    try stdout.writeAll("],\"rows_per_lane\":[");
    for (wave_sizes.items, 0..) |n, idx| {
        if (idx > 0) try stdout.print(",", .{});
        try stdout.print("{d}", .{n * decision.triplet_width});
    }
    try stdout.writeAll("]}\n");
}

fn cmdPlanSync(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const input_path = try parseRequiredPath(args, "--input-json");
    const bytes = try std.fs.cwd().readFileAlloc(allocator, input_path, 16 * 1024 * 1024);
    const steps = try parsePlanSteps(allocator, bytes);

    var pending: usize = 0;
    var in_progress: usize = 0;
    var completed: usize = 0;
    var other: usize = 0;
    for (steps) |step| {
        if (std.mem.eql(u8, step.status, "pending")) pending += 1 else if (std.mem.eql(u8, step.status, "in_progress")) in_progress += 1 else if (std.mem.eql(u8, step.status, "completed")) completed += 1 else other += 1;
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"command\":\"plan_sync\",\"total_steps\":{d},\"pending\":{d},\"in_progress\":{d},\"completed\":{d},\"other\":{d}}}\n",
        .{ steps.len, pending, in_progress, completed, other },
    );
}

fn cmdSlice(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const input_path = try parseRequiredPath(args, "--input-json");
    const output_path = parseOptionalPath(args, "--output-json");
    const max_slices = parseOptionalUsize(args, "--max-slices") orelse std.math.maxInt(usize);

    const bytes = try std.fs.cwd().readFileAlloc(allocator, input_path, 16 * 1024 * 1024);
    const steps = try parsePlanSteps(allocator, bytes);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    try writer.writeAll("{\"command\":\"slice\",\"units\":[");

    var emitted: usize = 0;
    for (steps) |step| {
        if (!(std.mem.eql(u8, step.status, "pending") or std.mem.eql(u8, step.status, "in_progress"))) continue;
        if (emitted >= max_slices) break;

        if (emitted > 0) try writer.writeAll(",");
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "unit-{d:0>3}", .{emitted + 1});

        try writer.print(
            "{{\"id\":\"{s}\",\"objective\":",
            .{id},
        );
        try writeJsonString(writer, step.step);
        try writer.writeAll(",\"unit_scope\":\"unknown\",\"write_scope\":\"unknown\",\"constraints\":\"\",\"invariants\":\"\",\"proof_command\":\"\",\"risk_tier\":\"med\",\"base_sha\":\"HEAD\",\"delivery_mode\":\"patch_first\",\"attempt\":\"1\",\"variant\":\"baseline\",\"budget_tier\":\"unknown\"}");

        emitted += 1;
    }

    try writer.print("],\"unit_count\":{d}}}\n", .{emitted});

    if (output_path) |path| {
        try writeTextFile(path, out.items);
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(out.items);
}

fn cmdWave(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const units_path = try parseRequiredPath(args, "--units-json");
    const csv_path = try parseRequiredPath(args, "--csv-path");
    const max_active = parseOptionalUsize(args, "--max-active") orelse 1;
    const lane = parseOptionalLane(args, "--lane") orelse .coder;
    const triplet_width = parseOptionalUsize(args, "--triplet-width") orelse 3;

    if (triplet_width == 0 or triplet_width > 3) return error.InvalidTripletWidth;

    const units = try parseSliceUnits(allocator, units_path);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(allocator);
    var writer = csv.writer(allocator);

    try writer.writeAll("id,objective,unit_scope,write_scope,constraints,invariants,proof_command,risk_tier,candidate_id,triplet_index,lane,base_sha,delivery_mode,attempt,variant,budget_tier\n");

    var selected_units: usize = 0;
    var emitted_rows: usize = 0;
    var scopes = std.StringHashMap(void).init(allocator);
    defer scopes.deinit();

    for (units) |unit| {
        if (selected_units >= max_active) break;
        if (scopes.contains(unit.unit_scope)) continue;
        try scopes.put(unit.unit_scope, {});

        var idx: usize = 1;
        while (idx <= triplet_width) : (idx += 1) {
            var row_id_buf: [256]u8 = undefined;
            const row_id = try std.fmt.bufPrint(&row_id_buf, "{s}-{s}-{d}", .{ unit.id, laneString(lane), idx });
            var index_buf: [8]u8 = undefined;
            const index_text = try std.fmt.bufPrint(&index_buf, "{d}", .{idx});

            try writeCsvField(writer, row_id);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.objective);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.unit_scope);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.write_scope);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.constraints);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.invariants);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.proof_command);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.risk_tier);
            try writer.writeByte(',');
            try writeCsvField(writer, row_id);
            try writer.writeByte(',');
            try writeCsvField(writer, index_text);
            try writer.writeByte(',');
            try writeCsvField(writer, laneString(lane));
            try writer.writeByte(',');
            try writeCsvField(writer, unit.base_sha);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.delivery_mode);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.attempt);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.variant);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.budget_tier);
            try writer.writeByte('\n');

            emitted_rows += 1;
        }

        selected_units += 1;
    }

    try writeTextFile(csv_path, csv.items);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"command\":\"wave\",\"lane\":\"{s}\",\"triplet_width\":{d},\"units_in\":{d},\"units_selected\":{d},\"rows_emitted\":{d},\"csv_path\":",
        .{ laneString(lane), triplet_width, units.len, selected_units, emitted_rows },
    );
    try std.json.Stringify.value(csv_path, .{}, stdout);
    try stdout.writeAll("}\n");
}

fn cmdRunCsv(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const csv_path = try parseRequiredPath(args, "--csv-path");
    const output_csv_path = try parseRequiredPath(args, "--output-csv-path");
    const deps_csv_path = parseOptionalPath(args, "--deps-csv");
    const fail_on_floor = hasFlag(args, "--fail-on-floor");
    const floor_threshold = parseOptionalUsize(args, "--floor-threshold") orelse 3;
    const runnable_units_override = parseOptionalUsize(args, "--runnable-units");
    const max_concurrency = parseOptionalUsize(args, "--max-concurrency") orelse parseOptionalUsize(args, "--max-workers") orelse 0;

    if (floor_threshold == 0) return error.InvalidFloorThreshold;
    if (fail_on_floor and max_concurrency == 0) return error.MissingMaxConcurrencyForFloorGate;

    if (deps_csv_path) |path| {
        try validateDepsCsvPath(allocator, path);
    }

    if (!pathsAreDistinct(allocator, csv_path, output_csv_path)) {
        return error.CsvPathCollision;
    }

    const csv_bytes = try std.fs.cwd().readFileAlloc(allocator, csv_path, 16 * 1024 * 1024);
    var lines = std.mem.splitScalar(u8, csv_bytes, '\n');
    const header_line = lines.next() orelse return error.EmptyCsv;
    const headers = try parseHeaderColumns(allocator, header_line);

    if (!hasRequiredHeaders(headers, &RequiredCsvHeaders)) {
        return error.MissingRequiredHeaders;
    }

    const id_index = findHeaderIndex(headers, "id") orelse return error.MissingIdHeader;
    const candidate_id_index = findHeaderIndex(headers, "candidate_id") orelse return error.MissingCandidateIdHeader;
    const triplet_index_index = findHeaderIndex(headers, "triplet_index") orelse return error.MissingTripletIndexHeader;
    const lane_index = findHeaderIndex(headers, "lane") orelse return error.MissingRequiredHeaders;
    const write_scope_index = findHeaderIndex(headers, "write_scope") orelse return error.MissingRequiredHeaders;
    const risk_tier_index = findHeaderIndex(headers, "risk_tier") orelse return error.MissingRequiredHeaders;
    const base_sha_index = findHeaderIndex(headers, "base_sha") orelse return error.MissingRequiredHeaders;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var outw = output.writer(allocator);

    try outw.writeAll("id,candidate_id,triplet_index,lane,decision,proof_status,write_scope,risk_tier,base_sha,proof_attempts,proof_evidence\n");

    var row_count: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const id = nthCsvField(trimmed, id_index) orelse "";
        if (id.len == 0) continue;
        const candidate_id = nthCsvField(trimmed, candidate_id_index) orelse id;
        const triplet_index = nthCsvField(trimmed, triplet_index_index) orelse "1";
        const lane_raw = nthCsvField(trimmed, lane_index) orelse "coder";
        const lane = parseLane(lane_raw) catch return error.InvalidLane;
        const write_scope = nthCsvField(trimmed, write_scope_index) orelse "unknown";
        const risk_tier = nthCsvField(trimmed, risk_tier_index) orelse "med";
        const base_sha = nthCsvField(trimmed, base_sha_index) orelse "HEAD";

        try writeCsvField(outw, id);
        try outw.writeByte(',');
        try writeCsvField(outw, candidate_id);
        try outw.writeByte(',');
        try writeCsvField(outw, triplet_index);
        try outw.writeByte(',');
        try writeCsvField(outw, laneString(lane));
        try outw.writeAll(",queued,pending,");
        try writeCsvField(outw, write_scope);
        try outw.writeByte(',');
        try writeCsvField(outw, risk_tier);
        try outw.writeByte(',');
        try writeCsvField(outw, base_sha);
        try outw.writeAll(",0,");
        try writeCsvField(outw, "{\"command\":\"\",\"key_line\":\"\",\"exit_code\":0}");
        try outw.writeByte('\n');
        row_count += 1;
    }

    const runnable_units = runnable_units_override orelse row_count;
    const configured_concurrency = if (max_concurrency > 0) max_concurrency else row_count;
    const floor_decision = evaluateRunCsvFloor(configured_concurrency, runnable_units, floor_threshold);
    const deps_check_status = if (deps_csv_path != null) "pass" else "skipped";

    if (fail_on_floor and std.mem.eql(u8, floor_decision.result, "fail")) {
        return error.ConcurrencyFloorFailed;
    }

    try writeTextFile(output_csv_path, output.items);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{{\"command\":\"run_csv\",\"row_count\":{d},\"csv_path\":", .{row_count});
    try std.json.Stringify.value(csv_path, .{}, stdout);
    try stdout.print(",\"output_csv_path\":", .{});
    try std.json.Stringify.value(output_csv_path, .{}, stdout);
    try stdout.print(
        ",\"status\":\"prepared\",\"spawn_substrate\":\"spawn_agents_on_csv\",\"mesh_truth_verdict\":true,\"max_concurrency\":{d},\"runnable_units\":{d},\"effective_peak\":{d},\"floor_threshold\":{d},\"floor_applicable\":{s},\"floor_result\":",
        .{
            configured_concurrency,
            runnable_units,
            floor_decision.effective_peak,
            floor_threshold,
            if (floor_decision.applicable) "true" else "false",
        },
    );
    try std.json.Stringify.value(floor_decision.result, .{}, stdout);
    try stdout.print(",\"deps_check_status\":", .{});
    try std.json.Stringify.value(deps_check_status, .{}, stdout);
    try stdout.writeAll("}\n");
}

fn cmdLedger(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const input_path = try parseRequiredPath(args, "--input-json");
    const bytes = try std.fs.cwd().readFileAlloc(allocator, input_path, 16 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});

    if (parsed.value != .object) return error.LedgerInputMustBeObject;

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.print("{{\"command\":\"ledger\",\"events\":{{", .{});

    var first = true;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (!ledgerValueOccurred(value)) continue;

        if (!first) try stdout.print(",", .{});
        try std.json.Stringify.value(key, .{}, stdout);
        try stdout.print(":", .{});
        try std.json.Stringify.value(value, .{}, stdout);
        first = false;
    }

    try stdout.writeAll("}}}\n");
}

fn cmdOrchplanToUnits(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const orchplan_path = try parseRequiredPath(args, "--orchplan");
    const output_json_path = try parseRequiredPath(args, "--output-json");
    const format = parseOptionalPath(args, "--format") orelse "json";
    if (!std.mem.eql(u8, format, "json") and !std.mem.eql(u8, format, "quiet")) {
        return error.InvalidFormat;
    }

    const bytes = try std.fs.cwd().readFileAlloc(allocator, orchplan_path, 32 * 1024 * 1024);
    const tasks = try parseOrchplanTasks(allocator, bytes);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer warnings.deinit(allocator);
    var units: std.ArrayList(SliceUnit) = .empty;
    defer units.deinit(allocator);

    for (tasks) |task| {
        if (task.id.len == 0) continue;
        const title = if (task.title.len > 0) task.title else task.id;
        const risk_tier = normalizeRiskTier(task.risk_tier);

        const write_scope = if (task.scopes.len == 0) blk: {
            const msg = try std.fmt.allocPrint(
                allocator,
                "task {s}: missing scope; write_scope will be 'unknown' and parallelism will collapse",
                .{task.id},
            );
            try warnings.append(allocator, msg);
            break :blk "unknown";
        } else try std.mem.join(allocator, ";", task.scopes);

        const proof_command = if (task.validations.len > 0) task.validations[0] else blk: {
            const msg = try std.fmt.allocPrint(
                allocator,
                "task {s}: missing validation; proof_command is empty",
                .{task.id},
            );
            try warnings.append(allocator, msg);
            break :blk "";
        };

        try units.append(allocator, .{
            .id = task.id,
            .objective = title,
            .unit_scope = task.id,
            .write_scope = write_scope,
            .constraints = "",
            .invariants = "",
            .proof_command = proof_command,
            .risk_tier = risk_tier,
            .base_sha = "HEAD",
            .delivery_mode = "patch_first",
            .attempt = "1",
            .variant = "baseline",
            .budget_tier = "unknown",
        });
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const out_writer = out.writer(allocator);
    try writeUnitsPayloadJson(out_writer, units.items);
    try writeTextFile(output_json_path, out.items);

    if (std.mem.eql(u8, format, "quiet")) return;

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"command\":\"orchplan_to_units\",\"orchplan\":",
        .{},
    );
    try std.json.Stringify.value(orchplan_path, .{}, stdout);
    try stdout.print(",\"output_json\":", .{});
    try std.json.Stringify.value(output_json_path, .{}, stdout);
    try stdout.print(",\"unit_count\":{d},\"warnings\":[", .{units.items.len});
    for (warnings.items, 0..) |warning, idx| {
        if (idx > 0) try stdout.writeAll(",");
        try std.json.Stringify.value(warning, .{}, stdout);
    }
    try stdout.writeAll("]}\n");
}

fn cmdPrepareCrfipBatch(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const units_json_path = try parseRequiredPath(args, "--units-json");
    const max_active = parseOptionalUsize(args, "--max-active") orelse 6;
    const artifact_root = parseOptionalPath(args, "--artifact-root");
    const run_id = parseOptionalPath(args, "--run-id");
    const batch_name = parseOptionalPath(args, "--name") orelse "candidate";
    const max_concurrency = parseOptionalUsize(args, "--max-concurrency");
    const floor_threshold = parseOptionalUsize(args, "--floor-threshold") orelse 3;
    const fail_on_floor = hasFlag(args, "--fail-on-floor");
    const format = parseOptionalPath(args, "--format") orelse "json";
    if (!std.mem.eql(u8, format, "json") and !std.mem.eql(u8, format, "paths")) {
        return error.InvalidFormat;
    }

    const units = try parseSliceUnits(allocator, units_json_path);

    const resolved_root = if (artifact_root) |root| try expandPathWithHome(allocator, root) else try defaultArtifactRoot(allocator);
    const resolved_run_id = if (run_id) |rid| rid else try defaultRunId(allocator);
    const run_dir = try meshArtifactRunDir(allocator, resolved_root, resolved_run_id);
    const csv_path = try std.fmt.allocPrint(allocator, "{s}/{s}.csv", .{ run_dir, batch_name });
    const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.out.csv", .{ run_dir, batch_name });

    var warnings: std.ArrayList([]const u8) = .empty;
    defer warnings.deinit(allocator);
    const selected = try selectCrfipUnits(allocator, units, @max(@as(usize, 1), max_active), &warnings);
    try writeCrfipCandidateCsv(allocator, csv_path, selected);

    var run_csv_args: std.ArrayList([]const u8) = .empty;
    defer run_csv_args.deinit(allocator);
    try run_csv_args.appendSlice(allocator, &.{ "run_csv", "--csv-path", csv_path, "--output-csv-path", out_path });
    if (max_concurrency) |mc| {
        const mc_text = try std.fmt.allocPrint(allocator, "{d}", .{mc});
        try run_csv_args.appendSlice(allocator, &.{ "--max-concurrency", mc_text });
    }
    const floor_text = try std.fmt.allocPrint(allocator, "{d}", .{@max(@as(usize, 1), floor_threshold)});
    try run_csv_args.appendSlice(allocator, &.{ "--floor-threshold", floor_text });
    if (fail_on_floor) try run_csv_args.append(allocator, "--fail-on-floor");

    const run_csv_json = try runSelfJsonCommand(allocator, run_csv_args.items);

    if (std.mem.eql(u8, format, "paths")) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("{s}\n{s}\n", .{ csv_path, out_path });
        return;
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{{\"command\":\"prepare_crfip_batch\",\"run_dir\":", .{});
    try std.json.Stringify.value(run_dir, .{}, stdout);
    try stdout.print(",\"csv_path\":", .{});
    try std.json.Stringify.value(csv_path, .{}, stdout);
    try stdout.print(",\"output_csv_path\":", .{});
    try std.json.Stringify.value(out_path, .{}, stdout);
    try stdout.print(
        ",\"units_in\":{d},\"units_selected\":{d},\"rows_emitted\":{d},\"warnings\":[",
        .{ units.len, selected.len, selected.len * 2 },
    );
    for (warnings.items, 0..) |warning, idx| {
        if (idx > 0) try stdout.writeAll(",");
        try std.json.Stringify.value(warning, .{}, stdout);
    }
    try stdout.writeAll("],\"run_csv\":");
    try std.json.Stringify.value(run_csv_json, .{}, stdout);
    try stdout.writeAll("}\n");
}

fn cmdDoctor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var rollout_jsonl: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    var root = try defaultSessionsRoot(allocator);
    var expect_mesh_truth = false;
    var require_artifacts = false;
    var require_archived_paths = false;
    var artifact_root: ?[]const u8 = null;
    var lane_check: []const u8 = "crfip";
    var require_spawn_substrate = false;
    var format: []const u8 = "text";
    var exec_out_paths: std.ArrayList([]const u8) = .empty;
    defer exec_out_paths.deinit(allocator);
    var exec_out_globs: std.ArrayList([]const u8) = .empty;
    defer exec_out_globs.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rollout-jsonl")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            rollout_jsonl = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--session-id")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            session_id = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            root = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--expect-mesh-truth")) {
            expect_mesh_truth = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--require-artifacts")) {
            require_artifacts = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--require-archived-paths")) {
            require_archived_paths = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--artifact-root")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            artifact_root = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--lane-check")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            lane_check = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--require-spawn-substrate")) {
            require_spawn_substrate = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-out")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try exec_out_paths.append(allocator, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-out-glob")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try exec_out_globs.append(allocator, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            format = args[i];
            continue;
        }
        return error.UnknownFlag;
    }

    if ((rollout_jsonl == null and session_id == null) or (rollout_jsonl != null and session_id != null)) {
        return error.ExpectedRolloutOrSession;
    }
    if (!std.mem.eql(u8, lane_check, "skip") and !std.mem.eql(u8, lane_check, "crfip") and !std.mem.eql(u8, lane_check, "full")) {
        return error.InvalidLaneCheck;
    }
    if (!std.mem.eql(u8, format, "json") and !std.mem.eql(u8, format, "text")) return error.InvalidFormat;

    var seq_args: std.ArrayList([]const u8) = .empty;
    defer seq_args.deinit(allocator);
    try seq_args.appendSlice(allocator, &.{ "seq", "orchestration-concurrency" });
    if (rollout_jsonl) |path| {
        try seq_args.appendSlice(allocator, &.{ "--path", path });
    } else {
        try seq_args.appendSlice(allocator, &.{ "--root", root, "--session-id", session_id.? });
    }
    try seq_args.appendSlice(allocator, &.{ "--format", "json" });

    const seq_result = try runCommandCapture(allocator, seq_args.items, null);
    if (seq_result.exit_code != 0) return error.SeqCommandFailed;
    const seq_row = try parseFirstSeqRow(allocator, seq_result.stdout);

    const missing = jsonObjectGetInt(seq_row.object, "csv_rows_missing");
    const known = jsonObjectGetInt(seq_row.object, "csv_rows_known");
    const mesh_truth = jsonObjectGetBool(seq_row.object, "mesh_truth_verdict");
    const substrate = jsonObjectGetString(seq_row.object, "spawn_substrate");

    var errors: std.ArrayList([]const u8) = .empty;
    defer errors.deinit(allocator);
    if (expect_mesh_truth and !mesh_truth) {
        try appendLintError(allocator, &errors, "mesh_truth_verdict=false (spawn_substrate={s})", .{substrate});
    }
    if (require_artifacts and missing != 0) {
        try appendLintError(allocator, &errors, "csv_rows_missing={d} (known={d})", .{ missing, known });
    }

    var archived_paths_ok: ?bool = null;
    var spawn_pairs: []SpawnCsvPair = &.{};
    var archived_misses: std.ArrayList([]const u8) = .empty;
    defer archived_misses.deinit(allocator);
    var archived_missing_files: std.ArrayList([]const u8) = .empty;
    defer archived_missing_files.deinit(allocator);

    if (require_archived_paths) {
        const seq_rollout = jsonObjectGetString(seq_row.object, "path");
        if (seq_rollout.len == 0) {
            try appendLintError(allocator, &errors, "seq row missing rollout path; cannot validate archived paths", .{});
        } else {
            const root_path = if (artifact_root) |r| try expandPathWithHome(allocator, r) else try defaultArtifactRoot(allocator);
            spawn_pairs = try extractSpawnCsvPairs(allocator, seq_rollout);
            for (spawn_pairs) |pair| {
                const paths = [_][]const u8{ pair.csv_path, pair.output_csv_path };
                for (paths) |p| {
                    if (!isPathUnderRoot(allocator, root_path, p)) {
                        try archived_misses.append(allocator, p);
                    }
                    const expanded = try expandPathWithHome(allocator, p);
                    std.fs.cwd().access(expanded, .{}) catch {
                        try archived_missing_files.append(allocator, p);
                    };
                }
            }
            archived_paths_ok = archived_misses.items.len == 0;
            if (!(archived_paths_ok orelse false)) {
                try appendLintError(allocator, &errors, "spawn_agents_on_csv paths not under artifact root", .{});
            }
            if (archived_missing_files.items.len > 0) {
                try appendLintError(allocator, &errors, "spawn_agents_on_csv referenced csv files are missing", .{});
            }
        }
    }

    var lane_rc: u8 = 0;
    var lane_out: []const u8 = "";
    var lane_err: []const u8 = "";
    var expanded_exec_paths: std.ArrayList([]const u8) = .empty;
    defer expanded_exec_paths.deinit(allocator);

    if (!std.mem.eql(u8, lane_check, "skip")) {
        try expanded_exec_paths.appendSlice(allocator, exec_out_paths.items);
        if (exec_out_globs.items.len == 0) {
            const defaults = try expandSimpleGlob(allocator, ".mesh/*.exec.out.csv");
            try expanded_exec_paths.appendSlice(allocator, defaults);
        } else {
            for (exec_out_globs.items) |pattern| {
                const matches = try expandSimpleGlob(allocator, pattern);
                try expanded_exec_paths.appendSlice(allocator, matches);
            }
        }

        if (expanded_exec_paths.items.len > 0) {
            var lint_args: std.ArrayList([]const u8) = .empty;
            defer lint_args.deinit(allocator);
            try lint_args.appendSlice(allocator, &.{ "lane_completeness_lint", "--check", lane_check });
            if (require_spawn_substrate) try lint_args.append(allocator, "--require-spawn-substrate");
            try lint_args.appendSlice(allocator, expanded_exec_paths.items);
            const lint_result = try runSelfCommandCapture(allocator, lint_args.items);
            lane_rc = lint_result.exit_code;
            lane_out = std.mem.trim(u8, lint_result.stdout, " \t\r\n");
            lane_err = std.mem.trim(u8, lint_result.stderr, " \t\r\n");
            if (lane_rc != 0) try appendLintError(allocator, &errors, "lane_completeness_lint failed", .{});
        }
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    if (std.mem.eql(u8, format, "json")) {
        try stdout.writeAll("{\"command\":\"mesh_doctor\",\"seq\":");
        try std.json.Stringify.value(seq_row, .{}, stdout);
        try stdout.print(",\"archived_paths\":{{\"requested\":{s},\"ok\":", .{
            if (require_archived_paths) "true" else "false",
        });
        if (archived_paths_ok) |ok| {
            try stdout.writeAll(if (ok) "true" else "false");
        } else {
            try stdout.writeAll("null");
        }
        try stdout.print(",\"spawn_call_pairs\":{d},\"misses\":[", .{spawn_pairs.len});
        for (archived_misses.items, 0..) |miss, idx| {
            if (idx > 0) try stdout.writeAll(",");
            try std.json.Stringify.value(miss, .{}, stdout);
        }
        try stdout.writeAll("],\"missing_files\":[");
        for (archived_missing_files.items, 0..) |miss, idx| {
            if (idx > 0) try stdout.writeAll(",");
            try std.json.Stringify.value(miss, .{}, stdout);
        }
        try stdout.writeAll("]},\"lane_check\":{");
        try stdout.print("\"requested\":", .{});
        try std.json.Stringify.value(lane_check, .{}, stdout);
        try stdout.print(",\"exec_out_paths\":[", .{});
        for (expanded_exec_paths.items, 0..) |p, idx| {
            if (idx > 0) try stdout.writeAll(",");
            try std.json.Stringify.value(p, .{}, stdout);
        }
        try stdout.print("],\"returncode\":{d},\"stdout\":", .{lane_rc});
        try std.json.Stringify.value(lane_out, .{}, stdout);
        try stdout.print(",\"stderr\":", .{});
        try std.json.Stringify.value(lane_err, .{}, stdout);
        try stdout.writeAll("},\"errors\":[");
        for (errors.items, 0..) |msg, idx| {
            if (idx > 0) try stdout.writeAll(",");
            try std.json.Stringify.value(msg, .{}, stdout);
        }
        try stdout.writeAll("]}\n");
    } else {
        try stdout.writeAll("mesh doctor\n");
        try stdout.print(
            "- mesh_truth_verdict: {s} (spawn_substrate={s})\n",
            .{ if (mesh_truth) "true" else "false", if (substrate.len > 0) substrate else "-" },
        );
        try stdout.print("- artifacts: csv_rows_known={d} csv_rows_missing={d}\n", .{ known, missing });
        if (require_archived_paths) {
            const ok_text = if (archived_paths_ok == null) "unknown" else if (archived_paths_ok.?) "pass" else "fail";
            try stdout.print(
                "- archived_paths: {s} (spawn_pairs={d} misses={d})\n",
                .{ ok_text, spawn_pairs.len, archived_misses.items.len },
            );
            if (archived_missing_files.items.len > 0) {
                try stdout.print("- archived_paths: missing_files={d}\n", .{archived_missing_files.items.len});
            }
        }
        if (!std.mem.eql(u8, lane_check, "skip")) {
            try stdout.print("- lane_check: {s} (exec_out_paths={d})\n", .{ lane_check, expanded_exec_paths.items.len });
        }
        if (errors.items.len == 0) {
            try stdout.writeAll("- PASS\n");
        } else {
            for (errors.items) |msg| {
                try stdout.print("- FAIL: {s}\n", .{msg});
            }
        }
    }

    if (errors.items.len > 0) return error.MeshDoctorFailed;
}

fn cmdLaneCompletenessLint(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var check_raw: ?[]const u8 = null;
    var collapsed_ok = false;
    var require_spawn_substrate = false;
    var expected_spawn_substrate: []const u8 = "spawn_agents_on_csv";
    var deps_csv_paths: std.ArrayList([]const u8) = .empty;
    defer deps_csv_paths.deinit(allocator);
    var csv_paths: std.ArrayList([]const u8) = .empty;
    defer csv_paths.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            check_raw = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--collapsed-ok")) {
            collapsed_ok = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--require-spawn-substrate")) {
            require_spawn_substrate = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--expected-spawn-substrate")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            expected_spawn_substrate = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--deps-csv")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try deps_csv_paths.append(allocator, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownFlag;
        try csv_paths.append(allocator, arg);
    }

    if (check_raw == null) return error.MissingRequiredOption;
    if (csv_paths.items.len == 0) return error.MissingRequiredOption;
    const check = try parseLaneLintCheck(check_raw.?);

    var errors = try evaluateLaneLint(
        allocator,
        check,
        csv_paths.items,
        require_spawn_substrate,
        expected_spawn_substrate,
        deps_csv_paths.items,
    );
    defer errors.deinit(allocator);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    if (errors.items.len == 0) {
        try stdout.writeAll("lane_completeness_lint: PASS\n");
        return;
    }

    if (collapsed_ok) {
        try stdout.writeAll("lane_completeness_lint: WAIVED (collapsed path override)\n");
        for (errors.items) |msg| {
            try stdout.print("- {s}\n", .{msg});
        }
        return;
    }

    try stdout.writeAll("lane_completeness_lint: FAIL\n");
    for (errors.items) |msg| {
        try stdout.print("- {s}\n", .{msg});
    }
    return error.LaneCompletenessLintFailed;
}

fn cmdContractDriftLint(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const repo_root = parseOptionalPath(args, "--repo-root") orelse blk: {
        break :blk try std.process.getCwdAlloc(allocator);
    };

    const DriftRule = struct {
        rel_path: []const u8,
        snippets: []const []const u8,
    };
    const rules = [_]DriftRule{
        .{
            .rel_path = "codex/AGENTS.md",
            .snippets = &.{
                "mesh lane_completeness_lint",
                "mesh prepare_crfip_batch",
                "mesh doctor",
            },
        },
        .{
            .rel_path = "codex/skills/mesh/SKILL.md",
            .snippets = &.{
                "mesh orchplan_to_units",
                "mesh prepare_crfip_batch",
                "mesh lane_completeness_lint",
                "mesh doctor",
            },
        },
        .{
            .rel_path = "codex/skills/mesh/agents/openai.yaml",
            .snippets = &.{
                "mesh orchplan_to_units",
                "mesh prepare_crfip_batch",
                "mesh lane_completeness_lint",
                "mesh doctor",
            },
        },
        .{
            .rel_path = "codex/skills/mesh/references/output-contract.md",
            .snippets = &.{
                "Mesh Output Contract v2",
                "write_scope",
                "proof_evidence",
            },
        },
    };

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);

    for (rules) |rule| {
        const file_path = try std.fs.path.resolve(allocator, &.{ repo_root, rule.rel_path });
        defer allocator.free(file_path);

        const bytes = std.fs.cwd().readFileAlloc(allocator, file_path, 16 * 1024 * 1024) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "{s}: file missing ({s})", .{ rule.rel_path, @errorName(err) });
            try missing.append(allocator, msg);
            continue;
        };

        for (rule.snippets) |snippet| {
            if (std.mem.indexOf(u8, bytes, snippet) == null) {
                const msg = try std.fmt.allocPrint(allocator, "{s}: missing snippet -> {s}", .{ rule.rel_path, snippet });
                try missing.append(allocator, msg);
            }
        }
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    if (missing.items.len == 0) {
        try stdout.writeAll("contract_drift_lint: PASS\n");
        return;
    }

    try stdout.writeAll("contract_drift_lint: FAIL\n");
    for (missing.items) |msg| {
        try stdout.print("- {s}\n", .{msg});
    }
    return error.ContractDriftLintFailed;
}

fn cmdMigrationGate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var rollout_jsonl: ?[]const u8 = null;
    var format: []const u8 = "text";
    var exec_out_globs: std.ArrayList([]const u8) = .empty;
    defer exec_out_globs.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rollout-jsonl")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            rollout_jsonl = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-out-glob")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try exec_out_globs.append(allocator, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            format = args[i];
            continue;
        }
        return error.UnknownFlag;
    }
    if (rollout_jsonl == null) return error.MissingRequiredOption;
    if (!std.mem.eql(u8, format, "json") and !std.mem.eql(u8, format, "text")) return error.InvalidFormat;

    const drift_result = try runSelfCommandCapture(allocator, &.{"contract_drift_lint"});
    var doctor_args: std.ArrayList([]const u8) = .empty;
    defer doctor_args.deinit(allocator);
    try doctor_args.appendSlice(
        allocator,
        &.{
            "doctor",
            "--rollout-jsonl",
            rollout_jsonl.?,
            "--expect-mesh-truth",
            "--require-artifacts",
            "--require-archived-paths",
            "--lane-check",
            "crfip",
            "--require-spawn-substrate",
            "--format",
            "json",
        },
    );
    if (exec_out_globs.items.len == 0) {
        try doctor_args.appendSlice(allocator, &.{ "--exec-out-glob", ".mesh/*.exec.out.csv" });
    } else {
        for (exec_out_globs.items) |glob| {
            try doctor_args.appendSlice(allocator, &.{ "--exec-out-glob", glob });
        }
    }
    const doctor_result = try runSelfCommandCapture(allocator, doctor_args.items);
    const python_files = try findPythonFilesUnder(allocator, "codex/skills/mesh");

    var errors: std.ArrayList([]const u8) = .empty;
    defer errors.deinit(allocator);
    if (drift_result.exit_code != 0) {
        try appendLintError(allocator, &errors, "contract_drift_lint failed", .{});
    }
    if (doctor_result.exit_code != 0) {
        try appendLintError(allocator, &errors, "doctor failed", .{});
    }
    if (python_files.len > 0) {
        try appendLintError(allocator, &errors, "python files still present under codex/skills/mesh", .{});
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    if (std.mem.eql(u8, format, "json")) {
        try stdout.writeAll("{\"command\":\"migration_gate\",\"contract_drift\":{");
        try stdout.print("\"returncode\":{d},\"stdout\":", .{drift_result.exit_code});
        try std.json.Stringify.value(std.mem.trim(u8, drift_result.stdout, " \t\r\n"), .{}, stdout);
        try stdout.print(",\"stderr\":", .{});
        try std.json.Stringify.value(std.mem.trim(u8, drift_result.stderr, " \t\r\n"), .{}, stdout);
        try stdout.writeAll("},\"doctor\":{");
        try stdout.print("\"returncode\":{d},\"stdout\":", .{doctor_result.exit_code});
        try std.json.Stringify.value(std.mem.trim(u8, doctor_result.stdout, " \t\r\n"), .{}, stdout);
        try stdout.print(",\"stderr\":", .{});
        try std.json.Stringify.value(std.mem.trim(u8, doctor_result.stderr, " \t\r\n"), .{}, stdout);
        try stdout.writeAll("},\"python_files\":[");
        for (python_files, 0..) |p, idx| {
            if (idx > 0) try stdout.writeAll(",");
            try std.json.Stringify.value(p, .{}, stdout);
        }
        try stdout.writeAll("],\"errors\":[");
        for (errors.items, 0..) |msg, idx| {
            if (idx > 0) try stdout.writeAll(",");
            try std.json.Stringify.value(msg, .{}, stdout);
        }
        try stdout.writeAll("]}\n");
    } else {
        try stdout.writeAll("migration_gate\n");
        try stdout.print("- contract_drift_lint: rc={d}\n", .{drift_result.exit_code});
        try stdout.print("- doctor: rc={d}\n", .{doctor_result.exit_code});
        try stdout.print("- python_files: {d}\n", .{python_files.len});
        if (errors.items.len == 0) {
            try stdout.writeAll("- PASS\n");
        } else {
            for (errors.items) |msg| {
                try stdout.print("- FAIL: {s}\n", .{msg});
            }
        }
    }

    if (errors.items.len > 0) return error.MigrationGateFailed;
}

fn parseRequiredPath(args: []const []const u8, flag: []const u8) ![]const u8 {
    return parseOptionalPath(args, flag) orelse error.MissingRequiredOption;
}

fn parseOptionalPath(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 >= args.len) return null;
            return args[i + 1];
        }
    }
    return null;
}

fn parseOptionalUsize(args: []const []const u8, flag: []const u8) ?usize {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 >= args.len) return null;
            return std.fmt.parseUnsigned(usize, args[i + 1], 10) catch return null;
        }
    }
    return null;
}

fn parseOptionalLane(args: []const []const u8, flag: []const u8) ?Lane {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 >= args.len) return null;
            return parseLane(args[i + 1]) catch return null;
        }
    }
    return null;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn parseBool(raw: []const u8) !bool {
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) return true;
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) return false;
    return error.InvalidBoolean;
}

fn parseLane(raw: []const u8) !Lane {
    if (std.mem.eql(u8, raw, "coder")) return .coder;
    if (std.mem.eql(u8, raw, "reducer")) return .reducer;
    if (std.mem.eql(u8, raw, "locksmith")) return .locksmith;
    if (std.mem.eql(u8, raw, "applier")) return .applier;
    if (std.mem.eql(u8, raw, "prover")) return .prover;
    if (std.mem.eql(u8, raw, "fixer")) return .fixer;
    if (std.mem.eql(u8, raw, "integrator")) return .integrator;
    return error.InvalidLane;
}

const LaneLintCheck = enum {
    candidate,
    candidate_crfip,
    full,
    crfip,
};

const UnitLaneCounts = struct {
    coder: usize = 0,
    reducer: usize = 0,
    locksmith: usize = 0,
    applier: usize = 0,
    prover: usize = 0,
    fixer: usize = 0,
    integrator: usize = 0,
};

const FixerState = struct {
    decision: []const u8 = "",
    selected_candidate: []const u8 = "",
};

fn parseLaneLintCheck(raw: []const u8) !LaneLintCheck {
    if (std.mem.eql(u8, raw, "candidate")) return .candidate;
    if (std.mem.eql(u8, raw, "candidate_crfip")) return .candidate_crfip;
    if (std.mem.eql(u8, raw, "full")) return .full;
    if (std.mem.eql(u8, raw, "crfip")) return .crfip;
    return error.InvalidCheck;
}

fn appendLintError(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    try errors.append(allocator, msg);
}

fn csvFieldByName(headers: []const []const u8, line: []const u8, name: []const u8) []const u8 {
    const idx = findHeaderIndex(headers, name) orelse return "";
    return nthCsvField(line, idx) orelse "";
}

fn isKnownLaneName(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "coder") or
        std.mem.eql(u8, raw, "reducer") or
        std.mem.eql(u8, raw, "locksmith") or
        std.mem.eql(u8, raw, "applier") or
        std.mem.eql(u8, raw, "prover") or
        std.mem.eql(u8, raw, "fixer") or
        std.mem.eql(u8, raw, "integrator");
}

fn incrementLaneCount(unit: *UnitLaneCounts, lane: []const u8) void {
    if (std.mem.eql(u8, lane, "coder")) unit.coder += 1 else if (std.mem.eql(u8, lane, "reducer")) unit.reducer += 1 else if (std.mem.eql(u8, lane, "locksmith")) unit.locksmith += 1 else if (std.mem.eql(u8, lane, "applier")) unit.applier += 1 else if (std.mem.eql(u8, lane, "prover")) unit.prover += 1 else if (std.mem.eql(u8, lane, "fixer")) unit.fixer += 1 else if (std.mem.eql(u8, lane, "integrator")) unit.integrator += 1;
}

fn extractStringFromResultJson(
    allocator: std.mem.Allocator,
    raw_json: []const u8,
    key: []const u8,
) []const u8 {
    if (raw_json.len == 0) return "";
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return "";
    if (parsed.value != .object) return "";
    const v = parsed.value.object.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn extractFieldOrResultJson(
    allocator: std.mem.Allocator,
    headers: []const []const u8,
    line: []const u8,
    key: []const u8,
) []const u8 {
    const direct = csvFieldByName(headers, line, key);
    if (direct.len > 0) return std.mem.trim(u8, direct, " \t\r");
    const raw_json = csvFieldByName(headers, line, "result_json");
    const json_val = extractStringFromResultJson(allocator, raw_json, key);
    return std.mem.trim(u8, json_val, " \t\r");
}

fn keySetCoderOnly(lane_counts: *std.StringHashMap(usize)) bool {
    var it = lane_counts.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len == 0) continue;
        if (!std.mem.eql(u8, key, "coder")) return false;
    }
    return lane_counts.count() > 0;
}

fn evaluateLaneLint(
    allocator: std.mem.Allocator,
    check: LaneLintCheck,
    csv_paths: []const []const u8,
    require_spawn_substrate: bool,
    expected_spawn_substrate: []const u8,
    deps_csv_paths: []const []const u8,
) !std.ArrayList([]const u8) {
    var errors: std.ArrayList([]const u8) = .empty;

    var lane_counts: std.StringHashMap(usize) = .init(allocator);
    defer lane_counts.deinit();
    var units: std.StringHashMap(UnitLaneCounts) = .init(allocator);
    defer units.deinit();
    var fixer_states: std.StringHashMap(FixerState) = .init(allocator);
    defer fixer_states.deinit();

    for (csv_paths) |path| {
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024) catch |err| {
            try appendLintError(allocator, &errors, "{s}: read failed ({s})", .{ path, @errorName(err) });
            continue;
        };

        var lines_it = std.mem.splitScalar(u8, bytes, '\n');
        const header_line = lines_it.next() orelse {
            try appendLintError(allocator, &errors, "{s}: missing CSV header", .{path});
            continue;
        };
        const headers = try parseHeaderColumns(allocator, header_line);

        const needs_candidate = check == .candidate or check == .candidate_crfip;
        const missing_id = findHeaderIndex(headers, "id") == null;
        const missing_lane = findHeaderIndex(headers, "lane") == null;
        if (missing_id or missing_lane) {
            try appendLintError(allocator, &errors, "{s}: missing headers: id,lane", .{path});
            continue;
        }
        if (needs_candidate and findHeaderIndex(headers, "candidate_id") == null) {
            try appendLintError(allocator, &errors, "{s}: missing headers: candidate_id", .{path});
            continue;
        }
        if (needs_candidate and findHeaderIndex(headers, "triplet_index") == null) {
            try appendLintError(allocator, &errors, "{s}: missing headers: triplet_index", .{path});
            continue;
        }
        if (require_spawn_substrate and (check == .full or check == .crfip) and findHeaderIndex(headers, "spawn_substrate") == null) {
            try appendLintError(allocator, &errors, "{s}: missing headers: spawn_substrate", .{path});
            continue;
        }

        var row_count: usize = 0;
        var bad_spawn_ids: std.StringHashMap(void) = .init(allocator);
        defer bad_spawn_ids.deinit();

        while (lines_it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            row_count += 1;

            const id = std.mem.trim(u8, csvFieldByName(headers, line, "id"), " \t\r");
            const lane = std.mem.trim(u8, csvFieldByName(headers, line, "lane"), " \t\r");
            if (lane_counts.getPtr(lane)) |ptr| {
                ptr.* += 1;
            } else {
                try lane_counts.put(lane, 1);
            }

            if (id.len > 0) {
                const gop = try units.getOrPut(id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                incrementLaneCount(gop.value_ptr, lane);
            }

            if (check == .crfip and id.len > 0 and std.mem.eql(u8, lane, "fixer")) {
                const decision = extractFieldOrResultJson(allocator, headers, line, "decision");
                const selected = extractFieldOrResultJson(allocator, headers, line, "selected_candidate");
                try fixer_states.put(id, .{
                    .decision = decision,
                    .selected_candidate = selected,
                });
            }

            if (require_spawn_substrate and (check == .full or check == .crfip)) {
                const substrate = std.mem.trim(u8, csvFieldByName(headers, line, "spawn_substrate"), " \t\r");
                if (!std.mem.eql(u8, substrate, expected_spawn_substrate)) {
                    const key = if (id.len > 0) id else "<unknown>";
                    _ = try bad_spawn_ids.getOrPut(key);
                }
            }
        }

        if (row_count == 0) {
            try appendLintError(allocator, &errors, "{s}: no rows", .{path});
        }
        if (bad_spawn_ids.count() > 0) {
            var it_bad = bad_spawn_ids.keyIterator();
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(allocator);
            var first = true;
            while (it_bad.next()) |id_ptr| {
                if (!first) try joined.appendSlice(allocator, ", ");
                first = false;
                try joined.appendSlice(allocator, id_ptr.*);
            }
            try appendLintError(allocator, &errors, "{s}: spawn_substrate mismatch for ids: {s}", .{ path, joined.items });
        }
    }

    var it_lanes = lane_counts.iterator();
    while (it_lanes.next()) |entry| {
        const lane = entry.key_ptr.*;
        if (lane.len == 0) continue;
        if (!isKnownLaneName(lane)) {
            try appendLintError(allocator, &errors, "unknown lane values: {s}", .{lane});
        }
        if ((check == .candidate or check == .candidate_crfip) and !std.mem.eql(u8, lane, "coder") and !std.mem.eql(u8, lane, "reducer")) {
            try appendLintError(allocator, &errors, "{s}: candidate check expects only coder/reducer lanes", .{lane});
        }
    }

    if ((check == .full or check == .crfip) and keySetCoderOnly(&lane_counts)) {
        const msg = if (check == .full)
            "coder-only run detected (this is not lane-complete mesh orchestration)"
        else
            "coder-only run detected (this is not lane-complete CRFIP mesh orchestration)";
        try appendLintError(allocator, &errors, "{s}", .{msg});
    }

    var it_units = units.iterator();
    while (it_units.next()) |entry| {
        const unit_id = entry.key_ptr.*;
        const counts = entry.value_ptr.*;

        if (check == .candidate) {
            if (counts.coder < 2 or counts.reducer < 1) {
                try appendLintError(
                    allocator,
                    &errors,
                    "{s}: candidate cohort incomplete (need coder>=2 and reducer>=1; got coder={d}, reducer={d})",
                    .{ unit_id, counts.coder, counts.reducer },
                );
            }
            continue;
        }
        if (check == .candidate_crfip) {
            if (counts.coder < 1 or counts.reducer < 1) {
                try appendLintError(
                    allocator,
                    &errors,
                    "{s}: candidate cohort incomplete (need coder>=1 and reducer>=1; got coder={d}, reducer={d})",
                    .{ unit_id, counts.coder, counts.reducer },
                );
            }
            continue;
        }
        if (check == .full) {
            if (counts.coder < 2 or counts.reducer < 1) {
                try appendLintError(
                    allocator,
                    &errors,
                    "{s}: candidate cohort incomplete (need coder>=2 and reducer>=1; got coder={d}, reducer={d})",
                    .{ unit_id, counts.coder, counts.reducer },
                );
            }
            if (counts.locksmith == 0) try appendLintError(allocator, &errors, "{s}: missing lanes: locksmith", .{unit_id});
            if (counts.applier == 0) try appendLintError(allocator, &errors, "{s}: missing lanes: applier", .{unit_id});
            if (counts.prover == 0) try appendLintError(allocator, &errors, "{s}: missing lanes: prover", .{unit_id});
            if (counts.fixer == 0) try appendLintError(allocator, &errors, "{s}: missing lanes: fixer", .{unit_id});
            if (counts.integrator == 0) try appendLintError(allocator, &errors, "{s}: missing lanes: integrator", .{unit_id});
            continue;
        }

        if (counts.coder < 1 or counts.reducer < 1) {
            try appendLintError(
                allocator,
                &errors,
                "{s}: missing candidate lanes (need coder>=1 and reducer>=1; got coder={d}, reducer={d})",
                .{ unit_id, counts.coder, counts.reducer },
            );
        }
        if (counts.fixer < 1) {
            try appendLintError(allocator, &errors, "{s}: missing fixer lane", .{unit_id});
            continue;
        }

        const fs = fixer_states.get(unit_id) orelse FixerState{};
        if (fs.decision.len == 0) {
            try appendLintError(allocator, &errors, "{s}: fixer missing decision (expected decision=accepted|rework_required|blocked_safety)", .{unit_id});
            continue;
        }
        if (fs.selected_candidate.len == 0) {
            try appendLintError(allocator, &errors, "{s}: fixer missing selected_candidate (must be explicit; use selected_candidate=none for no-op)", .{unit_id});
            continue;
        }
        if (!std.mem.eql(u8, fs.decision, "accepted")) {
            try appendLintError(allocator, &errors, "{s}: fixer decision not accepted (got {s}); unit is not completion-eligible", .{ unit_id, fs.decision });
            continue;
        }
        if (std.mem.eql(u8, fs.selected_candidate, "none")) continue;
        if (counts.prover < 1) {
            try appendLintError(allocator, &errors, "{s}: missing prover lane for selected_candidate={s}", .{ unit_id, fs.selected_candidate });
        }
        if (counts.integrator < 1) {
            try appendLintError(allocator, &errors, "{s}: missing integrator lane for selected_candidate={s}", .{ unit_id, fs.selected_candidate });
        }
    }

    for (deps_csv_paths) |deps_path| {
        validateDepsCsvPath(allocator, deps_path) catch |err| {
            try appendLintError(allocator, &errors, "{s}: deps lint failed ({s})", .{ deps_path, @errorName(err) });
        };
    }

    return errors;
}

fn parseTruthy(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "true") or
        std.mem.eql(u8, raw, "1") or
        std.mem.eql(u8, raw, "yes") or
        std.mem.eql(u8, raw, "y") or
        std.mem.eql(u8, raw, "on");
}

fn evaluateRunCsvFloor(
    configured_concurrency: usize,
    runnable_units: usize,
    floor_threshold: usize,
) RunCsvFloorDecision {
    const effective_peak = @min(configured_concurrency, runnable_units);
    const applicable = runnable_units >= floor_threshold;
    const result = if (!applicable)
        "not_applicable"
    else if (effective_peak >= floor_threshold)
        "pass"
    else
        "fail";
    return .{
        .effective_peak = effective_peak,
        .applicable = applicable,
        .result = result,
    };
}

fn hasAnyDepToken(raw: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ',' or raw[i] == ';' or raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\r')) : (i += 1) {}
        if (i >= raw.len) break;
        var j = i;
        while (j < raw.len and raw[j] != ',' and raw[j] != ';') : (j += 1) {}
        const token = std.mem.trim(u8, raw[i..j], " \t\r");
        if (token.len > 0) return true;
        i = if (j < raw.len) j + 1 else j;
    }
    return false;
}

fn forEachDepToken(raw: []const u8, context: anytype, comptime cb: fn (@TypeOf(context), []const u8) anyerror!void) !void {
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ',' or raw[i] == ';' or raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\r')) : (i += 1) {}
        if (i >= raw.len) break;
        var j = i;
        while (j < raw.len and raw[j] != ',' and raw[j] != ';') : (j += 1) {}
        const token = std.mem.trim(u8, raw[i..j], " \t\r");
        if (token.len > 0) try cb(context, token);
        i = if (j < raw.len) j + 1 else j;
    }
}

fn validateDepsCsvPath(allocator: std.mem.Allocator, deps_csv_path: []const u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, deps_csv_path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    try validateDepsCsvBytes(allocator, bytes);
}

fn validateDepsCsvBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header_line = lines.next() orelse return error.EmptyDepsCsv;
    const headers = try parseHeaderColumns(allocator, header_line);
    defer allocator.free(headers);

    const id_index = findHeaderIndex(headers, "id") orelse return error.MissingDepsIdHeader;
    const depends_on_index = findHeaderIndex(headers, "depends_on");
    const interactive_lead_index = findHeaderIndex(headers, "interactive_lead");

    var rows: std.ArrayList(DepRow) = .empty;
    defer rows.deinit(allocator);

    var id_to_index = std.StringHashMap(usize).init(allocator);
    defer id_to_index.deinit();

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const id = nthCsvField(trimmed, id_index) orelse "";
        if (id.len == 0) return error.MissingDepsIdValue;
        if (id_to_index.contains(id)) return error.DuplicateDepsId;

        const deps_raw = if (depends_on_index) |idx| (nthCsvField(trimmed, idx) orelse "") else "";
        const interactive_raw = if (interactive_lead_index) |idx| (nthCsvField(trimmed, idx) orelse "") else "";
        const interactive = parseTruthy(interactive_raw);

        if (interactive and hasAnyDepToken(deps_raw)) {
            return error.InteractiveLeadBlockedByDeps;
        }

        try rows.append(allocator, .{
            .id = id,
            .deps_raw = deps_raw,
            .interactive_lead = interactive,
        });
        try id_to_index.put(id, rows.items.len - 1);
    }

    for (rows.items) |row| {
        const Ctx = struct {
            map: *std.StringHashMap(usize),
            pub fn check(self: @This(), token: []const u8) !void {
                if (!self.map.contains(token)) return error.UnknownDependencyId;
            }
        };
        const ctx = Ctx{ .map = &id_to_index };
        try forEachDepToken(row.deps_raw, ctx, Ctx.check);
    }

    const visit_state = try allocator.alloc(u8, rows.items.len);
    defer allocator.free(visit_state);
    @memset(visit_state, 0);

    const Dfs = struct {
        rows: []const DepRow,
        map: *std.StringHashMap(usize),
        state: []u8,
        fn visit(self: *@This(), idx: usize) !void {
            if (self.state[idx] == 2) return;
            if (self.state[idx] == 1) return error.DependencyCycleDetected;
            self.state[idx] = 1;

            var i: usize = 0;
            const deps_raw = self.rows[idx].deps_raw;
            while (i < deps_raw.len) {
                while (i < deps_raw.len and (deps_raw[i] == ',' or deps_raw[i] == ';' or deps_raw[i] == ' ' or deps_raw[i] == '\t' or deps_raw[i] == '\r')) : (i += 1) {}
                if (i >= deps_raw.len) break;
                var j = i;
                while (j < deps_raw.len and deps_raw[j] != ',' and deps_raw[j] != ';') : (j += 1) {}
                const token = std.mem.trim(u8, deps_raw[i..j], " \t\r");
                if (token.len > 0) {
                    const next_idx = self.map.get(token) orelse return error.UnknownDependencyId;
                    try self.visit(next_idx);
                }
                i = if (j < deps_raw.len) j + 1 else j;
            }
            self.state[idx] = 2;
        }
    };

    var dfs = Dfs{
        .rows = rows.items,
        .map = &id_to_index,
        .state = visit_state,
    };
    for (rows.items, 0..) |_, idx| {
        try dfs.visit(idx);
    }
}

fn parsePlanSteps(allocator: std.mem.Allocator, json_bytes: []const u8) ![]PlanStep {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});

    var steps: std.ArrayList(PlanStep) = .empty;

    if (parsed.value == .array) {
        try appendPlanStepsFromArray(allocator, &steps, parsed.value.array.items);
    } else if (parsed.value == .object) {
        if (parsed.value.object.get("plan")) |plan_value| {
            if (plan_value == .array) {
                try appendPlanStepsFromArray(allocator, &steps, plan_value.array.items);
            }
        }
    }

    return try steps.toOwnedSlice(allocator);
}

fn appendPlanStepsFromArray(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(PlanStep),
    entries: []const std.json.Value,
) !void {
    for (entries) |entry| {
        if (entry != .object) continue;
        const step_text = jsonStringField(entry.object, "step") orelse jsonStringField(entry.object, "title") orelse "untitled-step";
        const status = jsonStringField(entry.object, "status") orelse "pending";
        try steps.append(allocator, .{ .step = step_text, .status = status });
    }
}

fn parseSliceUnits(allocator: std.mem.Allocator, path: []const u8) ![]SliceUnit {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});

    if (parsed.value != .object) return error.InvalidUnitsJson;
    if (parsed.value.object.get("units") == null) return error.InvalidUnitsJson;

    const units_value = parsed.value.object.get("units").?;
    if (units_value != .array) return error.InvalidUnitsJson;

    var units: std.ArrayList(SliceUnit) = .empty;
    for (units_value.array.items) |entry| {
        if (entry != .object) continue;
        const id = jsonStringField(entry.object, "id") orelse continue;
        try units.append(allocator, .{
            .id = id,
            .objective = jsonStringField(entry.object, "objective") orelse "",
            .unit_scope = jsonStringField(entry.object, "unit_scope") orelse "unknown",
            .write_scope = jsonStringField(entry.object, "write_scope") orelse "unknown",
            .constraints = jsonStringField(entry.object, "constraints") orelse "",
            .invariants = jsonStringField(entry.object, "invariants") orelse "",
            .proof_command = jsonStringField(entry.object, "proof_command") orelse "",
            .risk_tier = jsonStringField(entry.object, "risk_tier") orelse "med",
            .base_sha = jsonStringField(entry.object, "base_sha") orelse "HEAD",
            .delivery_mode = jsonStringField(entry.object, "delivery_mode") orelse "patch_first",
            .attempt = jsonStringField(entry.object, "attempt") orelse "1",
            .variant = jsonStringField(entry.object, "variant") orelse "baseline",
            .budget_tier = jsonStringField(entry.object, "budget_tier") orelse "unknown",
        });
    }

    return try units.toOwnedSlice(allocator);
}

const OrchTask = struct {
    id: []const u8,
    title: []const u8,
    risk_tier: []const u8,
    scopes: []const []const u8,
    validations: []const []const u8,
};

fn normalizeRiskTier(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "low") or std.mem.eql(u8, raw, "med") or std.mem.eql(u8, raw, "high")) {
        return raw;
    }
    return "med";
}

fn writeUnitsPayloadJson(writer: anytype, units: []const SliceUnit) !void {
    try writer.writeAll("{\"command\":\"orchplan_to_units\",\"units\":[");
    for (units, 0..) |unit, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":");
        try writeJsonString(writer, unit.id);
        try writer.writeAll(",\"objective\":");
        try writeJsonString(writer, unit.objective);
        try writer.writeAll(",\"unit_scope\":");
        try writeJsonString(writer, unit.unit_scope);
        try writer.writeAll(",\"write_scope\":");
        try writeJsonString(writer, unit.write_scope);
        try writer.writeAll(",\"constraints\":");
        try writeJsonString(writer, unit.constraints);
        try writer.writeAll(",\"invariants\":");
        try writeJsonString(writer, unit.invariants);
        try writer.writeAll(",\"proof_command\":");
        try writeJsonString(writer, unit.proof_command);
        try writer.writeAll(",\"risk_tier\":");
        try writeJsonString(writer, unit.risk_tier);
        try writer.writeAll(",\"base_sha\":");
        try writeJsonString(writer, unit.base_sha);
        try writer.writeAll(",\"delivery_mode\":");
        try writeJsonString(writer, unit.delivery_mode);
        try writer.writeAll(",\"attempt\":");
        try writeJsonString(writer, unit.attempt);
        try writer.writeAll(",\"variant\":");
        try writeJsonString(writer, unit.variant);
        try writer.writeAll(",\"budget_tier\":");
        try writeJsonString(writer, unit.budget_tier);
        try writer.writeAll("}");
    }
    try writer.print("],\"unit_count\":{d}}}\n", .{units.len});
}

fn parseOrchplanTasks(allocator: std.mem.Allocator, bytes: []const u8) ![]OrchTask {
    if (parseOrchplanTasksFromJson(allocator, bytes)) |tasks| return tasks else |_| {}
    return parseOrchplanTasksFromYaml(allocator, bytes);
}

fn parseOrchplanTasksFromJson(allocator: std.mem.Allocator, bytes: []const u8) ![]OrchTask {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    if (parsed.value != .object) return error.InvalidOrchPlan;
    const tasks_value = parsed.value.object.get("tasks") orelse return error.InvalidOrchPlan;
    if (tasks_value != .array) return error.InvalidOrchPlan;

    var tasks: std.ArrayList(OrchTask) = .empty;
    for (tasks_value.array.items) |entry| {
        if (entry != .object) continue;
        const id = jsonStringField(entry.object, "id") orelse continue;
        const title = jsonStringField(entry.object, "title") orelse "";
        const risk_tier = jsonStringField(entry.object, "risk_tier") orelse "med";
        const scopes = try jsonStringListValue(allocator, entry.object.get("scope"));
        const validations = try jsonStringListValue(allocator, entry.object.get("validation"));
        try tasks.append(allocator, .{
            .id = id,
            .title = title,
            .risk_tier = risk_tier,
            .scopes = scopes,
            .validations = validations,
        });
    }
    if (tasks.items.len == 0) return error.InvalidOrchPlan;
    return try tasks.toOwnedSlice(allocator);
}

fn jsonStringListValue(
    allocator: std.mem.Allocator,
    value_opt: ?std.json.Value,
) ![]const []const u8 {
    const value = value_opt orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    switch (value) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s, " \t\r");
            if (trimmed.len > 0) try out.append(allocator, trimmed);
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .string) continue;
                const trimmed = std.mem.trim(u8, item.string, " \t\r");
                if (trimmed.len > 0) try out.append(allocator, trimmed);
            }
        },
        else => {},
    }
    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn parseOrchplanTasksFromYaml(allocator: std.mem.Allocator, bytes: []const u8) ![]OrchTask {
    const ActiveList = enum { none, scope, validation };
    const TaskBuilder = struct {
        id: []const u8 = "",
        title: []const u8 = "",
        risk_tier: []const u8 = "med",
        scopes: std.ArrayList([]const u8) = .empty,
        validations: std.ArrayList([]const u8) = .empty,
    };

    var tasks: std.ArrayList(OrchTask) = .empty;
    var current: ?TaskBuilder = null;
    var active: ActiveList = .none;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const no_comment = stripYamlComment(line_raw);
        const trimmed_line = std.mem.trim(u8, no_comment, " \t\r");
        if (trimmed_line.len == 0) continue;
        if (std.mem.eql(u8, trimmed_line, "tasks:")) continue;
        if (std.mem.startsWith(u8, trimmed_line, "kind:")) continue;

        if (std.mem.startsWith(u8, trimmed_line, "- id:")) {
            if (current) |*curr| {
                if (curr.id.len > 0) {
                    const scopes = if (curr.scopes.items.len == 0) &.{} else try curr.scopes.toOwnedSlice(allocator);
                    const validations = if (curr.validations.items.len == 0) &.{} else try curr.validations.toOwnedSlice(allocator);
                    try tasks.append(allocator, .{
                        .id = curr.id,
                        .title = curr.title,
                        .risk_tier = curr.risk_tier,
                        .scopes = scopes,
                        .validations = validations,
                    });
                }
            }
            current = TaskBuilder{};
            active = .none;
            if (current) |*curr| {
                curr.id = parseYamlScalar(trimmed_line["- id:".len..]);
            }
            continue;
        }

        if (current == null) continue;
        if (std.mem.startsWith(u8, trimmed_line, "- ") and active != .none) {
            const item = parseYamlScalar(trimmed_line[2..]);
            if (item.len > 0) {
                if (active == .scope) {
                    try current.?.scopes.append(allocator, item);
                } else {
                    try current.?.validations.append(allocator, item);
                }
            }
            continue;
        }

        const colon_idx = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed_line[0..colon_idx], " \t\r");
        const raw_val = trimmed_line[colon_idx + 1 ..];

        if (std.mem.eql(u8, key, "id")) {
            current.?.id = parseYamlScalar(raw_val);
            active = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "title")) {
            current.?.title = parseYamlScalar(raw_val);
            active = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "risk_tier")) {
            current.?.risk_tier = parseYamlScalar(raw_val);
            active = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "scope")) {
            active = .scope;
            const maybe_inline = std.mem.trim(u8, raw_val, " \t\r");
            if (maybe_inline.len > 0) {
                const inline_items = try parseYamlInlineList(allocator, maybe_inline);
                for (inline_items) |item| {
                    try current.?.scopes.append(allocator, item);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, key, "validation")) {
            active = .validation;
            const maybe_inline = std.mem.trim(u8, raw_val, " \t\r");
            if (maybe_inline.len > 0) {
                const inline_items = try parseYamlInlineList(allocator, maybe_inline);
                for (inline_items) |item| {
                    try current.?.validations.append(allocator, item);
                }
            }
            continue;
        }
    }

    if (current) |*curr| {
        if (curr.id.len > 0) {
            const scopes = if (curr.scopes.items.len == 0) &.{} else try curr.scopes.toOwnedSlice(allocator);
            const validations = if (curr.validations.items.len == 0) &.{} else try curr.validations.toOwnedSlice(allocator);
            try tasks.append(allocator, .{
                .id = curr.id,
                .title = curr.title,
                .risk_tier = curr.risk_tier,
                .scopes = scopes,
                .validations = validations,
            });
        }
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
        if (ch == '#' and !in_single and !in_double) {
            return line[0..idx];
        }
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
    var out: std.ArrayList([]const u8) = .empty;

    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        const body = trimmed[1 .. trimmed.len - 1];
        var it = std.mem.splitScalar(u8, body, ',');
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

fn expandPathWithHome(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return raw;
    if (raw[0] != '~') return raw;
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return raw;
    if (raw.len == 1) return home;
    if (raw[1] == '/') return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, raw[1..] });
    return raw;
}

fn defaultArtifactRoot(allocator: std.mem.Allocator) ![]const u8 {
    const env = std.process.getEnvVarOwned(allocator, "CODEX_MESH_ARTIFACT_ROOT") catch "";
    if (env.len > 0) return try expandPathWithHome(allocator, env);
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return ".codex/mesh-artifacts";
    return try std.fmt.allocPrint(allocator, "{s}/.codex/mesh-artifacts", .{home});
}

fn defaultRunId(allocator: std.mem.Allocator) ![]const u8 {
    const now = std.time.timestamp();
    return try std.fmt.allocPrint(allocator, "{d}", .{now});
}

fn meshArtifactRunDir(allocator: std.mem.Allocator, root: []const u8, run_id: []const u8) ![]const u8 {
    if (run_id.len >= 15 and run_id[8] == 'T') {
        return try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}/{s}/run-{s}",
            .{ root, run_id[0..4], run_id[4..6], run_id[6..8], run_id },
        );
    }
    return try std.fmt.allocPrint(allocator, "{s}/run-{s}", .{ root, run_id });
}

fn normalizeScopeToken(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
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

fn scopeRootsFromWriteScope(allocator: std.mem.Allocator, write_scope: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, write_scope, ",;");
    while (it.next()) |part| {
        const token = try normalizeScopeToken(allocator, part);
        if (token.len > 0) try out.append(allocator, token);
    }
    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn rootsOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (a.len > b.len and std.mem.startsWith(u8, a, b) and a[b.len] == '/') return true;
    if (b.len > a.len and std.mem.startsWith(u8, b, a) and b[a.len] == '/') return true;
    return false;
}

fn scopesOverlap(a: []const []const u8, b: []const []const u8) bool {
    for (a) |a_root| {
        for (b) |b_root| {
            if (rootsOverlap(a_root, b_root)) return true;
        }
    }
    return false;
}

fn selectCrfipUnits(
    allocator: std.mem.Allocator,
    units: []const SliceUnit,
    max_active: usize,
    warnings: *std.ArrayList([]const u8),
) ![]SliceUnit {
    var selected: std.ArrayList(SliceUnit) = .empty;
    var selected_roots: std.ArrayList([]const []const u8) = .empty;

    for (units) |unit| {
        if (selected.items.len >= max_active) break;
        if (unit.id.len == 0) continue;

        const roots = try scopeRootsFromWriteScope(allocator, unit.write_scope);
        var broad = roots.len == 0;
        for (roots) |root| {
            if (isBroadScopeToken(root)) {
                broad = true;
                break;
            }
        }
        if (broad) {
            if (selected.items.len > 0) continue;
            const msg = try std.fmt.allocPrint(
                allocator,
                "unit {s}: write_scope is missing/broad; selected alone",
                .{unit.id},
            );
            try warnings.append(allocator, msg);
            try selected.append(allocator, unit);
            try selected_roots.append(allocator, roots);
            continue;
        }

        var overlaps = false;
        for (selected_roots.items) |prior_roots| {
            if (scopesOverlap(roots, prior_roots)) {
                overlaps = true;
                break;
            }
        }
        if (overlaps) continue;
        try selected.append(allocator, unit);
        try selected_roots.append(allocator, roots);
    }

    return try selected.toOwnedSlice(allocator);
}

fn writeCrfipCandidateCsv(
    allocator: std.mem.Allocator,
    csv_path: []const u8,
    selected: []const SliceUnit,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.writeAll("id,objective,unit_scope,write_scope,constraints,invariants,proof_command,risk_tier,candidate_id,triplet_index,lane,base_sha,delivery_mode,attempt,variant,budget_tier\n");

    for (selected) |unit| {
        var coder_id_buf: [256]u8 = undefined;
        const coder_id = try std.fmt.bufPrint(&coder_id_buf, "{s}-coder-1", .{unit.id});
        var reducer_id_buf: [256]u8 = undefined;
        const reducer_id = try std.fmt.bufPrint(&reducer_id_buf, "{s}-reducer-2", .{unit.id});

        const rows = [_]struct { candidate_id: []const u8, triplet_index: []const u8, lane: []const u8 }{
            .{ .candidate_id = coder_id, .triplet_index = "1", .lane = "coder" },
            .{ .candidate_id = reducer_id, .triplet_index = "2", .lane = "reducer" },
        };
        for (rows) |row| {
            try writeCsvField(writer, unit.id);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.objective);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.unit_scope);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.write_scope);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.constraints);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.invariants);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.proof_command);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.risk_tier);
            try writer.writeByte(',');
            try writeCsvField(writer, row.candidate_id);
            try writer.writeByte(',');
            try writeCsvField(writer, row.triplet_index);
            try writer.writeByte(',');
            try writeCsvField(writer, row.lane);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.base_sha);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.delivery_mode);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.attempt);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.variant);
            try writer.writeByte(',');
            try writeCsvField(writer, unit.budget_tier);
            try writer.writeByte('\n');
        }
    }

    try writeTextFile(csv_path, out.items);
}

const CommandRunResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn runCommandCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !CommandRunResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (cwd) |cwd_path| child.cwd = cwd_path;
    try child.spawn();

    const out = try child.stdout.?.readToEndAlloc(allocator, 32 * 1024 * 1024);
    const err = try child.stderr.?.readToEndAlloc(allocator, 32 * 1024 * 1024);
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| @intCast(c),
        else => 1,
    };
    return .{ .exit_code = code, .stdout = out, .stderr = err };
}

fn runSelfJsonCommand(
    allocator: std.mem.Allocator,
    cmd_args: []const []const u8,
) !std.json.Value {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, cmd_args);

    const result = try runCommandCapture(allocator, argv.items, null);
    if (result.exit_code != 0) {
        return error.ChildCommandFailed;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    return parsed.value;
}

fn runSelfCommandCapture(
    allocator: std.mem.Allocator,
    cmd_args: []const []const u8,
) !CommandRunResult {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, cmd_args);
    return runCommandCapture(allocator, argv.items, null);
}

fn defaultSessionsRoot(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return "~/.codex/sessions";
    return try std.fmt.allocPrint(allocator, "{s}/.codex/sessions", .{home});
}

fn parseFirstSeqRow(allocator: std.mem.Allocator, raw: []const u8) !std.json.Value {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    if (parsed.value != .array or parsed.value.array.items.len == 0) return error.InvalidSeqJson;
    const first = parsed.value.array.items[0];
    if (first != .object) return error.InvalidSeqJson;
    return first;
}

fn jsonObjectGetString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        else => "",
    };
}

fn jsonObjectGetBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .integer => |n| n != 0,
        .float => |f| f != 0,
        .number_string => |s| !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "false"),
        .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
        else => false,
    };
}

fn jsonObjectGetInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        .bool => |b| if (b) 1 else 0,
        else => 0,
    };
}

const SpawnCsvPair = struct {
    csv_path: []const u8,
    output_csv_path: []const u8,
};

fn extractSpawnCsvPairs(
    allocator: std.mem.Allocator,
    rollout_jsonl: []const u8,
) ![]SpawnCsvPair {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, rollout_jsonl, 64 * 1024 * 1024);
    var out: std.ArrayList(SpawnCsvPair) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        if (parsed.value != .object) continue;
        const payload_v = parsed.value.object.get("payload") orelse continue;
        if (payload_v != .object) continue;
        const payload = payload_v.object;
        if (!std.mem.eql(u8, jsonObjectGetString(payload, "type"), "function_call")) continue;
        if (!std.mem.eql(u8, jsonObjectGetString(payload, "name"), "spawn_agents_on_csv")) continue;

        var args_obj: ?std.json.ObjectMap = null;
        if (payload.get("arguments")) |args_v| {
            switch (args_v) {
                .object => args_obj = args_v.object,
                .string => |raw_args| {
                    const args_parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_args, .{}) catch continue;
                    if (args_parsed.value == .object) args_obj = args_parsed.value.object;
                },
                else => {},
            }
        }
        const obj = args_obj orelse continue;
        const csv_path = jsonObjectGetString(obj, "csv_path");
        const out_path = jsonObjectGetString(obj, "output_csv_path");
        if (csv_path.len == 0 or out_path.len == 0) continue;
        try out.append(allocator, .{ .csv_path = csv_path, .output_csv_path = out_path });
    }
    return try out.toOwnedSlice(allocator);
}

fn isPathUnderRoot(
    allocator: std.mem.Allocator,
    root_path_raw: []const u8,
    candidate_raw: []const u8,
) bool {
    const root_path = expandPathWithHome(allocator, root_path_raw) catch return false;
    const candidate = expandPathWithHome(allocator, candidate_raw) catch return false;
    const cwd = std.process.getCwdAlloc(allocator) catch return false;
    const abs_root = std.fs.path.resolve(allocator, &.{ cwd, root_path }) catch return false;
    const abs_candidate = std.fs.path.resolve(allocator, &.{ cwd, candidate }) catch return false;
    if (!std.mem.startsWith(u8, abs_candidate, abs_root)) return false;
    if (abs_candidate.len == abs_root.len) return true;
    return abs_candidate[abs_root.len] == '/';
}

fn expandSimpleGlob(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return &.{pattern};
    }

    const slash_idx = std.mem.lastIndexOfScalar(u8, pattern, '/') orelse return &.{};
    const dir_path = if (slash_idx == 0) "." else pattern[0..slash_idx];
    const file_pat = pattern[slash_idx + 1 ..];
    const star_idx = std.mem.indexOfScalar(u8, file_pat, '*') orelse return &.{};
    const prefix = file_pat[0..star_idx];
    const suffix = file_pat[star_idx + 1 ..];

    var out: std.ArrayList([]const u8) = .empty;
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        try out.append(allocator, full);
    }
    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn findPythonFilesUnder(allocator: std.mem.Allocator, root_rel: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.fs.cwd().openDir(root_rel, .{ .iterate = true }) catch return &.{};
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".py")) continue;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_rel, entry.path });
        try out.append(allocator, full);
    }
    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn computeBudgetDecision(
    remaining_five_hour_raw: f64,
    remaining_weekly_raw: f64,
    max_threads_raw: usize,
    linear_start_threshold_raw: f64,
    single_agent_threshold_raw: f64,
    scaleout_threshold_raw: f64,
    previous_triplet_width_raw: usize,
    prior_wave_instability: bool,
    consecutive_unstable_waves: usize,
    consecutive_clean_waves: usize,
) BudgetDecision {
    const remaining_five_hour = clampPercent(remaining_five_hour_raw);
    const remaining_weekly = clampPercent(remaining_weekly_raw);
    const linear_start_threshold = clampPercent(linear_start_threshold_raw);
    const single_agent_threshold = clampPercent(single_agent_threshold_raw);
    const scaleout_threshold = clampPercent(scaleout_threshold_raw);
    const max_threads = @max(@as(usize, 1), max_threads_raw);

    const remaining_strict = @min(remaining_five_hour, remaining_weekly);

    var mode: BudgetMode = .full_fanout;
    var max_active_units: usize = max_threads;

    if (remaining_strict <= single_agent_threshold or linear_start_threshold <= single_agent_threshold) {
        mode = .single_agent;
        max_active_units = 1;
    } else if (remaining_strict <= linear_start_threshold) {
        mode = .linear_clamp;
        const span = linear_start_threshold - single_agent_threshold;
        const ratio = (remaining_strict - single_agent_threshold) / span;
        const scaled = @as(f64, @floatFromInt(max_threads)) * ratio;
        max_active_units = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(scaled))));
    }

    const triplet = computeTripletDecision(
        previous_triplet_width_raw,
        remaining_strict,
        prior_wave_instability,
        consecutive_unstable_waves,
        consecutive_clean_waves,
        15,
        10,
        20,
    );

    return .{
        .remaining_five_hour = remaining_five_hour,
        .remaining_weekly = remaining_weekly,
        .remaining_strict = remaining_strict,
        .linear_start_threshold = linear_start_threshold,
        .single_agent_threshold = single_agent_threshold,
        .scaleout_threshold = scaleout_threshold,
        .max_threads = max_threads,
        .max_active_units = max_active_units,
        .mode = mode,
        .cas_scaleout_allowed = remaining_strict > scaleout_threshold,
        .triplet_width = triplet.width,
        .triplet_degrade_reason = triplet.degrade_reason,
        .triplet_restored = triplet.restored,
    };
}

fn computeTripletDecision(
    previous_triplet_width_raw: usize,
    remaining_strict: f64,
    prior_wave_instability: bool,
    consecutive_unstable_waves: usize,
    consecutive_clean_waves: usize,
    low_threshold_raw: f64,
    critical_threshold_raw: f64,
    restore_threshold_raw: f64,
) TripletDecision {
    const low_threshold = clampPercent(low_threshold_raw);
    const critical_threshold = clampPercent(critical_threshold_raw);
    const restore_threshold = clampPercent(restore_threshold_raw);
    var width = std.math.clamp(previous_triplet_width_raw, 1, 3);
    var degrade_reason: []const u8 = "";
    var restored = false;

    if (remaining_strict <= critical_threshold or consecutive_unstable_waves >= 2) {
        width = 1;
        degrade_reason = if (remaining_strict <= critical_threshold) "budget_critical" else "two_unstable_waves";
    } else if (remaining_strict <= low_threshold or prior_wave_instability) {
        if (width > 2) width = 2;
        if (remaining_strict <= low_threshold and prior_wave_instability) {
            degrade_reason = "budget_low_and_instability";
        } else if (remaining_strict <= low_threshold) {
            degrade_reason = "budget_low";
        } else {
            degrade_reason = "prior_wave_instability";
        }
    } else if (width < 3 and remaining_strict > restore_threshold and consecutive_clean_waves >= 2) {
        width += 1;
        restored = true;
        degrade_reason = "restored_after_clean_waves";
    }

    return .{
        .width = width,
        .degrade_reason = degrade_reason,
        .restored = restored,
    };
}

fn budgetModeString(mode: BudgetMode) []const u8 {
    return switch (mode) {
        .full_fanout => "full_fanout",
        .linear_clamp => "linear_clamp",
        .single_agent => "single_agent",
    };
}

fn laneString(lane: Lane) []const u8 {
    return switch (lane) {
        .coder => "coder",
        .reducer => "reducer",
        .locksmith => "locksmith",
        .applier => "applier",
        .prover => "prover",
        .fixer => "fixer",
        .integrator => "integrator",
    };
}

fn roleInLane(lane: Lane, triplet_index: usize) []const u8 {
    if (lane != .integrator) return "";
    if (triplet_index == 1) return "writer";
    return "shadow";
}

fn quorumRule(lane: Lane) []const u8 {
    return switch (lane) {
        .coder => "adjudicate_one",
        .reducer => "adjudicate_one",
        .locksmith => "lease_single",
        .applier => "single_apply",
        .prover => "max_attempts=2",
        .fixer => "min_accept=2,no_blocker_reject",
        .integrator => "writer_pass,shadow_accepts=2",
    };
}

fn challengeTargets(lane: Lane, width: usize, self: usize) []const u8 {
    if (lane == .integrator or lane == .locksmith or lane == .applier or lane == .prover or width <= 1) return "";
    return switch (width) {
        1 => "",
        2 => if (self == 1) "2" else "1",
        3 => switch (self) {
            1 => "2;3",
            2 => "1;3",
            3 => "1;2",
            else => "",
        },
        else => "",
    };
}

fn clampPercent(value: f64) f64 {
    if (value < 0) return 0;
    if (value > 100) return 100;
    return value;
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn parseHeaderColumns(allocator: std.mem.Allocator, header_line: []const u8) ![][]const u8 {
    var cols: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, header_line, ',');
    while (it.next()) |col| {
        const trimmed = std.mem.trim(u8, col, " \t\r");
        try cols.append(allocator, trimmed);
    }
    return try cols.toOwnedSlice(allocator);
}

fn findHeaderIndex(headers: []const []const u8, needle: []const u8) ?usize {
    for (headers, 0..) |h, idx| {
        if (std.mem.eql(u8, h, needle)) return idx;
    }
    return null;
}

fn hasRequiredHeaders(headers: []const []const u8, required: []const []const u8) bool {
    for (required) |needle| {
        if (findHeaderIndex(headers, needle) == null) return false;
    }
    return true;
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
            if (current == idx) {
                return std.mem.trim(u8, line[field_start..i], " \t\r\"");
            }
            current += 1;
            field_start = i + 1;
        }
    }
    return null;
}

fn writeCsvField(writer: anytype, value: []const u8) !void {
    const needs_quote = std.mem.indexOfAny(u8, value, ",\"\n\r") != null;
    if (!needs_quote) {
        try writer.writeAll(value);
        return;
    }

    try writer.writeByte('"');
    for (value) |ch| {
        if (ch == '"') {
            try writer.writeAll("\"\"");
        } else {
            try writer.writeByte(ch);
        }
    }
    try writer.writeByte('"');
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\\\""),
            '\\' => try writer.writeAll("\\\\\\\\"),
            '\n' => try writer.writeAll("\\\\n"),
            '\r' => try writer.writeAll("\\\\r"),
            '\t' => try writer.writeAll("\\\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn writeTextFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.fs.cwd().makePath(dir);
    }
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn pathsAreDistinct(allocator: std.mem.Allocator, path_a: []const u8, path_b: []const u8) bool {
    const cwd = std.process.getCwdAlloc(allocator) catch return !std.mem.eql(u8, path_a, path_b);
    defer allocator.free(cwd);

    const abs_a = std.fs.path.resolve(allocator, &.{ cwd, path_a }) catch return !std.mem.eql(u8, path_a, path_b);
    defer allocator.free(abs_a);

    const abs_b = std.fs.path.resolve(allocator, &.{ cwd, path_b }) catch return !std.mem.eql(u8, path_a, path_b);
    defer allocator.free(abs_b);

    return !std.mem.eql(u8, abs_a, abs_b);
}

fn ledgerValueOccurred(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .bool => |b| b,
        .integer => |n| n > 0,
        .float => |f| f > 0,
        .number_string => |s| blk: {
            const parsed = std.fmt.parseFloat(f64, s) catch break :blk s.len > 0 and !std.mem.eql(u8, s, "0");
            break :blk parsed > 0;
        },
        .string => |s| s.len > 0 and !std.mem.eql(u8, s, "none"),
        .array => |arr| arr.items.len > 0,
        .object => |obj| obj.count() > 0,
    };
}

test "computeBudgetDecision enforces thresholds" {
    const full = computeBudgetDecision(90, 70, 12, 33, 10, 25, 3, false, 0, 0);
    try std.testing.expectEqual(.full_fanout, full.mode);
    try std.testing.expectEqual(@as(usize, 12), full.max_active_units);
    try std.testing.expect(full.cas_scaleout_allowed);
    try std.testing.expectEqual(@as(usize, 3), full.triplet_width);

    const linear = computeBudgetDecision(30, 28, 12, 33, 10, 25, 3, false, 0, 0);
    try std.testing.expectEqual(.linear_clamp, linear.mode);
    try std.testing.expect(linear.max_active_units >= 1);
    try std.testing.expectEqual(@as(usize, 3), linear.triplet_width);

    const single = computeBudgetDecision(9, 40, 12, 33, 10, 25, 3, false, 0, 0);
    try std.testing.expectEqual(.single_agent, single.mode);
    try std.testing.expectEqual(@as(usize, 1), single.max_active_units);
    try std.testing.expect(!single.cas_scaleout_allowed);
    try std.testing.expectEqual(@as(usize, 1), single.triplet_width);
    try std.testing.expectEqualStrings("budget_critical", single.triplet_degrade_reason);
}

test "computeTripletDecision degrades and restores by policy" {
    const instability = computeTripletDecision(3, 60, true, 0, 0, 15, 10, 20);
    try std.testing.expectEqual(@as(usize, 2), instability.width);
    try std.testing.expectEqualStrings("prior_wave_instability", instability.degrade_reason);
    try std.testing.expect(!instability.restored);

    const critical = computeTripletDecision(3, 8, false, 0, 0, 15, 10, 20);
    try std.testing.expectEqual(@as(usize, 1), critical.width);
    try std.testing.expectEqualStrings("budget_critical", critical.degrade_reason);
    try std.testing.expect(!critical.restored);

    const restored = computeTripletDecision(1, 45, false, 0, 2, 15, 10, 20);
    try std.testing.expectEqual(@as(usize, 2), restored.width);
    try std.testing.expectEqualStrings("restored_after_clean_waves", restored.degrade_reason);
    try std.testing.expect(restored.restored);
}

test "lane helper metadata follows triplet contract" {
    try std.testing.expectEqualStrings("coder", laneString(.coder));
    try std.testing.expectEqualStrings("reducer", laneString(.reducer));
    try std.testing.expectEqualStrings("locksmith", laneString(.locksmith));
    try std.testing.expectEqualStrings("applier", laneString(.applier));
    try std.testing.expectEqualStrings("prover", laneString(.prover));
    try std.testing.expectEqualStrings("writer", roleInLane(.integrator, 1));
    try std.testing.expectEqualStrings("shadow", roleInLane(.integrator, 2));
    try std.testing.expectEqualStrings("", roleInLane(.coder, 1));
    try std.testing.expectEqualStrings("", challengeTargets(.prover, 3, 1));
    try std.testing.expectEqualStrings("1;2", challengeTargets(.coder, 3, 3));
    try std.testing.expectEqualStrings("", challengeTargets(.integrator, 3, 1));
    try std.testing.expectEqualStrings("max_attempts=2", quorumRule(.prover));
    try std.testing.expectEqualStrings("writer_pass,shadow_accepts=2", quorumRule(.integrator));
    try std.testing.expectEqual(Lane.reducer, try parseLane("reducer"));
    try std.testing.expectEqual(Lane.locksmith, try parseLane("locksmith"));
}

test "hasRequiredHeaders validates required set" {
    const good = [_][]const u8{
        "id",
        "objective",
        "unit_scope",
        "write_scope",
        "constraints",
        "invariants",
        "proof_command",
        "risk_tier",
        "candidate_id",
        "triplet_index",
        "lane",
        "base_sha",
        "delivery_mode",
        "attempt",
        "variant",
        "budget_tier",
    };
    try std.testing.expect(hasRequiredHeaders(&good, &RequiredCsvHeaders));

    const bad = [_][]const u8{ "id", "objective", "unit_scope" };
    try std.testing.expect(!hasRequiredHeaders(&bad, &RequiredCsvHeaders));
}

test "parseOrchplanTasks supports json and yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json_input =
        \\{
        \\  "kind": "OrchPlan",
        \\  "tasks": [
        \\    {"id":"u1","title":"Unit 1","scope":["a/b"],"validation":["echo ok"],"risk_tier":"low"},
        \\    {"id":"u2","scope":"x/y"}
        \\  ]
        \\}
    ;
    const json_tasks = try parseOrchplanTasks(a, json_input);
    try std.testing.expectEqual(@as(usize, 2), json_tasks.len);
    try std.testing.expectEqualStrings("u1", json_tasks[0].id);
    try std.testing.expectEqualStrings("Unit 1", json_tasks[0].title);
    try std.testing.expectEqualStrings("low", json_tasks[0].risk_tier);
    try std.testing.expectEqualStrings("a/b", json_tasks[0].scopes[0]);

    const yaml_input =
        \\kind: OrchPlan
        \\tasks:
        \\  - id: u3
        \\    title: Unit 3
        \\    scope:
        \\      - m/n
        \\    validation:
        \\      - echo run
    ;
    const yaml_tasks = try parseOrchplanTasks(a, yaml_input);
    try std.testing.expectEqual(@as(usize, 1), yaml_tasks.len);
    try std.testing.expectEqualStrings("u3", yaml_tasks[0].id);
    try std.testing.expectEqualStrings("Unit 3", yaml_tasks[0].title);
    try std.testing.expectEqualStrings("m/n", yaml_tasks[0].scopes[0]);
    try std.testing.expectEqualStrings("echo run", yaml_tasks[0].validations[0]);
}

test "evaluateLaneLint enforces candidate_crfip lanes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pass_csv =
        \\id,objective,unit_scope,write_scope,constraints,invariants,proof_command,risk_tier,candidate_id,triplet_index,lane,base_sha,delivery_mode,attempt,variant,budget_tier
        \\u1,obj,u1,s1,,,,med,u1-coder-1,1,coder,HEAD,patch_first,1,baseline,unknown
        \\u1,obj,u1,s1,,,,med,u1-reducer-2,2,reducer,HEAD,patch_first,1,baseline,unknown
    ;
    try tmp.dir.writeFile(.{ .sub_path = "pass.csv", .data = pass_csv });
    const pass_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "pass.csv");
    defer std.testing.allocator.free(pass_abs);
    const pass_paths = [_][]const u8{pass_abs};
    var pass_errors = try evaluateLaneLint(
        a,
        .candidate_crfip,
        &pass_paths,
        false,
        "spawn_agents_on_csv",
        &.{},
    );
    defer pass_errors.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), pass_errors.items.len);

    const fail_csv =
        \\id,objective,unit_scope,write_scope,constraints,invariants,proof_command,risk_tier,candidate_id,triplet_index,lane,base_sha,delivery_mode,attempt,variant,budget_tier
        \\u1,obj,u1,s1,,,,med,u1-coder-1,1,coder,HEAD,patch_first,1,baseline,unknown
    ;
    try tmp.dir.writeFile(.{ .sub_path = "fail.csv", .data = fail_csv });
    const fail_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "fail.csv");
    defer std.testing.allocator.free(fail_abs);
    const fail_paths = [_][]const u8{fail_abs};
    var fail_errors = try evaluateLaneLint(
        a,
        .candidate_crfip,
        &fail_paths,
        false,
        "spawn_agents_on_csv",
        &.{},
    );
    defer fail_errors.deinit(a);
    try std.testing.expect(fail_errors.items.len > 0);
}

test "pathsAreDistinct rejects identical path" {
    try std.testing.expect(!pathsAreDistinct(std.testing.allocator, "./tmp/a.csv", "./tmp/a.csv"));
    try std.testing.expect(pathsAreDistinct(std.testing.allocator, "./tmp/a.csv", "./tmp/b.csv"));
}

test "evaluateRunCsvFloor returns pass fail and not_applicable" {
    const pass = evaluateRunCsvFloor(5, 5, 3);
    try std.testing.expect(pass.applicable);
    try std.testing.expectEqual(@as(usize, 5), pass.effective_peak);
    try std.testing.expectEqualStrings("pass", pass.result);

    const fail = evaluateRunCsvFloor(2, 4, 3);
    try std.testing.expect(fail.applicable);
    try std.testing.expectEqual(@as(usize, 2), fail.effective_peak);
    try std.testing.expectEqualStrings("fail", fail.result);

    const na = evaluateRunCsvFloor(8, 2, 3);
    try std.testing.expect(!na.applicable);
    try std.testing.expectEqual(@as(usize, 2), na.effective_peak);
    try std.testing.expectEqualStrings("not_applicable", na.result);
}

test "validateDepsCsvBytes enforces deadlock guards" {
    const valid =
        \\id,depends_on,interactive_lead
        \\u1,,true
        \\u2,u1,false
    ;
    try validateDepsCsvBytes(std.testing.allocator, valid);

    const interactive_blocked =
        \\id,depends_on,interactive_lead
        \\u1,u2,true
        \\u2,,false
    ;
    try std.testing.expectError(
        error.InteractiveLeadBlockedByDeps,
        validateDepsCsvBytes(std.testing.allocator, interactive_blocked),
    );

    const unknown_dep =
        \\id,depends_on,interactive_lead
        \\u1,u_missing,false
    ;
    try std.testing.expectError(
        error.UnknownDependencyId,
        validateDepsCsvBytes(std.testing.allocator, unknown_dep),
    );

    const cycle =
        \\id,depends_on,interactive_lead
        \\u1,u2,false
        \\u2,u1,false
    ;
    try std.testing.expectError(
        error.DependencyCycleDetected,
        validateDepsCsvBytes(std.testing.allocator, cycle),
    );
}

fn fuzzBudgetDecisionTarget(_: void, input: []const u8) !void {
    if (input.len < 4) return;

    const remaining_five_hour = @as(f64, @floatFromInt(input[0]));
    const remaining_weekly = @as(f64, @floatFromInt(input[1]));
    const max_threads = @max(@as(usize, 1), @as(usize, input[2] % 32));
    const previous_triplet_width = @as(usize, (input[3] % 3) + 1);

    const decision = computeBudgetDecision(remaining_five_hour, remaining_weekly, max_threads, 33, 10, 25, previous_triplet_width, false, 0, 0);
    try std.testing.expect(decision.max_active_units >= 1);
    try std.testing.expect(decision.max_active_units <= max_threads);
    try std.testing.expect(decision.triplet_width >= 1);
    try std.testing.expect(decision.triplet_width <= 3);
}

test "fuzz budget decision" {
    try std.testing.fuzz({}, fuzzBudgetDecisionTarget, .{});
}
