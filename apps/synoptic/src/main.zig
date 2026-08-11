const std = @import("std");
const stopped_status = "{\"schema\":\"synoptic-status/v1\",\"status\":\"stopped\"}\n";
const auth_remediation = "Run gh auth login for the target GitHub host, then retry.";
const pr_remediation = "Run gh pr view successfully or pass a valid --pr selector.";
const fetch_remediation = "Ensure the PR base and head objects are fetchable from origin.";
const skill_remediation = "Install valid synoptic-ui/v1 and synoptic-exclusions/v1 skill assets.";
const builtin = @import("builtin");
const app_meta = @import("app_meta");
const app_domain = @import("app.zig");
const App = app_domain.App;
const config = @import("config.zig");
const domain = @import("domain.zig");
const graphql = @import("graphql.zig");
const github = @import("github.zig");
const http = @import("http.zig");
const pr = @import("pr.zig");
const sessions = @import("sessions.zig");
const worktree = @import("worktree.zig");
const launch_shutdown_grace_ms: u32 = 500;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) return usage();
    if (std.mem.eql(u8, argv[1], "version")) return printVersion(init.io);
    if (std.mem.eql(u8, argv[1], "capabilities")) return printCapabilities(init.io, argv[2..]);
    if (std.mem.eql(u8, argv[1], "launch")) return launch(
        allocator,
        init.io,
        init.environ_map,
        argv[2..],
    );
    if (std.mem.eql(u8, argv[1], "serve")) return serve(
        allocator,
        init.io,
        init.environ_map,
        argv[2..],
    );
    if (std.mem.eql(u8, argv[1], "status")) return status(
        allocator,
        init.io,
        init.environ_map,
        argv[2..],
    );
    if (std.mem.eql(u8, argv[1], "stop")) return stop(
        allocator,
        init.io,
        init.environ_map,
        argv[2..],
    );
    return usage();
}

fn printVersion(io: std.Io) !void {
    var out = std.Io.File.stdout().writer(io, &.{});
    try out.interface.print("synoptic {s}\n", .{app_meta.version});
    try out.interface.flush();
}
fn printCapabilities(io: std.Io, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[0], "--format") and
        std.mem.eql(u8, args[1], "json");
    if (!json and args.len != 0) return error.InvalidArguments;
    var out = std.Io.File.stdout().writer(io, &.{});
    if (json) try out.interface.print("{{\"synopticCapabilities\":{{\"version\":{f},\"platfor" ++
        "m\":\"macos\",\"skillAbi\":\"{s}\",\"uiAbi\":\"{s}\"," ++
        "\"features\":{{\"casRuntimeV1\":true,\"githubViewedQue" ++
        "ueV1\":true,\"ephemeralFileSessionsV1\":true,\"githubA" ++
        "ctionCardsV1\":true}}}}}}\n", .{
        std.json.fmt(app_meta.version, .{}),
        config.skill_abi,
        config.ui_abi,
    }) else try out.interface.print(
        "synoptic {s}\n{s}\n{s}\n",
        .{ app_meta.version, config.skill_abi, config.ui_abi },
    );
    try out.interface.flush();
}

const LifecycleRecord = struct {
    allocator: std.mem.Allocator,
    raw: []u8,
    launch_id: []u8,
    runtime_root: []u8,
    executable: []u8,
    url: []u8,
    worktree: ?[]u8,
    worktree_kind: ?[]u8,
    repository_cwd: ?[]u8,
    pid: u64,

    fn deinit(self: *LifecycleRecord) void {
        self.allocator.free(self.raw);
        self.allocator.free(self.launch_id);
        self.allocator.free(self.runtime_root);
        self.allocator.free(self.executable);
        self.allocator.free(self.url);
        if (self.worktree) |value| self.allocator.free(value);
        if (self.worktree_kind) |value| self.allocator.free(value);
        if (self.repository_cwd) |value| self.allocator.free(value);
    }
};

fn launch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    args: []const []const u8,
) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const options = try parseLaunch(args);
    try config.validateManifest(allocator, io, options.skill_root);
    var settings = try config.Settings.load(allocator, io, environment, options.skill_root);
    defer settings.deinit();
    const runtime_root = try runtimeRootAlloc(allocator, environment);
    defer allocator.free(runtime_root);
    try ensurePrivateDir(io, runtime_root);
    const claim_path = try std.fs.path.join(allocator, &.{ runtime_root, "launch.lock" });
    defer allocator.free(claim_path);
    var claim = try acquireLaunchClaim(io, claim_path);
    defer claim.close(io);
    defer claim.unlock(io);
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    if (try readCurrentForLaunch(allocator, io, current_path)) |record_value| {
        var record = record_value;
        defer record.deinit();
        if (try verifiedProcess(allocator, io, record)) return error.SynopticAlreadyRunning;
        try retireDeadLaunch(allocator, io, runtime_root, record);
        std.Io.Dir.cwd().deleteFile(io, current_path) catch |ignored_error| {
            switch (ignored_error) {
                else => {},
            }
        };
    }

    var launch_bytes: [24]u8 = undefined;
    io.random(&launch_bytes);
    var launch_buf: [48]u8 = undefined;
    const launch_id = try std.fmt.bufPrint(&launch_buf, "{x}", .{launch_bytes});
    const launch_dir = try std.fs.path.join(allocator, &.{ runtime_root, launch_id });
    defer allocator.free(launch_dir);
    try ensurePrivateDir(io, launch_dir);
    const ready_path = try std.fs.path.join(allocator, &.{ launch_dir, "ready.json" });
    defer allocator.free(ready_path);
    const error_path = try std.fs.path.join(allocator, &.{ launch_dir, "error.json" });
    defer allocator.free(error_path);
    var child = try spawnServeChild(allocator, io, environment, args, launch_id, runtime_root);
    var child_owned = true;
    errdefer if (child_owned) cleanupFailedLaunch(
        allocator,
        io,
        &child,
        launch_dir,
        options.cwd,
    );
    const child_pid: u64 = @intCast(child.id orelse return error.ChildMissingPid);
    var ready = try awaitChildReady(allocator, io, ready_path, error_path, launch_id, child_pid);
    defer ready.deinit();
    if (!try verifiedProcess(allocator, io, ready)) return error.InvalidLaunchReadiness;
    try writeOperationalFile(allocator, io, current_path, ready.raw);
    if (!options.no_browser and settings.browser_open) {
        openBrowser(allocator, io, ready.url) catch |ignored_error| switch (ignored_error) {
            else => {},
        };
    }
    var out = std.Io.File.stdout().writer(io, &.{});
    if (options.json) {
        try out.interface.print("{s}\n", .{ready.raw});
    } else try out.interface.print("{s}\n", .{ready.url});
    try out.interface.flush();
    child_owned = false;
}

fn cleanupFailedLaunch(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    launch_dir: []const u8,
    repository_cwd: []const u8,
) void {
    if (!retireLaunchProcessGroup(io, child)) return;
    const managed_path = std.fs.path.join(
        allocator,
        &.{ launch_dir, "worktree" },
    ) catch return;
    defer allocator.free(managed_path);
    worktree.retireManaged(
        allocator,
        io,
        .{ .managed = managed_path },
        repository_cwd,
    ) catch |ignored_error| switch (ignored_error) {
        else => {},
    };
}

