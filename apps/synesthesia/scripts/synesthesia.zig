const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "ledger --source synesthesia";
const DefaultSynesthesiaPath = ".ledger/synesthesia/events.jsonl";
const MaxStoreBytes = 64 * 1024 * 1024;
const MaxInputBytes = 4 * 1024 * 1024;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = ProgramName,
    .help_text = UsageText,
};
const CaptureHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger capture --source synesthesia",
    .help_text = CaptureUsageText,
};
const DoctorHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger doctor --source synesthesia",
    .help_text = DoctorUsageText,
};
const PathHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger path --source synesthesia",
    .help_text = PathUsageText,
};
const RecentHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger recent --source synesthesia",
    .help_text = RecentUsageText,
};
const RecallHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger recall --source synesthesia",
    .help_text = RecallUsageText,
};
const QueryHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger query --source synesthesia",
    .help_text = QueryUsageText,
};
const ShowHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger show --source synesthesia",
    .help_text = ShowUsageText,
};
const ExportHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger export --source synesthesia",
    .help_text = ExportUsageText,
};
const MemoryDigestHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger memory-digest --source synesthesia",
    .help_text = MemoryDigestUsageText,
};
const MigrateHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger migrate --source synesthesia",
    .help_text = MigrateUsageText,
};

const UsageText =
    \\ledger --source synesthesia
    \\
    \\usage: ledger --source synesthesia [-h] [--path PATH] {capture,doctor,path,recent,recall,query,show,export,memory-digest,migrate} ...
    \\
    \\Capture, recall, and export durable Synesthesia mapping events from repo-local .ledger/synesthesia/events.jsonl.
    \\
    \\positional arguments:
    \\  {capture,doctor,path,recent,recall,query,show,export,memory-digest,migrate}
    \\    capture             Append a durable Synesthesia event from JSON
    \\    doctor              Report Synesthesia store status
    \\    path                Print the resolved default Synesthesia event path
    \\    recent              Show most recent Synesthesia events
    \\    recall              Rank relevant Synesthesia events for a task
    \\    query               Search Synesthesia events
    \\    show                Show one Synesthesia event
    \\    export              Emit a full or memory-note projection
    \\    memory-digest       Generate a disposable Synesthesia digest
    \\    migrate             Copy existing Synesthesia source notes into the ledger store
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --path PATH           Path to Synesthesia JSONL file (relative to repo root by default)
    \\  -V, --version         Show version
    \\  version               Show version
;

const CaptureUsageText =
    \\ledger capture --source synesthesia
    \\
    \\usage: ledger capture --source synesthesia [-h] --kind KIND --json FILE|- [--path PATH] [--allow-duplicate]
    \\
    \\Append a durable Synesthesia event to repo-local .ledger/synesthesia/events.jsonl.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --kind KIND           mapping-endorsement, mapping-confirmation, mapping-correction, mapping-rejection, activation-boundary, or boundary-retraction
    \\  --json FILE|-         Synesthesia envelope JSON
    \\  --path PATH           Override store path
    \\  --allow-duplicate     Append even when the event fingerprint already exists
;

const DoctorUsageText =
    \\ledger doctor --source synesthesia
    \\
    \\usage: ledger doctor --source synesthesia [-h] [--path PATH]
    \\
    \\Report Synesthesia store path status.
;

const PathUsageText =
    \\ledger path --source synesthesia
    \\
    \\usage: ledger path --source synesthesia [-h] [--path PATH]
    \\
    \\Print the resolved Synesthesia event path.
;

const RecentUsageText =
    \\ledger recent --source synesthesia
    \\
    \\usage: ledger recent --source synesthesia [-h] [--limit LIMIT] [--path PATH]
    \\
    \\Show the most recent Synesthesia events.
;

const RecallUsageText =
    \\ledger recall --source synesthesia
    \\
    \\usage: ledger recall --source synesthesia [-h] --query QUERY [--limit LIMIT] [--path PATH]
    \\
    \\Rank relevant Synesthesia events for a task.
;

const QueryUsageText =
    \\ledger query --source synesthesia
    \\
    \\usage: ledger query --source synesthesia [-h] --query QUERY [--limit LIMIT] [--path PATH]
    \\
    \\Search Synesthesia events.
;

const ShowUsageText =
    \\ledger show --source synesthesia
    \\
    \\usage: ledger show --source synesthesia [-h] --id SYN-ID [--path PATH]
    \\
    \\Show one Synesthesia event.
;

const ExportUsageText =
    \\ledger export --source synesthesia
    \\
    \\usage: ledger export --source synesthesia [-h] --id SYN-ID [--format full|memory-note] [--path PATH]
    \\
    \\Emit a full ledger row or memory-note adapter envelope projection.
;

const MemoryDigestUsageText =
    \\ledger memory-digest --source synesthesia
    \\
    \\usage: ledger memory-digest --source synesthesia [-h] [--output PATH] [--path PATH]
    \\
    \\Generate a disposable Synesthesia digest.
;

const MigrateUsageText =
    \\ledger migrate --source synesthesia
    \\
    \\usage: ledger migrate --source synesthesia [-h] [--from PATH] [--to PATH] [--mode copy] [--dry-run] [--allow-existing-target]
    \\
    \\Copy existing Synesthesia memory-source notes into .ledger/synesthesia/events.jsonl.
;

const Command = enum {
    capture,
    append,
    doctor,
    path,
    recent,
    recall,
    query,
    show,
    @"export",
    memory_digest,
    migrate,
};

const MigrationMode = enum { copy };

const Args = struct {
    command: ?Command = null,
    path: []const u8 = DefaultSynesthesiaPath,
    path_explicit: bool = false,
    json_path: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    id: ?[]const u8 = null,
    query: []const u8 = "",
    limit: usize = 20,
    format: []const u8 = "full",
    output: []const u8 = "",
    migrate_from: []const u8 = "",
    migrate_to: []const u8 = DefaultSynesthesiaPath,
    dry_run: bool = false,
    allow_existing_target: bool = false,
    allow_duplicate: bool = false,
    mode: MigrationMode = .copy,
};

const StoredRecord = struct {
    id: []u8,
    captured_at: []u8,
    logical_kind: []u8,
    kind: []u8,
    operation: []u8,
    authority: []u8,
    summary: []u8,
    fingerprint: []u8,
    record_json: []u8,
    line_json: []u8,
    search_text: []u8,

    fn deinit(self: *StoredRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.captured_at);
        allocator.free(self.logical_kind);
        allocator.free(self.kind);
        allocator.free(self.operation);
        allocator.free(self.authority);
        allocator.free(self.summary);
        allocator.free(self.fingerprint);
        allocator.free(self.record_json);
        allocator.free(self.line_json);
        allocator.free(self.search_text);
    }
};

const Match = struct {
    idx: usize,
    score: usize,
};

