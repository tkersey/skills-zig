const std = @import("std");

pub const max_files = 4000;
pub const max_text_files = 800;
pub const default_read_limit = 20000;

const ignore_dirs = std.StaticStringMap(void).initComptime(.{
    .{ ".git", {} },
    .{ ".hg", {} },
    .{ ".svn", {} },
    .{ ".jj", {} },
    .{ ".xit", {} },
    .{ ".idea", {} },
    .{ ".vscode", {} },
    .{ "__pycache__", {} },
    .{ "node_modules", {} },
    .{ "vendor", {} },
    .{ "dist", {} },
    .{ "build", {} },
    .{ "target", {} },
    .{ ".next", {} },
    .{ ".nuxt", {} },
    .{ ".turbo", {} },
    .{ ".zig-cache", {} },
    .{ ".cache", {} },
    .{ "coverage", {} },
    .{ ".venv", {} },
    .{ "venv", {} },
    .{ "tmp", {} },
    .{ "temp", {} },
});

const text_suffixes = std.StaticStringMap(void).initComptime(.{
    .{ ".md", {} },
    .{ ".txt", {} },
    .{ ".rst", {} },
    .{ ".adoc", {} },
    .{ ".json", {} },
    .{ ".jsonc", {} },
    .{ ".yaml", {} },
    .{ ".yml", {} },
    .{ ".toml", {} },
    .{ ".ini", {} },
    .{ ".cfg", {} },
    .{ ".conf", {} },
    .{ ".properties", {} },
    .{ ".xml", {} },
    .{ ".proto", {} },
    .{ ".sql", {} },
    .{ ".tf", {} },
    .{ ".py", {} },
    .{ ".rb", {} },
    .{ ".go", {} },
    .{ ".rs", {} },
    .{ ".zig", {} },
    .{ ".ts", {} },
    .{ ".tsx", {} },
    .{ ".js", {} },
    .{ ".jsx", {} },
    .{ ".java", {} },
    .{ ".kt", {} },
    .{ ".kts", {} },
    .{ ".swift", {} },
    .{ ".c", {} },
    .{ ".cc", {} },
    .{ ".cpp", {} },
    .{ ".h", {} },
    .{ ".hpp", {} },
    .{ ".cs", {} },
    .{ ".php", {} },
    .{ ".sh", {} },
    .{ ".zsh", {} },
});

const text_names = std.StaticStringMap(void).initComptime(.{
    .{ "README", {} },
    .{ "README.md", {} },
    .{ "ARCHITECTURE.md", {} },
    .{ "Dockerfile", {} },
    .{ "Makefile", {} },
    .{ "Justfile", {} },
    .{ "Tiltfile", {} },
});

const doc_suffixes = std.StaticStringMap(void).initComptime(.{
    .{ ".md", {} },
    .{ ".txt", {} },
    .{ ".rst", {} },
    .{ ".adoc", {} },
});

const low_signal_parts = std.StaticStringMap(void).initComptime(.{
    .{ ".github", {} },
    .{ "github", {} },
    .{ "test", {} },
    .{ "tests", {} },
    .{ "spec", {} },
    .{ "specs", {} },
    .{ "fixtures", {} },
    .{ "examples", {} },
    .{ "docs", {} },
    .{ "doc", {} },
    .{ "references", {} },
    .{ "skill", {} },
    .{ "skills", {} },
    .{ "agent", {} },
    .{ "agents", {} },
});

const manifest_hints = std.StaticStringMap([]const u8).initComptime(.{
    .{ "package.json", "node" },
    .{ "pnpm-workspace.yaml", "workspace" },
    .{ "turbo.json", "workspace" },
    .{ "nx.json", "workspace" },
    .{ "pyproject.toml", "python" },
    .{ "requirements.txt", "python" },
    .{ "go.mod", "go" },
    .{ "Cargo.toml", "rust" },
    .{ "Gemfile", "ruby" },
    .{ "pom.xml", "jvm" },
    .{ "build.gradle", "jvm" },
    .{ "build.gradle.kts", "jvm" },
    .{ "build.zig", "zig" },
    .{ "Dockerfile", "container" },
    .{ "docker-compose.yml", "container" },
    .{ "docker-compose.yaml", "container" },
    .{ "flake.nix", "nix" },
});

const entrypoint_file_names = std.StaticStringMap(void).initComptime(.{
    .{ "main.py", {} },
    .{ "main.go", {} },
    .{ "main.rs", {} },
    .{ "main.ts", {} },
    .{ "main.tsx", {} },
    .{ "main.js", {} },
    .{ "main.jsx", {} },
    .{ "app.py", {} },
    .{ "app.ts", {} },
    .{ "app.tsx", {} },
    .{ "server.py", {} },
    .{ "server.ts", {} },
    .{ "server.js", {} },
    .{ "manage.py", {} },
    .{ "cli.py", {} },
});

const entrypoint_dir_parts = std.StaticStringMap(void).initComptime(.{
    .{ "cmd", {} },
    .{ "bin", {} },
    .{ "api", {} },
    .{ "server", {} },
    .{ "web", {} },
    .{ "app", {} },
    .{ "apps", {} },
});

const domain_import_tokens = std.StaticStringMap(void).initComptime(.{
    .{ "domain", {} },
    .{ "application", {} },
    .{ "usecase", {} },
    .{ "usecases", {} },
    .{ "core", {} },
    .{ "service", {} },
    .{ "services", {} },
    .{ "entity", {} },
    .{ "entities", {} },
    .{ "port", {} },
    .{ "ports", {} },
});

const infra_import_tokens = std.StaticStringMap(void).initComptime(.{
    .{ "adapter", {} },
    .{ "adapters", {} },
    .{ "repository", {} },
    .{ "repositories", {} },
    .{ "infra", {} },
    .{ "infrastructure", {} },
    .{ "db", {} },
    .{ "database", {} },
    .{ "storage", {} },
    .{ "persistence", {} },
    .{ "gateway", {} },
    .{ "gateways", {} },
});

const layered_import_tokens = std.StaticStringMap(void).initComptime(.{
    .{ "service", {} },
    .{ "services", {} },
    .{ "repository", {} },
    .{ "repositories", {} },
    .{ "model", {} },
    .{ "models", {} },
});

const plugin_dir_markers = std.StaticStringMap(void).initComptime(.{
    .{ "plugins", {} },
    .{ "extensions", {} },
    .{ "hooks", {} },
    .{ "providers", {} },
});

const pipeline_dir_markers = std.StaticStringMap(void).initComptime(.{
    .{ "pipelines", {} },
    .{ "dags", {} },
    .{ "jobs", {} },
    .{ "workflows", {} },
    .{ "etl", {} },
});

const apps_dir_markers = std.StaticStringMap(void).initComptime(.{
    .{ "apps", {} },
    .{ "services", {} },
    .{ "packages", {} },
});

const service_like_markers = std.StaticStringMap(void).initComptime(.{
    .{ "app", {} },
    .{ "apps", {} },
    .{ "api", {} },
    .{ "apis", {} },
    .{ "service", {} },
    .{ "services", {} },
    .{ "worker", {} },
    .{ "workers", {} },
});

const frontend_like_markers = std.StaticStringMap(void).initComptime(.{
    .{ "web", {} },
    .{ "frontend", {} },
    .{ "ui", {} },
    .{ "client", {} },
    .{ "components", {} },
    .{ "pages", {} },
    .{ "views", {} },
    .{ "screens", {} },
});

const cli_like_markers = std.StaticStringMap(void).initComptime(.{
    .{ "cmd", {} },
    .{ "bin", {} },
    .{ "scripts", {} },
    .{ "tools", {} },
});

const infra_like_markers = std.StaticStringMap(void).initComptime(.{
    .{ "terraform", {} },
    .{ "helm", {} },
    .{ "k8s", {} },
    .{ "ops", {} },
    .{ "deploy", {} },
    .{ "infra", {} },
});

