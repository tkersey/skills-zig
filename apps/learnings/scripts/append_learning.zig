const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "append_learning";
const UsageLine =
    "usage: append_learning [-h] [--status STATUS] --learning LEARNING [--evidence EVIDENCE] [--application APPLICATION] [--tag TAG] [--related-id RELATED_ID] [--supersedes-id SUPERSEDES_ID] [--repo REPO] [--path PATH] [--source SOURCE] [--allow-duplicate] [--quality-mode {strict,best_effort}] [--allow-temp-path]";
const HelpText =
    \\append_learning.zig
    \\
    \\Marker: append_learning.zig
    \\
    \\usage: append_learning [-h] [--status STATUS] --learning LEARNING [--evidence EVIDENCE] [--application APPLICATION] [--tag TAG] [--related-id RELATED_ID] [--supersedes-id SUPERSEDES_ID] [--repo REPO] [--path PATH] [--source SOURCE] [--allow-duplicate] [--quality-mode {strict,best_effort}] [--allow-temp-path]
    \\
    \\Append a structured learning record to repo-root .learnings.jsonl.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --status STATUS       Action status (for example: do_more, do_less); defaults to review_later
    \\  --learning LEARNING   Learning statement
    \\  --evidence EVIDENCE   Evidence item (repeat for multiple lines); optional in best-effort mode
    \\  --application APPLICATION
    \\                        How to apply this learning; optional in best-effort mode
    \\  --tag TAG             Tag (repeatable; comma-separated ok), for example: tooling, git, ci
    \\  --related-id RELATED_ID
    \\                        Related learning id (repeatable; comma-separated ok)
    \\  --supersedes-id SUPERSEDES_ID
    \\                        If this learning supersedes an older record id
    \\  --repo REPO           Repo identifier override (defaults to remote origin slug or repo dir name)
    \\  --path PATH           Path to JSONL file, relative to repo root by default
    \\  --source SOURCE       Source marker for the record
    \\  --allow-duplicate     Append even if an existing record has the same fingerprint
    \\  --quality-mode {strict,best_effort}
    \\                        Record quality gate mode; strict rejects weak records, best_effort keeps legacy placeholder behavior.
    \\  --allow-temp-path     Allow capture when repo root is under temporary paths (/tmp or /var/folders).
    \\  -V, --version         Show version
    \\  version               Show version
;

const QualityMode = enum {
    best_effort,
    strict,
};

const TEMP_PATH_PREFIXES = [_][]const u8{
    "/tmp",
    "/tmp/",
    "/private/tmp",
    "/private/tmp/",
    "/var/folders/",
    "/private/var/folders/",
};

const PLACEHOLDER_VALUES = [_][]const u8{
    "none_provided",
    "capture_follow_up_later",
    "n/a",
    "na",
    "todo",
    "unknown",
    "tbd",
};

const CONDITION_TOKENS = [_][]const u8{ "when", "if", "for" };
const ACTION_TOKENS = [_][]const u8{
    "prefer",
    "use",
    "avoid",
    "set",
    "run",
    "keep",
    "add",
    "remove",
    "require",
    "enforce",
    "treat",
    "encode",
    "split",
    "move",
    "mirror",
    "pin",
    "gate",
};
const COUNTERFACTUAL_TOKENS = [_][]const u8{ "because", "prevent", "otherwise" };

const Options = struct {
    status: []const u8 = "review_later",
    learning: ?[]const u8 = null,
    evidence: std.ArrayListUnmanaged([]const u8) = .{},
    application: []const u8 = "",
    tags: std.ArrayListUnmanaged([]const u8) = .{},
    related_ids: std.ArrayListUnmanaged([]const u8) = .{},
    supersedes_id: []const u8 = "",
    repo: []const u8 = "",
    path: []const u8 = ".learnings.jsonl",
    source: []const u8 = "skill:learnings",
    allow_duplicate: bool = false,
    quality_mode: QualityMode = .strict,
    allow_temp_path: bool = false,

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.evidence.deinit(allocator);
        self.tags.deinit(allocator);
        self.related_ids.deinit(allocator);
    }
};

