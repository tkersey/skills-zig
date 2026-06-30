const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const LegacyStorePath = ".ledger/negative-ledger.jsonl";
const DefaultStorePath = ".ledger/negative-ledger/events.jsonl";
const MaxStoreBytes = 64 * 1024 * 1024;
const MaxInputBytes = 4 * 1024 * 1024;

const HelpText =
    \\ledger
    \\
    \\Durable negative-evidence ledger.
    \\
    \\usage: ledger {init,capture,query,map,status,reopen,export,compact,handoff,show,doctor,migrate} [options]
    \\
    \\commands:
    \\  init       Create the ledger store if missing
    \\  capture    Append witness-backed negative evidence from --json FILE|-
    \\  query      List projected records
    \\  map        Emit negative_route_gate for a route/cluster
    \\  status     Append a lifecycle status event
    \\  reopen     Mark a NEG record reopened
    \\  export     Emit a full or memory-note projection
    \\  compact    Report compaction candidates
    \\  handoff    Emit active exclusions for handoff
    \\  show       Show one NEG record by --id
    \\  doctor     Validate JSONL store integrity
    \\  migrate    Copy or move legacy .ledger/negative-ledger.jsonl into .ledger/negative-ledger/events.jsonl
    \\
    \\options:
    \\  --file PATH       Store path (default: .ledger/negative-ledger/events.jsonl)
    \\  --json PATH|-     Capture input JSON
    \\  --id NEG-ID       Record id for show/reopen/status/export
    \\  --to VALUE        Target status for status, target path for migrate
    \\  --from PATH       Legacy store path for migrate
    \\  --mode MODE       copy|move for migrate
    \\  --dry-run         Report migrate outcome without writing
    \\  --reason TEXT     Reason for status
    \\  --format FORMAT   full|memory-note for export
    \\  --cluster ID      Current route cluster for map
    \\  --route ID        Current route id/tag for map
    \\  --artifact ID     Current artifact state id for map
    \\  -h, --help        Show help
    \\  -V, --version     Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger",
    .help_text = HelpText,
};

const Command = enum {
    init,
    capture,
    query,
    map,
    status,
    reopen,
    @"export",
    compact,
    handoff,
    show,
    doctor,
    migrate,
};

const MigrationMode = enum {
    copy,
    move,
};

const Args = struct {
    command: Command,
    file: []const u8 = DefaultStorePath,
    migrate_from: []const u8 = LegacyStorePath,
    migrate_to: []const u8 = DefaultStorePath,
    migrate_mode: MigrationMode = .copy,
    dry_run: bool = false,
    json_path: ?[]const u8 = null,
    id: ?[]const u8 = null,
    to_status: ?[]const u8 = null,
    reason: []const u8 = "",
    format: []const u8 = "full",
    cluster: []const u8 = "",
    route: []const u8 = "",
    artifact: []const u8 = "",
};

const Record = struct {
    neg_id: []u8,
    status: []u8,
    hypothesis: []u8,
    route_id: []u8,
    cluster_id: []u8,
    artifact_state_id: []u8,
    exclusion_scope: []u8,
    exclusion_rule: []u8,
    failure_class: []u8,
    confidence: []u8,
    next_search_hint: []u8,
    record_json: []u8,
    source_refs_count: usize = 0,
    applicability_conditions_count: usize = 0,
    evidence_count: usize = 0,

    fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.neg_id);
        allocator.free(self.status);
        allocator.free(self.hypothesis);
        allocator.free(self.route_id);
        allocator.free(self.cluster_id);
        allocator.free(self.artifact_state_id);
        allocator.free(self.exclusion_scope);
        allocator.free(self.exclusion_rule);
        allocator.free(self.failure_class);
        allocator.free(self.confidence);
        allocator.free(self.next_search_hint);
        allocator.free(self.record_json);
    }
};

const CaptureResult = struct {
    neg_id: []u8,
    status: []u8,

    fn deinit(self: *CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.neg_id);
        allocator.free(self.status);
    }
};

const RouteGate = struct {
    active_match_index: ?usize = null,
    fuzzy_candidates: usize = 0,
};

const ValidationIssue = struct {
    issue_count: usize = 0,
    first_issue: ?[]const u8 = null,

    fn add(self: *ValidationIssue, message: []const u8) void {
        self.issue_count += 1;
        if (self.first_issue == null) self.first_issue = message;
    }

    fn ok(self: ValidationIssue) bool {
        return self.issue_count == 0;
    }
};

const LoadResult = struct {
    records: std.ArrayList(Record),
    validation: ValidationIssue = .{},

    fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        deinitRecords(allocator, &self.records);
    }
};

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try handleHelpAndVersion(allocator, argv)) return;

    const args = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    const code = run(allocator, args) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("ledger: {s}\n", .{@errorName(err)});
        return err;
    };
    std.process.exit(code);
}

fn handleHelpAndVersion(allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    if (argv.len <= 1) {
        try writeHelp(allocator);
        return true;
    }

    const first = argv[1];
    if (core_cli.isHelpArg(first)) {
        try writeHelp(allocator);
        return true;
    }
    if (core_cli.isVersionArg(first) or core_cli.isVersionSubcommand(first)) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try core_cli.printVersion(&out.writer, Version);
        try writeStdoutAlloc(allocator, &out);
        return true;
    }
    if (parseCommand(first) != null and core_cli.containsHelpArg(argv[2..])) {
        try writeHelp(allocator);
        return true;
    }
    return false;
}