const CaptureResult = struct {
    id: []u8,
    kind: []u8,
    operation: []u8,
    path: []u8,

    fn deinit(self: *CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
        allocator.free(self.operation);
        allocator.free(self.path);
    }
};

const NormalizedInput = struct {
    logical_kind: []const u8,
    physical_kind: []const u8,
    operation: []const u8,
    authority: []const u8,
    summary: []const u8,
    scope: std.json.Value,
    source_refs: std.json.Value,
    related_ids: std.json.Value,
    supersedes_id: ?[]const u8,
    payload: std.json.Value,
    slug: ?[]const u8,
    fingerprint: []u8,

    fn deinit(self: *NormalizedInput, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    try runWithArgv(allocator, argv, init.environ_map.get("CODEX_HOME") orelse "");
}

pub fn runWithArgv(allocator: std.mem.Allocator, argv: []const []const u8, codex_home: []const u8) !void {
    if (argv.len <= 1 or core_cli.isHelpArg(argv[1])) {
        try printHelp(HelpSurface);
        return;
    }
    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        try core_cli.printVersion(&stdout_writer.interface, Version);
        return;
    }
    if (subcommandHelpSurface(argv)) |surface| {
        try printHelp(surface);
        return;
    }

    const parsed = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    const repo_root = try discoverRepoRootAlloc(allocator, cwd);
    defer allocator.free(repo_root);

    switch (parsed.command orelse return error.MissingCommand) {
        .capture, .append => {
            if (try cmdCapture(allocator, repo_root, parsed)) |result_value| {
                var result = result_value;
                defer result.deinit(allocator);
                var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                try stdout_writer.interface.print(
                    "appended: id={s} kind={s} operation={s} path={s}\n",
                    .{ result.id, result.kind, result.operation, result.path },
                );
            }
        },
        .doctor => try cmdDoctor(allocator, repo_root, parsed, codex_home),
        .path => try cmdPath(allocator, repo_root, parsed),
        .recent => try cmdRecent(allocator, repo_root, parsed),
        .recall => try cmdRecall(allocator, repo_root, parsed),
        .query => try cmdQuery(allocator, repo_root, parsed),
        .show => try cmdShow(allocator, repo_root, parsed),
        .@"export" => try cmdExport(allocator, repo_root, parsed),
        .memory_digest => try cmdMemoryDigest(allocator, repo_root, parsed, codex_home),
        .migrate => try cmdMigrate(allocator, repo_root, parsed, codex_home),
    }
}

fn printHelp(surface: core_cli.HelpSurface) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, surface, Version);
}

fn subcommandHelpSurface(argv: []const []const u8) ?core_cli.HelpSurface {
    var command: ?Command = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (std.mem.eql(u8, token, "--path") or std.mem.eql(u8, token, "--json") or
            std.mem.eql(u8, token, "--kind") or std.mem.eql(u8, token, "--id") or
            std.mem.eql(u8, token, "--query") or std.mem.eql(u8, token, "--limit") or
            std.mem.eql(u8, token, "--format") or std.mem.eql(u8, token, "--output") or
            std.mem.eql(u8, token, "--from") or std.mem.eql(u8, token, "--to") or
            std.mem.eql(u8, token, "--mode"))
        {
            i += 1;
            continue;
        }
        if (core_cli.isHelpArg(token)) {
            return if (command) |cmd| helpForCommand(cmd) else HelpSurface;
        }
        if (command == null and !std.mem.startsWith(u8, token, "-")) {
            command = parseCommand(token) orelse null;
        }
    }
    return null;
}

fn helpForCommand(command: Command) core_cli.HelpSurface {
    return switch (command) {
        .capture, .append => CaptureHelpSurface,
        .doctor => DoctorHelpSurface,
        .path => PathHelpSurface,
        .recent => RecentHelpSurface,
        .recall => RecallHelpSurface,
        .query => QueryHelpSurface,
        .show => ShowHelpSurface,
        .@"export" => ExportHelpSurface,
        .memory_digest => MemoryDigestHelpSurface,
        .migrate => MigrateHelpSurface,
    };
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (std.mem.eql(u8, token, "--path") or std.mem.eql(u8, token, "--file")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.path = argv[i];
            args.migrate_to = argv[i];
            args.path_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--json")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.json_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--kind")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.kind = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--query")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.query = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--limit")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.limit = try std.fmt.parseInt(usize, argv[i], 10);
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.format = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--output")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.output = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--from")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.migrate_from = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--to")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.migrate_to = argv[i];
            args.path = argv[i];
            args.path_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--mode")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (!std.mem.eql(u8, argv[i], "copy")) return error.InvalidMigrationMode;
            args.mode = .copy;
            continue;
        }
        if (std.mem.eql(u8, token, "--dry-run")) {
            args.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--allow-existing-target")) {
            args.allow_existing_target = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--allow-duplicate")) {
            args.allow_duplicate = true;
            continue;
        }
        if (args.command == null and !std.mem.startsWith(u8, token, "-")) {
            args.command = parseCommand(token) orelse return error.UnknownCommand;
            continue;
        }
        return error.UnknownOption;
    }
    const command = args.command orelse return error.MissingCommand;
    if ((command == .capture or command == .append) and args.json_path == null) return error.MissingJsonInput;
    if ((command == .show or command == .@"export") and args.id == null) return error.MissingId;
    if ((command == .recall or command == .query) and args.query.len == 0) return error.MissingQuery;
    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "memory-digest")) return .memory_digest;
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn cmdCapture(allocator: std.mem.Allocator, repo_root: []const u8, args: Args) !?CaptureResult {
    const input = try readInputAlloc(allocator, args.json_path.?);
    defer allocator.free(input);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidCaptureJson,
    };
    const logical_kind = args.kind orelse jsonObjectString(obj, "kind");
    if (logical_kind.len == 0) return error.MissingKind;

    var normalized = try validateAndFingerprint(allocator, logical_kind, obj);
    defer normalized.deinit(allocator);
    const timestamp = try nowUtcAlloc(allocator);
    defer allocator.free(timestamp);
    const syn_id = try buildSynIdAlloc(allocator, timestamp, normalized.fingerprint);
    defer allocator.free(syn_id);
    const record_json = try encodeRecordJsonAlloc(allocator, syn_id, timestamp, normalized);
    defer allocator.free(record_json);
    const line = try encodeEventLineAlloc(allocator, syn_id, timestamp, normalized, record_json);
    defer allocator.free(line);
    const output_path = try resolveJsonlPathAlloc(allocator, repo_root, args.path);
    defer allocator.free(output_path);

    if (!args.allow_duplicate) {
        if (try findDuplicateByFingerprintAlloc(allocator, output_path, normalized.fingerprint)) |existing_id| {
            defer allocator.free(existing_id);
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try stderr_writer.interface.print(
                "duplicate-skip: fingerprint={s} existing_id={s} path={s}\n",
                .{ normalized.fingerprint, existing_id, output_path },
            );
            return null;
        }
    }

    var lock = try durable_store.acquireLock(allocator, output_path);
    defer lock.release(allocator);
    try durable_store.appendLineAtomic(allocator, output_path, line, MaxStoreBytes);

    return .{
        .id = try allocator.dupe(u8, syn_id),
        .kind = try allocator.dupe(u8, normalized.physical_kind),
        .operation = try allocator.dupe(u8, normalized.operation),
        .path = try allocator.dupe(u8, output_path),
    };
}

