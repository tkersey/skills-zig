const core_calendar = @import("core_calendar");
const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");
const memory_layout = @import("memory_layout.zig");
const memory_migrate = @import("memory_migrate.zig");
const memory_storage = @import("memory_storage.zig");
const memory_envelope = @import("memory_envelope.zig");
const memory_inventory = @import("memory_inventory.zig");

const Fs = durable_store.Fs;
const Version = core_cli.normalizeVersion(app_meta.version);

const MaxInputBytes = 1024 * 1024;
const MaxNoteBytes = memory_inventory.note_bytes_max;

const HelpText =
    \\memory-note
    \\
    \\Safe append-only custom memory-source note writer.
    \\
    \\usage: memory-note {append,list,show,doctor,path,migrate,version} [options]
    \\
    \\commands:
    \\  append   Append one typed note from --json FILE|-
    \\  list     List notes for an extension
    \\  show     Show one note by --id
    \\  doctor   Validate controlled memory-source layout
    \\  path     Print the selected notes path (--format json for the full layout)
    \\  migrate  Copy existing immutable notes from another version without recapturing
    \\  version  Show version
    \\
    \\options:
    \\  --extension NAME       harness|learnings|negative-ledger|synesthesia
    \\  --kind KIND            Extension-specific note kind
    \\  --json FILE|-          Append input JSON
    \\  --id NOTE-ID           Note id for show
    \\  --codex-home PATH      Override CODEX_HOME
    \\  --memory-version v1|v2 Pin an active session's layout; otherwise read Codex config
    \\  --from-memory-version v1|v2 Source layout for explicit note migration
    \\  --dry-run              Validate/render without writing
    \\  --limit N              List limit
    \\  --format json|text|raw Output format where supported
    \\  -h, --help             Show help
    \\  -V, --version          Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = "memory-note",
    .help_text = HelpText,
};

const Command = enum { append, list, show, doctor, path, migrate, version };

const Args = struct {
    command: Command,
    extension: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    id: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
    memory_version: ?memory_layout.Version = null,
    from_memory_version: ?memory_layout.Version = null,
    dry_run: bool = false,
    limit: usize = 100,
    format: ?[]const u8 = null,
};

const ParsedNote = struct {
    id: []const u8,
    captured_at: []const u8,
    extension: []const u8,
    kind: []const u8,
    operation: []const u8,
    summary: []const u8,
    fingerprint: []const u8,
};

const DoctorPathDiagnostic = struct {
    checked_path: []const u8,
    offending_component: ?[]u8 = null,
    component_kind: []const u8 = "unknown",

    fn deinit(self: *DoctorPathDiagnostic, allocator: std.mem.Allocator) void {
        if (self.offending_component) |component| allocator.free(component);
        self.* = .{ .checked_path = "" };
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
    var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});
    const stdout = &stdout_writer.interface;
    if (try handleHelpAndVersion(allocator, stdout, argv)) return;

    const args = parseArgs(argv) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(init.io, &.{});
        core_cli.printUsageFailureWithHelp(
            &stderr_writer.interface,
            HelpSurface,
            Version,
            @errorName(err),
            null,
        ) catch {
            std.process.exit(1);
        };
        std.process.exit(2);
    };

    const code = run(
        Fs.init(init.io, .cwd()),
        allocator,
        std.Io.File.stdin(),
        stdout,
        init.environ_map,
        args,
    ) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(init.io, &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("memory-note: {s}\n", .{@errorName(err)});
        std.process.exit(exitCodeForError(err));
    };
    std.process.exit(code);
}

fn handleHelpAndVersion(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    argv: []const []const u8,
) !bool {
    if (argv.len <= 1) {
        try writeHelp(allocator, stdout);
        return true;
    }
    const first = argv[1];
    if (core_cli.isHelpArg(first)) {
        try writeHelp(allocator, stdout);
        return true;
    }
    if (core_cli.isVersionArg(first) or core_cli.isVersionSubcommand(first)) {
        try writeVersion(allocator, stdout);
        return true;
    }
    if (parseCommand(first) != null and core_cli.containsHelpArg(argv[2..])) {
        try writeHelp(allocator, stdout);
        return true;
    }
    return false;
}

fn writeHelp(allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try core_cli.printHelpSurface(&out.writer, HelpSurface, Version);
    try writeOutputAlloc(allocator, stdout, &out);
}

fn writeVersion(allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try core_cli.printVersion(&out.writer, Version);
    try writeOutputAlloc(allocator, stdout, &out);
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 2) return error.MissingCommand;
    var args = Args{ .command = parseCommand(argv[1]) orelse return error.UnknownCommand };
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (std.mem.eql(u8, token, "--extension")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.extension = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--kind")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.kind = argv[i];
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
        if (std.mem.eql(u8, token, "--codex-home")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.codex_home = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--memory-version")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.memory_version = try memory_layout.Version.parse(argv[i]);
            continue;
        }
        if (std.mem.eql(u8, token, "--from-memory-version")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.from_memory_version = try memory_layout.Version.parse(argv[i]);
            continue;
        }
        if (std.mem.eql(u8, token, "--dry-run")) {
            args.dry_run = true;
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
        return error.UnknownOption;
    }
    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "append")) return .append;
    if (std.mem.eql(u8, raw, "list")) return .list;
    if (std.mem.eql(u8, raw, "show")) return .show;
    if (std.mem.eql(u8, raw, "doctor")) return .doctor;
    if (std.mem.eql(u8, raw, "path")) return .path;
    if (std.mem.eql(u8, raw, "migrate")) return .migrate;
    if (std.mem.eql(u8, raw, "version")) return .version;
    return null;
}