fn writeHelp(allocator: std.mem.Allocator) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try core_cli.printHelpSurface(&out.writer, HelpSurface, Version);
    try writeStdoutAlloc(allocator, &out);
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 2) return error.MissingCommand;
    var args = Args{ .command = parseCommand(argv[1]) orelse return error.UnknownCommand };
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (std.mem.eql(u8, token, "--file")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.file = argv[i];
            args.migrate_to = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--from")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.migrate_from = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--mode")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (std.mem.eql(u8, argv[i], "copy")) {
                args.migrate_mode = .copy;
            } else if (std.mem.eql(u8, argv[i], "move")) {
                args.migrate_mode = .move;
            } else {
                return error.InvalidMigrationMode;
            }
            continue;
        }
        if (std.mem.eql(u8, token, "--dry-run")) {
            args.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--json")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.json_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--to")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (args.command == .migrate) {
                args.migrate_to = argv[i];
                args.file = argv[i];
            } else {
                args.to_status = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, token, "--reason")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.reason = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.format = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--cluster")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.cluster = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--route")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.route = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--artifact")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.artifact = argv[i];
            continue;
        }
        return error.UnknownOption;
    }
    if (args.command == .capture and args.json_path == null) return error.MissingJsonInput;
    if ((args.command == .show or args.command == .reopen or args.command == .status or args.command == .@"export") and args.id == null) return error.MissingId;
    if (args.command == .status and args.to_status == null) return error.MissingStatus;
    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn run(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.command) {
        .init => cmdInit(allocator, args.file),
        .capture => cmdCapture(allocator, args),
        .query => cmdQuery(allocator, args.file),
        .map => cmdMap(allocator, args),
        .status => cmdStatusEvent(allocator, args.file, args.id.?, args.to_status.?, args.reason, .status),
        .reopen => cmdStatusEvent(allocator, args.file, args.id.?, "reopened", "explicit reopen", .reopen),
        .@"export" => cmdExport(allocator, args),
        .compact => cmdCompact(allocator, args.file),
        .handoff => cmdHandoff(allocator, args.file),
        .show => cmdShow(allocator, args.file, args.id.?),
        .doctor => cmdDoctor(allocator, args.file),
        .migrate => cmdMigrate(allocator, args),
    };
}

fn cmdInit(allocator: std.mem.Allocator, path: []const u8) !u8 {
    if (!durable_store.fileExists(path)) {
        try durable_store.writeTextAtomic(std.heap.page_allocator, path, "");
        try durable_store.ensureLockSidecarGitignored(std.heap.page_allocator, path);
        try printJsonLine(allocator, .init, "initialized", path, 0);
        return 0;
    }
    try printJsonLine(allocator, .init, "already_initialized", path, 0);
    return 0;
}

fn cmdCapture(allocator: std.mem.Allocator, args: Args) !u8 {
    var result = try appendCapture(allocator, args);
    defer result.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"command\":\"capture\",\"neg_id\":", .{});
    try writeJsonString(&out.writer, result.neg_id);
    try out.writer.print(",\"status\":", .{});
    try writeJsonString(&out.writer, result.status);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn appendCapture(allocator: std.mem.Allocator, args: Args) !CaptureResult {
    const input = try readCaptureInput(allocator, args.json_path.?);
    defer allocator.free(input);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidCaptureJson,
    };
    try validateCaptureInput(obj);

    var lock = try durable_store.acquireLock(allocator, args.file);
    defer lock.release(allocator);

    var records = try loadRecords(allocator, args.file);
    defer deinitRecords(allocator, &records);
    const neg_id = if (jsonStringField(obj, "neg_id")) |id|
        try allocator.dupe(u8, id)
    else
        try nextNegIdAlloc(allocator, records.items);
    defer allocator.free(neg_id);
    if (findRecord(records.items, neg_id) != null) return error.DuplicateCaptureId;

    const requested_status = jsonStringField(obj, "status") orelse "active";
    const status = if (captureCanRequestStatus(obj, requested_status))
        requested_status
    else if (std.mem.eql(u8, requested_status, "active"))
        "need-evidence"
    else
        requested_status;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"v\":1,\"event\":\"capture\",\"neg_id\":");
    try writeJsonString(&out.writer, neg_id);
    try out.writer.writeAll(",\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"record\":");
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    try out.writer.writeByte('}');
    const line = try out.toOwnedSlice();
    defer allocator.free(line);
    try durable_store.appendLineAtomic(allocator, args.file, line, MaxStoreBytes);

    return .{
        .neg_id = try allocator.dupe(u8, neg_id),
        .status = try allocator.dupe(u8, status),
    };
}

fn cmdQuery(allocator: std.mem.Allocator, path: []const u8) !u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRecordsJson(&out.writer, records.items);
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn cmdShow(allocator: std.mem.Allocator, path: []const u8, neg_id: []const u8) !u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (records.items) |record| {
        if (std.mem.eql(u8, record.neg_id, neg_id)) {
            const fingerprint = try projectionFingerprintAlloc(allocator, record);
            defer allocator.free(fingerprint);
            try writeRecordJson(&out.writer, record, fingerprint);
            try out.writer.writeByte('\n');
            try writeStdoutAlloc(allocator, &out);
            return 0;
        }
    }
    try out.writer.print("{{\"command\":\"show\",\"id\":", .{});
    try writeJsonString(&out.writer, neg_id);
    try out.writer.writeAll(",\"found\":false}\n");
    try writeStdoutAlloc(allocator, &out);
    return 1;
}

fn cmdMap(allocator: std.mem.Allocator, args: Args) !u8 {
    if (args.route.len == 0 or args.cluster.len == 0 or args.artifact.len == 0) {
        try writeRouteGate(allocator, args, .{}, null, 3, false, "invalid_gate_input");
        return 3;
    }
    if (!durable_store.fileExists(args.file)) {
        try writeRouteGate(allocator, args, .{}, null, 3, false, "ledger_missing");
        return 3;
    }
    var loaded = try loadRecordsValidated(allocator, args.file);
    defer loaded.deinit(allocator);
    if (!loaded.validation.ok()) {
        try writeRouteGate(allocator, args, .{}, null, 3, true, "store_invalid");
        return 3;
    }

    const gate = evaluateRouteGate(loaded.records.items, args);
    const exit_code: u8 = if (gate.active_match_index != null) 2 else 0;
    try writeRouteGate(allocator, args, gate, loaded.records.items, exit_code, true, "none");
    return exit_code;
}

