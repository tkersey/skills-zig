const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;
const Version = core_cli.normalizeVersion(app_meta.version);

const MaxInputBytes = 1024 * 1024;
const MaxNoteBytes = 1024 * 1024;
const MaxFiles = 10_000;

const HelpText =
    \\memory-note
    \\
    \\Safe append-only custom memory-source note writer.
    \\
    \\usage: memory-note {append,list,show,doctor,path,version} [options]
    \\
    \\commands:
    \\  append   Append one typed note from --json FILE|-
    \\  list     List notes for an extension
    \\  show     Show one note by --id
    \\  doctor   Validate controlled memory-source layout
    \\  path     Print the notes directory for an extension
    \\  version  Show version
    \\
    \\options:
    \\  --extension NAME       harness|learnings|negative-ledger|synesthesia
    \\  --kind KIND            Extension-specific note kind
    \\  --json FILE|-          Append input JSON
    \\  --id NOTE-ID           Note id for show
    \\  --codex-home PATH      Override CODEX_HOME
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

const Command = enum { append, list, show, doctor, path, version };

const Args = struct {
    command: Command,
    extension: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    id: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
    dry_run: bool = false,
    limit: usize = 100,
    format: []const u8 = "json",
};

const SourceRef = struct {
    kind: []const u8,
    ref: []const u8,
    summary: []const u8,
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

    const code = run(allocator, init.environ_map, args) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(Io.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("memory-note: {s}\n", .{@errorName(err)});
        std.process.exit(exitCodeForError(err));
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
        try writeVersion(allocator);
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

fn writeVersion(allocator: std.mem.Allocator) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try core_cli.printVersion(&out.writer, Version);
    try writeStdoutAlloc(allocator, &out);
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
    if (std.mem.eql(u8, raw, "version")) return .version;
    return null;
}

fn run(allocator: std.mem.Allocator, env: *std.process.Environ.Map, args: Args) !u8 {
    return switch (args.command) {
        .append => try cmdAppend(allocator, env, args),
        .list => try cmdList(allocator, env, args),
        .show => try cmdShow(allocator, env, args),
        .doctor => try cmdDoctor(allocator, env, args),
        .path => try cmdPath(allocator, env, args),
        .version => {
            try writeVersion(allocator);
            return 0;
        },
    };
}

fn cmdAppend(allocator: std.mem.Allocator, env: *std.process.Environ.Map, args: Args) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    const kind = args.kind orelse return error.MissingKind;
    const json_path = args.json_path orelse return error.MissingJson;
    try validateExtensionKind(extension, kind);

    const input = try readJsonInput(allocator, json_path);
    defer allocator.free(input);
    if (input.len > MaxInputBytes) return error.InputTooLarge;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidJson,
    };
    try validateCommon(root);
    try validatePayload(extension, kind, root);
    try rejectSensitiveKeys(parsed.value);

    const fingerprint = try fingerprintInputAlloc(allocator, extension, kind, input);
    defer allocator.free(fingerprint);
    const fp16 = fingerprint[0..16];
    const now = try nowUtcAlloc(allocator);
    defer allocator.free(now);
    const id = try noteIdAlloc(allocator, now, fp16);
    defer allocator.free(id);
    const slug = try slugAlloc(allocator, root.get("slug"), root.get("summary"));
    defer allocator.free(slug);
    const filename = try filenameAlloc(allocator, now, kind, slug, fp16);
    defer allocator.free(filename);
    const note = try renderEnvelopeAlloc(allocator, id, now, extension, kind, fingerprint, parsed.value);
    defer allocator.free(note);
    if (note.len > MaxNoteBytes) return error.OutputTooLarge;

    const notes_dir = try notesDirAlloc(allocator, env, args.codex_home, extension);
    defer allocator.free(notes_dir);
    const dest_path = try std.fs.path.join(allocator, &.{ notes_dir, filename });
    defer allocator.free(dest_path);

    const lock_path = try memoryNoteLockPathAlloc(allocator, env, args.codex_home, extension);
    defer allocator.free(lock_path);
    var lock = try durable_store.acquireAbsoluteExclusiveLock(allocator, lock_path);
    defer lock.release(allocator);

    if (try findFingerprint(allocator, notes_dir, fingerprint)) |existing| {
        defer allocator.free(existing.id);
        defer allocator.free(existing.path);
        try writeDuplicateSkip(allocator, extension, kind, existing.id, fingerprint, existing.path);
        return 0;
    }

    if (args.dry_run) {
        try writeDryRun(allocator, id, extension, kind, fingerprint, dest_path, note);
        return 0;
    }

    try durable_store.writeTextCreateNew(allocator, dest_path, note, .{});
    try writeCreated(allocator, id, extension, kind, fingerprint, dest_path);
    return 0;
}