const Record = struct {
    id: []const u8,
    captured_at: []const u8,
    status: []const u8,
    learning: []const u8,
    evidence: []const []u8,
    application: []const u8,
    repo: []const u8,
    branch: []const u8,
    paths: []const []u8,
    source: []const u8,
    fingerprint: []const u8,
    tags: []const []u8,
    related_ids: []const []u8,
    supersedes_id: ?[]const u8,
};

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var opts = Options{};
    defer opts.deinit(allocator);

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (core_cli.isHelpArg(arg)) {
            var stdout_writer = std.fs.File.stdout().writer(&.{});
            const stdout = &stdout_writer.interface;
            try stdout.print("{s}\n", .{HelpText});
            return;
        }
        if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
            var stdout_writer = std.fs.File.stdout().writer(&.{});
            const stdout = &stdout_writer.interface;
            try core_cli.printVersion(stdout, Version);
            return;
        }
        if (std.mem.eql(u8, arg, "--allow-duplicate")) {
            opts.allow_duplicate = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-temp-path")) {
            opts.allow_temp_path = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quality-mode")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --quality-mode: expected one argument", .{});
            const mode = argv[i];
            if (std.mem.eql(u8, mode, "strict")) {
                opts.quality_mode = .strict;
            } else if (std.mem.eql(u8, mode, "best_effort")) {
                opts.quality_mode = .best_effort;
            } else {
                exitParseError("argument --quality-mode: expected one of strict,best_effort", .{});
            }
            continue;
        }

        if (std.mem.eql(u8, arg, "--status")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --status: expected one argument", .{});
            opts.status = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--learning")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --learning: expected one argument", .{});
            opts.learning = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--evidence")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --evidence: expected one argument", .{});
            opts.evidence.append(allocator, argv[i]) catch |err| return err;
            continue;
        }
        if (std.mem.eql(u8, arg, "--application")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --application: expected one argument", .{});
            opts.application = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--tag")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --tag: expected one argument", .{});
            opts.tags.append(allocator, argv[i]) catch |err| return err;
            continue;
        }
        if (std.mem.eql(u8, arg, "--related-id")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --related-id: expected one argument", .{});
            opts.related_ids.append(allocator, argv[i]) catch |err| return err;
            continue;
        }
        if (std.mem.eql(u8, arg, "--supersedes-id")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --supersedes-id: expected one argument", .{});
            opts.supersedes_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --repo: expected one argument", .{});
            opts.repo = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --path: expected one argument", .{});
            opts.path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= argv.len) exitParseError("argument --source: expected one argument", .{});
            opts.source = argv[i];
            continue;
        }

        exitParseError("unrecognized arguments: {s}", .{arg});
    }

    const learning_raw = opts.learning orelse {
        exitParseError("the following arguments are required: --learning", .{});
    };

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const repo_root = try discoverRepoRootAlloc(allocator, cwd);
    defer allocator.free(repo_root);

    var status = try normalizeStatusAlloc(allocator, opts.status);
    defer allocator.free(status);
    if (status.len == 0) {
        allocator.free(status);
        status = try allocator.dupe(u8, "review_later");
    }

    const learning = try normalizeLearningAlloc(allocator, learning_raw);
    defer allocator.free(learning);
    if (learning.len == 0) {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("error: learning is empty\n", .{});
        std.process.exit(1);
    }

    var evidence: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(allocator, &evidence);
    for (opts.evidence.items) |raw| {
        const normalized = try normalizeLearningAlloc(allocator, raw);
        if (normalized.len == 0) {
            allocator.free(normalized);
            continue;
        }
        try evidence.append(allocator, normalized);
    }
    if (opts.quality_mode == .best_effort and evidence.items.len == 0) {
        try evidence.append(allocator, try allocator.dupe(u8, "none_provided"));
    }

    var application = try normalizeLearningAlloc(allocator, opts.application);
    defer allocator.free(application);
    if (opts.quality_mode == .best_effort and application.len == 0) {
        allocator.free(application);
        application = try allocator.dupe(u8, "capture_follow_up_later");
    }

    if (opts.quality_mode == .strict) {
        const quality_ok = try validateQuality(
            allocator,
            status,
            learning,
            evidence.items,
            application,
            repo_root,
            opts.allow_temp_path,
        );
        if (!quality_ok) {
            std.process.exit(2);
        }
    }

    var tags: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(allocator, &tags);
    for (opts.tags.items) |raw| {
        var parts = std.mem.splitScalar(u8, raw, ',');
        while (parts.next()) |part| {
            const normalized = try normalizeTagAlloc(allocator, part);
            if (normalized.len == 0) {
                allocator.free(normalized);
                continue;
            }
            if (containsString(tags.items, normalized)) {
                allocator.free(normalized);
                continue;
            }
            try tags.append(allocator, normalized);
        }
    }

    var related_ids: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(allocator, &related_ids);
    for (opts.related_ids.items) |raw| {
        var parts = std.mem.splitScalar(u8, raw, ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (containsString(related_ids.items, trimmed)) continue;
            try related_ids.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    const supersedes_trimmed = std.mem.trim(u8, opts.supersedes_id, " \t\r\n");
    const supersedes_id = if (supersedes_trimmed.len == 0) null else try allocator.dupe(u8, supersedes_trimmed);
    defer if (supersedes_id) |value| allocator.free(value);

    const fp = try fingerprintAlloc(allocator, status, learning);
    defer allocator.free(fp);

    const timestamp = try nowUtcAlloc(allocator);
    defer allocator.free(timestamp);

    const record_id = try buildRecordIdAlloc(allocator, timestamp, fp);
    defer allocator.free(record_id);

    var branch = try runGitAlloc(allocator, repo_root, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    if (branch.len == 0) {
        allocator.free(branch);
        branch = try allocator.dupe(u8, "unknown");
    }
    defer allocator.free(branch);

    var context_paths = try changedPathsAlloc(allocator, repo_root);
    defer freeOwnedStrings(allocator, &context_paths);

    const repo_override = std.mem.trim(u8, opts.repo, " \t\r\n");
    const repo = if (repo_override.len == 0) try inferRepoSlugAlloc(allocator, repo_root) else try allocator.dupe(u8, repo_override);
    defer allocator.free(repo);

    const output_path = try resolveOutputPathAlloc(allocator, repo_root, opts.path);
    defer allocator.free(output_path);

    if (!opts.allow_duplicate) {
        const existing_id = try findDuplicateExistingIdAlloc(allocator, output_path, fp);
        if (existing_id) |id| {
            defer allocator.free(id);
            var stderr_writer = std.fs.File.stderr().writer(&.{});
            const stderr = &stderr_writer.interface;
            try stderr.print("duplicate-skip: fingerprint={s} existing_id={s} path={s}\n", .{ fp, id, output_path });
            return;
        }
    }

    const record = Record{
        .id = record_id,
        .captured_at = timestamp,
        .status = status,
        .learning = learning,
        .evidence = evidence.items,
        .application = application,
        .repo = repo,
        .branch = branch,
        .paths = context_paths.items,
        .source = opts.source,
        .fingerprint = fp,
        .tags = tags.items,
        .related_ids = related_ids.items,
        .supersedes_id = supersedes_id,
    };

    const line = try encodeRecordJsonAlloc(allocator, record);
    defer allocator.free(line);

    try appendJsonLine(output_path, line);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("appended: id={s} status={s} path={s}\n", .{ record_id, status, output_path });
}

fn exitParseError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("{s}\n", .{UsageLine});
    std.debug.print(ProgramName ++ ": error: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn isAsciiAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

fn toLowerAscii(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0b' or c == '\x0c';
}

fn normalizeStatusAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var prev_underscore = false;
    for (raw) |c| {
        if (isAsciiAlnum(c)) {
            try out.append(allocator, toLowerAscii(c));
            prev_underscore = false;
            continue;
        }
        if (out.items.len == 0 or prev_underscore) continue;
        try out.append(allocator, '_');
        prev_underscore = true;
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        _ = out.pop();
    }

    return out.toOwnedSlice(allocator);
}

fn normalizeLearningAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var pending_space = false;
    for (trimmed) |c| {
        if (isWhitespace(c)) {
            if (out.items.len > 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        try out.append(allocator, c);
    }

    return out.toOwnedSlice(allocator);
}

fn normalizeTagAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return normalizeStatusAlloc(allocator, raw);
}

fn validateQuality(
    allocator: std.mem.Allocator,
    status: []const u8,
    learning: []const u8,
    evidence: []const []u8,
    application: []const u8,
    repo_root: []const u8,
    allow_temp_path: bool,
) !bool {
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;

    var has_errors = false;

    if (isEphemeralPath(repo_root) and !allow_temp_path) {
        has_errors = true;
        try stderr.print(
            "quality-error: repo root is ephemeral: {s}. Use --allow-temp-path only when capture must be temporary.\n",
            .{repo_root},
        );
    }

    if (learning.len < 24) {
        has_errors = true;
        try stderr.print("quality-error: learning is too short; include a durable decision rule.\n", .{});
    }

    const learning_lower = try asciiLowerAlloc(allocator, learning);
    defer allocator.free(learning_lower);

    if (!hasConditionAction(learning_lower)) {
        has_errors = true;
        try stderr.print(
            "quality-error: learning must include explicit condition + action (for example: 'When X, prefer Y ...').\n",
            .{},
        );
    }

    if (!hasCounterfactual(learning_lower)) {
        try stderr.print(
            "quality-warning: learning lacks explicit consequence wording (because/to avoid/prevent/otherwise).\n",
            .{},
        );
    }

    if (evidence.len == 0) {
        has_errors = true;
        try stderr.print("quality-error: at least one --evidence value is required in strict mode.\n", .{});
    } else if (containsPlaceholderValue(evidence)) {
        has_errors = true;
        try stderr.print("quality-error: evidence contains placeholder text.\n", .{});
    } else if (!hasAnchoredEvidence(evidence)) {
        has_errors = true;
        try stderr.print(
            "quality-error: evidence needs at least one concrete anchor (command outcome, sha/run id, file path, or exact error).\n",
            .{},
        );
    }

    if (isPlaceholderValue(application)) {
        has_errors = true;
        try stderr.print("quality-error: application must be concrete in strict mode.\n", .{});
    }

    if (std.mem.eql(u8, status, "review_later")) {
        try stderr.print(
            "quality-warning: status=review_later used; ensure this uncertainty is itself decision-shaping.\n",
            .{},
        );
    }

    if (has_errors) {
        try stderr.print(
            "quality-error: use --quality-mode best_effort only for intentional exceptions.\n",
            .{},
        );
    }
    return !has_errors;
}

fn isEphemeralPath(path: []const u8) bool {
    for (TEMP_PATH_PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

fn containsPlaceholderValue(values: []const []const u8) bool {
    for (values) |value| {
        if (isPlaceholderValue(value)) return true;
    }
    return false;
}

fn isPlaceholderValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return true;
    for (PLACEHOLDER_VALUES) |placeholder| {
        if (std.ascii.eqlIgnoreCase(trimmed, placeholder)) return true;
    }
    return false;
}

fn hasConditionAction(learning_lower: []const u8) bool {
    var has_condition = false;
    for (CONDITION_TOKENS) |token| {
        if (containsWordLower(learning_lower, token)) {
            has_condition = true;
            break;
        }
    }
    if (!has_condition) return false;

    for (ACTION_TOKENS) |token| {
        if (containsWordLower(learning_lower, token)) return true;
    }
    return false;
}

fn hasCounterfactual(learning_lower: []const u8) bool {
    if (std.mem.indexOf(u8, learning_lower, "to avoid") != null) return true;
    for (COUNTERFACTUAL_TOKENS) |token| {
        if (containsWordLower(learning_lower, token)) return true;
    }
    return false;
}

fn containsWordLower(haystack: []const u8, needle: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |idx| {
        const before_ok = idx == 0 or !isAsciiAlnum(haystack[idx - 1]);
        const after_idx = idx + needle.len;
        const after_ok = after_idx >= haystack.len or !isAsciiAlnum(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        start = idx + 1;
    }
    return false;
}

fn hasAnchoredEvidence(evidence: []const []const u8) bool {
    for (evidence) |item| {
        if (hasEvidenceAnchor(item)) return true;
    }
    return false;
}

fn hasEvidenceAnchor(text: []const u8) bool {
    if (containsCaseInsensitive(text, "task_")) return true;
    if (containsCaseInsensitive(text, "passed")) return true;
    if (containsCaseInsensitive(text, "failed")) return true;
    if (containsCaseInsensitive(text, "error")) return true;
    if (containsCaseInsensitive(text, "exit ")) return true;
    if (containsCaseInsensitive(text, "exited ")) return true;

    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n,;:()[]{}<>\"'`");
    while (tokens.next()) |tok| {
        if (isHexishToken(tok)) return true;
        if (isFileLikeToken(tok)) return true;
        if (isRunNumberToken(tok)) return true;
    }
    return false;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

fn isHexishToken(token: []const u8) bool {
    if (token.len < 7 or token.len > 40) return false;
    for (token) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn isFileLikeToken(token: []const u8) bool {
    if (token.len < 3) return false;
    if (std.mem.startsWith(u8, token, "--")) return false;
    if (std.mem.indexOfScalar(u8, token, '.') == null) return false;
    return true;
}

fn isRunNumberToken(token: []const u8) bool {
    if (!std.mem.startsWith(u8, token, "run")) return false;
    if (token.len <= 3) return false;
    var idx: usize = 3;
    while (idx < token.len and (token[idx] == '_' or token[idx] == '-' or token[idx] == ':')) : (idx += 1) {}
    if (idx >= token.len) return false;
    var digits: usize = 0;
    while (idx < token.len and std.ascii.isDigit(token[idx])) : (idx += 1) {
        digits += 1;
    }
    return digits >= 6;
}

fn discoverRepoRootAlloc(allocator: std.mem.Allocator, start: []const u8) ![]u8 {
    const root = try runGitAlloc(allocator, start, &.{ "rev-parse", "--show-toplevel" });
    defer allocator.free(root);

    if (root.len == 0) return allocator.dupe(u8, start);

    return std.fs.realpathAlloc(allocator, root) catch allocator.dupe(u8, root);
}

fn inferRepoSlugAlloc(allocator: std.mem.Allocator, repo_root: []const u8) ![]u8 {
    const remote = try runGitAlloc(allocator, repo_root, &.{ "config", "--get", "remote.origin.url" });
    defer allocator.free(remote);

    const trimmed_remote = std.mem.trim(u8, remote, " \t\r\n");
    if (trimmed_remote.len == 0) return allocator.dupe(u8, std.fs.path.basename(repo_root));

    var path = trimmed_remote;
    if (std.mem.startsWith(u8, trimmed_remote, "git@")) {
        if (std.mem.indexOfScalar(u8, trimmed_remote, ':')) |idx| {
            path = trimmed_remote[idx + 1 ..];
        }
    } else if (std.mem.indexOf(u8, trimmed_remote, "://")) |scheme_idx| {
        const rest = trimmed_remote[scheme_idx + 3 ..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
            path = rest[slash_idx + 1 ..];
        } else {
            path = "";
        }
    } else if (std.mem.indexOfScalar(u8, trimmed_remote, ':')) |idx| {
        const tail = trimmed_remote[idx + 1 ..];
        if (std.mem.indexOfScalar(u8, tail, '/')) |_| {
            path = tail;
        }
    }

    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) {
        path = path[0 .. path.len - 4];
    }

    var prev: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        prev = last;
        last = part;
    }

    if (prev != null and last != null) {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prev.?, last.? });
    }

    return allocator.dupe(u8, std.fs.path.basename(repo_root));
}

fn appendUniquePathsFromLines(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
    lines_text: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, lines_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (containsString(paths.items, trimmed)) continue;
        try paths.append(allocator, try allocator.dupe(u8, trimmed));
    }
}