fn run(
    fs: Fs,
    allocator: std.mem.Allocator,
    stdin: std.Io.File,
    stdout: *std.Io.Writer,
    env: *std.process.Environ.Map,
    unresolved: Args,
) !u8 {
    var args = unresolved;
    if (args.command != .migrate and args.from_memory_version != null)
        return error.UnexpectedMigrationSource;
    if (args.command == .version) {
        try writeVersion(allocator, stdout);
        return 0;
    }
    const home = try codexHomeAlloc(allocator, env, args.codex_home);
    defer allocator.free(home);
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCodexHome;
    memory_layout.validateDirectory(fs.io, fs.directory(), home) catch |err| {
        if (args.command == .doctor) return cmdDoctor(fs, allocator, stdout, home, args, err);
        return err;
    };
    args.memory_version = try memory_layout.selectedVersion(
        allocator,
        fs.io,
        fs.directory(),
        env,
        home,
        args.memory_version,
    );
    return switch (args.command) {
        .append => try cmdAppend(fs, stdin, allocator, stdout, home, args),
        .list => try cmdList(fs, allocator, stdout, home, args),
        .show => try cmdShow(fs, allocator, stdout, home, args),
        .doctor => try cmdDoctor(fs, allocator, stdout, home, args, null),
        .path => try cmdPath(fs, allocator, stdout, home, args),
        .migrate => try cmdMigrate(fs, allocator, stdout, home, args),
        .version => {
            try writeVersion(allocator, stdout);
            return 0;
        },
    };
}

fn validatedAppendInput(
    allocator: std.mem.Allocator,
    extension: []const u8,
    kind: []const u8,
    input: []const u8,
) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    try memory_envelope.validateCommon(parsed.value.object);
    try validatePayload(extension, kind, parsed.value.object);
    try rejectSensitiveKeys(allocator, parsed.value);
    return parsed;
}

fn cmdAppend(
    fs: Fs,
    stdin: std.Io.File,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    home: []const u8,
    args: Args,
) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    const kind = args.kind orelse return error.MissingKind;
    const json_path = args.json_path orelse return error.MissingJson;
    try validateExtensionKind(extension, kind);

    const input = try readJsonInput(fs, stdin, allocator, json_path);
    defer allocator.free(input);
    if (input.len > MaxInputBytes) return error.InputTooLarge;

    var parsed = try validatedAppendInput(allocator, extension, kind, input);
    defer parsed.deinit();
    const fingerprint = try fingerprintInputAlloc(allocator, extension, kind, input);
    defer allocator.free(fingerprint);
    const now = try nowUtcAlloc(fs.io, allocator);
    defer allocator.free(now);
    try validateEnvelopeSize(now, extension, kind, fingerprint, parsed.value);

    const notes_dir = try notesDirAlloc(allocator, home, args, extension);
    defer allocator.free(notes_dir);
    try memory_layout.validateDirectory(fs.io, fs.directory(), notes_dir);
    const lock_path = try memoryNoteLockPathAlloc(allocator, home, extension);
    defer allocator.free(lock_path);
    var lock = if (args.dry_run)
        null
    else
        try memory_storage.acquireExtensionLock(fs, allocator, lock_path);
    defer if (lock) |*held| held.release();

    if (try findFingerprint(fs, allocator, notes_dir, fingerprint)) |existing| {
        defer allocator.free(existing.id);
        defer allocator.free(existing.path);
        try writeDuplicateSkip(allocator, stdout, extension, kind, existing, fingerprint);
        return 0;
    }

    return appendNew(fs, allocator, stdout, args, notes_dir, now, fingerprint, parsed.value);
}

fn appendNew(
    fs: Fs,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    args: Args,
    notes_dir: []const u8,
    now: []const u8,
    fingerprint: []const u8,
    input: std.json.Value,
) !u8 {
    const extension = args.extension.?;
    const kind = args.kind.?;
    const fp16 = fingerprint[0..16];
    const id = try noteIdAlloc(allocator, now, fp16);
    defer allocator.free(id);
    const root = input.object;
    const slug = try slugAlloc(allocator, root.get("slug"), root.get("summary"));
    defer allocator.free(slug);
    const filename = try filenameAlloc(allocator, now, kind, slug, fp16);
    defer allocator.free(filename);
    const dest_path = try std.fs.path.join(allocator, &.{ notes_dir, filename });
    defer allocator.free(dest_path);
    const note = try renderEnvelopeAlloc(allocator, id, now, extension, kind, fingerprint, input);
    defer allocator.free(note);
    std.debug.assert(note.len <= MaxNoteBytes);

    if (args.dry_run) {
        try writeDryRun(allocator, stdout, id, extension, kind, fingerprint, dest_path, note);
        return 0;
    }

    try memory_storage.publishNote(fs, allocator, dest_path, note);
    try writeCreated(allocator, stdout, id, extension, kind, fingerprint, dest_path);
    return 0;
}

fn cmdList(
    fs: Fs,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    home: []const u8,
    args: Args,
) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    try validateExtension(extension);
    const notes_dir = try notesDirAlloc(allocator, home, args, extension);
    defer allocator.free(notes_dir);
    try memory_layout.validateDirectory(fs.io, fs.directory(), notes_dir);
    var inventory = try memory_inventory.Reader.open(fs, allocator, notes_dir, .empty);
    defer inventory.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("{{\"extension\":", .{});
    try writeJsonString(w, extension);
    try w.writeAll(",\"notes\":[");
    var emitted: usize = 0;
    var idx = inventory.names.len;
    while (idx > 0 and emitted < args.limit) {
        idx -= 1;
        const record = try inventory.readBorrowed(idx);
        const parsed = inventory.parseBorrowed(record) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        const note = parseNoteSummary(parsed) catch continue;
        if (args.kind) |wanted| {
            if (!std.mem.eql(u8, note.kind, wanted)) continue;
        }
        if (emitted > 0) try w.writeByte(',');
        try writeNoteSummaryJson(w, note, record.path);
        emitted += 1;
    }
    try w.writeAll("],\"truncated\":");
    try w.writeAll(if (inventory.names.len > emitted) "true" else "false");
    try w.writeAll("}\n");
    try writeOutputAlloc(allocator, stdout, &out);
    return 0;
}

fn cmdShow(
    fs: Fs,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    home: []const u8,
    args: Args,
) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    const id = args.id orelse return error.MissingId;
    try validateExtension(extension);
    const notes_dir = try notesDirAlloc(allocator, home, args, extension);
    defer allocator.free(notes_dir);
    try memory_layout.validateDirectory(fs.io, fs.directory(), notes_dir);
    var inventory = try memory_inventory.Reader.open(fs, allocator, notes_dir, .fail);
    defer inventory.deinit();

    var found: ?[]u8 = null;
    defer if (found) |owned| allocator.free(owned);
    for (0..inventory.names.len) |index| {
        const record = try inventory.readBorrowed(index);
        const parsed = inventory.parseBorrowed(record) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        const note = parseNoteSummary(parsed) catch continue;
        if (std.mem.eql(u8, note.id, id)) {
            if (found != null) return error.DuplicateId;
            found = try allocator.dupe(u8, record.raw);
        }
    }
    const payload = found orelse return error.NotFound;
    const format = args.format orelse "json";
    if (std.mem.eql(u8, format, "raw") or std.mem.eql(u8, format, "json")) {
        try stdout.writeAll(payload);
        return 0;
    }
    return error.InvalidFormat;
}

