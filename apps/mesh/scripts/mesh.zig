const std = @import("std");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);

const UsageText =
    \\mesh.zig
    \\
    \\Marker: mesh.zig
    \\
    \\Plan-driven orchestration helpers for budget clamps, CSV-wave contracts, and event-only ledgers.
    \\
    \\usage: mesh {budget,plan_sync,slice,wave,run_csv,ledger,replay} [options]
    \\
    \\commands:
    \\  budget      Compute active-unit clamp from 5-hour + weekly remaining percentages
    \\  plan_sync   Summarize update_plan payload shape
    \\  slice       Derive atomic units from plan steps
    \\  wave        Emit a wave-template CSV from sliced units
    \\  run_csv     Validate a wave CSV and prepare output CSV path safely
    \\  ledger      Filter a ledger object down to occurred events only
    \\  replay      Simulate budget + wave sizing without execution
    \\
    \\global options:
    \\  -h, --help                 Show help
    \\  -V, --version | version    Show version
;

const RequiredCsvHeaders = [_][]const u8{
    "id",
    "objective",
    "unit_scope",
    "constraints",
    "invariants",
    "proof_command",
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
};

const PlanStep = struct {
    step: []const u8,
    status: []const u8,
};

const SliceUnit = struct {
    id: []const u8,
    objective: []const u8,
    unit_scope: []const u8,
    constraints: []const u8,
    invariants: []const u8,
    proof_command: []const u8,
    delivery_mode: []const u8,
    attempt: []const u8,
    variant: []const u8,
    budget_tier: []const u8,
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
    );

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    if (!format_json) {
        try stdout.print(
            "mode={s} strict_remaining={d:.2} max_active_units={d} cas_scaleout_allowed={s}\n",
            .{
                budgetModeString(decision.mode),
                decision.remaining_strict,
                decision.max_active_units,
                if (decision.cas_scaleout_allowed) "true" else "false",
            },
        );
        return;
    }

    try stdout.print(
        "{{\"command\":\"budget\",\"remaining_five_hour\":{d:.4},\"remaining_weekly\":{d:.4},\"remaining_strict\":{d:.4},\"linear_start_threshold\":{d:.4},\"single_agent_threshold\":{d:.4},\"scaleout_threshold\":{d:.4},\"max_threads\":{d},\"max_active_units\":{d},\"mode\":\"{s}\",\"cas_scaleout_allowed\":{s}}}\n",
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
        },
    );
}

fn cmdReplay(args: []const []const u8) !void {
    var remaining_five_hour: ?f64 = null;
    var remaining_weekly: ?f64 = null;
    var max_threads: usize = 12;
    var ready_units: ?usize = null;

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
        return error.UnknownFlag;
    }

    if (remaining_five_hour == null or remaining_weekly == null or ready_units == null) {
        return error.MissingRequiredOption;
    }

    const decision = computeBudgetDecision(remaining_five_hour.?, remaining_weekly.?, max_threads, 33, 10, 25);
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
        "{{\"command\":\"replay\",\"mode\":\"{s}\",\"max_active_units\":{d},\"ready_units\":{d},\"wave_count\":{d},\"waves\":[",
        .{ budgetModeString(decision.mode), decision.max_active_units, ready_units.?, wave_sizes.items.len },
    );
    for (wave_sizes.items, 0..) |n, idx| {
        if (idx > 0) try stdout.print(",", .{});
        try stdout.print("{d}", .{n});
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
        try writer.writeAll(",\"unit_scope\":\"unknown\",\"constraints\":\"\",\"invariants\":\"\",\"proof_command\":\"\",\"delivery_mode\":\"commit_first\",\"attempt\":\"1\",\"variant\":\"baseline\",\"budget_tier\":\"unknown\"}");

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

    const units = try parseSliceUnits(allocator, units_path);

    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(allocator);
    var writer = csv.writer(allocator);

    try writer.writeAll("id,objective,unit_scope,constraints,invariants,proof_command,delivery_mode,attempt,variant,budget_tier\n");

    var selected: usize = 0;
    var scopes = std.StringHashMap(void).init(allocator);
    defer scopes.deinit();

    for (units) |unit| {
        if (selected >= max_active) break;
        if (scopes.contains(unit.unit_scope)) continue;
        try scopes.put(unit.unit_scope, {});

        try writeCsvField(writer, unit.id);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.objective);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.unit_scope);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.constraints);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.invariants);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.proof_command);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.delivery_mode);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.attempt);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.variant);
        try writer.writeByte(',');
        try writeCsvField(writer, unit.budget_tier);
        try writer.writeByte('\n');

        selected += 1;
    }

    try writeTextFile(csv_path, csv.items);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"command\":\"wave\",\"units_in\":{d},\"units_selected\":{d},\"csv_path\":",
        .{ units.len, selected },
    );
    try std.json.Stringify.value(csv_path, .{}, stdout);
    try stdout.writeAll("}\n");
}