fn retireDeadLaunch(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_root: []const u8,
    record: LifecycleRecord,
) !void {
    const kind = record.worktree_kind orelse return;
    if (!std.mem.eql(u8, kind, "managed")) return;
    const recorded_path = record.worktree orelse return error.IncompleteManagedLaunchRecord;
    const repository_cwd = record.repository_cwd orelse
        return error.IncompleteManagedLaunchRecord;
    if (!std.fs.path.isAbsolute(repository_cwd)) return error.InvalidLifecycleRecord;
    const expected_path = try std.fs.path.join(
        allocator,
        &.{ runtime_root, record.launch_id, "worktree" },
    );
    defer allocator.free(expected_path);
    if (!std.mem.eql(u8, recorded_path, expected_path) or
        !std.mem.eql(u8, record.runtime_root, runtime_root))
    {
        return error.InvalidLifecycleRecord;
    }
    try worktree.retireManaged(
        allocator,
        io,
        .{ .managed = recorded_path },
        repository_cwd,
    );
}

fn retireLaunchProcessGroup(io: std.Io, child: *std.process.Child) bool {
    const child_id = child.id orelse return true;
    const group_id: u64 = @intCast(child_id);
    const positive = std.math.cast(std.posix.pid_t, group_id) orelse return false;
    std.posix.kill(-positive, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => {},
    };
    const websocket = @import("cas_runtime").websocket;
    if (!websocket.waitForProcessGroupExit(group_id, launch_shutdown_grace_ms)) {
        websocket.forceKillProcessGroup(group_id);
    }
    _ = child.wait(io) catch child.kill(io);
    return websocket.waitForProcessGroupExit(group_id, launch_shutdown_grace_ms);
}

fn spawnServeChild(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    args: []const []const u8,
    launch_id: []const u8,
    runtime_root: []const u8,
) !std.process.Child {
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    try child_argv.appendSlice(
        allocator,
        &.{ self_path, "serve", "--launch-id", launch_id, "--runtime-root", runtime_root },
    );
    try child_argv.appendSlice(allocator, args);
    return std.process.spawn(io, .{
        .argv = child_argv.items,
        .environ_map = environment,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
}

fn awaitChildReady(
    allocator: std.mem.Allocator,
    io: std.Io,
    ready_path: []const u8,
    error_path: []const u8,
    launch_id: []const u8,
    child_pid: u64,
) !LifecycleRecord {
    const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
    while (true) { // tiger: event-loop -- bounded by owner state or deadline.
        if (readLifecycleRecord(allocator, io, ready_path)) |candidate| {
            if (candidate.pid != child_pid or !std.mem.eql(u8, candidate.launch_id, launch_id)) {
                var invalid = candidate;
                invalid.deinit();
                return error.InvalidLaunchReadiness;
            }
            return candidate;
        } else |_| {}
        if (std.Io.Dir.cwd().readFileAlloc(
            io,
            error_path,
            allocator,
            .limited(64 * 1024),
        )) |child_error| {
            defer allocator.free(child_error);
            var err_out = std.Io.File.stderr().writer(io, &.{});
            try err_out.interface.print("{s}\n", .{child_error});
            try err_out.interface.flush();
            return error.SynopticChildLaunchFailed;
        } else |_| {}
        if (!processAlive(child_pid)) return error.SynopticChildExitedBeforeReady;
        const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
        if (now_ms - started_ms >= config.lifecycle_ready_timeout_ms) {
            return error.SynopticReadinessTimeout;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |ignored_error| {
            switch (ignored_error) {
                else => {},
            }
        };
    }
}

fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    args: []const []const u8,
) !void {
    const invalid = args.len < 4 or !std.mem.eql(u8, args[0], "--launch-id") or
        !std.mem.eql(u8, args[2], "--runtime-root");
    if (invalid) return error.InvalidArguments;
    const launch_id = args[1];
    const runtime_root = args[3];
    if (launch_id.len != 48 or std.mem.indexOfScalar(u8, launch_id, std.fs.path.sep) != null)
        return error.InvalidLaunchId;
    serveReview(allocator, io, environment, args[4..], launch_id, runtime_root) catch |err| {
        writeLaunchError(allocator, io, runtime_root, launch_id, err) catch |ignored_error| {
            switch (ignored_error) {
                else => {},
            }
        };
        return err;
    };
}

fn serveReview(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    args: []const []const u8,
    launch_id: []const u8,
    runtime_root: []const u8,
) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    var options = try parseLaunch(args);
    const repository_cwd = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        options.cwd,
        allocator,
    );
    defer allocator.free(repository_cwd);
    options.cwd = repository_cwd;
    try config.validateManifest(allocator, io, options.skill_root);
    var settings = try config.Settings.load(allocator, io, environment, options.skill_root);
    defer settings.deinit();
    const gh_path = environment.get("SYNOPTIC_GH") orelse "gh";
    const codex_path = environment.get("SYNOPTIC_CODEX") orelse "codex";
    const gh_resolved = try @import("cas_runtime").resolveExecutableAlloc(allocator, gh_path);
    defer allocator.free(gh_resolved);
    const codex_resolved = try @import("cas_runtime").resolveExecutableAlloc(allocator, codex_path);
    defer allocator.free(codex_resolved);
    const schema_dir = try std.fs.path.join(
        allocator,
        &.{ runtime_root, launch_id, "codex-schema" },
    );
    defer allocator.free(schema_dir);
    if (try config.codexSchemaProblemAlloc(allocator, io, codex_resolved, schema_dir)) |problem| {
        defer allocator.free(problem);
        try writeLaunchProblem(allocator, io, runtime_root, launch_id, problem);
        return error.CodexSchemaIncompatible;
    }
    try preflightGhAuthentication(
        allocator,
        io,
        gh_resolved,
        options.cwd,
        options.pr,
    );
    const selector_url = try resolveSelectorUrl(
        allocator,
        io,
        gh_resolved,
        options.cwd,
        options.pr,
    );
    defer allocator.free(selector_url);
    const identity = try pr.parseUrl(selector_url);
    try requireGhAuthentication(allocator, io, gh_resolved, identity.host);
    return serveResolvedPullRequest(
        allocator,
        io,
        &settings,
        options,
        gh_resolved,
        codex_resolved,
        identity,
        launch_id,
        runtime_root,
    );
}

fn serveResolvedPullRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    settings: *config.Settings,
    options: config.LaunchOptions,
    gh_resolved: []const u8,
    codex_resolved: []const u8,
    identity: pr.Identity,
    launch_id: []const u8,
    runtime_root: []const u8,
) !void {
    const broker = github.Broker{
        .allocator = allocator,
        .io = io,
        .gh_path = gh_resolved,
        .host = identity.host,
    };
    var pages = try broker.readGenerationPages(
        identity.owner,
        identity.repository,
        identity.number,
    );
    defer pages.deinit();
    var snapshot = try Snapshot.load(allocator, pages.files.items[0]);
    defer snapshot.deinit();
    var generation = try domain.PrGeneration.initFull(allocator, snapshot.base, snapshot.head);
    var generation_owned = true;
    errdefer if (generation_owned) generation.deinit();
    for (pages.files.items) |page| try loadSnapshotFiles(allocator, page, &generation);
    for (pages.threads.items) |page| try github.loadThreads(allocator, page, &generation);
    try serveGeneration(
        allocator,
        io,
        .{
            .settings = settings,
            .options = options,
            .codex_resolved = codex_resolved,
            .identity = identity,
            .broker = broker,
            .launch_id = launch_id,
            .runtime_root = runtime_root,
            .snapshot = snapshot,
        },
        &generation,
        &generation_owned,
    );
}