fn changedPathsAlloc(allocator: std.mem.Allocator, repo_root: []const u8) !std.ArrayList([]u8) {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedStrings(allocator, &paths);

    const staged = try runGitAlloc(allocator, repo_root, &.{ "diff", "--cached", "--name-only", "--relative" });
    defer allocator.free(staged);
    try appendUniquePathsFromLines(allocator, &paths, staged);

    const unstaged = try runGitAlloc(allocator, repo_root, &.{ "diff", "--name-only", "--relative" });
    defer allocator.free(unstaged);
    try appendUniquePathsFromLines(allocator, &paths, unstaged);

    return paths;
}

fn runGitAlloc(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return allocator.dupe(u8, "");

    const stdout_file = child.stdout orelse {
        _ = child.wait() catch {};
        return allocator.dupe(u8, "");
    };

    const raw_output = stdout_file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch {
        _ = child.wait() catch {};
        return allocator.dupe(u8, "");
    };
    errdefer allocator.free(raw_output);

    const term = child.wait() catch {
        allocator.free(raw_output);
        return allocator.dupe(u8, "");
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(raw_output);
                return allocator.dupe(u8, "");
            }
        },
        else => {
            allocator.free(raw_output);
            return allocator.dupe(u8, "");
        },
    }

    const trimmed = std.mem.trim(u8, raw_output, " \t\r\n");
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw_output);
    return out;
}