fn cmdDoctor(allocator: std.mem.Allocator, repo_root: []const u8, args: Args, codex_home: []const u8) !void {
    const path = try resolveJsonlPathAlloc(allocator, repo_root, args.path);
    defer allocator.free(path);
    const exists = durable_store.fileExists(path);
    var status: []const u8 = "missing";
    var lines: usize = 0;
    var first_issue: []const u8 = "";
    if (exists) {
        const bytes = durable_store.readRegularFileNoSymlink(allocator, path, MaxStoreBytes) catch |err| {
            first_issue = @errorName(err);
            status = "invalid";
            try printDoctorJson(allocator, status, path, 0, first_issue);
            return;
        };
        defer allocator.free(bytes);
        const validation = validateJsonlBytes(allocator, bytes);
        if (validation) |count| {
            lines = count;
            status = "current";
        } else |err| {
            first_issue = @errorName(err);
            status = "invalid";
        }
    } else if (try synesthesiaNotesExist(allocator, codex_home)) {
        status = "notes-only";
    }
    try printDoctorJson(allocator, status, path, lines, first_issue);
}

fn printDoctorJson(allocator: std.mem.Allocator, status: []const u8, path: []const u8, lines: usize, first_issue: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"source\":\"synesthesia\",\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"path\":");
    try writeJsonString(&out.writer, path);
    try out.writer.print(",\"lines\":{d},\"first_issue\":", .{lines});
    try writeJsonString(&out.writer, first_issue);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn cmdPath(allocator: std.mem.Allocator, repo_root: []const u8, args: Args) !void {
    const path = try resolveJsonlPathAlloc(allocator, repo_root, args.path);
    defer allocator.free(path);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.print("{s}\n", .{path});
}

fn cmdRecent(allocator: std.mem.Allocator, repo_root: []const u8, args: Args) !void {
    const path = try resolveJsonlPathAlloc(allocator, repo_root, args.path);
    defer allocator.free(path);
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    const limit = if (args.limit == 0) 20 else args.limit;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (records.items.len == 0) return;
    var remaining = @min(limit, records.items.len);
    var idx = records.items.len;
    while (remaining > 0) : (remaining -= 1) {
        idx -= 1;
        const record = records.items[idx];
        try stdout.print("{s} {s} {s}/{s} {s}\n", .{ record.id, record.captured_at, record.kind, record.operation, record.summary });
    }
}

fn cmdRecall(allocator: std.mem.Allocator, repo_root: []const u8, args: Args) !void {
    try searchRecords(allocator, repo_root, args, true);
}

fn cmdQuery(allocator: std.mem.Allocator, repo_root: []const u8, args: Args) !void {
    try searchRecords(allocator, repo_root, args, false);
}

fn searchRecords(allocator: std.mem.Allocator, repo_root: []const u8, args: Args, ranked: bool) !void {
    const path = try resolveJsonlPathAlloc(allocator, repo_root, args.path);
    defer allocator.free(path);
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    const query_lower = try asciiLowerAlloc(allocator, args.query);
    defer allocator.free(query_lower);
    const limit = if (args.limit == 0) 8 else args.limit;

    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(allocator);
    for (records.items, 0..) |record, idx| {
        const hay = try asciiLowerAlloc(allocator, record.search_text);
        defer allocator.free(hay);
        const score = lexicalScore(query_lower, hay);
        if (score == 0 and ranked) continue;
        if (!ranked and std.mem.indexOf(u8, hay, query_lower) == null) continue;
        try matches.append(allocator, .{ .idx = idx, .score = score });
    }
    std.mem.sort(@TypeOf(matches.items[0]), matches.items, records.items, lessMatch);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    const take = @min(limit, matches.items.len);
    for (matches.items[0..take]) |match| {
        const record = records.items[match.idx];
        if (ranked) {
            try stdout.print("score={d} {s} {s}/{s} {s}\n", .{ match.score, record.id, record.kind, record.operation, record.summary });
        } else {
            try stdout.print("{s} {s}/{s} {s}\n", .{ record.id, record.kind, record.operation, record.summary });
        }
    }
}

fn lessMatch(records: []StoredRecord, a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, records[a.idx].captured_at, records[b.idx].captured_at) == .gt;
}

fn cmdShow(allocator: std.mem.Allocator, repo_root: []const u8, args: Args) !void {
    const path = try resolveJsonlPathAlloc(allocator, repo_root, args.path);
    defer allocator.free(path);
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (records.items) |record| {
        if (std.mem.eql(u8, record.id, args.id.?)) {
            try out.writer.writeAll(record.line_json);
            try out.writer.writeByte('\n');
            try writeStdoutAlloc(allocator, &out);
            return;
        }
    }
    try out.writer.writeAll("{\"command\":\"show\",\"source\":\"synesthesia\",\"id\":");
    try writeJsonString(&out.writer, args.id.?);
    try out.writer.writeAll(",\"found\":false}\n");
    try writeStdoutAlloc(allocator, &out);
    std.process.exit(1);
}

fn cmdExport(allocator: std.mem.Allocator, repo_root: []const u8, args: Args) !void {
    const path = try resolveJsonlPathAlloc(allocator, repo_root, args.path);
    defer allocator.free(path);
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    for (records.items) |record| {
        if (!std.mem.eql(u8, record.id, args.id.?)) continue;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        if (std.mem.eql(u8, args.format, "memory-note")) {
            try writeMemoryNoteProjection(allocator, &out.writer, record);
        } else {
            try out.writer.writeAll(record.line_json);
        }
        try out.writer.writeByte('\n');
        try writeStdoutAlloc(allocator, &out);
        return;
    }
    return error.UnknownSynesthesiaId;
}

fn writeMemoryNoteProjection(allocator: std.mem.Allocator, writer: anytype, record: StoredRecord) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record.record_json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidRecord,
    };
    try writer.writeByte('{');
    var first = true;
    try copyField(writer, &first, obj, "operation");
    try copyField(writer, &first, obj, "authority");
    try copyField(writer, &first, obj, "summary");
    try copyField(writer, &first, obj, "scope");
    try copyField(writer, &first, obj, "source_refs");
    try copyField(writer, &first, obj, "related_ids");
    try copyField(writer, &first, obj, "supersedes_id");
    try copyField(writer, &first, obj, "payload");
    try writer.writeByte('}');
}