const GenerationContext = struct {
    settings: *config.Settings,
    options: config.LaunchOptions,
    codex_resolved: []const u8,
    identity: pr.Identity,
    broker: github.Broker,
    launch_id: []const u8,
    runtime_root: []const u8,
    snapshot: Snapshot,
};

const Snapshot = struct {
    allocator: std.mem.Allocator,
    head: []const u8,
    base: []const u8,
    pull_request_id: []const u8,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    pull_url: []const u8,
    pull_state: []const u8,
    is_draft: bool,

    fn load(allocator: std.mem.Allocator, page: []const u8) !Snapshot {
        const head = try snapshotField(allocator, page, "headRefOid");
        errdefer allocator.free(head);
        const base = try snapshotField(allocator, page, "baseRefOid");
        errdefer allocator.free(base);
        const pull_request_id = try snapshotField(allocator, page, "id");
        errdefer allocator.free(pull_request_id);
        const title = try snapshotField(allocator, page, "title");
        errdefer allocator.free(title);
        const body = try snapshotOptionalTextField(allocator, page, "body");
        errdefer allocator.free(body);
        const base_ref = try snapshotField(allocator, page, "baseRefName");
        errdefer allocator.free(base_ref);
        const head_ref = try snapshotField(allocator, page, "headRefName");
        errdefer allocator.free(head_ref);
        const pull_url = try snapshotField(allocator, page, "url");
        errdefer allocator.free(pull_url);
        const pull_state = try snapshotField(allocator, page, "state");
        errdefer allocator.free(pull_state);
        return .{
            .allocator = allocator,
            .head = head,
            .base = base,
            .pull_request_id = pull_request_id,
            .title = title,
            .body = body,
            .base_ref = base_ref,
            .head_ref = head_ref,
            .pull_url = pull_url,
            .pull_state = pull_state,
            .is_draft = try snapshotBoolField(allocator, page, "isDraft"),
        };
    }

    fn deinit(self: *Snapshot) void {
        self.allocator.free(self.head);
        self.allocator.free(self.base);
        self.allocator.free(self.pull_request_id);
        self.allocator.free(self.title);
        self.allocator.free(self.body);
        self.allocator.free(self.base_ref);
        self.allocator.free(self.head_ref);
        self.allocator.free(self.pull_url);
        self.allocator.free(self.pull_state);
    }
};

fn serveGeneration(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: GenerationContext,
    generation: *domain.PrGeneration,
    generation_owned: *bool,
) !void {
    const managed_path = try std.fs.path.join(
        allocator,
        &.{ context.runtime_root, context.launch_id, "worktree" },
    );
    defer allocator.free(managed_path);
    var custody = try worktree.select(
        allocator,
        io,
        context.options.cwd,
        context.snapshot.head_ref,
        context.snapshot.head,
        managed_path,
        context.settings.worktree_prefer_current_pr_checkout,
    );
    defer allocator.free(custody.path());
    var custody_retirement: CustodyRetirement = .pending;
    try serveSelectedGeneration(
        allocator,
        io,
        context,
        generation,
        generation_owned,
        custody,
        &custody_retirement,
    );
}

const CustodyRetirement = enum { pending, preserve, retired };

fn serveSelectedGeneration(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: GenerationContext,
    generation: *domain.PrGeneration,
    generation_owned: *bool,
    custody: worktree.Custody,
    custody_retirement: *CustodyRetirement,
) !void {
    const review_cwd = custody.path();
    try github.hydrateRevisionKeys(allocator, io, review_cwd, generation);
    var worktree_baseline = try worktree.Baseline.capture(allocator, io, review_cwd);
    defer worktree_baseline.deinit();
    var state = try configureAppState(
        allocator,
        context.settings,
        context.identity,
        context.snapshot,
        generation,
        generation_owned,
    );
    defer state.deinit();

    const app_server_receipts = try std.fs.path.join(
        allocator,
        &.{ context.runtime_root, context.launch_id, "codex" },
    );
    defer allocator.free(app_server_receipts);
    var registry = try sessions.Registry.startManagedPreferred(
        allocator,
        io,
        review_cwd,
        app_server_receipts,
        context.codex_resolved,
    );
    defer registry.deinit();
    const skill_path = try initializePrimary(
        allocator,
        io,
        context.options.skill_root,
        context.identity,
        context.snapshot,
        review_cwd,
        &state,
        &registry,
    );
    defer allocator.free(skill_path);
    try serveHttpRuntime(
        allocator,
        io,
        context,
        context.snapshot.pull_request_id,
        custody,
        &worktree_baseline,
        &state,
        &registry,
        review_cwd,
        skill_path,
        custody_retirement,
    );
}

fn initializePrimary(
    allocator: std.mem.Allocator,
    io: std.Io,
    skill_root: []const u8,
    identity: pr.Identity,
    snapshot: Snapshot,
    review_cwd: []const u8,
    state: *App,
    registry: *sessions.Registry,
) ![]u8 {
    try registry.setGenerationEvidence(&state.generation);
    const skill_path = try std.fs.path.join(allocator, &.{ skill_root, "SKILL.md" });
    errdefer allocator.free(skill_path);
    const pr_context = try primaryContextAlloc(
        allocator,
        identity.owner,
        identity.repository,
        identity.number,
        snapshot.title,
        snapshot.body,
        snapshot.base_ref,
        snapshot.base,
        snapshot.head_ref,
        snapshot.head,
        &state.generation,
    );
    defer allocator.free(pr_context);
    try registry.createPrimary(io, review_cwd, skill_path, pr_context);
    state.primary_ready = registry.primaryReady();
    return skill_path;
}

fn applyLaunchExclusions(
    allocator: std.mem.Allocator,
    settings: *config.Settings,
    broker: github.Broker,
    identity: pr.Identity,
    pull_request_id: []const u8,
    review_cwd: []const u8,
    state: *App,
    registry: *sessions.Registry,
    tool_domain: *http.ToolDomainContext,
) !void {
    if (!settings.exclusions_enabled) return;
    tool_domain.lock();
    var outcomes = state.applyAutomaticExclusions(
        settings,
        broker,
        identity.owner,
        identity.repository,
        identity.number,
        pull_request_id,
        review_cwd,
    ) catch |err| {
        tool_domain.unlock();
        return err;
    };
    tool_domain.unlock();
    defer {
        for (outcomes.items) |outcome| outcome.deinit();
        outcomes.deinit(allocator);
    }
    try http.queueExclusionEvents(registry, outcomes.items);
}

fn configureAppState(
    allocator: std.mem.Allocator,
    settings: *config.Settings,
    identity: pr.Identity,
    snapshot: Snapshot,
    generation: *domain.PrGeneration,
    generation_owned: *bool,
) !App {
    var state = try App.init(allocator, snapshot.head);
    errdefer state.deinit();
    state.replaceGeneration(generation.*);
    generation_owned.* = false;
    const repository = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ identity.owner, identity.repository },
    );
    defer allocator.free(repository);
    try state.setPullRequest(.{
        .repository = repository,
        .number = identity.number,
        .title = snapshot.title,
        .body = snapshot.body,
        .url = snapshot.pull_url,
        .base_ref_name = snapshot.base_ref,
        .base_ref_oid = snapshot.base,
        .head_ref_name = snapshot.head_ref,
        .head_ref_oid = snapshot.head,
        .state = snapshot.pull_state,
        .is_draft = snapshot.is_draft,
    });
    state.file_review_start_mode = settings.file_review_start_mode;
    return state;
}