fn nowUtcAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now_sec: i64 = std.time.timestamp();
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

    const year: u32 = @intCast(date.year);
    const month: u32 = @intCast(date.month);
    const day: u32 = @intCast(date.day);
    const hour_u: u32 = @intCast(hour);
    const minute_u: u32 = @intCast(minute);
    const second_u: u32 = @intCast(second);

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ year, month, day, hour_u, minute_u, second_u },
    );
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

fn fingerprintAlloc(allocator: std.mem.Allocator, status: []const u8, learning: []const u8) ![]u8 {
    const lower_learning = try asciiLowerAlloc(allocator, learning);
    defer allocator.free(lower_learning);

    const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ status, lower_learning });
    defer allocator.free(key);

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(key, &digest, .{});

    const first8: [8]u8 = digest[0..8].*;
    const hex = std.fmt.bytesToHex(first8, .lower);
    return allocator.dupe(u8, hex[0..]);
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, idx| out[idx] = toLowerAscii(c);
    return out;
}

fn buildRecordIdAlloc(allocator: std.mem.Allocator, timestamp: []const u8, fingerprint: []const u8) ![]u8 {
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(allocator);

    for (timestamp) |c| {
        if (c == '-' or c == ':') continue;
        try compact.append(allocator, c);
    }

    return std.fmt.allocPrint(allocator, "lrn-{s}-{s}", .{ compact.items, fingerprint[0..8] });
}