fn cmdMemoryDigest(allocator: std.mem.Allocator, repo_root: []const u8, args: Args, codex_home: []const u8) !void {
    const path = try resolveJsonlPathAlloc(allocator, repo_root, args.path);
    defer allocator.free(path);
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    const output = if (args.output.len > 0)
        try resolveOutputPathAlloc(allocator, repo_root, args.output)
    else
        try defaultDigestOutputPathAlloc(allocator, codex_home);
    defer allocator.free(output);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("# Synesthesia Ledger Digest\n\n");
    try out.writer.print("source: `{s}`\n\n", .{DefaultSynesthesiaPath});
    try out.writer.writeAll("## Events\n\n");
    for (records.items) |record| {
        try out.writer.print("- `{s}` `{s}` `{s}` `{s}`\n", .{ record.id, record.kind, record.operation, record.summary });
    }
    const digest = try out.toOwnedSlice();
    defer allocator.free(digest);
    try durable_store.writeTextAtomic(allocator, output, digest);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.print("memory-digest: path={s} events={d}\n", .{ output, records.items.len });
}

fn cmdMigrate(allocator: std.mem.Allocator, repo_root: []const u8, args: Args, codex_home: []const u8) !void {
    const notes_dir = if (args.migrate_from.len > 0)
        try resolveOutputPathAlloc(allocator, repo_root, args.migrate_from)
    else
        try defaultNotesDirAlloc(allocator, codex_home);
    defer allocator.free(notes_dir);
    const output_path = try resolveJsonlPathAlloc(allocator, repo_root, args.migrate_to);
    defer allocator.free(output_path);

    var rows: std.ArrayList([]u8) = .empty;
    defer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
    try collectNoteRows(allocator, notes_dir, &rows);
    if (args.dry_run) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        try stdout_writer.interface.print("migrate: dry-run source={s} target={s} rows={d}\n", .{ notes_dir, output_path, rows.items.len });
        return;
    }
    if (durable_store.fileExists(output_path) and !args.allow_existing_target) return error.TargetExists;
    var combined: std.Io.Writer.Allocating = .init(allocator);
    defer combined.deinit();
    if (durable_store.fileExists(output_path)) {
        const existing = try durable_store.readRegularFileNoSymlink(allocator, output_path, MaxStoreBytes);
        defer allocator.free(existing);
        try combined.writer.writeAll(existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') try combined.writer.writeByte('\n');
    }
    for (rows.items) |row| {
        try combined.writer.writeAll(row);
        try combined.writer.writeByte('\n');
    }
    const migrated = try combined.toOwnedSlice();
    defer allocator.free(migrated);
    try durable_store.writeTextAtomic(allocator, output_path, migrated);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.print("migrate: copied rows={d} target={s}\n", .{ rows.items.len, output_path });
}

fn validateAndFingerprint(allocator: std.mem.Allocator, logical_kind: []const u8, obj: std.json.ObjectMap) !NormalizedInput {
    const physical_kind = physicalKind(logical_kind) orelse return error.UnsupportedKind;
    try validateAllowedTop(obj);
    const operation = try nonemptyString(obj, "operation");
    if (!operationAllowed(logical_kind, operation)) return error.InvalidOperation;
    const authority = try nonemptyString(obj, "authority");
    if (!authorityAllowed(logical_kind, authority)) return error.InvalidAuthority;
    const summary = try nonemptyString(obj, "summary");
    const scope = obj.get("scope") orelse return error.MissingScope;
    try validateScope(scope);
    const source_refs = obj.get("source_refs") orelse return error.MissingSourceRefs;
    try validateSourceRefs(source_refs);
    const related_ids = obj.get("related_ids") orelse return error.MissingRelatedIds;
    try validateStringArray(related_ids, true);
    const supersedes_id = optionalString(obj, "supersedes_id");
    if (requiresPrior(operation) and !hasPriorRelationship(related_ids, supersedes_id)) return error.MissingPriorRelationship;
    if (std.mem.eql(u8, operation, "confirm") and !hasRelatedId(related_ids)) return error.MissingPriorRelationship;
    const payload = obj.get("payload") orelse return error.MissingPayload;
    try validatePayload(logical_kind, payload);
    try rejectSensitiveKeys(obj);
    const slug = optionalString(obj, "slug");
    if (slug) |value| try validateSlug(value);
    const fp = try fingerprintAlloc(allocator, physical_kind, logical_kind, obj);
    return .{
        .logical_kind = logical_kind,
        .physical_kind = physical_kind,
        .operation = operation,
        .authority = authority,
        .summary = summary,
        .scope = scope,
        .source_refs = source_refs,
        .related_ids = related_ids,
        .supersedes_id = supersedes_id,
        .payload = payload,
        .slug = slug,
        .fingerprint = fp,
    };
}

fn validateAllowedTop(obj: std.json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "kind") or std.mem.eql(u8, key, "operation") or
            std.mem.eql(u8, key, "authority") or std.mem.eql(u8, key, "summary") or
            std.mem.eql(u8, key, "scope") or std.mem.eql(u8, key, "source_refs") or
            std.mem.eql(u8, key, "related_ids") or std.mem.eql(u8, key, "supersedes_id") or
            std.mem.eql(u8, key, "slug") or std.mem.eql(u8, key, "payload")) continue;
        return error.UnexpectedField;
    }
}

fn physicalKind(logical_kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, logical_kind, "mapping-confirmation")) return "mapping-endorsement";
    if (std.mem.eql(u8, logical_kind, "mapping-endorsement") or
        std.mem.eql(u8, logical_kind, "mapping-correction") or
        std.mem.eql(u8, logical_kind, "mapping-rejection") or
        std.mem.eql(u8, logical_kind, "activation-boundary") or
        std.mem.eql(u8, logical_kind, "boundary-retraction")) return logical_kind;
    return null;
}

fn operationAllowed(logical_kind: []const u8, operation: []const u8) bool {
    if (std.mem.eql(u8, logical_kind, "mapping-endorsement")) return anyEqual(operation, &.{ "assert", "confirm", "reopen" });
    if (std.mem.eql(u8, logical_kind, "mapping-confirmation")) return std.mem.eql(u8, operation, "confirm");
    if (std.mem.eql(u8, logical_kind, "mapping-correction")) return std.mem.eql(u8, operation, "supersede");
    if (std.mem.eql(u8, logical_kind, "mapping-rejection")) return std.mem.eql(u8, operation, "reject");
    if (std.mem.eql(u8, logical_kind, "activation-boundary")) return anyEqual(operation, &.{ "assert", "confirm", "supersede", "reopen" });
    if (std.mem.eql(u8, logical_kind, "boundary-retraction")) return std.mem.eql(u8, operation, "retract");
    return false;
}

