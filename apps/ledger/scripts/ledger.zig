const app_meta = @import("app_meta");
const actuation_cli = @import("actuation.zig");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const hylo_cli = if (builtin.is_test) struct {
    pub fn runWithArgv(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !u8 {
        return error.HyloDelegateUnavailableInLedgerTests;
    }
} else @import("hylo.zig");
const learnings_cli = @import("learnings_cli");
const std = @import("std");
const synesthesia_cli = @import("synesthesia_cli");
const universalist_cli = @import("universalist.zig");
const validation_cli = @import("validation.zig");

const Version = core_cli.normalizeVersion(app_meta.version);
const HctpProductAvailable = builtin.os.tag == .macos;
const LegacyStorePath = ".ledger/negative-ledger.jsonl";
const DefaultStorePath = ".ledger/negative-ledger/events.jsonl";
const MaxStoreBytes = 64 * 1024 * 1024;
const MaxInputBytes = 4 * 1024 * 1024;
threadlocal var runtime_io: ?std.Io = null;

fn defaultIo() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io orelse std.Io.Threaded.global_single_threaded.io();
}

const HelpText = std.fmt.comptimePrint(
    \\ledger
    \\
    \\{s}
    \\
    \\usage: ledger {{init,capture,query,map,status,reopen,export,compact,handoff,show,doctor,migrate,recent,recall,codify-candidates,quality-audit,value-report,memory-digest,path,datasets,dataset-schema,validate}} [options]
    \\
    \\commands:
    \\  init       Create the ledger store if missing
    \\  capture    Append witness-backed negative evidence from --json FILE|-; source namespaces own their commands
    \\  query      List projected records
    \\  map        Emit negative_route_gate for a route/cluster
    \\  status     Append a lifecycle status event
    \\  reopen     Mark a NEG record reopened
    \\  export     Emit a full or memory-note projection
    \\  compact    Report compaction candidates
    \\  handoff    Emit active exclusions for handoff
    \\  show       Show one source record by --id
    \\  doctor     Validate event-store integrity
    \\  migrate    Copy or move legacy source stores into the current persistent adapter
    \\  recent     With a supporting --source namespace, show recent source events
    \\  recall     With a supporting --source namespace, rank relevant source events
    \\  path       With a supporting --source namespace, print the resolved event path
    \\  datasets   With --source learnings, list learning datasets
    \\  validate   Purely validate governance and review artifacts
    \\
    \\options:
    \\  --file PATH       Persistent-adapter path (default: .ledger/negative-ledger/events.jsonl)
    \\  --source SOURCE   {s}
    \\  --json PATH|-     Capture input JSON or lifecycle-transition proof JSON
    \\  --id RECORD-ID    Record id for show/reopen/status/export
    \\  --to VALUE        Target status for status, target path for migrate
    \\  --from PATH       Legacy store path for migrate
    \\  --mode MODE       copy|move for migrate
    \\  --dry-run         Report migrate outcome without writing
    \\  --reason TEXT     Fallback transition reason; lifecycle proof JSON is still required
    \\  --format FORMAT   full|memory-note for export
    \\  --cluster ID      Current route cluster for map
    \\  --route ID        Current route id/tag for map
    \\  --route-family ID Current route-family id for map
    \\  --authority-model ID  Current authority-model id for map
    \\  --distinction-pattern ID  Current distinction-pattern id for map
    \\  --proof-pattern ID  Current proof-pattern id for map
    \\  --artifact ID     Current immutable artifact state id (symbolic Git refs are resolved)
    \\  --input FILE|-    Canonical JSON input for validate
    \\  -h, --help        Show help
    \\  -V, --version     Show version
, .{
    "Materialize, validate, record, and project workflow artifacts, including Actuating evidence.",
    if (HctpProductAvailable)
        "Source namespace; use negative-ledger, actuation, hylo, learnings, synesthesia, or universalist"
    else
        "Source namespace; use negative-ledger, actuation, learnings, synesthesia, or universalist",
});

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
    route_family: []const u8 = "",
    authority_model: []const u8 = "",
    distinction_pattern: []const u8 = "",
    proof_pattern: []const u8 = "",
    artifact: []const u8 = "",
    artifact_label: []const u8 = "",
};

const Record = struct {
    neg_id: []u8,
    status: []u8,
    record_version: []u8,
    kind: []u8,
    hypothesis: []u8,
    route_id: []u8,
    route_family_id: []u8,
    cluster_id: []u8,
    authority_model_id: []u8,
    distinction_pattern_id: []u8,
    proof_pattern_id: []u8,
    artifact_state_id: []u8,
    artifact_state_label: []u8,
    repository_id: []u8,
    attempted_change: []u8,
    observed_outcome: []u8,
    exclusion_scope: []u8,
    exclusion_rule: []u8,
    failure_class: []u8,
    confidence: []u8,
    next_search_hint: []u8,
    record_json: []u8,
    event_chain_fingerprint: []u8,
    prior_projection_fingerprint: []u8,
    source_refs_count: usize = 0,
    applicability_conditions_count: usize = 0,
    reopening_criteria_count: usize = 0,
    capture_event_count: usize = 0,
    status_event_count: usize = 0,
    source_event_count: usize = 0,

    fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.neg_id);
        allocator.free(self.status);
        allocator.free(self.record_version);
        allocator.free(self.kind);
        allocator.free(self.hypothesis);
        allocator.free(self.route_id);
        allocator.free(self.route_family_id);
        allocator.free(self.cluster_id);
        allocator.free(self.authority_model_id);
        allocator.free(self.distinction_pattern_id);
        allocator.free(self.proof_pattern_id);
        allocator.free(self.artifact_state_id);
        allocator.free(self.artifact_state_label);
        allocator.free(self.repository_id);
        allocator.free(self.attempted_change);
        allocator.free(self.observed_outcome);
        allocator.free(self.exclusion_scope);
        allocator.free(self.exclusion_rule);
        allocator.free(self.failure_class);
        allocator.free(self.confidence);
        allocator.free(self.next_search_hint);
        allocator.free(self.record_json);
        allocator.free(self.event_chain_fingerprint);
        allocator.free(self.prior_projection_fingerprint);
    }
};

const ResolvedArtifact = struct {
    id: []u8,
    label: []u8,

    fn deinit(self: *ResolvedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
    }
};

const RepositoryScope = struct {
    id: []u8,
    ledger_path: []u8,
    paths_json: []u8,

    fn deinit(self: *RepositoryScope, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.ledger_path);
        allocator.free(self.paths_json);
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
    reopen_required_index: ?usize = null,
    fuzzy_candidates: usize = 0,
};

const ValidationIssue = struct {
    issue_count: usize = 0,
    first_issue: ?[]const u8 = null,
    first_issue_line: usize = 0,

    fn add(self: *ValidationIssue, message: []const u8, diagnostic_position: ?usize) void {
        self.issue_count += 1;
        if (self.first_issue == null) {
            self.first_issue = message;
            self.first_issue_line = diagnostic_position orelse 0;
        }
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
    runtime_io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argvSource(argv)) |source| {
        if (!sourceAvailable(source)) {
            core_cli.exitUsageFailure(HelpSurface, Version, "UnknownSource", source);
            return;
        }
        const source_argv = try sourceArgvAlloc(allocator, argv, source);
        defer allocator.free(source_argv);
        if (std.mem.eql(u8, source, "negative-ledger")) {
            try runRootWithArgv(allocator, init.io, source_argv);
            return;
        }
        if (std.mem.eql(u8, source, "learnings")) {
            try learnings_cli.runWithArgv(allocator, source_argv, init.environ_map.get("CODEX_HOME") orelse "");
            return;
        }
        if (std.mem.eql(u8, source, "synesthesia")) {
            try synesthesia_cli.runWithArgv(allocator, source_argv, init.environ_map.get("CODEX_HOME") orelse "");
            return;
        }
        if (std.mem.eql(u8, source, "actuation")) {
            const code = try actuation_cli.runWithArgv(allocator, init.io, source_argv);
            if (code != 0) std.process.exit(code);
            return;
        }
        if (HctpProductAvailable and std.mem.eql(u8, source, "hylo")) {
            const code = try hylo_cli.runWithArgv(allocator, init.io, source_argv);
            if (code != 0) std.process.exit(code);
            return;
        }
        if (std.mem.eql(u8, source, "universalist")) {
            const code = try universalist_cli.runWithArgv(allocator, init.io, source_argv);
            if (code != 0) std.process.exit(code);
            return;
        }
        core_cli.exitUsageFailure(HelpSurface, Version, "UnknownSource", source);
        return;
    }
    try runRootWithArgv(allocator, init.io, argv);
}

fn runRootWithArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "validate")) {
        const code = validation_cli.runWithArgv(allocator, io, argv) catch |err| {
            core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
        };
        if (code != 0) std.process.exit(code);
        return;
    }
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

fn argvSource(argv: []const []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (!std.mem.eql(u8, argv[i], "--source")) continue;
        i += 1;
        if (i >= argv.len) return null;
        return argv[i];
    }
    return null;
}

fn sourceAvailable(source: []const u8) bool {
    return HctpProductAvailable or !std.mem.eql(u8, source, "hylo");
}

fn sourceArgvAlloc(allocator: std.mem.Allocator, argv: []const []const u8, source: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, "ledger");

    var command_seen = false;
    var skipped_source = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (!skipped_source and std.mem.eql(u8, token, "--source")) {
            if (i + 1 >= argv.len) return error.MissingValue;
            if (std.mem.eql(u8, argv[i + 1], source)) {
                skipped_source = true;
                i += 1;
                continue;
            }
        }
        if (!std.mem.eql(u8, source, "negative-ledger") and std.mem.eql(u8, token, "--file")) {
            try out.append(allocator, "--path");
            continue;
        }
        if (!command_seen and !std.mem.startsWith(u8, token, "-")) {
            command_seen = true;
            if (std.mem.eql(u8, source, "learnings") and std.mem.eql(u8, token, "capture")) {
                try out.append(allocator, "append");
            } else {
                try out.append(allocator, token);
            }
            continue;
        }
        try out.append(allocator, token);
    }
    return out.toOwnedSlice(allocator);
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
        if (std.mem.eql(u8, token, "--route-family")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.route_family = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--authority-model")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.authority_model = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--distinction-pattern")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.distinction_pattern = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--proof-pattern")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.proof_pattern = argv[i];
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
        .status => cmdStatusEvent(allocator, args, args.to_status.?, .status),
        .reopen => cmdStatusEvent(allocator, args, "reopened", .reopen),
        .@"export" => cmdExport(allocator, args),
        .compact => cmdCompact(allocator, args.file),
        .handoff => cmdHandoff(allocator, args.file),
        .show => cmdShow(allocator, args.file, args.id.?),
        .doctor => cmdDoctor(allocator, args.file),
        .migrate => cmdMigrate(allocator, args),
    };
}

fn cmdInit(allocator: std.mem.Allocator, path: []const u8) !u8 {
    var backend = durable_store.PersistentEventStore.init(path);
    const store = backend.eventStore();
    var snapshot = try store.snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    if (!snapshot.exists) {
        var receipt = try store.replace(allocator, &.{}, .{ .revision = snapshot.revision, .exists = false }, MaxStoreBytes);
        defer receipt.deinit(allocator);
        try ensureInitLockSidecarGitignored(allocator, path);
        try printJsonLine(allocator, .init, "initialized", path, 0);
        return 0;
    }
    try printJsonLine(allocator, .init, "already_initialized", path, 0);
    return 0;
}