fn cmdDoctor(
    fs: Fs,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    home: []const u8,
    args: Args,
    home_issue: ?anyerror,
) !u8 {
    std.debug.assert(args.memory_version != null or home_issue != null);
    if (args.extension) |extension| try validateExtension(extension);
    var issues: usize = 0;
    var checked: usize = 0;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"command\":\"doctor\",\"extensions\":[");
    var emitted_extension = false;
    for (AllowedExtensions) |extension| {
        if (args.extension) |wanted| {
            if (!std.mem.eql(u8, extension, wanted)) continue;
        }
        if (emitted_extension) try w.writeByte(',');
        emitted_extension = true;
        try w.writeAll("{\"extension\":");
        try writeJsonString(w, extension);
        const notes_dir = if (args.memory_version != null)
            try notesDirAlloc(allocator, home, args, extension)
        else
            try allocator.dupe(u8, home);
        defer allocator.free(notes_dir);
        var path_issue = home_issue;
        if (path_issue == null) {
            memory_layout.validateDirectory(fs.io, fs.directory(), notes_dir) catch |err| {
                path_issue = err;
            };
        }
        if (path_issue) |err| {
            issues += 1;
            var diagnostic = try doctorPathDiagnosticAlloc(fs, allocator, notes_dir, err);
            defer diagnostic.deinit(allocator);
            try writeDoctorFailureJson(w, err, diagnostic);
            continue;
        }
        var inventory = try memory_inventory.Reader.open(fs, allocator, notes_dir, .empty);
        defer inventory.deinit();
        const counts = try doctorNoteCounts(&inventory, extension);
        checked += counts.checked;
        issues += counts.issues;
        try w.print(",\"status\":\"ok\",\"notes\":{d}}}", .{inventory.names.len});
    }
    try w.print("],\"checked\":{d},\"issues\":{d},\"storage_mutated\":false}}\n", .{
        checked, issues,
    });
    try writeOutputAlloc(allocator, stdout, &out);
    return if (issues == 0) 0 else 8;
}

fn doctorNoteCounts(
    inventory: *memory_inventory.Reader,
    extension: []const u8,
) !struct { checked: usize, issues: usize } {
    var checked: usize = 0;
    var issues: usize = 0;
    for (0..inventory.names.len) |index| {
        const record = try inventory.readBorrowed(index);
        const parsed = inventory.parseBorrowed(record) catch |err| {
            if (err == error.OutOfMemory) return err;
            issues += 1;
            continue;
        };
        const note = parseNoteSummary(parsed) catch {
            issues += 1;
            continue;
        };
        if (!std.mem.eql(u8, note.extension, extension)) issues += 1;
        checked += 1;
    }
    return .{ .checked = checked, .issues = issues };
}

fn cmdPath(
    fs: Fs,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    home: []const u8,
    args: Args,
) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    try validateExtension(extension);
    const version = args.memory_version.?;
    const root = try std.fs.path.join(allocator, &.{ home, version.directory() });
    defer allocator.free(root);
    const extension_root = try std.fs.path.join(allocator, &.{ root, "extensions", extension });
    defer allocator.free(extension_root);
    const notes_dir = try std.fs.path.join(allocator, &.{ extension_root, "notes" });
    defer allocator.free(notes_dir);
    const instructions = try std.fs.path.join(allocator, &.{ extension_root, "instructions.md" });
    defer allocator.free(instructions);
    const resources = try std.fs.path.join(allocator, &.{ extension_root, "resources" });
    defer allocator.free(resources);
    try memory_layout.validateDirectory(fs.io, fs.directory(), notes_dir);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const format = args.format orelse "text";
    if (std.mem.eql(u8, format, "text")) {
        try out.writer.print("{s}\n", .{notes_dir});
    } else if (std.mem.eql(u8, format, "json")) {
        try std.json.Stringify.value(.{
            .schema = "memory-note-layout/v1",
            .codex_home = home,
            .memory_version = @tagName(version),
            .memory_root = root,
            .extension_root = extension_root,
            .notes_dir = notes_dir,
            .instructions_path = instructions,
            .resources_dir = resources,
        }, .{}, &out.writer);
        try out.writer.writeByte('\n');
    } else return error.InvalidFormat;
    try writeOutputAlloc(allocator, stdout, &out);
    return 0;
}

fn cmdMigrate(
    fs: Fs,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    home: []const u8,
    args: Args,
) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    try validateExtension(extension);
    const from = args.from_memory_version orelse return error.MissingFromMemoryVersion;
    const to = args.memory_version.?;
    if (from == to) return error.SameMemoryVersion;
    var source_args = args;
    source_args.memory_version = from;
    const source = try notesDirAlloc(allocator, home, source_args, extension);
    defer allocator.free(source);
    const destination = try notesDirAlloc(allocator, home, args, extension);
    defer allocator.free(destination);
    const result = if (args.dry_run)
        try memory_migrate.copy(fs, allocator, source, destination, extension, true)
    else result: {
        const lock_path = try memoryNoteLockPathAlloc(allocator, home, extension);
        defer allocator.free(lock_path);
        var lock = try memory_storage.acquireExtensionLock(fs, allocator, lock_path);
        defer lock.release();
        var copied = try memory_migrate.copy(
            fs,
            allocator,
            source,
            destination,
            extension,
            false,
        );
        copied.storage_mutated = copied.storage_mutated or lock.created;
        break :result copied;
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{
        .schema = "memory-note-migration/v1",
        .from_memory_version = @tagName(from),
        .memory_version = @tagName(to),
        .source_notes = result.source_notes,
        .copied = result.copied,
        .duplicate_skip = result.duplicate_skip,
        .planned = result.planned,
        .storage_mutated = result.storage_mutated,
    }, .{}, &out.writer);
    try out.writer.writeByte('\n');
    try writeOutputAlloc(allocator, stdout, &out);
    return 0;
}