fn writeRouteGate(
    allocator: std.mem.Allocator,
    args: Args,
    gate: RouteGate,
    records: ?[]const Record,
    exit_code: u8,
    ledger_available: bool,
    failure: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const active_match = gate.active_match_index != null;
    try out.writer.writeAll("{\"negative_route_gate\":{\"checked\":true,\"query_or_map\":\"yes\",\"ledger_cli\":\"ledger\",\"store\":");
    try writeJsonString(&out.writer, args.file);
    try out.writer.writeAll(",\"command\":");
    try writeMapCommandJson(&out.writer, args);
    try out.writer.print(",\"exit_code\":{d},\"ledger_available\":{s},\"active_exclusion_match\":", .{
        exit_code,
        if (ledger_available) "true" else "false",
    });
    if (!ledger_available or exit_code == 3) {
        try out.writer.writeAll("null");
    } else {
        try out.writer.writeAll(if (active_match) "true" else "false");
    }
    try out.writer.writeAll(",\"exclusion_id\":");
    if (gate.active_match_index) |idx| {
        const source_records = records orelse return error.MissingGateRecords;
        try writeJsonString(&out.writer, source_records[idx].neg_id);
    } else {
        try writeJsonString(&out.writer, "none");
    }
    try out.writer.writeAll(",\"fuzzy_candidates\":");
    try out.writer.print("{d}", .{gate.fuzzy_candidates});
    try out.writer.writeAll(",\"fuzzy_authority\":");
    try writeJsonString(&out.writer, if (ledger_available) "suggest_only" else "none");
    try out.writer.writeAll(",\"failure\":");
    try writeJsonString(&out.writer, failure);
    try out.writer.writeAll(",\"handoff_allowed\":");
    try out.writer.writeAll(if (exit_code == 0) "true" else "false");
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeMapCommandJson(writer: anytype, args: Args) !void {
    try writer.writeByte('"');
    try writer.writeAll("ledger map --route ");
    try writeJsonEscapedBare(writer, args.route);
    try writer.writeAll(" --cluster ");
    try writeJsonEscapedBare(writer, args.cluster);
    try writer.writeAll(" --artifact ");
    try writeJsonEscapedBare(writer, args.artifact);
    try writer.writeByte('"');
}

fn mapStatusForStore(allocator: std.mem.Allocator, args: Args) !u8 {
    if (args.route.len == 0 or args.cluster.len == 0 or args.artifact.len == 0) return 3;
    if (!durable_store.fileExists(args.file)) return 3;
    var loaded = try loadRecordsValidated(allocator, args.file);
    defer loaded.deinit(allocator);
    if (!loaded.validation.ok()) return 3;
    const gate = evaluateRouteGate(loaded.records.items, args);
    return if (gate.active_match_index != null) 2 else 0;
}

fn evaluateRouteGate(records: []const Record, args: Args) RouteGate {
    var gate = RouteGate{};
    for (records, 0..) |record, idx| {
        const exact_route = args.route.len > 0 and record.route_id.len > 0 and std.mem.eql(u8, args.route, record.route_id);
        const exact_cluster = args.cluster.len > 0 and record.cluster_id.len > 0 and std.mem.eql(u8, args.cluster, record.cluster_id) and std.mem.eql(u8, record.exclusion_scope, "cluster");
        const artifact_ok = args.artifact.len == 0 or record.artifact_state_id.len == 0 or std.mem.eql(u8, args.artifact, record.artifact_state_id);
        if (recordCanBlock(record) and (exact_route or exact_cluster) and artifact_ok) {
            gate.active_match_index = idx;
            return gate;
        }
        if (lexicalOverlap(args.route, record.route_id) or lexicalOverlap(args.cluster, record.cluster_id)) gate.fuzzy_candidates += 1;
    }
    return gate;
}

fn cmdStatusEvent(allocator: std.mem.Allocator, path: []const u8, neg_id: []const u8, status: []const u8, reason: []const u8, command: Command) !u8 {
    if (!isKnownStatus(status)) return error.InvalidStatus;
    if (reason.len == 0) return error.MissingReason;
    var lock = try durable_store.acquireLock(allocator, path);
    defer lock.release(allocator);

    var loaded = try loadRecordsValidated(allocator, path);
    defer loaded.deinit(allocator);
    if (findRecord(loaded.records.items, neg_id) == null) {
        var missing: std.Io.Writer.Allocating = .init(allocator);
        defer missing.deinit();
        try missing.writer.writeAll("{\"command\":\"reopen\",\"id\":");
        try writeJsonString(&missing.writer, neg_id);
        try missing.writer.writeAll(",\"found\":false}\n");
        try writeStdoutAlloc(allocator, &missing);
        return 1;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"v\":2,\"event\":\"status\",\"neg_id\":");
    try writeJsonString(&out.writer, neg_id);
    try out.writer.writeAll(",\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"reason\":");
    try writeJsonString(&out.writer, reason);
    try out.writer.writeByte('}');
    const line = try out.toOwnedSlice();
    defer allocator.free(line);
    try durable_store.appendLineAtomic(allocator, path, line, MaxStoreBytes);
    try printJsonLine(allocator, command, status, neg_id, 0);
    return 0;
}

fn cmdExport(allocator: std.mem.Allocator, args: Args) !u8 {
    var records = try loadRecords(allocator, args.file);
    defer deinitRecords(allocator, &records);
    const idx = findRecord(records.items, args.id.?) orelse return error.NotFound;
    const record = records.items[idx];
    const exported_at = try nowUtcAlloc(allocator);
    defer allocator.free(exported_at);
    const fingerprint = try projectionFingerprintAlloc(allocator, record);
    defer allocator.free(fingerprint);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (std.mem.eql(u8, args.format, "full")) {
        try writeFullProjection(allocator, &out.writer, args.file, record, fingerprint, exported_at);
    } else if (std.mem.eql(u8, args.format, "memory-note")) {
        try writeLedgerMemoryNoteInput(allocator, &out.writer, args.file, record, fingerprint);
    } else {
        return error.InvalidFormat;
    }
    try out.writer.writeByte('\n');
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn cmdCompact(allocator: std.mem.Allocator, path: []const u8) !u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    try printJsonLine(allocator, .compact, "no_compaction_performed", path, records.items.len);
    return 0;
}

fn cmdHandoff(allocator: std.mem.Allocator, path: []const u8) !u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    var active = std.ArrayList(Record).empty;
    defer active.deinit(allocator);
    for (records.items) |record| {
        if (recordCanBlock(record)) try active.append(allocator, record);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRecordsJson(&out.writer, active.items);
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn cmdDoctor(allocator: std.mem.Allocator, path: []const u8) !u8 {
    const jsonl_result = try durable_store.validateJsonl(allocator, path, MaxStoreBytes);
    var loaded = try loadRecordsValidated(allocator, path);
    defer loaded.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const ok = jsonl_result.ok() and loaded.validation.ok();
    try out.writer.print("{{\"command\":\"doctor\",\"ok\":{s},\"records\":{d},\"blank_lines\":{d},\"issues\":{d}", .{
        if (ok) "true" else "false",
        loaded.records.items.len,
        jsonl_result.blank_lines,
        loaded.validation.issue_count + if (jsonl_result.ok()) @as(usize, 0) else @as(usize, 1),
    });
    if (jsonl_result.first_issue) |issue| {
        try out.writer.print(",\"first_issue\":{{\"line\":{d},\"message\":", .{issue.line});
        try writeJsonString(&out.writer, issue.message);
        try out.writer.writeAll("}");
    } else if (loaded.validation.first_issue) |message| {
        try out.writer.writeAll(",\"first_issue\":{\"line\":0,\"message\":");
        try writeJsonString(&out.writer, message);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return if (ok) 0 else 1;
}

fn cmdMigrate(allocator: std.mem.Allocator, args: Args) !u8 {
    const source_bytes = durable_store.readRegularFileNoSymlink(allocator, args.migrate_from, MaxStoreBytes) catch |err| {
        try printMigrationFailure(allocator, args.migrate_from, args.migrate_to, "source_unreadable", @errorName(err));
        return 1;
    };
    defer allocator.free(source_bytes);

    var source_loaded = loadRecordsValidated(allocator, args.migrate_from) catch |err| {
        try printMigrationFailure(allocator, args.migrate_from, args.migrate_to, "invalid_source_jsonl", @errorName(err));
        return 1;
    };
    defer source_loaded.deinit(allocator);
    if (!source_loaded.validation.ok()) {
        try printMigrationFailure(allocator, args.migrate_from, args.migrate_to, "invalid_source_jsonl", source_loaded.validation.first_issue orelse "validation failed");
        return 1;
    }
    const source_sha = try sha256HexAlloc(allocator, source_bytes);
    defer allocator.free(source_sha);

    if (args.dry_run) {
        try printMigrationResult(allocator, .{
            .status = "would_migrate",
            .from = args.migrate_from,
            .to = args.migrate_to,
            .mode = migrationModeText(args.migrate_mode),
            .records = source_loaded.records.items.len,
            .source_sha256 = source_sha,
            .target_sha256 = source_sha,
            .legacy_left_in_place = true,
        });
        return 0;
    }

    if (durable_store.fileExists(args.migrate_to)) {
        const target_bytes = durable_store.readRegularFileNoSymlink(allocator, args.migrate_to, MaxStoreBytes) catch |err| {
            try printMigrationFailure(allocator, args.migrate_from, args.migrate_to, "target_unreadable", @errorName(err));
            return 1;
        };
        defer allocator.free(target_bytes);
        if (!std.mem.eql(u8, source_bytes, target_bytes)) {
            try printMigrationFailure(allocator, args.migrate_from, args.migrate_to, "target_exists_with_different_bytes", "refusing to overwrite existing target");
            return 1;
        }
        try maybeRemoveLegacy(args);
        try printMigrationResult(allocator, .{
            .status = "already_migrated",
            .from = args.migrate_from,
            .to = args.migrate_to,
            .mode = migrationModeText(args.migrate_mode),
            .records = source_loaded.records.items.len,
            .source_sha256 = source_sha,
            .target_sha256 = source_sha,
            .legacy_left_in_place = args.migrate_mode == .copy,
        });
        return 0;
    }

    try durable_store.writeTextCreateNew(allocator, args.migrate_to, source_bytes, .{ .reject_symlinks = true });
    try maybeRemoveLegacy(args);
    try printMigrationResult(allocator, .{
        .status = "migrated",
        .from = args.migrate_from,
        .to = args.migrate_to,
        .mode = migrationModeText(args.migrate_mode),
        .records = source_loaded.records.items.len,
        .source_sha256 = source_sha,
        .target_sha256 = source_sha,
        .legacy_left_in_place = args.migrate_mode == .copy,
    });
    return 0;
}

const MigrationPrint = struct {
    status: []const u8,
    from: []const u8,
    to: []const u8,
    mode: []const u8,
    records: usize,
    source_sha256: []const u8,
    target_sha256: []const u8,
    legacy_left_in_place: bool,
};

fn printMigrationResult(allocator: std.mem.Allocator, result: MigrationPrint) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"command\":\"migrate\",\"status\":");
    try writeJsonString(&out.writer, result.status);
    try out.writer.writeAll(",\"from\":");
    try writeJsonString(&out.writer, result.from);
    try out.writer.writeAll(",\"to\":");
    try writeJsonString(&out.writer, result.to);
    try out.writer.writeAll(",\"mode\":");
    try writeJsonString(&out.writer, result.mode);
    try out.writer.print(",\"records\":{d},\"source_sha256\":", .{result.records});
    try writeJsonString(&out.writer, result.source_sha256);
    try out.writer.writeAll(",\"target_sha256\":");
    try writeJsonString(&out.writer, result.target_sha256);
    try out.writer.print(",\"legacy_left_in_place\":{s}}}\n", .{if (result.legacy_left_in_place) "true" else "false"});
    try writeStdoutAlloc(allocator, &out);
}

fn printMigrationFailure(allocator: std.mem.Allocator, from_path: []const u8, to_path: []const u8, reason: []const u8, detail: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"command\":\"migrate\",\"status\":\"failed\",\"reason\":");
    try writeJsonString(&out.writer, reason);
    try out.writer.writeAll(",\"detail\":");
    try writeJsonString(&out.writer, detail);
    try out.writer.writeAll(",\"from\":");
    try writeJsonString(&out.writer, from_path);
    try out.writer.writeAll(",\"to\":");
    try writeJsonString(&out.writer, to_path);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn migrationModeText(mode: MigrationMode) []const u8 {
    return switch (mode) {
        .copy => "copy",
        .move => "move",
    };
}

fn maybeRemoveLegacy(args: Args) !void {
    if (args.migrate_mode != .move) return;
    try deleteFilePath(args.migrate_from);
}

fn deleteFilePath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), parent, .{ .follow_symlinks = false });
        defer dir.close(std.Io.Threaded.global_single_threaded.io());
        try dir.deleteFile(std.Io.Threaded.global_single_threaded.io(), base);
        return;
    }
    try std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path);
}