fn ensureInitLockSidecarGitignored(allocator: std.mem.Allocator, store_path: []const u8) !void {
    const parent = std.fs.path.dirname(store_path) orelse ".";
    const git_root = durable_store.findGitRootAlloc(allocator, parent) catch return;
    defer allocator.free(git_root);

    const lock_path = try durable_store.lockPathAlloc(allocator, store_path);
    defer allocator.free(lock_path);
    const lock_rel = if (std.fs.path.isAbsolute(lock_path))
        try std.fs.path.relative(allocator, git_root, null, git_root, lock_path)
    else
        try allocator.dupe(u8, lock_path);
    defer allocator.free(lock_rel);

    const argv = [_][]const u8{ "git", "-C", git_root, "check-ignore", "-q", "--", lock_rel };
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    if (result.term == .exited and result.term.exited == 1) return error.LockSidecarNotGitignored;
    return error.GitCommandFailed;
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

    var resolved_artifact = try resolveArtifactIdentityAlloc(
        allocator,
        args.file,
        jsonStringField(obj, "artifact_state_id") orelse jsonStringField(obj, "artifact") orelse "",
        jsonStringField(obj, "artifact_state_label") orelse "",
    );
    defer resolved_artifact.deinit(allocator);
    const repository_id = try resolveRepositoryIdForStoreAlloc(allocator, args.file, jsonStringField(obj, "repository_id") orelse "");
    defer allocator.free(repository_id);
    const normalized_record = try normalizedCaptureRecordAlloc(allocator, obj, resolved_artifact, repository_id);
    defer allocator.free(normalized_record);
    var normalized_parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized_record, .{});
    defer normalized_parsed.deinit();
    const normalized_obj = switch (normalized_parsed.value) {
        .object => |value| value,
        else => return error.InvalidCaptureJson,
    };

    var backend = durable_store.PersistentEventStore.init(args.file);
    const store = backend.eventStore();
    var snapshot = try store.snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    var loaded = try loadRecordsFromSnapshot(allocator, &snapshot);
    defer loaded.deinit(allocator);
    if (!loaded.validation.ok()) return error.StoreInvalid;
    const records = &loaded.records;
    const neg_id = if (jsonStringField(normalized_obj, "neg_id")) |id|
        try allocator.dupe(u8, id)
    else
        try nextNegIdAlloc(allocator, records.items);
    defer allocator.free(neg_id);
    if (findRecord(records.items, neg_id) != null) return error.DuplicateCaptureId;

    const requested_status = jsonStringField(normalized_obj, "status") orelse "active";
    var candidate = try initRecordFromObject(allocator, neg_id, requested_status, normalized_parsed.value);
    defer candidate.deinit(allocator);
    var candidate_validation = ValidationIssue{};
    validateProjectedRecord(candidate, &candidate_validation);
    const status = if (std.mem.eql(u8, requested_status, "active") and !candidate_validation.ok()) "need-evidence" else requested_status;

    const timestamp = try nowUtcAlloc(allocator);
    defer allocator.free(timestamp);
    const event_id = try eventIdAlloc(allocator, "capture", neg_id, timestamp, normalized_record);
    defer allocator.free(event_id);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"v\":3,\"event\":\"capture\",\"event_id\":");
    try writeJsonString(&out.writer, event_id);
    try out.writer.writeAll(",\"timestamp\":");
    try writeJsonString(&out.writer, timestamp);
    try out.writer.writeAll(",\"neg_id\":");
    try writeJsonString(&out.writer, neg_id);
    try out.writer.writeAll(",\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"record\":");
    try out.writer.writeAll(normalized_record);
    try out.writer.writeByte('}');
    const line = try out.toOwnedSlice();
    defer allocator.free(line);
    var receipt = try store.append(
        allocator,
        line,
        .{ .revision = snapshot.revision, .exists = snapshot.exists },
        MaxStoreBytes,
    );
    defer receipt.deinit(allocator);

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
    var resolved_artifact = try resolveArtifactIdentityAlloc(allocator, args.file, args.artifact, args.artifact_label);
    defer resolved_artifact.deinit(allocator);
    var resolved_args = args;
    resolved_args.artifact = resolved_artifact.id;
    resolved_args.artifact_label = resolved_artifact.label;
    if (!hasMapIdentity(resolved_args) or resolved_args.artifact.len == 0) {
        try writeRouteGate(allocator, resolved_args, .{}, null, 3, false, "invalid_gate_input");
        return 3;
    }
    var backend = durable_store.PersistentEventStore.init(args.file);
    var snapshot = try backend.eventStore().snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    if (!snapshot.exists) {
        try writeRouteGate(allocator, resolved_args, .{}, null, 3, false, "ledger_missing");
        return 3;
    }
    var loaded = try loadRecordsFromSnapshot(allocator, &snapshot);
    defer loaded.deinit(allocator);
    if (!loaded.validation.ok()) {
        try writeRouteGate(allocator, resolved_args, .{}, null, 3, true, "store_invalid");
        return 3;
    }

    const gate = evaluateRouteGate(loaded.records.items, resolved_args);
    const exit_code: u8 = if (gate.active_match_index != null) 2 else 0;
    try writeRouteGate(allocator, resolved_args, gate, loaded.records.items, exit_code, true, "none");
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
    try out.writer.writeAll(",\"reopen_required\":");
    try out.writer.writeAll(if (gate.reopen_required_index != null) "true" else "false");
    try out.writer.writeAll(",\"reopen_evidence_id\":");
    if (gate.reopen_required_index) |idx| {
        const source_records = records orelse return error.MissingGateRecords;
        try writeJsonString(&out.writer, source_records[idx].neg_id);
    } else {
        try writeJsonString(&out.writer, "none");
    }
    try out.writer.writeAll(",\"fuzzy_candidates\":");
    try out.writer.print("{d}", .{gate.fuzzy_candidates});
    try out.writer.writeAll(",\"fuzzy_authority\":");
    try writeJsonString(&out.writer, if (ledger_available) "suggest_only" else "none");
    try out.writer.writeAll(",\"artifact_state_id\":");
    try writeJsonString(&out.writer, args.artifact);
    try out.writer.writeAll(",\"artifact_state_label\":");
    try writeJsonString(&out.writer, args.artifact_label);
    try out.writer.writeAll(",\"failure\":");
    try writeJsonString(&out.writer, failure);
    try out.writer.writeAll(",\"handoff_allowed\":");
    try out.writer.writeAll(if (exit_code == 0) "true" else "false");
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeMapCommandJson(writer: anytype, args: Args) !void {
    try writer.writeByte('"');
    try writer.writeAll("ledger map");
    try writeOptionalMapArg(writer, " --route ", args.route);
    try writeOptionalMapArg(writer, " --cluster ", args.cluster);
    try writeOptionalMapArg(writer, " --route-family ", args.route_family);
    try writeOptionalMapArg(writer, " --authority-model ", args.authority_model);
    try writeOptionalMapArg(writer, " --distinction-pattern ", args.distinction_pattern);
    try writeOptionalMapArg(writer, " --proof-pattern ", args.proof_pattern);
    try writer.writeAll(" --artifact ");
    try writeJsonEscapedBare(writer, args.artifact);
    try writer.writeByte('"');
}

fn writeOptionalMapArg(writer: anytype, flag: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try writer.writeAll(flag);
    try writeJsonEscapedBare(writer, value);
}

fn mapStatusForStore(allocator: std.mem.Allocator, args: Args) !u8 {
    var resolved_artifact = try resolveArtifactIdentityAlloc(allocator, args.file, args.artifact, args.artifact_label);
    defer resolved_artifact.deinit(allocator);
    var resolved_args = args;
    resolved_args.artifact = resolved_artifact.id;
    resolved_args.artifact_label = resolved_artifact.label;
    if (!hasMapIdentity(resolved_args) or resolved_args.artifact.len == 0) return 3;
    var backend = durable_store.PersistentEventStore.init(args.file);
    var snapshot = try backend.eventStore().snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    if (!snapshot.exists) return 3;
    var loaded = try loadRecordsFromSnapshot(allocator, &snapshot);
    defer loaded.deinit(allocator);
    if (!loaded.validation.ok()) return 3;
    const gate = evaluateRouteGate(loaded.records.items, resolved_args);
    return if (gate.active_match_index != null) 2 else 0;
}

fn evaluateRouteGate(records: []const Record, args: Args) RouteGate {
    var gate = RouteGate{};
    for (records, 0..) |record, idx| {
        const artifact_ok = record.artifact_state_id.len > 0 and std.mem.eql(u8, args.artifact, record.artifact_state_id);
        const exact_scope = scopeMatches(record, args);
        if (recordCanBlock(record) and exact_scope and artifact_ok) {
            gate.active_match_index = idx;
            return gate;
        }
        if (std.mem.eql(u8, record.status, "reopened") and exact_scope) gate.reopen_required_index = idx;
        if (!exact_scope and scopeNearMatches(record, args)) gate.fuzzy_candidates += 1;
    }
    return gate;
}

fn cmdStatusEvent(allocator: std.mem.Allocator, args: Args, status: []const u8, command: Command) !u8 {
    if (!try appendStatusEvent(allocator, args, status)) {
        var missing: std.Io.Writer.Allocating = .init(allocator);
        defer missing.deinit();
        try missing.writer.writeAll("{\"command\":");
        try writeJsonString(&missing.writer, @tagName(command));
        try missing.writer.writeAll(",\"id\":");
        try writeJsonString(&missing.writer, args.id.?);
        try missing.writer.writeAll(",\"found\":false}\n");
        try writeStdoutAlloc(allocator, &missing);
        return 1;
    }
    try printJsonLine(allocator, command, status, args.id.?, 0);
    return 0;
}

fn appendStatusEvent(allocator: std.mem.Allocator, args: Args, status: []const u8) !bool {
    if (!isKnownStatus(status)) return error.InvalidStatus;
    const neg_id = args.id.?;
    var proof = try readTransitionProof(allocator, args);
    defer proof.deinit(allocator);
    if (proof.reason.len == 0) return error.MissingReason;
    if (proof.source_refs_count == 0) return error.MissingTransitionProof;
    var backend = durable_store.PersistentEventStore.init(args.file);
    const store = backend.eventStore();
    var snapshot = try store.snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    var loaded = try loadRecordsFromSnapshot(allocator, &snapshot);
    defer loaded.deinit(allocator);
    if (!loaded.validation.ok()) return error.StoreInvalid;
    const idx = findRecord(loaded.records.items, neg_id) orelse return false;
    const record = loaded.records.items[idx];
    if (!allowedStatusTransition(record.status, status)) return error.InvalidStatusTransition;
    if (std.mem.eql(u8, status, "active")) {
        var validation = ValidationIssue{};
        validateRecordForStatus(record, status, &validation);
        if (!validation.ok()) return error.InvalidActiveRecord;
        if (proof.source_refs_count == 0) return error.MissingTransitionProof;
    }
    if (std.mem.eql(u8, status, "reopened")) {
        if (proof.source_refs_count == 0 or proof.criterion_ids_count == 0 or proof.criterion_changes_count == 0) return error.MissingReopenProof;
        if (!try transitionCriteriaBelongToRecord(allocator, record, proof.criterion_ids_json)) return error.UnknownReopeningCriterion;
    }

    const timestamp = try nowUtcAlloc(allocator);
    defer allocator.free(timestamp);
    const event_material = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ record.status, status, proof.reason, proof.criterion_ids_json, proof.criterion_changes_json, proof.source_refs_json });
    defer allocator.free(event_material);
    const event_id = try eventIdAlloc(allocator, "status", neg_id, timestamp, event_material);
    defer allocator.free(event_id);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"v\":3,\"event\":\"status\",\"event_id\":");
    try writeJsonString(&out.writer, event_id);
    try out.writer.writeAll(",\"timestamp\":");
    try writeJsonString(&out.writer, timestamp);
    try out.writer.writeAll(",\"neg_id\":");
    try writeJsonString(&out.writer, neg_id);
    try out.writer.writeAll(",\"from\":");
    try writeJsonString(&out.writer, record.status);
    try out.writer.writeAll(",\"to\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"reason\":");
    try writeJsonString(&out.writer, proof.reason);
    try out.writer.writeAll(",\"criterion_ids\":");
    try out.writer.writeAll(proof.criterion_ids_json);
    try out.writer.writeAll(",\"criterion_changes\":");
    try out.writer.writeAll(proof.criterion_changes_json);
    try out.writer.writeAll(",\"source_refs\":");
    try out.writer.writeAll(proof.source_refs_json);
    try out.writer.writeByte('}');
    const line = try out.toOwnedSlice();
    defer allocator.free(line);
    var receipt = try store.append(
        allocator,
        line,
        .{ .revision = snapshot.revision, .exists = snapshot.exists },
        MaxStoreBytes,
    );
    defer receipt.deinit(allocator);
    return true;
}