fn serveHttpRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: GenerationContext,
    pull_request_id: []const u8,
    custody: worktree.Custody,
    worktree_baseline: *worktree.Baseline,
    state: *App,
    registry: *sessions.Registry,
    review_cwd: []const u8,
    skill_path: []const u8,
    custody_retirement: *CustodyRetirement,
) !void {
    var server = try http.Server.bind(allocator, io, context.options.skill_root);
    defer server.deinit();
    const stop_request_path = try std.fs.path.join(
        allocator,
        &.{ context.runtime_root, context.launch_id, "stop.request" },
    );
    defer allocator.free(stop_request_path);
    var runtime = makeHttpRuntime(
        context.settings,
        context.options,
        context.identity,
        context.broker,
        pull_request_id,
        custody,
        worktree_baseline,
        state,
        registry,
        review_cwd,
        skill_path,
        context.launch_id,
        stop_request_path,
    );
    const tool_domain = try configureToolDomain(
        allocator,
        state,
        registry,
        context.broker,
        context.identity,
        pull_request_id,
    );
    runtime.tool_domain = tool_domain;
    registry.setExclusionsPending(true);
    errdefer registry.setExclusionsPending(false);
    var exclusion_work = LaunchExclusionWork.init(
        allocator,
        context.settings,
        context.broker,
        context.identity,
        pull_request_id,
        review_cwd,
        state,
        registry,
        tool_domain,
    );
    const exclusion_thread = try std.Thread.spawn(.{}, LaunchExclusionWork.run, .{&exclusion_work});
    var exclusion_thread_owned = true;
    errdefer if (exclusion_thread_owned) {
        exclusion_work.cancelled.store(true, .release);
        exclusion_thread.join();
    };
    try publishRuntimeReady(
        allocator,
        io,
        &server,
        &runtime,
        context.runtime_root,
    );
    const terminal_error = runHttpLoop(io, &server, &runtime, state, registry, stop_request_path);
    exclusion_work.cancelled.store(true, .release);
    exclusion_thread.join();
    exclusion_thread_owned = false;
    try finishHttpRuntime(
        allocator,
        io,
        context.options,
        context.runtime_root,
        &runtime,
        custody_retirement,
        terminal_error,
    );
}

fn configureToolDomain(
    allocator: std.mem.Allocator,
    state: *App,
    registry: *sessions.Registry,
    broker: github.Broker,
    identity: pr.Identity,
    pull_request_id: []const u8,
) !*http.ToolDomainContext {
    const context = try http.ToolDomainContext.create(
        allocator,
        state,
        registry,
        broker,
        identity.owner,
        identity.repository,
        identity.number,
        pull_request_id,
    );
    registry.setAuthoritativeToolHandler(context.handler()) catch |err| {
        allocator.destroy(context);
        return err;
    };
    return context;
}

const LaunchExclusionWork = struct {
    allocator: std.mem.Allocator,
    settings: *config.Settings,
    broker: github.Broker,
    identity: pr.Identity,
    pull_request_id: []const u8,
    review_cwd: []const u8,
    state: *App,
    registry: *sessions.Registry,
    tool_domain: *http.ToolDomainContext,
    cancelled: std.atomic.Value(bool) = .init(false),

    fn init(
        allocator: std.mem.Allocator,
        settings: *config.Settings,
        broker: github.Broker,
        identity: pr.Identity,
        pull_request_id: []const u8,
        review_cwd: []const u8,
        state: *App,
        registry: *sessions.Registry,
        tool_domain: *http.ToolDomainContext,
    ) LaunchExclusionWork {
        return .{
            .allocator = allocator,
            .settings = settings,
            .broker = broker,
            .identity = identity,
            .pull_request_id = pull_request_id,
            .review_cwd = review_cwd,
            .state = state,
            .registry = registry,
            .tool_domain = tool_domain,
        };
    }

    fn run(self: *LaunchExclusionWork) void {
        defer self.registry.setExclusionsPending(false);
        var broker = self.broker;
        broker.cancelled = &self.cancelled;
        queueLaunchExclusionFailures(
            self.allocator,
            self.settings,
            broker,
            self.identity,
            self.pull_request_id,
            self.review_cwd,
            self.state,
            self.registry,
            self.tool_domain,
        );
    }
};

fn publishRuntimeReady(
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *http.Server,
    runtime: *http.Runtime,
    runtime_root: []const u8,
) !void {
    try publishReadyReceipt(
        allocator,
        io,
        server,
        .{
            .owner = runtime.owner,
            .repository = runtime.name,
            .number = runtime.number,
        },
        runtime.launch_id,
        runtime_root,
        runtime.cwd,
        runtime.custody,
        runtime.registry.transportName(),
        runtime.repository_cwd,
    );
}

fn finishHttpRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: config.LaunchOptions,
    runtime_root: []const u8,
    runtime: *http.Runtime,
    custody_retirement: *CustodyRetirement,
    terminal_error: ?anyerror,
) !void {
    try shutdownReview(
        allocator,
        io,
        options,
        runtime.launch_id,
        runtime_root,
        runtime.custody,
        runtime.baseline orelse return error.MissingWorktreeBaseline,
        runtime.app,
        runtime.registry,
        runtime.stop_request_path orelse return error.MissingStopRequestPath,
        custody_retirement,
        terminal_error,
    );
}

fn makeHttpRuntime(
    settings: *config.Settings,
    options: config.LaunchOptions,
    identity: pr.Identity,
    broker: github.Broker,
    pull_request_id: []const u8,
    custody: worktree.Custody,
    worktree_baseline: *worktree.Baseline,
    state: *App,
    registry: *sessions.Registry,
    review_cwd: []const u8,
    skill_path: []const u8,
    launch_id: []const u8,
    stop_request_path: []const u8,
) http.Runtime {
    return .{
        .app = state,
        .registry = registry,
        .broker = broker,
        .owner = identity.owner,
        .name = identity.repository,
        .number = identity.number,
        .pull_request_id = pull_request_id,
        .cwd = review_cwd,
        .skill_path = skill_path,
        .repository_cwd = options.cwd,
        .custody = custody,
        .baseline = worktree_baseline,
        .settings = settings,
        .launch_id = launch_id,
        .stop_request_path = stop_request_path,
    };
}

fn queueLaunchExclusionFailures(
    allocator: std.mem.Allocator,
    settings: *config.Settings,
    broker: github.Broker,
    identity: pr.Identity,
    pull_request_id: []const u8,
    review_cwd: []const u8,
    state: *App,
    registry: *sessions.Registry,
    tool_domain: *http.ToolDomainContext,
) void {
    applyLaunchExclusions(
        allocator,
        settings,
        broker,
        identity,
        pull_request_id,
        review_cwd,
        state,
        registry,
        tool_domain,
    ) catch |err| {
        const payload = std.fmt.allocPrint(
            allocator,
            "{{\"code\":{f}}}",
            .{std.json.fmt(@errorName(err), .{})},
        ) catch null;
        if (payload) |value| {
            defer allocator.free(value);
            queueWarning(registry, value);
        }
    };
}

fn queueWarning(registry: *sessions.Registry, payload: []const u8) void {
    registry.queueSystemEvent("warning", payload) catch |ignored_error| switch (ignored_error) {
        else => {},
    };
}