const library_like_markers = std.StaticStringMap(void).initComptime(.{
    .{ "src", {} },
    .{ "lib", {} },
    .{ "include", {} },
    .{ "pkg", {} },
});

const library_contract_surface_markers = std.StaticStringMap(void).initComptime(.{
    .{ "docs", {} },
    .{ "examples", {} },
    .{ "example", {} },
    .{ "test", {} },
    .{ "tests", {} },
    .{ "bench", {} },
    .{ "benches", {} },
    .{ "benchmark", {} },
    .{ "benchmarks", {} },
});

const interesting_subsystem_markers = std.StaticStringMap(void).initComptime(.{
    .{ "apps", {} },
    .{ "services", {} },
    .{ "packages", {} },
    .{ "libs", {} },
    .{ "modules", {} },
    .{ "plugins", {} },
    .{ "extensions", {} },
    .{ "cmd", {} },
    .{ "internal", {} },
});

const deployment_topology_markers = std.StaticStringMap(void).initComptime(.{
    .{ "k8s", {} },
    .{ "helm", {} },
    .{ "deploy", {} },
    .{ "terraform", {} },
    .{ "infra", {} },
    .{ "ops", {} },
});

const message_topology_markers = std.StaticStringMap(void).initComptime(.{
    .{ "consumers", {} },
    .{ "publishers", {} },
    .{ "queues", {} },
    .{ "topics", {} },
});

const workflow_topology_markers = std.StaticStringMap(void).initComptime(.{
    .{ "dags", {} },
    .{ "workflows", {} },
    .{ "pipelines", {} },
    .{ "jobs", {} },
    .{ "etl", {} },
});

const architecture_marker_sets = [_]MarkerSet{
    .{ .name = "layered", .markers = &.{
        "controller", "controllers", "service", "services", "repository", "repositories", "model", "models", "handler", "handlers",
    } },
    .{ .name = "component-ui", .markers = &.{
        "components", "component", "views", "view", "viewmodels", "viewmodel", "screens", "pages", "frontend", "ui",
    } },
    .{ .name = "clean-hexagonal", .markers = &.{
        "domain", "application", "usecases", "usecase", "ports", "port", "adapters", "adapter", "infrastructure", "delivery",
    } },
    .{ .name = "modular-monolith", .markers = &.{
        "modules", "module", "packages", "package", "bounded-contexts", "bounded_contexts", "contexts", "apps",
    } },
    .{ .name = "microservice", .markers = &.{ "services", "service", "gateway", "gateways" } },
    .{ .name = "event-driven", .markers = &.{
        "events", "event", "consumers", "consumer", "publishers", "publisher", "subscribers", "subscriber", "queues", "queue", "topics",
    } },
    .{ .name = "pipeline", .markers = &.{
        "pipelines", "pipeline", "jobs", "job", "dags", "dag", "etl", "ingest", "transform", "load", "workflow", "workflows",
    } },
    .{ .name = "plugin", .markers = &.{ "plugins", "plugin", "extensions", "extension", "hooks", "providers", "adapters" } },
};

const zone_marker_sets = [_]MarkerSet{
    .{ .name = "delivery", .markers = &.{
        "api", "http", "controller", "controllers", "handler", "handlers", "route", "routes", "gateway", "gateways", "cli", "cmd",
    } },
    .{ .name = "domain", .markers = &.{
        "domain", "application", "usecase", "usecases", "core", "service", "services", "entity", "entities", "model", "models", "ports", "port",
    } },
    .{ .name = "infrastructure", .markers = &.{
        "repository", "repositories", "adapter", "adapters", "infrastructure", "infra", "db", "database", "storage", "persistence",
    } },
    .{ .name = "ui", .markers = &.{
        "component", "components", "view", "views", "viewmodel", "viewmodels", "pages", "screens", "frontend", "ui", "web",
    } },
};

const keyword_patterns = [_]KeywordPattern{
    .{ .name = "component-ui", .tokens = &.{ "component", "viewmodel", "screen", "page", "react", "vue", "svelte", "solid" } },
    .{ .name = "event-driven", .tokens = &.{ "kafka", "rabbitmq", "nats", "sns", "sqs", "pubsub", "topic", "consumer", "publisher", "subscribe", "eventbridge" } },
    .{ .name = "pipeline", .tokens = &.{ "airflow", "dagster", "prefect", "etl", "pipeline", "cron job", "batch job", "dag" } },
    .{ .name = "plugin", .tokens = &.{ "plugin", "hook registry", "provider interface", "extension point", "dynamic load" } },
    .{ .name = "microservice", .tokens = &.{ "service boundary", "grpc", "service-to-service", "microservice" } },
    .{ .name = "clean-hexagonal", .tokens = &.{ "ports and adapters", "use case", "usecase", "application service", "domain layer", "infrastructure layer" } },
};

const doc_patterns = [_][]const u8{
    "clean architecture",
    "hexagonal",
    "ports and adapters",
    "onion architecture",
    "layered architecture",
    "n-tier",
    "three-tier",
    "modular monolith",
    "microservice",
    "microservices",
    "service-oriented",
    "event-driven",
    "message-driven",
    "event bus",
    "pub/sub",
    "plugin system",
    "plugin architecture",
    "extension system",
    "mvc",
    "mvvm",
};

pub const ManifestHint = struct {
    kind: []const u8,
    path: []const u8,
};

pub const RepoKindHint = struct {
    reason: []const u8,
    repo_kind: []const u8,
};

pub const SignalEntry = struct {
    evidence: []const []const u8,
    name: []const u8,
    score: i64,
};

pub const DependencyHint = struct {
    detail: []const u8,
    effect: []const u8,
    path: []const u8,
    signal: []const u8,
};

pub const DocsClaim = struct {
    claim: []const u8,
    path: []const u8,
};

pub const EntrypointHint = struct {
    hint: []const u8,
    path: []const u8,
};

pub const RuntimeHint = struct {
    detail: []const u8,
    hint: []const u8,
    path: []const u8,
};

pub const SubsystemHint = struct {
    children: []const u8,
    hint: []const u8,
    path: []const u8,
};

pub const FocusObservation = struct {
    exists: bool,
    kind: ?[]const u8 = null,
    note: ?[]const u8 = null,
    path: []const u8,
    reason: ?[]const u8 = null,
    top_signals: ?[]const SignalEntry = null,
};

pub const ScanCoverage = struct {
    files_considered: usize,
    read_errors: usize,
    read_limit: usize,
    text_files_considered: usize,
    total_files_seen: usize,
    total_text_files_seen: usize,
    truncated_reads: usize,
};

pub const EvidenceSummary = struct {
    dependency_direction_hints: usize,
    docs_claims: usize,
    entrypoint_hints: usize,
    focus_path_observations: usize,
    manifests: usize,
    runtime_boundary_hints: usize,
    subsystem_hints: usize,
};

pub const Payload = struct {
    architecture_signals: []const SignalEntry,
    confidence_gaps: []const []const u8,
    dependency_direction_hints: []const DependencyHint,
    docs_claims: []const DocsClaim,
    entrypoint_hints: []const EntrypointHint,
    evidence_summary: EvidenceSummary,
    focus_path_observations: []const FocusObservation,
    manifests: []const ManifestHint,
    repo_kind_hints: []const RepoKindHint,
    repo_path: []const u8,
    read_depth_verdict: []const u8,
    requested_focus_paths: []const []const u8,
    runtime_boundary_hints: []const RuntimeHint,
    scan_coverage: ScanCoverage,
    suggested_focus_paths: []const []const u8,
    subsystem_hints: []const SubsystemHint,
    thin_signal_classes: []const []const u8,
    followup_hint: []const u8,
    top_level_dirs: []const []const u8,
};

pub const CollectOptions = struct {
    focus_paths: []const []const u8 = &.{},
    read_limit: usize = default_read_limit,
};