fn cmdExport(allocator: std.mem.Allocator, args: Args) !u8 {
    var loaded = try loadRecordsValidated(allocator, args.file);
    defer loaded.deinit(allocator);
    if (!loaded.validation.ok()) return error.StoreInvalid;
    const idx = findRecord(loaded.records.items, args.id.?) orelse return error.NotFound;
    const record = loaded.records.items[idx];
    var repository_scope = try resolveRepositoryScopeAlloc(allocator, args.file, record);
    defer repository_scope.deinit(allocator);
    const exported_at = try nowUtcAlloc(allocator);
    defer allocator.free(exported_at);
    const fingerprint = try projectionFingerprintAlloc(allocator, record);
    defer allocator.free(fingerprint);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (std.mem.eql(u8, args.format, "full")) {
        try writeFullProjection(allocator, &out.writer, repository_scope, record, fingerprint, exported_at);
    } else if (std.mem.eql(u8, args.format, "memory-note")) {
        try writeLedgerMemoryNoteInput(allocator, &out.writer, repository_scope, record, fingerprint);
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
    var loaded = try loadRecordsValidated(allocator, path);
    defer loaded.deinit(allocator);
    if (!loaded.validation.ok()) return error.StoreInvalid;
    var active = std.ArrayList(Record).empty;
    defer active.deinit(allocator);
    for (loaded.records.items) |record| {
        if (recordCanBlock(record) or std.mem.eql(u8, record.status, "reopened")) try active.append(allocator, record);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRecordsJson(&out.writer, active.items);
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn cmdDoctor(allocator: std.mem.Allocator, path: []const u8) !u8 {
    var backend = durable_store.PersistentEventStore.init(path);
    var snapshot = try backend.eventStore().snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    var loaded = try loadRecordsFromSnapshot(allocator, &snapshot);
    defer loaded.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const ok = loaded.validation.ok();
    try out.writer.print("{{\"command\":\"doctor\",\"ok\":{s},\"records\":{d},\"blank_lines\":{d},\"issues\":{d}", .{
        if (ok) "true" else "false",
        loaded.records.items.len,
        snapshot.blank_entries,
        loaded.validation.issue_count,
    });
    if (loaded.validation.first_issue) |message| {
        try out.writer.print(",\"first_issue\":{{\"line\":{d},\"message\":", .{loaded.validation.first_issue_line});
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
    var backend = durable_store.PersistentEventStore.init(path);
    var snapshot = try backend.eventStore().snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    return loadRecordsFromSnapshot(allocator, &snapshot);
}

fn loadRecordsFromSnapshot(allocator: std.mem.Allocator, snapshot: *const durable_store.EventSnapshot) !LoadResult {
    var records = std.ArrayList(Record).empty;
    var validation = ValidationIssue{};
    for (snapshot.records) |stored| {
        const line = stored.payload;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            validation.add("invalid json", stored.diagnostic_position);
            continue;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => {
                validation.add("event is not an object", stored.diagnostic_position);
                continue;
            },
        };
        const event = jsonStringField(obj, "event") orelse {
            validation.add("missing event", stored.diagnostic_position);
            continue;
        };
        const neg_id = jsonStringField(obj, "neg_id") orelse {
            validation.add("missing neg_id", stored.diagnostic_position);
            continue;
        };
        if (std.mem.eql(u8, event, "status")) {
            const status = jsonStringField(obj, "to") orelse jsonStringField(obj, "status") orelse {
                validation.add("status event missing status", stored.diagnostic_position);
                continue;
            };
            if (!isKnownStatus(status)) {
                validation.add("unknown status", stored.diagnostic_position);
                continue;
            }
            const idx = findRecord(records.items, neg_id) orelse {
                validation.add("status references missing neg_id", stored.diagnostic_position);
                continue;
            };
            const version = jsonIntegerField(obj, "v") orelse 1;
            const record = &records.items[idx];
            if (version >= 3) {
                if (!validEventIdentity(obj)) validation.add("status event lacks typed identity", stored.diagnostic_position);
                const from = jsonStringField(obj, "from") orelse {
                    validation.add("status event missing from", stored.diagnostic_position);
                    continue;
                };
                if (!std.mem.eql(u8, from, record.status)) {
                    validation.add("status event from does not match folded status", stored.diagnostic_position);
                    continue;
                }
                if (stringFieldOrEmpty(obj, "reason").len == 0) {
                    validation.add("status event missing reason", stored.diagnostic_position);
                    continue;
                }
                if (obj.get("source_refs") == null or jsonArrayCount(obj, "source_refs") == 0 or !sourceRefsValueValid(obj.get("source_refs"))) {
                    validation.add("status event has invalid source_refs", stored.diagnostic_position);
                    continue;
                }
            } else if (std.mem.eql(u8, status, "active") or !isInitialCaptureStatus(status)) {
                const prior_fingerprint = try projectionFingerprintAlloc(allocator, record.*);
                allocator.free(record.prior_projection_fingerprint);
                record.prior_projection_fingerprint = prior_fingerprint;
                allocator.free(record.status);
                record.status = try allocator.dupe(u8, "need-evidence");
                const next_chain = try eventChainFingerprintAlloc(allocator, record.event_chain_fingerprint, line);
                allocator.free(record.event_chain_fingerprint);
                record.event_chain_fingerprint = next_chain;
                record.status_event_count += 1;
                record.source_event_count += 1;
                continue;
            }
            if (!allowedStatusTransition(record.status, status)) {
                validation.add("illegal status transition", stored.diagnostic_position);
                continue;
            }
            if (std.mem.eql(u8, status, "active")) {
                var active_validation = ValidationIssue{};
                validateRecordForStatus(record.*, status, &active_validation);
                if (!active_validation.ok() or jsonArrayCount(obj, "source_refs") == 0) {
                    validation.add("active transition lacks proof or complete record", stored.diagnostic_position);
                    continue;
                }
            }
            if (std.mem.eql(u8, status, "reopened")) {
                if (jsonArrayCount(obj, "source_refs") == 0 or jsonArrayCount(obj, "criterion_ids") == 0 or
                    jsonArrayCount(obj, "criterion_changes") == 0 or
                    !criterionChangesValueValid(obj.get("criterion_changes")) or
                    !criterionIdsMatchChanges(obj.get("criterion_ids"), obj.get("criterion_changes")) or
                    !try transitionCriteriaBelongToRecordValue(allocator, record.*, obj.get("criterion_ids")))
                {
                    validation.add("reopen lacks changed-criterion proof", stored.diagnostic_position);
                    continue;
                }
            }
            const prior_fingerprint = try projectionFingerprintAlloc(allocator, record.*);
            allocator.free(record.prior_projection_fingerprint);
            record.prior_projection_fingerprint = prior_fingerprint;
            allocator.free(record.status);
            record.status = try allocator.dupe(u8, status);
            const next_chain = try eventChainFingerprintAlloc(allocator, record.event_chain_fingerprint, line);
            allocator.free(record.event_chain_fingerprint);
            record.event_chain_fingerprint = next_chain;
            record.status_event_count += 1;
            record.source_event_count += 1;
            continue;
        }
        if (!std.mem.eql(u8, event, "capture")) {
            validation.add("unknown event", stored.diagnostic_position);
            continue;
        }
        const raw_record = obj.get("record") orelse {
            validation.add("capture missing record object", stored.diagnostic_position);
            continue;
        };
        const record_obj = switch (raw_record) {
            .object => |value| value,
            else => {
                validation.add("capture missing record object", stored.diagnostic_position);
                continue;
            },
        };
        const status = jsonStringField(obj, "status") orelse jsonStringField(record_obj, "status") orelse "unknown";
        if (findRecord(records.items, neg_id)) |idx| {
            validation.add("duplicate capture neg_id", stored.diagnostic_position);
            _ = idx;
            continue;
        }
        const version = jsonIntegerField(obj, "v") orelse 1;
        if (version >= 3) {
            if (!validEventIdentity(obj)) validation.add("capture event lacks typed identity", stored.diagnostic_position);
            if (!isInitialCaptureStatus(status)) validation.add("capture event has lifecycle-only initial status", stored.diagnostic_position);
        }
        const legacy_requires_evidence = version < 3 and
            (std.mem.eql(u8, status, "active") or !isInitialCaptureStatus(status));
        const projected_status = if (legacy_requires_evidence) "need-evidence" else status;
        var record = try initRecordFromObject(allocator, neg_id, projected_status, raw_record);
        errdefer record.deinit(allocator);
        allocator.free(record.event_chain_fingerprint);
        record.event_chain_fingerprint = try eventChainFingerprintAlloc(allocator, "", line);
        record.capture_event_count = 1;
        record.source_event_count = 1;
        try records.append(allocator, record);
    }
    for (records.items) |record| validateProjectedRecord(record, &validation);
    return .{ .records = records, .validation = validation };
}

fn initRecordFromObject(allocator: std.mem.Allocator, neg_id: []const u8, status: []const u8, raw_record: std.json.Value) !Record {
    const record_obj = switch (raw_record) {
        .object => |value| value,
        else => return error.InvalidCaptureJson,
    };
    const route_or_model_id = jsonStringField(record_obj, "route_or_model_id") orelse "";
    return .{
        .neg_id = try allocator.dupe(u8, neg_id),
        .status = try allocator.dupe(u8, status),
        .record_version = try allocator.dupe(u8, jsonStringField(record_obj, "record_version") orelse ""),
        .kind = try allocator.dupe(u8, jsonStringField(record_obj, "kind") orelse ""),
        .hypothesis = try allocator.dupe(u8, jsonStringField(record_obj, "hypothesis") orelse ""),
        .route_id = try allocator.dupe(u8, jsonStringField(record_obj, "route_id") orelse jsonStringField(record_obj, "route") orelse ""),
        .route_family_id = try allocator.dupe(u8, jsonStringField(record_obj, "route_family_id") orelse route_or_model_id),
        .cluster_id = try allocator.dupe(u8, jsonStringField(record_obj, "cluster_id") orelse jsonStringField(record_obj, "cluster") orelse ""),
        .authority_model_id = try allocator.dupe(u8, jsonStringField(record_obj, "authority_model_id") orelse route_or_model_id),
        .distinction_pattern_id = try allocator.dupe(u8, jsonStringField(record_obj, "distinction_pattern_id") orelse route_or_model_id),
        .proof_pattern_id = try allocator.dupe(u8, jsonStringField(record_obj, "proof_pattern_id") orelse route_or_model_id),
        .artifact_state_id = try allocator.dupe(u8, jsonStringField(record_obj, "artifact_state_id") orelse jsonStringField(record_obj, "artifact") orelse ""),
        .artifact_state_label = try allocator.dupe(u8, jsonStringField(record_obj, "artifact_state_label") orelse ""),
        .repository_id = try allocator.dupe(u8, jsonStringField(record_obj, "repository_id") orelse ""),
        .attempted_change = try allocator.dupe(u8, jsonStringField(record_obj, "attempted_change") orelse ""),
        .observed_outcome = try allocator.dupe(u8, jsonStringField(record_obj, "observed_outcome") orelse ""),
        .exclusion_scope = try allocator.dupe(u8, jsonStringField(record_obj, "exclusion_scope") orelse "route"),
        .exclusion_rule = try allocator.dupe(u8, jsonStringField(record_obj, "exclusion_rule") orelse ""),
        .failure_class = try allocator.dupe(u8, jsonStringField(record_obj, "failure_class") orelse "unknown"),
        .confidence = try allocator.dupe(u8, jsonStringField(record_obj, "confidence") orelse "unknown"),
        .next_search_hint = try allocator.dupe(u8, jsonStringField(record_obj, "next_search_hint") orelse ""),
        .record_json = try jsonValueAlloc(allocator, raw_record),
        .event_chain_fingerprint = try allocator.dupe(u8, ""),
        .prior_projection_fingerprint = try allocator.dupe(u8, ""),
        .source_refs_count = jsonArrayCount(record_obj, "source_refs"),
        .applicability_conditions_count = jsonArrayCount(record_obj, "applicability_conditions"),
        .reopening_criteria_count = jsonArrayCount(record_obj, "reopening_criteria"),
    };
}

fn validateProjectedRecord(record: Record, validation: *ValidationIssue) void {
    validateRecordForStatus(record, record.status, validation);
}

fn validateRecordForStatus(record: Record, status: []const u8, validation: *ValidationIssue) void {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, record.record_json, .{}) catch {
        validation.add("record json is invalid", null);
        return;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => {
            validation.add("record is not an object", null);
            return;
        },
    };
    if (!isKnownStatus(record.status)) validation.add("unknown status", null);
    if (!isKnownExclusionScope(record.exclusion_scope)) {
        validation.add("unknown exclusion_scope", null);
    }
    if (!optionalStringFieldsWellTyped(obj)) validation.add("record string field has invalid type", null);
    if (!sourceRefsValueValid(obj.get("source_refs"))) validation.add("record has invalid source_refs", null);
    if (!stringArrayValueValid(obj.get("falsifying_evidence"), true)) validation.add("record has invalid falsifying_evidence", null);
    if (!stringArrayValueValid(obj.get("applicability_conditions"), true)) validation.add("record has invalid applicability_conditions", null);
    if (!reopeningCriteriaValueValid(obj.get("reopening_criteria"))) validation.add("record has invalid reopening_criteria", null);
    if (!std.mem.eql(u8, status, "active")) return;
    if (jsonStringField(obj, "exclusion_scope") == null) validation.add("active record missing explicit exclusion_scope", null);
    if (!std.mem.eql(u8, record.record_version, "NER-v2")) validation.add("active record has unsupported record_version", null);
    if (!isKnownNegativeEvidenceKind(record.kind)) validation.add("active record has invalid kind", null);
    if (record.hypothesis.len == 0) validation.add("active record missing hypothesis", null);
    if (stringFieldOrEmpty(obj, "attempted_change").len == 0) validation.add("active record missing attempted_change", null);
    if (stringFieldOrEmpty(obj, "observed_outcome").len == 0) validation.add("active record missing observed_outcome", null);
    if (!isActionableFailureClass(record.failure_class)) validation.add("active record has invalid failure_class", null);
    if (!isActiveConfidence(record.confidence)) validation.add("active record has invalid confidence", null);
    if (record.next_search_hint.len == 0) validation.add("active record missing next_search_hint", null);
    if (record.source_refs_count == 0) validation.add("active record missing source_refs", null);
    if (!scopeIdentityComplete(record)) validation.add("active record missing scope identity", null);
    if (!isImmutableArtifactIdentity(record.artifact_state_id)) validation.add("active record lacks immutable artifact identity", null);
    if (record.exclusion_rule.len == 0) validation.add("active record missing exclusion_rule", null);
    if (record.applicability_conditions_count == 0) validation.add("active record missing applicability_conditions", null);
    if (record.reopening_criteria_count == 0) validation.add("active record missing reopening_criteria", null);
}

fn recordActiveComplete(record: Record) bool {
    return std.mem.eql(u8, record.record_version, "NER-v2") and
        isKnownNegativeEvidenceKind(record.kind) and
        record.source_refs_count > 0 and
        record.hypothesis.len > 0 and
        record.attempted_change.len > 0 and
        record.observed_outcome.len > 0 and
        record.exclusion_rule.len > 0 and
        record.applicability_conditions_count > 0 and
        record.reopening_criteria_count > 0 and
        record.next_search_hint.len > 0 and
        isActionableFailureClass(record.failure_class) and
        isActiveConfidence(record.confidence) and
        isImmutableArtifactIdentity(record.artifact_state_id) and
        scopeIdentityComplete(record);
}

fn recordCanBlock(record: Record) bool {
    return std.mem.eql(u8, record.status, "active") and recordActiveComplete(record);
}

fn scopeIdentityComplete(record: Record) bool {
    if (std.mem.eql(u8, record.exclusion_scope, "exact") or std.mem.eql(u8, record.exclusion_scope, "route")) return record.route_id.len > 0;
    if (std.mem.eql(u8, record.exclusion_scope, "route_family")) return record.route_family_id.len > 0;
    if (std.mem.eql(u8, record.exclusion_scope, "cluster")) return record.cluster_id.len > 0;
    if (std.mem.eql(u8, record.exclusion_scope, "authority_model")) return record.authority_model_id.len > 0;
    if (std.mem.eql(u8, record.exclusion_scope, "distinction_pattern")) return record.distinction_pattern_id.len > 0;
    if (std.mem.eql(u8, record.exclusion_scope, "proof_pattern")) return record.proof_pattern_id.len > 0;
    return false;
}

fn recordScopeIdentity(record: Record) []const u8 {
    if (std.mem.eql(u8, record.exclusion_scope, "exact") or std.mem.eql(u8, record.exclusion_scope, "route")) return record.route_id;
    if (std.mem.eql(u8, record.exclusion_scope, "route_family")) return record.route_family_id;
    if (std.mem.eql(u8, record.exclusion_scope, "cluster")) return record.cluster_id;
    if (std.mem.eql(u8, record.exclusion_scope, "authority_model")) return record.authority_model_id;
    if (std.mem.eql(u8, record.exclusion_scope, "distinction_pattern")) return record.distinction_pattern_id;
    if (std.mem.eql(u8, record.exclusion_scope, "proof_pattern")) return record.proof_pattern_id;
    return &.{};
}

fn hasMapIdentity(args: Args) bool {
    return args.route.len > 0 or args.cluster.len > 0 or args.route_family.len > 0 or args.authority_model.len > 0 or args.distinction_pattern.len > 0 or args.proof_pattern.len > 0;
}

fn scopeMatches(record: Record, args: Args) bool {
    if (std.mem.eql(u8, record.exclusion_scope, "exact") or std.mem.eql(u8, record.exclusion_scope, "route")) return args.route.len > 0 and std.mem.eql(u8, args.route, record.route_id);
    if (std.mem.eql(u8, record.exclusion_scope, "route_family")) return args.route_family.len > 0 and std.mem.eql(u8, args.route_family, record.route_family_id);
    if (std.mem.eql(u8, record.exclusion_scope, "cluster")) return args.cluster.len > 0 and std.mem.eql(u8, args.cluster, record.cluster_id);
    if (std.mem.eql(u8, record.exclusion_scope, "authority_model")) return args.authority_model.len > 0 and std.mem.eql(u8, args.authority_model, record.authority_model_id);
    if (std.mem.eql(u8, record.exclusion_scope, "distinction_pattern")) return args.distinction_pattern.len > 0 and std.mem.eql(u8, args.distinction_pattern, record.distinction_pattern_id);
    if (std.mem.eql(u8, record.exclusion_scope, "proof_pattern")) return args.proof_pattern.len > 0 and std.mem.eql(u8, args.proof_pattern, record.proof_pattern_id);
    return false;
}

fn scopeNearMatches(record: Record, args: Args) bool {
    return lexicalOverlap(args.route, record.route_id) or
        lexicalOverlap(args.cluster, record.cluster_id) or
        lexicalOverlap(args.route_family, record.route_family_id) or
        lexicalOverlap(args.authority_model, record.authority_model_id) or
        lexicalOverlap(args.distinction_pattern, record.distinction_pattern_id) or
        lexicalOverlap(args.proof_pattern, record.proof_pattern_id);
}

fn isKnownNegativeEvidenceKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "realization_route") or
        std.mem.eql(u8, kind, "authority_model") or
        std.mem.eql(u8, kind, "kernel_distinction") or
        std.mem.eql(u8, kind, "proof_pattern");
}