fn loadRecords(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(Record) {
    const loaded = try loadRecordsValidated(allocator, path);
    return loaded.records;
}

fn loadRecordsValidated(allocator: std.mem.Allocator, path: []const u8) !LoadResult {
    var records = std.ArrayList(Record).empty;
    const data = durable_store.readFileAlloc(allocator, path, MaxStoreBytes) catch |err| switch (err) {
        error.FileNotFound => return .{ .records = records },
        else => return err,
    };
    defer allocator.free(data);

    var validation = ValidationIssue{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            validation.add("invalid json");
            continue;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => {
                validation.add("event is not an object");
                continue;
            },
        };
        const event = jsonStringField(obj, "event") orelse {
            validation.add("missing event");
            continue;
        };
        const neg_id = jsonStringField(obj, "neg_id") orelse {
            validation.add("missing neg_id");
            continue;
        };
        if (std.mem.eql(u8, event, "status")) {
            const status = jsonStringField(obj, "status") orelse {
                validation.add("status event missing status");
                continue;
            };
            if (!isKnownStatus(status)) validation.add("unknown status");
            if (findRecord(records.items, neg_id)) |idx| {
                allocator.free(records.items[idx].status);
                records.items[idx].status = try allocator.dupe(u8, status);
            } else {
                validation.add("status references missing neg_id");
            }
            continue;
        }
        if (!std.mem.eql(u8, event, "capture")) {
            validation.add("unknown event");
            continue;
        }
        const raw_record = obj.get("record") orelse {
            validation.add("capture missing record object");
            continue;
        };
        const record_obj = switch (raw_record) {
            .object => |value| value,
            else => {
                validation.add("capture missing record object");
                continue;
            },
        };
        const status = jsonStringField(obj, "status") orelse jsonStringField(record_obj, "status") orelse "unknown";
        if (findRecord(records.items, neg_id)) |idx| {
            validation.add("duplicate capture neg_id");
            records.items[idx].evidence_count += 1;
            continue;
        }
        const source_refs_count = jsonArrayCount(record_obj, "source_refs") + jsonArrayCount(record_obj, "evidence");
        const exclusion_scope = jsonStringField(record_obj, "exclusion_scope") orelse "route";
        const exclusion_rule = jsonStringField(record_obj, "exclusion_rule") orelse "";
        const route_id = jsonStringField(record_obj, "route_id") orelse jsonStringField(record_obj, "route") orelse "";
        const cluster_id = jsonStringField(record_obj, "cluster_id") orelse jsonStringField(record_obj, "cluster") orelse "";

        var record = Record{
            .neg_id = try allocator.dupe(u8, neg_id),
            .status = try allocator.dupe(u8, status),
            .hypothesis = try allocator.dupe(u8, jsonStringField(record_obj, "hypothesis") orelse ""),
            .route_id = try allocator.dupe(u8, route_id),
            .cluster_id = try allocator.dupe(u8, cluster_id),
            .artifact_state_id = try allocator.dupe(u8, jsonStringField(record_obj, "artifact_state_id") orelse jsonStringField(record_obj, "artifact") orelse ""),
            .exclusion_scope = try allocator.dupe(u8, exclusion_scope),
            .exclusion_rule = try allocator.dupe(u8, exclusion_rule),
            .failure_class = try allocator.dupe(u8, jsonStringField(record_obj, "failure_class") orelse "unknown"),
            .confidence = try allocator.dupe(u8, jsonStringField(record_obj, "confidence") orelse "unknown"),
            .next_search_hint = try allocator.dupe(u8, jsonStringField(record_obj, "next_search_hint") orelse ""),
            .record_json = try jsonValueAlloc(allocator, raw_record),
            .source_refs_count = source_refs_count,
            .applicability_conditions_count = jsonArrayCount(record_obj, "applicability_conditions"),
            .evidence_count = 1,
        };
        errdefer record.deinit(allocator);
        try records.append(allocator, record);
    }
    for (records.items) |record| validateProjectedRecord(record, &validation);
    return .{ .records = records, .validation = validation };
}