fn publishReadyReceipt(
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *http.Server,
    identity: pr.Identity,
    launch_id: []const u8,
    runtime_root: []const u8,
    review_cwd: []const u8,
    custody: worktree.Custody,
    transport: []const u8,
    repository_cwd: []const u8,
) !void {
    var token_buf: [64]u8 = undefined;
    const token = server.tokenHex(&token_buf);
    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/?token={s}",
        .{ server.port(), token },
    );
    defer allocator.free(url);
    const repository = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ identity.owner, identity.repository },
    );
    defer allocator.free(repository);
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const receipt_format = "{{\"schema\":\"synoptic-launch-ready/v1\",\"runtimeSch" ++
        "ema\":\"{s}\",\"status\":\"ready\",\"capabilityState\"" ++
        ":\"ready\",\"lifecycle\":\"detached\",\"launchId\":{f}" ++
        ",\"runtimeRoot\":{f},\"executable\":{f},\"pid\":{d},\"" ++
        "url\":{f},\"repository\":{f},\"pullRequest\":{d},\"wor" ++
        "ktree\":{f},\"worktreeKind\":{f},\"transport\":{f}," ++
        "\"repositoryCwd\":{f}}}";
    const receipt = try std.fmt.allocPrint(
        allocator,
        receipt_format,
        .{
            config.lifecycle_schema,
            std.json.fmt(launch_id, .{}),
            std.json.fmt(runtime_root, .{}),
            std.json.fmt(executable, .{}),
            std.c.getpid(),
            std.json.fmt(url, .{}),
            std.json.fmt(repository, .{}),
            identity.number,
            std.json.fmt(review_cwd, .{}),
            std.json.fmt(custody.kind(), .{}),
            std.json.fmt(transport, .{}),
            std.json.fmt(repository_cwd, .{}),
        },
    );
    defer allocator.free(receipt);
    const ready_path = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "ready.json" });
    defer allocator.free(ready_path);
    try writeOperationalFile(allocator, io, ready_path, receipt);
}

fn runHttpLoop(
    io: std.Io,
    server: *http.Server,
    runtime: *http.Runtime,
    state: *App,
    registry: *sessions.Registry,
    stop_request_path: []const u8,
) ?anyerror {
    var terminal_error: ?anyerror = null;
    while (!runtime.stop_requested) {
        if (runtime.tool_domain) |domain_context| domain_context.lock();
        state.primary_ready = registry.primaryReady();
        if (runtime.tool_domain) |domain_context| domain_context.unlock();
        server.serveOne(runtime) catch |err| {
            terminal_error = err;
            break;
        };
        if (std.Io.Dir.cwd().access(io, stop_request_path, .{})) |_| runtime.stop_requested =
            true else |_| {}
    }
    return terminal_error;
}

fn shutdownReview(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: config.LaunchOptions,
    launch_id: []const u8,
    runtime_root: []const u8,
    custody: worktree.Custody,
    worktree_baseline: *worktree.Baseline,
    state: *App,
    registry: *sessions.Registry,
    stop_request_path: []const u8,
    custody_retirement: *CustodyRetirement,
    terminal_error: ?anyerror,
) !void {
    _ = state;
    custody_retirement.* = .preserve;
    try registry.beginSynchronization(io, sessions.safe_boundary_timeout_ms);
    defer registry.endSynchronization();
    worktree.reconcileShutdown(
        allocator,
        io,
        custody,
        worktree_baseline.head_oid,
        worktree_baseline,
    ) catch |err| {
        return err;
    };
    try worktree.retireManaged(allocator, io, custody, options.cwd);
    custody_retirement.* = .retired;
    std.Io.Dir.cwd().deleteFile(io, stop_request_path) catch |ignored_error| {
        switch (ignored_error) {
            else => {},
        }
    };
    try finishLifecycleRecord(allocator, io, runtime_root, launch_id, terminal_error);
}

fn finishLifecycleRecord(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_root: []const u8,
    launch_id: []const u8,
    terminal_error: ?anyerror,
) !void {
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    removeCurrentIfLaunch(allocator, io, current_path, launch_id);
    if (terminal_error) |err| return err;
}

fn readCurrentForLaunch(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?LifecycleRecord {
    return readLifecycleRecord(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn status(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    args: []const []const u8,
) !void {
    const json = try parseJsonOnly(args);
    const runtime_root = try runtimeRootAlloc(allocator, environment);
    defer allocator.free(runtime_root);
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    var out = std.Io.File.stdout().writer(io, &.{});
    var record = readLifecycleRecord(allocator, io, current_path) catch {
        if (json) {
            try out.interface.writeAll(stopped_status);
        } else try out.interface.writeAll("stopped\n");
        try out.interface.flush();
        return;
    };
    defer record.deinit();
    if (!try verifiedProcess(allocator, io, record)) {
        if (json) {
            try out.interface.writeAll(stopped_status);
        } else try out.interface.writeAll("stopped\n");
    } else if (json) {
        try out.interface.print("{{\"schema\":\"synoptic-status/v1\",\"status\":\"runni" ++
            "ng\",\"launchId\":{f},\"pid\":{d},\"url\":{f}}}\n", .{
            std.json.fmt(record.launch_id, .{}),
            record.pid,
            std.json.fmt(record.url, .{}),
        });
    } else try out.interface.print("running {d} {s}\n", .{ record.pid, record.url });
    try out.interface.flush();
}

fn stop(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    args: []const []const u8,
) !void {
    const json = try parseJsonOnly(args);
    const runtime_root = try runtimeRootAlloc(allocator, environment);
    defer allocator.free(runtime_root);
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    var record = readLifecycleRecord(allocator, io, current_path) catch
        return printStopResult(io, json, null, false);
    defer record.deinit();
    if (!try verifiedProcess(allocator, io, record)) {
        return printStopResult(io, json, null, false);
    }
    const stop_request_path = try std.fs.path.join(
        allocator,
        &.{ record.runtime_root, record.launch_id, "stop.request" },
    );
    defer allocator.free(stop_request_path);
    try writeOperationalFile(allocator, io, stop_request_path, "{}\n");
    wakeLoopback(allocator, io, record.url) catch |ignored_error| {
        switch (ignored_error) {
            else => {},
        }
    };
    const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
    while (try verifiedProcess(allocator, io, record)) {
        const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
        if (now_ms - started_ms >= config.lifecycle_stop_timeout_ms) {
            return error.SynopticStopTimeout;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |ignored_error| {
            switch (ignored_error) {
                else => {},
            }
        };
    }
    const terminal_error_path = try std.fs.path.join(
        allocator,
        &.{ record.runtime_root, record.launch_id, "error.json" },
    );
    defer allocator.free(terminal_error_path);
    try requireNoTerminalError(io, terminal_error_path);
    removeCurrentIfLaunch(allocator, io, current_path, record.launch_id);
    return printStopResult(io, json, record.launch_id, true);
}

fn requireNoTerminalError(io: std.Io, path: []const u8) !void {
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
        return error.SynopticChildShutdownFailed;
    } else |_| {}
}

fn wakeLoopback(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidLifecycleUrl;
    const slash = std.mem.indexOfScalarPos(u8, url, prefix.len, '/') orelse
        return error.InvalidLifecycleUrl;
    const port = try std.fmt.parseInt(u16, url[prefix.len..slash], 10);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const request_format = "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n" ++
        "Connection: close\r\n\r\n";
    const request = try std.fmt.allocPrint(
        allocator,
        request_format,
        .{ url[slash..], port },
    );
    defer allocator.free(request);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(request);
    try writer.interface.flush();
}

fn printStopResult(io: std.Io, json: bool, launch_id: ?[]const u8, stopped: bool) !void {
    var out = std.Io.File.stdout().writer(io, &.{});
    if (json) try out.interface.print("{{\"schema\":\"synoptic-stop/v1\",\"status\":\"{s}\"," ++
        "\"launchId\":{f}}}\n", .{
        if (stopped) "stopped" else "not-running",
        std.json.fmt(launch_id orelse "", .{}),
    }) else try out.interface.print(
        "{s}\n",
        .{if (stopped) "stopped" else "not running"},
    );
    try out.interface.flush();
}

fn parseJsonOnly(args: []const []const u8) !bool {
    if (args.len == 0) return false;
    if (args.len == 1 and std.mem.eql(u8, args[0], "--json")) return true;
    return error.InvalidArguments;
}

fn runtimeRootAlloc(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) ![]u8 {
    return std.fs.path.join(allocator, &.{ environment.get("TMPDIR") orelse "/tmp", "synoptic" });
}

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .follow_symlinks = false });
    defer dir.close(io);
    try dir.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));
}