fn isActionableFailureClass(failure_class: []const u8) bool {
    return std.mem.eql(u8, failure_class, "no-effect") or
        std.mem.eql(u8, failure_class, "local-regression") or
        std.mem.eql(u8, failure_class, "global-regression") or
        std.mem.eql(u8, failure_class, "unsound") or
        std.mem.eql(u8, failure_class, "too-complex") or
        std.mem.eql(u8, failure_class, "stale");
}

fn isActiveConfidence(confidence: []const u8) bool {
    return std.mem.eql(u8, confidence, "high") or std.mem.eql(u8, confidence, "medium") or std.mem.eql(u8, confidence, "low");
}

fn allowedStatusTransition(from: []const u8, to: []const u8) bool {
    if (std.mem.eql(u8, from, to) or !isKnownStatus(from) or !isKnownStatus(to)) return false;
    if (std.mem.eql(u8, from, "superseded")) return false;
    if (std.mem.eql(u8, to, "capture_candidate") or std.mem.eql(u8, to, "need-evidence") or std.mem.eql(u8, to, "unknown")) {
        return std.mem.eql(u8, from, "capture_candidate") or std.mem.eql(u8, from, "need-evidence") or std.mem.eql(u8, from, "unknown");
    }
    if (std.mem.eql(u8, to, "active")) return !std.mem.eql(u8, from, "active") and !std.mem.eql(u8, from, "superseded");
    if (std.mem.eql(u8, to, "reopened")) return std.mem.eql(u8, from, "active") or std.mem.eql(u8, from, "accepted_risk") or std.mem.eql(u8, from, "stale");
    return std.mem.eql(u8, to, "accepted_risk") or std.mem.eql(u8, to, "stale") or std.mem.eql(u8, to, "superseded");
}

fn validEventIdentity(obj: std.json.ObjectMap) bool {
    const event_id = jsonStringField(obj, "event_id") orelse return false;
    const timestamp = jsonStringField(obj, "timestamp") orelse return false;
    return event_id.len > 0 and isUtcTimestamp(timestamp);
}

fn isUtcTimestamp(value: []const u8) bool {
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') return false;
    for (value, 0..) |char, idx| {
        if (idx == 4 or idx == 7 or idx == 10 or idx == 13 or idx == 16 or idx == 19) continue;
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
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

fn isInitialCaptureStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "capture_candidate") or
        std.mem.eql(u8, status, "need-evidence") or
        std.mem.eql(u8, status, "unknown") or
        std.mem.eql(u8, status, "active");
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

fn validateCaptureInput(obj: std.json.ObjectMap) !void {
    const exclusion_scope = jsonStringField(obj, "exclusion_scope") orelse "route";
    if (!isKnownExclusionScope(exclusion_scope)) return error.InvalidExclusionScope;
    if (jsonStringField(obj, "status")) |status| {
        if (!isKnownStatus(status)) return error.InvalidStatus;
        if (!isInitialCaptureStatus(status)) return error.InvalidInitialStatus;
    }
    if (!optionalStringFieldsWellTyped(obj)) return error.InvalidCaptureFieldType;
    if (obj.get("source_refs") != null and !sourceRefsValueValid(obj.get("source_refs"))) return error.InvalidSourceRefs;
    if (!stringArrayValueValid(obj.get("falsifying_evidence"), true)) return error.InvalidFalsifyingEvidence;
    if (!stringArrayValueValid(obj.get("applicability_conditions"), true)) return error.InvalidApplicabilityConditions;
    if (!reopeningCriteriaValueValid(obj.get("reopening_criteria"))) return error.InvalidReopeningCriteria;
    if (!stringArrayValueValid(obj.get("applicable_paths"), true)) return error.InvalidApplicablePaths;
    if (jsonStringField(obj, "record_version")) |version| {
        if (!std.mem.eql(u8, version, "NER-v2")) return error.InvalidRecordVersion;
    }
    if (jsonStringField(obj, "kind")) |kind| {
        if (!isKnownNegativeEvidenceKind(kind)) return error.InvalidNegativeEvidenceKind;
    }
    if (jsonStringField(obj, "failure_class")) |failure_class| {
        if (!isKnownFailureClass(failure_class)) return error.InvalidFailureClass;
    }
    if (jsonStringField(obj, "confidence")) |confidence| {
        if (!isKnownConfidence(confidence)) return error.InvalidConfidence;
    }
}

fn optionalStringFieldsWellTyped(obj: std.json.ObjectMap) bool {
    inline for (&.{
        "record_version",
        "kind",
        "route_or_model_id",
        "route_id",
        "route",
        "route_family_id",
        "cluster_id",
        "cluster",
        "authority_model_id",
        "distinction_pattern_id",
        "proof_pattern_id",
        "artifact_state_id",
        "artifact_state_label",
        "artifact",
        "hypothesis",
        "attempted_change",
        "observed_outcome",
        "failure_class",
        "exclusion_scope",
        "exclusion_rule",
        "confidence",
        "next_search_hint",
        "repository_id",
        "surface",
        "status",
    }) |key| {
        if (obj.get(key)) |value| if (value != .string) return false;
    }
    return true;
}

fn sourceRefsValueValid(value: ?std.json.Value) bool {
    const refs = value orelse return true;
    if (refs != .array) return false;
    for (refs.array.items) |item| {
        if (item != .object) return false;
        if (stringFieldOrEmpty(item.object, "kind").len == 0) return false;
        if (stringFieldOrEmpty(item.object, "ref").len == 0) return false;
        if (item.object.get("summary")) |summary| if (summary != .string) return false;
    }
    return true;
}

fn stringArrayValueValid(value: ?std.json.Value, allow_missing: bool) bool {
    const items = value orelse return allow_missing;
    if (items != .array) return false;
    for (items.array.items) |item| if (item != .string or item.string.len == 0) return false;
    return true;
}

fn reopeningCriteriaValueValid(value: ?std.json.Value) bool {
    const criteria = value orelse return true;
    if (criteria != .array) return false;
    for (criteria.array.items) |item| {
        if (item != .object) return false;
        if (stringFieldOrEmpty(item.object, "id").len == 0) return false;
        if (stringFieldOrEmpty(item.object, "condition").len == 0) return false;
    }
    return true;
}

fn normalizedCaptureRecordAlloc(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    artifact: ResolvedArtifact,
    repository_id: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('{');
    var wrote = false;
    var iterator = obj.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "artifact_state_id") or
            std.mem.eql(u8, entry.key_ptr.*, "artifact_state_label") or
            std.mem.eql(u8, entry.key_ptr.*, "artifact") or
            std.mem.eql(u8, entry.key_ptr.*, "repository_id")) continue;
        if (wrote) try out.writer.writeByte(',');
        wrote = true;
        try writeJsonString(&out.writer, entry.key_ptr.*);
        try out.writer.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer);
    }
    if (wrote) try out.writer.writeByte(',');
    try out.writer.writeAll("\"artifact_state_id\":");
    try writeJsonString(&out.writer, artifact.id);
    try out.writer.writeAll(",\"artifact_state_label\":");
    try writeJsonString(&out.writer, artifact.label);
    try out.writer.writeAll(",\"repository_id\":");
    try writeJsonString(&out.writer, repository_id);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn resolveArtifactIdentityAlloc(
    allocator: std.mem.Allocator,
    store_path: []const u8,
    raw_id: []const u8,
    explicit_label: []const u8,
) !ResolvedArtifact {
    const label = if (explicit_label.len > 0) explicit_label else raw_id;
    if (raw_id.len == 0) return .{ .id = try allocator.dupe(u8, ""), .label = try allocator.dupe(u8, label) };
    if (isImmutableArtifactIdentity(raw_id)) return .{ .id = try allocator.dupe(u8, raw_id), .label = try allocator.dupe(u8, label) };

    var revision_text = raw_id;
    var output_prefix: []const u8 = "";
    var resolve_tree = false;
    if (std.mem.startsWith(u8, raw_id, "commit:")) {
        revision_text = raw_id["commit:".len..];
        output_prefix = "commit:";
    } else if (std.mem.startsWith(u8, raw_id, "tree:")) {
        revision_text = raw_id["tree:".len..];
        output_prefix = "tree:";
        resolve_tree = true;
    } else if (std.mem.startsWith(u8, raw_id, "sha256:") or std.mem.startsWith(u8, raw_id, "surface:")) {
        return .{ .id = try allocator.dupe(u8, ""), .label = try allocator.dupe(u8, label) };
    }
    if (revision_text.len == 0) return .{ .id = try allocator.dupe(u8, ""), .label = try allocator.dupe(u8, label) };

    const git_root = findGitRootForStoreAlloc(allocator, store_path) catch
        return .{ .id = try allocator.dupe(u8, ""), .label = try allocator.dupe(u8, label) };
    defer allocator.free(git_root);
    const revision = if (resolve_tree)
        try std.fmt.allocPrint(allocator, "{s}^{{tree}}", .{revision_text})
    else
        try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{revision_text});
    defer allocator.free(revision);
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = &.{ "git", "-C", git_root, "rev-parse", "--verify", revision },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) {
        const resolved = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (isGitObjectId(resolved)) {
            const identity = if (output_prefix.len == 0)
                try allocator.dupe(u8, resolved)
            else
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ output_prefix, resolved });
            return .{ .id = identity, .label = try allocator.dupe(u8, label) };
        }
    }
    return .{ .id = try allocator.dupe(u8, ""), .label = try allocator.dupe(u8, label) };
}

fn resolveRepositoryIdForStoreAlloc(allocator: std.mem.Allocator, store_path: []const u8, configured: []const u8) ![]u8 {
    if (configured.len > 0) return allocator.dupe(u8, configured);
    const git_root = findGitRootForStoreAlloc(allocator, store_path) catch return allocator.dupe(u8, "");
    defer allocator.free(git_root);
    return gitRepositoryIdAlloc(allocator, git_root) catch allocator.dupe(u8, "");
}

fn findGitRootForStoreAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    var probe = std.fs.path.dirname(store_path) orelse ".";
    while (true) {
        if (durable_store.findGitRootAlloc(allocator, probe)) |root| return root else |_| {}
        const parent = std.fs.path.dirname(probe) orelse {
            if (std.mem.eql(u8, probe, ".")) return error.GitCommandFailed;
            probe = ".";
            continue;
        };
        if (std.mem.eql(u8, parent, probe)) return error.GitCommandFailed;
        probe = parent;
    }
}

