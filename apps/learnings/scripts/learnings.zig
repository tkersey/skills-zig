const std = @import("std");
const append_learning_cli = @import("append_learning_cli");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const app_meta = @import("app_meta");
const seq_bundle = @import("seq_bundle");
const query_engine = seq_bundle.query_engine;
const query_output = seq_bundle.query_output;
const query_spec = seq_bundle.query_spec;

const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "ledger --source learnings";
const LegacyLearningsPath = append_learning_cli.LegacyLearningsPath;
const PreviousLearningsPath = append_learning_cli.PreviousLearningsPath;
const DefaultLearningsPath = append_learning_cli.DefaultLearningsPath;
const MaxLearningsBytes = 64 * 1024 * 1024;
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger --source learnings",
    .help_text = UsageText,
};
const MigrateHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger migrate --source learnings",
    .help_text = MigrateUsageText,
};
const DatasetsHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger datasets --source learnings",
    .help_text = DatasetsUsageText,
};
const DatasetSchemaHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger dataset-schema --source learnings",
    .help_text = DatasetSchemaUsageText,
};
const QueryHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger query --source learnings",
    .help_text = QueryUsageText,
};
const RecentHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger recent --source learnings",
    .help_text = RecentUsageText,
};
const RecallHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger recall --source learnings",
    .help_text = RecallUsageText,
};
const ExportHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger export --source learnings",
    .help_text = ExportUsageText,
};
const CodifyCandidatesHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger codify-candidates --source learnings",
    .help_text = CodifyCandidatesUsageText,
};
const QualityAuditHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger quality-audit --source learnings",
    .help_text = QualityAuditUsageText,
};
const ValueReportHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger value-report --source learnings",
    .help_text = ValueReportUsageText,
};
const MemoryDigestHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger memory-digest --source learnings",
    .help_text = MemoryDigestUsageText,
};
const DoctorHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger doctor --source learnings",
    .help_text = DoctorUsageText,
};
const PathHelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger path --source learnings",
    .help_text = PathUsageText,
};

const UsageText =
    \\ledger --source learnings
    \\
    \\usage: ledger --source learnings [-h] [--path PATH] {capture,datasets,dataset-schema,query,recent,recall,export,codify-candidates,quality-audit,value-report,memory-digest,migrate,doctor,path} ...
    \\
    \\Mine, recall, and promote records through the repo-local learning-source API.
    \\
    \\positional arguments:
    \\  {capture,datasets,dataset-schema,query,recent,recall,export,codify-candidates,quality-audit,value-report,memory-digest,migrate,doctor,path}
    \\    capture             Append a structured learning event
    \\    datasets            List datasets
    \\    dataset-schema      Show dataset schema
    \\    query               Run a JSON spec query
    \\    recent              Show most recent learnings
    \\    recall              Rank relevant learnings for a task
    \\    export              Emit a full or memory-note projection for one learning
    \\    codify-candidates   Suggest repeated/high-impact learnings to promote into durable docs
    \\    quality-audit       Summarize learning capture quality and contract health
    \\    value-report        Compare recall-loaded sessions against a non-recall comparator
    \\    memory-digest       Generate a disposable cross-repo memory consolidation digest
    \\    migrate             Copy or move legacy learning rows into .ledger/learnings/events.jsonl
    \\    doctor              Validate the selected learnings store and report path status
    \\    path                Print the resolved default learnings path
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --path PATH           Current persistent-adapter path (relative to repo root by default)
    \\  -V, --version         Show version
    \\  version               Show version
;

const MigrateUsageText =
    \\ledger migrate --source learnings
    \\
    \\usage: ledger migrate --source learnings [-h] [--from PATH] [--to PATH] [--mode {copy,move}] [--invalid-policy {error,skip}] [--dry-run] [--allow-existing-target] [--remove-legacy]
    \\
    \\Copy or move legacy learning rows into .ledger/learnings/events.jsonl.
    \\
    \\Migration states:
    \\  legacy-only           old learnings store exists and .ledger/learnings/events.jsonl is missing; run --mode copy before append
    \\  migrated              canonical .ledger/learnings/events.jsonl exists; append is allowed
    \\  invalid               selected store contains irreparable records; inspect doctor spans or use source-preserving --invalid-policy skip
    \\  missing               no learnings store exists yet
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --from PATH           Legacy source path relative to repo root (default: .ledger/learnings/learnings.jsonl when present, then .learnings.jsonl)
    \\  --to PATH             Canonical target path relative to repo root (default: .ledger/learnings/events.jsonl)
    \\  --mode {copy,move}    Copy preserves the legacy file; move may remove it when safe (default: copy)
    \\  --invalid-policy {error,skip}
    \\                        Error rejects any irreparable logical record (default); skip copies valid records, reports skipped line spans, and preserves the legacy source
    \\  --dry-run             Validate and report the migration without writing
    \\  --allow-existing-target
    \\                        Merge compatible target rows instead of requiring a missing target
    \\  --remove-legacy       Remove legacy source after a successful migration when allowed
    \\
    \\Preflight:
    \\  ledger doctor --source learnings
    \\  ledger migrate --source learnings --dry-run --mode copy
    \\  ledger migrate --source learnings --mode copy
;

const DatasetsUsageText =
    \\ledger datasets --source learnings
    \\
    \\usage: ledger datasets --source learnings [-h]
    \\
    \\List queryable learnings datasets.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
;

const DatasetSchemaUsageText =
    \\ledger dataset-schema --source learnings
    \\
    \\usage: ledger dataset-schema --source learnings [-h] --dataset DATASET
    \\
    \\Show the schema for a queryable learnings dataset.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --dataset DATASET     Dataset name, for example: learnings
;

const QueryUsageText =
    \\ledger query --source learnings
    \\
    \\usage: ledger query --source learnings [-h] --spec SPEC
    \\
    \\Run a JSON query spec against the learnings dataset.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --spec SPEC           Inline JSON spec or path to a JSON spec file
;

const RecentUsageText =
    \\ledger recent --source learnings
    \\
    \\usage: ledger recent --source learnings [-h] [--limit LIMIT]
    \\
    \\Show the most recent learnings.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --limit LIMIT         Maximum rows to show (default: 20)
;

const RecallUsageText =
    \\ledger recall --source learnings
    \\
    \\usage: ledger recall --source learnings [-h] --query QUERY [--paths PATHS] [--limit LIMIT] [--format FORMAT] [--drop-superseded]
    \\
    \\Rank relevant learnings for a task.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --query QUERY         Focused task or failure description
    \\  --paths PATHS         Optional path hints, comma-separated or text
    \\  --limit LIMIT         Maximum rows to show (default: 8)
    \\  --format FORMAT       Output format
    \\  --drop-superseded     Hide records superseded by newer learnings
;

const ExportUsageText =
    \\ledger export --source learnings
    \\
    \\usage: ledger export --source learnings [-h] --id lrn-ID [--format full|memory-note] [--path PATH]
    \\
    \\Emit an authoritative deterministic projection of one canonical learning record.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --id lrn-ID           Canonical learning id
    \\  --format FORMAT       full or memory-note (default: full)
    \\  --path PATH           Current persistent-adapter path
;

const CodifyCandidatesUsageText =
    \\ledger codify-candidates --source learnings
    \\
    \\usage: ledger codify-candidates --source learnings [-h] [--min-count COUNT] [--limit LIMIT] [--format FORMAT] [--drop-superseded]
    \\
    \\Suggest repeated or high-impact learnings to promote into durable docs.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --min-count COUNT     Minimum repeated evidence count
    \\  --limit LIMIT         Maximum candidates to show (default: 20)
    \\  --format FORMAT       Output format
    \\  --drop-superseded     Hide records superseded by newer learnings
;

const QualityAuditUsageText =
    \\ledger quality-audit --source learnings
    \\
    \\usage: ledger quality-audit --source learnings [-h] [--since DATE] [--until DATE] [--format FORMAT] [--output PATH]
    \\
    \\Summarize learning capture quality and contract health.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --since DATE          Start date filter
    \\  --until DATE          End date filter
    \\  --format FORMAT       Output format
    \\  --output PATH         Write report to path
;

const ValueReportUsageText =
    \\ledger value-report --source learnings
    \\
    \\usage: ledger value-report --source learnings [-h] [--sessions-root PATH] [--since DATE] [--until DATE] [--comparator NAME] [--format FORMAT] [--output PATH]
    \\
    \\Compare recall-loaded sessions against a non-recall comparator.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --sessions-root PATH  Sessions root to scan
    \\  --since DATE          Start date filter
    \\  --until DATE          End date filter
    \\  --comparator NAME     learnings_nonrecall, impl_nonrecall, or all_nonrecall
    \\  --format FORMAT       Output format
    \\  --output PATH         Write report to path
;

const MemoryDigestUsageText =
    \\ledger memory-digest --source learnings
    \\
    \\usage: ledger memory-digest --source learnings [-h] [--scan-root PATH] [--since DATE] [--limit-candidates LIMIT] [--output PATH]
    \\
    \\Generate a disposable cross-repo memory consolidation digest.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --scan-root PATH      Root to scan for learnings stores
    \\  --since DATE          Start date filter
    \\  --limit-candidates LIMIT
    \\                        Maximum candidate rows (default: 12)
    \\  --output PATH         Write digest to path
;

const DoctorUsageText =
    \\ledger doctor --source learnings
    \\
    \\usage: ledger doctor --source learnings [-h]
    \\
    \\Validate the selected learnings store and report path status, repairs, and invalid physical line spans.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
;

const PathUsageText =
    \\ledger path --source learnings
    \\
    \\usage: ledger path --source learnings [-h]
    \\
    \\Print the resolved default learnings path.
    \\
    \\options:
    \\  -h, --help            show this help message and exit
;

const LearningsFields = [_][]const u8{
    "id",
    "captured_at",
    "day",
    "week",
    "month",
    "status",
    "learning",
    "learning_snippet",
    "application",
    "source",
    "fingerprint",
    "repo",
    "branch",
    "tags_text",
    "tags_count",
    "paths_text",
    "paths_count",
    "evidence_text",
    "evidence_count",
    "related_ids_text",
    "supersedes_id",
    "text",
};

const LearningPathsFields = [_][]const u8{
    "id",
    "captured_at",
    "day",
    "week",
    "month",
    "status",
    "repo",
    "branch",
    "path",
    "fingerprint",
    "source",
};

const LearningTagsFields = [_][]const u8{
    "id",
    "captured_at",
    "day",
    "week",
    "month",
    "status",
    "repo",
    "branch",
    "tag",
    "fingerprint",
    "source",
};

const STOPWORDS = [_][]const u8{
    "a",
    "an",
    "and",
    "are",
    "as",
    "at",
    "be",
    "because",
    "but",
    "by",
    "for",
    "from",
    "if",
    "in",
    "into",
    "is",
    "it",
    "no",
    "not",
    "of",
    "on",
    "or",
    "over",
    "so",
    "such",
    "that",
    "the",
    "their",
    "then",
    "there",
    "these",
    "this",
    "to",
    "too",
    "up",
    "was",
    "were",
    "when",
    "with",
};

const TOOL_KEYWORDS = [_][]const u8{
    "git",
    "gh",
    "uv",
    "pytest",
    "ruff",
    "mypy",
    "zig",
    "go",
    "npm",
    "bun",
    "docker",
    "make",
    "ci",
    "pre_commit",
    "precommit",
};

const RecallTextMarkers = [_][]const u8{
    "learnings recall",
    "run_learnings_tool recall",
};

const LearningsTextMarkers = [_][]const u8{
    "$learnings",
    "append_learning",
    "run_learnings_tool",
    "learnings recall",
    ".ledger/learnings/learnings.jsonl",
    ".learnings.jsonl",
    "skill:learnings",
};

const ImplementationTextMarkers = [_][]const u8{
    "$tk",
    "$fix",
    "$mesh",
    "$commit",
    "$patch",
    "$ship",
    "$join",
    "$fin",
    "$zig",
    "<name>tk</name>",
    "<name>fix</name>",
    "<name>mesh</name>",
};

const ProofTextMarkers = [_][]const u8{
    "proof",
    "validated",
    "validation",
    "passed",
    "fail->pass",
};

const FrictionTextMarkers = [_][]const u8{
    "error",
    "failed",
    "timeout",
    "retry",
    "invalid",
};

const StatusBoost = struct {
    status: []const u8,
    value: f64,
};

const STATUS_BOOSTS = [_]StatusBoost{
    .{ .status = "codify_now", .value = 0.30 },
    .{ .status = "avoid_for_now", .value = 0.25 },
    .{ .status = "do_less", .value = 0.15 },
    .{ .status = "do_more", .value = 0.15 },
    .{ .status = "investigate_more", .value = 0.10 },
    .{ .status = "review_later", .value = -0.05 },
};

const Command = enum {
    append,
    datasets,
    dataset_schema,
    query,
    recent,
    recall,
    @"export",
    codify_candidates,
    quality_audit,
    value_report,
    memory_digest,
    migrate,
    doctor,
    path,
};

const MigrationMode = enum {
    copy,
    move,
};

const InvalidPolicy = enum {
    reject,
    skip,
};

const Args = struct {
    path: []const u8 = DefaultLearningsPath,
    path_explicit: bool = false,
    sessions_root: []const u8 = "",
    since: []const u8 = "",
    until: []const u8 = "",
    comparator: []const u8 = "learnings_nonrecall",
    output: []const u8 = "",
    command: ?Command = null,
    dataset: ?[]const u8 = null,
    spec: ?[]const u8 = null,
    limit: usize = 0,
    query: ?[]const u8 = null,
    export_id: ?[]const u8 = null,
    export_format: []const u8 = "full",
    paths: []const u8 = "",
    format: []const u8 = "table",
    drop_superseded: bool = false,
    min_count: usize = 3,
    scan_root: []const u8 = "",
    append_args_start: usize = 0,
    migrate_from: []const u8 = "",
    migrate_to: []const u8 = DefaultLearningsPath,
    migrate_mode: MigrationMode = .copy,
    invalid_policy: InvalidPolicy = .reject,
    dry_run: bool = false,
    allow_existing_target: bool = false,
    remove_legacy: bool = false,
};

const RecallCandidate = struct {
    row_index: usize,
    score: f64,
    overlap: usize,
    jaccard: f64,
    tool_match: f64,
    path_match: f64,
};

const CodifyCandidate = struct {
    score: f64,
    count: usize,
    last_seen: []const u8,
    status: []const u8,
    theme: []u8,
    learning: []u8,

    fn deinit(self: *CodifyCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.last_seen);
        allocator.free(self.status);
        allocator.free(self.theme);
        allocator.free(self.learning);
    }
};

const DateParts = struct {
    year: i32,
    month: i32,
    day: i32,
};

const Comparator = enum {
    learnings_nonrecall,
    impl_nonrecall,
    all_nonrecall,
};

const QualityCounts = struct {
    total_records: usize = 0,
    required_key_missing_count: usize = 0,
    missing_application_count: usize = 0,
    missing_or_empty_evidence_count: usize = 0,
    condition_action_count: usize = 0,
    evidence_anchor_count: usize = 0,
    fingerprint_duplicate_groups: usize = 0,
};

const SessionSummary = struct {
    path: []u8,
    day: []u8,
    duration_min: f64,
    has_recall: bool,
    has_learnings: bool,
    has_impl: bool,
    has_proof: bool,
    has_friction: bool,
    recall_delta_min: ?f64,

    fn deinit(self: SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.day);
    }
};

const CohortStats = struct {
    n: usize = 0,
    duration_median_min: ?f64 = null,
    duration_p90_min: ?f64 = null,
    proof_rate: ?f64 = null,
    friction_rate: ?f64 = null,
    recall_delta_median_min: ?f64 = null,
};

const DigestCandidate = struct {
    score: f64,
    theme: []u8,
    indices: []usize,

    fn deinit(self: *DigestCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.theme);
        allocator.free(self.indices);
    }
};

const DigestGroupAccumulator = struct {
    score: f64 = 0,
    indices: std.ArrayList(usize) = .empty,

    fn deinit(self: *DigestGroupAccumulator, allocator: std.mem.Allocator) void {
        self.indices.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    try runWithArgv(allocator, argv, init.environ_map.get("CODEX_HOME") orelse "");
}

pub fn runWithArgv(allocator: std.mem.Allocator, argv: []const []const u8, codex_home: []const u8) !void {
    if (argv.len <= 1) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    if (core_cli.isHelpArg(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }
    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }
    if (subcommandHelpSurface(argv)) |surface| {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, surface, Version);
        return;
    }

    const parsed = parseArgs(argv) catch |err| {
        printParseError(err, argv);
    };

    if ((parsed.command orelse unreachable) == .append) {
        try cmdAppend(allocator, argv, parsed, codex_home);
        return;
    }

    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    const repo_root = try discoverRepoRootAlloc(allocator, cwd);
    defer allocator.free(repo_root);

    switch (parsed.command orelse unreachable) {
        .append => unreachable,
        .datasets => try cmdDatasets(allocator),
        .dataset_schema => try cmdDatasetSchema(allocator, parsed.dataset.?),
        .query => {
            const jsonl_path = try resolveReadJsonlPathAlloc(allocator, repo_root, parsed.path, parsed.path_explicit);
            defer allocator.free(jsonl_path);
            try cmdQuery(allocator, repo_root, jsonl_path, parsed.spec.?);
        },
        .recent => {
            const jsonl_path = try resolveReadJsonlPathAlloc(allocator, repo_root, parsed.path, parsed.path_explicit);
            defer allocator.free(jsonl_path);
            try cmdRecent(allocator, repo_root, jsonl_path, if (parsed.limit == 0) 20 else parsed.limit);
        },
        .recall => {
            const jsonl_path = try resolveReadJsonlPathAlloc(allocator, repo_root, parsed.path, parsed.path_explicit);
            defer allocator.free(jsonl_path);
            try cmdRecall(
                allocator,
                repo_root,
                jsonl_path,
                parsed.query.?,
                parsed.paths,
                if (parsed.limit == 0) 8 else parsed.limit,
                parsed.format,
                parsed.drop_superseded,
            );
        },
        .@"export" => {
            const jsonl_path = try resolveReadJsonlPathAlloc(allocator, repo_root, parsed.path, parsed.path_explicit);
            defer allocator.free(jsonl_path);
            try cmdExport(allocator, jsonl_path, parsed.path, parsed.export_id.?, parsed.export_format);
        },
        .codify_candidates => {
            const jsonl_path = try resolveReadJsonlPathAlloc(allocator, repo_root, parsed.path, parsed.path_explicit);
            defer allocator.free(jsonl_path);
            try cmdCodifyCandidates(
                allocator,
                repo_root,
                jsonl_path,
                if (parsed.limit == 0) 20 else parsed.limit,
                parsed.min_count,
                parsed.format,
                parsed.drop_superseded,
            );
        },
        .quality_audit => {
            const jsonl_path = try resolveReadJsonlPathAlloc(allocator, repo_root, parsed.path, parsed.path_explicit);
            defer allocator.free(jsonl_path);
            try cmdQualityAudit(
                allocator,
                jsonl_path,
                parsed.since,
                parsed.until,
                parsed.format,
                parsed.output,
            );
        },
        .value_report => try cmdValueReport(
            allocator,
            repo_root,
            parsed.path,
            parsed.sessions_root,
            parsed.since,
            parsed.until,
            parsed.comparator,
            parsed.format,
            parsed.output,
        ),
        .memory_digest => try cmdMemoryDigest(
            allocator,
            repo_root,
            parsed.scan_root,
            parsed.since,
            if (parsed.limit == 0) 12 else parsed.limit,
            parsed.output,
            codex_home,
            true,
        ),
        .migrate => std.process.exit(try cmdMigrate(allocator, repo_root, parsed)),
        .doctor => std.process.exit(try cmdDoctor(allocator, repo_root)),
        .path => try cmdPath(allocator, repo_root, parsed.path, parsed.path_explicit),
    }
}