const MarkerSet = struct {
    name: []const u8,
    markers: []const []const u8,
};

const KeywordPattern = struct {
    name: []const u8,
    tokens: []const []const u8,
};

const FileRecord = struct {
    abs_path: []const u8,
    rel_path: []const u8,
};

const TextFileRecord = struct {
    abs_path: []const u8,
    content: []const u8,
    rel_path: []const u8,
};

const SignalBuilder = struct {
    name: []const u8,
    score: i64 = 0,
    evidence: std.ArrayList([]const u8) = .empty,

    fn appendEvidence(self: *SignalBuilder, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.evidence.append(allocator, value);
    }
};

const ReadDepthDiagnostics = struct {
    verdict: []const u8,
    thin_signal_classes: []const []const u8,
    suggested_focus_paths: []const []const u8,
    followup_hint: []const u8,
};

pub fn collect(allocator: std.mem.Allocator, repo_path: []const u8, options: CollectOptions) !Payload {
    const root_abs = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), repo_path, allocator);
    var root_dir = try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), root_abs, .{ .iterate = true });
    errdefer root_dir.close(std.Io.Threaded.global_single_threaded.io());

    const file_scan = try collectFiles(allocator, root_abs, root_dir, options.read_limit);
    const top_level_dirs = try collectTopLevelDirs(allocator, root_dir);
    const manifests = try collectManifests(allocator, file_scan.files, root_abs);
    const docs_claims = try collectDocsClaims(allocator, file_scan.text_files);
    const dependency_hints = try collectDependencyDirectionHints(allocator, file_scan.text_files);
    const entrypoint_hints = try collectEntrypointHints(allocator, file_scan.files);
    const runtime_hints = try collectRuntimeBoundaryHints(allocator, file_scan.files, top_level_dirs);
    const architecture_signals = try collectSignals(
        allocator,
        top_level_dirs,
        file_scan.text_files,
        dependency_hints,
        runtime_hints,
        entrypoint_hints,
    );
    const subsystem_hints = try collectSubsystemHints(allocator, root_abs, top_level_dirs);
    var confidence_gaps_list: std.ArrayList([]const u8) = .empty;
    const repo_kind_hints = try inferRepoKinds(allocator, manifests, top_level_dirs, architecture_signals, &confidence_gaps_list);
    const focus_observations = try collectFocusObservations(
        allocator,
        root_abs,
        top_level_dirs,
        file_scan.text_files,
        architecture_signals,
        options.focus_paths,
        options.read_limit,
    );

    if (manifests.len == 0) try confidence_gaps_list.append(allocator, "no common manifest file was detected");
    if (docs_claims.len == 0) try confidence_gaps_list.append(allocator, "no architecture claim was detected in README or architecture docs");
    if (top_level_dirs.len < 2) try confidence_gaps_list.append(allocator, "very few top-level directories were available for structural inference");
    if (file_scan.coverage.total_files_seen > file_scan.coverage.files_considered) {
        try confidence_gaps_list.append(allocator, try std.fmt.allocPrint(allocator, "file scan hit the {d} file cap; large-repo conclusions may be partial", .{max_files}));
    }
    if (file_scan.coverage.total_text_files_seen > file_scan.coverage.text_files_considered) {
        try confidence_gaps_list.append(allocator, try std.fmt.allocPrint(allocator, "text scan hit the {d} file cap; keyword and dependency evidence may be partial", .{max_text_files}));
    }
    if (hasWeakeningHint(dependency_hints)) {
        try confidence_gaps_list.append(allocator, "dependency-direction hints contain at least one architecture contradiction");
    }

    const confidence_gaps = try uniqueSortedStrings(allocator, confidence_gaps_list.items);
    const requested_focus_paths = try cloneStringSlice(allocator, options.focus_paths);
    const evidence_summary = EvidenceSummary{
        .dependency_direction_hints = dependency_hints.len,
        .docs_claims = docs_claims.len,
        .entrypoint_hints = entrypoint_hints.len,
        .focus_path_observations = focus_observations.len,
        .manifests = manifests.len,
        .runtime_boundary_hints = runtime_hints.len,
        .subsystem_hints = subsystem_hints.len,
    };
    const read_depth = try computeReadDepthDiagnostics(
        allocator,
        root_abs,
        top_level_dirs,
        manifests,
        repo_kind_hints,
        architecture_signals,
        evidence_summary,
        file_scan.coverage,
        options.focus_paths,
    );

    return .{
        .architecture_signals = architecture_signals,
        .confidence_gaps = confidence_gaps,
        .dependency_direction_hints = dependency_hints,
        .docs_claims = docs_claims,
        .entrypoint_hints = entrypoint_hints,
        .evidence_summary = evidence_summary,
        .focus_path_observations = focus_observations,
        .manifests = manifests,
        .repo_kind_hints = repo_kind_hints,
        .repo_path = root_abs,
        .read_depth_verdict = read_depth.verdict,
        .requested_focus_paths = requested_focus_paths,
        .runtime_boundary_hints = runtime_hints,
        .scan_coverage = .{
            .files_considered = file_scan.coverage.files_considered,
            .read_errors = file_scan.coverage.read_errors,
            .read_limit = options.read_limit,
            .text_files_considered = file_scan.coverage.text_files_considered,
            .total_files_seen = file_scan.coverage.total_files_seen,
            .total_text_files_seen = file_scan.coverage.total_text_files_seen,
            .truncated_reads = file_scan.coverage.truncated_reads,
        },
        .suggested_focus_paths = read_depth.suggested_focus_paths,
        .subsystem_hints = subsystem_hints,
        .thin_signal_classes = read_depth.thin_signal_classes,
        .followup_hint = read_depth.followup_hint,
        .top_level_dirs = top_level_dirs,
    };
}

pub fn writeJson(writer: anytype, payload: Payload) !void {
    try writer.print("{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
        .escape_unicode = true,
    })});
    try writer.writeByte('\n');
}

fn computeReadDepthDiagnostics(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    top_level_dirs: []const []const u8,
    manifests: []const ManifestHint,
    repo_kind_hints: []const RepoKindHint,
    architecture_signals: []const SignalEntry,
    evidence_summary: EvidenceSummary,
    coverage: ScanCoverage,
    focus_paths: []const []const u8,
) !ReadDepthDiagnostics {
    var thin_classes = std.ArrayList([]const u8).empty;
    var evidence_surfaces: usize = 0;

    if (repo_kind_hints.len > 0) {
        evidence_surfaces += 1;
    } else {
        try thin_classes.append(allocator, "repo_kind_hints");
    }

    if (evidence_summary.manifests > 0) {
        evidence_surfaces += 1;
    } else {
        try thin_classes.append(allocator, "manifests");
    }
    if (evidence_summary.docs_claims > 0) {
        evidence_surfaces += 1;
    } else {
        try thin_classes.append(allocator, "docs_claims");
    }
    if (evidence_summary.entrypoint_hints > 0) {
        evidence_surfaces += 1;
    } else {
        try thin_classes.append(allocator, "entrypoint_hints");
    }
    if (evidence_summary.dependency_direction_hints > 0) {
        evidence_surfaces += 1;
    } else {
        try thin_classes.append(allocator, "dependency_direction_hints");
    }
    if (evidence_summary.runtime_boundary_hints > 0) {
        evidence_surfaces += 1;
    } else {
        try thin_classes.append(allocator, "runtime_boundary_hints");
    }
    if (evidence_summary.subsystem_hints > 0) {
        evidence_surfaces += 1;
    } else {
        try thin_classes.append(allocator, "subsystem_hints");
    }

    const top_score = if (architecture_signals.len > 0) architecture_signals[0].score else 0;
    if (top_score >= 4) {
        evidence_surfaces += 1;
    } else {
        try thin_classes.append(allocator, "top_architecture_signal");
    }
    if (architecture_signals.len == 0) try thin_classes.append(allocator, "architecture_signals");
    if (coverage.total_files_seen > coverage.files_considered) try thin_classes.append(allocator, "file_scan_cap");
    if (coverage.total_text_files_seen > coverage.text_files_considered) try thin_classes.append(allocator, "text_scan_cap");
    if (coverage.read_errors > 0) try thin_classes.append(allocator, "read_errors");
    if (coverage.truncated_reads > 0) try thin_classes.append(allocator, "truncated_reads");

    const unique_thin_classes = try uniqueSortedStrings(allocator, thin_classes.items);
    if (focus_paths.len > 0) {
        return .{
            .verdict = "focused",
            .thin_signal_classes = unique_thin_classes,
            .suggested_focus_paths = &.{},
            .followup_hint = "",
        };
    }

    const thin_repo_wide = architecture_signals.len == 0 or
        evidence_surfaces < 3 or
        (repo_kind_hints.len == 0 and top_score <= 2);

    const suggested_focus_paths = if (thin_repo_wide)
        try suggestFocusPaths(allocator, root_abs, top_level_dirs, manifests)
    else
        &.{};

    return .{
        .verdict = if (thin_repo_wide) "thin_repo_wide" else "repo_wide_ok",
        .thin_signal_classes = unique_thin_classes,
        .suggested_focus_paths = suggested_focus_paths,
        .followup_hint = if (thin_repo_wide and suggested_focus_paths.len > 0)
            "Repo-wide signals are thin. Rerun collect with the suggested focus paths before broader manual inspection."
        else
            "",
    };
}