fn isImmutableArtifactIdentity(value: []const u8) bool {
    if (isGitObjectId(value)) return true;
    if (std.mem.startsWith(u8, value, "commit:")) return isGitObjectId(value["commit:".len..]);
    if (std.mem.startsWith(u8, value, "tree:")) return isGitObjectId(value["tree:".len..]);
    if (std.mem.startsWith(u8, value, "sha256:")) return isHexDigest(value["sha256:".len..], 64);
    if (std.mem.startsWith(u8, value, "surface:")) return isHexDigest(value["surface:".len..], 64);
    return false;
}

fn isGitObjectId(value: []const u8) bool {
    return (value.len == 40 or value.len == 64) and isHexDigest(value, value.len);
}

fn isHexDigest(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

const TransitionProof = struct {
    reason: []u8,
    source_refs_json: []u8,
    criterion_ids_json: []u8,
    criterion_changes_json: []u8,
    source_refs_count: usize,
    criterion_ids_count: usize,
    criterion_changes_count: usize,

    fn deinit(self: *TransitionProof, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        allocator.free(self.source_refs_json);
        allocator.free(self.criterion_ids_json);
        allocator.free(self.criterion_changes_json);
    }
};

fn readTransitionProof(allocator: std.mem.Allocator, args: Args) !TransitionProof {
    if (args.json_path == null) {
        return .{
            .reason = try allocator.dupe(u8, args.reason),
            .source_refs_json = try allocator.dupe(u8, "[]"),
            .criterion_ids_json = try allocator.dupe(u8, "[]"),
            .criterion_changes_json = try allocator.dupe(u8, "[]"),
            .source_refs_count = 0,
            .criterion_ids_count = 0,
            .criterion_changes_count = 0,
        };
    }
    const input = try readCaptureInput(allocator, args.json_path.?);
    defer allocator.free(input);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidTransitionProof,
    };
    const reason = jsonStringField(obj, "reason") orelse args.reason;
    if (obj.get("source_refs") == null or !sourceRefsValueValid(obj.get("source_refs"))) return error.InvalidTransitionSourceRefs;
    if (!criterionChangesValueValid(obj.get("criterion_changes"))) return error.InvalidTransitionCriteria;
    const criterion_ids_json = try criterionIdsFromChangesAlloc(allocator, obj.get("criterion_changes"));
    errdefer allocator.free(criterion_ids_json);
    return .{
        .reason = try allocator.dupe(u8, reason),
        .source_refs_json = if (obj.get("source_refs")) |value| try jsonValueAlloc(allocator, value) else try allocator.dupe(u8, "[]"),
        .criterion_ids_json = criterion_ids_json,
        .criterion_changes_json = if (obj.get("criterion_changes")) |value| try jsonValueAlloc(allocator, value) else try allocator.dupe(u8, "[]"),
        .source_refs_count = jsonArrayCount(obj, "source_refs"),
        .criterion_ids_count = jsonArrayCount(obj, "criterion_changes"),
        .criterion_changes_count = jsonArrayCount(obj, "criterion_changes"),
    };
}

fn criterionChangesValueValid(value: ?std.json.Value) bool {
    const changes = value orelse return true;
    if (changes != .array) return false;
    for (changes.array.items) |item| {
        if (item != .object) return false;
        const criterion_id = stringFieldOrEmpty(item.object, "criterion_id");
        const before = stringFieldOrEmpty(item.object, "before");
        const after = stringFieldOrEmpty(item.object, "after");
        if (criterion_id.len == 0 or before.len == 0 or after.len == 0 or std.mem.eql(u8, before, after)) return false;
    }
    return true;
}

fn criterionIdsFromChangesAlloc(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    const changes = value orelse return allocator.dupe(u8, "[]");
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (changes.array.items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeJsonString(&out.writer, jsonStringField(item.object, "criterion_id").?);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn criterionIdsMatchChanges(ids_value: ?std.json.Value, changes_value: ?std.json.Value) bool {
    const ids = ids_value orelse return false;
    const changes = changes_value orelse return false;
    if (ids != .array or changes != .array or ids.array.items.len != changes.array.items.len) return false;
    for (changes.array.items) |change| {
        const criterion_id = jsonStringField(change.object, "criterion_id") orelse return false;
        var found = false;
        for (ids.array.items) |id| {
            if (id == .string and std.mem.eql(u8, id.string, criterion_id)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn transitionCriteriaBelongToRecord(allocator: std.mem.Allocator, record: Record, criterion_ids_json: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, criterion_ids_json, .{});
    defer parsed.deinit();
    return transitionCriteriaBelongToRecordValue(allocator, record, parsed.value);
}

fn transitionCriteriaBelongToRecordValue(allocator: std.mem.Allocator, record: Record, criterion_ids: ?std.json.Value) !bool {
    const requested = criterion_ids orelse return false;
    if (requested != .array or requested.array.items.len == 0) return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record.record_json, .{});
    defer parsed.deinit();
    const record_obj = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const criteria_value = record_obj.get("reopening_criteria") orelse return false;
    if (criteria_value != .array) return false;
    for (requested.array.items) |item| {
        if (item != .string or item.string.len == 0) return false;
        var found = false;
        for (criteria_value.array.items) |criterion| {
            if (criterion == .object and std.mem.eql(u8, item.string, jsonStringField(criterion.object, "id") orelse "")) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
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

fn stringFieldOrEmpty(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return jsonStringField(obj, key) orelse &.{};
}

fn jsonIntegerField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
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

fn isKnownFailureClass(failure_class: []const u8) bool {
    return isActionableFailureClass(failure_class) or std.mem.eql(u8, failure_class, "unknown");
}

fn isKnownConfidence(confidence: []const u8) bool {
    return isActiveConfidence(confidence) or std.mem.eql(u8, confidence, "unknown");
}

fn jsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeCanonicalJson(allocator, &out.writer, value);
    return out.toOwnedSlice();
}

fn writeCanonicalJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |number| {
            if (!std.math.isFinite(number)) return error.NonFiniteNumber;
            try std.json.Stringify.value(number, .{}, writer);
        },
        .number_string => return error.NumberOutOfRange,
        .string => |text| try std.json.Stringify.value(text, .{}, writer),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeCanonicalJson(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(allocator);
            var iterator = object.iterator();
            while (iterator.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.lessThan(u8, left, right);
                }
            }.lessThan);
            try writer.writeByte('{');
            for (keys.items, 0..) |key, index| {
                if (index > 0) try writer.writeByte(',');
                try std.json.Stringify.value(key, .{}, writer);
                try writer.writeByte(':');
                try writeCanonicalJson(allocator, writer, object.get(key).?);
            }
            try writer.writeByte('}');
        },
    }
}

fn projectionFingerprintAlloc(allocator: std.mem.Allocator, record: Record) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("negative-ledger-projection/v3\n");
    hasher.update(record.neg_id);
    hasher.update("\n");
    hasher.update(record.status);
    hasher.update("\n");
    hasher.update(record.record_json);
    hasher.update("\n");
    hasher.update(record.repository_id);
    hasher.update("\n");
    hasher.update(record.event_chain_fingerprint);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn eventChainFingerprintAlloc(allocator: std.mem.Allocator, previous: []const u8, event_bytes: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("negative-ledger-event-chain/v1\n");
    hasher.update(previous);
    hasher.update("\n");
    hasher.update(event_bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn eventIdAlloc(allocator: std.mem.Allocator, kind: []const u8, neg_id: []const u8, timestamp: []const u8, material: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("negative-ledger-event/v1\n");
    hasher.update(kind);
    hasher.update("\n");
    hasher.update(neg_id);
    hasher.update("\n");
    hasher.update(timestamp);
    hasher.update("\n");
    hasher.update(material);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "NLE-{s}", .{encoded[0..24]});
}

fn sha256HexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn resolveRepositoryScopeAlloc(allocator: std.mem.Allocator, store_path: []const u8, record: Record) !RepositoryScope {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record.record_json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidCaptureJson,
    };

    const git_root = findGitRootForStoreAlloc(allocator, store_path) catch null;
    defer if (git_root) |root| allocator.free(root);
    const repository_id = if (record.repository_id.len > 0)
        try allocator.dupe(u8, record.repository_id)
    else if (git_root) |root|
        try gitRepositoryIdAlloc(allocator, root)
    else
        return error.MissingRepositoryIdentity;
    errdefer allocator.free(repository_id);

    const ledger_path = if (git_root) |root|
        if (std.fs.path.isAbsolute(store_path))
            try std.fs.path.relative(allocator, root, null, root, store_path)
        else
            try allocator.dupe(u8, store_path)
    else
        try allocator.dupe(u8, store_path);
    errdefer allocator.free(ledger_path);

    var paths_json: []u8 = undefined;
    if (obj.get("applicable_paths")) |paths| {
        if (!stringArrayValueValid(paths, false) or paths.array.items.len == 0) return error.MissingApplicableScope;
        paths_json = try jsonValueAlloc(allocator, paths);
    } else if (jsonStringField(obj, "surface")) |surface| {
        if (surface.len == 0) return error.MissingApplicableScope;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeByte('[');
        try writeJsonString(&out.writer, surface);
        try out.writer.writeByte(']');
        paths_json = try out.toOwnedSlice();
    } else {
        return error.MissingApplicableScope;
    }
    return .{ .id = repository_id, .ledger_path = ledger_path, .paths_json = paths_json };
}

fn gitRepositoryIdAlloc(allocator: std.mem.Allocator, git_root: []const u8) ![]u8 {
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = &.{ "git", "-C", git_root, "config", "--get", "remote.origin.url" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return error.MissingRepositoryIdentity;
    const remote = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (remote.len == 0) return error.MissingRepositoryIdentity;
    return normalizeRepositoryIdAlloc(allocator, remote);
}

fn normalizeRepositoryIdAlloc(allocator: std.mem.Allocator, remote: []const u8) ![]u8 {
    var value = remote;
    inline for (&.{ "git@github.com:", "https://github.com/", "http://github.com/", "ssh://git@github.com/" }) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) {
            value = value[prefix.len..];
            break;
        }
    }
    if (std.mem.endsWith(u8, value, ".git")) value = value[0 .. value.len - 4];
    if (value.len == 0) return error.MissingRepositoryIdentity;
    return allocator.dupe(u8, value);
}

fn writeFullProjection(
    allocator: std.mem.Allocator,
    writer: anytype,
    repository_scope: RepositoryScope,
    record: Record,
    projection_fingerprint: []const u8,
    exported_at: ?[]const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record.record_json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidCaptureJson,
    };

    try writer.writeAll("{\"schema\":\"negative-ledger-projection/v3\",\"repository_id\":");
    try writeJsonString(writer, repository_scope.id);
    try writer.writeAll(",\"ledger_path\":");
    try writeJsonString(writer, repository_scope.ledger_path);
    try writer.writeAll(",\"applicable_paths\":");
    try writer.writeAll(repository_scope.paths_json);
    try writer.writeAll(",\"neg_id\":");
    try writeJsonString(writer, record.neg_id);
    try writer.writeAll(",\"record_version\":");
    try writeJsonString(writer, record.record_version);
    try writer.writeAll(",\"campaign_id\":");
    try writeJsonString(writer, jsonStringField(obj, "campaign_id") orelse "");
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, record.status);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, record.kind);
    try writer.writeAll(",\"kernel_law_ids\":");
    try writeJsonArrayField(writer, obj, "kernel_law_ids");
    try writer.writeAll(",\"counterexample_family_ids\":");
    try writeJsonArrayField(writer, obj, "counterexample_family_ids");
    try writer.writeAll(",\"route_or_model_id\":");
    try writeJsonString(writer, jsonStringField(obj, "route_or_model_id") orelse recordScopeIdentity(record));
    try writer.writeAll(",\"route_id\":");
    try writeJsonString(writer, record.route_id);
    try writer.writeAll(",\"route_family_id\":");
    try writeJsonString(writer, record.route_family_id);
    try writer.writeAll(",\"cluster_id\":");
    try writeJsonString(writer, record.cluster_id);
    try writer.writeAll(",\"authority_model_id\":");
    try writeJsonString(writer, record.authority_model_id);
    try writer.writeAll(",\"distinction_pattern_id\":");
    try writeJsonString(writer, record.distinction_pattern_id);
    try writer.writeAll(",\"proof_pattern_id\":");
    try writeJsonString(writer, record.proof_pattern_id);
    try writer.writeAll(",\"artifact_state_id\":");
    try writeJsonString(writer, record.artifact_state_id);
    try writer.writeAll(",\"artifact_state_label\":");
    try writeJsonString(writer, record.artifact_state_label);
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
    try writer.print(",\"capture_event_count\":{d},\"status_event_count\":{d},\"source_event_count\":{d},\"event_chain_fingerprint\":", .{
        record.capture_event_count,
        record.status_event_count,
        record.source_event_count,
    });
    try writeJsonString(writer, record.event_chain_fingerprint);
    try writer.writeAll(",\"previous_projection_fingerprint\":");
    if (record.prior_projection_fingerprint.len > 0) try writeJsonString(writer, record.prior_projection_fingerprint) else try writer.writeAll("null");
    try writer.writeAll(",\"projection_fingerprint\":");
    try writeJsonString(writer, projection_fingerprint);
    if (exported_at) |timestamp| {
        try writer.writeAll(",\"exported_at\":");
        try writeJsonString(writer, timestamp);
    }
    try writer.writeByte('}');
}