fn subcommandHelpSurface(argv: []const []const u8) ?core_cli.HelpSurface {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--path")) {
            i += 1;
            continue;
        }
        if (!core_cli.containsHelpArg(argv[i + 1 ..])) return null;
        if (std.mem.eql(u8, arg, "append")) {
            const surface = append_learning_cli.subcommandSurface();
            return .{ .executable_name = surface.program_name, .help_text = surface.help_text };
        }
        if (std.mem.eql(u8, arg, "datasets")) return DatasetsHelpSurface;
        if (std.mem.eql(u8, arg, "dataset-schema")) return DatasetSchemaHelpSurface;
        if (std.mem.eql(u8, arg, "query")) return QueryHelpSurface;
        if (std.mem.eql(u8, arg, "recent")) return RecentHelpSurface;
        if (std.mem.eql(u8, arg, "recall")) return RecallHelpSurface;
        if (std.mem.eql(u8, arg, "export")) return ExportHelpSurface;
        if (std.mem.eql(u8, arg, "codify-candidates")) return CodifyCandidatesHelpSurface;
        if (std.mem.eql(u8, arg, "quality-audit")) return QualityAuditHelpSurface;
        if (std.mem.eql(u8, arg, "value-report")) return ValueReportHelpSurface;
        if (std.mem.eql(u8, arg, "memory-digest")) return MemoryDigestHelpSurface;
        if (std.mem.eql(u8, arg, "migrate")) return MigrateHelpSurface;
        if (std.mem.eql(u8, arg, "doctor")) return DoctorHelpSurface;
        if (std.mem.eql(u8, arg, "path")) return PathHelpSurface;
        return null;
    }
    return null;
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 1;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i >= argv.len) return error.MissingPathValue;
            args.path = argv[i];
            args.path_explicit = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "append")) {
            args.command = .append;
            args.append_args_start = i + 1;
            break;
        }
        if (std.mem.eql(u8, arg, "datasets")) {
            args.command = .datasets;
            continue;
        }
        if (std.mem.eql(u8, arg, "dataset-schema")) {
            args.command = .dataset_schema;
            continue;
        }
        if (std.mem.eql(u8, arg, "query")) {
            args.command = .query;
            continue;
        }
        if (std.mem.eql(u8, arg, "recent")) {
            args.command = .recent;
            continue;
        }
        if (std.mem.eql(u8, arg, "recall")) {
            args.command = .recall;
            continue;
        }
        if (std.mem.eql(u8, arg, "export")) {
            args.command = .@"export";
            continue;
        }
        if (std.mem.eql(u8, arg, "codify-candidates")) {
            args.command = .codify_candidates;
            continue;
        }
        if (std.mem.eql(u8, arg, "quality-audit")) {
            args.command = .quality_audit;
            continue;
        }
        if (std.mem.eql(u8, arg, "value-report")) {
            args.command = .value_report;
            continue;
        }
        if (std.mem.eql(u8, arg, "memory-digest")) {
            args.command = .memory_digest;
            continue;
        }
        if (std.mem.eql(u8, arg, "migrate")) {
            args.command = .migrate;
            continue;
        }
        if (std.mem.eql(u8, arg, "doctor")) {
            args.command = .doctor;
            continue;
        }
        if (std.mem.eql(u8, arg, "path")) {
            args.command = .path;
            continue;
        }

        if (args.command == null) return error.MissingCommand;

        switch (args.command.?) {
            .append => unreachable,
            .dataset_schema => {
                if (std.mem.eql(u8, arg, "--dataset")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingDatasetValue;
                    args.dataset = argv[i];
                    continue;
                }
                return error.InvalidDatasetSchemaArg;
            },
            .query => {
                if (std.mem.eql(u8, arg, "--spec")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingSpecValue;
                    args.spec = argv[i];
                    continue;
                }
                return error.InvalidQueryArg;
            },
            .recent => {
                if (std.mem.eql(u8, arg, "--limit")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingLimitValue;
                    args.limit = try parsePositiveInt(argv[i]);
                    continue;
                }
                return error.InvalidRecentArg;
            },
            .recall => {
                if (std.mem.eql(u8, arg, "--query")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingQueryValue;
                    args.query = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--paths")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingPathsValue;
                    args.paths = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--limit")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingLimitValue;
                    args.limit = try parsePositiveInt(argv[i]);
                    continue;
                }
                if (std.mem.eql(u8, arg, "--format")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingFormatValue;
                    args.format = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--drop-superseded")) {
                    args.drop_superseded = true;
                    continue;
                }
                return error.InvalidRecallArg;
            },
            .@"export" => {
                if (std.mem.eql(u8, arg, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.export_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--format")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingFormatValue;
                    if (!std.mem.eql(u8, argv[i], "full") and !std.mem.eql(u8, argv[i], "memory-note")) return error.InvalidExportFormat;
                    args.export_format = argv[i];
                    continue;
                }
                return error.InvalidExportArg;
            },
            .codify_candidates => {
                if (std.mem.eql(u8, arg, "--min-count")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingMinCountValue;
                    args.min_count = try parsePositiveInt(argv[i]);
                    continue;
                }
                if (std.mem.eql(u8, arg, "--limit")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingLimitValue;
                    args.limit = try parsePositiveInt(argv[i]);
                    continue;
                }
                if (std.mem.eql(u8, arg, "--format")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingFormatValue;
                    args.format = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--drop-superseded")) {
                    args.drop_superseded = true;
                    continue;
                }
                return error.InvalidCodifyArg;
            },
            .quality_audit => {
                if (std.mem.eql(u8, arg, "--since")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingSinceValue;
                    args.since = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--until")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingUntilValue;
                    args.until = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--format")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingFormatValue;
                    args.format = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--output")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingOutputValue;
                    args.output = argv[i];
                    continue;
                }
                return error.InvalidQualityAuditArg;
            },
            .value_report => {
                if (std.mem.eql(u8, arg, "--sessions-root")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingSessionsRootValue;
                    args.sessions_root = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--since")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingSinceValue;
                    args.since = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--until")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingUntilValue;
                    args.until = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--comparator")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingComparatorValue;
                    args.comparator = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--format")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingFormatValue;
                    args.format = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--output")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingOutputValue;
                    args.output = argv[i];
                    continue;
                }
                return error.InvalidValueReportArg;
            },
            .memory_digest => {
                if (std.mem.eql(u8, arg, "--scan-root")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingScanRootValue;
                    args.scan_root = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--since")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingSinceValue;
                    args.since = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--limit-candidates")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingLimitValue;
                    args.limit = try parsePositiveInt(argv[i]);
                    continue;
                }
                if (std.mem.eql(u8, arg, "--output")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingOutputValue;
                    args.output = argv[i];
                    continue;
                }
                return error.InvalidMemoryDigestArg;
            },
            .migrate => {
                if (std.mem.eql(u8, arg, "--from")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingFromValue;
                    args.migrate_from = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--to")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingToValue;
                    args.migrate_to = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--mode")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingModeValue;
                    if (std.mem.eql(u8, argv[i], "copy")) {
                        args.migrate_mode = .copy;
                    } else if (std.mem.eql(u8, argv[i], "move")) {
                        args.migrate_mode = .move;
                    } else {
                        return error.InvalidMigrationMode;
                    }
                    continue;
                }
                if (std.mem.eql(u8, arg, "--invalid-policy")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInvalidPolicyValue;
                    if (std.mem.eql(u8, argv[i], "error")) {
                        args.invalid_policy = .reject;
                    } else if (std.mem.eql(u8, argv[i], "skip")) {
                        args.invalid_policy = .skip;
                    } else {
                        return error.InvalidPolicyValue;
                    }
                    continue;
                }
                if (std.mem.eql(u8, arg, "--dry-run")) {
                    args.dry_run = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--allow-existing-target")) {
                    args.allow_existing_target = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--remove-legacy")) {
                    args.remove_legacy = true;
                    continue;
                }
                return error.InvalidMigrateArg;
            },
            .doctor => return error.InvalidDoctorArg,
            .path => return error.InvalidPathArg,
            .datasets => return error.InvalidDatasetsArg,
        }
    }

    if (args.command == null) return error.MissingCommand;
    switch (args.command.?) {
        .dataset_schema => if (args.dataset == null) return error.MissingDatasetValue,
        .query => if (args.spec == null) return error.MissingSpecValue,
        .recall => if (args.query == null) return error.MissingQueryValue,
        .@"export" => if (args.export_id == null) return error.MissingIdValue,
        else => {},
    }
    if (args.command.? == .migrate and args.invalid_policy == .skip and
        (args.migrate_mode != .copy or args.remove_legacy))
    {
        return error.UnsafeSkipPolicy;
    }

    return args;
}

fn printParseError(err: anyerror, argv: []const []const u8) noreturn {
    _ = argv;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;

    switch (err) {
        error.MissingCommand => {
            stderr.print("error: missing command\n", .{}) catch {};
        },
        error.MissingPathValue => {
            stderr.print("error: argument --path: expected one argument\n", .{}) catch {};
        },
        error.MissingDatasetValue => {
            stderr.print("error: argument --dataset: expected one argument\n", .{}) catch {};
        },
        error.MissingSpecValue => {
            stderr.print("error: argument --spec: expected one argument\n", .{}) catch {};
        },
        error.MissingLimitValue => {
            stderr.print("error: argument --limit: expected one argument\n", .{}) catch {};
        },
        error.MissingQueryValue => {
            stderr.print("error: argument --query: expected one argument\n", .{}) catch {};
        },
        error.MissingIdValue => {
            stderr.print("error: argument --id: expected one argument\n", .{}) catch {};
        },
        error.MissingPathsValue => {
            stderr.print("error: argument --paths: expected one argument\n", .{}) catch {};
        },
        error.MissingMinCountValue => {
            stderr.print("error: argument --min-count: expected one argument\n", .{}) catch {};
        },
        error.MissingFormatValue => {
            stderr.print("error: argument --format: expected one argument\n", .{}) catch {};
        },
        error.MissingSinceValue => {
            stderr.print("error: argument --since: expected one argument\n", .{}) catch {};
        },
        error.MissingUntilValue => {
            stderr.print("error: argument --until: expected one argument\n", .{}) catch {};
        },
        error.MissingSessionsRootValue => {
            stderr.print("error: argument --sessions-root: expected one argument\n", .{}) catch {};
        },
        error.MissingComparatorValue => {
            stderr.print("error: argument --comparator: expected one argument\n", .{}) catch {};
        },
        error.MissingOutputValue => {
            stderr.print("error: argument --output: expected one argument\n", .{}) catch {};
        },
        error.MissingScanRootValue => {
            stderr.print("error: argument --scan-root: expected one argument\n", .{}) catch {};
        },
        error.MissingFromValue => {
            stderr.print("error: argument --from: expected one argument\n", .{}) catch {};
        },
        error.MissingToValue => {
            stderr.print("error: argument --to: expected one argument\n", .{}) catch {};
        },
        error.MissingModeValue => {
            stderr.print("error: argument --mode: expected one argument\n", .{}) catch {};
        },
        error.MissingInvalidPolicyValue => {
            stderr.print("error: argument --invalid-policy: expected one argument\n", .{}) catch {};
        },
        error.InvalidMigrationMode => {
            stderr.print("error: argument --mode: expected copy or move\n", .{}) catch {};
        },
        error.InvalidPolicyValue => {
            stderr.print("error: argument --invalid-policy: expected error or skip\n", .{}) catch {};
        },
        error.UnsafeSkipPolicy => {
            stderr.print("error: --invalid-policy skip requires --mode copy and forbids --remove-legacy\n", .{}) catch {};
        },
        error.InvalidPositiveInt => {
            stderr.print("error: expected non-negative integer\n", .{}) catch {};
        },
        error.InvalidDatasetsArg,
        error.InvalidDatasetSchemaArg,
        error.InvalidQueryArg,
        error.InvalidRecentArg,
        error.InvalidRecallArg,
        error.InvalidExportArg,
        error.InvalidExportFormat,
        error.InvalidCodifyArg,
        error.InvalidQualityAuditArg,
        error.InvalidValueReportArg,
        error.InvalidMemoryDigestArg,
        error.InvalidMigrateArg,
        error.InvalidDoctorArg,
        error.InvalidPathArg,
        error.ConflictingPathValue,
        => {
            stderr.print("error: invalid arguments\n", .{}) catch {};
        },
        else => {
            stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
        },
    }

    core_cli.printHelpSurface(stderr, HelpSurface, Version) catch {};
    std.process.exit(2);
}

fn cmdAppend(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    args: Args,
    codex_home: []const u8,
) !void {
    const append_args = mergeAppendArgsAlloc(allocator, args.path_explicit, args.path, argv[args.append_args_start..]) catch |err| switch (err) {
        error.MissingPathValue => exitAppendParseError("argument --path: expected one argument", .{}),
        error.ConflictingPathValue => exitAppendParseError("conflicting --path values before and after append", .{}),
        else => return err,
    };
    defer allocator.free(append_args);
    try append_learning_cli.runWithAllocator(allocator, append_args, append_learning_cli.subcommandSurface());

    if (appendArgsRequestHelpOrVersion(append_args)) return;
    runAutoMemoryDigest(allocator, codex_home) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("memory-digest warning: {s}\n", .{@errorName(err)});
    };
}

const JsonlStats = struct {
    records: usize = 0,
    blank_lines: usize = 0,
    sha256: []u8,
    ids: std.StringHashMap([]u8),

    fn deinit(self: *JsonlStats, allocator: std.mem.Allocator) void {
        allocator.free(self.sha256);
        var it = self.ids.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.ids.deinit();
    }
};

const MigrationIssue = struct {
    start_line: usize,
    end_line: usize,
    reason: []const u8,
};

const MigrationRepair = struct {
    start_line: usize,
    end_line: usize,
    repair: []const u8,
};

const ConvertedLearningRows = struct {
    bytes: []u8,
    records: usize,
    blank_lines: usize,
    recovered_multiline_records: usize,
    repairs: std.ArrayList(MigrationRepair),
    issues: std.ArrayList(MigrationIssue),

    fn deinit(self: *ConvertedLearningRows, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.repairs.deinit(allocator);
        self.issues.deinit(allocator);
    }
};

const StoreInspection = struct {
    records: usize = 0,
    blank_lines: usize = 0,
    issues: std.ArrayList(MigrationIssue) = .empty,

    fn deinit(self: *StoreInspection, allocator: std.mem.Allocator) void {
        self.issues.deinit(allocator);
    }
};

fn cmdMigrate(allocator: std.mem.Allocator, repo_root: []const u8, args: Args) !u8 {
    const effective_from = try resolveMigrateFromPathAlloc(allocator, repo_root, args.migrate_from);
    defer allocator.free(effective_from);
    const from_path = try resolveJsonlPathAlloc(allocator, repo_root, effective_from);
    defer allocator.free(from_path);
    const to_path = try resolveJsonlPathAlloc(allocator, repo_root, args.migrate_to);
    defer allocator.free(to_path);

    const source_bytes = durable_store.readRegularFileNoSymlink(allocator, from_path, MaxLearningsBytes) catch |err| {
        try printMigrationFailure(allocator, from_path, to_path, "source_unreadable", @errorName(err));
        return 1;
    };
    defer allocator.free(source_bytes);

    var conversion = try convertLearningRowsToEventsAlloc(allocator, source_bytes);
    defer conversion.deinit(allocator);

    if (conversion.issues.items.len > 0 and args.invalid_policy == .reject) {
        try printMigrationIssueFailure(
            allocator,
            from_path,
            to_path,
            "invalid_source_record",
            conversion.issues.items[0],
            conversion.issues.items.len,
        );
        return 1;
    }
    const converted_source = conversion.bytes;

    var source_stats = validateJsonlBytes(allocator, converted_source) catch |err| {
        try printMigrationFailure(allocator, from_path, to_path, "invalid_source_jsonl", @errorName(err));
        return 1;
    };
    defer source_stats.deinit(allocator);
    const source_sha = try sha256HexAlloc(allocator, source_bytes);
    defer allocator.free(source_sha);

    if (args.dry_run) {
        try printMigrationResult(allocator, .{
            .status = migrationStatus("would_migrate", conversion.issues.items.len),
            .from = from_path,
            .to = to_path,
            .mode = migrationModeText(args.migrate_mode),
            .invalid_policy = invalidPolicyText(args.invalid_policy),
            .records = source_stats.records,
            .blank_lines = source_stats.blank_lines,
            .recovered_multiline_records = conversion.recovered_multiline_records,
            .repairs = conversion.repairs.items,
            .issues = conversion.issues.items,
            .source_sha256 = source_sha,
            .target_sha256 = source_stats.sha256,
            .legacy_left_in_place = true,
        });
        return 0;
    }

    if (durable_store.fileExists(to_path)) {
        const target_bytes = durable_store.readRegularFileNoSymlink(allocator, to_path, MaxLearningsBytes) catch |err| {
            try printMigrationFailure(allocator, from_path, to_path, "target_unreadable", @errorName(err));
            return 1;
        };
        defer allocator.free(target_bytes);

        var target_stats = validateJsonlBytes(allocator, target_bytes) catch |err| {
            try printMigrationFailure(allocator, from_path, to_path, "invalid_target_jsonl", @errorName(err));
            return 1;
        };
        defer target_stats.deinit(allocator);

        if (std.mem.eql(u8, converted_source, target_bytes)) {
            try maybeRemoveLegacy(args, from_path);
            try printMigrationResult(allocator, .{
                .status = migrationStatus("already_migrated", conversion.issues.items.len),
                .from = from_path,
                .to = to_path,
                .mode = migrationModeText(args.migrate_mode),
                .invalid_policy = invalidPolicyText(args.invalid_policy),
                .records = source_stats.records,
                .blank_lines = source_stats.blank_lines,
                .recovered_multiline_records = conversion.recovered_multiline_records,
                .repairs = conversion.repairs.items,
                .issues = conversion.issues.items,
                .source_sha256 = source_sha,
                .target_sha256 = target_stats.sha256,
                .legacy_left_in_place = !args.remove_legacy and args.migrate_mode == .copy,
            });
            return 0;
        }

        if (!args.allow_existing_target) {
            try printMigrationFailure(allocator, from_path, to_path, "target_exists_with_different_bytes", "use --allow-existing-target for safe merge");
            return 1;
        }

        const merged = mergeJsonlBytesByIdAlloc(allocator, target_bytes, &target_stats, converted_source, &source_stats) catch |err| {
            try printMigrationFailure(allocator, from_path, to_path, "target_exists_with_conflicting_rows", @errorName(err));
            return 1;
        };
        defer allocator.free(merged);

        try durable_store.writeTextAtomic(allocator, to_path, merged);
        const target_sha = try sha256HexAlloc(allocator, merged);
        defer allocator.free(target_sha);
        try maybeRemoveLegacy(args, from_path);
        try printMigrationResult(allocator, .{
            .status = migrationStatus("merged", conversion.issues.items.len),
            .from = from_path,
            .to = to_path,
            .mode = migrationModeText(args.migrate_mode),
            .invalid_policy = invalidPolicyText(args.invalid_policy),
            .records = source_stats.records,
            .blank_lines = source_stats.blank_lines,
            .recovered_multiline_records = conversion.recovered_multiline_records,
            .repairs = conversion.repairs.items,
            .issues = conversion.issues.items,
            .source_sha256 = source_sha,
            .target_sha256 = target_sha,
            .legacy_left_in_place = !args.remove_legacy and args.migrate_mode == .copy,
        });
        return 0;
    }

    try durable_store.writeTextCreateNew(allocator, to_path, converted_source, .{ .reject_symlinks = true });
    var target_stats = validateJsonlBytes(allocator, converted_source) catch unreachable;
    defer target_stats.deinit(allocator);
    try maybeRemoveLegacy(args, from_path);
    try printMigrationResult(allocator, .{
        .status = migrationStatus("migrated", conversion.issues.items.len),
        .from = from_path,
        .to = to_path,
        .mode = migrationModeText(args.migrate_mode),
        .invalid_policy = invalidPolicyText(args.invalid_policy),
        .records = source_stats.records,
        .blank_lines = source_stats.blank_lines,
        .recovered_multiline_records = conversion.recovered_multiline_records,
        .repairs = conversion.repairs.items,
        .issues = conversion.issues.items,
        .source_sha256 = source_sha,
        .target_sha256 = target_stats.sha256,
        .legacy_left_in_place = !args.remove_legacy and args.migrate_mode == .copy,
    });
    return 0;
}

fn cmdDoctor(allocator: std.mem.Allocator, repo_root: []const u8) !u8 {
    const next_path = try resolveJsonlPathAlloc(allocator, repo_root, DefaultLearningsPath);
    defer allocator.free(next_path);
    const previous_path = try resolveJsonlPathAlloc(allocator, repo_root, PreviousLearningsPath);
    defer allocator.free(previous_path);
    const legacy_path = try resolveJsonlPathAlloc(allocator, repo_root, LegacyLearningsPath);
    defer allocator.free(legacy_path);
    const previous_exists = durable_store.fileExists(previous_path);
    const legacy_exists = durable_store.fileExists(legacy_path);
    var persistence = durable_store.PersistentEventStore.init(next_path);
    var next_snapshot = persistence.eventStore().snapshot(allocator, MaxLearningsBytes) catch |err| {
        const issue = MigrationIssue{ .start_line = 0, .end_line = 0, .reason = @errorName(err) };
        const issues = [_]MigrationIssue{issue};
        try printDoctorResult(.{
            .status = "invalid",
            .selected_path = next_path,
            .selected_kind = "current",
            .default_exists = true,
            .previous_exists = previous_exists,
            .legacy_exists = legacy_exists,
            .issues = &issues,
        });
        return 1;
    };
    defer next_snapshot.deinit(allocator);
    const next_exists = next_snapshot.exists;
    const selected_path: ?[]const u8 = if (next_exists)
        next_path
    else if (previous_exists)
        previous_path
    else if (legacy_exists)
        legacy_path
    else
        null;
    const selected_kind = if (next_exists)
        "current"
    else if (previous_exists)
        "previous"
    else if (legacy_exists)
        "legacy"
    else
        "none";

    if (selected_path == null) {
        try printDoctorResult(.{
            .status = "missing",
            .selected_path = null,
            .selected_kind = selected_kind,
            .default_exists = next_exists,
            .previous_exists = previous_exists,
            .legacy_exists = legacy_exists,
        });
        return 0;
    }

    if (next_exists) {
        var inspection = try inspectCanonicalSnapshotAlloc(allocator, next_snapshot);
        defer inspection.deinit(allocator);
        try printDoctorResult(.{
            .status = if (inspection.issues.items.len == 0) "current" else "invalid",
            .selected_path = selected_path,
            .selected_kind = selected_kind,
            .default_exists = next_exists,
            .previous_exists = previous_exists,
            .legacy_exists = legacy_exists,
            .records = inspection.records,
            .blank_lines = inspection.blank_lines,
            .issues = inspection.issues.items,
        });
        return if (inspection.issues.items.len == 0) 0 else 1;
    }

    const selected_bytes = durable_store.readRegularFileNoSymlink(allocator, selected_path.?, MaxLearningsBytes) catch |err| {
        const issue = MigrationIssue{ .start_line = 0, .end_line = 0, .reason = @errorName(err) };
        const issues = [_]MigrationIssue{issue};
        try printDoctorResult(.{
            .status = "invalid",
            .selected_path = selected_path,
            .selected_kind = selected_kind,
            .default_exists = next_exists,
            .previous_exists = previous_exists,
            .legacy_exists = legacy_exists,
            .issues = &issues,
        });
        return 1;
    };
    defer allocator.free(selected_bytes);

    var conversion = try convertLearningRowsToEventsAlloc(allocator, selected_bytes);
    defer conversion.deinit(allocator);
    try printDoctorResult(.{
        .status = if (conversion.issues.items.len == 0) "legacy-only" else "invalid",
        .selected_path = selected_path,
        .selected_kind = selected_kind,
        .default_exists = next_exists,
        .previous_exists = previous_exists,
        .legacy_exists = legacy_exists,
        .records = conversion.records,
        .blank_lines = conversion.blank_lines,
        .recovered_multiline_records = conversion.recovered_multiline_records,
        .repairs = conversion.repairs.items,
        .issues = conversion.issues.items,
    });
    return if (conversion.issues.items.len == 0) 0 else 1;
}

fn cmdPath(allocator: std.mem.Allocator, repo_root: []const u8, raw_path: []const u8, path_explicit: bool) !void {
    const resolved = try resolveReadJsonlPathAlloc(allocator, repo_root, raw_path, path_explicit);
    defer allocator.free(resolved);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.print("{s}\n", .{resolved});
}

const MigrationPrint = struct {
    status: []const u8,
    from: []const u8,
    to: []const u8,
    mode: []const u8,
    invalid_policy: []const u8,
    records: usize,
    blank_lines: usize,
    recovered_multiline_records: usize,
    repairs: []const MigrationRepair,
    issues: []const MigrationIssue,
    source_sha256: []const u8,
    target_sha256: []const u8,
    legacy_left_in_place: bool,
};

fn printMigrationResult(allocator: std.mem.Allocator, result: MigrationPrint) !void {
    _ = allocator;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"command\":\"migrate\",\"status\":");
    try writeJsonString(stdout, result.status);
    try stdout.writeAll(",\"from\":");
    try writeJsonString(stdout, result.from);
    try stdout.writeAll(",\"to\":");
    try writeJsonString(stdout, result.to);
    try stdout.writeAll(",\"mode\":");
    try writeJsonString(stdout, result.mode);
    try stdout.writeAll(",\"invalid_policy\":");
    try writeJsonString(stdout, result.invalid_policy);
    try stdout.print(",\"records\":{d},\"blank_lines\":{d},\"recovered_multiline_records\":{d},\"repaired_records\":{d},\"repairs\":", .{
        result.records,
        result.blank_lines,
        result.recovered_multiline_records,
        result.repairs.len,
    });
    try writeMigrationRepairs(stdout, result.repairs);
    try stdout.print(",\"skipped_records\":{d},\"skipped\":", .{result.issues.len});
    try writeMigrationIssues(stdout, result.issues);
    try stdout.writeAll(",\"source_sha256\":");
    try writeJsonString(stdout, result.source_sha256);
    try stdout.writeAll(",\"target_sha256\":");
    try writeJsonString(stdout, result.target_sha256);
    try stdout.print(",\"legacy_left_in_place\":{s}}}\n", .{if (result.legacy_left_in_place) "true" else "false"});
}

const DoctorPrint = struct {
    status: []const u8,
    selected_path: ?[]const u8,
    selected_kind: []const u8,
    default_exists: bool,
    previous_exists: bool,
    legacy_exists: bool,
    records: usize = 0,
    blank_lines: usize = 0,
    recovered_multiline_records: usize = 0,
    repairs: []const MigrationRepair = &.{},
    issues: []const MigrationIssue = &.{},
};

fn printDoctorResult(result: DoctorPrint) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"command\":\"doctor\",\"status\":");
    try writeJsonString(stdout, result.status);
    try stdout.writeAll(",\"default_path\":");
    try writeJsonString(stdout, DefaultLearningsPath);
    try stdout.writeAll(",\"selected_path\":");
    if (result.selected_path) |path| try writeJsonString(stdout, path) else try stdout.writeAll("null");
    try stdout.writeAll(",\"selected_kind\":");
    try writeJsonString(stdout, result.selected_kind);
    try stdout.print(",\"default_exists\":{s},\"previous_exists\":{s},\"legacy_exists\":{s},\"records\":{d},\"blank_lines\":{d},\"recovered_multiline_records\":{d},\"repaired_records\":{d},\"repairs\":", .{
        if (result.default_exists) "true" else "false",
        if (result.previous_exists) "true" else "false",
        if (result.legacy_exists) "true" else "false",
        result.records,
        result.blank_lines,
        result.recovered_multiline_records,
        result.repairs.len,
    });
    try writeMigrationRepairs(stdout, result.repairs);
    try stdout.print(",\"invalid_records\":{d},\"issues\":", .{result.issues.len});
    try writeMigrationIssues(stdout, result.issues);
    try stdout.writeAll("}\n");
}