fn cmdList(allocator: std.mem.Allocator, env: *std.process.Environ.Map, args: Args) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    try validateExtension(extension);
    const notes_dir = try notesDirAlloc(allocator, env, args.codex_home, extension);
    defer allocator.free(notes_dir);
    const names = durable_store.listSortedRegularFilesNoSymlink(allocator, notes_dir, MaxFiles, MaxNoteBytes) catch |err| switch (err) {
        error.FileNotFound => &[_][]u8{},
        else => return err,
    };
    defer durable_store.freeStringList(allocator, names);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("{{\"extension\":", .{});
    try writeJsonString(w, extension);
    try w.writeAll(",\"notes\":[");
    var emitted: usize = 0;
    var idx = names.len;
    while (idx > 0 and emitted < args.limit) {
        idx -= 1;
        const path = try std.fs.path.join(allocator, &.{ notes_dir, names[idx] });
        defer allocator.free(path);
        const raw = try durable_store.readRegularFileNoSymlink(allocator, path, MaxNoteBytes);
        defer allocator.free(raw);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch continue;
        defer parsed.deinit();
        const note = parseNoteSummary(parsed.value) catch continue;
        if (args.kind) |wanted| {
            if (!std.mem.eql(u8, note.kind, wanted)) continue;
        }
        if (emitted > 0) try w.writeByte(',');
        try writeNoteSummaryJson(w, note, path);
        emitted += 1;
    }
    try w.writeAll("],\"truncated\":");
    try w.writeAll(if (names.len > emitted) "true" else "false");
    try w.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn cmdShow(allocator: std.mem.Allocator, env: *std.process.Environ.Map, args: Args) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    const id = args.id orelse return error.MissingId;
    try validateExtension(extension);
    const notes_dir = try notesDirAlloc(allocator, env, args.codex_home, extension);
    defer allocator.free(notes_dir);
    const names = try durable_store.listSortedRegularFilesNoSymlink(allocator, notes_dir, MaxFiles, MaxNoteBytes);
    defer durable_store.freeStringList(allocator, names);

    var found: ?[]u8 = null;
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ notes_dir, name });
        defer allocator.free(path);
        const raw = try durable_store.readRegularFileNoSymlink(allocator, path, MaxNoteBytes);
        defer allocator.free(raw);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch continue;
        defer parsed.deinit();
        const note = parseNoteSummary(parsed.value) catch continue;
        if (std.mem.eql(u8, note.id, id)) {
            if (found != null) return error.DuplicateId;
            found = try allocator.dupe(u8, raw);
        }
    }
    const payload = found orelse return error.NotFound;
    defer allocator.free(payload);
    if (std.mem.eql(u8, args.format, "raw") or std.mem.eql(u8, args.format, "json")) {
        try writeStdoutBytes(payload);
        try writeStdoutBytes("\n");
        return 0;
    }
    return error.InvalidFormat;
}

fn cmdDoctor(allocator: std.mem.Allocator, env: *std.process.Environ.Map, args: Args) !u8 {
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
        const notes_dir = try notesDirAlloc(allocator, env, args.codex_home, extension);
        defer allocator.free(notes_dir);
        durable_store.ensureDirectoryPathNoSymlinks(notes_dir) catch |err| {
            issues += 1;
            try w.print(",\"status\":\"failed\",\"issue\":", .{});
            try writeJsonString(w, @errorName(err));
            try w.writeByte('}');
            continue;
        };
        const names = try durable_store.listSortedRegularFilesNoSymlink(allocator, notes_dir, MaxFiles, MaxNoteBytes);
        defer durable_store.freeStringList(allocator, names);
        for (names) |name| {
            const path = try std.fs.path.join(allocator, &.{ notes_dir, name });
            defer allocator.free(path);
            const raw = try durable_store.readRegularFileNoSymlink(allocator, path, MaxNoteBytes);
            defer allocator.free(raw);
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
                issues += 1;
                continue;
            };
            defer parsed.deinit();
            const note = parseNoteSummary(parsed.value) catch {
                issues += 1;
                continue;
            };
            if (!std.mem.eql(u8, note.extension, extension)) issues += 1;
            checked += 1;
        }
        try w.print(",\"status\":\"ok\",\"notes\":{d}}}", .{names.len});
    }
    try w.print("],\"checked\":{d},\"issues\":{d}}}\n", .{ checked, issues });
    try writeStdoutAlloc(allocator, &out);
    return if (issues == 0) 0 else 8;
}