const AllowedExtensions = [_][]const u8{ "harness", "learnings", "negative-ledger", "synesthesia" };

fn validateExtension(extension: []const u8) !void {
    for (AllowedExtensions) |allowed| {
        if (std.mem.eql(u8, extension, allowed)) return;
    }
    return error.InvalidExtension;
}

fn validateExtensionKind(extension: []const u8, kind: []const u8) !void {
    try validateExtension(extension);
    if (std.mem.eql(u8, extension, "harness")) {
        if (oneOf(
            kind,
            &.{
                "harness-rule",
                "harness-confirmation",
                "harness-supersession",
                "harness-retraction",
            },
        )) return;
    } else if (std.mem.eql(u8, extension, "learnings")) {
        if (oneOf(
            kind,
            &.{
                "learning-admission",
                "learning-confirmation",
                "learning-supersession",
                "learning-withdrawal",
            },
        )) return;
    } else if (std.mem.eql(u8, extension, "negative-ledger")) {
        if (oneOf(
            kind,
            &.{
                "ledger-projection",
                "ledger-status-transition",
                "ledger-supersession",
                "ledger-retraction",
            },
        )) return;
    } else if (std.mem.eql(u8, extension, "synesthesia")) {
        if (oneOf(
            kind,
            &.{
                "mapping-endorsement",
                "mapping-correction",
                "mapping-rejection",
                "activation-boundary",
                "boundary-retraction",
            },
        )) return;
    }
    return error.InvalidKind;
}

fn oneOf(value: []const u8, comptime values: []const []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

const HarnessPayloadFields = &.{
    "harness_rule",
    "trigger",
    "preferred_behavior",
    "failure_avoided",
    "verification_cue",
};

const LearningPayloadFields = &.{
    "learning_id",
    "learning_status",
    "repo",
    "source_path",
    "decision_delta",
    "future_behavior",
    "verification",
};

const NegativePayloadFields = &.{
    "neg_id",
    "record_version",
    "ledger_path",
    "projection_fingerprint",
    "status",
    "kind",
    "artifact_state_id",
    "hypothesis",
    "attempted_change",
    "observed_outcome",
    "failure_class",
    "exclusion_scope",
    "confidence",
    "next_search_hint",
};

const MappingPayloadFields = &.{
    "sensory_phrase",
    "activation_boundary",
    "scope",
    "endorsement_type",
    "verification",
};

fn validatePayload(extension: []const u8, kind: []const u8, root: std.json.ObjectMap) !void {
    const payload_value = root.get("payload") orelse return error.InvalidJson;
    const payload = switch (payload_value) {
        .object => |value| value,
        else => return error.InvalidJson,
    };
    if (std.mem.eql(u8, extension, "harness") and std.mem.eql(u8, kind, "harness-rule")) {
        try requirePayloadStrings(
            payload,
            HarnessPayloadFields,
        );
        if (payload.get("evidence_count") == null) return error.InvalidPayload;
    } else if (std.mem.eql(u8, extension, "learnings") and std.mem.eql(
        u8,
        kind,
        "learning-admission",
    )) {
        try requirePayloadStrings(
            payload,
            LearningPayloadFields,
        );
        if (payload.get("evidence_snapshot") == null) return error.InvalidPayload;
    } else if (std.mem.eql(
        u8,
        extension,
        "negative-ledger",
    ) and std.mem.eql(u8, kind, "ledger-projection")) {
        try requirePayloadStrings(
            payload,
            NegativePayloadFields,
        );
    } else if (std.mem.eql(u8, extension, "synesthesia") and
        std.mem.startsWith(u8, kind, "mapping-"))
    {
        try requirePayloadStrings(
            payload,
            MappingPayloadFields,
        );
        if (!std.mem.eql(
            u8,
            kind,
            "mapping-rejection",
        )) _ = stringField(payload, "engineering_translation") orelse return error.InvalidPayload;
    }
}

fn requirePayloadStrings(payload: std.json.ObjectMap, comptime fields: []const []const u8) !void {
    for (fields) |field| {
        _ = stringField(payload, field) orelse return error.InvalidPayload;
    }
}

const SensitiveFrame = struct {
    value: std.json.Value,
    next: usize = 0,
};

fn rejectSensitiveKeys(allocator: std.mem.Allocator, value: std.json.Value) !void {
    var stack: std.ArrayList(SensitiveFrame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .value = value });
    // Every node requires at least one input byte; every parent requires two delimiters.
    // Heap frames borrow the parsed owner only for this call and preserve depth-first order.
    var visited: usize = 1;
    while (stack.items.len > 0) {
        const frame = &stack.items[stack.items.len - 1];
        const child: std.json.Value = switch (frame.value) {
            .object => |object| blk: {
                if (frame.next == object.count()) {
                    _ = stack.pop();
                    continue;
                }
                if (isSensitiveKey(object.keys()[frame.next])) return error.SensitiveKey;
                break :blk object.values()[frame.next];
            },
            .array => |array| blk: {
                if (frame.next == array.items.len) {
                    _ = stack.pop();
                    continue;
                }
                break :blk array.items[frame.next];
            },
            else => {
                _ = stack.pop();
                continue;
            },
        };
        frame.next += 1;
        if (visited == MaxInputBytes) return error.InputTooLarge;
        visited += 1;
        if (stack.items.len == MaxInputBytes / 2 + 1) return error.InputTooLarge;
        try stack.append(allocator, .{ .value = child });
    }
}

fn isSensitiveKey(key: []const u8) bool {
    return oneOfAsciiLower(
        key,
        &.{
            "password",
            "passwd",
            "secret",
            "api_key",
            "apikey",
            "access_token",
            "refresh_token",
            "private_key",
            "client_secret",
        },
    );
}

fn oneOfAsciiLower(value: []const u8, comptime values: []const []const u8) bool {
    for (values) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    return false;
}

fn readJsonInput(
    fs: Fs,
    stdin: std.Io.File,
    allocator: std.mem.Allocator,
    json_path: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, json_path, "-")) {
        var reader = stdin.reader(fs.io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes + 1));
    }
    return durable_store.readFileAlloc(fs, allocator, json_path, MaxInputBytes + 1);
}