fn writeMigrationRepairs(writer: *std.Io.Writer, repairs: []const MigrationRepair) !void {
    try writer.writeByte('[');
    for (repairs, 0..) |repair, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"start_line\":{d},\"end_line\":{d},\"repair\":", .{ repair.start_line, repair.end_line });
        try writeJsonString(writer, repair.repair);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeMigrationIssues(writer: *std.Io.Writer, issues: []const MigrationIssue) !void {
    try writer.writeByte('[');
    for (issues, 0..) |issue, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"start_line\":{d},\"end_line\":{d},\"reason\":", .{ issue.start_line, issue.end_line });
        try writeJsonString(writer, issue.reason);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn printMigrationFailure(allocator: std.mem.Allocator, from_path: []const u8, to_path: []const u8, reason: []const u8, detail: []const u8) !void {
    _ = allocator;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"command\":\"migrate\",\"status\":\"failed\",\"reason\":");
    try writeJsonString(stdout, reason);
    try stdout.writeAll(",\"detail\":");
    try writeJsonString(stdout, detail);
    try stdout.writeAll(",\"from\":");
    try writeJsonString(stdout, from_path);
    try stdout.writeAll(",\"to\":");
    try writeJsonString(stdout, to_path);
    try stdout.writeAll("}\n");
}

fn printMigrationIssueFailure(
    allocator: std.mem.Allocator,
    from_path: []const u8,
    to_path: []const u8,
    reason: []const u8,
    issue: MigrationIssue,
    invalid_records: usize,
) !void {
    _ = allocator;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"command\":\"migrate\",\"status\":\"failed\",\"reason\":");
    try writeJsonString(stdout, reason);
    try stdout.writeAll(",\"detail\":");
    try writeJsonString(stdout, issue.reason);
    try stdout.print(",\"start_line\":{d},\"end_line\":{d},\"invalid_records\":{d},\"from\":", .{
        issue.start_line,
        issue.end_line,
        invalid_records,
    });
    try writeJsonString(stdout, from_path);
    try stdout.writeAll(",\"to\":");
    try writeJsonString(stdout, to_path);
    try stdout.writeAll("}\n");
}

fn migrationModeText(mode: MigrationMode) []const u8 {
    return switch (mode) {
        .copy => "copy",
        .move => "move",
    };
}

fn invalidPolicyText(policy: InvalidPolicy) []const u8 {
    return switch (policy) {
        .reject => "error",
        .skip => "skip",
    };
}

fn migrationStatus(base: []const u8, skipped_records: usize) []const u8 {
    if (skipped_records == 0) return base;
    if (std.mem.eql(u8, base, "would_migrate")) return "would_migrate_with_skips";
    if (std.mem.eql(u8, base, "already_migrated")) return "already_migrated_with_skips";
    if (std.mem.eql(u8, base, "merged")) return "merged_with_skips";
    if (std.mem.eql(u8, base, "migrated")) return "migrated_with_skips";
    return base;
}

fn maybeRemoveLegacy(args: Args, from_path: []const u8) !void {
    if (args.migrate_mode != .move and !args.remove_legacy) return;
    try deleteFilePath(from_path);
}

fn resolveMigrateFromPathAlloc(allocator: std.mem.Allocator, repo_root: []const u8, raw_path: []const u8) ![]u8 {
    if (raw_path.len != 0) return allocator.dupe(u8, raw_path);

    const previous_path = try resolveJsonlPathAlloc(allocator, repo_root, PreviousLearningsPath);
    defer allocator.free(previous_path);
    if (durable_store.fileExists(previous_path)) return allocator.dupe(u8, PreviousLearningsPath);

    return allocator.dupe(u8, LegacyLearningsPath);
}

const JsonFragmentState = struct {
    depth: usize = 0,
    in_string: bool = false,
    escaped: bool = false,
    invalid_closing: bool = false,

    fn scan(self: *JsonFragmentState, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.in_string) {
                if (self.escaped) {
                    self.escaped = false;
                } else if (byte == '\\') {
                    self.escaped = true;
                } else if (byte == '"') {
                    self.in_string = false;
                }
                continue;
            }

            switch (byte) {
                '"' => self.in_string = true,
                '{', '[' => self.depth += 1,
                '}', ']' => {
                    if (self.depth == 0) {
                        self.invalid_closing = true;
                    } else {
                        self.depth -= 1;
                    }
                },
                else => {},
            }
        }
    }
};

const RecordConversion = union(enum) {
    appended,
    issue: []const u8,
};

fn convertLearningRowsToEventsAlloc(allocator: std.mem.Allocator, bytes: []const u8) !ConvertedLearningRows {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var repairs: std.ArrayList(MigrationRepair) = .empty;
    errdefer repairs.deinit(allocator);
    var issues: std.ArrayList(MigrationIssue) = .empty;
    errdefer issues.deinit(allocator);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var seen_ids = std.StringHashMap(void).init(allocator);
    defer {
        var key_it = seen_ids.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        seen_ids.deinit();
    }

    var records: usize = 0;
    var blank_lines: usize = 0;
    var recovered_multiline_records: usize = 0;
    var pending_start_line: usize = 0;
    var pending_end_line: usize = 0;
    var fragment_state = JsonFragmentState{};
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) {
            blank_lines += 1;
            if (pending.items.len > 0) {
                try pending.append(allocator, '\n');
                pending_end_line = line_number;
            }
            continue;
        }

        if (pending.items.len == 0) {
            pending_start_line = line_number;
            fragment_state = .{};
        } else {
            if (try repairMissingOpeningKeyQuoteAlloc(allocator, pending.items, line)) |repaired_record| {
                defer allocator.free(repaired_record);
                const outcome = try appendConvertedLearningRecord(allocator, &out, &seen_ids, repaired_record);
                switch (outcome) {
                    .appended => {
                        records += 1;
                        recovered_multiline_records += 1;
                        try repairs.append(allocator, .{
                            .start_line = pending_start_line,
                            .end_line = line_number,
                            .repair = "insert_missing_opening_key_quote",
                        });
                    },
                    .issue => |reason| try issues.append(allocator, .{
                        .start_line = pending_start_line,
                        .end_line = line_number,
                        .reason = reason,
                    }),
                }
                pending.clearRetainingCapacity();
                fragment_state = .{};
                continue;
            }
            try pending.append(allocator, '\n');
        }
        try pending.appendSlice(allocator, line);
        pending_end_line = line_number;
        fragment_state.scan(line);

        if (fragment_state.in_string) {
            try issues.append(allocator, .{
                .start_line = pending_start_line,
                .end_line = pending_end_line,
                .reason = "MalformedJsonValue",
            });
            pending.clearRetainingCapacity();
            fragment_state = .{};
            continue;
        }
        if (fragment_state.depth != 0 and !fragment_state.invalid_closing) continue;

        const outcome = try appendConvertedLearningRecord(allocator, &out, &seen_ids, pending.items);
        switch (outcome) {
            .appended => {
                records += 1;
                if (pending_end_line > pending_start_line) recovered_multiline_records += 1;
            },
            .issue => |reason| try issues.append(allocator, .{
                .start_line = pending_start_line,
                .end_line = pending_end_line,
                .reason = reason,
            }),
        }
        pending.clearRetainingCapacity();
        fragment_state = .{};
    }

    if (pending.items.len > 0) {
        try issues.append(allocator, .{
            .start_line = pending_start_line,
            .end_line = pending_end_line,
            .reason = "UnexpectedEndOfInput",
        });
    }
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n' and blank_lines > 0) blank_lines -= 1;

    return .{
        .bytes = try out.toOwnedSlice(allocator),
        .records = records,
        .blank_lines = blank_lines,
        .recovered_multiline_records = recovered_multiline_records,
        .repairs = repairs,
        .issues = issues,
    };
}

const LegacyMissingOpeningQuotePrefixes = [_][]const u8{
    "id\":",
    "captured_at\":",
    "status\":",
    "learning\":",
    "evidence\":",
    "application\":",
    "context\":",
    "source\":",
    "fingerprint\":",
    "tags\":",
    "related_ids\":",
    "supersedes_id\":",
};

fn repairMissingOpeningKeyQuoteAlloc(
    allocator: std.mem.Allocator,
    pending: []const u8,
    continuation_line: []const u8,
) !?[]u8 {
    var recognized_prefix = false;
    for (LegacyMissingOpeningQuotePrefixes) |prefix| {
        if (std.mem.startsWith(u8, continuation_line, prefix)) {
            recognized_prefix = true;
            break;
        }
    }
    if (!recognized_prefix) return null;

    var candidate: std.ArrayList(u8) = .empty;
    defer candidate.deinit(allocator);
    try candidate.appendSlice(allocator, pending);
    try candidate.append(allocator, '\n');
    try candidate.append(allocator, '"');
    try candidate.appendSlice(allocator, continuation_line);
    const candidate_bytes = try candidate.toOwnedSlice(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, candidate_bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => {
            allocator.free(candidate_bytes);
            return error.OutOfMemory;
        },
        else => {
            allocator.free(candidate_bytes);
            return null;
        },
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => {
            allocator.free(candidate_bytes);
            return null;
        },
    };
    if (learningIdFromObject(obj).len == 0) {
        allocator.free(candidate_bytes);
        return null;
    }
    return candidate_bytes;
}

fn appendConvertedLearningRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    seen_ids: *std.StringHashMap(void),
    record_bytes: []const u8,
) !RecordConversion {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, record_bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .issue = @errorName(err) },
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return .{ .issue = "NonObjectJson" },
    };
    const id = learningIdFromObject(obj);
    if (id.len == 0) return .{ .issue = "MissingLearningId" };
    if (seen_ids.contains(id)) return .{ .issue = "DuplicateLearningId" };

    const normalized_record = try stringifyJsonValueAlloc(allocator, parsed.value);
    defer allocator.free(normalized_record);
    if (learningEventRecordObject(obj) != null) {
        try out.appendSlice(allocator, normalized_record);
        try out.append(allocator, '\n');
    } else {
        const status = jsonObjectString(obj, "status");
        try out.appendSlice(allocator, "{\"v\":1,\"source\":\"learnings\",\"event\":\"learning.capture\",\"learning_id\":");
        try appendJsonString(allocator, out, id);
        try out.appendSlice(allocator, ",\"status\":");
        try appendJsonString(allocator, out, status);
        try out.appendSlice(allocator, ",\"record\":");
        try out.appendSlice(allocator, normalized_record);
        try out.appendSlice(allocator, "}\n");
    }

    try seen_ids.put(try allocator.dupe(u8, id), {});
    return .appended;
}

fn stringifyJsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn inspectCanonicalJsonlAlloc(allocator: std.mem.Allocator, bytes: []const u8) !StoreInspection {
    var inspection = StoreInspection{};
    errdefer inspection.deinit(allocator);
    var seen_ids = std.StringHashMap(void).init(allocator);
    defer {
        var key_it = seen_ids.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        seen_ids.deinit();
    }

    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) {
            inspection.blank_lines += 1;
            continue;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try inspection.issues.append(allocator, .{ .start_line = line_number, .end_line = line_number, .reason = @errorName(err) });
                continue;
            },
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => {
                try inspection.issues.append(allocator, .{ .start_line = line_number, .end_line = line_number, .reason = "NonObjectJson" });
                continue;
            },
        };
        const id = learningIdFromObject(obj);
        if (id.len == 0) {
            try inspection.issues.append(allocator, .{ .start_line = line_number, .end_line = line_number, .reason = "MissingLearningId" });
            continue;
        }
        if (seen_ids.contains(id)) {
            try inspection.issues.append(allocator, .{ .start_line = line_number, .end_line = line_number, .reason = "DuplicateLearningId" });
            continue;
        }
        try seen_ids.put(try allocator.dupe(u8, id), {});
        inspection.records += 1;
    }
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n' and inspection.blank_lines > 0) inspection.blank_lines -= 1;
    return inspection;
}

fn inspectCanonicalSnapshotAlloc(
    allocator: std.mem.Allocator,
    snapshot: durable_store.EventSnapshot,
) !StoreInspection {
    var inspection = StoreInspection{ .blank_lines = snapshot.blank_entries };
    errdefer inspection.deinit(allocator);
    var seen_ids = std.StringHashMap(void).init(allocator);
    defer {
        var key_it = seen_ids.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        seen_ids.deinit();
    }

    for (snapshot.records) |event| {
        const line_number = event.diagnostic_position orelse @as(usize, @intCast(event.ordinal));
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, event.payload, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try inspection.issues.append(allocator, .{ .start_line = line_number, .end_line = line_number, .reason = @errorName(err) });
                continue;
            },
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => {
                try inspection.issues.append(allocator, .{ .start_line = line_number, .end_line = line_number, .reason = "NonObjectJson" });
                continue;
            },
        };
        const id = learningIdFromObject(obj);
        if (id.len == 0) {
            try inspection.issues.append(allocator, .{ .start_line = line_number, .end_line = line_number, .reason = "MissingLearningId" });
            continue;
        }
        if (seen_ids.contains(id)) {
            try inspection.issues.append(allocator, .{ .start_line = line_number, .end_line = line_number, .reason = "DuplicateLearningId" });
            continue;
        }
        try seen_ids.put(try allocator.dupe(u8, id), {});
        inspection.records += 1;
    }
    return inspection;
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
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

fn validateJsonlBytes(allocator: std.mem.Allocator, bytes: []const u8) !JsonlStats {
    var stats = JsonlStats{
        .sha256 = try sha256HexAlloc(allocator, bytes),
        .ids = std.StringHashMap([]u8).init(allocator),
    };
    errdefer stats.deinit(allocator);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) {
            stats.blank_lines += 1;
            continue;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidJsonLine;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidJsonLine,
        };
        const id = learningIdFromObject(obj);
        if (id.len == 0) return error.MissingLearningId;

        const gop = try stats.ids.getOrPut(id);
        if (gop.found_existing) return error.DuplicateLearningId;
        gop.key_ptr.* = try allocator.dupe(u8, id);
        gop.value_ptr.* = try allocator.dupe(u8, line);
        stats.records += 1;
    }
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n' and stats.blank_lines > 0) stats.blank_lines -= 1;

    return stats;
}

fn mergeJsonlBytesByIdAlloc(
    allocator: std.mem.Allocator,
    target_bytes: []const u8,
    target_stats: *JsonlStats,
    source_bytes: []const u8,
    source_stats: *JsonlStats,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, target_bytes);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');

    var lines = std.mem.splitScalar(u8, source_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidJsonLine;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidJsonLine,
        };
        const id = learningIdFromObject(obj);
        if (target_stats.ids.get(id)) |existing_line| {
            if (!std.mem.eql(u8, existing_line, source_stats.ids.get(id).?)) return error.ConflictingLearningId;
            continue;
        }
        try out.appendSlice(allocator, raw_line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn learningEventRecordObject(obj: std.json.ObjectMap) ?std.json.ObjectMap {
    if (!std.mem.eql(u8, jsonObjectString(obj, "event"), "learning.capture")) return null;
    const record_value = obj.get("record") orelse return null;
    return switch (record_value) {
        .object => |record_obj| record_obj,
        else => null,
    };
}

fn learningRecordObject(obj: std.json.ObjectMap) std.json.ObjectMap {
    return learningEventRecordObject(obj) orelse obj;
}

fn learningIdFromObject(obj: std.json.ObjectMap) []const u8 {
    if (learningEventRecordObject(obj)) |record_obj| {
        const event_id = jsonObjectString(obj, "learning_id");
        if (event_id.len > 0) return event_id;
        return jsonObjectString(record_obj, "id");
    }
    return jsonObjectString(obj, "id");
}

fn sha256HexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, hex[0..]);
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
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn appendArgsRequestHelpOrVersion(args: []const []const u8) bool {
    for (args) |arg| {
        if (core_cli.isHelpArg(arg) or core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) return true;
    }
    return false;
}

fn runAutoMemoryDigest(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    const repo_root = try discoverRepoRootAlloc(allocator, cwd);
    defer allocator.free(repo_root);
    try cmdMemoryDigest(allocator, repo_root, "", "", 12, "", codex_home, false);
}

fn mergeAppendArgsAlloc(
    allocator: std.mem.Allocator,
    path_explicit: bool,
    prefixed_path: []const u8,
    tail_args: []const []const u8,
) ![]const []const u8 {
    const tail_path = try lastPathValue(tail_args);
    if (!path_explicit) return allocator.dupe([]const u8, tail_args);
    if (tail_path) |value| {
        if (!std.mem.eql(u8, value, prefixed_path)) return error.ConflictingPathValue;
        return allocator.dupe([]const u8, tail_args);
    }

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, &.{ "--path", prefixed_path });
    try out.appendSlice(allocator, tail_args);
    return out.toOwnedSlice(allocator);
}

fn lastPathValue(args: []const []const u8) !?[]const u8 {
    var value: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--path")) continue;
        i += 1;
        if (i >= args.len) return error.MissingPathValue;
        value = args[i];
    }
    return value;
}

fn exitAppendParseError(comptime fmt: []const u8, args: anytype) noreturn {
    const surface = append_learning_cli.subcommandSurface();
    const detail = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch null;
    defer if (detail) |value| std.heap.page_allocator.free(value);
    core_cli.exitUsageFailure(.{
        .executable_name = surface.program_name,
        .help_text = surface.help_text,
    }, Version, "InvalidArgument", detail);
}

fn parsePositiveInt(text: []const u8) !usize {
    const value = std.fmt.parseInt(i64, text, 10) catch return error.InvalidPositiveInt;
    if (value < 0) return error.InvalidPositiveInt;
    return @intCast(value);
}

fn cmdDatasets(allocator: std.mem.Allocator) !void {
    var rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    try appendDatasetRow(allocator, &rows, "learnings", "Learning records from .ledger/learnings/events.jsonl (1 row per record)");
    try appendDatasetRow(allocator, &rows, "learning_paths", "Exploded context.paths (1 row per record-path)");
    try appendDatasetRow(allocator, &rows, "learning_tags", "Exploded tags (1 row per record-tag)");

    const cols = [_][]const u8{ "dataset", "description" };
    const rendered = try query_output.render(allocator, .table, rows.items, cols[0..]);
    defer allocator.free(rendered);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(rendered);
}

fn appendDatasetRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    dataset: []const u8,
    description: []const u8,
) !void {
    var row = query_engine.Row.init(allocator);
    errdefer row.deinit();

    try row.putOwnedKey("dataset", .{ .string = dataset });
    try row.putOwnedKey("description", .{ .string = description });

    try rows.append(allocator, row);
}

fn cmdDatasetSchema(allocator: std.mem.Allocator, dataset: []const u8) !void {
    _ = allocator;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, dataset, "learnings")) {
        try stdout.print("Dataset: learnings\n", .{});
        try stdout.print("Description: Learning records from .ledger/learnings/events.jsonl (1 row per record)\n", .{});
        try stdout.print("Fields:\n", .{});
        for (LearningsFields) |field| {
            try stdout.print("- {s}\n", .{field});
        }
        return;
    }

    if (std.mem.eql(u8, dataset, "learning_paths")) {
        try stdout.print("Dataset: learning_paths\n", .{});
        try stdout.print("Description: Exploded context.paths (1 row per record-path)\n", .{});
        try stdout.print("Fields:\n", .{});
        for (LearningPathsFields) |field| {
            try stdout.print("- {s}\n", .{field});
        }
        return;
    }

    if (std.mem.eql(u8, dataset, "learning_tags")) {
        try stdout.print("Dataset: learning_tags\n", .{});
        try stdout.print("Description: Exploded tags (1 row per record-tag)\n", .{});
        try stdout.print("Fields:\n", .{});
        for (LearningTagsFields) |field| {
            try stdout.print("- {s}\n", .{field});
        }
        return;
    }

    try stdout.print("Unknown dataset: {s}\n", .{dataset});
}

fn cmdQuery(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    jsonl_path: []const u8,
    spec_arg: []const u8,
) !void {
    const spec_json = parseJsonArgAlloc(allocator, repo_root, spec_arg) catch |err| {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("Invalid --spec JSON: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(spec_json);

    var parsed_spec_value = std.json.parseFromSlice(std.json.Value, allocator, spec_json, .{}) catch {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("Spec must be a JSON object.\n", .{});
        return;
    };
    defer parsed_spec_value.deinit();

    const root = switch (parsed_spec_value.value) {
        .object => |obj| obj,
        else => {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            try stdout.print("Spec must be a JSON object.\n", .{});
            return;
        },
    };

    const dataset_name = switch (root.get("dataset") orelse .null) {
        .string => |value| value,
        else => {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            try stdout.print("Spec must include dataset (string).\n", .{});
            return;
        },
    };

    const format = blk: {
        if (root.get("format")) |fmt_value| {
            const fmt_text = switch (fmt_value) {
                .string => |value| value,
                else => {
                    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                    const stdout = &stdout_writer.interface;
                    try stdout.print("Spec format must be one of: table, json, csv, jsonl.\n", .{});
                    return;
                },
            };
            break :blk query_output.Format.parse(fmt_text) catch {
                var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stdout = &stdout_writer.interface;
                try stdout.print("Spec format must be one of: table, json, csv, jsonl.\n", .{});
                return;
            };
        }

        const group_by = switch (root.get("group_by") orelse .null) {
            .array => |arr| arr.items.len,
            else => 0,
        };
        break :blk if (group_by > 0) query_output.Format.table else query_output.Format.jsonl;
    };

    var rows = collectDatasetRows(allocator, jsonl_path, dataset_name) catch {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("Unknown dataset: {s}\n", .{dataset_name});
        return;
    };
    defer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const query_spec_value = query_spec.parseQuerySpecValue(arena.allocator(), parsed_spec_value.value) catch |err| {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("Invalid --spec JSON: {s}\n", .{@errorName(err)});
        return;
    };

    var result = try query_engine.execute(allocator, rows.items, query_spec_value);
    defer result.deinit(allocator);

    const columns_opt: ?[]const []const u8 = if (query_spec_value.select.len > 0)
        query_spec_value.select
    else
        null;

    const rendered = try query_output.render(allocator, format, result.rows.items, columns_opt);
    defer allocator.free(rendered);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(rendered);
}

fn cmdRecent(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    jsonl_path: []const u8,
    limit: usize,
) !void {
    _ = repo_root;
    var rows = try collectDatasetRows(allocator, jsonl_path, "learnings");
    defer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    std.mem.sort(query_engine.Row, rows.items, {}, lessRecentRows);

    const capped = if (limit > 0 and rows.items.len > limit) rows.items[0..limit] else rows.items;

    var out_rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (out_rows.items) |*row| row.deinit();
        out_rows.deinit(allocator);
    }

    for (capped) |row| {
        var out = query_engine.Row.init(allocator);
        errdefer out.deinit();

        try out.putOwnedKey("captured_at", valueAsScalarString(row.valueOrNull("captured_at")));
        try out.putOwnedKey("status", valueAsScalarString(row.valueOrNull("status")));

        const learning = rowString(row, "learning");
        const tags = rowString(row, "tags_text");
        const paths = rowString(row, "paths_text");

        const learning_short = try shortenAlloc(allocator, learning, 120);
        defer allocator.free(learning_short);
        const tags_short = try shortenAlloc(allocator, tags, 30);
        defer allocator.free(tags_short);
        const paths_short = try shortenAlloc(allocator, paths, 40);
        defer allocator.free(paths_short);

        try out.putOwnedKey("learning", .{ .string = learning_short });
        try out.putOwnedKey("tags", .{ .string = tags_short });
        try out.putOwnedKey("paths", .{ .string = paths_short });

        try out_rows.append(allocator, out);
    }

    const cols = [_][]const u8{ "captured_at", "status", "learning", "tags", "paths" };
    const rendered = try query_output.render(allocator, .table, out_rows.items, cols[0..]);
    defer allocator.free(rendered);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(rendered);
}

fn cmdExport(
    allocator: std.mem.Allocator,
    jsonl_path: []const u8,
    source_path: []const u8,
    learning_id: []const u8,
    format: []const u8,
) !void {
    var persistence = durable_store.PersistentEventStore.init(jsonl_path);
    var snapshot = try persistence.eventStore().snapshot(allocator, MaxLearningsBytes);
    defer snapshot.deinit(allocator);

    var inspection = try inspectCanonicalSnapshotAlloc(allocator, snapshot);
    defer inspection.deinit(allocator);
    if (inspection.issues.items.len != 0) return error.StoreInvalid;

    for (snapshot.records) |event| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, event.payload, .{});
        defer parsed.deinit();
        const event_object = switch (parsed.value) {
            .object => |value| value,
            else => return error.StoreInvalid,
        };
        const record = learningRecordObject(event_object);
        if (!std.mem.eql(u8, jsonObjectString(record, "id"), learning_id)) continue;

        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        if (std.mem.eql(u8, format, "full")) {
            try std.json.Stringify.value(std.json.Value{ .object = record }, .{}, stdout);
        } else if (std.mem.eql(u8, format, "memory-note")) {
            try writeLearningMemoryNoteProjection(allocator, stdout, record, source_path);
        } else {
            return error.InvalidExportFormat;
        }
        try stdout.writeByte('\n');
        return;
    }
    return error.LearningNotFound;
}