fn resolveOutputPathAlloc(allocator: std.mem.Allocator, repo_root: []const u8, raw_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) return allocator.dupe(u8, raw_path);
    return std.fs.path.join(allocator, &.{ repo_root, raw_path });
}

fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trimLeft(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        try root.makePath(rel);
        return;
    }

    try std.fs.cwd().makePath(parent);
}

fn appendJsonLine(path: []const u8, json_line: []const u8) !void {
    try ensureParentPath(path);

    var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.createFileAbsolute(path, .{ .truncate = false }),
        else => return err,
    };
    defer file.close();

    try file.seekFromEnd(0);
    try file.writeAll(json_line);
    try file.writeAll("\n");
}

fn findDuplicateExistingIdAlloc(allocator: std.mem.Allocator, path: []const u8, fingerprint: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |value| value,
            else => continue,
        };

        const fp_value = obj.get("fingerprint") orelse continue;
        const fp_text = switch (fp_value) {
            .string => |value| value,
            else => continue,
        };

        if (!std.mem.eql(u8, fp_text, fingerprint)) continue;

        if (obj.get("id")) |id_value| {
            const id_text = switch (id_value) {
                .string => |value| value,
                else => "unknown",
            };
            return try allocator.dupe(u8, id_text);
        }

        return try allocator.dupe(u8, "unknown");
    }

    return null;
}