fn codexHomeAlloc(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    override: ?[]const u8,
) ![]u8 {
    if (override) |path| return allocator.dupe(u8, path);
    if (env.get("CODEX_HOME")) |path| return allocator.dupe(u8, path);
    if (env.get("HOME")) |home| return std.fs.path.join(allocator, &.{ home, ".codex" });
    return error.MissingCodexHome;
}

fn notesDirAlloc(
    allocator: std.mem.Allocator,
    home: []const u8,
    args: Args,
    extension: []const u8,
) ![]u8 {
    const version = args.memory_version.?;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCodexHome;
    return std.fs.path.join(allocator, &.{
        home, version.directory(), "extensions", extension, "notes",
    });
}

fn doctorPathDiagnosticAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    checked_path: []const u8,
    issue: anyerror,
) !DoctorPathDiagnostic {
    var diagnostic = DoctorPathDiagnostic{ .checked_path = checked_path };
    errdefer diagnostic.deinit(allocator);

    var it = std.fs.path.componentIterator(checked_path);
    while (it.next()) |component| {
        const stat = fs.directory().statFile(
            fs.io,
            component.path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return diagnostic,
        };
        if (issue == error.SymlinkComponent and stat.kind == .sym_link) {
            diagnostic.offending_component = try allocator.dupe(u8, component.path);
            diagnostic.component_kind = "symlink";
            return diagnostic;
        }
        if (issue == error.NotDir and stat.kind != .directory) {
            diagnostic.offending_component = try allocator.dupe(u8, component.path);
            diagnostic.component_kind = "not_dir";
            return diagnostic;
        }
    }
    return diagnostic;
}

fn memoryNoteLockPathAlloc(
    allocator: std.mem.Allocator,
    home: []const u8,
    extension: []const u8,
) ![]u8 {
    const lock_name = try allocator.print("{s}.lock", .{extension});
    defer allocator.free(lock_name);
    return std.fs.path.join(allocator, &.{ home, ".memory-note", "locks", lock_name });
}

fn fingerprintInputAlloc(
    allocator: std.mem.Allocator,
    extension: []const u8,
    kind: []const u8,
    input: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(extension);
    hasher.update("\n");
    hasher.update(kind);
    hasher.update("\n");
    hasher.update(input);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn noteIdAlloc(allocator: std.mem.Allocator, iso: []const u8, fp16: []const u8) ![]u8 {
    return allocator.print(
        "MSN-{s}{s}{s}T{s}{s}{s}Z-{s}",
        .{ iso[0..4], iso[5..7], iso[8..10], iso[11..13], iso[14..16], iso[17..19], fp16 },
    );
}

fn filenameAlloc(
    allocator: std.mem.Allocator,
    iso: []const u8,
    kind: []const u8,
    slug: []const u8,
    fp16: []const u8,
) ![]u8 {
    return allocator.print(
        "{s}-{s}-{s}T{s}-{s}-{s}-{s}-{s}-{s}.md",
        .{
            iso[0..4],
            iso[5..7],
            iso[8..10],
            iso[11..13],
            iso[14..16],
            iso[17..19],
            kind,
            if (slug.len > 0) slug else "note",
            fp16,
        },
    );
}

fn slugAlloc(
    allocator: std.mem.Allocator,
    slug_value: ?std.json.Value,
    summary_value: ?std.json.Value,
) ![]u8 {
    if (slug_value) |value| {
        if (value == .string) return sanitizeSlugAlloc(allocator, value.string);
    }
    if (summary_value) |value| {
        if (value == .string) return sanitizeSlugAlloc(allocator, value.string);
    }
    return allocator.dupe(u8, "note");
}

fn sanitizeSlugAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var last_dash = true;
    for (raw) |c| {
        if (out.items.len >= 80) break;
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            try out.append(allocator, lower);
            last_dash = false;
        } else if (!last_dash and out.items.len > 0) {
            try out.append(allocator, '-');
            last_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(allocator, "note");
    return out.toOwnedSlice(allocator);
}

fn renderEnvelopeAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    captured_at: []const u8,
    extension: []const u8,
    kind: []const u8,
    fingerprint: []const u8,
    input: std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeEnvelope(&out.writer, id, captured_at, extension, kind, fingerprint, input);
    return out.toOwnedSlice();
}

fn validateEnvelopeSize(
    captured_at: []const u8,
    extension: []const u8,
    kind: []const u8,
    fingerprint: []const u8,
    input: std.json.Value,
) !void {
    var output: std.Io.Writer.Discarding = .init(&.{});
    try writeEnvelope(
        &output.writer,
        "MSN-00000000T000000Z-0000000000000000",
        captured_at,
        extension,
        kind,
        fingerprint,
        input,
    );
    if (output.fullCount() > MaxNoteBytes) return error.OutputTooLarge;
}

fn writeEnvelope(
    w: *std.Io.Writer,
    id: []const u8,
    captured_at: []const u8,
    extension: []const u8,
    kind: []const u8,
    fingerprint: []const u8,
    input: std.json.Value,
) !void {
    const root = input.object;
    try w.writeAll("{\"schema\":\"memory-source-note/v1\",\"id\":");
    try writeJsonString(w, id);
    try w.writeAll(",\"captured_at\":");
    try writeJsonString(w, captured_at);
    try w.writeAll(",\"extension\":");
    try writeJsonString(w, extension);
    try w.writeAll(",\"kind\":");
    try writeJsonString(w, kind);
    try copyField(w, root, "operation");
    try copyField(w, root, "authority");
    try copyField(w, root, "summary");
    try copyField(w, root, "scope");
    try copyField(w, root, "source_refs");
    try w.writeAll(",\"related_ids\":");
    if (root.get("related_ids")) |v|
        try std.json.Stringify.value(v, .{}, w)
    else
        try w.writeAll("[]");
    try w.writeAll(",\"supersedes_id\":");
    if (root.get("supersedes_id")) |v|
        try std.json.Stringify.value(v, .{}, w)
    else
        try w.writeAll("null");
    try w.writeAll(",\"fingerprint\":");
    try writeJsonString(w, fingerprint);
    try copyField(w, root, "payload");
    try w.writeAll("}\n");
}

fn copyField(w: *std.Io.Writer, root: std.json.ObjectMap, field: []const u8) !void {
    const value = root.get(field) orelse return error.InvalidJson;
    try w.writeByte(',');
    try writeJsonString(w, field);
    try w.writeByte(':');
    try std.json.Stringify.value(value, .{}, w);
}