fn authorityAllowed(logical_kind: []const u8, authority: []const u8) bool {
    if (std.mem.eql(u8, logical_kind, "mapping-endorsement") or std.mem.eql(u8, logical_kind, "mapping-confirmation")) {
        return anyEqual(authority, &.{ "explicit-user-endorsement", "repeated-accepted-use" });
    }
    if (std.mem.eql(u8, logical_kind, "mapping-correction")) return std.mem.eql(u8, authority, "explicit-user-correction");
    if (std.mem.eql(u8, logical_kind, "mapping-rejection")) return std.mem.eql(u8, authority, "explicit-user-rejection");
    if (std.mem.eql(u8, logical_kind, "activation-boundary")) {
        return anyEqual(authority, &.{ "explicit-user-endorsement", "explicit-user-correction", "repeated-accepted-use" });
    }
    if (std.mem.eql(u8, logical_kind, "boundary-retraction")) {
        return anyEqual(authority, &.{ "explicit-user-correction", "explicit-user-rejection" });
    }
    return false;
}

fn anyEqual(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

fn validateScope(value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |v| v,
        else => return error.InvalidScope,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "kind") or std.mem.eql(u8, key, "repo") or std.mem.eql(u8, key, "paths")) continue;
        return error.InvalidScope;
    }
    const kind = try nonemptyString(obj, "kind");
    if (!anyEqual(kind, &.{ "global", "repo", "path-family", "task-family", "workflow", "tool" })) return error.InvalidScope;
    const repo = optionalString(obj, "repo");
    if ((std.mem.eql(u8, kind, "repo") or std.mem.eql(u8, kind, "path-family")) and (repo == null or repo.?.len == 0)) {
        return error.InvalidScope;
    }
    const paths_value = obj.get("paths") orelse return error.InvalidScope;
    try validateStringArray(paths_value, false);
    if (std.mem.eql(u8, kind, "path-family")) {
        const array = switch (paths_value) {
            .array => |v| v,
            else => return error.InvalidScope,
        };
        if (array.items.len == 0) return error.InvalidScope;
    }
}

fn validateSourceRefs(value: std.json.Value) !void {
    const array = switch (value) {
        .array => |v| v,
        else => return error.InvalidSourceRefs,
    };
    if (array.items.len == 0) return error.InvalidSourceRefs;
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |v| v,
            else => return error.InvalidSourceRefs,
        };
        _ = try nonemptyString(obj, "kind");
        _ = try nonemptyString(obj, "ref");
        _ = try nonemptyString(obj, "summary");
        var it = obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "kind") or std.mem.eql(u8, key, "ref") or std.mem.eql(u8, key, "summary")) continue;
            return error.InvalidSourceRefs;
        }
    }
}

fn validateStringArray(value: std.json.Value, allow_absent_empty: bool) !void {
    _ = allow_absent_empty;
    const array = switch (value) {
        .array => |v| v,
        else => return error.InvalidArray,
    };
    for (array.items) |item| {
        const text = switch (item) {
            .string => |v| v,
            else => return error.InvalidArray,
        };
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidArray;
    }
}

fn validatePayload(logical_kind: []const u8, value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |v| v,
        else => return error.InvalidPayload,
    };
    if (obj.count() == 0) return error.InvalidPayload;
    if (std.mem.eql(u8, logical_kind, "mapping-endorsement") or
        std.mem.eql(u8, logical_kind, "mapping-confirmation") or
        std.mem.eql(u8, logical_kind, "mapping-correction"))
    {
        try requirePayloadStrings(obj, &.{ "sensory_phrase", "engineering_translation", "activation_boundary", "non_activation_boundary", "verification" });
    } else if (std.mem.eql(u8, logical_kind, "mapping-rejection")) {
        try requirePayloadStrings(obj, &.{ "sensory_phrase", "activation_boundary", "non_activation_boundary", "rejection_reason", "verification" });
    } else if (std.mem.eql(u8, logical_kind, "activation-boundary")) {
        try requirePayloadStrings(obj, &.{ "activation_boundary", "non_activation_boundary", "verification" });
    } else if (std.mem.eql(u8, logical_kind, "boundary-retraction")) {
        try requirePayloadStrings(obj, &.{ "retracted_boundary", "reason", "verification" });
    }
}

fn requirePayloadStrings(obj: std.json.ObjectMap, fields: []const []const u8) !void {
    for (fields) |field| _ = try nonemptyString(obj, field);
}

fn rejectSensitiveKeys(obj: std.json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        try rejectSensitiveValue(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn rejectSensitiveValue(key: []const u8, value: std.json.Value) !void {
    if (isSensitiveKey(key)) return error.SensitiveKey;
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| try rejectSensitiveValue(entry.key_ptr.*, entry.value_ptr.*);
        },
        .array => |array| for (array.items) |item| try rejectSensitiveValue(key, item),
        else => {},
    }
}

fn isSensitiveKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "password") or
        std.ascii.eqlIgnoreCase(key, "passwd") or
        std.ascii.eqlIgnoreCase(key, "secret") or
        std.ascii.eqlIgnoreCase(key, "api_key") or
        std.ascii.eqlIgnoreCase(key, "apikey") or
        std.ascii.eqlIgnoreCase(key, "access_token") or
        std.ascii.eqlIgnoreCase(key, "refresh_token") or
        std.ascii.eqlIgnoreCase(key, "private_key") or
        std.ascii.eqlIgnoreCase(key, "client_secret");
}

fn requiresPrior(operation: []const u8) bool {
    return anyEqual(operation, &.{ "confirm", "supersede", "reject", "retract", "reopen" });
}

fn hasPriorRelationship(related_ids: std.json.Value, supersedes_id: ?[]const u8) bool {
    return hasRelatedId(related_ids) or (supersedes_id != null and supersedes_id.?.len > 0);
}

fn hasRelatedId(related_ids: std.json.Value) bool {
    const array = switch (related_ids) {
        .array => |v| v,
        else => return false,
    };
    return array.items.len > 0;
}

fn nonemptyString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.MissingString;
    const text = switch (value) {
        .string => |v| v,
        else => return error.MissingString,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.MissingString;
    return trimmed;
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |v| std.mem.trim(u8, v, " \t\r\n"),
        .null => null,
        else => null,
    };
}