fn writeLedgerMemoryNoteInput(
    allocator: std.mem.Allocator,
    writer: anytype,
    repository_scope: RepositoryScope,
    record: Record,
    projection_fingerprint: []const u8,
) !void {
    try writer.writeAll("{\"operation\":");
    try writeJsonString(writer, if (std.mem.eql(u8, record.status, "reopened")) "reopen" else "assert");
    try writer.writeAll(",\"authority\":\"ledger-cli\",\"summary\":");
    const summary = try std.fmt.allocPrint(allocator, "{s} {s} negative-evidence projection", .{ record.neg_id, record.status });
    defer allocator.free(summary);
    try writeJsonString(writer, summary);
    try writer.writeAll(",\"scope\":{\"kind\":\"repo\",\"repo\":");
    try writeJsonString(writer, repository_scope.id);
    try writer.writeAll(",\"paths\":");
    try writer.writeAll(repository_scope.paths_json);
    try writer.writeAll("},\"source_refs\":[{\"kind\":\"negative-ledger\",\"ref\":");
    const ref = try std.fmt.allocPrint(allocator, "{s}:{s}#{s}", .{ repository_scope.id, repository_scope.ledger_path, record.neg_id });
    defer allocator.free(ref);
    try writeJsonString(writer, ref);
    try writer.writeAll(",\"summary\":\"Canonical ledger export\"}],\"related_ids\":[");
    if (record.prior_projection_fingerprint.len > 0) {
        const prior_ref = try std.fmt.allocPrint(allocator, "projection:{s}", .{record.prior_projection_fingerprint});
        defer allocator.free(prior_ref);
        try writeJsonString(writer, prior_ref);
    }
    try writer.writeAll("],\"supersedes_id\":null,\"payload\":");
    try writeFullProjection(allocator, writer, repository_scope, record, projection_fingerprint, null);
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
    try writer.writeAll(",\"record_version\":");
    try writeJsonString(writer, record.record_version);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, record.kind);
    try writer.writeAll(",\"hypothesis\":");
    try writeJsonString(writer, record.hypothesis);
    try writer.writeAll(",\"route_id\":");
    try writeJsonString(writer, record.route_id);
    try writer.writeAll(",\"route_family_id\":");
    try writeJsonString(writer, record.route_family_id);
    try writer.writeAll(",\"cluster_id\":");
    try writeJsonString(writer, record.cluster_id);
    try writer.writeAll(",\"authority_model_id\":");
    try writeJsonString(writer, record.authority_model_id);
    try writer.writeAll(",\"distinction_pattern_id\":");
    try writeJsonString(writer, record.distinction_pattern_id);
    try writer.writeAll(",\"proof_pattern_id\":");
    try writeJsonString(writer, record.proof_pattern_id);
    try writer.writeAll(",\"artifact_state_id\":");
    try writeJsonString(writer, record.artifact_state_id);
    try writer.writeAll(",\"artifact_state_label\":");
    try writeJsonString(writer, record.artifact_state_label);
    try writer.writeAll(",\"repository_id\":");
    try writeJsonString(writer, record.repository_id);
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
    try writer.print(",\"source_refs_count\":{d},\"applicability_conditions_count\":{d},\"reopening_criteria_count\":{d},\"capture_event_count\":{d},\"status_event_count\":{d},\"source_event_count\":{d},\"event_chain_fingerprint\":", .{
        record.source_refs_count,
        record.applicability_conditions_count,
        record.reopening_criteria_count,
        record.capture_event_count,
        record.status_event_count,
        record.source_event_count,
    });
    try writeJsonString(writer, record.event_chain_fingerprint);
    try writer.writeAll(",\"previous_projection_fingerprint\":");
    if (record.prior_projection_fingerprint.len > 0) try writeJsonString(writer, record.prior_projection_fingerprint) else try writer.writeAll("null");
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

const TestArtifact = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OtherTestArtifact = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn testActiveCaptureAlloc(
    allocator: std.mem.Allocator,
    exclusion_scope: []const u8,
    identity_key: []const u8,
    identity_value: []const u8,
    artifact_state_id: []const u8,
) ![]u8 {
    return testActiveCaptureForRepositoryAlloc(allocator, exclusion_scope, identity_key, identity_value, artifact_state_id, "tkersey/skills-zig");
}

fn testActiveCaptureForRepositoryAlloc(
    allocator: std.mem.Allocator,
    exclusion_scope: []const u8,
    identity_key: []const u8,
    identity_value: []const u8,
    artifact_state_id: []const u8,
    repository_id: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"record_version\":\"NER-v2\",\"kind\":\"realization_route\",");
    try writeJsonString(&out.writer, identity_key);
    try out.writer.writeByte(':');
    try writeJsonString(&out.writer, identity_value);
    try out.writer.writeAll(",\"artifact_state_id\":");
    try writeJsonString(&out.writer, artifact_state_id);
    try out.writer.writeAll(",\"hypothesis\":\"the selected route is falsified\",\"attempted_change\":\"implemented the selected route\",\"observed_outcome\":\"the representative proof failed\",\"failure_class\":\"no-effect\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"zig build test-ledger\"}],\"falsifying_evidence\":[\"representative proof failed\"],\"exclusion_scope\":");
    try writeJsonString(&out.writer, exclusion_scope);
    try out.writer.writeAll(",\"exclusion_rule\":\"do not retry while the current artifact applies\",\"applicability_conditions\":[\"current artifact and proof surface\"],\"reopening_criteria\":[{\"id\":\"artifact-changed\",\"condition\":\"the artifact or proof surface changed\"}],\"confidence\":\"high\",\"next_search_hint\":\"try an adjacent owner-boundary route\",\"repository_id\":");
    try writeJsonString(&out.writer, repository_id);
    try out.writer.writeAll(",\"applicable_paths\":[\"apps/ledger\"]}");
    return out.toOwnedSlice();
}

fn testMapArgsForScope(scope: []const u8, identity: []const u8, artifact: []const u8) Args {
    var args = Args{ .command = .map, .artifact = artifact };
    if (std.mem.eql(u8, scope, "exact") or std.mem.eql(u8, scope, "route")) {
        args.route = identity;
    } else if (std.mem.eql(u8, scope, "route_family")) {
        args.route_family = identity;
    } else if (std.mem.eql(u8, scope, "cluster")) {
        args.cluster = identity;
    } else if (std.mem.eql(u8, scope, "authority_model")) {
        args.authority_model = identity;
    } else if (std.mem.eql(u8, scope, "distinction_pattern")) {
        args.distinction_pattern = identity;
    } else if (std.mem.eql(u8, scope, "proof_pattern")) {
        args.proof_pattern = identity;
    }
    return args;
}

fn testRunCommand(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) {
        allocator.free(result.stdout);
        return error.TestCommandFailed;
    }
    return result.stdout;
}

fn testRepositoryScopeAlloc(allocator: std.mem.Allocator, id: []const u8) !RepositoryScope {
    return .{
        .id = try allocator.dupe(u8, id),
        .ledger_path = try allocator.dupe(u8, DefaultStorePath),
        .paths_json = try allocator.dupe(u8, "[\"apps/ledger\"]"),
    };
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

test "init lock check accepts an ignored store inside a git repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const gitignore = try std.fs.path.join(std.testing.allocator, &.{ root, ".gitignore" });
    defer std.testing.allocator.free(gitignore);
    try durable_store.writeTextAtomic(std.testing.allocator, gitignore, ".ledger/\n");

    const git_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "git", "init", "--quiet" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer std.testing.allocator.free(git_result.stdout);
    defer std.testing.allocator.free(git_result.stderr);
    try std.testing.expect(git_result.term == .exited and git_result.term.exited == 0);

    const store = try std.fs.path.join(std.testing.allocator, &.{ root, DefaultStorePath });
    defer std.testing.allocator.free(store);
    try ensureInitLockSidecarGitignored(std.testing.allocator, store);
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
    const record = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(record);
    const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"v\":1,\"event\":\"capture\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{s}}}\n", .{record});
    defer std.testing.allocator.free(bytes);
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
    const record = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(record);
    try durable_store.writeTextAtomic(std.testing.allocator, input, record);

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
        .artifact = TestArtifact,
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
    const record = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(record);
    try durable_store.writeTextAtomic(std.testing.allocator, input, record);

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
        .artifact = OtherTestArtifact,
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
    const record = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(record);
    try durable_store.writeTextAtomic(std.testing.allocator, input, record);

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-b",
        .cluster = "cluster-a",
        .artifact = TestArtifact,
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
    const record = try testActiveCaptureAlloc(std.testing.allocator, "cluster", "cluster_id", "cluster-a", TestArtifact);
    defer std.testing.allocator.free(record);
    try durable_store.writeTextAtomic(std.testing.allocator, input, record);

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-b",
        .cluster = "cluster-a",
        .artifact = TestArtifact,
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
    const transition = try std.fs.path.join(std.testing.allocator, &.{ root, "transition.json" });
    defer std.testing.allocator.free(transition);
    const record = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(record);
    try durable_store.writeTextAtomic(std.testing.allocator, input, record);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        transition,
        "{\"reason\":\"the artifact changed\",\"criterion_changes\":[{\"criterion_id\":\"artifact-changed\",\"before\":\"old artifact\",\"after\":\"new artifact\"}],\"source_refs\":[{\"kind\":\"test\",\"ref\":\"new artifact proof\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    try std.testing.expect(try appendStatusEvent(std.testing.allocator, .{ .command = .reopen, .file = store, .id = capture.neg_id, .json_path = transition }, "reopened"));
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
        .artifact = TestArtifact,
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
        "{\"v\":3,\"event\":\"capture\",\"event_id\":\"evt-unsafe\",\"timestamp\":\"2026-07-12T00:00:00Z\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{\"record_version\":\"NER-v2\",\"hypothesis\":\"h\",\"route_id\":\"route-a\"}}\n",
    );

    var loaded = try loadRecordsValidated(std.testing.allocator, store);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.validation.ok());
}

test "pre-NER-v2 active capture projects as recoverable need-evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        store,
        "{\"v\":1,\"event\":\"capture\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{\"hypothesis\":\"legacy route failed\",\"route_id\":\"route-a\",\"artifact_state_id\":\"HEAD\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"legacy proof\"}]}}\n",
    );

    var legacy = try loadRecordsValidated(std.testing.allocator, store);
    defer legacy.deinit(std.testing.allocator);
    try std.testing.expect(legacy.validation.ok());
    try std.testing.expectEqualStrings("need-evidence", legacy.records.items[0].status);
    try std.testing.expectEqual(@as(u8, 0), try mapStatusForStore(std.testing.allocator, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .artifact = TestArtifact,
    }));

    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "replacement.json" });
    defer std.testing.allocator.free(input);
    const replacement = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(replacement);
    try durable_store.writeTextAtomic(std.testing.allocator, input, replacement);
    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("NEG-000002", capture.neg_id);
    try std.testing.expectEqualStrings("active", capture.status);
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

test "legacy proofless authority transitions project as need-evidence" {
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
    try std.testing.expect(promoted_loaded.validation.ok());
    try std.testing.expectEqualStrings("need-evidence", promoted_loaded.records.items[0].status);

    const active_record = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(active_record);
    const reopened_bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"v\":1,\"event\":\"capture\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{s}}}\n{{\"v\":1,\"event\":\"status\",\"neg_id\":\"NEG-000001\",\"status\":\"reopened\"}}\n", .{active_record});
    defer std.testing.allocator.free(reopened_bytes);
    try durable_store.writeTextAtomic(std.testing.allocator, reopened, reopened_bytes);
    var reopened_loaded = try loadRecordsValidated(std.testing.allocator, reopened);
    defer reopened_loaded.deinit(std.testing.allocator);
    try std.testing.expect(reopened_loaded.validation.ok());
    try std.testing.expectEqualStrings("need-evidence", reopened_loaded.records.items[0].status);
}

test "v3 proofless authority transitions are invalid and do not change folded status" {
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
        "{\"v\":3,\"event\":\"capture\",\"event_id\":\"evt-capture\",\"timestamp\":\"2026-07-12T00:00:00Z\",\"neg_id\":\"NEG-000001\",\"status\":\"need-evidence\",\"record\":{\"hypothesis\":\"h\",\"route_id\":\"route-a\"}}\n{\"v\":3,\"event\":\"status\",\"event_id\":\"evt-promote\",\"timestamp\":\"2026-07-12T00:00:01Z\",\"neg_id\":\"NEG-000001\",\"from\":\"need-evidence\",\"to\":\"active\",\"reason\":\"promote without proof\",\"source_refs\":[]}\n",
    );
    var promoted_loaded = try loadRecordsValidated(std.testing.allocator, promoted);
    defer promoted_loaded.deinit(std.testing.allocator);
    try std.testing.expect(!promoted_loaded.validation.ok());
    try std.testing.expectEqualStrings("need-evidence", promoted_loaded.records.items[0].status);

    const active_record = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(active_record);
    const reopened_bytes = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"v\":3,\"event\":\"capture\",\"event_id\":\"evt-capture\",\"timestamp\":\"2026-07-12T00:00:00Z\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{s}}}\n{{\"v\":3,\"event\":\"status\",\"event_id\":\"evt-reopen\",\"timestamp\":\"2026-07-12T00:00:01Z\",\"neg_id\":\"NEG-000001\",\"from\":\"active\",\"to\":\"reopened\",\"reason\":\"reopen without criterion proof\",\"source_refs\":[{{\"kind\":\"test\",\"ref\":\"fixture\"}}]}}\n",
        .{active_record},
    );
    defer std.testing.allocator.free(reopened_bytes);
    try durable_store.writeTextAtomic(std.testing.allocator, reopened, reopened_bytes);
    var reopened_loaded = try loadRecordsValidated(std.testing.allocator, reopened);
    defer reopened_loaded.deinit(std.testing.allocator);
    try std.testing.expect(!reopened_loaded.validation.ok());
    try std.testing.expectEqualStrings("active", reopened_loaded.records.items[0].status);
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