fn cmdPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map, args: Args) !u8 {
    const extension = args.extension orelse return error.MissingExtension;
    try validateExtension(extension);
    const notes_dir = try notesDirAlloc(allocator, env, args.codex_home, extension);
    defer allocator.free(notes_dir);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{s}\n", .{notes_dir});
    try writeStdoutAlloc(allocator, &out);
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
        if (oneOf(kind, &.{ "harness-rule", "harness-confirmation", "harness-supersession", "harness-retraction" })) return;
    } else if (std.mem.eql(u8, extension, "learnings")) {
        if (oneOf(kind, &.{ "learning-admission", "learning-confirmation", "learning-supersession", "learning-withdrawal" })) return;
    } else if (std.mem.eql(u8, extension, "negative-ledger")) {
        if (oneOf(kind, &.{ "ledger-projection", "ledger-status-transition", "ledger-supersession", "ledger-retraction" })) return;
    } else if (std.mem.eql(u8, extension, "synesthesia")) {
        if (oneOf(kind, &.{ "mapping-endorsement", "mapping-correction", "mapping-rejection", "activation-boundary", "boundary-retraction" })) return;
    }
    return error.InvalidKind;
}

fn oneOf(value: []const u8, comptime values: []const []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn validateCommon(root: std.json.ObjectMap) !void {
    _ = stringField(root, "operation") orelse return error.InvalidJson;
    _ = stringField(root, "authority") orelse return error.InvalidJson;
    _ = stringField(root, "summary") orelse return error.InvalidJson;
    if (root.get("scope") == null) return error.InvalidJson;
    const source_refs = root.get("source_refs") orelse return error.InvalidJson;
    if (source_refs != .array or source_refs.array.items.len == 0) return error.InvalidJson;
    const payload = root.get("payload") orelse return error.InvalidJson;
    if (payload != .object or payload.object.count() == 0) return error.InvalidJson;
}

fn validatePayload(extension: []const u8, kind: []const u8, root: std.json.ObjectMap) !void {
    const payload_value = root.get("payload") orelse return error.InvalidJson;
    const payload = switch (payload_value) {
        .object => |value| value,
        else => return error.InvalidJson,
    };
    if (std.mem.eql(u8, extension, "harness") and std.mem.eql(u8, kind, "harness-rule")) {
        try requirePayloadStrings(payload, &.{ "harness_rule", "trigger", "preferred_behavior", "failure_avoided", "verification_cue" });
        if (payload.get("evidence_count") == null) return error.InvalidPayload;
    } else if (std.mem.eql(u8, extension, "learnings") and std.mem.eql(u8, kind, "learning-admission")) {
        try requirePayloadStrings(payload, &.{ "learning_id", "learning_status", "repo", "source_path", "decision_delta", "future_behavior", "verification" });
        if (payload.get("evidence_snapshot") == null) return error.InvalidPayload;
    } else if (std.mem.eql(u8, extension, "negative-ledger") and std.mem.eql(u8, kind, "ledger-projection")) {
        try requirePayloadStrings(payload, &.{ "neg_id", "record_version", "ledger_path", "projection_fingerprint", "status", "kind", "artifact_state_id", "hypothesis", "attempted_change", "observed_outcome", "failure_class", "exclusion_scope", "confidence", "next_search_hint" });
    } else if (std.mem.eql(u8, extension, "synesthesia") and std.mem.startsWith(u8, kind, "mapping-")) {
        try requirePayloadStrings(payload, &.{ "sensory_phrase", "activation_boundary", "scope", "endorsement_type", "verification" });
        if (!std.mem.eql(u8, kind, "mapping-rejection")) _ = stringField(payload, "engineering_translation") orelse return error.InvalidPayload;
    }
}

fn requirePayloadStrings(payload: std.json.ObjectMap, comptime fields: []const []const u8) !void {
    for (fields) |field| {
        _ = stringField(payload, field) orelse return error.InvalidPayload;
    }
}

fn rejectSensitiveKeys(value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            var iter = object.iterator();
            while (iter.next()) |entry| {
                if (isSensitiveKey(entry.key_ptr.*)) return error.SensitiveKey;
                try rejectSensitiveKeys(entry.value_ptr.*);
            }
        },
        .array => |array| for (array.items) |item| try rejectSensitiveKeys(item),
        else => {},
    }
}