fn validateSlug(value: []const u8) !void {
    if (value.len == 0 or value.len > 80) return error.InvalidSlug;
    if (!std.ascii.isLower(value[0]) and !std.ascii.isDigit(value[0])) return error.InvalidSlug;
    for (value) |c| {
        if (std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-') continue;
        return error.InvalidSlug;
    }
}

fn encodeRecordJsonAlloc(allocator: std.mem.Allocator, id: []const u8, captured_at: []const u8, input: NormalizedInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('{');
    var first = true;
    try writeStringField(&out.writer, &first, "id", id);
    try writeStringField(&out.writer, &first, "captured_at", captured_at);
    try writeStringField(&out.writer, &first, "logical_kind", input.logical_kind);
    try writeStringField(&out.writer, &first, "kind", input.physical_kind);
    try writeStringField(&out.writer, &first, "operation", input.operation);
    try writeStringField(&out.writer, &first, "authority", input.authority);
    try writeStringField(&out.writer, &first, "summary", input.summary);
    try writeValueField(&out.writer, &first, "scope", input.scope);
    try writeValueField(&out.writer, &first, "source_refs", input.source_refs);
    try writeValueField(&out.writer, &first, "related_ids", input.related_ids);
    try writeOptionalStringField(&out.writer, &first, "supersedes_id", input.supersedes_id);
    try writeStringField(&out.writer, &first, "fingerprint", input.fingerprint);
    try writeValueField(&out.writer, &first, "payload", input.payload);
    if (input.slug) |slug| try writeStringField(&out.writer, &first, "slug", slug);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn encodeEventLineAlloc(allocator: std.mem.Allocator, id: []const u8, captured_at: []const u8, input: NormalizedInput, record_json: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"v\":1,\"source\":\"synesthesia\",\"event\":\"synesthesia.capture\",\"syn_id\":");
    try writeJsonString(&out.writer, id);
    try out.writer.writeAll(",\"captured_at\":");
    try writeJsonString(&out.writer, captured_at);
    try out.writer.writeAll(",\"kind\":");
    try writeJsonString(&out.writer, input.physical_kind);
    try out.writer.writeAll(",\"logical_kind\":");
    try writeJsonString(&out.writer, input.logical_kind);
    try out.writer.writeAll(",\"operation\":");
    try writeJsonString(&out.writer, input.operation);
    try out.writer.writeAll(",\"record\":");
    try out.writer.writeAll(record_json);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn loadRecords(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(StoredRecord) {
    var records: std.ArrayList(StoredRecord) = .empty;
    if (!durable_store.fileExists(path)) return records;
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxStoreBytes);
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        const record = try parseStoredRecordAlloc(allocator, line);
        try records.append(allocator, record);
    }
    return records;
}

fn parseStoredRecordAlloc(allocator: std.mem.Allocator, line: []const u8) !StoredRecord {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidJsonLine,
    };
    const record_obj = if (obj.get("record")) |record_value| switch (record_value) {
        .object => |value| value,
        else => return error.InvalidRecord,
    } else obj;
    const record_json = try jsonValueAlloc(allocator, .{ .object = record_obj });
    errdefer allocator.free(record_json);
    const line_json = try allocator.dupe(u8, line);
    errdefer allocator.free(line_json);
    const id = try allocator.dupe(u8, jsonObjectString(record_obj, "id"));
    errdefer allocator.free(id);
    const captured_at = try allocator.dupe(u8, jsonObjectString(record_obj, "captured_at"));
    errdefer allocator.free(captured_at);
    const logical_kind = try allocator.dupe(u8, jsonObjectString(record_obj, "logical_kind"));
    errdefer allocator.free(logical_kind);
    const kind = try allocator.dupe(u8, jsonObjectString(record_obj, "kind"));
    errdefer allocator.free(kind);
    const operation = try allocator.dupe(u8, jsonObjectString(record_obj, "operation"));
    errdefer allocator.free(operation);
    const authority = try allocator.dupe(u8, jsonObjectString(record_obj, "authority"));
    errdefer allocator.free(authority);
    const summary = try allocator.dupe(u8, jsonObjectString(record_obj, "summary"));
    errdefer allocator.free(summary);
    const fingerprint = try allocator.dupe(u8, jsonObjectString(record_obj, "fingerprint"));
    errdefer allocator.free(fingerprint);
    const search_text = try searchTextAlloc(allocator, record_obj);
    errdefer allocator.free(search_text);
    return .{
        .id = id,
        .captured_at = captured_at,
        .logical_kind = logical_kind,
        .kind = kind,
        .operation = operation,
        .authority = authority,
        .summary = summary,
        .fingerprint = fingerprint,
        .record_json = record_json,
        .line_json = line_json,
        .search_text = search_text,
    };
}

fn deinitRecords(allocator: std.mem.Allocator, records: *std.ArrayList(StoredRecord)) void {
    for (records.items) |*record| record.deinit(allocator);
    records.deinit(allocator);
}

fn searchTextAlloc(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const fields = [_][]const u8{ "id", "logical_kind", "kind", "operation", "authority", "summary" };
    for (fields) |field| {
        const text = jsonObjectString(obj, field);
        if (text.len == 0) continue;
        try out.writer.writeAll(text);
        try out.writer.writeByte(' ');
    }
    if (obj.get("payload")) |payload| {
        const payload_json = try jsonValueAlloc(allocator, payload);
        defer allocator.free(payload_json);
        try out.writer.writeAll(payload_json);
    }
    return out.toOwnedSlice();
}

fn findDuplicateByFingerprintAlloc(allocator: std.mem.Allocator, path: []const u8, fingerprint: []const u8) !?[]u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    for (records.items) |record| {
        if (std.mem.eql(u8, record.fingerprint, fingerprint)) return try allocator.dupe(u8, record.id);
    }
    return null;
}

fn validateJsonlBytes(allocator: std.mem.Allocator, bytes: []const u8) !usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        var record = try parseStoredRecordAlloc(allocator, line);
        record.deinit(allocator);
        count += 1;
    }
    return count;
}

fn collectNoteRows(allocator: std.mem.Allocator, notes_dir: []const u8, rows: *std.ArrayList([]u8)) !void {
    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), notes_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var iter = dir.iterate();
    while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ notes_dir, entry.name });
        defer allocator.free(path);
        const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, MaxInputBytes);
        defer allocator.free(bytes);
        const line = std.mem.trim(u8, bytes, " \t\r\n");
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, jsonObjectString(obj, "extension"), "synesthesia")) continue;
        const row = try eventLineFromStoredNoteAlloc(allocator, obj);
        try rows.append(allocator, row);
    }
}