fn validateProjectedRecord(record: Record, validation: *ValidationIssue) void {
    if (!isKnownStatus(record.status)) validation.add("unknown status");
    if (!isKnownExclusionScope(record.exclusion_scope)) {
        validation.add("unknown exclusion_scope");
    }
    if (std.mem.eql(u8, record.status, "active") and !recordActiveComplete(record)) {
        validation.add("active record lacks required evidence");
    }
}

fn recordActiveComplete(record: Record) bool {
    if (record.source_refs_count == 0) return false;
    return record.route_id.len > 0 or record.cluster_id.len > 0;
}

fn recordCanBlock(record: Record) bool {
    if (!std.mem.eql(u8, record.status, "active")) return false;
    if (std.mem.eql(u8, record.exclusion_scope, "exact")) {
        return record.route_id.len > 0;
    }
    if (record.source_refs_count == 0) return false;
    if (std.mem.eql(u8, record.exclusion_scope, "cluster")) {
        return record.cluster_id.len > 0 and record.exclusion_rule.len > 0;
    }
    if (!std.mem.eql(u8, record.exclusion_scope, "route")) return false;
    return record.route_id.len > 0;
}

fn isKnownStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "capture_candidate") or
        std.mem.eql(u8, status, "active") or
        std.mem.eql(u8, status, "need-evidence") or
        std.mem.eql(u8, status, "accepted_risk") or
        std.mem.eql(u8, status, "stale") or
        std.mem.eql(u8, status, "superseded") or
        std.mem.eql(u8, status, "reopened") or
        std.mem.eql(u8, status, "unknown");
}

fn deinitRecords(allocator: std.mem.Allocator, records: *std.ArrayList(Record)) void {
    for (records.items) |*record| record.deinit(allocator);
    records.deinit(allocator);
}

fn findRecord(records: []const Record, neg_id: []const u8) ?usize {
    for (records, 0..) |record, idx| {
        if (std.mem.eql(u8, record.neg_id, neg_id)) return idx;
    }
    return null;
}

fn nextNegIdAlloc(allocator: std.mem.Allocator, records: []const Record) ![]u8 {
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (records) |record| try ids.append(allocator, record.neg_id);
    return durable_store.nextMonotonicIdAlloc(allocator, "NEG-", ids.items);
}

fn captureCanRequestStatus(obj: std.json.ObjectMap, requested_status: []const u8) bool {
    if (std.mem.eql(u8, requested_status, "active")) {
        if (!captureHasWitness(obj)) return false;
        const route_id = jsonStringField(obj, "route_id") orelse jsonStringField(obj, "route") orelse "";
        const cluster_id = jsonStringField(obj, "cluster_id") orelse jsonStringField(obj, "cluster") orelse "";
        const exclusion_scope = jsonStringField(obj, "exclusion_scope") orelse "route";
        const exclusion_rule = jsonStringField(obj, "exclusion_rule") orelse "";
        if (std.mem.eql(u8, exclusion_scope, "cluster")) return cluster_id.len > 0 and exclusion_rule.len > 0;
        return route_id.len > 0 or cluster_id.len > 0;
    }
    return true;
}