test "capture rejects lifecycle-only initial statuses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const baseline = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(baseline);
    const terminal_statuses = [_][]const u8{ "accepted_risk", "stale", "superseded", "reopened" };

    for (terminal_statuses, 0..) |status, index| {
        const store = try std.fmt.allocPrint(std.testing.allocator, "{s}/terminal-{d}.jsonl", .{ root, index });
        defer std.testing.allocator.free(store);
        const input = try std.fmt.allocPrint(std.testing.allocator, "{s}/terminal-{d}.json", .{ root, index });
        defer std.testing.allocator.free(input);
        const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"status\":\"{s}\",{s}", .{ status, baseline[1..] });
        defer std.testing.allocator.free(payload);
        try durable_store.writeTextAtomic(std.testing.allocator, input, payload);
        try std.testing.expectError(error.InvalidInitialStatus, appendCapture(std.testing.allocator, .{
            .command = .capture,
            .file = store,
            .json_path = input,
        }));
        try std.testing.expect(!durable_store.fileExists(store));
    }
}

test "replay rejects v3 captures with lifecycle-only initial status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const record = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(record);
    const event = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"v\":3,\"event\":\"capture\",\"event_id\":\"evt-capture\",\"timestamp\":\"2026-07-12T00:00:00Z\",\"neg_id\":\"NEG-000001\",\"status\":\"reopened\",\"record\":{s}}}\n",
        .{record},
    );
    defer std.testing.allocator.free(event);
    try durable_store.writeTextAtomic(std.testing.allocator, store, event);

    var loaded = try loadRecordsValidated(std.testing.allocator, store);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.validation.ok());
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
    try std.testing.expectEqualStrings("need-evidence", loaded.records.items[0].status);
}

test "every required active field independently prevents active status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const baseline = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(baseline);
    const required_fields = [_][]const u8{
        "record_version",
        "kind",
        "hypothesis",
        "attempted_change",
        "observed_outcome",
        "failure_class",
        "source_refs",
        "exclusion_scope",
        "route_id",
        "artifact_state_id",
        "exclusion_rule",
        "applicability_conditions",
        "reopening_criteria",
        "confidence",
        "next_search_hint",
    };

    for (required_fields, 0..) |field, index| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, baseline, .{});
        defer parsed.deinit();
        _ = parsed.value.object.orderedRemove(field);
        const variant = try jsonValueAlloc(std.testing.allocator, parsed.value);
        defer std.testing.allocator.free(variant);
        const store = try std.fmt.allocPrint(std.testing.allocator, "{s}/store-{d}.jsonl", .{ root, index });
        defer std.testing.allocator.free(store);
        const input = try std.fmt.allocPrint(std.testing.allocator, "{s}/input-{d}.json", .{ root, index });
        defer std.testing.allocator.free(input);
        try durable_store.writeTextAtomic(std.testing.allocator, input, variant);
        var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
        defer capture.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("need-evidence", capture.status);
    }
}

test "invalid witness objects fail capture and replay validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(std.testing.allocator, input, "{\"status\":\"capture_candidate\",\"source_refs\":[{}]}");
    try std.testing.expectError(error.InvalidSourceRefs, appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input }));
    try std.testing.expect(!durable_store.fileExists(store));

    try durable_store.writeTextAtomic(
        std.testing.allocator,
        store,
        "{\"v\":1,\"event\":\"capture\",\"neg_id\":\"NEG-000001\",\"status\":\"active\",\"record\":{\"record_version\":\"NER-v2\",\"kind\":\"realization_route\",\"route_id\":\"route-a\",\"artifact_state_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"hypothesis\":\"h\",\"attempted_change\":\"a\",\"observed_outcome\":\"o\",\"failure_class\":\"no-effect\",\"source_refs\":[{}],\"exclusion_scope\":\"route\",\"exclusion_rule\":\"r\",\"applicability_conditions\":[\"a\"],\"reopening_criteria\":[{\"id\":\"c\",\"condition\":\"changed\"}],\"confidence\":\"high\",\"next_search_hint\":\"n\"}}\n",
    );
    var loaded = try loadRecordsValidated(std.testing.allocator, store);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.validation.ok());
}

test "symbolic HEAD is resolved and empty artifact identity cannot activate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var output = try testRunCommand(std.testing.allocator, root, &.{ "git", "init", "--quiet" });
    std.testing.allocator.free(output);
    output = try testRunCommand(std.testing.allocator, root, &.{ "git", "config", "user.email", "ledger-test@example.com" });
    std.testing.allocator.free(output);
    output = try testRunCommand(std.testing.allocator, root, &.{ "git", "config", "user.name", "Ledger Test" });
    std.testing.allocator.free(output);
    const tracked = try std.fs.path.join(std.testing.allocator, &.{ root, "tracked.txt" });
    defer std.testing.allocator.free(tracked);
    try durable_store.writeTextAtomic(std.testing.allocator, tracked, "tracked\n");
    output = try testRunCommand(std.testing.allocator, root, &.{ "git", "add", "tracked.txt" });
    std.testing.allocator.free(output);
    output = try testRunCommand(std.testing.allocator, root, &.{ "git", "commit", "--quiet", "-m", "fixture" });
    std.testing.allocator.free(output);
    const head_output = try testRunCommand(std.testing.allocator, root, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_output);
    const head = std.mem.trim(u8, head_output, " \t\r\n");

    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    const symbolic = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", "HEAD");
    defer std.testing.allocator.free(symbolic);
    try durable_store.writeTextAtomic(std.testing.allocator, input, symbolic);
    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("active", capture.status);
    var loaded = try loadRecordsValidated(std.testing.allocator, store);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(loaded.validation.ok());
    try std.testing.expectEqualStrings(head, loaded.records.items[0].artifact_state_id);
    try std.testing.expectEqualStrings("HEAD", loaded.records.items[0].artifact_state_label);

    const prefixed_store = try std.fs.path.join(std.testing.allocator, &.{ root, "prefixed-artifact.jsonl" });
    defer std.testing.allocator.free(prefixed_store);
    const prefixed_input = try std.fs.path.join(std.testing.allocator, &.{ root, "prefixed-artifact.json" });
    defer std.testing.allocator.free(prefixed_input);
    const symbolic_prefixed = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", "commit:HEAD");
    defer std.testing.allocator.free(symbolic_prefixed);
    try durable_store.writeTextAtomic(std.testing.allocator, prefixed_input, symbolic_prefixed);
    var prefixed_capture = try appendCapture(std.testing.allocator, .{
        .command = .capture,
        .file = prefixed_store,
        .json_path = prefixed_input,
    });
    defer prefixed_capture.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("active", prefixed_capture.status);
    var prefixed_loaded = try loadRecordsValidated(std.testing.allocator, prefixed_store);
    defer prefixed_loaded.deinit(std.testing.allocator);
    const expected_prefixed = try std.fmt.allocPrint(std.testing.allocator, "commit:{s}", .{head});
    defer std.testing.allocator.free(expected_prefixed);
    try std.testing.expectEqualStrings(expected_prefixed, prefixed_loaded.records.items[0].artifact_state_id);
    try std.testing.expectEqualStrings("commit:HEAD", prefixed_loaded.records.items[0].artifact_state_label);

    const empty_store = try std.fs.path.join(std.testing.allocator, &.{ root, "empty-artifact.jsonl" });
    defer std.testing.allocator.free(empty_store);
    const empty_input = try std.fs.path.join(std.testing.allocator, &.{ root, "empty-artifact.json" });
    defer std.testing.allocator.free(empty_input);
    const empty_artifact = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", "");
    defer std.testing.allocator.free(empty_artifact);
    try durable_store.writeTextAtomic(std.testing.allocator, empty_input, empty_artifact);
    var empty_capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = empty_store, .json_path = empty_input });
    defer empty_capture.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("need-evidence", empty_capture.status);

    const malformed_identities = [_][]const u8{ "sha256:x", "surface:x", "commit:", "tree:not-a-ref" };
    for (malformed_identities, 0..) |identity, index| {
        const malformed_store = try std.fmt.allocPrint(std.testing.allocator, "{s}/malformed-{d}.jsonl", .{ root, index });
        defer std.testing.allocator.free(malformed_store);
        const malformed_input = try std.fmt.allocPrint(std.testing.allocator, "{s}/malformed-{d}.json", .{ root, index });
        defer std.testing.allocator.free(malformed_input);
        const malformed = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", identity);
        defer std.testing.allocator.free(malformed);
        try durable_store.writeTextAtomic(std.testing.allocator, malformed_input, malformed);
        var malformed_capture = try appendCapture(std.testing.allocator, .{
            .command = .capture,
            .file = malformed_store,
            .json_path = malformed_input,
        });
        defer malformed_capture.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("need-evidence", malformed_capture.status);
    }
}

test "prefixed artifact identity formats are concrete" {
    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expect(isImmutableArtifactIdentity("commit:" ++ TestArtifact));
    try std.testing.expect(isImmutableArtifactIdentity("tree:" ++ TestArtifact));
    try std.testing.expect(isImmutableArtifactIdentity("sha256:" ++ digest));
    try std.testing.expect(isImmutableArtifactIdentity("surface:" ++ digest));
    try std.testing.expect(!isImmutableArtifactIdentity("commit:HEAD"));
    try std.testing.expect(!isImmutableArtifactIdentity("tree:main"));
    try std.testing.expect(!isImmutableArtifactIdentity("sha256:x"));
    try std.testing.expect(!isImmutableArtifactIdentity("surface:x"));
}

test "all advertised scopes have exact negative and near-match semantics" {
    const scopes = [_]struct { scope: []const u8, key: []const u8 }{
        .{ .scope = "exact", .key = "route_id" },
        .{ .scope = "route", .key = "route_id" },
        .{ .scope = "route_family", .key = "route_family_id" },
        .{ .scope = "cluster", .key = "cluster_id" },
        .{ .scope = "authority_model", .key = "authority_model_id" },
        .{ .scope = "distinction_pattern", .key = "distinction_pattern_id" },
        .{ .scope = "proof_pattern", .key = "proof_pattern_id" },
    };
    for (scopes) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        const store = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
        defer std.testing.allocator.free(store);
        const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
        defer std.testing.allocator.free(input);
        const record = try testActiveCaptureAlloc(std.testing.allocator, case.scope, case.key, "scope-alpha", TestArtifact);
        defer std.testing.allocator.free(record);
        try durable_store.writeTextAtomic(std.testing.allocator, input, record);
        var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
        defer capture.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("active", capture.status);
        var loaded = try loadRecordsValidated(std.testing.allocator, store);
        defer loaded.deinit(std.testing.allocator);
        try std.testing.expect(loaded.validation.ok());

        const positive = evaluateRouteGate(loaded.records.items, testMapArgsForScope(case.scope, "scope-alpha", TestArtifact));
        try std.testing.expectEqual(@as(?usize, 0), positive.active_match_index);
        const negative = evaluateRouteGate(loaded.records.items, testMapArgsForScope(case.scope, "other-scope", TestArtifact));
        try std.testing.expectEqual(@as(?usize, null), negative.active_match_index);
        try std.testing.expectEqual(@as(usize, 0), negative.fuzzy_candidates);
        const near = evaluateRouteGate(loaded.records.items, testMapArgsForScope(case.scope, "scope-alpha-adjacent", TestArtifact));
        try std.testing.expectEqual(@as(?usize, null), near.active_match_index);
        try std.testing.expectEqual(@as(usize, 1), near.fuzzy_candidates);
    }
}

test "invalid stores cannot export or hand off" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(store);
    try durable_store.writeTextAtomic(std.testing.allocator, store, "{bad json}\n");
    try std.testing.expectError(error.StoreInvalid, cmdExport(std.testing.allocator, .{ .command = .@"export", .file = store, .id = "NEG-000001" }));
    try std.testing.expectError(error.StoreInvalid, cmdHandoff(std.testing.allocator, store));
}