fn writeLearningMemoryNoteProjection(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    record: std.json.ObjectMap,
    source_path: []const u8,
) !void {
    const learning_id = jsonObjectString(record, "id");
    const status = jsonObjectString(record, "status");
    const learning = jsonObjectString(record, "learning");
    const application = jsonObjectString(record, "application");
    if (learning_id.len == 0 or status.len == 0 or learning.len == 0 or application.len == 0) {
        return error.IncompleteLearningProjection;
    }

    const context = if (record.get("context")) |value| switch (value) {
        .object => |object| object,
        else => null,
    } else null;
    const repo = if (context) |object| jsonObjectString(object, "repo") else "";
    if (repo.len == 0) return error.IncompleteLearningProjection;

    const summary = try std.fmt.allocPrint(allocator, "Admit {s} for Phase 2 consideration.", .{learning_id});
    defer allocator.free(summary);
    const source_ref = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ source_path, learning_id });
    defer allocator.free(source_ref);

    try writer.writeAll("{\"operation\":\"assert\",\"authority\":\"ledger-cli\",\"summary\":");
    try writeJsonString(writer, summary);
    try writer.writeAll(",\"scope\":{\"kind\":\"repo\",\"repo\":");
    try writeJsonString(writer, repo);
    try writer.writeAll(",\"paths\":");
    if (context) |object| {
        if (object.get("paths")) |paths| try std.json.Stringify.value(paths, .{}, writer) else try writer.writeAll("[]");
    } else try writer.writeAll("[]");
    try writer.writeAll("},\"source_refs\":[{\"kind\":\"learning\",\"ref\":");
    try writeJsonString(writer, source_ref);
    try writer.writeAll(",\"summary\":\"Canonical learning row\"}],\"related_ids\":");
    if (record.get("related_ids")) |related| try std.json.Stringify.value(related, .{}, writer) else try writer.writeAll("[]");
    try writer.writeAll(",\"supersedes_id\":");
    if (record.get("supersedes_id")) |supersedes| try std.json.Stringify.value(supersedes, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"payload\":{\"learning_id\":");
    try writeJsonString(writer, learning_id);
    try writer.writeAll(",\"learning_status\":");
    try writeJsonString(writer, status);
    try writer.writeAll(",\"repo\":");
    try writeJsonString(writer, repo);
    try writer.writeAll(",\"source_path\":");
    try writeJsonString(writer, source_path);
    try writer.writeAll(",\"decision_delta\":");
    try writeJsonString(writer, learning);
    try writer.writeAll(",\"evidence_snapshot\":");
    if (record.get("evidence")) |evidence| try std.json.Stringify.value(evidence, .{}, writer) else try writer.writeAll("[]");
    try writer.writeAll(",\"future_behavior\":");
    try writeJsonString(writer, application);
    try writer.writeAll(",\"verification\":\"Re-check the canonical row and evidence snapshot before applying this learning.\",\"tags\":");
    if (record.get("tags")) |tags| try std.json.Stringify.value(tags, .{}, writer) else try writer.writeAll("[]");
    try writer.writeAll(",\"canonical_fingerprint\":");
    try writeJsonString(writer, jsonObjectString(record, "fingerprint"));
    try writer.writeAll("}}");
}

fn cmdRecall(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    jsonl_path: []const u8,
    query_text: []const u8,
    raw_paths: []const u8,
    limit: usize,
    format_text: []const u8,
    drop_superseded: bool,
) !void {
    _ = repo_root;

    if (std.mem.trim(u8, query_text, " \t\r\n").len == 0) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("error: --query is required\n", .{});
        return;
    }

    var rows = try collectDatasetRows(allocator, jsonl_path, "learnings");
    defer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    if (rows.items.len == 0) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("(no learnings file at {s})\n", .{jsonl_path});
        return;
    }

    var superseded = std.StringHashMap(void).init(allocator);
    defer deinitOwnedStringSet(allocator, &superseded);

    for (rows.items) |row| {
        const supersedes_id = rowString(row, "supersedes_id");
        if (supersedes_id.len == 0) continue;
        const key = try allocator.dupe(u8, supersedes_id);
        errdefer allocator.free(key);
        if (superseded.contains(key)) {
            allocator.free(key);
            continue;
        }
        try superseded.put(key, {});
    }

    var query_tokens = try tokenizeSet(allocator, query_text);
    defer deinitOwnedStringSet(allocator, &query_tokens);

    var query_tool_tokens = std.StringHashMap(void).init(allocator);
    defer deinitOwnedStringSet(allocator, &query_tool_tokens);

    var it_q = query_tokens.iterator();
    while (it_q.next()) |entry| {
        if (isToolKeyword(entry.key_ptr.*)) {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            if (query_tool_tokens.contains(key)) {
                allocator.free(key);
            } else {
                try query_tool_tokens.put(key, {});
            }
        }
    }

    var path_hints: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &path_hints);

    try appendPathHintsFromCsv(allocator, &path_hints, raw_paths);
    try appendPathHintsFromQuery(allocator, &path_hints, query_text);

    const now_sec = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000)));

    var candidates: std.ArrayList(RecallCandidate) = .empty;
    defer candidates.deinit(allocator);

    for (rows.items, 0..) |row, row_index| {
        const row_id = rowString(row, "id");
        if (drop_superseded and row_id.len > 0 and superseded.contains(row_id)) continue;
        const learning = rowString(row, "learning");
        const application = rowString(row, "application");
        const tags_text = rowString(row, "tags_text");
        var evidence_text = rowString(row, "evidence_text");
        if (std.mem.eql(u8, evidence_text, "none_provided")) {
            evidence_text = "";
        }

        var match_text: std.ArrayList(u8) = .empty;
        defer match_text.deinit(allocator);
        try appendJoinText(allocator, &match_text, learning);
        try appendJoinText(allocator, &match_text, application);
        try appendJoinText(allocator, &match_text, tags_text);
        try appendJoinText(allocator, &match_text, evidence_text);

        var record_tokens = try tokenizeSet(allocator, match_text.items);
        defer deinitOwnedStringSet(allocator, &record_tokens);

        const overlap = intersectionCount(&query_tokens, &record_tokens);
        const union_count = unionCount(&query_tokens, &record_tokens, overlap);
        const jaccard = if (union_count == 0) 0.0 else @as(f64, @floatFromInt(overlap)) / @as(f64, @floatFromInt(union_count));

        const tool_match: f64 = if (hasIntersection(&query_tool_tokens, &record_tokens)) 1.0 else 0.0;

        const paths_text = rowString(row, "paths_text");
        const path_match: f64 = if (containsAnyHint(paths_text, path_hints.items)) 1.0 else 0.0;

        if (overlap == 0 and tool_match == 0.0 and path_match == 0.0) continue;

        const recency = blk: {
            const captured_at = rowString(row, "captured_at");
            if (captured_at.len == 0) break :blk 0.0;
            if (parseIsoTimestampSeconds(captured_at)) |captured_sec| {
                const delta = @as(f64, @floatFromInt(@max(now_sec - captured_sec, 0)));
                const age_days = delta / 86_400.0;
                break :blk std.math.exp(-(age_days / 45.0));
            }
            break :blk 0.0;
        };

        const status_boost = statusBoost(rowString(row, "status"));
        const success_boost: f64 = if (evidence_text.len > 0) 0.5 else 0.0;

        const score =
            (3.0 * jaccard) +
            (1.5 * path_match) +
            (1.0 * tool_match) +
            (1.0 * recency) +
            (0.5 * success_boost) +
            status_boost;

        try candidates.append(allocator, .{
            .row_index = row_index,
            .score = score,
            .overlap = overlap,
            .jaccard = jaccard,
            .tool_match = tool_match,
            .path_match = path_match,
        });
    }

    std.mem.sort(RecallCandidate, candidates.items, rows.items, lessRecallCandidate);

    var kept: std.ArrayList(RecallCandidate) = .empty;
    defer kept.deinit(allocator);

    var theme_counts = std.StringHashMap(usize).init(allocator);
    defer deinitOwnedStringMapValues(allocator, &theme_counts);

    for (candidates.items) |candidate| {
        const theme = try computeThemeAlloc(
            allocator,
            rowString(rows.items[candidate.row_index], "tags_text"),
            rowString(rows.items[candidate.row_index], "learning"),
        );
        defer allocator.free(theme);

        var allow = true;
        if (theme.len > 0) {
            if (theme_counts.get(theme)) |count| {
                if (count >= 2) {
                    allow = false;
                } else {
                    const owned = try allocator.dupe(u8, theme);
                    _ = owned;
                }
            }
            if (allow) {
                if (theme_counts.getEntry(theme)) |entry| {
                    entry.value_ptr.* += 1;
                } else {
                    const owned_theme = try allocator.dupe(u8, theme);
                    errdefer allocator.free(owned_theme);
                    try theme_counts.put(owned_theme, 1);
                }
            }
        }

        if (!allow) continue;

        try kept.append(allocator, candidate);
        if (limit > 0 and kept.items.len >= limit) break;
    }

    if (kept.items.len == 0 and limit > 0 and candidates.items.len > 0) {
        try kept.append(allocator, candidates.items[0]);
    }

    if (std.ascii.eqlIgnoreCase(format_text, "json")) {
        try renderRecallJson(allocator, rows.items, kept.items);
        return;
    }

    try renderRecallTable(allocator, rows.items, kept.items);
}

fn cmdCodifyCandidates(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    jsonl_path: []const u8,
    limit: usize,
    min_count: usize,
    format_text: []const u8,
    drop_superseded: bool,
) !void {
    _ = repo_root;

    var rows = try collectDatasetRows(allocator, jsonl_path, "learnings");
    defer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    if (rows.items.len == 0) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("(no learnings file at {s})\n", .{jsonl_path});
        return;
    }

    var superseded = std.StringHashMap(void).init(allocator);
    defer deinitOwnedStringSet(allocator, &superseded);

    for (rows.items) |row| {
        const supersedes_id = rowString(row, "supersedes_id");
        if (supersedes_id.len == 0) continue;
        const key = try allocator.dupe(u8, supersedes_id);
        errdefer allocator.free(key);
        if (superseded.contains(key)) {
            allocator.free(key);
            continue;
        }
        try superseded.put(key, {});
    }

    var active_indices: std.ArrayList(usize) = .empty;
    defer active_indices.deinit(allocator);

    for (rows.items, 0..) |row, idx| {
        const row_id = rowString(row, "id");
        if (drop_superseded and row_id.len > 0 and superseded.contains(row_id)) continue;
        try active_indices.append(allocator, idx);
    }

    var groups = std.StringHashMap(std.ArrayList(usize)).init(allocator);
    defer {
        var it_groups = groups.iterator();
        while (it_groups.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        groups.deinit();
    }

    for (active_indices.items) |idx| {
        const row = rows.items[idx];
        const theme = try computeThemeAlloc(allocator, rowString(row, "learning"), rowString(row, "application"));
        defer allocator.free(theme);

        const key_value = if (theme.len == 0) "(untagged)" else theme;

        if (groups.getEntry(key_value)) |entry| {
            try entry.value_ptr.append(allocator, idx);
        } else {
            const key = try allocator.dupe(u8, key_value);
            errdefer allocator.free(key);
            var list: std.ArrayList(usize) = .empty;
            errdefer list.deinit(allocator);
            try list.append(allocator, idx);
            try groups.put(key, list);
        }
    }

    var results: std.ArrayList(CodifyCandidate) = .empty;
    defer {
        for (results.items) |*item| item.deinit(allocator);
        results.deinit(allocator);
    }

    const now_sec = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000)));

    var it = groups.iterator();
    while (it.next()) |entry| {
        const theme = entry.key_ptr.*;
        const list = entry.value_ptr.*;
        if (list.items.len == 0) continue;

        var rep_idx = list.items[0];
        var saw_codify_now = false;
        var max_impact: f64 = 0.0;

        for (list.items) |idx| {
            const row = rows.items[idx];
            const captured = rowString(row, "captured_at");
            const rep_captured = rowString(rows.items[rep_idx], "captured_at");
            if (std.mem.order(u8, captured, rep_captured) == .gt) {
                rep_idx = idx;
            }

            if (std.mem.eql(u8, rowString(row, "status"), "codify_now")) {
                saw_codify_now = true;
            }

            const impact = impactScore(
                rowString(row, "text"),
                rowString(row, "status"),
                rowString(row, "tags_text"),
            );
            if (impact > max_impact) max_impact = impact;
        }

        const count = list.items.len;
        if (count < min_count and !saw_codify_now) continue;

        const rep_row = rows.items[rep_idx];
        const last_seen = rowString(rep_row, "captured_at");

        const recency = blk: {
            if (last_seen.len == 0) break :blk 0.0;
            if (parseIsoTimestampSeconds(last_seen)) |captured_sec| {
                const delta = @as(f64, @floatFromInt(@max(now_sec - captured_sec, 0)));
                const age_days = delta / 86_400.0;
                break :blk std.math.exp(-(age_days / 60.0));
            }
            break :blk 0.0;
        };

        const score = (@as(f64, @floatFromInt(count)) * 2.0) + (recency * 2.0) + max_impact;

        const theme_short = try shortenAlloc(allocator, theme, 36);
        const learning_short = try shortenAlloc(allocator, rowString(rep_row, "learning"), 120);

        try results.append(allocator, .{
            .score = score,
            .count = count,
            .last_seen = try allocator.dupe(u8, last_seen),
            .status = try allocator.dupe(u8, rowString(rep_row, "status")),
            .theme = theme_short,
            .learning = learning_short,
        });
    }

    std.mem.sort(CodifyCandidate, results.items, {}, lessCodifyCandidate);

    const capped = if (limit > 0 and results.items.len > limit) results.items[0..limit] else results.items;

    if (std.ascii.eqlIgnoreCase(format_text, "json")) {
        try renderCodifyJson(allocator, capped);
        return;
    }

    try renderCodifyTable(allocator, capped);
}

fn cmdQualityAudit(
    allocator: std.mem.Allocator,
    jsonl_path: []const u8,
    since: []const u8,
    until: []const u8,
    format_text: []const u8,
    output_path: []const u8,
) !void {
    const format = query_output.Format.parse(format_text) catch {
        try renderErrorLine("error: --format must be one of: table, json, csv, jsonl\n", .{});
        return;
    };

    var rows = try collectDatasetRows(allocator, jsonl_path, "learnings");
    defer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    var counts = QualityCounts{};

    var status_counts = std.StringHashMap(usize).init(allocator);
    defer deinitOwnedStringMapValues(allocator, &status_counts);

    var day_counts = std.StringHashMap(usize).init(allocator);
    defer deinitOwnedStringMapValues(allocator, &day_counts);

    var fingerprint_counts = std.StringHashMap(usize).init(allocator);
    defer deinitOwnedStringMapValues(allocator, &fingerprint_counts);

    for (rows.items) |row| {
        const day = rowString(row, "day");
        if (!inDateWindow(day, since, until)) continue;

        counts.total_records += 1;
        if (hasMissingRequiredKey(row)) counts.required_key_missing_count += 1;
        if (std.mem.trim(u8, rowString(row, "application"), " \t\r\n").len == 0) {
            counts.missing_application_count += 1;
        }

        const evidence_count = scalarAsInt(row.valueOrNull("evidence_count"));
        const evidence_text = rowString(row, "evidence_text");
        if (evidence_count == 0 or std.mem.trim(u8, evidence_text, " \t\r\n").len == 0) {
            counts.missing_or_empty_evidence_count += 1;
        }

        if (isConditionActionLearning(rowString(row, "learning"))) {
            counts.condition_action_count += 1;
        }
        if (evidenceHasAnchor(evidence_text)) {
            counts.evidence_anchor_count += 1;
        }

        const status = rowString(row, "status");
        if (status.len > 0) {
            try incrementCount(&status_counts, allocator, status);
        }
        if (day.len > 0) {
            try incrementCount(&day_counts, allocator, day);
        }

        const fingerprint = rowString(row, "fingerprint");
        if (fingerprint.len > 0) {
            try incrementCount(&fingerprint_counts, allocator, fingerprint);
        }
    }

    var fp_it = fingerprint_counts.iterator();
    while (fp_it.next()) |entry| {
        if (entry.value_ptr.* > 1) counts.fingerprint_duplicate_groups += 1;
    }

    const condition_rate = ratioAsPercent(counts.condition_action_count, counts.total_records);
    const anchor_rate = ratioAsPercent(counts.evidence_anchor_count, counts.total_records);

    var out_rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (out_rows.items) |*row| row.deinit();
        out_rows.deinit(allocator);
    }

    try appendMetricValueRow(allocator, &out_rows, "total_records", counts.total_records);
    try appendMetricValueRow(allocator, &out_rows, "required_key_missing_count", counts.required_key_missing_count);
    try appendMetricValueRow(allocator, &out_rows, "missing_application_count", counts.missing_application_count);
    try appendMetricValueRow(allocator, &out_rows, "missing_or_empty_evidence_count", counts.missing_or_empty_evidence_count);
    try appendMetricFloatRow(allocator, &out_rows, "condition_action_rate_pct", condition_rate);
    try appendMetricFloatRow(allocator, &out_rows, "evidence_anchor_rate_pct", anchor_rate);
    try appendMetricValueRow(allocator, &out_rows, "fingerprint_duplicate_groups", counts.fingerprint_duplicate_groups);

    try appendGroupedCountsRows(allocator, &out_rows, &status_counts, "status_count");
    try appendGroupedCountsRows(allocator, &out_rows, &day_counts, "daily_count");

    if (counts.total_records == 0) {
        try appendMetricTextRow(allocator, &out_rows, "confidence_note", "no_records_in_window");
    } else {
        if (counts.total_records < 10) {
            try appendMetricTextRow(allocator, &out_rows, "confidence_note", "small_sample");
        }
        if (counts.required_key_missing_count > 0) {
            try appendMetricTextRow(allocator, &out_rows, "confidence_note", "required_key_gaps_present");
        }
        if (counts.missing_or_empty_evidence_count > 0) {
            try appendMetricTextRow(allocator, &out_rows, "confidence_note", "evidence_gaps_present");
        }
    }

    const cols = [_][]const u8{ "metric", "value" };
    const rendered = try query_output.render(allocator, format, out_rows.items, cols[0..]);
    defer allocator.free(rendered);
    try emitOutput(output_path, rendered);
}

fn cmdValueReport(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    jsonl_path: []const u8,
    sessions_root_raw: []const u8,
    since: []const u8,
    until: []const u8,
    comparator_text: []const u8,
    format_text: []const u8,
    output_path: []const u8,
) !void {
    _ = jsonl_path;

    const format = query_output.Format.parse(format_text) catch {
        try renderErrorLine("error: --format must be one of: table, json, csv, jsonl\n", .{});
        return;
    };

    const comparator = parseComparator(comparator_text) catch {
        try renderErrorLine("error: --comparator must be one of: learnings_nonrecall, impl_nonrecall, all_nonrecall\n", .{});
        return;
    };

    const sessions_root = try resolveSessionsRootAlloc(allocator, repo_root, sessions_root_raw);
    defer allocator.free(sessions_root);

    var sessions = try collectSessionSummaries(allocator, sessions_root, since, until, comparator);
    defer {
        for (sessions.items) |entry| entry.deinit(allocator);
        sessions.deinit(allocator);
    }

    var primary_idxs: std.ArrayList(usize) = .empty;
    defer primary_idxs.deinit(allocator);

    var comparator_idxs: std.ArrayList(usize) = .empty;
    defer comparator_idxs.deinit(allocator);

    for (sessions.items, 0..) |entry, idx| {
        if (entry.has_recall) try primary_idxs.append(allocator, idx);

        if (entry.has_recall) continue;
        switch (comparator) {
            .learnings_nonrecall => if (entry.has_learnings) try comparator_idxs.append(allocator, idx),
            .impl_nonrecall => if (entry.has_impl) try comparator_idxs.append(allocator, idx),
            .all_nonrecall => try comparator_idxs.append(allocator, idx),
        }
    }

    const primary = computeCohortStats(allocator, sessions.items, primary_idxs.items);
    const comparator_stats = computeCohortStats(allocator, sessions.items, comparator_idxs.items);

    const rel_duration = relativeDelta(primary.duration_median_min, comparator_stats.duration_median_min);
    const rel_proof = relativeDelta(primary.proof_rate, comparator_stats.proof_rate);
    const rel_friction = relativeDelta(primary.friction_rate, comparator_stats.friction_rate);

    var recommendation: []const u8 = "keep_policy";
    if (primary.n == 0 or comparator_stats.n == 0) {
        recommendation = "insufficient_data";
    } else if (exceedsRecommendationThreshold(rel_duration, rel_proof, rel_friction)) {
        recommendation = "review_policy";
    }

    var out_rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (out_rows.items) |*row| row.deinit();
        out_rows.deinit(allocator);
    }

    try appendValueReportRow(allocator, &out_rows, "window_since", since, "", "");
    try appendValueReportRow(allocator, &out_rows, "window_until", until, "", "");
    try appendValueReportRow(allocator, &out_rows, "cohort_primary", "recall_loaded", "", "");
    try appendValueReportRow(allocator, &out_rows, "cohort_comparator", comparatorLabel(comparator), "", "");

    try appendValueReportIntRow(allocator, &out_rows, "n_primary", primary.n, comparator_stats.n);
    try appendValueReportOptionalFloatRow(allocator, &out_rows, "duration_median_primary_min", primary.duration_median_min, comparator_stats.duration_median_min);
    try appendValueReportOptionalFloatRow(allocator, &out_rows, "duration_p90_primary_min", primary.duration_p90_min, comparator_stats.duration_p90_min);
    try appendValueReportOptionalFloatRow(allocator, &out_rows, "proof_rate_primary", primary.proof_rate, comparator_stats.proof_rate);
    try appendValueReportOptionalFloatRow(allocator, &out_rows, "friction_rate_primary", primary.friction_rate, comparator_stats.friction_rate);
    try appendValueReportOptionalFloatRow(allocator, &out_rows, "recall_load_delta_median_min", primary.recall_delta_median_min, null);

    try appendValueReportDeltaRow(allocator, &out_rows, "relative_delta_duration", rel_duration);
    try appendValueReportDeltaRow(allocator, &out_rows, "relative_delta_proof", rel_proof);
    try appendValueReportDeltaRow(allocator, &out_rows, "relative_delta_friction", rel_friction);
    try appendValueReportRow(allocator, &out_rows, "comparator_fallback_used", "false", "", "");
    try appendValueReportRow(allocator, &out_rows, "policy_recommendation", recommendation, "", "");

    if (comparator_stats.n < 10) {
        try appendValueReportRow(allocator, &out_rows, "confidence_note", "small_comparator_sample", "", "");
    }
    if (primary.n == 0) {
        try appendValueReportRow(allocator, &out_rows, "confidence_note", "no_recall_sessions_in_window", "", "");
    }

    const cols = [_][]const u8{ "metric", "primary", "comparator", "delta" };
    const rendered = try query_output.render(allocator, format, out_rows.items, cols[0..]);
    defer allocator.free(rendered);
    try emitOutput(output_path, rendered);
}