const ExistingFingerprint = struct {
    id: []u8,
    path: []u8,
};

fn findFingerprint(
    fs: Fs,
    allocator: std.mem.Allocator,
    notes_dir: []const u8,
    fingerprint: []const u8,
) !?ExistingFingerprint {
    var inventory = try memory_inventory.Reader.open(fs, allocator, notes_dir, .empty);
    defer inventory.deinit();
    for (0..inventory.names.len) |index| {
        const record = try inventory.readBorrowed(index);
        const parsed = inventory.parseBorrowed(record) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        const note = parseNoteSummary(parsed) catch continue;
        if (std.mem.eql(u8, note.fingerprint, fingerprint)) {
            const id = try allocator.dupe(u8, note.id);
            errdefer allocator.free(id);
            return .{ .id = id, .path = try allocator.dupe(u8, record.path) };
        }
    }
    return null;
}

fn parseNoteSummary(value: std.json.Value) !ParsedNote {
    const root = switch (value) {
        .object => |object| object,
        else => return error.InvalidJson,
    };
    return .{
        .id = stringField(root, "id") orelse return error.InvalidJson,
        .captured_at = stringField(root, "captured_at") orelse return error.InvalidJson,
        .extension = stringField(root, "extension") orelse return error.InvalidJson,
        .kind = stringField(root, "kind") orelse return error.InvalidJson,
        .operation = stringField(root, "operation") orelse return error.InvalidJson,
        .summary = stringField(root, "summary") orelse return error.InvalidJson,
        .fingerprint = stringField(root, "fingerprint") orelse return error.InvalidJson,
    };
}

fn stringField(root: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = root.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn writeCreated(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    id: []const u8,
    extension: []const u8,
    kind: []const u8,
    fingerprint: []const u8,
    path: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"command\":\"append\",\"status\":\"created\",\"id\":");
    try writeJsonString(w, id);
    try w.writeAll(",\"extension\":");
    try writeJsonString(w, extension);
    try w.writeAll(",\"kind\":");
    try writeJsonString(w, kind);
    try w.writeAll(",\"fingerprint\":");
    try writeJsonString(w, fingerprint);
    try w.writeAll(",\"path\":");
    try writeJsonString(w, path);
    try w.writeAll("}\n");
    try writeOutputAlloc(allocator, stdout, &out);
}

fn writeDuplicateSkip(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    extension: []const u8,
    kind: []const u8,
    existing: ExistingFingerprint,
    fingerprint: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"command\":\"append\",\"status\":\"duplicate_skip\",\"id\":");
    try writeJsonString(w, existing.id);
    try w.writeAll(",\"extension\":");
    try writeJsonString(w, extension);
    try w.writeAll(",\"kind\":");
    try writeJsonString(w, kind);
    try w.writeAll(",\"fingerprint\":");
    try writeJsonString(w, fingerprint);
    try w.writeAll(",\"path\":");
    try writeJsonString(w, existing.path);
    try w.writeAll("}\n");
    try writeOutputAlloc(allocator, stdout, &out);
}

fn writeDryRun(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    id: []const u8,
    extension: []const u8,
    kind: []const u8,
    fingerprint: []const u8,
    path: []const u8,
    note: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"command\":\"append\",\"status\":\"valid_dry_run\",\"id\":");
    try writeJsonString(w, id);
    try w.writeAll(",\"extension\":");
    try writeJsonString(w, extension);
    try w.writeAll(",\"kind\":");
    try writeJsonString(w, kind);
    try w.writeAll(",\"fingerprint\":");
    try writeJsonString(w, fingerprint);
    try w.writeAll(",\"path\":");
    try writeJsonString(w, path);
    try w.writeAll(",\"note\":");
    try writeJsonString(w, note);
    try w.writeAll("}\n");
    try writeOutputAlloc(allocator, stdout, &out);
}

fn writeNoteSummaryJson(w: *std.Io.Writer, note: ParsedNote, path: []const u8) !void {
    try w.writeAll("{\"id\":");
    try writeJsonString(w, note.id);
    try w.writeAll(",\"captured_at\":");
    try writeJsonString(w, note.captured_at);
    try w.writeAll(",\"kind\":");
    try writeJsonString(w, note.kind);
    try w.writeAll(",\"operation\":");
    try writeJsonString(w, note.operation);
    try w.writeAll(",\"summary\":");
    try writeJsonString(w, note.summary);
    try w.writeAll(",\"fingerprint\":");
    try writeJsonString(w, note.fingerprint);
    try w.writeAll(",\"path\":");
    try writeJsonString(w, path);
    try w.writeByte('}');
}

fn writeDoctorFailureJson(
    w: *std.Io.Writer,
    issue: anyerror,
    diagnostic: DoctorPathDiagnostic,
) !void {
    try w.writeAll(",\"status\":\"failed\",\"issue\":");
    try writeJsonString(w, @errorName(issue));
    try w.writeAll(",\"checked_path\":");
    try writeJsonString(w, diagnostic.checked_path);
    if (diagnostic.offending_component) |component| {
        try w.writeAll(",\"offending_component\":");
        try writeJsonString(w, component);
    }
    try w.writeAll(",\"component_kind\":");
    try writeJsonString(w, diagnostic.component_kind);
    try w.writeByte('}');
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, w);
}

fn writeOutputAlloc(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    out: *std.Io.Writer.Allocating,
) !void {
    const payload = try out.toOwnedSlice();
    defer allocator.free(payload);
    try stdout.writeAll(payload);
}

fn exitCodeForError(err: anyerror) u8 {
    return switch (err) {
        error.UnknownCommand,
        error.UnknownOption,
        error.MissingCommand,
        error.MissingValue,
        error.MissingExtension,
        error.MissingKind,
        error.MissingJson,
        error.MissingId,
        error.InvalidMemoryVersion,
        error.MissingFromMemoryVersion,
        error.UnexpectedMigrationSource,
        error.SameMemoryVersion,
        => 2,
        error.InvalidJson, error.InvalidStoredNote => 3,
        error.InvalidExtension, error.InvalidKind, error.InvalidPayload, error.SensitiveKey => 4,
        error.SymlinkComponent,
        error.NotDir,
        error.NotFile,
        error.InvalidPath,
        error.InvalidCodexHome,
        => 5,
        error.PathAlreadyExists,
        error.DuplicateId,
        error.MigrationFilenameConflict,
        error.MigrationIdentityConflict,
        error.MemoryNoteBusy,
        error.LegacyLockNeedsReview,
        => 6,
        error.FileNotFound,
        error.NotFound,
        error.InputTooLarge,
        error.OutputTooLarge,
        error.FileTooBig,
        error.TooManyFiles,
        => 7,
        else => 9,
    };
}