fn encodeRecordJsonAlloc(allocator: std.mem.Allocator, record: Record) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const writer = out.writer(allocator);

    try writer.writeByte('{');
    var first = true;

    try writeFieldString(writer, &first, "id", record.id);
    try writeFieldString(writer, &first, "captured_at", record.captured_at);
    try writeFieldString(writer, &first, "status", record.status);
    try writeFieldString(writer, &first, "learning", record.learning);
    try writeFieldArray(writer, &first, "evidence", record.evidence);
    try writeFieldString(writer, &first, "application", record.application);

    try writeObjectKey(writer, &first, "context");
    try writer.writeByte('{');
    var context_first = true;
    try writeFieldString(writer, &context_first, "repo", record.repo);
    try writeFieldString(writer, &context_first, "branch", record.branch);
    try writeFieldArray(writer, &context_first, "paths", record.paths);
    try writer.writeByte('}');

    try writeFieldString(writer, &first, "source", record.source);
    try writeFieldString(writer, &first, "fingerprint", record.fingerprint);

    if (record.tags.len > 0) {
        try writeFieldArray(writer, &first, "tags", record.tags);
    }
    if (record.related_ids.len > 0) {
        try writeFieldArray(writer, &first, "related_ids", record.related_ids);
    }
    if (record.supersedes_id) |value| {
        try writeFieldString(writer, &first, "supersedes_id", value);
    }

    try writer.writeByte('}');
    return out.toOwnedSlice(allocator);
}