fn validateCaptureInput(obj: std.json.ObjectMap) !void {
    const exclusion_scope = jsonStringField(obj, "exclusion_scope") orelse "route";
    if (!isKnownExclusionScope(exclusion_scope)) return error.InvalidExclusionScope;
    if (jsonStringField(obj, "status")) |status| {
        if (!isKnownStatus(status)) return error.InvalidStatus;
    }
}

fn captureHasWitness(obj: std.json.ObjectMap) bool {
    if (obj.get("source_refs")) |value| {
        if (value == .array and value.array.items.len > 0) return true;
    }
    if (obj.get("evidence")) |value| {
        if (value == .array and value.array.items.len > 0) return true;
    }
    return false;
}

fn readCaptureInput(allocator: std.mem.Allocator, json_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, json_path, "-")) {
        var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
    }
    return durable_store.readFileAlloc(allocator, json_path, MaxInputBytes);
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonArrayCount(obj: std.json.ObjectMap, key: []const u8) usize {
    const value = obj.get(key) orelse return 0;
    return switch (value) {
        .array => |array| array.items.len,
        else => 0,
    };
}

fn isKnownExclusionScope(exclusion_scope: []const u8) bool {
    return std.mem.eql(u8, exclusion_scope, "exact") or
        std.mem.eql(u8, exclusion_scope, "route") or
        std.mem.eql(u8, exclusion_scope, "route_family") or
        std.mem.eql(u8, exclusion_scope, "cluster") or
        std.mem.eql(u8, exclusion_scope, "authority_model") or
        std.mem.eql(u8, exclusion_scope, "distinction_pattern") or
        std.mem.eql(u8, exclusion_scope, "proof_pattern");
}

fn jsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn projectionFingerprintAlloc(allocator: std.mem.Allocator, record: Record) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(record.neg_id);
    hasher.update("\n");
    hasher.update(record.status);
    hasher.update("\n");
    hasher.update(record.record_json);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn sha256HexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn writeFullProjection(
    allocator: std.mem.Allocator,
    writer: anytype,
    ledger_path: []const u8,
    record: Record,
    projection_fingerprint: []const u8,
    exported_at: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record.record_json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidCaptureJson,
    };

    try writer.writeAll("{\"schema\":\"negative-ledger-projection/v2\",\"ledger_path\":");
    try writeJsonString(writer, ledger_path);
    try writer.writeAll(",\"neg_id\":");
    try writeJsonString(writer, record.neg_id);
    try writer.writeAll(",\"record_version\":");
    try writeJsonString(writer, jsonStringField(obj, "record_version") orelse "NER-v2");
    try writer.writeAll(",\"campaign_id\":");
    try writeJsonString(writer, jsonStringField(obj, "campaign_id") orelse "");
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, record.status);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, jsonStringField(obj, "kind") orelse "realization_route");
    try writer.writeAll(",\"kernel_law_ids\":");
    try writeJsonArrayField(writer, obj, "kernel_law_ids");
    try writer.writeAll(",\"counterexample_family_ids\":");
    try writeJsonArrayField(writer, obj, "counterexample_family_ids");
    try writer.writeAll(",\"route_or_model_id\":");
    try writeJsonString(writer, jsonStringField(obj, "route_or_model_id") orelse record.route_id);
    try writer.writeAll(",\"route_id\":");
    try writeJsonString(writer, record.route_id);
    try writer.writeAll(",\"cluster_id\":");
    try writeJsonString(writer, record.cluster_id);
    try writer.writeAll(",\"artifact_state_id\":");
    try writeJsonString(writer, record.artifact_state_id);
    try writer.writeAll(",\"hypothesis\":");
    try writeJsonString(writer, record.hypothesis);
    try writer.writeAll(",\"attempted_change\":");
    try writeJsonString(writer, jsonStringField(obj, "attempted_change") orelse "");
    try writer.writeAll(",\"observed_outcome\":");
    try writeJsonString(writer, jsonStringField(obj, "observed_outcome") orelse "");
    try writer.writeAll(",\"failure_class\":");
    try writeJsonString(writer, record.failure_class);
    try writer.writeAll(",\"source_refs\":");
    try writeJsonArrayField(writer, obj, "source_refs");
    try writer.writeAll(",\"falsifying_evidence\":");
    try writeJsonArrayField(writer, obj, "falsifying_evidence");
    try writer.writeAll(",\"exclusion_scope\":");
    try writeJsonString(writer, record.exclusion_scope);
    try writer.writeAll(",\"exclusion_rule\":");
    try writeJsonString(writer, record.exclusion_rule);
    try writer.writeAll(",\"applicability_conditions\":");
    try writeJsonArrayField(writer, obj, "applicability_conditions");
    try writer.writeAll(",\"reopening_criteria\":");
    try writeJsonArrayField(writer, obj, "reopening_criteria");
    try writer.writeAll(",\"confidence\":");
    try writeJsonString(writer, record.confidence);
    try writer.writeAll(",\"next_search_hint\":");
    try writeJsonString(writer, record.next_search_hint);
    try writer.print(",\"source_event_count\":{d},\"projection_fingerprint\":", .{record.evidence_count});
    try writeJsonString(writer, projection_fingerprint);
    try writer.writeAll(",\"exported_at\":");
    try writeJsonString(writer, exported_at);
    try writer.writeByte('}');
}

fn writeLedgerMemoryNoteInput(
    allocator: std.mem.Allocator,
    writer: anytype,
    ledger_path: []const u8,
    record: Record,
    projection_fingerprint: []const u8,
) !void {
    try writer.writeAll("{\"operation\":");
    try writeJsonString(writer, if (std.mem.eql(u8, record.status, "reopened")) "reopen" else "assert");
    try writer.writeAll(",\"authority\":\"ledger-cli\",\"summary\":");
    const summary = try std.fmt.allocPrint(allocator, "{s} {s} negative-evidence projection", .{ record.neg_id, record.status });
    defer allocator.free(summary);
    try writeJsonString(writer, summary);
    try writer.writeAll(",\"scope\":{\"kind\":\"repo\",\"repo\":null,\"paths\":[]},\"source_refs\":[{\"kind\":\"negative-ledger\",\"ref\":");
    const ref = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ ledger_path, record.neg_id });
    defer allocator.free(ref);
    try writeJsonString(writer, ref);
    try writer.writeAll(",\"summary\":\"Canonical ledger export\"}],\"related_ids\":[],\"supersedes_id\":null,\"payload\":");
    const exported_at = try nowUtcAlloc(allocator);
    defer allocator.free(exported_at);
    try writeFullProjection(allocator, writer, ledger_path, record, projection_fingerprint, exported_at);
    try writer.writeByte('}');
}