fn suggestFocusPaths(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    top_level_dirs: []const []const u8,
    manifests: []const ManifestHint,
) ![]const []const u8 {
    var paths = std.ArrayList([]const u8).empty;
    for (manifests) |manifest| try appendUniquePath(allocator, &paths, manifest.path);

    const preferred_dirs = [_][]const u8{
        "src",
        "app",
        "apps",
        "packages",
        "cmd",
        "cli",
        "lib",
        "internal",
        "core",
        "services",
        "modules",
        "plugins",
        "providers",
        "hooks",
        "pipelines",
        "workflows",
        "dags",
        "jobs",
        "etl",
        "infra",
        "terraform",
        "helm",
        "k8s",
        "ops",
        "tools",
        "codex",
        "nvim",
        ".config",
        ".github",
        "docs",
        "test",
        "tests",
        "examples",
        "bench",
        "benches",
    };
    for (preferred_dirs) |candidate| {
        if (containsString(top_level_dirs, candidate)) try appendUniquePath(allocator, &paths, candidate);
    }

    const preferred_files = [_][]const u8{
        "README.md",
        "README",
        "ARCHITECTURE.md",
        "FORMAL_CORE.md",
        "AGENTS.md",
        "docs/ARCHITECTURE.md",
        "docs/research_decision.md",
    };
    for (preferred_files) |candidate| {
        if (repoPathExists(root_abs, candidate)) try appendUniquePath(allocator, &paths, candidate);
    }

    return try paths.toOwnedSlice(allocator);
}

fn appendUniquePath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]const u8),
    candidate: []const u8,
) !void {
    if (candidate.len == 0) return;
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, candidate)) return;
    }
    try paths.append(allocator, try allocator.dupe(u8, candidate));
}

fn containsString(items: []const []const u8, target: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, target)) return true;
    }
    return false;
}

fn repoPathExists(root_abs: []const u8, rel_path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), root_abs, .{}) catch return false;
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    _ = dir.statFile(std.Io.Threaded.global_single_threaded.io(), rel_path, .{}) catch return false;
    return true;
}

const FileScanResult = struct {
    coverage: ScanCoverage,
    files: []const FileRecord,
    text_files: []const TextFileRecord,
};

fn collectFiles(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    root_dir: std.Io.Dir,
    read_limit: usize,
) !FileScanResult {
    var all_files: std.ArrayList(FileRecord) = .empty;
    var walk = try root_dir.walk(allocator);
    defer walk.deinit();

    while (try walk.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file) continue;
        if (shouldSkipEntry(entry.path)) continue;
        const rel_path = try allocator.dupe(u8, entry.path);
        const abs_path = try std.fs.path.join(allocator, &.{ root_abs, entry.path });
        try all_files.append(allocator, .{ .abs_path = abs_path, .rel_path = rel_path });
    }

    std.mem.sort(FileRecord, all_files.items, {}, struct {
        fn lessThan(_: void, a: FileRecord, b: FileRecord) bool {
            return std.mem.order(u8, a.abs_path, b.abs_path) == .lt;
        }
    }.lessThan);

    var text_candidates: std.ArrayList(FileRecord) = .empty;
    for (all_files.items) |file| {
        if (isTextFile(file.rel_path)) try text_candidates.append(allocator, file);
    }

    var coverage = ScanCoverage{
        .files_considered = @min(all_files.items.len, max_files),
        .read_errors = 0,
        .read_limit = read_limit,
        .text_files_considered = @min(text_candidates.items.len, max_text_files),
        .total_files_seen = all_files.items.len,
        .total_text_files_seen = text_candidates.items.len,
        .truncated_reads = 0,
    };

    const limited_files = try cloneFileRecordSlice(allocator, all_files.items[0..coverage.files_considered]);

    var limited_text_files_list: std.ArrayList(TextFileRecord) = .empty;
    const candidate_slice = text_candidates.items[0..coverage.text_files_considered];
    for (candidate_slice) |file| {
        const content = try readLimitedFile(allocator, file.abs_path, read_limit, &coverage);
        try limited_text_files_list.append(allocator, .{
            .abs_path = file.abs_path,
            .content = content,
            .rel_path = file.rel_path,
        });
    }

    return .{
        .coverage = coverage,
        .files = limited_files,
        .text_files = try limited_text_files_list.toOwnedSlice(allocator),
    };
}

fn shouldSkipEntry(rel_path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, rel_path, std.fs.path.sep);
    while (parts.next()) |part| {
        if (ignore_dirs.has(part)) return true;
        if (std.mem.startsWith(u8, part, ".cache")) return true;
        if (std.mem.startsWith(u8, part, ".venv")) return true;
    }
    return false;
}

fn isTextFile(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (text_names.has(base)) return true;
    const ext = std.fs.path.extension(path);
    return text_suffixes.has(ext);
}

fn isDocFile(path: []const u8) bool {
    return doc_suffixes.has(std.fs.path.extension(path));
}

fn hasLowSignalPart(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (parts.next()) |part| {
        if (low_signal_parts.has(part)) return true;
    }
    return false;
}

fn readLimitedFile(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    limit: usize,
    coverage: *ScanCoverage,
) ![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), abs_path, .{}) catch {
        coverage.read_errors += 1;
        return "";
    };
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(limit + 1)) catch {
        coverage.read_errors += 1;
        return "";
    };
    if (bytes.len > limit) {
        coverage.truncated_reads += 1;
        return bytes[0..limit];
    }
    return bytes;
}

fn collectTopLevelDirs(allocator: std.mem.Allocator, root_dir: std.Io.Dir) ![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    var it = root_dir.iterate();
    while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .directory) continue;
        if (ignoreDirsLike(entry.name)) continue;
        try entries.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, entries.items, {}, stringLessThan);
    return try entries.toOwnedSlice(allocator);
}

fn ignoreDirsLike(name: []const u8) bool {
    return ignore_dirs.has(name);
}

fn collectManifests(
    allocator: std.mem.Allocator,
    files: []const FileRecord,
    root_abs: []const u8,
) ![]const ManifestHint {
    _ = root_abs;
    var manifests: std.ArrayList(ManifestHint) = .empty;
    for (files) |file| {
        const base = std.fs.path.basename(file.rel_path);
        const kind = manifest_hints.get(base) orelse continue;
        try manifests.append(allocator, .{
            .kind = kind,
            .path = file.rel_path,
        });
    }
    return try manifests.toOwnedSlice(allocator);
}