fn acquireLaunchClaim(io: std.Io, path: []const u8) !std.Io.File {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidRuntimeRoot;
    const name = std.fs.path.basename(path);
    var parent = try std.Io.Dir.cwd().openDir(io, parent_path, .{ .follow_symlinks = false });
    defer parent.close(io);
    var claim = parent.createFile(io, name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch |err| switch (err) {
        error.PathAlreadyExists => parent.openFile(io, name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
        }) catch |open_err| switch (open_err) {
            error.WouldBlock => return error.SynopticLaunchInProgress,
            else => return open_err,
        },
        error.WouldBlock => return error.SynopticLaunchInProgress,
        else => return err,
    };
    errdefer claim.close(io);
    try claim.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
    return claim;
}

fn readLifecycleRecord(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !LifecycleRecord {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    errdefer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidLifecycleRecord,
    };
    const runtime_schema = object.get("runtimeSchema") orelse return error.InvalidLifecycleRecord;
    if (runtime_schema != .string or !std.mem.eql(
        u8,
        runtime_schema.string,
        config.lifecycle_schema,
    )) return error.InvalidLifecycleRecord;
    const launch_id = try lifecycleStringAlloc(allocator, object, "launchId");
    errdefer allocator.free(launch_id);
    const runtime_root = try lifecycleStringAlloc(allocator, object, "runtimeRoot");
    errdefer allocator.free(runtime_root);
    const executable = try lifecycleStringAlloc(allocator, object, "executable");
    errdefer allocator.free(executable);
    const url = try lifecycleStringAlloc(allocator, object, "url");
    errdefer allocator.free(url);
    const worktree_path = try lifecycleOptionalStringAlloc(allocator, object, "worktree");
    errdefer if (worktree_path) |value| allocator.free(value);
    const worktree_kind = try lifecycleOptionalStringAlloc(allocator, object, "worktreeKind");
    errdefer if (worktree_kind) |value| allocator.free(value);
    const repository_cwd = try lifecycleOptionalStringAlloc(allocator, object, "repositoryCwd");
    errdefer if (repository_cwd) |value| allocator.free(value);
    const pid_value = object.get("pid") orelse return error.InvalidLifecycleRecord;
    if (pid_value != .integer or pid_value.integer <= 0) return error.InvalidLifecycleRecord;
    return .{
        .allocator = allocator,
        .raw = raw,
        .launch_id = launch_id,
        .runtime_root = runtime_root,
        .executable = executable,
        .url = url,
        .worktree = worktree_path,
        .worktree_kind = worktree_kind,
        .repository_cwd = repository_cwd,
        .pid = @intCast(pid_value.integer),
    };
}

fn lifecycleStringAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return error.InvalidLifecycleRecord;
    if (value != .string or value.string.len == 0) return error.InvalidLifecycleRecord;
    return allocator.dupe(u8, value.string);
}

fn lifecycleOptionalStringAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return error.InvalidLifecycleRecord;
    return @as(?[]u8, try allocator.dupe(u8, value.string));
}

fn verifiedProcess(allocator: std.mem.Allocator, io: std.Io, record: LifecycleRecord) !bool {
    if (!processAlive(record.pid)) return false;
    const pid_text = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{record.pid},
    );
    defer allocator.free(pid_text);
    const result = try std.process.run(
        allocator,
        io,
        .{ .argv = &.{ "/bin/ps", "-ww", "-p", pid_text, "-o", "command=" } },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return false;
    const command = std.mem.trim(u8, result.stdout, " \t\r\n");
    const identity = try std.fmt.allocPrint(
        allocator,
        "serve --launch-id {s} --runtime-root {s}",
        .{ record.launch_id, record.runtime_root },
    );
    defer allocator.free(identity);
    return std.mem.startsWith(
        u8,
        command,
        record.executable,
    ) and std.mem.indexOf(u8, command, identity) != null;
}

fn processAlive(process_id: u64) bool {
    const pid = std.math.cast(std.posix.pid_t, process_id) orelse return false;
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

fn writeOperationalFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    contents: []const u8,
) !void {
    const staging = try std.fmt.allocPrint(
        allocator,
        "{s}.tmp.{d}",
        .{ path, std.c.getpid() },
    );
    defer allocator.free(staging);
    std.Io.Dir.cwd().deleteFile(io, staging) catch |ignored_error| {
        switch (ignored_error) {
            else => {},
        }
    };
    errdefer std.Io.Dir.cwd().deleteFile(io, staging) catch |ignored_error| {
        switch (ignored_error) {
            else => {},
        }
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staging, .data = contents });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        staging,
        std.Io.File.Permissions.fromMode(0o600),
        .{},
    );
    try std.Io.Dir.renameAbsolute(staging, path, io);
}

fn writeLaunchError(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_root: []const u8,
    launch_id: []const u8,
    err: anyerror,
) !void {
    const path = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "error.json" });
    defer allocator.free(path);
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
    const format = "{{\"schema\":\"synoptic-launch-error/v1\",\"status\":" ++
        "\"blocked\",\"reason\":{f},\"remediation\":{f}}}";
    const receipt = try std.fmt.allocPrint(
        allocator,
        format,
        .{
            std.json.fmt(@errorName(err), .{}),
            std.json.fmt(launchRemediation(err), .{}),
        },
    );
    defer allocator.free(receipt);
    try writeOperationalFile(allocator, io, path, receipt);
}

fn writeLaunchProblem(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_root: []const u8,
    launch_id: []const u8,
    reason: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "error.json" });
    defer allocator.free(path);
    const format = "{{\"schema\":\"synoptic-launch-error/v1\",\"status\":" ++
        "\"blocked\",\"reason\":{f},\"remediation\":\"Install a" ++
        " Codex version providing every named app-server surfac" ++
        "e.\"}}";
    const receipt = try std.fmt.allocPrint(
        allocator,
        format,
        .{std.json.fmt(reason, .{})},
    );
    defer allocator.free(receipt);
    try writeOperationalFile(allocator, io, path, receipt);
}