fn cmdMemoryDigest(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    scan_root_raw: []const u8,
    since: []const u8,
    limit_candidates: usize,
    output_path_raw: []const u8,
    codex_home: []const u8,
    emit_summary: bool,
) !void {
    var source_files = try collectLearningFiles(allocator, repo_root, scan_root_raw);
    defer freeOwnedStringList(allocator, &source_files);

    var rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    for (source_files.items) |path| {
        var file_rows = try collectDigestRows(allocator, path);
        defer file_rows.deinit(allocator);
        try rows.appendSlice(allocator, file_rows.items);
        file_rows.clearRetainingCapacity();
    }

    var candidates = try buildDigestCandidates(allocator, rows.items, since, if (limit_candidates == 0) 12 else limit_candidates);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    const generated_at = try nowUtcAlloc(allocator);
    defer allocator.free(generated_at);

    const output_path = if (output_path_raw.len > 0)
        try resolveDigestOutputPathAlloc(allocator, repo_root, output_path_raw)
    else
        try defaultDigestOutputPathAlloc(allocator, codex_home);
    defer allocator.free(output_path);

    const digest = try renderMemoryDigestAlloc(allocator, generated_at, source_files.items, rows.items, candidates.items);
    defer allocator.free(digest);

    try writeTextFile(output_path, digest);

    if (emit_summary) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("memory-digest: wrote {s} candidates={d} sources={d}\n", .{ output_path, candidates.items.len, source_files.items.len });
    }
}

fn collectLearningFiles(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    scan_root_raw: []const u8,
) !std.ArrayList([]u8) {
    var files: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedStringList(allocator, &files);

    var seen = std.StringHashMap(void).init(allocator);
    defer deinitOwnedStringSet(allocator, &seen);

    if (scan_root_raw.len > 0) {
        var parts = std.mem.splitScalar(u8, scan_root_raw, ',');
        while (parts.next()) |raw_part| {
            const trimmed = std.mem.trim(u8, raw_part, " \t\r\n");
            if (trimmed.len == 0) continue;
            const root_abs = try resolveDigestScanRootAlloc(allocator, repo_root, trimmed);
            defer allocator.free(root_abs);
            try collectLearningFilesUnder(allocator, &files, &seen, root_abs, 8);
        }
    } else {
        const home = std.Io.Threaded.global_single_threaded.environString("HOME") orelse return error.MissingHomeEnv;
        const workspace = try std.fmt.allocPrint(allocator, "{s}/workspace", .{home});
        defer allocator.free(workspace);
        try collectLearningFilesUnder(allocator, &files, &seen, workspace, 3);

        const dotfiles = try std.fmt.allocPrint(allocator, "{s}/.dotfiles", .{home});
        defer allocator.free(dotfiles);
        try collectLearningFilesUnder(allocator, &files, &seen, dotfiles, 4);

        try collectLearningFilesUnder(allocator, &files, &seen, repo_root, 4);
    }

    std.mem.sort([]u8, files.items, {}, lessStringAsc);
    return files;
}

fn collectLearningFilesUnder(
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]u8),
    seen: *std.StringHashMap(void),
    root_abs: []const u8,
    max_depth: usize,
) !void {
    if (std.mem.endsWith(u8, root_abs, "/" ++ DefaultLearningsPath) or std.mem.endsWith(u8, root_abs, "/" ++ LegacyLearningsPath)) {
        try appendUniqueLearningFile(allocator, files, seen, root_abs);
        return;
    }

    const direct_next_learning_file = try std.fs.path.join(allocator, &.{ root_abs, DefaultLearningsPath });
    defer allocator.free(direct_next_learning_file);
    if (fileExistsAbsolute(direct_next_learning_file)) {
        try appendUniqueLearningFile(allocator, files, seen, direct_next_learning_file);
    }

    const direct_learning_file = try std.fs.path.join(allocator, &.{ root_abs, LegacyLearningsPath });
    defer allocator.free(direct_learning_file);
    if (fileExistsAbsolute(direct_learning_file)) {
        try appendUniqueLearningFile(allocator, files, seen, direct_learning_file);
    }
    if (pathHasGitMarker(root_abs)) return;

    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), root_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(std.Io.Threaded.global_single_threaded.io());

    var iter = dir.iterate();
    while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .directory) continue;
        if (max_depth == 0 or shouldSkipDigestScanDir(entry.name)) continue;

        const child = try std.fs.path.join(allocator, &.{ root_abs, entry.name });
        defer allocator.free(child);
        try collectLearningFilesUnder(allocator, files, seen, child, max_depth - 1);
    }
}

fn fileExistsAbsolute(path: []const u8) bool {
    return durable_store.fileExists(path);
}

fn appendUniqueLearningFile(
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]u8),
    seen: *std.StringHashMap(void),
    raw_path: []const u8,
) !void {
    const canonical = blk: {
        const resolved = std.Io.Dir.realPathFileAbsoluteAlloc(std.Io.Threaded.global_single_threaded.io(), raw_path, allocator) catch null;
        if (resolved) |value| {
            defer allocator.free(value);
            break :blk try allocator.dupe(u8, value);
        }
        break :blk try allocator.dupe(u8, raw_path);
    };
    errdefer allocator.free(canonical);

    if (seen.contains(canonical)) {
        allocator.free(canonical);
        return;
    }

    const key = try allocator.dupe(u8, canonical);
    errdefer allocator.free(key);
    try seen.put(key, {});
    try files.append(allocator, canonical);
}

fn shouldSkipDigestScanDir(name: []const u8) bool {
    const skipped = [_][]const u8{
        ".git",
        ".hg",
        ".svn",
        ".zig-cache",
        "zig-out",
        "node_modules",
        ".venv",
        ".direnv",
        ".cache",
        "target",
        "vendor",
        "build",
        "dist",
        "Library",
    };
    for (skipped) |item| {
        if (std.mem.eql(u8, name, item)) return true;
    }
    return false;
}

fn buildDigestCandidates(
    allocator: std.mem.Allocator,
    rows: []const query_engine.Row,
    since: []const u8,
    limit: usize,
) !std.ArrayList(DigestCandidate) {
    var groups = std.StringHashMap(DigestGroupAccumulator).init(allocator);
    defer {
        var it_groups = groups.iterator();
        while (it_groups.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        groups.deinit();
    }

    for (rows, 0..) |row, idx| {
        if (!digestEligible(row)) continue;
        if (!inDateWindow(rowString(row, "day"), since, "")) continue;

        const theme = try computeThemeAlloc(allocator, rowString(row, "tags_text"), rowString(row, "learning"));
        defer allocator.free(theme);
        const theme_key = if (theme.len == 0) "(untagged)" else theme;

        const gop = try groups.getOrPut(theme_key);
        if (!gop.found_existing) {
            const owned_key = try allocator.dupe(u8, theme_key);
            errdefer allocator.free(owned_key);
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.score += digestRowScore(row);
        try gop.value_ptr.indices.append(allocator, idx);
    }

    var out: std.ArrayList(DigestCandidate) = .empty;
    errdefer {
        for (out.items) |*candidate| candidate.deinit(allocator);
        out.deinit(allocator);
    }

    var it = groups.iterator();
    while (it.next()) |entry| {
        const source_indices = entry.value_ptr.indices.items;
        const take = @min(source_indices.len, 8);
        const indices = try allocator.dupe(usize, source_indices[0..take]);
        errdefer allocator.free(indices);
        try out.append(allocator, .{
            .score = entry.value_ptr.score + @as(f64, @floatFromInt(source_indices.len)),
            .theme = try allocator.dupe(u8, entry.key_ptr.*),
            .indices = indices,
        });
    }

    std.mem.sort(DigestCandidate, out.items, {}, lessDigestCandidate);
    if (limit > 0 and out.items.len > limit) {
        for (out.items[limit..]) |*candidate| candidate.deinit(allocator);
        out.shrinkRetainingCapacity(limit);
    }
    return out;
}

fn digestEligible(row: query_engine.Row) bool {
    const status = rowString(row, "status");
    if (std.mem.eql(u8, status, "codify_now")) return true;
    if (std.mem.eql(u8, status, "avoid_for_now")) return evidenceHasAnchor(rowString(row, "evidence_text"));
    if (std.mem.eql(u8, status, "review_later")) {
        return evidenceHasAnchor(rowString(row, "evidence_text")) or scalarAsInt(row.valueOrNull("paths_count")) > 0;
    }
    return false;
}

fn digestStatusMaybeEligible(status: []const u8) bool {
    return std.mem.eql(u8, status, "codify_now") or
        std.mem.eql(u8, status, "avoid_for_now") or
        std.mem.eql(u8, status, "review_later");
}

fn digestRowScore(row: query_engine.Row) f64 {
    var score = impactScore(rowString(row, "text"), rowString(row, "status"), rowString(row, "tags_text"));
    if (std.mem.eql(u8, rowString(row, "status"), "codify_now")) score += 5.0;
    if (std.mem.eql(u8, rowString(row, "status"), "avoid_for_now")) score += 3.0;
    if (std.mem.eql(u8, rowString(row, "status"), "review_later")) score += 1.0;
    if (evidenceHasAnchor(rowString(row, "evidence_text"))) score += 1.0;
    score += @as(f64, @floatFromInt(scalarAsInt(row.valueOrNull("paths_count")))) * 0.05;
    return score;
}

fn lessDigestCandidate(_: void, a: DigestCandidate, b: DigestCandidate) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.theme, b.theme) == .lt;
}

fn renderMemoryDigestAlloc(
    allocator: std.mem.Allocator,
    generated_at: []const u8,
    source_files: []const []u8,
    rows: []const query_engine.Row,
    candidates: []const DigestCandidate,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try appendFmt(allocator, &out,
        \\# Learnings Digest
        \\
        \\generated_at: {s}
        \\generator: ledger memory-digest --source learnings
        \\source: .ledger/learnings/events.jsonl
        \\source_repo: multiple
        \\source_count: {d}
        \\source_branch_policy: preserve per-entry branch; do not globalize branch-local guidance
        \\digest_kind: candidate evidence for Codex Phase 2 memory consolidation
        \\canonical: false
        \\
        \\This file is a generated, disposable resource for the `learnings` memory
        \\extension. It is not durable memory. Promote only entries that pass the
        \\decision-delta, evidence-anchor, scope, and actionability gates.
        \\
        \\Do not copy this file wholesale into MEMORY.md. Use it to decide which
        \\repo-scoped memories, failure shields, verification routes, or skills deserve
        \\promotion.
        \\
        \\## Selection policy used
        \\
        \\- Included `codify_now` entries.
        \\- Included `avoid_for_now` and `review_later` entries only when they carry concrete evidence anchors or path scope.
        \\- Clustered near-duplicates by task family.
        \\- Compressed command/path evidence into the smallest discriminative anchors.
        \\- Preserved repo and branch scope per entry.
        \\
        \\## Source files
        \\
    , .{ generated_at, source_files.len });

    if (source_files.len == 0) {
        try out.appendSlice(allocator, "- none\n");
    } else {
        for (source_files) |path| {
            try appendFmt(allocator, &out, "- `{s}`\n", .{path});
        }
    }

    try out.appendSlice(allocator, "\n## Promotion candidates\n\n");
    if (candidates.len == 0) {
        try out.appendSlice(allocator, "No promotion candidates matched this digest policy.\n");
        return out.toOwnedSlice(allocator);
    }

    for (candidates, 0..) |candidate, idx| {
        try renderDigestCandidate(allocator, &out, rows, candidate, idx + 1);
    }

    try out.appendSlice(allocator,
        \\## Generator recommendations
        \\
        \\- Keep the digest disposable; promote only the condensed memory guidance.
        \\- Re-run `ledger memory-digest --source learnings` after append-heavy work before memory consolidation.
        \\- Use `--scan-root` to narrow a consolidation pass when a repo family needs focused review.
        \\
    );

    return out.toOwnedSlice(allocator);
}

fn renderDigestCandidate(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rows: []const query_engine.Row,
    candidate: DigestCandidate,
    ordinal: usize,
) !void {
    const rep = rows[candidate.indices[0]];
    const title = try digestTitleAlloc(allocator, rep, candidate.theme);
    defer allocator.free(title);

    var repos: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &repos);
    var branches: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &branches);
    var statuses: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &statuses);
    var ids: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &ids);
    var anchors: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &anchors);

    for (candidate.indices) |idx| {
        const row = rows[idx];
        try appendUniqueTrimmed(allocator, &repos, rowString(row, "repo"));
        try appendUniqueTrimmed(allocator, &branches, rowString(row, "branch"));
        try appendUniqueTrimmed(allocator, &statuses, rowString(row, "status"));
        try appendUniqueTrimmed(allocator, &ids, rowString(row, "id"));
        try appendEvidenceAnchors(allocator, &anchors, rowString(row, "evidence_text"), rowString(row, "paths_text"), 5);
    }

    const priority = digestPriority(rows, candidate.indices);
    const repo_scope = try joinOrFallbackAlloc(allocator, repos.items, "unknown");
    defer allocator.free(repo_scope);
    const branch_scope = try joinOrFallbackAlloc(allocator, branches.items, "unknown");
    defer allocator.free(branch_scope);
    const status_mix = try joinOrFallbackAlloc(allocator, statuses.items, "unknown");
    defer allocator.free(status_mix);

    try appendFmt(allocator, out,
        \\### P{d}: {s}
        \\
        \\priority: {s}
        \\suggested_target: MEMORY.md
        \\scope: repo={s}; branch={s}
        \\confidence: candidate
        \\status_mix: {s}
        \\supporting_learning_ids:
        \\
    , .{ ordinal, title, priority, repo_scope, branch_scope, status_mix });

    for (ids.items) |id| {
        try appendFmt(allocator, out, "- {s}\n", .{id});
    }

    try out.appendSlice(allocator, "\ndecision_delta:\n");
    try appendDigestBulletsFromRows(allocator, out, rows, candidate.indices, "learning", 3, false);

    try out.appendSlice(allocator, "\nevidence_anchors:\n");
    if (anchors.items.len == 0) {
        try out.appendSlice(allocator, "- none\n");
    } else {
        for (anchors.items) |anchor| {
            try appendFmt(allocator, out, "- `{s}`\n", .{anchor});
        }
    }

    try out.appendSlice(allocator, "\nproposed_memory_guidance:\n");
    try appendDigestBulletsFromRows(allocator, out, rows, candidate.indices, "application", 3, false);

    if (hasStatus(rows, candidate.indices, "review_later") or hasStatus(rows, candidate.indices, "avoid_for_now")) {
        try out.appendSlice(allocator, "\nfailure_shields:\n");
        try appendDigestBulletsFromRows(allocator, out, rows, candidate.indices, "learning", 2, true);
    }

    const summary = try shortenAlloc(allocator, rowString(rep, "learning"), 220);
    defer allocator.free(summary);
    try appendFmt(allocator, out,
        \\
        \\memory_summary_candidate:
        \\- In {s}, {s}
        \\
        \\---
        \\
        \\
    , .{ repo_scope, summary });
}

fn digestTitleAlloc(allocator: std.mem.Allocator, row: query_engine.Row, theme: []const u8) ![]u8 {
    const learning = rowString(row, "learning");
    if (learning.len > 0) return shortenAlloc(allocator, learning, 86);
    if (theme.len > 0) return shortenAlloc(allocator, theme, 86);
    return allocator.dupe(u8, "Untitled learning cluster");
}

fn digestPriority(rows: []const query_engine.Row, indices: []const usize) []const u8 {
    if (hasStatus(rows, indices, "codify_now")) return "high";
    if (hasStatus(rows, indices, "avoid_for_now")) return "medium-high";
    if (indices.len >= 3) return "medium-high";
    return "medium";
}

fn hasStatus(rows: []const query_engine.Row, indices: []const usize, status: []const u8) bool {
    for (indices) |idx| {
        if (std.mem.eql(u8, rowString(rows[idx], "status"), status)) return true;
    }
    return false;
}

fn appendDigestBulletsFromRows(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rows: []const query_engine.Row,
    indices: []const usize,
    field: []const u8,
    limit: usize,
    failure_shield: bool,
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer deinitOwnedStringSet(allocator, &seen);

    var emitted: usize = 0;
    for (indices) |idx| {
        if (limit > 0 and emitted >= limit) break;
        const raw = std.mem.trim(u8, rowString(rows[idx], field), " \t\r\n");
        if (raw.len == 0) continue;
        const shortened = try shortenAlloc(allocator, raw, 260);
        defer allocator.free(shortened);
        if (seen.contains(shortened)) continue;
        const key = try allocator.dupe(u8, shortened);
        errdefer allocator.free(key);
        try seen.put(key, {});
        if (failure_shield) {
            try appendFmt(allocator, out, "- If this recurs, preserve the scoped rule: {s}\n", .{shortened});
        } else {
            try appendFmt(allocator, out, "- {s}\n", .{shortened});
        }
        emitted += 1;
    }

    if (emitted == 0) try out.appendSlice(allocator, "- none\n");
}

fn appendEvidenceAnchors(
    allocator: std.mem.Allocator,
    anchors: *std.ArrayList([]u8),
    evidence_text: []const u8,
    paths_text: []const u8,
    limit: usize,
) !void {
    var evidence_parts = std.mem.splitScalar(u8, evidence_text, '\n');
    while (evidence_parts.next()) |part| {
        if (limit > 0 and anchors.items.len >= limit) return;
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none_provided")) continue;
        if (!evidenceHasAnchor(trimmed)) continue;
        const shortened = try sanitizeMarkdownCodeAlloc(allocator, trimmed, 120);
        defer allocator.free(shortened);
        try appendUniqueTrimmed(allocator, anchors, shortened);
    }

    var path_parts = std.mem.splitScalar(u8, paths_text, ',');
    while (path_parts.next()) |part| {
        if (limit > 0 and anchors.items.len >= limit) return;
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        const shortened = try sanitizeMarkdownCodeAlloc(allocator, trimmed, 120);
        defer allocator.free(shortened);
        try appendUniqueTrimmed(allocator, anchors, shortened);
    }
}

fn appendUniqueTrimmed(allocator: std.mem.Allocator, items: *std.ArrayList([]u8), raw: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return;
    for (items.items) |existing| {
        if (std.mem.eql(u8, existing, trimmed)) return;
    }
    try items.append(allocator, try allocator.dupe(u8, trimmed));
}

fn sanitizeMarkdownCodeAlloc(allocator: std.mem.Allocator, raw: []const u8, max_len: usize) ![]u8 {
    const shortened = try shortenAlloc(allocator, raw, max_len);
    defer allocator.free(shortened);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (shortened) |char| {
        try out.append(allocator, if (char == '`') '\'' else char);
    }
    return out.toOwnedSlice(allocator);
}

fn joinOrFallbackAlloc(allocator: std.mem.Allocator, items: []const []u8, fallback: []const u8) ![]u8 {
    if (items.len == 0) return allocator.dupe(u8, fallback);
    return std.mem.join(allocator, ", ", items);
}

fn resolveDigestScanRootAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    raw_root: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(raw_root)) return allocator.dupe(u8, raw_root);
    return std.fs.path.join(allocator, &.{ repo_root, raw_root });
}

fn resolveDigestOutputPathAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    raw_path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) return allocator.dupe(u8, raw_path);
    return std.fs.path.join(allocator, &.{ repo_root, raw_path });
}

fn defaultDigestOutputPathAlloc(allocator: std.mem.Allocator, codex_home_raw: []const u8) ![]u8 {
    const codex_home = std.mem.trim(u8, codex_home_raw, " \t\r\n");
    if (codex_home.len > 0) {
        return std.fs.path.join(allocator, &.{ codex_home, "memories", "extensions", "learnings", "resources", "latest_learnings_digest.md" });
    }
    const home = std.Io.Threaded.global_single_threaded.environString("HOME") orelse return error.MissingHomeEnv;
    return std.fs.path.join(allocator, &.{ home, ".codex", "memories", "extensions", "learnings", "resources", "latest_learnings_digest.md" });
}

fn appendFmt(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn writeTextFile(path: []const u8, text: []const u8) !void {
    return durable_store.writeTextAtomic(std.heap.page_allocator, path, text);
}

fn nowUtcAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now = std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io());
    const seconds = @as(i64, @intCast(@divFloor(now.nanoseconds, 1_000_000_000)));
    var days = @divFloor(seconds, 86_400);
    var seconds_of_day = seconds - days * 86_400;
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

const CivilDate = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days_since_unix_epoch: i64) CivilDate {
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

fn collectDigestRows(
    allocator: std.mem.Allocator,
    jsonl_path: []const u8,
) !std.ArrayList(query_engine.Row) {
    var rows: std.ArrayList(query_engine.Row) = .empty;
    var persistence = durable_store.PersistentEventStore.init(jsonl_path);
    var snapshot = try persistence.eventStore().snapshot(allocator, MaxLearningsBytes);
    defer snapshot.deinit(allocator);

    for (snapshot.records) |event| {
        const line = event.payload;
        if (!rawLineDigestStatusMaybeEligible(line)) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const parsed_obj = switch (parsed.value) {
            .object => |value| value,
            else => continue,
        };
        const obj = learningRecordObject(parsed_obj);

        const status = jsonObjectString(obj, "status");
        if (!digestStatusMaybeEligible(status)) continue;

        const evidence = jsonArrayStringsAlloc(allocator, obj.get("evidence"));
        defer freeOwnedSlice(allocator, evidence);
        const tags = jsonArrayStringsAlloc(allocator, obj.get("tags"));
        defer freeOwnedSlice(allocator, tags);

        var repo: []u8 = &.{};
        var branch: []u8 = &.{};
        var paths = std.ArrayList([]u8).empty;
        defer freeOwnedStringList(allocator, &paths);

        if (obj.get("context")) |context_value| {
            if (context_value == .object) {
                const context = context_value.object;
                repo = try allocator.dupe(u8, jsonObjectString(context, "repo"));
                branch = try allocator.dupe(u8, jsonObjectString(context, "branch"));
                paths = jsonArrayStringsListAlloc(allocator, context.get("paths")) catch .empty;
            }
        }
        defer allocator.free(repo);
        defer allocator.free(branch);

        const evidence_text = try joinLinesAlloc(allocator, evidence);
        defer allocator.free(evidence_text);
        const tags_text = try joinCsvAlloc(allocator, tags);
        defer allocator.free(tags_text);
        const paths_text = try joinCsvAlloc(allocator, paths.items);
        defer allocator.free(paths_text);

        const paths_count = paths.items.len;
        if (std.mem.eql(u8, status, "review_later") and !evidenceHasAnchor(evidence_text) and paths_count == 0) continue;
        if (std.mem.eql(u8, status, "avoid_for_now") and !evidenceHasAnchor(evidence_text)) continue;

        const captured_at = jsonObjectString(obj, "captured_at");
        const learning = jsonObjectString(obj, "learning");
        const application = jsonObjectString(obj, "application");

        var text_builder: std.ArrayList(u8) = .empty;
        defer text_builder.deinit(allocator);
        try appendJoinText(allocator, &text_builder, learning);
        try appendJoinText(allocator, &text_builder, application);
        try appendJoinText(allocator, &text_builder, evidence_text);
        try appendJoinText(allocator, &text_builder, tags_text);

        var row = query_engine.Row.init(allocator);
        errdefer row.deinit();
        try row.putOwnedKey("id", .{ .string = jsonObjectString(obj, "id") });
        try row.putOwnedKey("captured_at", .{ .string = captured_at });
        try row.putOwnedKey("day", .{ .string = dayLabel(captured_at) });
        try row.putOwnedKey("status", .{ .string = status });
        try row.putOwnedKey("learning", .{ .string = learning });
        try row.putOwnedKey("application", .{ .string = application });
        try row.putOwnedKey("source", .{ .string = jsonObjectString(obj, "source") });
        try row.putOwnedKey("fingerprint", .{ .string = jsonObjectString(obj, "fingerprint") });
        try row.putOwnedKey("repo", .{ .string = repo });
        try row.putOwnedKey("branch", .{ .string = branch });
        try row.putOwnedKey("tags_text", .{ .string = tags_text });
        try row.putOwnedKey("paths_text", .{ .string = paths_text });
        try row.putOwnedKey("paths_count", .{ .int = @intCast(paths_count) });
        try row.putOwnedKey("evidence_text", .{ .string = evidence_text });
        try row.putOwnedKey("evidence_count", .{ .int = @intCast(evidence.len) });
        try row.putOwnedKey("text", .{ .string = text_builder.items });

        try rows.append(allocator, row);
    }

    return rows;
}

fn rawLineDigestStatusMaybeEligible(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"status\":\"codify_now\"") != null or
        std.mem.indexOf(u8, line, "\"status\":\"avoid_for_now\"") != null or
        std.mem.indexOf(u8, line, "\"status\":\"review_later\"") != null;
}