fn collectDocsClaims(allocator: std.mem.Allocator, text_files: []const TextFileRecord) ![]const DocsClaim {
    var claims: std.ArrayList(DocsClaim) = .empty;
    for (text_files) |file| {
        if (!isDocsCandidate(file.rel_path)) continue;
        for (doc_patterns) |pattern| {
            if (containsIgnoreCase(file.content, pattern)) {
                try claims.append(allocator, .{
                    .claim = try allocator.dupe(u8, pattern),
                    .path = file.rel_path,
                });
            }
        }
    }
    if (claims.items.len > 50) claims.shrinkRetainingCapacity(50);
    return try claims.toOwnedSlice(allocator);
}

fn isDocsCandidate(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, base) catch return false;
    defer std.heap.page_allocator.free(lower);
    return std.mem.indexOf(u8, lower, "readme") != null or std.mem.indexOf(u8, lower, "architecture") != null or std.mem.indexOf(u8, lower, "adr") != null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn collectDependencyDirectionHints(allocator: std.mem.Allocator, text_files: []const TextFileRecord) ![]const DependencyHint {
    var hints: std.ArrayList(DependencyHint) = .empty;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (text_files) |file| {
        if (!shouldScanKeywords(file.rel_path)) continue;
        const zones = classifyZones(allocator, file.rel_path) catch &.{};
        if (zones.len == 0) continue;
        const tokens = try extractImportTokens(allocator, file.content);
        if (tokens.count() == 0) continue;

        if (containsZone(zones, "domain")) {
            if (try joinTokenSubset(allocator, tokens, infra_import_tokens)) |imports| {
                try addDependencyHint(allocator, &hints, &seen, file.rel_path, "clean-hexagonal", "weakens", try std.fmt.allocPrint(allocator, "domain-like module imports infrastructure tokens: {s}", .{imports}));
            }
        }
        if (containsAnyZone(zones, &.{ "delivery", "ui" })) {
            if (try joinTokenSubset(allocator, tokens, domain_import_tokens)) |imports| {
                try addDependencyHint(allocator, &hints, &seen, file.rel_path, "clean-hexagonal", "supports", try std.fmt.allocPrint(allocator, "delivery-like module imports domain/application tokens: {s}", .{imports}));
            }
        }
        if (containsZone(zones, "infrastructure")) {
            if (try joinTokenSubset(allocator, tokens, domain_import_tokens)) |imports| {
                try addDependencyHint(allocator, &hints, &seen, file.rel_path, "clean-hexagonal", "supports", try std.fmt.allocPrint(allocator, "adapter-like module imports domain/application tokens: {s}", .{imports}));
            }
        }
        if (containsZone(zones, "delivery")) {
            if (try joinTokenSubset(allocator, tokens, layered_import_tokens)) |imports| {
                try addDependencyHint(allocator, &hints, &seen, file.rel_path, "layered", "supports", try std.fmt.allocPrint(allocator, "delivery-like module imports service/repository tokens: {s}", .{imports}));
            }
        }
    }

    if (hints.items.len > 24) hints.shrinkRetainingCapacity(24);
    return try hints.toOwnedSlice(allocator);
}

fn shouldScanKeywords(path: []const u8) bool {
    if (isDocFile(path)) return false;
    return !hasLowSignalPart(path);
}

fn classifyZones(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var zones: std.ArrayList([]const u8) = .empty;
    for (zone_marker_sets) |marker_set| {
        if (firstMatchingPathMarker(path, marker_set.markers) != null) {
            try zones.append(allocator, marker_set.name);
        }
    }
    return try zones.toOwnedSlice(allocator);
}

fn containsZone(zones: []const []const u8, target: []const u8) bool {
    for (zones) |zone| {
        if (std.mem.eql(u8, zone, target)) return true;
    }
    return false;
}

fn containsAnyZone(zones: []const []const u8, targets: []const []const u8) bool {
    for (targets) |target| if (containsZone(zones, target)) return true;
    return false;
}

fn extractImportTokens(allocator: std.mem.Allocator, content: []const u8) !std.StringHashMap(void) {
    var tokens = std.StringHashMap(void).init(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        try parseImportLine(allocator, &tokens, line);
    }
    return tokens;
}

fn parseImportLine(allocator: std.mem.Allocator, tokens: *std.StringHashMap(void), line_raw: []const u8) !void {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (line.len == 0) return;

    if (std.mem.startsWith(u8, line, "from ")) {
        var rest = line["from ".len..];
        if (std.mem.indexOf(u8, rest, " import ")) |idx| {
            rest = rest[0..idx];
        }
        try addNormalizedImportTokens(allocator, tokens, rest);
    } else if (std.mem.startsWith(u8, line, "import ")) {
        try addNormalizedImportTokens(allocator, tokens, line["import ".len..]);
    } else if (std.mem.startsWith(u8, line, "use ")) {
        try addNormalizedImportTokens(allocator, tokens, line["use ".len..]);
    }

    var idx: usize = 0;
    while (idx < line.len) : (idx += 1) {
        if (line[idx] == '"' or line[idx] == '\'') {
            const quote = line[idx];
            const start = idx + 1;
            idx += 1;
            while (idx < line.len and line[idx] != quote) : (idx += 1) {}
            if (idx > start) {
                try addNormalizedImportTokens(allocator, tokens, line[start..idx]);
            }
        }
    }
}

fn addNormalizedImportTokens(
    allocator: std.mem.Allocator,
    tokens: *std.StringHashMap(void),
    raw: []const u8,
) !void {
    var normalized = std.ArrayList(u8).empty;
    for (raw) |ch| {
        const next = switch (ch) {
            ':', '.', '\\' => '/',
            else => ch,
        };
        try normalized.append(allocator, next);
    }
    const trimmed = std.mem.trim(u8, normalized.items, "./");
    var start: usize = 0;
    for (trimmed, 0..) |ch, idx| {
        if (!std.ascii.isAlphanumeric(ch)) {
            if (idx > start) try putLowerToken(allocator, tokens, trimmed[start..idx]);
            start = idx + 1;
        }
    }
    if (trimmed.len > start) try putLowerToken(allocator, tokens, trimmed[start..]);
}

fn putLowerToken(
    allocator: std.mem.Allocator,
    tokens: *std.StringHashMap(void),
    raw: []const u8,
) !void {
    if (raw.len == 0) return;
    const lower = try std.ascii.allocLowerString(allocator, raw);
    try tokens.put(lower, {});
}

fn joinTokenSubset(
    allocator: std.mem.Allocator,
    tokens: std.StringHashMap(void),
    subset: std.StaticStringMap(void),
) !?[]const u8 {
    var matches = std.ArrayList([]const u8).empty;
    var it = tokens.iterator();
    while (it.next()) |entry| {
        if (!subset.has(entry.key_ptr.*)) continue;
        try matches.append(allocator, entry.key_ptr.*);
    }
    if (matches.items.len == 0) return null;
    std.mem.sort([]const u8, matches.items, {}, stringLessThan);
    if (matches.items.len > 4) matches.shrinkRetainingCapacity(4);
    return try std.mem.join(allocator, ", ", matches.items);
}

fn addDependencyHint(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(DependencyHint),
    seen: *std.StringHashMap(void),
    rel_path: []const u8,
    signal: []const u8,
    effect: []const u8,
    detail: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ rel_path, signal, effect });
    if (seen.contains(key)) return;
    try seen.put(key, {});
    try hints.append(allocator, .{
        .detail = detail,
        .effect = effect,
        .path = rel_path,
        .signal = signal,
    });
}