fn eventLineFromStoredNoteAlloc(allocator: std.mem.Allocator, note: std.json.ObjectMap) ![]u8 {
    const note_id = try nonemptyString(note, "id");
    const captured_at = try nonemptyString(note, "captured_at");
    const kind = try nonemptyString(note, "kind");
    const operation = try nonemptyString(note, "operation");
    const fingerprint = try nonemptyString(note, "fingerprint");
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('{');
    var first = true;
    try writeStringField(&out.writer, &first, "id", note_id);
    try writeStringField(&out.writer, &first, "captured_at", captured_at);
    try writeStringField(&out.writer, &first, "logical_kind", kind);
    try copyField(&out.writer, &first, note, "kind");
    try copyField(&out.writer, &first, note, "operation");
    try copyField(&out.writer, &first, note, "authority");
    try copyField(&out.writer, &first, note, "summary");
    try copyField(&out.writer, &first, note, "scope");
    try copyField(&out.writer, &first, note, "source_refs");
    try copyField(&out.writer, &first, note, "related_ids");
    try copyField(&out.writer, &first, note, "supersedes_id");
    try writeStringField(&out.writer, &first, "fingerprint", fingerprint);
    try copyField(&out.writer, &first, note, "payload");
    try out.writer.writeByte('}');
    const record_json = try out.toOwnedSlice();
    defer allocator.free(record_json);
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    try line.writer.writeAll("{\"v\":1,\"source\":\"synesthesia\",\"event\":\"synesthesia.capture\",\"syn_id\":");
    try writeJsonString(&line.writer, note_id);
    try line.writer.writeAll(",\"captured_at\":");
    try writeJsonString(&line.writer, captured_at);
    try line.writer.writeAll(",\"kind\":");
    try writeJsonString(&line.writer, kind);
    try line.writer.writeAll(",\"logical_kind\":");
    try writeJsonString(&line.writer, kind);
    try line.writer.writeAll(",\"operation\":");
    try writeJsonString(&line.writer, operation);
    try line.writer.writeAll(",\"record\":");
    try line.writer.writeAll(record_json);
    try line.writer.writeByte('}');
    return line.toOwnedSlice();
}

fn synesthesiaNotesExist(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    const notes_dir = try defaultNotesDirAlloc(allocator, codex_home);
    defer allocator.free(notes_dir);
    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), notes_dir, .{ .iterate = true }) catch return false;
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var iter = dir.iterate();
    while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) return true;
    }
    return false;
}

fn fingerprintAlloc(allocator: std.mem.Allocator, physical_kind: []const u8, logical_kind: []const u8, obj: std.json.ObjectMap) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("synesthesia\n");
    hasher.update(physical_kind);
    hasher.update("\n");
    hasher.update(logical_kind);
    hasher.update("\n");
    const json = try jsonValueAlloc(allocator, .{ .object = obj });
    defer allocator.free(json);
    hasher.update(json);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn buildSynIdAlloc(allocator: std.mem.Allocator, timestamp: []const u8, fingerprint: []const u8) ![]u8 {
    var compact: [15]u8 = undefined;
    if (timestamp.len >= 20) {
        @memcpy(compact[0..4], timestamp[0..4]);
        @memcpy(compact[4..6], timestamp[5..7]);
        @memcpy(compact[6..8], timestamp[8..10]);
        compact[8] = 'T';
        @memcpy(compact[9..11], timestamp[11..13]);
        @memcpy(compact[11..13], timestamp[14..16]);
        @memcpy(compact[13..15], timestamp[17..19]);
    } else {
        @memset(&compact, '0');
    }
    return std.fmt.allocPrint(allocator, "SYN-{s}Z-{s}", .{ compact[0..], fingerprint[0..16] });
}

fn nowUtcAlloc(allocator: std.mem.Allocator) ![]u8 {
    var ts: std.posix.timespec = undefined;
    const now_sec: i64 = switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => @intCast(ts.sec),
        else => return error.ClockUnavailable,
    };
    var days = @divFloor(now_sec, 86_400);
    var seconds_of_day = now_sec - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }
    const civil = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(civil.year)),
        @as(u32, @intCast(civil.month)),
        @as(u32, @intCast(civil.day)),
        @as(u32, @intCast(hour)),
        @as(u32, @intCast(minute)),
        @as(u32, @intCast(second)),
    });
}

const CivilDate = struct { year: i64, month: i64, day: i64 };

fn civilFromDays(days_in: i64) CivilDate {
    const z = days_in + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9);
    y += if (m <= 2) 1 else 0;
    return .{ .year = y, .month = m, .day = d };
}

fn lexicalScore(query_lower: []const u8, hay_lower: []const u8) usize {
    var score: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, query_lower, " \t\r\n,.;:/()[]{}<>\"'`");
    while (tokens.next()) |token| {
        if (token.len < 2) continue;
        if (std.mem.indexOf(u8, hay_lower, token) != null) score += 1;
    }
    return score;
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |char, idx| out[idx] = if (char >= 'A' and char <= 'Z') char + 32 else char;
    return out;
}

fn readInputAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
    }
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(MaxInputBytes));
}

fn resolveJsonlPathAlloc(allocator: std.mem.Allocator, repo_root: []const u8, raw_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) return allocator.dupe(u8, raw_path);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, raw_path });
}

fn resolveOutputPathAlloc(allocator: std.mem.Allocator, repo_root: []const u8, raw_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) return allocator.dupe(u8, raw_path);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, raw_path });
}

fn defaultCodexHomeAlloc(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    if (codex_home.len > 0) return allocator.dupe(u8, codex_home);
    const home = std.Io.Threaded.global_single_threaded.environString("HOME") orelse return error.MissingHomeEnv;
    return std.fmt.allocPrint(allocator, "{s}/.codex", .{home});
}

fn defaultNotesDirAlloc(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    const home = try defaultCodexHomeAlloc(allocator, codex_home);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/memories/extensions/synesthesia/notes", .{home});
}

fn defaultDigestOutputPathAlloc(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    const home = try defaultCodexHomeAlloc(allocator, codex_home);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/memories/extensions/synesthesia/resources/latest_synesthesia_digest.md", .{home});
}

fn discoverRepoRootAlloc(allocator: std.mem.Allocator, start: []const u8) ![]u8 {
    const normalized_start = try normalizeRepoProbePathAlloc(allocator, start);
    if (pathHasGitMarker(normalized_start)) return normalized_start;

    var current = try allocator.dupe(u8, normalized_start);
    while (parentPathOrNull(current)) |parent| {
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
        if (pathHasGitMarker(current)) {
            allocator.free(normalized_start);
            return current;
        }
    }
    allocator.free(current);
    return normalized_start;
}

fn normalizeRepoProbePathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const canonical = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.realPathFileAbsoluteAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator) catch null
    else
        std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator) catch null;
    if (canonical) |value| {
        defer allocator.free(value);
        return trimTrailingPathSeparatorsAlloc(allocator, value);
    }
    return trimTrailingPathSeparatorsAlloc(allocator, path);
}

fn trimTrailingPathSeparatorsAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == std.fs.path.sep or path[end - 1] == std.fs.path.sep_windows)) : (end -= 1) {}
    return allocator.dupe(u8, path[0..end]);
}

fn parentPathOrNull(path: []const u8) ?[]const u8 {
    const parent = std.fs.path.dirname(path) orelse return null;
    if (parent.len == 0 or std.mem.eql(u8, parent, path)) return null;
    return parent;
}

fn pathHasGitMarker(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    dir.access(std.Io.Threaded.global_single_threaded.io(), ".git", .{}) catch return false;
    return true;
}