fn writeJsonArrayField(writer: anytype, obj: std.json.ObjectMap, key: []const u8) !void {
    if (obj.get(key)) |value| {
        if (value == .array) {
            try std.json.Stringify.value(value, .{}, writer);
            return;
        }
    }
    try writer.writeAll("[]");
}

fn nowUtcAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now_sec: i64 = @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000));
    var days = @divFloor(now_sec, 86_400);
    var seconds_of_day = now_sec - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }
    const date = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(date.year)),
        @as(u32, @intCast(date.month)),
        @as(u32, @intCast(date.day)),
        @as(u32, @intCast(hour)),
        @as(u32, @intCast(minute)),
        @as(u32, @intCast(second)),
    });
}

fn civilFromDays(days_since_unix_epoch: i64) Date {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    var m = mp + 3;
    if (m > 12) m -= 12;
    if (m <= 2) y += 1;
    return .{ .year = y, .month = m, .day = d };
}

fn lexicalOverlap(a: []const u8, b: []const u8) bool {
    if (a.len < 3 or b.len < 3) return false;
    return std.mem.indexOf(u8, a, b) != null or std.mem.indexOf(u8, b, a) != null;
}

fn writeRecordsJson(writer: anytype, records: []const Record) !void {
    try writer.writeAll("{\"records\":[");
    for (records, 0..) |record, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeRecordJson(writer, record, null);
    }
    try writer.writeAll("]}\n");
}

fn writeRecordJson(writer: anytype, record: Record, projection_fingerprint: ?[]const u8) !void {
    try writer.writeAll("{\"neg_id\":");
    try writeJsonString(writer, record.neg_id);
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, record.status);
    try writer.writeAll(",\"hypothesis\":");
    try writeJsonString(writer, record.hypothesis);
    try writer.writeAll(",\"route_id\":");
    try writeJsonString(writer, record.route_id);
    try writer.writeAll(",\"cluster_id\":");
    try writeJsonString(writer, record.cluster_id);
    try writer.writeAll(",\"artifact_state_id\":");
    try writeJsonString(writer, record.artifact_state_id);
    try writer.writeAll(",\"exclusion_scope\":");
    try writeJsonString(writer, record.exclusion_scope);
    try writer.writeAll(",\"exclusion_rule\":");
    try writeJsonString(writer, record.exclusion_rule);
    try writer.writeAll(",\"failure_class\":");
    try writeJsonString(writer, record.failure_class);
    try writer.writeAll(",\"confidence\":");
    try writeJsonString(writer, record.confidence);
    try writer.writeAll(",\"next_search_hint\":");
    try writeJsonString(writer, record.next_search_hint);
    try writer.print(",\"source_refs_count\":{d},\"applicability_conditions_count\":{d},\"evidence_count\":{d},\"source_event_count\":{d}", .{
        record.source_refs_count,
        record.applicability_conditions_count,
        record.evidence_count,
        record.evidence_count,
    });
    if (projection_fingerprint) |fingerprint| {
        try writer.writeAll(",\"projection_fingerprint\":");
        try writeJsonString(writer, fingerprint);
    }
    try writer.writeByte('}');
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonEscapedBare(writer, text);
    try writer.writeByte('"');
}

fn writeJsonEscapedBare(writer: anytype, text: []const u8) !void {
    for (text) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
}

fn printJsonLine(allocator: std.mem.Allocator, command: Command, status: []const u8, subject: []const u8, count: usize) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"command\":\"{s}\",\"status\":", .{@tagName(command)});
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"subject\":");
    try writeJsonString(&out.writer, subject);
    try out.writer.print(",\"count\":{d}}}\n", .{count});
    try writeStdoutAlloc(allocator, &out);
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}

test "capture without witness becomes need-evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(std.testing.allocator, input, "{\"hypothesis\":\"h\",\"route_id\":\"r\"}");

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("NEG-000001", capture.neg_id);
    try std.testing.expectEqualStrings("need-evidence", capture.status);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqualStrings("NEG-000001", records.items[0].neg_id);
    try std.testing.expectEqualStrings("need-evidence", records.items[0].status);
}

test "default store path is namespaced under .ledger/negative-ledger" {
    const argv = [_][]const u8{ "ledger", "query" };
    const parsed = try parseArgs(&argv);
    try std.testing.expectEqualStrings(".ledger/negative-ledger/events.jsonl", parsed.file);
}

test "migrate parses explicit from and to paths" {
    const argv = [_][]const u8{ "ledger", "migrate", "--from", "old.jsonl", "--to", "new.jsonl", "--mode", "move", "--dry-run" };
    const parsed = try parseArgs(&argv);
    try std.testing.expectEqual(Command.migrate, parsed.command);
    try std.testing.expectEqualStrings("old.jsonl", parsed.migrate_from);
    try std.testing.expectEqualStrings("new.jsonl", parsed.migrate_to);
    try std.testing.expectEqual(MigrationMode.move, parsed.migrate_mode);
    try std.testing.expect(parsed.dry_run);
}

test "migration copy preserves legacy store bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(source);
    const target = try std.fs.path.join(std.testing.allocator, &.{ root, ".ledger", "negative-ledger", "events.jsonl" });
    defer std.testing.allocator.free(target);
    const bytes = "{\"v\":1,\"event\":\"capture\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}}\n";
    try durable_store.writeTextAtomic(std.testing.allocator, source, bytes);
    var source_loaded = try loadRecordsValidated(std.testing.allocator, source);
    defer source_loaded.deinit(std.testing.allocator);
    try std.testing.expect(source_loaded.validation.ok());

    try durable_store.writeTextCreateNew(std.testing.allocator, target, bytes, .{ .reject_symlinks = true });
    const target_bytes = try durable_store.readRegularFileNoSymlink(std.testing.allocator, target, MaxStoreBytes);
    defer std.testing.allocator.free(target_bytes);
    try std.testing.expectEqualStrings(bytes, target_bytes);
}

test "capture with witness can become active and map blocks exact route" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"cluster_id\":\"cluster-a\",\"artifact_state_id\":\"head\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"zig build test\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);
    try std.testing.expectEqualStrings("active", records.items[0].status);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
        .artifact = "head",
    });
    try std.testing.expectEqual(@as(?usize, 0), gate.active_match_index);
}