fn nowUtcAlloc(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const now_sec: i64 = @intCast(@divFloor(
        std.Io.Clock.real.now(io).nanoseconds,
        1_000_000_000,
    ));
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
    return allocator.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(date.year)),
        @as(u32, @intCast(date.month)),
        @as(u32, @intCast(date.day)),
        @as(u32, @intCast(hour)),
        @as(u32, @intCast(minute)),
        @as(u32, @intCast(second)),
    });
}

fn civilFromDays(days_since_unix_epoch: i64) Date {
    const date = core_calendar.civilFromDays(days_since_unix_epoch, .legacy_negative_era);
    return .{
        .year = @intCast(date.year),
        .month = @intCast(date.month),
        .day = @intCast(date.day),
    };
}

test "validates extension kind matrix" {
    try validateExtensionKind("harness", "harness-rule");
    try std.testing.expectError(
        error.InvalidExtension,
        validateExtensionKind("ad_hoc", "harness-rule"),
    );
    try std.testing.expectError(
        error.InvalidKind,
        validateExtensionKind("harness", "ledger-projection"),
    );
}

test "rejects sensitive keys recursively" {
    const raw = "{\"payload\":{\"nested\":{\"api_key\":\"x\"}}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.SensitiveKey,
        rejectSensitiveKeys(std.testing.allocator, parsed.value),
    );
}

const EnvelopeInputFixture =
    \\{"operation":"assert","authority":"explicit-user-correction","summary":"Proceed.","scope":{"kind":"global","repo":null,"paths":[]},"source_refs":[{"kind":"user","ref":"r","summary":"s"}],"payload":{"harness_rule":"r","trigger":"t","preferred_behavior":"p","failure_avoided":"f","verification_cue":"v","evidence_count":1}}
;

test "renders envelope with generated fields" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        EnvelopeInputFixture,
        .{},
    );
    defer parsed.deinit();
    try memory_envelope.validateCommon(parsed.value.object);
    try validatePayload("harness", "harness-rule", parsed.value.object);
    const note = try renderEnvelopeAlloc(
        std.testing.allocator,
        "MSN-20260620T183000Z-0123456789abcdef",
        "2026-06-20T18:30:00Z",
        "harness",
        "harness-rule",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        parsed.value,
    );
    defer std.testing.allocator.free(note);
    try std.testing.expect(std.mem.indexOf(
        u8,
        note,
        "\"schema\":\"memory-source-note/v1\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "\"extension\":\"harness\"") != null);
}

test "doctor path diagnostic reports symlink component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try tmp.dir.createDir(std.testing.io, "real", .default_dir);
    try tmp.dir.symLink(std.testing.io, "real", "link", .{ .is_directory = true });
    const checked_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "link", "harness", "notes" },
    );
    defer std.testing.allocator.free(checked_path);
    const offending = try std.fs.path.join(std.testing.allocator, &.{ root, "link" });
    defer std.testing.allocator.free(offending);

    var diagnostic = try doctorPathDiagnosticAlloc(
        Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        checked_path,
        error.SymlinkComponent,
    );
    defer diagnostic.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(checked_path, diagnostic.checked_path);
    try std.testing.expectEqualStrings("symlink", diagnostic.component_kind);
    try std.testing.expect(diagnostic.offending_component != null);
    try std.testing.expectEqualStrings(offending, diagnostic.offending_component.?);
}

test "doctor path diagnostic reports not-dir component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "payload" });
    const checked_path = try std.fs.path.join(std.testing.allocator, &.{ root, "file", "notes" });
    defer std.testing.allocator.free(checked_path);
    const offending = try std.fs.path.join(std.testing.allocator, &.{ root, "file" });
    defer std.testing.allocator.free(offending);

    var diagnostic = try doctorPathDiagnosticAlloc(
        Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        checked_path,
        error.NotDir,
    );
    defer diagnostic.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(checked_path, diagnostic.checked_path);
    try std.testing.expectEqualStrings("not_dir", diagnostic.component_kind);
    try std.testing.expect(diagnostic.offending_component != null);
    try std.testing.expectEqualStrings(offending, diagnostic.offending_component.?);
}

test "doctor failure json includes path diagnostic fields" {
    const checked_path = "/tmp/codex/memories/extensions/harness/notes";
    const offending_component = "/tmp/codex/memories/extensions";
    var diagnostic = DoctorPathDiagnostic{
        .checked_path = checked_path,
        .offending_component = try std.testing.allocator.dupe(u8, offending_component),
        .component_kind = "symlink",
    };
    defer diagnostic.deinit(std.testing.allocator);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"extension\":\"harness\"");
    try writeDoctorFailureJson(w, error.SymlinkComponent, diagnostic);
    const payload = try out.toOwnedSlice();
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"issue\":\"SymlinkComponent\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        payload,
        "\"checked_path\":\"/tmp/codex/memories/extensions/harness/notes\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        payload,
        "\"offending_component\":\"/tmp/codex/memories/extensions\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"component_kind\":\"symlink\"") != null);
}

fn nestedJsonAlloc(allocator: std.mem.Allocator, depth: usize, leaf: []const u8) ![]u8 {
    std.debug.assert(depth <= (MaxInputBytes - leaf.len) / 2);
    const raw = try allocator.alloc(u8, depth * 2 + leaf.len);
    @memset(raw[0..depth], '[');
    @memcpy(raw[depth..][0..leaf.len], leaf);
    @memset(raw[depth + leaf.len ..], ']');
    return raw;
}