fn parseComparator(text: []const u8) !Comparator {
    if (std.ascii.eqlIgnoreCase(text, "learnings_nonrecall")) return .learnings_nonrecall;
    if (std.ascii.eqlIgnoreCase(text, "impl_nonrecall")) return .impl_nonrecall;
    if (std.ascii.eqlIgnoreCase(text, "all_nonrecall")) return .all_nonrecall;
    return error.InvalidComparator;
}

fn comparatorLabel(comparator: Comparator) []const u8 {
    return switch (comparator) {
        .learnings_nonrecall => "learnings_nonrecall",
        .impl_nonrecall => "impl_nonrecall",
        .all_nonrecall => "all_nonrecall",
    };
}

fn hasMissingRequiredKey(row: query_engine.Row) bool {
    if (std.mem.trim(u8, rowString(row, "id"), " \t\r\n").len == 0) return true;
    if (std.mem.trim(u8, rowString(row, "captured_at"), " \t\r\n").len == 0) return true;
    if (std.mem.trim(u8, rowString(row, "status"), " \t\r\n").len == 0) return true;
    if (std.mem.trim(u8, rowString(row, "learning"), " \t\r\n").len == 0) return true;
    if (std.mem.trim(u8, rowString(row, "application"), " \t\r\n").len == 0) return true;
    if (std.mem.trim(u8, rowString(row, "source"), " \t\r\n").len == 0) return true;
    if (std.mem.trim(u8, rowString(row, "fingerprint"), " \t\r\n").len == 0) return true;
    if (scalarAsInt(row.valueOrNull("evidence_count")) == 0) return true;
    return false;
}

fn scalarAsInt(value: query_spec.Scalar) usize {
    return switch (value) {
        .int => |v| if (v < 0) 0 else @intCast(v),
        .float => |v| if (v < 0) 0 else @intFromFloat(v),
        else => 0,
    };
}

fn isConditionActionLearning(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    return containsCaseInsensitive(trimmed, "when ") or
        containsCaseInsensitive(trimmed, "if ") or
        containsCaseInsensitive(trimmed, "for ") or
        containsCaseInsensitive(trimmed, "on ") or
        containsCaseInsensitive(trimmed, "during ");
}

fn evidenceHasAnchor(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    const anchors = [_][]const u8{
        "gh run",
        "run ",
        ".md",
        ".zig",
        ".py",
        ".rb",
        " -- ",
        "::",
        "error",
        "passed",
        "failed",
        "http://",
        "https://",
        "/",
    };
    for (anchors) |needle| {
        if (containsCaseInsensitive(trimmed, needle)) return true;
    }
    return hasHexSpan(trimmed, 7);
}

fn hasHexSpan(text: []const u8, min_len: usize) bool {
    var run: usize = 0;
    for (text) |char| {
        if (std.ascii.isHex(char)) {
            run += 1;
            if (run >= min_len) return true;
        } else {
            run = 0;
        }
    }
    return false;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (toLowerAscii(haystack[start + i]) != toLowerAscii(needle[i])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn inDateWindow(day: []const u8, since: []const u8, until: []const u8) bool {
    if (since.len == 0 and until.len == 0) return true;
    if (day.len == 0) return false;
    if (since.len > 0 and std.mem.order(u8, day, since) == .lt) return false;
    if (until.len > 0 and std.mem.order(u8, day, until) == .gt) return false;
    return true;
}

fn incrementCount(
    map: *std.StringHashMap(usize),
    allocator: std.mem.Allocator,
    raw_key: []const u8,
) !void {
    const key = std.mem.trim(u8, raw_key, " \t\r\n");
    if (key.len == 0) return;
    if (map.getEntry(key)) |entry| {
        entry.value_ptr.* += 1;
        return;
    }
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    try map.put(owned, 1);
}

fn appendMetricValueRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    metric: []const u8,
    value: usize,
) !void {
    const value_text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(value_text);
    try appendMetricTextRow(allocator, rows, metric, value_text);
}

fn appendMetricFloatRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    metric: []const u8,
    value: f64,
) !void {
    const value_text = try std.fmt.allocPrint(allocator, "{d:.2}", .{value});
    defer allocator.free(value_text);
    try appendMetricTextRow(allocator, rows, metric, value_text);
}

fn appendMetricTextRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    metric: []const u8,
    value: []const u8,
) !void {
    var row = query_engine.Row.init(allocator);
    errdefer row.deinit();
    try row.putOwnedKey("metric", .{ .string = metric });
    try row.putOwnedKey("value", .{ .string = value });
    try rows.append(allocator, row);
}

fn appendGroupedCountsRows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    map: *std.StringHashMap(usize),
    prefix: []const u8,
) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);

    var it = map.iterator();
    while (it.next()) |entry| {
        try keys.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort([]const u8, keys.items, {}, lessStringAsc);

    for (keys.items) |key| {
        const metric = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ prefix, key });
        defer allocator.free(metric);
        try appendMetricValueRow(allocator, rows, metric, map.get(key).?);
    }
}

fn ratioAsPercent(numerator: usize, denominator: usize) f64 {
    if (denominator == 0) return 0.0;
    return (@as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator))) * 100.0;
}

fn resolveSessionsRootAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    raw_root: []const u8,
) ![]u8 {
    if (raw_root.len > 0) {
        if (std.fs.path.isAbsolute(raw_root)) return allocator.dupe(u8, raw_root);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, raw_root });
    }

    const home = std.Io.Threaded.global_single_threaded.environString("HOME") orelse return error.MissingHomeEnv;
    return std.fmt.allocPrint(allocator, "{s}/.codex/sessions", .{home});
}

fn collectSessionSummaries(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    since: []const u8,
    until: []const u8,
    comparator: Comparator,
) !std.ArrayList(SessionSummary) {
    var out: std.ArrayList(SessionSummary) = .empty;

    var root_dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), sessions_root, .{ .iterate = true }) catch return out;
    defer root_dir.close(std.Io.Threaded.global_single_threaded.io());

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;

        const base = std.fs.path.basename(entry.path);
        if (!std.mem.startsWith(u8, base, "rollout-")) continue;
        const path_day = sessionDayFromEntryPath(entry.path);
        if (path_day) |day_buf| {
            // Push down date filtering before file reads when day folders are present.
            if (!inDateWindow(day_buf[0..], since, until)) continue;
        }

        const abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_root, entry.path });
        defer allocator.free(abs_path);

        const data = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), abs_path, allocator, .limited(128 * 1024 * 1024)) catch continue;
        defer allocator.free(data);
        if (data.len == 0) continue;

        // Skip files that cannot contribute to either cohort for the selected comparator.
        if (shouldSkipValueReportFile(data, comparator)) continue;

        var first_day_buf: [10]u8 = undefined;
        var first_day: []const u8 = "";
        const first_ts_text = firstTimestampField(data) orelse continue;
        const last_ts_text = lastTimestampField(data) orelse continue;
        const first_ts = parseIsoTimestampSeconds(first_ts_text) orelse continue;
        const last_ts = parseIsoTimestampSeconds(last_ts_text) orelse continue;

        const has_recall = containsAnyNeedle(data, &RecallTextMarkers);
        const has_learnings = containsAnyNeedle(data, &LearningsTextMarkers);
        const has_impl = containsAnyNeedle(data, &ImplementationTextMarkers);
        const has_proof = containsAnyNeedle(data, &ProofTextMarkers);
        const has_friction = containsAnyNeedle(data, &FrictionTextMarkers);

        const ts_day = dayLabel(first_ts_text);
        if (ts_day.len == 10) {
            std.mem.copyForwards(u8, first_day_buf[0..], ts_day[0..10]);
            first_day = first_day_buf[0..];
        }
        if (first_day.len == 0) {
            if (path_day) |day_buf| {
                std.mem.copyForwards(u8, first_day_buf[0..], day_buf[0..]);
                first_day = first_day_buf[0..];
            }
        }
        if (!inDateWindow(first_day, since, until)) continue;

        var first_assistant_ts: ?i64 = null;
        var first_recall_ts: ?i64 = null;
        if (has_recall) {
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r\n");
                if (line.len == 0) continue;
                const role = extractJsonStringField(line, "role") orelse continue;
                if (!std.ascii.eqlIgnoreCase(role, "assistant")) continue;
                const ts = extractJsonStringField(line, "timestamp") orelse continue;
                const ts_sec = parseIsoTimestampSeconds(ts) orelse continue;
                if (first_assistant_ts == null) first_assistant_ts = ts_sec;
                if (containsAnyNeedle(line, &RecallTextMarkers)) {
                    first_recall_ts = ts_sec;
                    break;
                }
            }
        }

        const duration_min = @as(f64, @floatFromInt(last_ts - first_ts)) / 60.0;
        const recall_delta_min: ?f64 = blk: {
            if (first_assistant_ts == null or first_recall_ts == null) break :blk null;
            if (first_recall_ts.? < first_assistant_ts.?) break :blk null;
            break :blk @as(f64, @floatFromInt(first_recall_ts.? - first_assistant_ts.?)) / 60.0;
        };

        try out.append(allocator, .{
            .path = try allocator.dupe(u8, abs_path),
            .day = try allocator.dupe(u8, first_day),
            .duration_min = duration_min,
            .has_recall = has_recall,
            .has_learnings = has_learnings,
            .has_impl = has_impl,
            .has_proof = has_proof,
            .has_friction = has_friction,
            .recall_delta_min = recall_delta_min,
        });
    }

    return out;
}

fn containsAnyNeedle(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (needle.len == 0) continue;
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn shouldSkipValueReportFile(data: []const u8, comparator: Comparator) bool {
    if (comparator == .all_nonrecall) return false;
    const has_recall = containsAnyNeedle(data, &RecallTextMarkers);
    const has_candidate = switch (comparator) {
        .learnings_nonrecall => containsAnyNeedle(data, &LearningsTextMarkers),
        .impl_nonrecall => containsAnyNeedle(data, &ImplementationTextMarkers),
        .all_nonrecall => true,
    };
    return !has_recall and !has_candidate;
}

fn sessionDayFromEntryPath(entry_path: []const u8) ?[10]u8 {
    var parts = std.mem.splitScalar(u8, entry_path, '/');
    var year: ?[]const u8 = null;
    var month: ?[]const u8 = null;
    var day: ?[]const u8 = null;

    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (year == null) {
            year = part;
            continue;
        }
        if (month == null) {
            month = part;
            continue;
        }
        day = part;
        break;
    }

    if (year == null or month == null or day == null) return null;

    if (!isFixedDigits(year.?, 4)) return null;
    if (!isFixedDigits(month.?, 2)) return null;
    if (!isFixedDigits(day.?, 2)) return null;

    var out: [10]u8 = undefined;
    std.mem.copyForwards(u8, out[0..4], year.?);
    out[4] = '-';
    std.mem.copyForwards(u8, out[5..7], month.?);
    out[7] = '-';
    std.mem.copyForwards(u8, out[8..10], day.?);
    return out;
}

fn isFixedDigits(text: []const u8, expected_len: usize) bool {
    if (text.len != expected_len) return false;
    for (text) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

fn extractJsonStringField(line: []const u8, field: []const u8) ?[]const u8 {
    if (line.len == 0 or field.len == 0) return null;

    var search_from: usize = 0;
    while (search_from < line.len) {
        const hit = std.mem.indexOfPos(u8, line, search_from, field) orelse return null;
        search_from = hit + field.len;

        if (hit == 0) continue;
        if (hit + field.len >= line.len) continue;
        if (line[hit - 1] != '"' or line[hit + field.len] != '"') continue;

        var cursor = hit + field.len + 1;
        while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
        if (cursor >= line.len or line[cursor] != ':') continue;
        cursor += 1;
        while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
        if (cursor >= line.len or line[cursor] != '"') continue;

        const start = cursor + 1;
        cursor = start;
        while (cursor < line.len) : (cursor += 1) {
            if (line[cursor] == '"' and !isEscapedQuote(line, cursor)) {
                return line[start..cursor];
            }
        }
        return null;
    }

    return null;
}

fn isEscapedQuote(text: []const u8, quote_index: usize) bool {
    if (quote_index == 0) return false;
    var backslash_count: usize = 0;
    var idx = quote_index;
    while (idx > 0) {
        if (text[idx - 1] != '\\') break;
        backslash_count += 1;
        idx -= 1;
    }
    return @mod(backslash_count, 2) == 1;
}

const TimestampPattern = "\"timestamp\":\"";

fn firstTimestampField(data: []const u8) ?[]const u8 {
    const hit = std.mem.indexOf(u8, data, TimestampPattern) orelse return null;
    return quotedValueAt(data, hit + TimestampPattern.len);
}

fn lastTimestampField(data: []const u8) ?[]const u8 {
    const hit = std.mem.lastIndexOf(u8, data, TimestampPattern) orelse return null;
    return quotedValueAt(data, hit + TimestampPattern.len);
}

fn quotedValueAt(text: []const u8, start: usize) ?[]const u8 {
    if (start >= text.len) return null;
    var idx = start;
    while (idx < text.len) : (idx += 1) {
        if (text[idx] == '"' and !isEscapedQuote(text, idx)) {
            return text[start..idx];
        }
    }
    return null;
}

fn computeCohortStats(
    allocator: std.mem.Allocator,
    sessions: []const SessionSummary,
    idxs: []const usize,
) CohortStats {
    var stats = CohortStats{ .n = idxs.len };
    if (idxs.len == 0) return stats;

    var durations: std.ArrayList(f64) = .empty;
    defer durations.deinit(allocator);
    var recall_deltas: std.ArrayList(f64) = .empty;
    defer recall_deltas.deinit(allocator);

    var proof_count: usize = 0;
    var friction_count: usize = 0;

    for (idxs) |idx| {
        const session = sessions[idx];
        durations.append(allocator, session.duration_min) catch {};
        if (session.has_proof) proof_count += 1;
        if (session.has_friction) friction_count += 1;
        if (session.recall_delta_min) |delta| recall_deltas.append(allocator, delta) catch {};
    }

    std.mem.sort(f64, durations.items, {}, lessF64Asc);
    std.mem.sort(f64, recall_deltas.items, {}, lessF64Asc);

    stats.duration_median_min = medianSorted(durations.items);
    stats.duration_p90_min = p90Sorted(durations.items);
    stats.proof_rate = ratio(proof_count, idxs.len);
    stats.friction_rate = ratio(friction_count, idxs.len);
    stats.recall_delta_median_min = medianSorted(recall_deltas.items);
    return stats;
}

fn lessF64Asc(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn medianSorted(values: []const f64) ?f64 {
    if (values.len == 0) return null;
    if (@mod(values.len, 2) == 1) return values[values.len / 2];
    const right = values.len / 2;
    const left = right - 1;
    return (values[left] + values[right]) / 2.0;
}

fn p90Sorted(values: []const f64) ?f64 {
    if (values.len == 0) return null;
    const raw = (@as(f64, @floatFromInt(values.len)) * 0.9);
    var idx: usize = @intFromFloat(@floor(raw));
    if (idx >= values.len) idx = values.len - 1;
    return values[idx];
}

fn ratio(numerator: usize, denominator: usize) ?f64 {
    if (denominator == 0) return null;
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
}

fn relativeDelta(primary: ?f64, comparator: ?f64) ?f64 {
    if (primary == null or comparator == null) return null;
    if (comparator.? == 0.0) return null;
    return (primary.? - comparator.?) / comparator.?;
}

fn exceedsRecommendationThreshold(duration_delta: ?f64, proof_delta: ?f64, friction_delta: ?f64) bool {
    return absOptional(duration_delta) >= 0.05 or absOptional(proof_delta) >= 0.05 or absOptional(friction_delta) >= 0.05;
}

fn absOptional(value: ?f64) f64 {
    if (value == null) return 0.0;
    return @abs(value.?);
}

fn appendValueReportIntRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    metric: []const u8,
    primary: usize,
    comparator: usize,
) !void {
    const primary_text = try std.fmt.allocPrint(allocator, "{d}", .{primary});
    defer allocator.free(primary_text);
    const comparator_text = try std.fmt.allocPrint(allocator, "{d}", .{comparator});
    defer allocator.free(comparator_text);
    try appendValueReportRow(allocator, rows, metric, primary_text, comparator_text, "");
}

fn appendValueReportOptionalFloatRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    metric: []const u8,
    primary: ?f64,
    comparator: ?f64,
) !void {
    const primary_text = try optionalFloatText(allocator, primary);
    defer allocator.free(primary_text);
    const comparator_text = try optionalFloatText(allocator, comparator);
    defer allocator.free(comparator_text);

    const delta = blk: {
        if (primary == null or comparator == null) break :blk try allocator.dupe(u8, "");
        const delta_text = try std.fmt.allocPrint(allocator, "{d:.4}", .{primary.? - comparator.?});
        break :blk delta_text;
    };
    defer allocator.free(delta);

    try appendValueReportRow(allocator, rows, metric, primary_text, comparator_text, delta);
}

fn appendValueReportDeltaRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    metric: []const u8,
    delta: ?f64,
) !void {
    const delta_text = try optionalFloatText(allocator, delta);
    defer allocator.free(delta_text);
    try appendValueReportRow(allocator, rows, metric, "", "", delta_text);
}

fn optionalFloatText(allocator: std.mem.Allocator, value: ?f64) ![]u8 {
    if (value == null) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "{d:.4}", .{value.?});
}

fn appendValueReportRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query_engine.Row),
    metric: []const u8,
    primary: []const u8,
    comparator: []const u8,
    delta: []const u8,
) !void {
    var row = query_engine.Row.init(allocator);
    errdefer row.deinit();
    try row.putOwnedKey("metric", .{ .string = metric });
    try row.putOwnedKey("primary", .{ .string = primary });
    try row.putOwnedKey("comparator", .{ .string = comparator });
    try row.putOwnedKey("delta", .{ .string = delta });
    try rows.append(allocator, row);
}

fn emitOutput(output_path: []const u8, rendered: []const u8) !void {
    if (output_path.len == 0) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        try stdout_writer.interface.writeAll(rendered);
        return;
    }

    if (std.fs.path.isAbsolute(output_path)) {
        var file = try std.Io.Dir.createFileAbsolute(std.Io.Threaded.global_single_threaded.io(), output_path, .{ .truncate = true });
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), rendered);
        return;
    }

    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), output_path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), rendered);
}

fn collectDatasetRows(
    allocator: std.mem.Allocator,
    jsonl_path: []const u8,
    dataset_name: []const u8,
) !std.ArrayList(query_engine.Row) {
    if (std.mem.eql(u8, dataset_name, "learnings")) {
        return collectLearningRows(allocator, jsonl_path);
    }
    if (std.mem.eql(u8, dataset_name, "learning_paths")) {
        return collectLearningPathsRows(allocator, jsonl_path);
    }
    if (std.mem.eql(u8, dataset_name, "learning_tags")) {
        return collectLearningTagsRows(allocator, jsonl_path);
    }
    return error.UnknownDataset;
}

fn collectLearningRows(
    allocator: std.mem.Allocator,
    jsonl_path: []const u8,
) !std.ArrayList(query_engine.Row) {
    var rows: std.ArrayList(query_engine.Row) = .empty;
    var persistence = durable_store.PersistentEventStore.init(jsonl_path);
    var snapshot = try persistence.eventStore().snapshot(allocator, MaxLearningsBytes);
    defer snapshot.deinit(allocator);

    for (snapshot.records) |event| {
        const line = event.payload;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const parsed_obj = switch (parsed.value) {
            .object => |value| value,
            else => continue,
        };
        const obj = learningRecordObject(parsed_obj);

        var row = query_engine.Row.init(allocator);
        errdefer row.deinit();

        const captured_at = jsonObjectString(obj, "captured_at");
        const status = jsonObjectString(obj, "status");
        const learning = jsonObjectString(obj, "learning");
        const application = jsonObjectString(obj, "application");
        const source = jsonObjectString(obj, "source");
        const fingerprint = jsonObjectString(obj, "fingerprint");
        const supersedes_id = jsonObjectString(obj, "supersedes_id");

        const evidence = jsonArrayStringsAlloc(allocator, obj.get("evidence"));
        defer freeOwnedSlice(allocator, evidence);
        const tags = jsonArrayStringsAlloc(allocator, obj.get("tags"));
        defer freeOwnedSlice(allocator, tags);
        const related_ids = jsonArrayStringsAlloc(allocator, obj.get("related_ids"));
        defer freeOwnedSlice(allocator, related_ids);

        var repo: []u8 = &.{};
        var branch: []u8 = &.{};
        var paths = std.ArrayList([]u8).empty;
        defer freeOwnedStringList(allocator, &paths);

        if (obj.get("context")) |context_value| {
            if (context_value == .object) {
                const context = context_value.object;
                repo = try allocator.dupe(u8, jsonObjectString(context, "repo"));
                branch = try allocator.dupe(u8, jsonObjectString(context, "branch"));
                paths = jsonArrayStringsListAlloc(allocator, context.get("paths")) catch .empty;
            }
        }
        defer allocator.free(repo);
        defer allocator.free(branch);

        const evidence_text = try joinLinesAlloc(allocator, evidence);
        defer allocator.free(evidence_text);
        const tags_text = try joinCsvAlloc(allocator, tags);
        defer allocator.free(tags_text);
        const paths_text = try joinCsvAlloc(allocator, paths.items);
        defer allocator.free(paths_text);
        const related_ids_text = try joinCsvAlloc(allocator, related_ids);
        defer allocator.free(related_ids_text);

        const day = dayLabel(captured_at);
        const week = try weekLabelAlloc(allocator, captured_at);
        defer allocator.free(week);
        const month = monthLabel(captured_at);

        var text_builder: std.ArrayList(u8) = .empty;
        defer text_builder.deinit(allocator);
        try appendJoinText(allocator, &text_builder, learning);
        try appendJoinText(allocator, &text_builder, application);
        try appendJoinText(allocator, &text_builder, evidence_text);
        try appendJoinText(allocator, &text_builder, tags_text);
        try appendJoinText(allocator, &text_builder, paths_text);

        const learning_snippet = try shortenAlloc(allocator, learning, 160);
        defer allocator.free(learning_snippet);

        try row.putOwnedKey("id", valueAsScalarString(.{ .string = jsonObjectString(obj, "id") }));
        try row.putOwnedKey("captured_at", .{ .string = captured_at });
        try row.putOwnedKey("day", .{ .string = day });
        try row.putOwnedKey("week", .{ .string = week });
        try row.putOwnedKey("month", .{ .string = month });
        try row.putOwnedKey("status", .{ .string = status });
        try row.putOwnedKey("learning", .{ .string = learning });
        try row.putOwnedKey("learning_snippet", .{ .string = learning_snippet });
        try row.putOwnedKey("application", .{ .string = application });
        try row.putOwnedKey("source", .{ .string = source });
        try row.putOwnedKey("fingerprint", .{ .string = fingerprint });
        try row.putOwnedKey("repo", .{ .string = repo });
        try row.putOwnedKey("branch", .{ .string = branch });
        try row.putOwnedKey("tags_text", .{ .string = tags_text });
        try row.putOwnedKey("tags_count", .{ .int = @intCast(tags.len) });
        try row.putOwnedKey("paths_text", .{ .string = paths_text });
        try row.putOwnedKey("paths_count", .{ .int = @intCast(paths.items.len) });
        try row.putOwnedKey("evidence_text", .{ .string = evidence_text });
        try row.putOwnedKey("evidence_count", .{ .int = @intCast(evidence.len) });
        try row.putOwnedKey("related_ids_text", .{ .string = related_ids_text });
        try row.putOwnedKey("supersedes_id", .{ .string = supersedes_id });
        try row.putOwnedKey("text", .{ .string = text_builder.items });

        try rows.append(allocator, row);
    }

    return rows;
}