test "lifecycle transitions require proof and produce linked stable projections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    const record_json = try testActiveCaptureAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact);
    defer std.testing.allocator.free(record_json);
    try durable_store.writeTextAtomic(std.testing.allocator, input, record_json);
    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);

    const illegal = try std.fs.path.join(std.testing.allocator, &.{ root, "illegal.json" });
    defer std.testing.allocator.free(illegal);
    try durable_store.writeTextAtomic(std.testing.allocator, illegal, "{\"reason\":\"attempted demotion\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}");
    try std.testing.expectError(error.InvalidStatusTransition, appendStatusEvent(std.testing.allocator, .{ .command = .status, .file = store, .id = capture.neg_id, .json_path = illegal }, "need-evidence"));
    try std.testing.expectError(error.MissingReopenProof, appendStatusEvent(std.testing.allocator, .{ .command = .reopen, .file = store, .id = capture.neg_id, .json_path = illegal }, "reopened"));
    const unchanged = try std.fs.path.join(std.testing.allocator, &.{ root, "unchanged.json" });
    defer std.testing.allocator.free(unchanged);
    try durable_store.writeTextAtomic(std.testing.allocator, unchanged, "{\"reason\":\"no actual change\",\"criterion_changes\":[{\"criterion_id\":\"artifact-changed\",\"before\":\"same\",\"after\":\"same\"}],\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}");
    try std.testing.expectError(error.InvalidTransitionCriteria, appendStatusEvent(std.testing.allocator, .{ .command = .reopen, .file = store, .id = capture.neg_id, .json_path = unchanged }, "reopened"));
    const unknown = try std.fs.path.join(std.testing.allocator, &.{ root, "unknown.json" });
    defer std.testing.allocator.free(unknown);
    try durable_store.writeTextAtomic(std.testing.allocator, unknown, "{\"reason\":\"unknown criterion\",\"criterion_changes\":[{\"criterion_id\":\"not-recorded\",\"before\":\"old\",\"after\":\"new\"}],\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}");
    try std.testing.expectError(error.UnknownReopeningCriterion, appendStatusEvent(std.testing.allocator, .{ .command = .reopen, .file = store, .id = capture.neg_id, .json_path = unknown }, "reopened"));

    var before = try loadRecordsValidated(std.testing.allocator, store);
    defer before.deinit(std.testing.allocator);
    try std.testing.expect(before.validation.ok());
    const before_fingerprint = try projectionFingerprintAlloc(std.testing.allocator, before.records.items[0]);
    defer std.testing.allocator.free(before_fingerprint);
    var scope = try testRepositoryScopeAlloc(std.testing.allocator, "tkersey/skills-zig");
    defer scope.deinit(std.testing.allocator);
    var before_note_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer before_note_writer.deinit();
    try writeLedgerMemoryNoteInput(std.testing.allocator, &before_note_writer.writer, scope, before.records.items[0], before_fingerprint);
    const before_note = try before_note_writer.toOwnedSlice();
    defer std.testing.allocator.free(before_note);

    const transition = try std.fs.path.join(std.testing.allocator, &.{ root, "reopen.json" });
    defer std.testing.allocator.free(transition);
    try durable_store.writeTextAtomic(std.testing.allocator, transition, "{\"reason\":\"the artifact changed\",\"criterion_changes\":[{\"criterion_id\":\"artifact-changed\",\"before\":\"old artifact\",\"after\":\"new artifact\"}],\"source_refs\":[{\"kind\":\"test\",\"ref\":\"new artifact proof\"}]}");
    try std.testing.expect(try appendStatusEvent(std.testing.allocator, .{ .command = .reopen, .file = store, .id = capture.neg_id, .json_path = transition }, "reopened"));

    var after = try loadRecordsValidated(std.testing.allocator, store);
    defer after.deinit(std.testing.allocator);
    try std.testing.expect(after.validation.ok());
    const projected = after.records.items[0];
    try std.testing.expectEqualStrings("reopened", projected.status);
    try std.testing.expectEqual(@as(usize, 1), projected.capture_event_count);
    try std.testing.expectEqual(@as(usize, 1), projected.status_event_count);
    try std.testing.expectEqual(@as(usize, 2), projected.source_event_count);
    try std.testing.expectEqualStrings(before_fingerprint, projected.prior_projection_fingerprint);
    const after_fingerprint = try projectionFingerprintAlloc(std.testing.allocator, projected);
    defer std.testing.allocator.free(after_fingerprint);
    try std.testing.expect(!std.mem.eql(u8, before_fingerprint, after_fingerprint));
    const reopened_gate = evaluateRouteGate(after.records.items, testMapArgsForScope("route", "route-a", OtherTestArtifact));
    try std.testing.expectEqual(@as(?usize, null), reopened_gate.active_match_index);
    try std.testing.expectEqual(@as(?usize, 0), reopened_gate.reopen_required_index);

    var first_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first_writer.deinit();
    try writeLedgerMemoryNoteInput(std.testing.allocator, &first_writer.writer, scope, projected, after_fingerprint);
    const first = try first_writer.toOwnedSlice();
    defer std.testing.allocator.free(first);
    var second_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second_writer.deinit();
    try writeLedgerMemoryNoteInput(std.testing.allocator, &second_writer.writer, scope, projected, after_fingerprint);
    const second = try second_writer.toOwnedSlice();
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, before_fingerprint) != null);
    try std.testing.expect(!std.mem.eql(u8, before_note, first));

    var backend = durable_store.PersistentEventStore.init(store);
    var snapshot = try backend.eventStore().snapshot(std.testing.allocator, MaxStoreBytes);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.records.len);
    const transition_event = snapshot.records[1].payload;
    const transition_fields = [_][]const u8{ "\"event_id\"", "\"timestamp\"", "\"from\":\"active\"", "\"to\":\"reopened\"", "\"criterion_ids\"", "\"criterion_changes\"", "\"source_refs\"" };
    for (&transition_fields) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, transition_event, needle) != null);
    }
}

test "repository identity distinguishes equal NEG ids in memory projections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_a = try std.fs.path.join(std.testing.allocator, &.{ root, "events-a.jsonl" });
    defer std.testing.allocator.free(store_a);
    const store_b = try std.fs.path.join(std.testing.allocator, &.{ root, "events-b.jsonl" });
    defer std.testing.allocator.free(store_b);
    const input_a = try std.fs.path.join(std.testing.allocator, &.{ root, "capture-a.json" });
    defer std.testing.allocator.free(input_a);
    const input_b = try std.fs.path.join(std.testing.allocator, &.{ root, "capture-b.json" });
    defer std.testing.allocator.free(input_b);
    const record_a_json = try testActiveCaptureForRepositoryAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact, "owner/repo-a");
    defer std.testing.allocator.free(record_a_json);
    const record_b_json = try testActiveCaptureForRepositoryAlloc(std.testing.allocator, "route", "route_id", "route-a", TestArtifact, "owner/repo-b");
    defer std.testing.allocator.free(record_b_json);
    try durable_store.writeTextAtomic(std.testing.allocator, input_a, record_a_json);
    try durable_store.writeTextAtomic(std.testing.allocator, input_b, record_b_json);
    var capture_a = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store_a, .json_path = input_a });
    defer capture_a.deinit(std.testing.allocator);
    var capture_b = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store_b, .json_path = input_b });
    defer capture_b.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("NEG-000001", capture_a.neg_id);
    try std.testing.expectEqualStrings("NEG-000001", capture_b.neg_id);
    var loaded_a = try loadRecordsValidated(std.testing.allocator, store_a);
    defer loaded_a.deinit(std.testing.allocator);
    var loaded_b = try loadRecordsValidated(std.testing.allocator, store_b);
    defer loaded_b.deinit(std.testing.allocator);
    const record_a = loaded_a.records.items[0];
    const record_b = loaded_b.records.items[0];
    const fingerprint_a = try projectionFingerprintAlloc(std.testing.allocator, record_a);
    defer std.testing.allocator.free(fingerprint_a);
    const fingerprint_b = try projectionFingerprintAlloc(std.testing.allocator, record_b);
    defer std.testing.allocator.free(fingerprint_b);
    try std.testing.expect(!std.mem.eql(u8, fingerprint_a, fingerprint_b));
    var repo_a = try testRepositoryScopeAlloc(std.testing.allocator, "owner/repo-a");
    defer repo_a.deinit(std.testing.allocator);
    var repo_b = try testRepositoryScopeAlloc(std.testing.allocator, "owner/repo-b");
    defer repo_b.deinit(std.testing.allocator);
    var a_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer a_writer.deinit();
    try writeLedgerMemoryNoteInput(std.testing.allocator, &a_writer.writer, repo_a, record_a, fingerprint_a);
    const a = try a_writer.toOwnedSlice();
    defer std.testing.allocator.free(a);
    var b_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer b_writer.deinit();
    try writeLedgerMemoryNoteInput(std.testing.allocator, &b_writer.writer, repo_b, record_b, fingerprint_b);
    const b = try b_writer.toOwnedSlice();
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expect(std.mem.indexOf(u8, a, "owner/repo-a:.ledger/negative-ledger/events.jsonl#NEG-000001") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "owner/repo-b:.ledger/negative-ledger/events.jsonl#NEG-000001") != null);
}

test "actuation source routing preserves the goal-bound artifact command" {
    const argv = [_][]const u8{
        "ledger",
        "prepare",
        "--source",
        "actuation",
        "--goal",
        "goal-1",
        "--input",
        "operation.json",
    };
    const routed = try sourceArgvAlloc(std.testing.allocator, &argv, "actuation");
    defer std.testing.allocator.free(routed);
    try std.testing.expectEqual(@as(usize, 6), routed.len);
    try std.testing.expectEqualStrings("ledger", routed[0]);
    try std.testing.expectEqualStrings("prepare", routed[1]);
    try std.testing.expectEqualStrings("--goal", routed[2]);
    try std.testing.expectEqualStrings("goal-1", routed[3]);
    try std.testing.expectEqualStrings("--input", routed[4]);
    try std.testing.expectEqualStrings("operation.json", routed[5]);
}

test "actuation: adapter conformance declarations" {
    std.testing.refAllDecls(actuation_cli);
}

test "universalist source routing preserves plan creation arguments" {
    const argv = [_][]const u8{
        "ledger",
        "create",
        "--source",
        "universalist",
        "--repo",
        "/tmp/repo",
        "--template",
        "plan.md",
    };
    const routed = try sourceArgvAlloc(std.testing.allocator, &argv, "universalist");
    defer std.testing.allocator.free(routed);
    try std.testing.expectEqual(@as(usize, 6), routed.len);
    try std.testing.expectEqualStrings("ledger", routed[0]);
    try std.testing.expectEqualStrings("create", routed[1]);
    try std.testing.expectEqualStrings("--repo", routed[2]);
    try std.testing.expectEqualStrings("/tmp/repo", routed[3]);
    try std.testing.expectEqualStrings("--template", routed[4]);
    try std.testing.expectEqualStrings("plan.md", routed[5]);
}

test "universalist source routing preserves receipt emission arguments" {
    const argv = [_][]const u8{
        "ledger",
        "emit",
        "--source",
        "universalist",
        "--plan",
        "plan.md",
        "--contract",
        "decision-contract.yaml",
        "--write-plan",
    };
    const routed = try sourceArgvAlloc(std.testing.allocator, &argv, "universalist");
    defer std.testing.allocator.free(routed);
    try std.testing.expectEqual(@as(usize, 7), routed.len);
    try std.testing.expectEqualStrings("ledger", routed[0]);
    try std.testing.expectEqualStrings("emit", routed[1]);
    try std.testing.expectEqualStrings("--plan", routed[2]);
    try std.testing.expectEqualStrings("plan.md", routed[3]);
    try std.testing.expectEqualStrings("--contract", routed[4]);
    try std.testing.expectEqualStrings("decision-contract.yaml", routed[5]);
    try std.testing.expectEqualStrings("--write-plan", routed[6]);
}

test "hylo source routing preserves replay commands" {
    const argv = [_][]const u8{ "ledger", "--source", "hylo", "doctor", "--repo", "." };
    const routed = try sourceArgvAlloc(std.testing.allocator, &argv, "hylo");
    defer std.testing.allocator.free(routed);
    try std.testing.expectEqualSlices([]const u8, &.{ "ledger", "doctor", "--repo", "." }, routed);
    try std.testing.expectEqual(HctpProductAvailable, sourceAvailable("hylo"));
}

test "negative ledger source alias preserves root command arguments" {
    const argv = [_][]const u8{ "ledger", "export", "--source", "negative-ledger", "--file", ".ledger/custom.jsonl", "--id", "NEG-000001", "--format", "memory-note" };
    const routed = try sourceArgvAlloc(std.testing.allocator, &argv, "negative-ledger");
    defer std.testing.allocator.free(routed);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "ledger", "export", "--file", ".ledger/custom.jsonl", "--id", "NEG-000001", "--format", "memory-note" },
        routed,
    );
}

test "learnings show source alias preserves both command orderings" {
    const command_first = [_][]const u8{
        "ledger",
        "show",
        "--source",
        "learnings",
        "--id",
        "lrn-20260715T000000Z-12345678",
    };
    const routed_command_first = try sourceArgvAlloc(
        std.testing.allocator,
        &command_first,
        "learnings",
    );
    defer std.testing.allocator.free(routed_command_first);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "ledger", "show", "--id", "lrn-20260715T000000Z-12345678" },
        routed_command_first,
    );

    const source_first = [_][]const u8{
        "ledger",
        "--source",
        "learnings",
        "show",
        "--id",
        "lrn-20260715T000000Z-12345678",
    };
    const routed_source_first = try sourceArgvAlloc(
        std.testing.allocator,
        &source_first,
        "learnings",
    );
    defer std.testing.allocator.free(routed_source_first);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "ledger", "show", "--id", "lrn-20260715T000000Z-12345678" },
        routed_source_first,
    );
}

test "ledger routine test graph includes owned source and validation modules" {
    std.testing.refAllDecls(actuation_cli);
    std.testing.refAllDecls(universalist_cli);
    std.testing.refAllDecls(validation_cli);
}

test "ledger routine tests fail closed at the Hylo delegate" {
    try std.testing.expectError(
        error.HyloDelegateUnavailableInLedgerTests,
        hylo_cli.runWithArgv(std.testing.allocator, std.testing.io, &.{ "ledger", "hylo" }),
    );
}

test "root help follows Hylo source admission" {
    try std.testing.expectEqual(
        HctpProductAvailable,
        std.mem.indexOf(u8, HelpText, "actuation, hylo, learnings") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, HelpText, "including Actuating evidence") != null);
}