fn jsonObjectString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = obj.get(key) orelse return "";
    return switch (value) {
        .string => |text| text,
        .number_string => |text| text,
        else => "",
    };
}

fn jsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(bytes);
}

fn writeObjectKey(writer: anytype, first: *bool, key: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writeJsonString(writer, key);
    try writer.writeByte(':');
}

fn writeStringField(writer: anytype, first: *bool, key: []const u8, value: []const u8) !void {
    try writeObjectKey(writer, first, key);
    try writeJsonString(writer, value);
}

fn writeOptionalStringField(writer: anytype, first: *bool, key: []const u8, value: ?[]const u8) !void {
    try writeObjectKey(writer, first, key);
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeValueField(writer: anytype, first: *bool, key: []const u8, value: std.json.Value) !void {
    try writeObjectKey(writer, first, key);
    try std.json.Stringify.value(value, .{}, writer);
}

fn copyField(writer: anytype, first: *bool, obj: std.json.ObjectMap, key: []const u8) !void {
    const value = obj.get(key) orelse return;
    try writeValueField(writer, first, key, value);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "operation matrix rejects assistant inference and wrong operation" {
    const raw =
        "{\"operation\":\"assert\",\"authority\":\"assistant-inference\",\"summary\":\"bad\",\"scope\":{\"kind\":\"task-family\",\"repo\":null,\"paths\":[]},\"source_refs\":[{\"kind\":\"user\",\"ref\":\"r\",\"summary\":\"s\"}],\"related_ids\":[],\"supersedes_id\":null,\"payload\":{\"sensory_phrase\":\"long corridor\",\"engineering_translation\":\"serialized waits\",\"activation_boundary\":\"latency work\",\"non_activation_boundary\":\"syntax\",\"verification\":\"name the wait\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidAuthority, validateAndFingerprint(std.testing.allocator, "mapping-endorsement", parsed.value.object));
}

test "capture validates endorsement and creates SYN id" {
    const raw =
        "{\"operation\":\"assert\",\"authority\":\"explicit-user-endorsement\",\"summary\":\"Endorse long corridor.\",\"scope\":{\"kind\":\"task-family\",\"repo\":null,\"paths\":[]},\"source_refs\":[{\"kind\":\"user\",\"ref\":\"r\",\"summary\":\"s\"}],\"related_ids\":[],\"supersedes_id\":null,\"payload\":{\"sensory_phrase\":\"long corridor\",\"engineering_translation\":\"serialized waits\",\"activation_boundary\":\"latency work\",\"non_activation_boundary\":\"syntax\",\"verification\":\"name the wait\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    var normalized = try validateAndFingerprint(std.testing.allocator, "mapping-endorsement", parsed.value.object);
    defer normalized.deinit(std.testing.allocator);
    const id = try buildSynIdAlloc(std.testing.allocator, "2026-06-30T12:34:56Z", normalized.fingerprint);
    defer std.testing.allocator.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "SYN-20260630T123456Z-"));
}

test "duplicate capture is successful no-op and leaves durable store unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, DefaultSynesthesiaPath });
    defer std.testing.allocator.free(store_path);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "synesthesia.json" });
    defer std.testing.allocator.free(input_path);

    const raw =
        "{\"operation\":\"assert\",\"authority\":\"explicit-user-endorsement\",\"summary\":\"Endorse long corridor.\",\"scope\":{\"kind\":\"task-family\",\"repo\":null,\"paths\":[]},\"source_refs\":[{\"kind\":\"user\",\"ref\":\"r\",\"summary\":\"s\"}],\"related_ids\":[],\"supersedes_id\":null,\"payload\":{\"sensory_phrase\":\"long corridor\",\"engineering_translation\":\"serialized waits\",\"activation_boundary\":\"latency work\",\"non_activation_boundary\":\"syntax\",\"verification\":\"name the wait\"}}";
    try durable_store.writeTextAtomic(std.testing.allocator, input_path, raw);

    const args = Args{
        .command = .capture,
        .path = DefaultSynesthesiaPath,
        .json_path = input_path,
        .kind = "mapping-endorsement",
    };
    var first = (try cmdCapture(std.testing.allocator, root_abs, args)).?;
    defer first.deinit(std.testing.allocator);

    const before = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(before);
    const duplicate = try cmdCapture(std.testing.allocator, root_abs, args);
    try std.testing.expect(duplicate == null);
    const after = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "memory-note export omits ledger metadata" {
    const raw =
        "{\"operation\":\"assert\",\"authority\":\"explicit-user-endorsement\",\"summary\":\"Endorse long corridor.\",\"scope\":{\"kind\":\"task-family\",\"repo\":null,\"paths\":[]},\"source_refs\":[{\"kind\":\"user\",\"ref\":\"r\",\"summary\":\"s\"}],\"related_ids\":[],\"supersedes_id\":null,\"payload\":{\"sensory_phrase\":\"long corridor\",\"engineering_translation\":\"serialized waits\",\"activation_boundary\":\"latency work\",\"non_activation_boundary\":\"syntax\",\"verification\":\"name the wait\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    var normalized = try validateAndFingerprint(std.testing.allocator, "mapping-endorsement", parsed.value.object);
    defer normalized.deinit(std.testing.allocator);
    const record_json = try encodeRecordJsonAlloc(std.testing.allocator, "SYN-20260630T123456Z-0123456789abcdef", "2026-06-30T12:34:56Z", normalized);
    defer std.testing.allocator.free(record_json);
    const event_line = try encodeEventLineAlloc(std.testing.allocator, "SYN-20260630T123456Z-0123456789abcdef", "2026-06-30T12:34:56Z", normalized, record_json);
    defer std.testing.allocator.free(event_line);
    var record = try parseStoredRecordAlloc(std.testing.allocator, event_line);
    defer record.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeMemoryNoteProjection(std.testing.allocator, &out.writer, record);
    const projection = try out.toOwnedSlice();
    defer std.testing.allocator.free(projection);
    try std.testing.expect(std.mem.indexOf(u8, projection, "\"logical_kind\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, projection, "\"operation\":\"assert\"") != null);
}

test "prior operations require a relationship" {
    const raw =
        "{\"operation\":\"confirm\",\"authority\":\"explicit-user-endorsement\",\"summary\":\"Confirm long corridor.\",\"scope\":{\"kind\":\"task-family\",\"repo\":null,\"paths\":[]},\"source_refs\":[{\"kind\":\"user\",\"ref\":\"r\",\"summary\":\"s\"}],\"related_ids\":[],\"supersedes_id\":null,\"payload\":{\"sensory_phrase\":\"long corridor\",\"engineering_translation\":\"serialized waits\",\"activation_boundary\":\"latency work\",\"non_activation_boundary\":\"syntax\",\"verification\":\"name the wait\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.MissingPriorRelationship, validateAndFingerprint(std.testing.allocator, "mapping-confirmation", parsed.value.object));
}