fn isSensitiveKey(key: []const u8) bool {
    return oneOfAsciiLower(key, &.{ "password", "passwd", "secret", "api_key", "apikey", "access_token", "refresh_token", "private_key", "client_secret" });
}

fn oneOfAsciiLower(value: []const u8, comptime values: []const []const u8) bool {
    for (values) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    return false;
}

fn readJsonInput(allocator: std.mem.Allocator, json_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, json_path, "-")) {
        var reader = std.Io.File.stdin().reader(Io.io(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes + 1));
    }
    return durable_store.readFileAlloc(allocator, json_path, MaxInputBytes + 1);
}

fn codexHomeAlloc(allocator: std.mem.Allocator, env: *std.process.Environ.Map, override: ?[]const u8) ![]u8 {
    if (override) |path| return allocator.dupe(u8, path);
    if (env.get("CODEX_HOME")) |path| return allocator.dupe(u8, path);
    if (env.get("HOME")) |home| return std.fs.path.join(allocator, &.{ home, ".codex" });
    return error.MissingCodexHome;
}

fn notesDirAlloc(allocator: std.mem.Allocator, env: *std.process.Environ.Map, override: ?[]const u8, extension: []const u8) ![]u8 {
    const home = try codexHomeAlloc(allocator, env, override);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "memories", "extensions", extension, "notes" });
}

fn memoryNoteLockPathAlloc(allocator: std.mem.Allocator, env: *std.process.Environ.Map, override: ?[]const u8, extension: []const u8) ![]u8 {
    const home = try codexHomeAlloc(allocator, env, override);
    defer allocator.free(home);
    const lock_name = try std.fmt.allocPrint(allocator, "{s}.lock", .{extension});
    defer allocator.free(lock_name);
    return std.fs.path.join(allocator, &.{ home, ".memory-note", "locks", lock_name });
}

fn fingerprintInputAlloc(allocator: std.mem.Allocator, extension: []const u8, kind: []const u8, input: []const u8) ![]u8 {
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
    return std.fmt.allocPrint(allocator, "MSN-{s}{s}{s}T{s}{s}{s}Z-{s}", .{ iso[0..4], iso[5..7], iso[8..10], iso[11..13], iso[14..16], iso[17..19], fp16 });
}

fn filenameAlloc(allocator: std.mem.Allocator, iso: []const u8, kind: []const u8, slug: []const u8, fp16: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}T{s}-{s}-{s}-{s}-{s}-{s}.md", .{ iso[0..4], iso[5..7], iso[8..10], iso[11..13], iso[14..16], iso[17..19], kind, if (slug.len > 0) slug else "note", fp16 });
}