test "sensitive-key traversal handles deep arrays and preserves case-insensitive rejection" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { leaf: []const u8, sensitive: bool }{
        .{ .leaf = "null", .sensitive = false },
        .{ .leaf = "{\"safe\":[1,2],\"CLIENT_SECRET\":\"x\"}", .sensitive = true },
    };
    for (cases) |case| {
        const raw = try nestedJsonAlloc(allocator, 8192, case.leaf);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        if (case.sensitive) {
            try std.testing.expectError(
                error.SensitiveKey,
                rejectSensitiveKeys(allocator, parsed.value),
            );
        } else {
            try rejectSensitiveKeys(allocator, parsed.value);
        }
    }
}

fn scanSensitiveWithAllocator(allocator: std.mem.Allocator, value: std.json.Value) !void {
    rejectSensitiveKeys(allocator, value) catch |err| {
        if (err == error.SensitiveKey) return;
        return err;
    };
    return error.MissingSensitiveKey;
}

test "sensitive-key traversal releases every frame allocation on failure" {
    const allocator = std.testing.allocator;
    const raw = try nestedJsonAlloc(allocator, 64, "{\"secret\":\"x\"}");
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    try @import("test_support").checkAllAllocationFailures(
        allocator,
        scanSensitiveWithAllocator,
        .{parsed.value},
    );
}

const LookupNoteFixture =
    "{\"id\":\"same\",\"captured_at\":\"2026-09-07T00:00:00Z\"," ++
    "\"extension\":\"harness\",\"kind\":\"harness-rule\",\"operation\":\"assert\"," ++
    "\"summary\":\"test\",\"fingerprint\":\"fixture-fingerprint\"}";

fn lookupFingerprintWithAllocator(
    allocator: std.mem.Allocator,
    fs: Fs,
    notes_dir: []const u8,
) !void {
    const found = try findFingerprint(fs, allocator, notes_dir, "fixture-fingerprint") orelse
        return error.MissingFingerprint;
    defer allocator.free(found.id);
    defer allocator.free(found.path);
    try std.testing.expectEqualStrings("same", found.id);
}

test "fingerprint lookup propagates allocation failure without losing the duplicate" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one.json", .data = LookupNoteFixture });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    try @import("test_support").checkAllAllocationFailures(
        allocator,
        lookupFingerprintWithAllocator,
        .{ Fs.init(std.testing.io, .cwd()), path },
    );
}

test "show releases a retained matching note when a later duplicate is rejected" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const notes_path = "memories/extensions/harness/notes";
    try tmp.dir.createDirPath(std.testing.io, notes_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = notes_path ++ "/one.json",
        .data = LookupNoteFixture,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = notes_path ++ "/two.json",
        .data = LookupNoteFixture,
    });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.testing.expectError(error.DuplicateId, cmdShow(Fs.init(
        std.testing.io,
        .cwd(),
    ), allocator, &output.writer, home, .{
        .command = .show,
        .codex_home = home,
        .memory_version = .v1,
        .extension = "harness",
        .id = "same",
    }));
}

test {
    _ = memory_migrate;
    _ = memory_inventory;
}

test "allocation-free envelope admission matches rendered byte boundaries" {
    const allocator = std.testing.allocator;
    var input = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        EnvelopeInputFixture,
        .{},
    );
    defer input.deinit();
    const summary = input.value.object.getPtr("summary").?;
    summary.* = .{ .string = "" };
    const id = "MSN-20261011T000000Z-0123456789abcdef";
    const now = "2026-10-11T00:00:00Z";
    const fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const empty = try renderEnvelopeAlloc(
        allocator,
        id,
        now,
        "harness",
        "harness-rule",
        fingerprint,
        input.value,
    );
    defer allocator.free(empty);
    for ([_]usize{ MaxNoteBytes - 1, MaxNoteBytes, MaxNoteBytes + 1 }) |size| {
        const text = try allocator.alloc(u8, size - empty.len);
        defer allocator.free(text);
        @memset(text, 'x');
        summary.* = .{ .string = text };
        const note = try renderEnvelopeAlloc(
            allocator,
            id,
            now,
            "harness",
            "harness-rule",
            fingerprint,
            input.value,
        );
        defer allocator.free(note);
        try std.testing.expectEqual(size, note.len);
        const admission = validateEnvelopeSize(
            now,
            "harness",
            "harness-rule",
            fingerprint,
            input.value,
        );
        if (size <= MaxNoteBytes) {
            try admission;
        } else {
            try std.testing.expectError(error.OutputTooLarge, admission);
        }
    }
}

test "input reads use independent supplied directories and propagate canceled I/O" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var left = std.testing.tmpDir(.{});
    defer left.cleanup();
    var right = std.testing.tmpDir(.{});
    defer right.cleanup();
    try left.dir.writeFile(io, .{ .sub_path = "input.json", .data = "left" });
    try right.dir.writeFile(io, .{ .sub_path = "input.json", .data = "right" });
    const left_bytes = try readJsonInput(Fs.init(io, left.dir), .stdin(), allocator, "input.json");
    defer allocator.free(left_bytes);
    const right_bytes = try readJsonInput(
        Fs.init(io, right.dir),
        .stdin(),
        allocator,
        "input.json",
    );
    defer allocator.free(right_bytes);
    try std.testing.expectEqualStrings("left", left_bytes);
    try std.testing.expectEqualStrings("right", right_bytes);
    var vtable = io.vtable.*;
    vtable.dirOpenFile = struct {
        fn open(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.OpenFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            return error.Canceled;
        }
    }.open;
    const canceled = Fs.init(.{ .userdata = io.userdata, .vtable = &vtable }, left.dir);
    try std.testing.expectError(
        error.Canceled,
        readJsonInput(canceled, .stdin(), allocator, "input.json"),
    );
}

test "help rendering propagates writer failure without terminating the host" {
    var writer = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(
        error.WriteFailed,
        handleHelpAndVersion(std.testing.allocator, &writer, &.{"memory-note"}),
    );
}

test "home selection remains explicit override then Codex home then user home" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/user/home");
    try env.put("CODEX_HOME", "/codex/home");
    const explicit = try codexHomeAlloc(allocator, &env, "/selected/home");
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("/selected/home", explicit);
    const codex = try codexHomeAlloc(allocator, &env, null);
    defer allocator.free(codex);
    try std.testing.expectEqualStrings("/codex/home", codex);
    try std.testing.expect(env.swapRemove("CODEX_HOME"));
    const user = try codexHomeAlloc(allocator, &env, null);
    defer allocator.free(user);
    try std.testing.expectEqualStrings("/user/home/.codex", user);
}