fn collectEntrypointHints(allocator: std.mem.Allocator, files: []const FileRecord) ![]const EntrypointHint {
    var hints: std.ArrayList(EntrypointHint) = .empty;
    for (files) |file| {
        const rel = file.rel_path;
        const base = std.fs.path.basename(rel);
        var hint: ?[]const u8 = null;
        if (entrypoint_file_names.has(base)) {
            hint = "entrypoint candidate";
        } else if (hasFirstPathPart(rel, "cmd") or hasFirstPathPart(rel, "bin")) {
            hint = "cli entrypoint";
        } else if (std.mem.eql(u8, base, "index.tsx") or std.mem.eql(u8, base, "index.jsx") or std.mem.eql(u8, base, "main.tsx") or std.mem.eql(u8, base, "app.tsx")) {
            hint = "ui entrypoint";
        } else if (firstPathPart(rel)) |first| {
            if (entrypoint_dir_parts.has(first)) hint = "runnable surface";
        }
        if (hint) |value| try hints.append(allocator, .{ .hint = value, .path = rel });
    }
    if (hints.items.len > 20) hints.shrinkRetainingCapacity(20);
    return try hints.toOwnedSlice(allocator);
}

fn collectRuntimeBoundaryHints(
    allocator: std.mem.Allocator,
    files: []const FileRecord,
    top_level_dirs: []const []const u8,
) ![]const RuntimeHint {
    var hints: std.ArrayList(RuntimeHint) = .empty;
    var service_units = std.StringHashMap(void).init(allocator);
    defer service_units.deinit();
    var app_units = std.StringHashMap(void).init(allocator);
    defer app_units.deinit();

    for (files) |file| {
        const rel = file.rel_path;
        const base = std.fs.path.basename(rel);
        if (std.mem.eql(u8, base, "docker-compose.yml") or std.mem.eql(u8, base, "docker-compose.yaml")) {
            try hints.append(allocator, .{
                .detail = "compose file suggests multiple runnable units or local service topology",
                .hint = "local orchestration surface",
                .path = rel,
            });
        }

        if (nthPathPart(rel, 0)) |first| {
            if (std.mem.eql(u8, first, "services")) {
                if (nthPathPart(rel, 1)) |service_name| {
                    if (isServiceRuntimeMarker(base)) try service_units.put(service_name, {});
                }
            }
            if (std.mem.eql(u8, first, "apps")) {
                if (nthPathPart(rel, 1)) |app_name| {
                    try app_units.put(app_name, {});
                }
            }
        }
    }

    if (service_units.count() >= 2) {
        const names = try joinMapKeys(allocator, service_units, 4);
        try hints.append(allocator, .{
            .detail = try std.fmt.allocPrint(allocator, "multiple service folders have dedicated manifests or container surfaces: {s}", .{names}),
            .hint = "multiple service runtime units",
            .path = "services/",
        });
    }
    if (app_units.count() >= 2) {
        const names = try joinMapKeys(allocator, app_units, 4);
        try hints.append(allocator, .{
            .detail = try std.fmt.allocPrint(allocator, "multiple app folders are present: {s}", .{names}),
            .hint = "multiple app units",
            .path = "apps/",
        });
    }

    if (try intersectTopLevelMarkers(allocator, top_level_dirs, deployment_topology_markers)) |names| {
        try hints.append(allocator, .{
            .detail = "infra or deployment directories may reveal runtime boundaries",
            .hint = "deployment topology surface",
            .path = names,
        });
    }
    if (try intersectTopLevelMarkers(allocator, top_level_dirs, message_topology_markers)) |names| {
        try hints.append(allocator, .{
            .detail = "messaging directories suggest event or queue boundaries are first-class",
            .hint = "message topology surface",
            .path = names,
        });
    }
    if (try intersectTopLevelMarkers(allocator, top_level_dirs, workflow_topology_markers)) |names| {
        try hints.append(allocator, .{
            .detail = "workflow directories suggest stage or job boundaries dominate execution",
            .hint = "workflow topology surface",
            .path = names,
        });
    }
    if (hints.items.len > 12) hints.shrinkRetainingCapacity(12);
    return try hints.toOwnedSlice(allocator);
}

fn isServiceRuntimeMarker(base: []const u8) bool {
    return std.mem.eql(u8, base, "Dockerfile") or
        std.mem.eql(u8, base, "package.json") or
        std.mem.eql(u8, base, "pyproject.toml") or
        std.mem.eql(u8, base, "go.mod") or
        std.mem.eql(u8, base, "Cargo.toml");
}

fn collectSignals(
    allocator: std.mem.Allocator,
    top_level_dirs: []const []const u8,
    text_files: []const TextFileRecord,
    dependency_hints: []const DependencyHint,
    runtime_hints: []const RuntimeHint,
    entrypoint_hints: []const EntrypointHint,
) ![]const SignalEntry {
    var signal_builders = std.StringHashMap(SignalBuilder).init(allocator);
    defer signal_builders.deinit();

    const library_root_count = countTopLevelMatches(top_level_dirs, library_like_markers);
    const contract_surface_count = countTopLevelMatches(top_level_dirs, library_contract_surface_markers);
    const app_like_count = countTopLevelMatches(top_level_dirs, service_like_markers) +
        countTopLevelMatches(top_level_dirs, frontend_like_markers) +
        countTopLevelMatches(top_level_dirs, apps_dir_markers);

    if (library_root_count >= 1 and contract_surface_count >= 3 and app_like_count == 0) {
        if (try intersectTopLevelMarkers(allocator, top_level_dirs, library_contract_surface_markers)) |names| {
            const signal = try getSignalBuilder(allocator, &signal_builders, "modular-monolith");
            signal.score += 4;
            try signal.appendEvidence(allocator, try std.fmt.allocPrint(
                allocator,
                "library contract surfaces: src plus {s}",
                .{names},
            ));
        }
    }

    for (architecture_marker_sets) |marker_set| {
        var overlaps = std.ArrayList([]const u8).empty;
        for (top_level_dirs) |dir_name| {
            if (containsMarker(marker_set.markers, dir_name)) {
                try overlaps.append(allocator, dir_name);
            }
        }
        if (overlaps.items.len > 0) {
            const signal = try getSignalBuilder(allocator, &signal_builders, marker_set.name);
            signal.score += @min(@as(i64, @intCast(overlaps.items.len)), 4);
            try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, "top-level dirs: {s}", .{try std.mem.join(allocator, ", ", overlaps.items)}));
        }
    }

    var path_hits = std.StringHashMap(std.StringHashMap(std.ArrayList([]const u8))).init(allocator);
    defer path_hits.deinit();
    var keyword_hits = std.StringHashMap(std.StringHashMap(std.ArrayList([]const u8))).init(allocator);
    defer keyword_hits.deinit();

    for (text_files) |file| {
        if (!hasLowSignalPart(file.rel_path)) {
            for (architecture_marker_sets) |marker_set| {
                if (firstMatchingPathMarker(file.rel_path, marker_set.markers)) |marker| {
                    try rememberHit(allocator, &path_hits, marker_set.name, marker, file.rel_path, 2);
                }
            }
        }

        if (!shouldScanKeywords(file.rel_path)) continue;
        for (keyword_patterns) |pattern| {
            var matches = std.ArrayList([]const u8).empty;
            for (pattern.tokens) |token| {
                if (containsIgnoreCase(file.content, token)) {
                    try matches.append(allocator, try std.ascii.allocLowerString(allocator, token));
                }
            }
            if (matches.items.len == 0) continue;
            std.mem.sort([]const u8, matches.items, {}, stringLessThan);
            const unique_matches = try uniqueSortedStrings(allocator, matches.items);
            for (unique_matches[0..@min(unique_matches.len, 4)]) |match| {
                try rememberHit(allocator, &keyword_hits, pattern.name, match, file.rel_path, 2);
            }
        }
    }

    try applyNestedHits(allocator, &signal_builders, path_hits, "path marker {s}: {s}");
    try applyNestedHits(allocator, &signal_builders, keyword_hits, "{s}: {s}");

    for (dependency_hints) |hint| {
        const signal = try getSignalBuilder(allocator, &signal_builders, hint.signal);
        signal.score += if (std.mem.eql(u8, hint.effect, "supports")) 2 else -2;
        if (signal.evidence.items.len < 10) {
            try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, "dependency hint: {s} ({s})", .{ hint.path, hint.detail }));
        }
    }

    for (runtime_hints) |hint| {
        if (std.mem.indexOf(u8, hint.hint, "service runtime units") != null) {
            const signal = try getSignalBuilder(allocator, &signal_builders, "microservice");
            signal.score += 6;
            try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, "runtime hint: {s}", .{hint.detail}));
        }
        if (std.mem.indexOf(u8, hint.hint, "local orchestration surface") != null) {
            const signal = try getSignalBuilder(allocator, &signal_builders, "microservice");
            signal.score += 1;
            if (signal.evidence.items.len < 10) try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, "runtime hint: {s}", .{hint.detail}));
        }
        if (std.mem.indexOf(u8, hint.hint, "multiple app units") != null) {
            const signal = try getSignalBuilder(allocator, &signal_builders, "modular-monolith");
            signal.score += 1;
            try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, "runtime hint: {s}", .{hint.detail}));
        }
        if (std.mem.indexOf(u8, hint.hint, "message topology") != null) {
            const signal = try getSignalBuilder(allocator, &signal_builders, "event-driven");
            signal.score += 3;
            try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, "runtime hint: {s}", .{hint.detail}));
        }
        if (std.mem.indexOf(u8, hint.hint, "workflow topology") != null) {
            const signal = try getSignalBuilder(allocator, &signal_builders, "pipeline");
            signal.score += 3;
            try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, "runtime hint: {s}", .{hint.detail}));
        }
    }

    for (entrypoint_hints) |hint| {
        if (std.mem.eql(u8, hint.hint, "ui entrypoint")) {
            const signal = try getSignalBuilder(allocator, &signal_builders, "component-ui");
            signal.score += 1;
            if (signal.evidence.items.len < 10) try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, "entrypoint hint: {s}", .{hint.path}));
        }
    }

    var signals = std.ArrayList(SignalEntry).empty;
    var it = signal_builders.iterator();
    while (it.next()) |entry| {
        try signals.append(allocator, .{
            .evidence = try entry.value_ptr.evidence.toOwnedSlice(allocator),
            .name = entry.key_ptr.*,
            .score = entry.value_ptr.score,
        });
    }
    std.mem.sort(SignalEntry, signals.items, {}, struct {
        fn lessThan(_: void, a: SignalEntry, b: SignalEntry) bool {
            if (a.score == b.score) return std.mem.order(u8, a.name, b.name) == .lt;
            return a.score > b.score;
        }
    }.lessThan);
    return try signals.toOwnedSlice(allocator);
}