fn cmdRunCsv(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const csv_path = try parseRequiredPath(args, "--csv-path");
    const output_csv_path = try parseRequiredPath(args, "--output-csv-path");

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

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var outw = output.writer(allocator);

    try outw.writeAll("id,decision,proof_status,failure_code,notes\n");

    var row_count: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const id = nthCsvField(trimmed, id_index) orelse "";
        if (id.len == 0) continue;

        try writeCsvField(outw, id);
        try outw.writeAll(",queued,pending,,\n");
        row_count += 1;
    }

    try writeTextFile(output_csv_path, output.items);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{{\"command\":\"run_csv\",\"row_count\":{d},\"csv_path\":", .{row_count});
    try std.json.Stringify.value(csv_path, .{}, stdout);
    try stdout.print(",\"output_csv_path\":", .{});
    try std.json.Stringify.value(output_csv_path, .{}, stdout);
    try stdout.writeAll(",\"status\":\"prepared\"}\n");
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
            .constraints = jsonStringField(entry.object, "constraints") orelse "",
            .invariants = jsonStringField(entry.object, "invariants") orelse "",
            .proof_command = jsonStringField(entry.object, "proof_command") orelse "",
            .delivery_mode = jsonStringField(entry.object, "delivery_mode") orelse "commit_first",
            .attempt = jsonStringField(entry.object, "attempt") orelse "1",
            .variant = jsonStringField(entry.object, "variant") orelse "baseline",
            .budget_tier = jsonStringField(entry.object, "budget_tier") orelse "unknown",
        });
    }

    return try units.toOwnedSlice(allocator);
}

fn computeBudgetDecision(
    remaining_five_hour_raw: f64,
    remaining_weekly_raw: f64,
    max_threads_raw: usize,
    linear_start_threshold_raw: f64,
    single_agent_threshold_raw: f64,
    scaleout_threshold_raw: f64,
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
    };
}

fn budgetModeString(mode: BudgetMode) []const u8 {
    return switch (mode) {
        .full_fanout => "full_fanout",
        .linear_clamp => "linear_clamp",
        .single_agent => "single_agent",
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
    const full = computeBudgetDecision(90, 70, 12, 33, 10, 25);
    try std.testing.expectEqual(.full_fanout, full.mode);
    try std.testing.expectEqual(@as(usize, 12), full.max_active_units);
    try std.testing.expect(full.cas_scaleout_allowed);

    const linear = computeBudgetDecision(30, 28, 12, 33, 10, 25);
    try std.testing.expectEqual(.linear_clamp, linear.mode);
    try std.testing.expect(linear.max_active_units >= 1);

    const single = computeBudgetDecision(9, 40, 12, 33, 10, 25);
    try std.testing.expectEqual(.single_agent, single.mode);
    try std.testing.expectEqual(@as(usize, 1), single.max_active_units);
    try std.testing.expect(!single.cas_scaleout_allowed);
}

test "hasRequiredHeaders validates required set" {
    const good = [_][]const u8{ "id", "objective", "unit_scope", "constraints", "invariants", "proof_command", "delivery_mode", "attempt", "variant", "budget_tier" };
    try std.testing.expect(hasRequiredHeaders(&good, &RequiredCsvHeaders));

    const bad = [_][]const u8{ "id", "objective", "unit_scope" };
    try std.testing.expect(!hasRequiredHeaders(&bad, &RequiredCsvHeaders));
}

test "pathsAreDistinct rejects identical path" {
    try std.testing.expect(!pathsAreDistinct(std.testing.allocator, "./tmp/a.csv", "./tmp/a.csv"));
    try std.testing.expect(pathsAreDistinct(std.testing.allocator, "./tmp/a.csv", "./tmp/b.csv"));
}

fn fuzzBudgetDecisionTarget(_: void, input: []const u8) !void {
    if (input.len < 3) return;

    const remaining_five_hour = @as(f64, @floatFromInt(input[0]));
    const remaining_weekly = @as(f64, @floatFromInt(input[1]));
    const max_threads = @max(@as(usize, 1), @as(usize, input[2] % 32));

    const decision = computeBudgetDecision(remaining_five_hour, remaining_weekly, max_threads, 33, 10, 25);
    try std.testing.expect(decision.max_active_units >= 1);
    try std.testing.expect(decision.max_active_units <= max_threads);
}

test "fuzz budget decision" {
    try std.testing.fuzz({}, fuzzBudgetDecisionTarget, .{});
}