test "route gate fuzzy match is suggest-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"review-route-alpha\",\"cluster_id\":\"cluster-a\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "review-route",
        .cluster = "",
    });
    try std.testing.expectEqual(@as(?usize, null), gate.active_match_index);
    try std.testing.expectEqual(@as(usize, 1), gate.fuzzy_candidates);
}

test "route gate artifact mismatch does not block exact route" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"cluster_id\":\"cluster-a\",\"artifact_state_id\":\"old-head\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
        .artifact = "new-head",
    });
    try std.testing.expectEqual(@as(?usize, null), gate.active_match_index);
}

test "route gate missing store fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "missing", "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);

    try std.testing.expectEqual(@as(u8, 3), try mapStatusForStore(std.testing.allocator, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
    }));
}

test "witnessless capture cannot become active exclusion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"cluster_id\":\"cluster-a\",\"status\":\"active\"}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);
    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
    });

    try std.testing.expectEqualStrings("need-evidence", records.items[0].status);
    try std.testing.expectEqual(@as(?usize, null), gate.active_match_index);
}

test "route-scoped evidence does not block another route in same cluster" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"cluster_id\":\"cluster-a\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-b",
        .cluster = "cluster-a",
        .artifact = "head",
    });
    try std.testing.expectEqual(@as(?usize, null), gate.active_match_index);
}

test "explicit cluster-scoped evidence blocks same cluster" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"cluster_id\":\"cluster-a\",\"exclusion_scope\":\"cluster\",\"exclusion_rule\":\"cluster route family is falsified\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-b",
        .cluster = "cluster-a",
        .artifact = "head",
    });
    try std.testing.expectEqual(@as(?usize, 0), gate.active_match_index);
}

test "reopened evidence no longer blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"cluster_id\":\"cluster-a\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    try durable_store.appendLineAtomic(
        std.testing.allocator,
        store,
        "{\"v\":1,\"event\":\"status\",\"neg_id\":\"NEG-000001\",\"status\":\"reopened\"}",
        MaxStoreBytes,
    );
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
        .artifact = "head",
    });
    try std.testing.expectEqual(@as(?usize, null), gate.active_match_index);
}

test "map fails closed for invalid input and malformed store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    try durable_store.writeTextAtomic(std.testing.allocator, store, "{bad json}\n");

    try std.testing.expectEqual(@as(u8, 3), try mapStatusForStore(std.testing.allocator, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
        .artifact = "head",
    }));
    try std.testing.expectEqual(@as(u8, 3), try mapStatusForStore(std.testing.allocator, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "",
        .artifact = "head",
    }));
}

test "doctor reports unsafe active records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        store,
        "{\"v\":1,\"event\":\"capture\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{\"hypothesis\":\"h\",\"route_id\":\"route-a\"}}\n",
    );

    var loaded = try loadRecordsValidated(std.testing.allocator, store);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.validation.ok());
}

test "capture rejects unknown exclusion scope before append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"exclusion_scope\":\"rouet\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    try std.testing.expectError(error.InvalidExclusionScope, appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input }));
    try std.testing.expect(!durable_store.fileExists(store));
}

test "projection validation uses final replayed status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const promoted = try std.fs.path.join(std.testing.allocator, &.{ root, "promoted.jsonl" });
    defer std.testing.allocator.free(promoted);
    const reopened = try std.fs.path.join(std.testing.allocator, &.{ root, "reopened.jsonl" });
    defer std.testing.allocator.free(reopened);

    try durable_store.writeTextAtomic(
        std.testing.allocator,
        promoted,
        "{\"v\":1,\"event\":\"capture\",\"neg_id\":\"NEG-000001\",\"status\":\"need-evidence\",\"record\":{\"hypothesis\":\"h\",\"route_id\":\"route-a\"}}\n{\"v\":1,\"event\":\"status\",\"neg_id\":\"NEG-000001\",\"status\":\"active\"}\n",
    );
    var promoted_loaded = try loadRecordsValidated(std.testing.allocator, promoted);
    defer promoted_loaded.deinit(std.testing.allocator);
    try std.testing.expect(!promoted_loaded.validation.ok());
    try std.testing.expectEqualStrings("active", promoted_loaded.records.items[0].status);

    try durable_store.writeTextAtomic(
        std.testing.allocator,
        reopened,
        "{\"v\":1,\"event\":\"capture\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{\"hypothesis\":\"h\",\"route_id\":\"route-a\"}}\n{\"v\":1,\"event\":\"status\",\"neg_id\":\"NEG-000001\",\"status\":\"reopened\"}\n",
    );
    var reopened_loaded = try loadRecordsValidated(std.testing.allocator, reopened);
    defer reopened_loaded.deinit(std.testing.allocator);
    try std.testing.expect(reopened_loaded.validation.ok());
    try std.testing.expectEqualStrings("reopened", reopened_loaded.records.items[0].status);
}

test "capture rejects unknown status before append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"status\":\"actve\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    try std.testing.expectError(error.InvalidStatus, appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input }));
    try std.testing.expect(!durable_store.fileExists(store));
}

test "capture rejects duplicate neg_id before append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const first = try std.fs.path.join(std.testing.allocator, &.{ root, "first.json" });
    defer std.testing.allocator.free(first);
    const second = try std.fs.path.join(std.testing.allocator, &.{ root, "second.json" });
    defer std.testing.allocator.free(second);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        first,
        "{\"neg_id\":\"NEG-000001\",\"hypothesis\":\"h1\",\"route_id\":\"route-a\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        second,
        "{\"neg_id\":\"NEG-000001\",\"hypothesis\":\"h2\",\"route_id\":\"route-b\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = first });
    defer capture.deinit(std.testing.allocator);
    try std.testing.expectError(error.DuplicateCaptureId, appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = second }));
    var loaded = try loadRecordsValidated(std.testing.allocator, store);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(loaded.validation.ok());
    try std.testing.expectEqual(@as(usize, 1), loaded.records.items.len);
}

test "capture compacts multiline input before append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\n  \"hypothesis\":\"h\",\n  \"route_id\":\"route-a\",\n  \"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]\n}\n",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var loaded = try loadRecordsValidated(std.testing.allocator, store);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(loaded.validation.ok());
    try std.testing.expectEqual(@as(usize, 1), loaded.records.items.len);
    try std.testing.expectEqualStrings("active", loaded.records.items[0].status);
}