fn primaryContextAlloc(
    allocator: std.mem.Allocator,
    owner: []const u8,
    repo: []const u8,
    number: u64,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    base_oid: []const u8,
    head_ref: []const u8,
    head_oid: []const u8,
    generation: *const domain.PrGeneration,
) ![]u8 {
    var files: std.Io.Writer.Allocating = .init(allocator);
    defer files.deinit();
    try std.json.Stringify.value(generation.files.items, .{}, &files.writer);
    const repository = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ owner, repo },
    );
    defer allocator.free(repository);
    return std.fmt.allocPrint(
        allocator,
        "{{\"repository\":{f},\"pullRequest\":{d},\"title\":{f}" ++
            ",\"body\":{f},\"baseRefName\":{f},\"baseRefOid\":{f}," ++
            "\"headRefName\":{f},\"headRefOid\":{f},\"files\":{s}}}",
        .{
            std.json.fmt(repository, .{}),
            number,
            std.json.fmt(title, .{}),
            std.json.fmt(body, .{}),
            std.json.fmt(base_ref, .{}),
            std.json.fmt(base_oid, .{}),
            std.json.fmt(head_ref, .{}),
            std.json.fmt(head_oid, .{}),
            files.written(),
        },
    );
}

fn launchRemediation(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound,
        error.ExecutableNotFound,
        error.MissingExecutable,
        => "Install codex and gh and ensure both resolve on PATH.",
        error.GitHubAuthenticationFailed => auth_remediation,
        error.PullRequestResolutionFailed => pr_remediation,
        error.BaseFetchFailed, error.ManagedWorktreeFetchFailed => fetch_remediation,
        error.InvalidUiManifest, error.InvalidExclusionsManifest => skill_remediation,
        error.InvalidSynopticConfig => "Correct the supported Synoptic settings in config.toml" ++
            ", then retry.",
        else => "Inspect the exact reason and retry after correcting th" ++
            "e dependency or repository state.",
    };
}

fn removeCurrentIfLaunch(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    launch_id: []const u8,
) void {
    var record = readLifecycleRecord(allocator, io, path) catch return;
    defer record.deinit();
    if (std.mem.eql(
        u8,
        record.launch_id,
        launch_id,
    )) std.Io.Dir.cwd().deleteFile(io, path) catch |ignored_error| {
        switch (ignored_error) {
            else => {},
        }
    };
}

fn openBrowser(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "/usr/bin/open", url } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.BrowserOpenFailed;
}

fn parseLaunch(args: []const []const u8) !config.LaunchOptions {
    var cwd: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var selector: ?[]const u8 = null;
    var json = false;
    var no_browser = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            json = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--no-browser")) {
            no_browser = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        if (std.mem.eql(u8, args[i], "--cwd")) {
            cwd = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--skill-root")) {
            root = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--pr")) {
            selector = args[i + 1];
        } else return error.InvalidArguments;
        i += 1;
    }
    return .{
        .cwd = cwd orelse return error.MissingCwd,
        .skill_root = root orelse return error.MissingSkillRoot,
        .pr = selector,
        .json = json,
        .no_browser = no_browser,
    };
}

fn snapshotField(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try snapshotPull(parsed.value);
    return allocator.dupe(u8, pull.get(field).?.string);
}
fn snapshotOptionalTextField(
    allocator: std.mem.Allocator,
    raw: []const u8,
    field: []const u8,
) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try snapshotPull(parsed.value);
    const value = pull.get(field) orelse return error.InvalidSnapshot;
    return allocator.dupe(u8, if (value == .null) "" else value.string);
}
fn snapshotBoolField(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try snapshotPull(parsed.value);
    return pull.get(field).?.bool;
}
fn loadSnapshotFiles(
    allocator: std.mem.Allocator,
    raw: []const u8,
    generation: *domain.PrGeneration,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try snapshotPull(parsed.value);
    const files = (pull.get("files") orelse return error.InvalidSnapshot).object;
    const nodes = files.get("nodes").?.array.items;
    for (nodes) |node| {
        const o = node.object;
        const state = o.get("viewerViewedState").?.string;
        const path = o.get("path").?.string;
        const change_type = o.get("changeType").?.string;
        const revision = try domain.revisionKey(
            allocator,
            path,
            change_type,
            "graphql-blob-unavailable",
            path,
        );
        defer allocator.free(revision);
        try generation.addFile(
            .{
                .path = path,
                .additions = @intCast(o.get("additions").?.integer),
                .deletions = @intCast(o.get("deletions").?.integer),
                .change_type = change_type,
                .viewed = snapshotViewedState(state),
                .revision_key = revision,
            },
        );
    }
}

fn snapshotPull(value: std.json.Value) !std.json.ObjectMap {
    const data = value.object.get("data") orelse return error.InvalidSnapshot;
    const repository = data.object.get("repository") orelse return error.InvalidSnapshot;
    const pull = repository.object.get("pullRequest") orelse return error.InvalidSnapshot;
    return pull.object;
}

fn snapshotViewedState(value: []const u8) domain.ViewedState {
    if (std.mem.eql(u8, value, "VIEWED")) return .viewed;
    if (std.mem.eql(u8, value, "DISMISSED")) return .dismissed;
    return .unviewed;
}
fn resolveSelectorUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    gh_path: []const u8,
    cwd: []const u8,
    selector: ?[]const u8,
) ![]u8 {
    if (selector) |value| if (std.mem.startsWith(u8, value, "https://")) {
        return allocator.dupe(u8, value);
    };
    const argv: []const []const u8 = if (selector) |value| &.{
        gh_path,
        "pr",
        "view",
        value,
        "--json",
        "url",
        "--jq",
        ".url",
    } else &.{ gh_path, "pr", "view", "--json", "url", "--jq", ".url" };
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.PullRequestResolutionFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, "\r\n"));
}

fn preflightGhAuthentication(
    allocator: std.mem.Allocator,
    io: std.Io,
    gh_path: []const u8,
    cwd: []const u8,
    selector: ?[]const u8,
) !void {
    if (selector) |value| if (std.mem.startsWith(u8, value, "https://")) {
        const identity = try pr.parseUrl(value);
        return requireGhAuthentication(allocator, io, gh_path, identity.host);
    };
    if (try repositoryHostAlloc(allocator, io, cwd)) |host| {
        defer allocator.free(host);
        return requireGhAuthentication(allocator, io, gh_path, host);
    }
    const result = try std.process.run(
        allocator,
        io,
        .{ .argv = &.{ gh_path, "auth", "status" } },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitHubAuthenticationFailed;
    }
}

fn repositoryHostAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) !?[]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", cwd, "config", "--get", "remote.origin.url" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;
    return remoteHostAlloc(allocator, std.mem.trim(u8, result.stdout, "\r\n"));
}

fn remoteHostAlloc(allocator: std.mem.Allocator, remote: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, remote, "://")) |scheme_end| {
        const authority_start = scheme_end + 3;
        const authority_end = std.mem.indexOfScalarPos(
            u8,
            remote,
            authority_start,
            '/',
        ) orelse remote.len;
        const authority = remote[authority_start..authority_end];
        const host_start = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0;
        if (host_start == authority.len) return null;
        return @as(?[]u8, try allocator.dupe(u8, authority[host_start..]));
    }
    const at = std.mem.indexOfScalar(u8, remote, '@') orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, remote, at + 1, ':') orelse return null;
    if (colon == at + 1) return null;
    return @as(?[]u8, try allocator.dupe(u8, remote[at + 1 .. colon]));
}
fn requireGhAuthentication(
    allocator: std.mem.Allocator,
    io: std.Io,
    gh_path: []const u8,
    host: []const u8,
) !void {
    const result = try std.process.run(
        allocator,
        io,
        .{ .argv = &.{ gh_path, "auth", "status", "--hostname", host } },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GitHubAuthenticationFailed;
}
fn usage() error{InvalidArguments} {
    return error.InvalidArguments;
}

fn runTestCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.TestCommandFailed;
    }
    return result.stdout;
}