fn collectLearningPathsRows(
    allocator: std.mem.Allocator,
    jsonl_path: []const u8,
) !std.ArrayList(query_engine.Row) {
    var learnings = try collectLearningRows(allocator, jsonl_path);
    defer {
        for (learnings.items) |*row| row.deinit();
        learnings.deinit(allocator);
    }

    var out: std.ArrayList(query_engine.Row) = .empty;

    for (learnings.items) |row| {
        const paths_text = rowString(row, "paths_text");
        if (paths_text.len == 0) continue;

        var parts = std.mem.splitScalar(u8, paths_text, ',');
        while (parts.next()) |part| {
            const path = std.mem.trim(u8, part, " \t\r\n");
            if (path.len == 0) continue;

            var out_row = query_engine.Row.init(allocator);
            errdefer out_row.deinit();
            try out_row.putOwnedKey("id", valueAsScalarString(row.valueOrNull("id")));
            try out_row.putOwnedKey("captured_at", valueAsScalarString(row.valueOrNull("captured_at")));
            try out_row.putOwnedKey("day", valueAsScalarString(row.valueOrNull("day")));
            try out_row.putOwnedKey("week", valueAsScalarString(row.valueOrNull("week")));
            try out_row.putOwnedKey("month", valueAsScalarString(row.valueOrNull("month")));
            try out_row.putOwnedKey("status", valueAsScalarString(row.valueOrNull("status")));
            try out_row.putOwnedKey("repo", valueAsScalarString(row.valueOrNull("repo")));
            try out_row.putOwnedKey("branch", valueAsScalarString(row.valueOrNull("branch")));
            try out_row.putOwnedKey("path", .{ .string = path });
            try out_row.putOwnedKey("fingerprint", valueAsScalarString(row.valueOrNull("fingerprint")));
            try out_row.putOwnedKey("source", valueAsScalarString(row.valueOrNull("source")));
            try out.append(allocator, out_row);
        }
    }

    return out;
}

fn collectLearningTagsRows(
    allocator: std.mem.Allocator,
    jsonl_path: []const u8,
) !std.ArrayList(query_engine.Row) {
    var learnings = try collectLearningRows(allocator, jsonl_path);
    defer {
        for (learnings.items) |*row| row.deinit();
        learnings.deinit(allocator);
    }

    var out: std.ArrayList(query_engine.Row) = .empty;

    for (learnings.items) |row| {
        const tags_text = rowString(row, "tags_text");
        if (tags_text.len == 0) continue;

        var parts = std.mem.splitScalar(u8, tags_text, ',');
        while (parts.next()) |part| {
            const tag = std.mem.trim(u8, part, " \t\r\n");
            if (tag.len == 0) continue;

            var out_row = query_engine.Row.init(allocator);
            errdefer out_row.deinit();
            try out_row.putOwnedKey("id", valueAsScalarString(row.valueOrNull("id")));
            try out_row.putOwnedKey("captured_at", valueAsScalarString(row.valueOrNull("captured_at")));
            try out_row.putOwnedKey("day", valueAsScalarString(row.valueOrNull("day")));
            try out_row.putOwnedKey("week", valueAsScalarString(row.valueOrNull("week")));
            try out_row.putOwnedKey("month", valueAsScalarString(row.valueOrNull("month")));
            try out_row.putOwnedKey("status", valueAsScalarString(row.valueOrNull("status")));
            try out_row.putOwnedKey("repo", valueAsScalarString(row.valueOrNull("repo")));
            try out_row.putOwnedKey("branch", valueAsScalarString(row.valueOrNull("branch")));
            try out_row.putOwnedKey("tag", .{ .string = tag });
            try out_row.putOwnedKey("fingerprint", valueAsScalarString(row.valueOrNull("fingerprint")));
            try out_row.putOwnedKey("source", valueAsScalarString(row.valueOrNull("source")));
            try out.append(allocator, out_row);
        }
    }

    return out;
}

fn lessRecentRows(_: void, a: query_engine.Row, b: query_engine.Row) bool {
    const a_ts = rowString(a, "captured_at");
    const b_ts = rowString(b, "captured_at");
    return std.mem.order(u8, a_ts, b_ts) == .gt;
}

fn lessRecallCandidate(rows: []const query_engine.Row, a: RecallCandidate, b: RecallCandidate) bool {
    if (a.score != b.score) return a.score > b.score;
    const a_ts = rowString(rows[a.row_index], "captured_at");
    const b_ts = rowString(rows[b.row_index], "captured_at");
    return std.mem.order(u8, a_ts, b_ts) == .lt;
}

fn lessCodifyCandidate(_: void, a: CodifyCandidate, b: CodifyCandidate) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.last_seen, b.last_seen) == .gt;
}

fn renderRecallTable(
    allocator: std.mem.Allocator,
    rows: []const query_engine.Row,
    kept: []const RecallCandidate,
) !void {
    var out_rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (out_rows.items) |*row| row.deinit();
        out_rows.deinit(allocator);
    }

    for (kept) |candidate| {
        const row = rows[candidate.row_index];
        var out = query_engine.Row.init(allocator);
        errdefer out.deinit();

        const score_text = try std.fmt.allocPrint(allocator, "{d:.3}", .{candidate.score});
        defer allocator.free(score_text);

        const learning_short = try shortenAlloc(allocator, rowString(row, "learning"), 120);
        defer allocator.free(learning_short);
        const tags_short = try shortenAlloc(allocator, rowString(row, "tags_text"), 30);
        defer allocator.free(tags_short);
        const paths_short = try shortenAlloc(allocator, rowString(row, "paths_text"), 40);
        defer allocator.free(paths_short);

        try out.putOwnedKey("score", .{ .string = score_text });
        try out.putOwnedKey("captured_at", valueAsScalarString(row.valueOrNull("captured_at")));
        try out.putOwnedKey("status", valueAsScalarString(row.valueOrNull("status")));
        try out.putOwnedKey("learning", .{ .string = learning_short });
        try out.putOwnedKey("tags", .{ .string = tags_short });
        try out.putOwnedKey("paths", .{ .string = paths_short });

        try out_rows.append(allocator, out);
    }

    const cols = [_][]const u8{ "score", "captured_at", "status", "learning", "tags", "paths" };
    const rendered = try query_output.render(allocator, .table, out_rows.items, cols[0..]);
    defer allocator.free(rendered);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(rendered);
}

fn renderRecallJson(
    allocator: std.mem.Allocator,
    rows: []const query_engine.Row,
    kept: []const RecallCandidate,
) !void {
    var out_rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (out_rows.items) |*row| row.deinit();
        out_rows.deinit(allocator);
    }

    for (kept) |candidate| {
        const base = rows[candidate.row_index];
        var out = try base.cloneAll(allocator);
        errdefer out.deinit();
        try out.putOwnedKey("score", .{ .float = candidate.score });
        try out_rows.append(allocator, out);
    }

    const rendered = try query_output.render(allocator, .json, out_rows.items, null);
    defer allocator.free(rendered);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(rendered);
}

fn renderCodifyTable(
    allocator: std.mem.Allocator,
    items: []const CodifyCandidate,
) !void {
    var out_rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (out_rows.items) |*row| row.deinit();
        out_rows.deinit(allocator);
    }

    for (items) |item| {
        var out = query_engine.Row.init(allocator);
        errdefer out.deinit();

        try out.putOwnedKey("score", .{ .float = item.score });
        try out.putOwnedKey("count", .{ .int = @intCast(item.count) });
        try out.putOwnedKey("last_seen", .{ .string = item.last_seen });
        try out.putOwnedKey("status", .{ .string = item.status });
        try out.putOwnedKey("theme", .{ .string = item.theme });
        try out.putOwnedKey("learning", .{ .string = item.learning });

        try out_rows.append(allocator, out);
    }

    const cols = [_][]const u8{ "score", "count", "last_seen", "status", "theme", "learning" };
    const rendered = try query_output.render(allocator, .table, out_rows.items, cols[0..]);
    defer allocator.free(rendered);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(rendered);
}

fn renderCodifyJson(
    allocator: std.mem.Allocator,
    items: []const CodifyCandidate,
) !void {
    var out_rows: std.ArrayList(query_engine.Row) = .empty;
    defer {
        for (out_rows.items) |*row| row.deinit();
        out_rows.deinit(allocator);
    }

    for (items) |item| {
        var out = query_engine.Row.init(allocator);
        errdefer out.deinit();
        try out.putOwnedKey("score", .{ .float = item.score });
        try out.putOwnedKey("count", .{ .int = @intCast(item.count) });
        try out.putOwnedKey("last_seen", .{ .string = item.last_seen });
        try out.putOwnedKey("status", .{ .string = item.status });
        try out.putOwnedKey("theme", .{ .string = item.theme });
        try out.putOwnedKey("learning", .{ .string = item.learning });
        try out_rows.append(allocator, out);
    }

    const rendered = try query_output.render(allocator, .json, out_rows.items, null);
    defer allocator.free(rendered);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(rendered);
}

fn appendJoinText(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, trimmed);
}

fn containsAnyHint(paths_text: []const u8, hints: []const []u8) bool {
    for (hints) |hint| {
        if (hint.len == 0) continue;
        if (std.mem.indexOf(u8, paths_text, hint) != null) return true;
    }
    return false;
}

fn statusBoost(status: []const u8) f64 {
    for (STATUS_BOOSTS) |entry| {
        if (std.mem.eql(u8, entry.status, status)) return entry.value;
    }
    return 0.0;
}

fn impactScore(text: []const u8, status: []const u8, tags_text: []const u8) f64 {
    var score: f64 = 0.0;

    if (std.mem.eql(u8, status, "codify_now")) score += 3.0;
    if (std.mem.eql(u8, status, "avoid_for_now")) score += 2.0;

    if (containsAny(tags_text, &.{ "security", "data_loss", "corruption", "invariant", "ci" })) score += 2.0;
    if (containsAny(text, &.{ "data loss", "corrupt", "credential", "secret", "leak", "force", "--hard" })) score += 2.0;
    if (containsAny(text, &.{ "pre-commit", "precommit", "flake", "flaky", "timeout", "loop" })) score += 1.0;

    return score;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    var lower_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer lower_arena.deinit();
    const alloc = lower_arena.allocator();

    const lowered = asciiLowerAlloc(alloc, haystack) catch return false;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, lowered, needle) != null) return true;
    }
    return false;
}

fn isToolKeyword(token: []const u8) bool {
    for (TOOL_KEYWORDS) |keyword| {
        if (std.mem.eql(u8, keyword, token)) return true;
    }
    return false;
}

fn tokenizeSet(allocator: std.mem.Allocator, text: []const u8) !std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(allocator);
    errdefer deinitOwnedStringSet(allocator, &out);

    var token_buf: std.ArrayList(u8) = .empty;
    defer token_buf.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = toLowerAscii(text[i]);
        if (isAsciiLower(c) or std.ascii.isDigit(c)) {
            try token_buf.append(allocator, c);
            continue;
        }

        try flushToken(allocator, &out, &token_buf);
    }
    try flushToken(allocator, &out, &token_buf);

    return out;
}

fn flushToken(
    allocator: std.mem.Allocator,
    set: *std.StringHashMap(void),
    token_buf: *std.ArrayList(u8),
) !void {
    if (token_buf.items.len == 0) return;

    const stemmed = try stemTokenAlloc(allocator, token_buf.items);
    defer allocator.free(stemmed);

    token_buf.clearRetainingCapacity();

    if (stemmed.len <= 2) return;
    if (isStopword(stemmed)) return;

    const key = try allocator.dupe(u8, stemmed);
    errdefer allocator.free(key);

    if (set.contains(key)) {
        allocator.free(key);
        return;
    }

    try set.put(key, {});
}

fn stemTokenAlloc(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len > 5 and std.mem.endsWith(u8, token, "ing")) return allocator.dupe(u8, token[0 .. token.len - 3]);
    if (token.len > 4 and std.mem.endsWith(u8, token, "ed")) return allocator.dupe(u8, token[0 .. token.len - 2]);
    if (token.len > 4 and std.mem.endsWith(u8, token, "es")) return allocator.dupe(u8, token[0 .. token.len - 2]);
    if (token.len > 3 and std.mem.endsWith(u8, token, "s")) return allocator.dupe(u8, token[0 .. token.len - 1]);
    return allocator.dupe(u8, token);
}

fn isStopword(token: []const u8) bool {
    for (STOPWORDS) |word| {
        if (std.mem.eql(u8, word, token)) return true;
    }
    return false;
}

fn intersectionCount(a: *const std.StringHashMap(void), b: *const std.StringHashMap(void)) usize {
    var count: usize = 0;
    var it = a.iterator();
    while (it.next()) |entry| {
        if (b.contains(entry.key_ptr.*)) count += 1;
    }
    return count;
}

fn hasIntersection(a: *const std.StringHashMap(void), b: *const std.StringHashMap(void)) bool {
    var it = a.iterator();
    while (it.next()) |entry| {
        if (b.contains(entry.key_ptr.*)) return true;
    }
    return false;
}

fn unionCount(a: *const std.StringHashMap(void), b: *const std.StringHashMap(void), overlap: usize) usize {
    return a.count() + b.count() - overlap;
}

fn appendPathHintsFromCsv(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList([]u8),
    csv: []const u8,
) !void {
    var parts = std.mem.splitScalar(u8, csv, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        try appendUniqueHint(allocator, hints, trimmed);
    }
}

fn appendPathHintsFromQuery(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList([]u8),
    query: []const u8,
) !void {
    var token_buf: std.ArrayList(u8) = .empty;
    defer token_buf.deinit(allocator);

    var i: usize = 0;
    while (i < query.len) : (i += 1) {
        const c = query[i];
        if (isPathTokenChar(c)) {
            try token_buf.append(allocator, c);
            continue;
        }

        try flushPathHintToken(allocator, hints, token_buf.items);
        token_buf.clearRetainingCapacity();
    }

    try flushPathHintToken(allocator, hints, token_buf.items);
}

fn flushPathHintToken(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList([]u8),
    token: []const u8,
) !void {
    if (token.len < 3) return;
    if (std.mem.indexOfScalar(u8, token, '/') == null and std.mem.indexOfScalar(u8, token, '.') == null) {
        return;
    }
    try appendUniqueHint(allocator, hints, token);
}

fn appendUniqueHint(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList([]u8),
    hint: []const u8,
) !void {
    for (hints.items) |existing| {
        if (std.mem.eql(u8, existing, hint)) return;
    }
    try hints.append(allocator, try allocator.dupe(u8, hint));
}

fn computeThemeAlloc(
    allocator: std.mem.Allocator,
    part_a: []const u8,
    part_b: []const u8,
) ![]u8 {
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(allocator);

    if (part_a.len > 0) try combined.appendSlice(allocator, part_a);
    if (part_b.len > 0) {
        if (combined.items.len > 0) try combined.append(allocator, ' ');
        try combined.appendSlice(allocator, part_b);
    }

    var tokens = try tokenizeSet(allocator, combined.items);
    defer deinitOwnedStringSet(allocator, &tokens);

    if (tokens.count() == 0) return allocator.dupe(u8, "");

    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(allocator);

    var it = tokens.iterator();
    while (it.next()) |entry| {
        try items.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort([]const u8, items.items, {}, lessStringAsc);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const take = @min(items.items.len, 6);
    var idx: usize = 0;
    while (idx < take) : (idx += 1) {
        if (idx > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, items.items[idx]);
    }

    return out.toOwnedSlice(allocator);
}

fn lessStringAsc(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn renderErrorLine(comptime fmt: []const u8, args: anytype) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print(fmt, args);
}

fn parseJsonArgAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    arg: []const u8,
) ![]u8 {
    if (arg.len == 0) return error.InvalidSpec;
    if (arg[0] != '@') return allocator.dupe(u8, arg);

    const raw = arg[1..];
    if (raw.len == 0) return error.InvalidSpec;

    const path = if (std.fs.path.isAbsolute(raw))
        try allocator.dupe(u8, raw)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, raw });
    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(8 * 1024 * 1024));
}

fn valueAsScalarString(value: query_spec.Scalar) query_spec.Scalar {
    return switch (value) {
        .string => value,
        .int => .{ .string = "" },
        .float => .{ .string = "" },
        .bool => .{ .string = "" },
        .null => .{ .string = "" },
    };
}

fn rowString(row: query_engine.Row, field: []const u8) []const u8 {
    return switch (row.valueOrNull(field)) {
        .string => |value| value,
        else => "",
    };
}

fn jsonObjectString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |value| {
        return switch (value) {
            .string => |text| text,
            .number_string => |text| text,
            else => "",
        };
    }
    return "";
}

fn jsonArrayStringsAlloc(allocator: std.mem.Allocator, value_opt: ?std.json.Value) []const []u8 {
    var out: std.ArrayList([]u8) = .empty;

    if (value_opt) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                const text = switch (item) {
                    .string => |v| v,
                    .number_string => |v| v,
                    else => continue,
                };
                const duped = allocator.dupe(u8, text) catch continue;
                out.append(allocator, duped) catch {
                    allocator.free(duped);
                    continue;
                };
            }
        }
    }

    return out.toOwnedSlice(allocator) catch &.{};
}

fn jsonArrayStringsListAlloc(allocator: std.mem.Allocator, value_opt: ?std.json.Value) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;

    if (value_opt) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                const text = switch (item) {
                    .string => |v| v,
                    .number_string => |v| v,
                    else => continue,
                };
                try out.append(allocator, try allocator.dupe(u8, text));
            }
        }
    }

    return out;
}

fn joinLinesAlloc(allocator: std.mem.Allocator, items: []const []u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (items, 0..) |item, idx| {
        if (idx > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, item);
    }

    return out.toOwnedSlice(allocator);
}

fn joinCsvAlloc(allocator: std.mem.Allocator, items: []const []u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (items, 0..) |item, idx| {
        if (idx > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, item);
    }

    return out.toOwnedSlice(allocator);
}

fn shortenAlloc(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    if (text.len <= max_len) return allocator.dupe(u8, text);
    if (max_len <= 3) return allocator.dupe(u8, text[0..max_len]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, text[0 .. max_len - 3]);
    try out.appendSlice(allocator, "...");
    return out.toOwnedSlice(allocator);
}

fn dayLabel(captured_at: []const u8) []const u8 {
    if (captured_at.len >= 10 and captured_at[4] == '-' and captured_at[7] == '-') {
        return captured_at[0..10];
    }
    return "";
}

fn monthLabel(captured_at: []const u8) []const u8 {
    if (captured_at.len >= 7 and captured_at[4] == '-') {
        return captured_at[0..7];
    }
    return "";
}

fn weekLabelAlloc(allocator: std.mem.Allocator, captured_at: []const u8) ![]u8 {
    const parts = parseDateParts(captured_at) orelse return allocator.dupe(u8, "");
    const iso = isoWeek(parts.year, parts.month, parts.day);
    return std.fmt.allocPrint(allocator, "{d}-W{d:0>2}", .{ iso.year, iso.week });
}

const IsoWeek = struct {
    year: i32,
    week: i32,
};

fn isoWeek(year: i32, month: i32, day: i32) IsoWeek {
    const doy = dayOfYear(year, month, day);
    const weekday = weekdayMon1(year, month, day);

    var week = @divFloor(doy - weekday + 10, 7);
    var week_year = year;

    if (week < 1) {
        week_year = year - 1;
        week = isoWeeksInYear(week_year);
    } else if (week > isoWeeksInYear(year)) {
        week_year = year + 1;
        week = 1;
    }

    return .{ .year = week_year, .week = week };
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    return @mod(year, 4) == 0;
}

fn dayOfYear(year: i32, month: i32, day: i32) i32 {
    const month_days = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var total: i32 = day;
    var m: i32 = 1;
    while (m < month) : (m += 1) {
        total += month_days[@intCast(m - 1)];
        if (m == 2 and isLeapYear(year)) total += 1;
    }
    return total;
}

fn weekdayMon1(year: i32, month: i32, day: i32) i32 {
    const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y = year;
    if (month < 3) y -= 1;
    const weekday_sun0 = @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + offsets[@intCast(month - 1)] + day, 7);
    return if (weekday_sun0 == 0) 7 else weekday_sun0;
}

fn isoWeeksInYear(year: i32) i32 {
    const jan1_weekday = weekdayMon1(year, 1, 1);
    if (jan1_weekday == 4) return 53;
    if (jan1_weekday == 3 and isLeapYear(year)) return 53;
    return 52;
}