fn containsMarker(markers: []const []const u8, value: []const u8) bool {
    for (markers) |marker| {
        if (std.mem.eql(u8, marker, value)) return true;
    }
    return false;
}

fn firstMatchingPathMarker(path: []const u8, markers: []const []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (parts.next()) |part| {
        for (markers) |marker| {
            if (std.mem.eql(u8, part, marker)) return marker;
        }
    }
    return null;
}

fn rememberHit(
    allocator: std.mem.Allocator,
    outer: *std.StringHashMap(std.StringHashMap(std.ArrayList([]const u8))),
    signal_name: []const u8,
    key_name: []const u8,
    path: []const u8,
    max_paths: usize,
) !void {
    const gop = try outer.getOrPut(signal_name);
    if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    const inner_gop = try gop.value_ptr.getOrPut(key_name);
    if (!inner_gop.found_existing) inner_gop.value_ptr.* = .empty;
    if (inner_gop.value_ptr.items.len >= max_paths) return;
    try inner_gop.value_ptr.append(allocator, path);
}

fn applyNestedHits(
    allocator: std.mem.Allocator,
    builders: *std.StringHashMap(SignalBuilder),
    hits: std.StringHashMap(std.StringHashMap(std.ArrayList([]const u8))),
    comptime format: []const u8,
) !void {
    var outer_it = hits.iterator();
    while (outer_it.next()) |outer_entry| {
        const signal = try getSignalBuilder(allocator, builders, outer_entry.key_ptr.*);
        signal.score += @min(@as(i64, @intCast(outer_entry.value_ptr.count())), 4);
        var keys = std.ArrayList([]const u8).empty;
        var inner_it_a = outer_entry.value_ptr.iterator();
        while (inner_it_a.next()) |inner_entry| try keys.append(allocator, inner_entry.key_ptr.*);
        std.mem.sort([]const u8, keys.items, {}, stringLessThan);
        for (keys.items[0..@min(keys.items.len, 4)]) |key| {
            const paths = outer_entry.value_ptr.getPtr(key).?.items;
            if (signal.evidence.items.len < 10 and paths.len > 0) {
                try signal.appendEvidence(allocator, try std.fmt.allocPrint(allocator, format, .{ key, paths[0] }));
            }
        }
    }
}

fn getSignalBuilder(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(SignalBuilder),
    name: []const u8,
) !*SignalBuilder {
    const gop = try map.getOrPut(name);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .name = try allocator.dupe(u8, name),
        };
    }
    return gop.value_ptr;
}

fn collectSubsystemHints(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    top_level_dirs: []const []const u8,
) ![]const SubsystemHint {
    var hints: std.ArrayList(SubsystemHint) = .empty;
    for (top_level_dirs) |dir_name| {
        if (!interesting_subsystem_markers.has(dir_name)) continue;
        const abs_path = try std.fs.path.join(allocator, &.{ root_abs, dir_name });
        var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), abs_path, .{ .iterate = true }) catch continue;
        defer dir.close(std.Io.Threaded.global_single_threaded.io());
        var children = std.ArrayList([]const u8).empty;
        var it = dir.iterate();
        while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
            if (entry.kind != .directory) continue;
            if (ignoreDirsLike(entry.name)) continue;
            try children.append(allocator, try allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, children.items, {}, stringLessThan);
        if (children.items.len > 10) children.shrinkRetainingCapacity(10);
        try hints.append(allocator, .{
            .children = if (children.items.len == 0) "none" else try std.mem.join(allocator, ", ", children.items),
            .hint = "subsystem container",
            .path = dir_name,
        });
    }
    return try hints.toOwnedSlice(allocator);
}