fn slugAlloc(allocator: std.mem.Allocator, slug_value: ?std.json.Value, summary_value: ?std.json.Value) ![]u8 {
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

fn renderEnvelopeAlloc(allocator: std.mem.Allocator, id: []const u8, captured_at: []const u8, extension: []const u8, kind: []const u8, fingerprint: []const u8, input: std.json.Value) ![]u8 {
    const root = input.object;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
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
    if (root.get("related_ids")) |v| try std.json.Stringify.value(v, .{}, w) else try w.writeAll("[]");
    try w.writeAll(",\"supersedes_id\":");
    if (root.get("supersedes_id")) |v| try std.json.Stringify.value(v, .{}, w) else try w.writeAll("null");
    try w.writeAll(",\"fingerprint\":");
    try writeJsonString(w, fingerprint);
    try copyField(w, root, "payload");
    try w.writeAll("}\n");
    return out.toOwnedSlice();
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

fn findFingerprint(allocator: std.mem.Allocator, notes_dir: []const u8, fingerprint: []const u8) !?ExistingFingerprint {
    const names = durable_store.listSortedRegularFilesNoSymlink(allocator, notes_dir, MaxFiles, MaxNoteBytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer durable_store.freeStringList(allocator, names);
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ notes_dir, name });
        defer allocator.free(path);
        const raw = durable_store.readRegularFileNoSymlink(allocator, path, MaxNoteBytes) catch continue;
        defer allocator.free(raw);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch continue;
        defer parsed.deinit();
        const note = parseNoteSummary(parsed.value) catch continue;
        if (std.mem.eql(u8, note.fingerprint, fingerprint)) {
            return .{ .id = try allocator.dupe(u8, note.id), .path = try allocator.dupe(u8, path) };
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

fn writeCreated(allocator: std.mem.Allocator, id: []const u8, extension: []const u8, kind: []const u8, fingerprint: []const u8, path: []const u8) !void {
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
    try writeStdoutAlloc(allocator, &out);
}

fn writeDuplicateSkip(allocator: std.mem.Allocator, extension: []const u8, kind: []const u8, id: []const u8, fingerprint: []const u8, path: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"command\":\"append\",\"status\":\"duplicate_skip\",\"id\":");
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
    try writeStdoutAlloc(allocator, &out);
}

fn writeDryRun(allocator: std.mem.Allocator, id: []const u8, extension: []const u8, kind: []const u8, fingerprint: []const u8, path: []const u8, note: []const u8) !void {
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
    try writeStdoutAlloc(allocator, &out);
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

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, w);
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const payload = try out.toOwnedSlice();
    defer allocator.free(payload);
    try writeStdoutBytes(payload);
}

fn writeStdoutBytes(bytes: []const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(Io.io(), &.{});
    try stdout_writer.interface.writeAll(bytes);
}

fn exitCodeForError(err: anyerror) u8 {
    return switch (err) {
        error.UnknownCommand, error.UnknownOption, error.MissingCommand, error.MissingValue, error.MissingExtension, error.MissingKind, error.MissingJson, error.MissingId => 2,
        error.InvalidJson => 3,
        error.InvalidExtension, error.InvalidKind, error.InvalidPayload, error.SensitiveKey => 4,
        error.SymlinkComponent, error.NotDir, error.NotFile, error.InvalidPath => 5,
        error.PathAlreadyExists, error.DuplicateId => 6,
        error.FileNotFound, error.NotFound, error.InputTooLarge, error.OutputTooLarge, error.FileTooBig, error.TooManyFiles => 7,
        else => 9,
    };
}

fn nowUtcAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now_sec: i64 = @intCast(@divFloor(std.Io.Clock.real.now(Io.io()).nanoseconds, 1_000_000_000));
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

test "validates extension kind matrix" {
    try validateExtensionKind("harness", "harness-rule");
    try std.testing.expectError(error.InvalidExtension, validateExtensionKind("ad_hoc", "harness-rule"));
    try std.testing.expectError(error.InvalidKind, validateExtensionKind("harness", "ledger-projection"));
}

test "rejects sensitive keys recursively" {
    const raw = "{\"payload\":{\"nested\":{\"api_key\":\"x\"}}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.SensitiveKey, rejectSensitiveKeys(parsed.value));
}

test "renders envelope with generated fields" {
    const raw =
        \\{"operation":"assert","authority":"explicit-user-correction","summary":"Proceed.","scope":{"kind":"global","repo":null,"paths":[]},"source_refs":[{"kind":"user","ref":"r","summary":"s"}],"payload":{"harness_rule":"r","trigger":"t","preferred_behavior":"p","failure_avoided":"f","verification_cue":"v","evidence_count":1}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    try validateCommon(parsed.value.object);
    try validatePayload("harness", "harness-rule", parsed.value.object);
    const note = try renderEnvelopeAlloc(std.testing.allocator, "MSN-20260620T183000Z-0123456789abcdef", "2026-06-20T18:30:00Z", "harness", "harness-rule", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", parsed.value);
    defer std.testing.allocator.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "\"schema\":\"memory-source-note/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "\"extension\":\"harness\"") != null);
}