fn writeObjectKey(writer: anytype, first: *bool, key: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writeJsonStringAscii(writer, key);
    try writer.writeByte(':');
}

fn writeFieldString(writer: anytype, first: *bool, key: []const u8, value: []const u8) !void {
    try writeObjectKey(writer, first, key);
    try writeJsonStringAscii(writer, value);
}

fn writeFieldArray(writer: anytype, first: *bool, key: []const u8, items: anytype) !void {
    try writeObjectKey(writer, first, key);
    try writeStringArray(writer, items);
}

fn writeStringArray(writer: anytype, items: anytype) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonStringAscii(writer, item);
    }
    try writer.writeByte(']');
}

fn writeJsonStringAscii(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');

    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\x08' => try writer.writeAll("\\b"),
                '\x0c' => try writer.writeAll("\\f"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (byte < 0x20) {
                        try writer.print("\\u00{X:0>2}", .{byte});
                    } else {
                        try writer.writeByte(byte);
                    }
                },
            }
            i += 1;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.print("\\u00{X:0>2}", .{byte});
            i += 1;
            continue;
        };

        if (i + seq_len > text.len) {
            try writer.print("\\u00{X:0>2}", .{byte});
            i += 1;
            continue;
        }

        const codepoint = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            try writer.print("\\u00{X:0>2}", .{byte});
            i += 1;
            continue;
        };
        i += seq_len;

        if (codepoint <= 0xFFFF) {
            try writer.print("\\u{X:0>4}", .{codepoint});
            continue;
        }

        const scalar = codepoint - 0x1_0000;
        const high: u32 = 0xD800 + @as(u32, @intCast(scalar >> 10));
        const low: u32 = 0xDC00 + @as(u32, @intCast(scalar & 0x3FF));
        try writer.print("\\u{X:0>4}\\u{X:0>4}", .{ high, low });
    }

    try writer.writeByte('"');
}

fn containsString(items: []const []u8, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn freeOwnedStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

test "normalizeStatusAlloc canonicalizes mixed separators" {
    const status = try normalizeStatusAlloc(std.testing.allocator, "  Do More / ASAP  ");
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("do_more_asap", status);
}

test "condition-action and counterfactual detectors" {
    try std.testing.expect(hasConditionAction("when ci fails prefer rerun with logs"));
    try std.testing.expect(!hasConditionAction("this is an observation only"));

    try std.testing.expect(hasCounterfactual("prefer strict checks to avoid silent regressions"));
    try std.testing.expect(!hasCounterfactual("prefer strict checks for quality"));
}

test "evidence anchors detect run ids, paths, and status language" {
    try std.testing.expect(hasEvidenceAnchor("release run 22525295017 passed"));
    try std.testing.expect(hasEvidenceAnchor("see apps/mesh/scripts/mesh.zig"));
    try std.testing.expect(hasEvidenceAnchor("commit a1b2c3d4e5f6"));
    try std.testing.expect(!hasEvidenceAnchor("follow up later maybe"));
}

test "isEphemeralPath recognizes temporary roots" {
    try std.testing.expect(isEphemeralPath("/tmp/work/repo"));
    try std.testing.expect(isEphemeralPath("/private/var/folders/abc/repo"));
    try std.testing.expect(!isEphemeralPath("/Users/example/work/repo"));
}