fn inferRepoKinds(
    allocator: std.mem.Allocator,
    manifests: []const ManifestHint,
    top_level_dirs: []const []const u8,
    signals: []const SignalEntry,
    confidence_gaps: *std.ArrayList([]const u8),
) ![]const RepoKindHint {
    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();

    for (manifests) |manifest| {
        const current = counts.get(manifest.kind) orelse 0;
        try counts.put(manifest.kind, current + 1);
    }

    try counts.put("plugin", countTopLevelMatches(top_level_dirs, plugin_dir_markers));
    try counts.put("pipeline", countTopLevelMatches(top_level_dirs, pipeline_dir_markers));
    try counts.put("apps_dir", countTopLevelMatches(top_level_dirs, apps_dir_markers));
    try counts.put("service_like", countTopLevelMatches(top_level_dirs, service_like_markers));
    try counts.put("frontend_like", countTopLevelMatches(top_level_dirs, frontend_like_markers));
    try counts.put("cli_like", countTopLevelMatches(top_level_dirs, cli_like_markers));
    try counts.put("infra_like", countTopLevelMatches(top_level_dirs, infra_like_markers));
    try counts.put("library_like", countTopLevelMatches(top_level_dirs, library_like_markers));

    var hints = std.ArrayList(RepoKindHint).empty;
    if (getCount(counts, "plugin") >= 1) try hints.append(allocator, .{ .reason = "plugin or extension directories are present", .repo_kind = "plugin-extension" });
    if (getCount(counts, "pipeline") >= 3) try hints.append(allocator, .{ .reason = "pipeline and workflow directories dominate the repo", .repo_kind = "data-pipeline" });
    if (getCount(counts, "workspace") >= 1 or getCount(counts, "apps_dir") >= 2) try hints.append(allocator, .{ .reason = "workspace manifests or multi-app containers are present", .repo_kind = "monorepo-platform" });
    if (getCount(counts, "infra_like") >= 2) try hints.append(allocator, .{ .reason = "infra or deployment directories are prominent", .repo_kind = "infra-ops" });
    if (getCount(counts, "cli_like") >= 2) try hints.append(allocator, .{ .reason = "tooling entrypoints dominate the repo", .repo_kind = "cli-tooling" });
    if (getCount(counts, "service_like") >= 2 or getCount(counts, "frontend_like") >= 2) {
        const reason = if (getCount(counts, "frontend_like") >= 2 and getCount(counts, "service_like") < 2)
            "frontend or UI app directories dominate the repo"
        else
            "application or service directories are prominent";
        try hints.append(allocator, .{ .reason = reason, .repo_kind = "application-service" });
    }
    if (getCount(counts, "library_like") >= 1) try hints.append(allocator, .{ .reason = "library-style source roots are present", .repo_kind = "library-sdk" });

    if (hints.items.len == 0) {
        try confidence_gaps.append(allocator, "repo kind is weakly signaled; inspect entrypoints and packaging surfaces manually");
    }
    if (signals.len == 0) {
        try confidence_gaps.append(allocator, "architecture signals are sparse; inspect representative modules manually");
    }
    if (signals.len > 0 and signals[0].score <= 2) {
        try confidence_gaps.append(allocator, "top architecture signal is weak; avoid high-confidence claims");
    }

    if (hints.items.len > 3) hints.shrinkRetainingCapacity(3);
    return try hints.toOwnedSlice(allocator);
}

fn countTopLevelMatches(top_level_dirs: []const []const u8, markers: std.StaticStringMap(void)) usize {
    var count: usize = 0;
    for (top_level_dirs) |dir_name| {
        if (markers.has(dir_name)) count += 1;
    }
    return count;
}

fn getCount(counts: std.StringHashMap(usize), key: []const u8) usize {
    return counts.get(key) orelse 0;
}

fn collectFocusObservations(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    top_level_dirs: []const []const u8,
    text_files: []const TextFileRecord,
    repo_signals: []const SignalEntry,
    focus_paths: []const []const u8,
    read_limit: usize,
) ![]const FocusObservation {
    _ = top_level_dirs;
    _ = read_limit;
    var observations = std.ArrayList(FocusObservation).empty;
    const repo_top_signal = if (repo_signals.len > 0) repo_signals[0].name else null;

    for (focus_paths) |raw_path| {
        const joined = try std.fs.path.join(allocator, &.{ root_abs, raw_path });
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), joined, allocator) catch {
            try observations.append(allocator, .{
                .exists = false,
                .path = raw_path,
                .reason = "focus path not found",
            });
            continue;
        };
        if (!std.mem.startsWith(u8, resolved, root_abs)) {
            try observations.append(allocator, .{
                .exists = false,
                .path = raw_path,
                .reason = "focus path escapes repo root",
            });
            continue;
        }

        const top_signals = try collectFocusSignals(allocator, root_abs, resolved, text_files);
        const note = blk: {
            if (repo_top_signal != null and top_signals.len > 0 and !std.mem.eql(u8, top_signals[0].name, repo_top_signal.?)) {
                break :blk "focus slice differs from repo-wide signal; treat it as a local exception";
            }
            break :blk "focus slice aligns with repo-wide signal";
        };
        try observations.append(allocator, .{
            .exists = true,
            .kind = if (isDirectory(resolved)) "dir" else "file",
            .note = note,
            .path = raw_path,
            .top_signals = top_signals,
        });
    }
    return try observations.toOwnedSlice(allocator);
}

fn collectFocusSignals(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    focus_abs: []const u8,
    text_files: []const TextFileRecord,
) ![]const SignalEntry {
    var selected = std.ArrayList(TextFileRecord).empty;
    var focus_dirs = std.ArrayList([]const u8).empty;

    if (isDirectory(focus_abs)) {
        var dir = try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), focus_abs, .{ .iterate = true });
        defer dir.close(std.Io.Threaded.global_single_threaded.io());
        var it = dir.iterate();
        while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
            if (entry.kind != .directory) continue;
            if (ignoreDirsLike(entry.name)) continue;
            try focus_dirs.append(allocator, try allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, focus_dirs.items, {}, stringLessThan);
        for (text_files) |file| {
            if (std.mem.startsWith(u8, file.abs_path, focus_abs)) try selected.append(allocator, file);
        }
    } else {
        for (text_files) |file| {
            if (std.mem.eql(u8, file.abs_path, focus_abs)) try selected.append(allocator, file);
        }
    }
    _ = root_abs;
    return try collectSignals(allocator, focus_dirs.items, selected.items, &.{}, &.{}, &.{});
}

fn isDirectory(abs_path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), abs_path, .{}) catch return false;
    return stat.kind == .directory;
}

fn hasWeakeningHint(hints: []const DependencyHint) bool {
    for (hints) |hint| {
        if (std.mem.eql(u8, hint.effect, "weakens")) return true;
    }
    return false;
}

fn cloneFileRecordSlice(allocator: std.mem.Allocator, input: []const FileRecord) ![]const FileRecord {
    var out = try allocator.alloc(FileRecord, input.len);
    for (input, 0..) |item, idx| out[idx] = item;
    return out;
}

fn cloneStringSlice(allocator: std.mem.Allocator, input: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, input.len);
    for (input, 0..) |item, idx| out[idx] = try allocator.dupe(u8, item);
    return out;
}

fn uniqueSortedStrings(allocator: std.mem.Allocator, input: []const []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    for (input) |item| try list.append(allocator, item);
    std.mem.sort([]const u8, list.items, {}, stringLessThan);
    var deduped = std.ArrayList([]const u8).empty;
    for (list.items) |item| {
        if (deduped.items.len == 0 or !std.mem.eql(u8, deduped.items[deduped.items.len - 1], item)) {
            try deduped.append(allocator, item);
        }
    }
    return try deduped.toOwnedSlice(allocator);
}

fn joinMapKeys(allocator: std.mem.Allocator, map: std.StringHashMap(void), max_items: usize) ![]const u8 {
    var keys = std.ArrayList([]const u8).empty;
    var it = map.iterator();
    while (it.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, stringLessThan);
    if (keys.items.len > max_items) keys.shrinkRetainingCapacity(max_items);
    return try std.mem.join(allocator, ", ", keys.items);
}

fn intersectTopLevelMarkers(
    allocator: std.mem.Allocator,
    top_level_dirs: []const []const u8,
    markers: std.StaticStringMap(void),
) !?[]const u8 {
    var hits = std.ArrayList([]const u8).empty;
    for (top_level_dirs) |dir_name| {
        if (markers.has(dir_name)) try hits.append(allocator, dir_name);
    }
    if (hits.items.len == 0) return null;
    std.mem.sort([]const u8, hits.items, {}, stringLessThan);
    return try std.mem.join(allocator, ", ", hits.items);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn hasFirstPathPart(path: []const u8, target: []const u8) bool {
    return if (firstPathPart(path)) |first| std.mem.eql(u8, first, target) else false;
}

fn firstPathPart(path: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, path, std.fs.path.sep);
    return parts.next();
}

fn nthPathPart(path: []const u8, index: usize) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, path, std.fs.path.sep);
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i == index) return part;
    }
    return null;
}

test "collects layered fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload = try collect(
        arena.allocator(),
        "/Users/tk/workspace/tk/skills-zig/apps/parse-arch/references/eval/fixtures/layered-api",
        .{},
    );
    try std.testing.expect(payload.architecture_signals.len > 0);
    try std.testing.expectEqualStrings("layered", payload.architecture_signals[0].name);
}