fn failLaunchForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    launch_dir: []const u8,
    repository_cwd: []const u8,
) !void {
    errdefer cleanupFailedLaunch(allocator, io, child, launch_dir, repository_cwd);
    return error.OriginalLaunchFailure;
}

test "launch argv is safe and explicit" {
    const options = try parseLaunch(
        &.{
            "--cwd",
            "/tmp/w",
            "--skill-root",
            "/tmp/s",
            "--pr",
            "https://github.com/o/r/pull/1",
            "--json",
        },
    );
    try std.testing.expect(options.json);
}
test "runtime state is owner-private and the launch claim is exclusive" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const runtime = try std.fs.path.join(allocator, &.{ root, "runtime" });
    defer allocator.free(runtime);
    try ensurePrivateDir(io, runtime);
    const claim_path = try std.fs.path.join(allocator, &.{ runtime, "launch.lock" });
    defer allocator.free(claim_path);
    var first = try acquireLaunchClaim(io, claim_path);
    defer first.close(io);
    defer first.unlock(io);
    try std.testing.expectError(
        error.SynopticLaunchInProgress,
        acquireLaunchClaim(io, claim_path),
    );
    const receipt_path = try std.fs.path.join(allocator, &.{ runtime, "current.json" });
    defer allocator.free(receipt_path);
    try writeOperationalFile(allocator, io, receipt_path, "{}\n");
    var receipt = try std.Io.Dir.openFileAbsolute(io, receipt_path, .{});
    defer receipt.close(io);
    const stat = try receipt.stat(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0), stat.permissions.toMode() & 0o077);
}
test "runtime custody rejects symlink roots and remote hosts retain identity" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "target", .default_dir);
    try tmp.dir.symLink(io, "target", "runtime-link", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const link = try std.fs.path.join(allocator, &.{ root, "runtime-link" });
    defer allocator.free(link);
    var rejected = false;
    ensurePrivateDir(io, link) catch {
        rejected = true;
    };
    try std.testing.expect(rejected);
    const https = (try remoteHostAlloc(
        allocator,
        "https://github.example.test/o/r.git",
    )).?;
    defer allocator.free(https);
    try std.testing.expectEqualStrings("github.example.test", https);
    const ssh = (try remoteHostAlloc(allocator, "git@github.example.test:o/r.git")).?;
    defer allocator.free(ssh);
    try std.testing.expectEqualStrings("github.example.test", ssh);
    const direct = try resolveSelectorUrl(
        allocator,
        io,
        "/not-executed",
        ".",
        "https://github.example.test/o/r/pull/9",
    );
    defer allocator.free(direct);
    try std.testing.expectEqualStrings("https://github.example.test/o/r/pull/9", direct);
}
test "stop cannot report success after a terminal cleanup error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "error.json", .data = "{}" });
    const path = try tmp.dir.realPathFileAlloc(io, "error.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(
        error.SynopticChildShutdownFailed,
        requireNoTerminalError(io, path),
    );
}
test "launch distinguishes missing and unreadable lifecycle records" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(missing);
    const current_path = try std.fs.path.join(allocator, &.{ missing, "current.json" });
    defer allocator.free(current_path);
    try std.testing.expect((try readCurrentForLaunch(allocator, io, current_path)) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "current.json", .data = "{}" });
    try std.testing.expectError(
        error.InvalidLifecycleRecord,
        readCurrentForLaunch(allocator, io, current_path),
    );
}
test "terminal shutdown removes its lifecycle record before returning failure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(runtime);
    const current_path = try std.fs.path.join(allocator, &.{ runtime, "current.json" });
    defer allocator.free(current_path);
    try writeOperationalFile(
        allocator,
        io,
        current_path,
        "{\"runtimeSchema\":\"synoptic-runtime/v1\",\"launchId\":\"launch\"," ++
            "\"runtimeRoot\":\"/tmp/runtime\",\"executable\":\"/bin/false\"," ++
            "\"url\":\"http://127.0.0.1:1/\",\"pid\":1}",
    );
    try std.testing.expectError(
        error.SyntheticTerminalFailure,
        finishLifecycleRecord(
            allocator,
            io,
            runtime,
            "launch",
            error.SyntheticTerminalFailure,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, current_path, .{}),
    );
}
test "dead launch recovery retires managed custody" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked", .data = "head\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo);
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| {
        const output = try runTestCommand(allocator, io, repo, argv);
        allocator.free(output);
    }
    const runtime_root = try std.fs.path.join(allocator, &.{ root, "runtime" });
    defer allocator.free(runtime_root);
    const launch_id = "0123456789abcdef0123456789abcdef0123456789abcdef";
    const launch_dir = try std.fs.path.join(allocator, &.{ runtime_root, launch_id });
    defer allocator.free(launch_dir);
    try std.Io.Dir.cwd().createDirPath(io, launch_dir);
    const managed = try std.fs.path.join(allocator, &.{ launch_dir, "worktree" });
    defer allocator.free(managed);
    const head_raw = try runTestCommand(
        allocator,
        io,
        repo,
        &.{ "git", "rev-parse", "HEAD" },
    );
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const added = try runTestCommand(
        allocator,
        io,
        repo,
        &.{ "git", "worktree", "add", "--detach", managed, head },
    );
    allocator.free(added);
    var record = LifecycleRecord{
        .allocator = allocator,
        .raw = try allocator.dupe(u8, "{}"),
        .launch_id = try allocator.dupe(u8, launch_id),
        .runtime_root = try allocator.dupe(u8, runtime_root),
        .executable = try allocator.dupe(u8, "/tmp/synoptic"),
        .url = try allocator.dupe(u8, "http://127.0.0.1:1/"),
        .worktree = try allocator.dupe(u8, managed),
        .worktree_kind = try allocator.dupe(u8, "managed"),
        .repository_cwd = try allocator.dupe(u8, repo),
        .pid = 999_999,
    };
    defer record.deinit();
    try retireDeadLaunch(allocator, io, runtime_root, record);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, managed, .{}),
    );
}
test "failed launch retires descendants before managed custody and preserves error" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.createDirPath(io, "launch");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked", .data = "head\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo);
    const launch_dir = try std.fs.path.join(allocator, &.{ root, "launch" });
    defer allocator.free(launch_dir);
    const managed = try std.fs.path.join(allocator, &.{ launch_dir, "worktree" });
    defer allocator.free(managed);
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| allocator.free(try runTestCommand(allocator, io, repo, argv));
    const head_raw = try runTestCommand(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    allocator.free(try runTestCommand(
        allocator,
        io,
        repo,
        &.{ "git", "worktree", "add", "--detach", managed, head },
    ));
    var child = try std.process.spawn(io, .{
        .argv = &.{
            "/bin/sh",
            "-c",
            "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & " ++
                "while :; do sleep 1; done",
        },
        .cwd = .{ .path = managed },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const process_group: u64 = @intCast(child.id.?);
    try std.testing.expectError(
        error.OriginalLaunchFailure,
        failLaunchForTest(allocator, io, &child, launch_dir, repo),
    );
    try std.testing.expect(@import("cas_runtime").websocket.waitForProcessGroupExit(
        process_group,
        1_000,
    ));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, managed, .{}));
}
test {
    _ = domain;
}