fn parseDateParts(captured_at: []const u8) ?DateParts {
    if (captured_at.len < 10) return null;
    if (!(captured_at[4] == '-' and captured_at[7] == '-')) return null;

    const year = std.fmt.parseInt(i32, captured_at[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i32, captured_at[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i32, captured_at[8..10], 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;

    return .{ .year = year, .month = month, .day = day };
}

fn parseIsoTimestampSeconds(timestamp: []const u8) ?i64 {
    if (timestamp.len < 19) return null;
    if (!(timestamp[4] == '-' and timestamp[7] == '-' and timestamp[10] == 'T' and timestamp[13] == ':' and timestamp[16] == ':')) {
        return null;
    }

    const year = std.fmt.parseInt(i64, timestamp[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, timestamp[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, timestamp[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, timestamp[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, timestamp[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, timestamp[17..19], 10) catch return null;

    const days = daysFromCivil(year, month, day);
    return (days * 86_400) + (hour * 3600) + (minute * 60) + second;
}

fn daysFromCivil(year_in: i64, month_in: i64, day: i64) i64 {
    var year = year_in;
    const month = month_in;

    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(if (year >= 0) year else year - 399, 400);
    const yoe = year - era * 400;
    const mp = month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
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

fn resolveJsonlPathAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    raw_path: []const u8,
) ![]u8 {
    const effective = if (raw_path.len == 0) DefaultLearningsPath else raw_path;
    if (std.fs.path.isAbsolute(effective)) return allocator.dupe(u8, effective);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, effective });
}

fn resolveReadJsonlPathAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    raw_path: []const u8,
    path_explicit: bool,
) ![]u8 {
    if (path_explicit) return resolveJsonlPathAlloc(allocator, repo_root, raw_path);

    const next_path = try resolveJsonlPathAlloc(allocator, repo_root, DefaultLearningsPath);
    errdefer allocator.free(next_path);
    if (try persistentStoreExists(allocator, next_path)) return next_path;

    const previous_path = try resolveJsonlPathAlloc(allocator, repo_root, PreviousLearningsPath);
    if (durable_store.fileExists(previous_path)) {
        allocator.free(next_path);
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        try stderr_writer.interface.print(
            "migration-hint: reading legacy {s}; run `ledger migrate --source learnings --mode copy` to create {s}\n",
            .{ PreviousLearningsPath, DefaultLearningsPath },
        );
        return previous_path;
    }
    allocator.free(previous_path);

    const legacy_path = try resolveJsonlPathAlloc(allocator, repo_root, LegacyLearningsPath);
    if (durable_store.fileExists(legacy_path)) {
        allocator.free(next_path);
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        try stderr_writer.interface.print(
            "migration-hint: reading legacy {s}; run `ledger migrate --source learnings --mode copy` to create {s}\n",
            .{ LegacyLearningsPath, DefaultLearningsPath },
        );
        return legacy_path;
    }

    allocator.free(legacy_path);
    return next_path;
}

fn persistentStoreExists(allocator: std.mem.Allocator, locator: []const u8) !bool {
    var persistence = durable_store.PersistentEventStore.init(locator);
    var snapshot = try persistence.eventStore().snapshot(allocator, MaxLearningsBytes);
    defer snapshot.deinit(allocator);
    return snapshot.exists;
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
    while (end > 1 and isPathSep(path[end - 1])) : (end -= 1) {}
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

fn isPathSep(c: u8) bool {
    return c == std.fs.path.sep or c == std.fs.path.sep_windows;
}

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isAsciiLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isPathTokenChar(c: u8) bool {
    return isAsciiLower(toLowerAscii(c)) or std.ascii.isDigit(c) or c == '_' or c == '.' or c == '/' or c == '-';
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |char, idx| {
        out[idx] = toLowerAscii(char);
    }
    return out;
}

fn freeOwnedSlice(allocator: std.mem.Allocator, items: []const []u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeOwnedStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn deinitOwnedStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var it = set.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    set.deinit();
}

fn deinitOwnedStringMapValues(allocator: std.mem.Allocator, map: *std.StringHashMap(usize)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    map.deinit();
}

test "parse args datasets" {
    const argv = [_][]const u8{ ProgramName, "datasets" };
    const parsed = try parseArgs(&argv);
    try std.testing.expect(parsed.command.? == .datasets);
}

test "parse args append captures tail start" {
    const argv = [_][]const u8{ ProgramName, "--path", "nested.jsonl", "append", "--learning", "rule" };
    const parsed = try parseArgs(&argv);
    try std.testing.expect(parsed.command.? == .append);
    try std.testing.expect(parsed.path_explicit);
    try std.testing.expectEqualStrings("nested.jsonl", parsed.path);
    try std.testing.expectEqual(@as(usize, 4), parsed.append_args_start);
}

test "merge append args injects explicit prefixed path" {
    const merged = try mergeAppendArgsAlloc(std.testing.allocator, true, "nested.jsonl", &.{ "--learning", "rule" });
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try std.testing.expectEqualStrings("--path", merged[0]);
    try std.testing.expectEqualStrings("nested.jsonl", merged[1]);
}

test "merge append args rejects conflicting path values" {
    try std.testing.expectError(
        error.ConflictingPathValue,
        mergeAppendArgsAlloc(std.testing.allocator, true, "a.jsonl", &.{ "--path", "b.jsonl", "--learning", "rule" }),
    );
}

test "parse args recall" {
    const argv = [_][]const u8{ ProgramName, "--path", ".learnings.jsonl", "recall", "--query", "zig" };
    const parsed = try parseArgs(&argv);
    try std.testing.expect(parsed.command.? == .recall);
    try std.testing.expectEqualStrings(".learnings.jsonl", parsed.path);
    try std.testing.expectEqualStrings("zig", parsed.query.?);
}

test "parse args export requires identity and accepts memory note format" {
    const argv = [_][]const u8{ ProgramName, "export", "--id", "lrn-20260715T000000Z-12345678", "--format", "memory-note" };
    const parsed = try parseArgs(&argv);
    try std.testing.expect(parsed.command.? == .@"export");
    try std.testing.expectEqualStrings("lrn-20260715T000000Z-12345678", parsed.export_id.?);
    try std.testing.expectEqualStrings("memory-note", parsed.export_format);

    const missing = [_][]const u8{ ProgramName, "export" };
    try std.testing.expectError(error.MissingIdValue, parseArgs(&missing));
}

test "learning memory note projection is deterministic and source complete" {
    const input =
        \\{"id":"lrn-20260715T000000Z-12345678","captured_at":"2026-07-15T00:00:00Z","status":"codify_now","learning":"Prefer an explicit checkpoint.","evidence":["test:checkpoint"],"application":"Run the checkpoint at closeout.","source":"ledger:learnings","fingerprint":"1234567890abcdef","context":{"repo":"owner/repo","branch":"main","paths":["src/checkpoint.zig"]},"tags":["memory-admission"],"related_ids":[],"supersedes_id":null}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    const record = parsed.value.object;

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try writeLearningMemoryNoteProjection(std.testing.allocator, &first.writer, record, DefaultLearningsPath);
    const first_bytes = try first.toOwnedSlice();
    defer std.testing.allocator.free(first_bytes);

    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try writeLearningMemoryNoteProjection(std.testing.allocator, &second.writer, record, DefaultLearningsPath);
    const second_bytes = try second.toOwnedSlice();
    defer std.testing.allocator.free(second_bytes);

    try std.testing.expectEqualStrings(first_bytes, second_bytes);
    try std.testing.expect(std.mem.indexOf(u8, first_bytes, "\"authority\":\"ledger-cli\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_bytes, "\"learning_id\":\"lrn-20260715T000000Z-12345678\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_bytes, "\"source_path\":\".ledger/learnings/events.jsonl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_bytes, "\"evidence_snapshot\":[\"test:checkpoint\"]") != null);
}

test "discoverRepoRootAlloc walks to git ancestor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".git");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "nested/deeper");

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    const nested_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "nested/deeper", std.testing.allocator);
    defer std.testing.allocator.free(nested_abs);

    const resolved_nested = try discoverRepoRootAlloc(std.testing.allocator, nested_abs);
    defer std.testing.allocator.free(resolved_nested);
    try std.testing.expectEqualStrings(root_abs, resolved_nested);
}

test "parse args quality-audit" {
    const argv = [_][]const u8{
        ProgramName,
        "--path",
        ".learnings.jsonl",
        "quality-audit",
        "--since",
        "2026-02-14",
        "--until",
        "2026-03-05",
        "--format",
        "json",
    };
    const parsed = try parseArgs(&argv);
    try std.testing.expect(parsed.command.? == .quality_audit);
    try std.testing.expectEqualStrings("2026-02-14", parsed.since);
    try std.testing.expectEqualStrings("2026-03-05", parsed.until);
    try std.testing.expectEqualStrings("json", parsed.format);
}

test "parse args memory-digest" {
    const argv = [_][]const u8{
        ProgramName,
        "memory-digest",
        "--scan-root",
        "/tmp/learnings",
        "--since",
        "2026-03-01",
        "--limit-candidates",
        "7",
        "--output",
        "digest.md",
    };
    const parsed = try parseArgs(&argv);
    try std.testing.expect(parsed.command.? == .memory_digest);
    try std.testing.expectEqualStrings("/tmp/learnings", parsed.scan_root);
    try std.testing.expectEqualStrings("2026-03-01", parsed.since);
    try std.testing.expectEqual(@as(usize, 7), parsed.limit);
    try std.testing.expectEqualStrings("digest.md", parsed.output);
}

test "subcommand help dispatches before argument parsing" {
    const long_help = [_][]const u8{ ProgramName, "migrate", "--help" };
    try std.testing.expectEqualStrings("ledger migrate --source learnings", subcommandHelpSurface(&long_help).?.executable_name);

    const short_help = [_][]const u8{ ProgramName, "migrate", "-h" };
    try std.testing.expectEqualStrings("ledger migrate --source learnings", subcommandHelpSurface(&short_help).?.executable_name);

    const dry_run = [_][]const u8{ ProgramName, "migrate", "--dry-run" };
    try std.testing.expect(subcommandHelpSurface(&dry_run) == null);
    const parsed = try parseArgs(&dry_run);
    try std.testing.expect(parsed.command.? == .migrate);
    try std.testing.expect(parsed.dry_run);

    const global_path_help = [_][]const u8{ ProgramName, "--path", ".custom/learnings.jsonl", "migrate", "--help" };
    try std.testing.expectEqualStrings("ledger migrate --source learnings", subcommandHelpSurface(&global_path_help).?.executable_name);

    const late_help = [_][]const u8{ ProgramName, "migrate", "--dry-run", "--help" };
    try std.testing.expectEqualStrings("ledger migrate --source learnings", subcommandHelpSurface(&late_help).?.executable_name);

    const query_mentions_migrate = [_][]const u8{ ProgramName, "query", "--spec", "migrate", "--help" };
    try std.testing.expectEqualStrings("ledger query --source learnings", subcommandHelpSurface(&query_mentions_migrate).?.executable_name);

    const recall_help = [_][]const u8{ ProgramName, "recall", "--help" };
    try std.testing.expectEqualStrings("ledger recall --source learnings", subcommandHelpSurface(&recall_help).?.executable_name);

    const query_short_help = [_][]const u8{ ProgramName, "query", "-h" };
    try std.testing.expectEqualStrings("ledger query --source learnings", subcommandHelpSurface(&query_short_help).?.executable_name);

    const append_help = [_][]const u8{ ProgramName, "append", "--help" };
    try std.testing.expectEqualStrings("ledger capture --source learnings", subcommandHelpSurface(&append_help).?.executable_name);
}

test "migrate copies legacy rows preserving byte content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".ledger/learnings");
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, LegacyLearningsPath });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root, DefaultLearningsPath });
    defer std.testing.allocator.free(target_path);

    const payload =
        "{\"id\":\"lrn-1\",\"captured_at\":\"2026-06-21T00:00:00Z\",\"status\":\"do_more\",\"learning\":\"When migrating, preserve bytes.\",\"evidence\":[],\"application\":\"Verify sha.\",\"context\":{\"repo\":\"r\",\"branch\":\"main\",\"paths\":[]},\"fingerprint\":\"fp\",\"tags\":[],\"related_ids\":[]}\n";
    try durable_store.writeTextAtomic(std.testing.allocator, source_path, payload);
    const source_bytes = try durable_store.readRegularFileNoSymlink(std.testing.allocator, source_path, MaxLearningsBytes);
    defer std.testing.allocator.free(source_bytes);
    var stats = try validateJsonlBytes(std.testing.allocator, source_bytes);
    defer stats.deinit(std.testing.allocator);
    try durable_store.writeTextCreateNew(std.testing.allocator, target_path, source_bytes, .{ .reject_symlinks = true });
    const copied = try durable_store.readFileAlloc(std.testing.allocator, target_path, MaxLearningsBytes);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings(payload, copied);
}

test "migrate parser accepts source-preserving invalid-record skip policy" {
    const argv = [_][]const u8{ ProgramName, "migrate", "--invalid-policy", "skip", "--mode", "copy" };
    const parsed = try parseArgs(&argv);
    try std.testing.expectEqual(InvalidPolicy.skip, parsed.invalid_policy);

    const move_argv = [_][]const u8{ ProgramName, "migrate", "--invalid-policy", "skip", "--mode", "move" };
    try std.testing.expectError(error.UnsafeSkipPolicy, parseArgs(&move_argv));

    const remove_argv = [_][]const u8{ ProgramName, "migrate", "--invalid-policy", "skip", "--remove-legacy" };
    try std.testing.expectError(error.UnsafeSkipPolicy, parseArgs(&remove_argv));
    try std.testing.expectEqualStrings("would_migrate", migrationStatus("would_migrate", 0));
    try std.testing.expectEqualStrings("would_migrate_with_skips", migrationStatus("would_migrate", 1));
}

test "migrate recovers a legacy JSON object split across physical lines" {
    const payload =
        "{\"id\":\"lrn-1\",\"captured_at\":\"2026-06-21T00:00:00Z\",\"status\":\"do_more\",\"learning\":\"When migrating, recover logical JSON values.\",\"evidence\":[],\"application\":\"Parse values, not lines.\",\"context\":{\"repo\":\"r\",\"branch\":\"main\",\"paths\":[]},\"fingerprint\":\"fp\",\n" ++
        "\"tags\":[\"migration\"],\"related_ids\":[]}\n";
    var conversion = try convertLearningRowsToEventsAlloc(std.testing.allocator, payload);
    defer conversion.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), conversion.records);
    try std.testing.expectEqual(@as(usize, 1), conversion.recovered_multiline_records);
    try std.testing.expectEqual(@as(usize, 0), conversion.issues.items.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, conversion.bytes, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, conversion.bytes, "\"tags\":[\"migration\"]") != null);

    var stats = try validateJsonlBytes(std.testing.allocator, conversion.bytes);
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), stats.records);
}

test "migrate repairs a uniquely valid missing opening quote on a known continuation key" {
    const payload =
        "{\"id\":\"lrn-1\",\"status\":\"do_more\",\"fingerprint\":\"fp\",\n" ++
        "tags\":[\"migration\"]}\n";
    var conversion = try convertLearningRowsToEventsAlloc(std.testing.allocator, payload);
    defer conversion.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), conversion.records);
    try std.testing.expectEqual(@as(usize, 1), conversion.recovered_multiline_records);
    try std.testing.expectEqual(@as(usize, 1), conversion.repairs.items.len);
    try std.testing.expectEqualStrings("insert_missing_opening_key_quote", conversion.repairs.items[0].repair);
    try std.testing.expectEqual(@as(usize, 0), conversion.issues.items.len);
    try std.testing.expect(std.mem.indexOf(u8, conversion.bytes, "\"tags\":[\"migration\"]") != null);
}

test "migrate isolates irreparable records and retains later valid records" {
    const payload =
        "{bad json}\n" ++
        "{\"id\":\"lrn-2\",\"status\":\"do_more\",\"learning\":\"Keep valid rows.\"}\n";
    var conversion = try convertLearningRowsToEventsAlloc(std.testing.allocator, payload);
    defer conversion.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), conversion.records);
    try std.testing.expectEqual(@as(usize, 1), conversion.issues.items.len);
    try std.testing.expectEqual(@as(usize, 1), conversion.issues.items[0].start_line);
    try std.testing.expectEqual(@as(usize, 1), conversion.issues.items[0].end_line);
    try std.testing.expect(std.mem.indexOf(u8, conversion.bytes, "lrn-2") != null);

    var stats = try validateJsonlBytes(std.testing.allocator, conversion.bytes);
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), stats.records);
}

test "doctor inspection reports canonical issue line spans" {
    const payload =
        "{\"id\":\"lrn-1\"}\n" ++
        "{bad json}\n" ++
        "{\"id\":\"lrn-1\"}\n";
    var inspection = try inspectCanonicalJsonlAlloc(std.testing.allocator, payload);
    defer inspection.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), inspection.records);
    try std.testing.expectEqual(@as(usize, 2), inspection.issues.items.len);
    try std.testing.expectEqual(@as(usize, 2), inspection.issues.items[0].start_line);
    try std.testing.expectEqualStrings("DuplicateLearningId", inspection.issues.items[1].reason);
    try std.testing.expectEqual(@as(usize, 3), inspection.issues.items[1].end_line);
}

test "migrate refuses invalid JSONL" {
    try std.testing.expectError(error.InvalidJsonLine, validateJsonlBytes(std.testing.allocator, "{bad json}\n"));
}

test "migrate refuses target with conflicting existing IDs" {
    var source_stats = try validateJsonlBytes(std.testing.allocator, "{\"id\":\"lrn-1\",\"learning\":\"new\"}\n");
    defer source_stats.deinit(std.testing.allocator);
    var target_stats = try validateJsonlBytes(std.testing.allocator, "{\"id\":\"lrn-1\",\"learning\":\"old\"}\n");
    defer target_stats.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ConflictingLearningId,
        mergeJsonlBytesByIdAlloc(
            std.testing.allocator,
            "{\"id\":\"lrn-1\",\"learning\":\"old\"}\n",
            &target_stats,
            "{\"id\":\"lrn-1\",\"learning\":\"new\"}\n",
            &source_stats,
        ),
    );
}

test "migrate idempotent when target has same rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".ledger/learnings");
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, LegacyLearningsPath });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root, DefaultLearningsPath });
    defer std.testing.allocator.free(target_path);

    const payload = "{\"id\":\"lrn-1\",\"learning\":\"same\"}\n";
    try durable_store.writeTextAtomic(std.testing.allocator, source_path, payload);
    try durable_store.writeTextAtomic(std.testing.allocator, target_path, payload);
    const source_bytes = try durable_store.readRegularFileNoSymlink(std.testing.allocator, source_path, MaxLearningsBytes);
    defer std.testing.allocator.free(source_bytes);
    const target_bytes = try durable_store.readRegularFileNoSymlink(std.testing.allocator, target_path, MaxLearningsBytes);
    defer std.testing.allocator.free(target_bytes);
    try std.testing.expectEqualStrings(source_bytes, target_bytes);
}

test "read commands resolve new path by default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".ledger/learnings");
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root, DefaultLearningsPath });
    defer std.testing.allocator.free(target_path);
    try durable_store.writeTextAtomic(std.testing.allocator, target_path, "{\"id\":\"lrn-1\"}\n");

    const resolved = try resolveReadJsonlPathAlloc(std.testing.allocator, root, DefaultLearningsPath, false);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(target_path, resolved);
}

test "legacy read resolves compatibility path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const legacy_path = try std.fs.path.join(std.testing.allocator, &.{ root, LegacyLearningsPath });
    defer std.testing.allocator.free(legacy_path);
    try durable_store.writeTextAtomic(std.testing.allocator, legacy_path, "{\"id\":\"lrn-1\"}\n");

    const resolved = try resolveReadJsonlPathAlloc(std.testing.allocator, root, DefaultLearningsPath, false);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(legacy_path, resolved);
}

test "default memory digest path uses Codex memories extensions root" {
    const path = try defaultDigestOutputPathAlloc(std.testing.allocator, "/tmp/codex-home");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings(
        "/tmp/codex-home/memories/extensions/learnings/resources/latest_learnings_digest.md",
        path,
    );
}

test "digest eligibility keeps codify and anchored review later" {
    var codify = query_engine.Row.init(std.testing.allocator);
    defer codify.deinit();
    try codify.putOwnedKey("status", .{ .string = "codify_now" });
    try codify.putOwnedKey("evidence_text", .{ .string = "" });
    try std.testing.expect(digestEligible(codify));

    var review = query_engine.Row.init(std.testing.allocator);
    defer review.deinit();
    try review.putOwnedKey("status", .{ .string = "review_later" });
    try review.putOwnedKey("evidence_text", .{ .string = "zig build test-learnings passed" });
    try std.testing.expect(digestEligible(review));

    var weak = query_engine.Row.init(std.testing.allocator);
    defer weak.deinit();
    try weak.putOwnedKey("status", .{ .string = "review_later" });
    try weak.putOwnedKey("evidence_text", .{ .string = "general note" });
    try weak.putOwnedKey("paths_count", .{ .int = 0 });
    try std.testing.expect(!digestEligible(weak));
}

test "parse args value-report" {
    const argv = [_][]const u8{
        ProgramName,
        "value-report",
        "--sessions-root",
        "/tmp/sessions",
        "--comparator",
        "impl_nonrecall",
        "--format",
        "csv",
        "--output",
        "value.csv",
    };
    const parsed = try parseArgs(&argv);
    try std.testing.expect(parsed.command.? == .value_report);
    try std.testing.expectEqualStrings("/tmp/sessions", parsed.sessions_root);
    try std.testing.expectEqualStrings("impl_nonrecall", parsed.comparator);
    try std.testing.expectEqualStrings("csv", parsed.format);
    try std.testing.expectEqualStrings("value.csv", parsed.output);
}

test "session day from entry path" {
    const day = sessionDayFromEntryPath("2026/03/05/rollout-2026-03-05T05-12-23-123.jsonl").?;
    try std.testing.expectEqualStrings("2026-03-05", day[0..]);
    const day_with_dot = sessionDayFromEntryPath("./2026/03/05/rollout-2026-03-05T05-12-23-123.jsonl").?;
    try std.testing.expectEqualStrings("2026-03-05", day_with_dot[0..]);
    try std.testing.expect(sessionDayFromEntryPath("rollout-2026-03-05.jsonl") == null);
}

test "extract json string field" {
    const line =
        "{\"timestamp\":\"2026-03-05T05:13:26Z\",\"role\":\"assistant\",\"text\":\"Run LEARNINGS recall \\\"now\\\"\"}";
    try std.testing.expectEqualStrings("2026-03-05T05:13:26Z", extractJsonStringField(line, "timestamp").?);
    try std.testing.expectEqualStrings("assistant", extractJsonStringField(line, "role").?);
    try std.testing.expect(extractJsonStringField(line, "missing") == null);
}

test "timestamp field extraction from blob" {
    const blob =
        "{\"timestamp\":\"2026-03-05T05:13:26Z\",\"role\":\"user\"}\n{\"timestamp\":\"2026-03-05T06:34:21Z\",\"role\":\"assistant\"}";
    try std.testing.expectEqualStrings("2026-03-05T05:13:26Z", firstTimestampField(blob).?);
    try std.testing.expectEqualStrings("2026-03-05T06:34:21Z", lastTimestampField(blob).?);
}

test "containsAnyNeedle basic matching" {
    try std.testing.expect(containsAnyNeedle("run learnings recall now", &RecallTextMarkers));
    try std.testing.expect(containsAnyNeedle("token failed with error", &FrictionTextMarkers));
}

test "value report file prefilter" {
    const recall_blob = "{\"role\":\"assistant\",\"text\":\"Run learnings recall before implementation\"}";
    try std.testing.expect(!shouldSkipValueReportFile(recall_blob, .learnings_nonrecall));
    try std.testing.expect(!shouldSkipValueReportFile(recall_blob, .impl_nonrecall));

    const learnings_blob = "{\"role\":\"user\",\"text\":\"append_learning wrote .learnings.jsonl\"}";
    try std.testing.expect(!shouldSkipValueReportFile(learnings_blob, .learnings_nonrecall));
    try std.testing.expect(shouldSkipValueReportFile(learnings_blob, .impl_nonrecall));

    const unrelated_blob = "{\"role\":\"user\",\"text\":\"plain status update\"}";
    try std.testing.expect(shouldSkipValueReportFile(unrelated_blob, .learnings_nonrecall));
    try std.testing.expect(!shouldSkipValueReportFile(unrelated_blob, .all_nonrecall));
}

test "condition action learning detection" {
    try std.testing.expect(isConditionActionLearning("When a run fails, prefer rerun with proof."));
    try std.testing.expect(isConditionActionLearning("If evidence is weak, skip capture."));
    try std.testing.expect(!isConditionActionLearning("Boundary parsing eliminated duplication."));
}

test "evidence anchor detection" {
    try std.testing.expect(evidenceHasAnchor("gh run 12345678 succeeded"));
    try std.testing.expect(evidenceHasAnchor("Updated codex/skills/learnings/SKILL.md and tests passed"));
    try std.testing.expect(!evidenceHasAnchor("General observation without anchors"));
}

test "relative delta helper" {
    const delta = relativeDelta(2.0, 1.0).?;
    try std.testing.expectApproxEqRel(@as(f64, 1.0), delta, 1e-6);
    try std.testing.expect(relativeDelta(null, 1.0) == null);
    try std.testing.expect(relativeDelta(1.0, 0.0) == null);
}

test "iso week basic" {
    const w = isoWeek(2026, 2, 23);
    try std.testing.expect(w.week >= 1);
}

fn fuzzTokenizeTarget(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    for (&storage) |*b| b.* = smith.value(u8);
    const len = smith.value(usize) % (storage.len + 1);
    const input = storage[0..len];
    var set = try tokenizeSet(std.testing.allocator, input);
    defer deinitOwnedStringSet(std.testing.allocator, &set);
}

test "fuzz tokenize set" {
    try std.testing.fuzz({}, fuzzTokenizeTarget, .{});
}

fn allocThemeTarget(allocator: std.mem.Allocator, text: []const u8) !void {
    const theme = try computeThemeAlloc(allocator, text, "");
    allocator.free(theme);
}

test "allocation failures computeThemeAlloc" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocThemeTarget, .{"zig token token token"});
}
