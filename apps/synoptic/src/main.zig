const std = @import("std");
const builtin = @import("builtin");
const app_meta = @import("app_meta");
const App = @import("app.zig").App;
const config = @import("config.zig");
const domain = @import("domain.zig");
const graphql = @import("graphql.zig");
const github = @import("github.zig");
const http = @import("http.zig");
const pr = @import("pr.zig");
const sessions = @import("sessions.zig");
const worktree = @import("worktree.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) return usage();
    if (std.mem.eql(u8, argv[1], "version")) return printVersion(init.io);
    if (std.mem.eql(u8, argv[1], "capabilities")) return printCapabilities(init.io, argv[2..]);
    if (std.mem.eql(u8, argv[1], "launch")) return launch(allocator, init.io, init.environ_map, argv[2..]);
    if (std.mem.eql(u8, argv[1], "serve")) return serve(allocator, init.io, init.environ_map, argv[2..]);
    if (std.mem.eql(u8, argv[1], "status")) return status(allocator, init.io, init.environ_map, argv[2..]);
    if (std.mem.eql(u8, argv[1], "stop")) return stop(allocator, init.io, init.environ_map, argv[2..]);
    return usage();
}

fn printVersion(io: std.Io) !void {
    var out = std.Io.File.stdout().writer(io, &.{});
    try out.interface.print("synoptic {s}\n", .{app_meta.version});
    try out.interface.flush();
}
fn printCapabilities(io: std.Io, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[0], "--format") and std.mem.eql(u8, args[1], "json");
    if (!json and args.len != 0) return error.InvalidArguments;
    var out = std.Io.File.stdout().writer(io, &.{});
    if (json) try out.interface.print("{{\"synopticCapabilities\":{{\"version\":{f},\"platform\":\"macos\",\"skillAbi\":\"{s}\",\"uiAbi\":\"{s}\",\"features\":{{\"casRuntimeV1\":true,\"githubViewedQueueV1\":true,\"ephemeralFileSessionsV1\":true,\"githubActionCardsV1\":true}}}}}}\n", .{ std.json.fmt(app_meta.version, .{}), config.skill_abi, config.ui_abi }) else try out.interface.print("synoptic {s}\n{s}\n{s}\n", .{ app_meta.version, config.skill_abi, config.ui_abi });
    try out.interface.flush();
}

const LifecycleRecord = struct {
    allocator: std.mem.Allocator,
    raw: []u8,
    launch_id: []u8,
    runtime_root: []u8,
    executable: []u8,
    url: []u8,
    pid: u64,

    fn deinit(self: *LifecycleRecord) void {
        self.allocator.free(self.raw);
        self.allocator.free(self.launch_id);
        self.allocator.free(self.runtime_root);
        self.allocator.free(self.executable);
        self.allocator.free(self.url);
    }
};

fn launch(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const options = try parseLaunch(args);
    try config.validateManifest(allocator, io, options.skill_root);
    var settings = try config.Settings.load(allocator, io, environment, options.skill_root);
    defer settings.deinit();
    const runtime_root = try runtimeRootAlloc(allocator, environment);
    defer allocator.free(runtime_root);
    try std.Io.Dir.cwd().createDirPath(io, runtime_root);
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    if (readLifecycleRecord(allocator, io, current_path)) |record_value| {
        var record = record_value;
        defer record.deinit();
        if (try verifiedProcess(allocator, io, record)) return error.SynopticAlreadyRunning;
        std.Io.Dir.cwd().deleteFile(io, current_path) catch {};
    } else |_| {}

    var launch_bytes: [24]u8 = undefined;
    io.random(&launch_bytes);
    var launch_buf: [48]u8 = undefined;
    const launch_id = try std.fmt.bufPrint(&launch_buf, "{x}", .{launch_bytes});
    const launch_dir = try std.fs.path.join(allocator, &.{ runtime_root, launch_id });
    defer allocator.free(launch_dir);
    try std.Io.Dir.cwd().createDirPath(io, launch_dir);
    const ready_path = try std.fs.path.join(allocator, &.{ launch_dir, "ready.json" });
    defer allocator.free(ready_path);
    const error_path = try std.fs.path.join(allocator, &.{ launch_dir, "error.json" });
    defer allocator.free(error_path);
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    try child_argv.appendSlice(allocator, &.{ self_path, "serve", "--launch-id", launch_id, "--runtime-root", runtime_root });
    try child_argv.appendSlice(allocator, args);
    var child = try std.process.spawn(io, .{
        .argv = child_argv.items,
        .environ_map = environment,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    var child_owned = true;
    errdefer if (child_owned) child.kill(io);
    const child_pid: u64 = @intCast(child.id orelse return error.ChildMissingPid);
    const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
    var ready: LifecycleRecord = undefined;
    while (true) {
        if (readLifecycleRecord(allocator, io, ready_path)) |candidate| {
            if (candidate.pid != child_pid or !std.mem.eql(u8, candidate.launch_id, launch_id)) {
                var invalid = candidate;
                invalid.deinit();
                return error.InvalidLaunchReadiness;
            }
            ready = candidate;
            break;
        } else |_| {}
        if (std.Io.Dir.cwd().readFileAlloc(io, error_path, allocator, .limited(64 * 1024))) |child_error| {
            defer allocator.free(child_error);
            var err_out = std.Io.File.stderr().writer(io, &.{});
            try err_out.interface.print("{s}\n", .{child_error});
            try err_out.interface.flush();
            return error.SynopticChildLaunchFailed;
        } else |_| {}
        if (!processAlive(child_pid)) return error.SynopticChildExitedBeforeReady;
        const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
        if (now_ms - started_ms >= config.lifecycle_ready_timeout_ms) return error.SynopticReadinessTimeout;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    defer ready.deinit();
    if (!try verifiedProcess(allocator, io, ready)) return error.InvalidLaunchReadiness;
    try writeOperationalFile(allocator, io, current_path, ready.raw);
    if (!options.no_browser and settings.browser_open) openBrowser(allocator, io, ready.url) catch |err| {
        removeCurrentIfLaunch(allocator, io, current_path, launch_id);
        return err;
    };
    var out = std.Io.File.stdout().writer(io, &.{});
    if (options.json) try out.interface.print("{s}\n", .{ready.raw}) else try out.interface.print("{s}\n", .{ready.url});
    try out.interface.flush();
    child_owned = false;
}

fn serve(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len < 4 or !std.mem.eql(u8, args[0], "--launch-id") or !std.mem.eql(u8, args[2], "--runtime-root")) return error.InvalidArguments;
    const launch_id = args[1];
    const runtime_root = args[3];
    if (launch_id.len != 48 or std.mem.indexOfScalar(u8, launch_id, std.fs.path.sep) != null) return error.InvalidLaunchId;
    serveReview(allocator, io, environment, args[4..], launch_id, runtime_root) catch |err| {
        writeLaunchError(allocator, io, runtime_root, launch_id, err) catch {};
        return err;
    };
}

fn serveReview(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, args: []const []const u8, launch_id: []const u8, runtime_root: []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const options = try parseLaunch(args);
    try config.validateManifest(allocator, io, options.skill_root);
    var settings = try config.Settings.load(allocator, io, environment, options.skill_root);
    defer settings.deinit();
    const gh_path = environment.get("SYNOPTIC_GH") orelse "gh";
    const codex_path = environment.get("SYNOPTIC_CODEX") orelse "codex";
    const gh_resolved = try @import("cas_runtime").resolveExecutableAlloc(allocator, gh_path);
    defer allocator.free(gh_resolved);
    const codex_resolved = try @import("cas_runtime").resolveExecutableAlloc(allocator, codex_path);
    defer allocator.free(codex_resolved);
    const schema_dir = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "codex-schema" });
    defer allocator.free(schema_dir);
    if (try config.codexSchemaProblemAlloc(allocator, io, codex_resolved, schema_dir)) |problem| {
        defer allocator.free(problem);
        try writeLaunchProblem(allocator, io, runtime_root, launch_id, problem);
        return error.CodexSchemaIncompatible;
    }
    if (options.pr == null or !std.mem.startsWith(u8, options.pr.?, "https://")) try requireGhAuthentication(allocator, io, gh_resolved, "github.com");
    const selector_url = try resolveSelectorUrl(allocator, io, gh_resolved, options.cwd, options.pr);
    defer allocator.free(selector_url);
    const identity = try pr.parseUrl(selector_url);
    try requireGhAuthentication(allocator, io, gh_resolved, identity.host);
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_resolved, .host = identity.host };
    var pages = try broker.readGenerationPages(identity.owner, identity.repository, identity.number);
    defer pages.deinit();
    const snapshot_head = try snapshotField(allocator, pages.files.items[0], "headRefOid");
    defer allocator.free(snapshot_head);
    const snapshot_base = try snapshotField(allocator, pages.files.items[0], "baseRefOid");
    defer allocator.free(snapshot_base);
    const pull_request_id = try snapshotField(allocator, pages.files.items[0], "id");
    defer allocator.free(pull_request_id);
    const title = try snapshotField(allocator, pages.files.items[0], "title");
    defer allocator.free(title);
    const body = try snapshotOptionalTextField(allocator, pages.files.items[0], "body");
    defer allocator.free(body);
    const base_ref = try snapshotField(allocator, pages.files.items[0], "baseRefName");
    defer allocator.free(base_ref);
    const head_ref = try snapshotField(allocator, pages.files.items[0], "headRefName");
    defer allocator.free(head_ref);
    var generation = try domain.PrGeneration.initFull(allocator, snapshot_base, snapshot_head);
    errdefer generation.deinit();
    for (pages.files.items) |page| try loadSnapshotFiles(allocator, page, &generation);
    for (pages.threads.items) |page| try github.loadThreads(allocator, page, &generation);

    const managed_path = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "worktree" });
    defer allocator.free(managed_path);
    var custody = try worktree.select(allocator, io, options.cwd, head_ref, snapshot_head, managed_path, settings.worktree_prefer_current_pr_checkout);
    defer allocator.free(custody.path());
    const review_cwd = custody.path();
    try hydrateRevisionKeys(allocator, io, review_cwd, snapshot_base, &generation);
    var worktree_baseline = try worktree.Baseline.capture(allocator, io, review_cwd);
    defer worktree_baseline.deinit();
    var state = try App.init(allocator, snapshot_head);
    state.replaceGeneration(generation);
    state.file_review_start_mode = settings.file_review_start_mode;
    defer state.deinit();

    var registry = try sessions.Registry.start(allocator, io, review_cwd, codex_resolved);
    defer registry.deinit();
    var exclusion_outcomes = try state.applyAutomaticExclusions(&settings, broker, identity.owner, identity.repository, identity.number, pull_request_id, review_cwd);
    defer {
        for (exclusion_outcomes.items) |outcome| outcome.deinit();
        exclusion_outcomes.deinit(allocator);
    }
    try http.queueExclusionEvents(&registry, exclusion_outcomes.items);
    try registry.setGenerationEvidence(&state.generation);
    const skill_path = try std.fs.path.join(allocator, &.{ options.skill_root, "SKILL.md" });
    defer allocator.free(skill_path);
    const pr_context = try primaryContextAlloc(allocator, identity.owner, identity.repository, identity.number, title, body, base_ref, snapshot_base, head_ref, snapshot_head, &state.generation);
    defer allocator.free(pr_context);
    try registry.createPrimary(io, review_cwd, skill_path, pr_context);
    state.primary_ready = registry.primaryReady();
    var server = try http.Server.bind(allocator, io, options.skill_root);
    defer server.deinit();
    var token_buf: [64]u8 = undefined;
    const token = server.tokenHex(&token_buf);
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/?token={s}", .{ server.port(), token });
    defer allocator.free(url);
    const repository = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ identity.owner, identity.repository });
    defer allocator.free(repository);
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const receipt = try std.fmt.allocPrint(allocator, "{{\"schema\":\"synoptic-launch-ready/v1\",\"runtimeSchema\":\"{s}\",\"status\":\"ready\",\"capabilityState\":\"ready\",\"lifecycle\":\"detached\",\"launchId\":{f},\"runtimeRoot\":{f},\"executable\":{f},\"pid\":{d},\"url\":{f},\"repository\":{f},\"pullRequest\":{d},\"worktree\":{f},\"worktreeKind\":{f},\"transport\":\"stdio\"}}", .{ config.lifecycle_schema, std.json.fmt(launch_id, .{}), std.json.fmt(runtime_root, .{}), std.json.fmt(executable, .{}), std.c.getpid(), std.json.fmt(url, .{}), std.json.fmt(repository, .{}), identity.number, std.json.fmt(review_cwd, .{}), std.json.fmt(custody.kind(), .{}) });
    defer allocator.free(receipt);
    const ready_path = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "ready.json" });
    defer allocator.free(ready_path);
    try writeOperationalFile(allocator, io, ready_path, receipt);
    var runtime = http.Runtime{ .app = &state, .registry = &registry, .broker = broker, .owner = identity.owner, .name = identity.repository, .number = identity.number, .pull_request_id = pull_request_id, .cwd = review_cwd, .skill_path = skill_path, .repository_cwd = options.cwd, .custody = custody, .baseline = &worktree_baseline, .settings = &settings, .launch_id = launch_id };
    const stop_request_path = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "stop.request" });
    defer allocator.free(stop_request_path);
    var terminal_error: ?anyerror = null;
    while (!runtime.stop_requested) {
        state.primary_ready = registry.primaryReady();
        server.serveOne(&runtime) catch |err| switch (err) {
            error.EndOfStream => continue,
            else => {
                terminal_error = err;
                break;
            },
        };
        if (std.Io.Dir.cwd().access(io, stop_request_path, .{})) |_| runtime.stop_requested = true else |_| {}
    }
    try registry.beginSynchronization(io, sessions.safe_boundary_timeout_ms);
    defer registry.endSynchronization();
    try worktree.reconcileShutdown(allocator, io, custody, state.generation.head_oid, &worktree_baseline);
    std.Io.Dir.cwd().deleteFile(io, stop_request_path) catch {};
    if (terminal_error) |err| return err;
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    removeCurrentIfLaunch(allocator, io, current_path, launch_id);
}

fn status(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, args: []const []const u8) !void {
    const json = try parseJsonOnly(args);
    const runtime_root = try runtimeRootAlloc(allocator, environment);
    defer allocator.free(runtime_root);
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    var out = std.Io.File.stdout().writer(io, &.{});
    var record = readLifecycleRecord(allocator, io, current_path) catch {
        if (json) try out.interface.writeAll("{\"schema\":\"synoptic-status/v1\",\"status\":\"stopped\"}\n") else try out.interface.writeAll("stopped\n");
        try out.interface.flush();
        return;
    };
    defer record.deinit();
    if (!try verifiedProcess(allocator, io, record)) {
        std.Io.Dir.cwd().deleteFile(io, current_path) catch {};
        if (json) try out.interface.writeAll("{\"schema\":\"synoptic-status/v1\",\"status\":\"stopped\"}\n") else try out.interface.writeAll("stopped\n");
    } else if (json) {
        try out.interface.print("{{\"schema\":\"synoptic-status/v1\",\"status\":\"running\",\"launchId\":{f},\"pid\":{d},\"url\":{f}}}\n", .{ std.json.fmt(record.launch_id, .{}), record.pid, std.json.fmt(record.url, .{}) });
    } else try out.interface.print("running {d} {s}\n", .{ record.pid, record.url });
    try out.interface.flush();
}

fn stop(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, args: []const []const u8) !void {
    const json = try parseJsonOnly(args);
    const runtime_root = try runtimeRootAlloc(allocator, environment);
    defer allocator.free(runtime_root);
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    var record = readLifecycleRecord(allocator, io, current_path) catch return printStopResult(io, json, null, false);
    defer record.deinit();
    if (!try verifiedProcess(allocator, io, record)) {
        std.Io.Dir.cwd().deleteFile(io, current_path) catch {};
        return printStopResult(io, json, null, false);
    }
    const pid = std.math.cast(std.posix.pid_t, record.pid) orelse return error.InvalidRuntimePid;
    const stop_request_path = try std.fs.path.join(allocator, &.{ record.runtime_root, record.launch_id, "stop.request" });
    defer allocator.free(stop_request_path);
    try writeOperationalFile(allocator, io, stop_request_path, "{}\n");
    wakeLoopback(allocator, io, record.url) catch {};
    const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
    while (try verifiedProcess(allocator, io, record)) {
        const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
        if (now_ms - started_ms >= config.lifecycle_stop_timeout_ms) {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    const killed_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
    while (try verifiedProcess(allocator, io, record)) {
        const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
        if (now_ms - killed_ms >= 1_000) return error.SynopticStopTimeout;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    removeCurrentIfLaunch(allocator, io, current_path, record.launch_id);
    return printStopResult(io, json, record.launch_id, true);
}

fn wakeLoopback(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidLifecycleUrl;
    const slash = std.mem.indexOfScalarPos(u8, url, prefix.len, '/') orelse return error.InvalidLifecycleUrl;
    const port = try std.fmt.parseInt(u16, url[prefix.len..slash], 10);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const request = try std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ url[slash..], port });
    defer allocator.free(request);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(request);
    try writer.interface.flush();
}

fn printStopResult(io: std.Io, json: bool, launch_id: ?[]const u8, stopped: bool) !void {
    var out = std.Io.File.stdout().writer(io, &.{});
    if (json) try out.interface.print("{{\"schema\":\"synoptic-stop/v1\",\"status\":\"{s}\",\"launchId\":{f}}}\n", .{ if (stopped) "stopped" else "not-running", std.json.fmt(launch_id orelse "", .{}) }) else try out.interface.print("{s}\n", .{if (stopped) "stopped" else "not running"});
    try out.interface.flush();
}

fn parseJsonOnly(args: []const []const u8) !bool {
    if (args.len == 0) return false;
    if (args.len == 1 and std.mem.eql(u8, args[0], "--json")) return true;
    return error.InvalidArguments;
}

fn runtimeRootAlloc(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) ![]u8 {
    return std.fs.path.join(allocator, &.{ environment.get("TMPDIR") orelse "/tmp", "synoptic" });
}

fn readLifecycleRecord(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LifecycleRecord {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    errdefer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidLifecycleRecord,
    };
    const runtime_schema = object.get("runtimeSchema") orelse return error.InvalidLifecycleRecord;
    if (runtime_schema != .string or !std.mem.eql(u8, runtime_schema.string, config.lifecycle_schema)) return error.InvalidLifecycleRecord;
    const launch_id = try lifecycleStringAlloc(allocator, object, "launchId");
    errdefer allocator.free(launch_id);
    const runtime_root = try lifecycleStringAlloc(allocator, object, "runtimeRoot");
    errdefer allocator.free(runtime_root);
    const executable = try lifecycleStringAlloc(allocator, object, "executable");
    errdefer allocator.free(executable);
    const url = try lifecycleStringAlloc(allocator, object, "url");
    errdefer allocator.free(url);
    const pid_value = object.get("pid") orelse return error.InvalidLifecycleRecord;
    if (pid_value != .integer or pid_value.integer <= 0) return error.InvalidLifecycleRecord;
    return .{ .allocator = allocator, .raw = raw, .launch_id = launch_id, .runtime_root = runtime_root, .executable = executable, .url = url, .pid = @intCast(pid_value.integer) };
}

fn lifecycleStringAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidLifecycleRecord;
    if (value != .string or value.string.len == 0) return error.InvalidLifecycleRecord;
    return allocator.dupe(u8, value.string);
}

fn verifiedProcess(allocator: std.mem.Allocator, io: std.Io, record: LifecycleRecord) !bool {
    if (!processAlive(record.pid)) return false;
    const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{record.pid});
    defer allocator.free(pid_text);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "/bin/ps", "-ww", "-p", pid_text, "-o", "command=" } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return false;
    const command = std.mem.trim(u8, result.stdout, " \t\r\n");
    const identity = try std.fmt.allocPrint(allocator, "serve --launch-id {s} --runtime-root {s}", .{ record.launch_id, record.runtime_root });
    defer allocator.free(identity);
    return std.mem.startsWith(u8, command, record.executable) and std.mem.indexOf(u8, command, identity) != null;
}

fn processAlive(process_id: u64) bool {
    const pid = std.math.cast(std.posix.pid_t, process_id) orelse return false;
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

fn writeOperationalFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, contents: []const u8) !void {
    const staging = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.c.getpid() });
    defer allocator.free(staging);
    std.Io.Dir.cwd().deleteFile(io, staging) catch {};
    errdefer std.Io.Dir.cwd().deleteFile(io, staging) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staging, .data = contents });
    try std.Io.Dir.renameAbsolute(staging, path, io);
}

fn writeLaunchError(allocator: std.mem.Allocator, io: std.Io, runtime_root: []const u8, launch_id: []const u8, err: anyerror) !void {
    const path = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "error.json" });
    defer allocator.free(path);
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
    const receipt = try std.fmt.allocPrint(allocator, "{{\"schema\":\"synoptic-launch-error/v1\",\"status\":\"blocked\",\"reason\":{f},\"remediation\":{f}}}", .{ std.json.fmt(@errorName(err), .{}), std.json.fmt(launchRemediation(err), .{}) });
    defer allocator.free(receipt);
    try writeOperationalFile(allocator, io, path, receipt);
}

fn writeLaunchProblem(allocator: std.mem.Allocator, io: std.Io, runtime_root: []const u8, launch_id: []const u8, reason: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ runtime_root, launch_id, "error.json" });
    defer allocator.free(path);
    const receipt = try std.fmt.allocPrint(allocator, "{{\"schema\":\"synoptic-launch-error/v1\",\"status\":\"blocked\",\"reason\":{f},\"remediation\":\"Install a Codex version providing every named app-server surface.\"}}", .{std.json.fmt(reason, .{})});
    defer allocator.free(receipt);
    try writeOperationalFile(allocator, io, path, receipt);
}

fn primaryContextAlloc(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8, number: u64, title: []const u8, body: []const u8, base_ref: []const u8, base_oid: []const u8, head_ref: []const u8, head_oid: []const u8, generation: *const domain.PrGeneration) ![]u8 {
    var files: std.Io.Writer.Allocating = .init(allocator);
    defer files.deinit();
    try std.json.Stringify.value(generation.files.items, .{}, &files.writer);
    const repository = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, repo });
    defer allocator.free(repository);
    return std.fmt.allocPrint(allocator, "{{\"repository\":{f},\"pullRequest\":{d},\"title\":{f},\"body\":{f},\"baseRefName\":{f},\"baseRefOid\":{f},\"headRefName\":{f},\"headRefOid\":{f},\"files\":{s}}}", .{ std.json.fmt(repository, .{}), number, std.json.fmt(title, .{}), std.json.fmt(body, .{}), std.json.fmt(base_ref, .{}), std.json.fmt(base_oid, .{}), std.json.fmt(head_ref, .{}), std.json.fmt(head_oid, .{}), files.written() });
}

fn launchRemediation(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound, error.ExecutableNotFound, error.MissingExecutable => "Install codex and gh and ensure both resolve on PATH.",
        error.GitHubAuthenticationFailed => "Run gh auth login for the target GitHub host, then retry.",
        error.PullRequestResolutionFailed => "Run gh pr view successfully from the checkout or pass a valid --pr selector.",
        error.BaseFetchFailed, error.ManagedWorktreeFetchFailed => "Ensure the PR base and head objects are fetchable from origin.",
        error.InvalidUiManifest, error.InvalidExclusionsManifest => "Install a Synoptic skill package with valid synoptic-ui/v1 and synoptic-exclusions/v1 assets.",
        error.InvalidSynopticConfig => "Correct the supported Synoptic settings in config.toml, then retry.",
        else => "Inspect the exact reason and retry after correcting the dependency or repository state.",
    };
}

fn removeCurrentIfLaunch(allocator: std.mem.Allocator, io: std.Io, path: []const u8, launch_id: []const u8) void {
    var record = readLifecycleRecord(allocator, io, path) catch return;
    defer record.deinit();
    if (std.mem.eql(u8, record.launch_id, launch_id)) std.Io.Dir.cwd().deleteFile(io, path) catch {};
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
        if (std.mem.eql(u8, args[i], "--cwd")) cwd = args[i + 1] else if (std.mem.eql(u8, args[i], "--skill-root")) root = args[i + 1] else if (std.mem.eql(u8, args[i], "--pr")) selector = args[i + 1] else return error.InvalidArguments;
        i += 1;
    }
    return .{ .cwd = cwd orelse return error.MissingCwd, .skill_root = root orelse return error.MissingSkillRoot, .pr = selector, .json = json, .no_browser = no_browser };
}

fn snapshotField(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    return allocator.dupe(u8, (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object.get(field).?.string);
}
fn snapshotOptionalTextField(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const value = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object.get(field) orelse return error.InvalidSnapshot;
    return allocator.dupe(u8, if (value == .null) "" else value.string);
}
fn loadSnapshotFiles(allocator: std.mem.Allocator, raw: []const u8, generation: *domain.PrGeneration) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
    const nodes = (pull.get("files") orelse return error.InvalidSnapshot).object.get("nodes").?.array.items;
    for (nodes) |node| {
        const o = node.object;
        const state = o.get("viewerViewedState").?.string;
        const path = o.get("path").?.string;
        const change_type = o.get("changeType").?.string;
        const revision = try domain.revisionKey(allocator, path, change_type, "graphql-blob-unavailable", path);
        defer allocator.free(revision);
        try generation.addFile(.{ .path = path, .additions = @intCast(o.get("additions").?.integer), .deletions = @intCast(o.get("deletions").?.integer), .change_type = change_type, .viewed = if (std.mem.eql(u8, state, "VIEWED")) .viewed else if (std.mem.eql(u8, state, "DISMISSED")) .dismissed else .unviewed, .revision_key = revision });
    }
}
fn resolveSelectorUrl(allocator: std.mem.Allocator, io: std.Io, gh_path: []const u8, cwd: []const u8, selector: ?[]const u8) ![]u8 {
    if (selector) |value| if (std.mem.startsWith(u8, value, "https://github.com/")) return allocator.dupe(u8, value);
    const argv: []const []const u8 = if (selector) |value| &.{ gh_path, "pr", "view", value, "--json", "url", "--jq", ".url" } else &.{ gh_path, "pr", "view", "--json", "url", "--jq", ".url" };
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.PullRequestResolutionFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, "\r\n"));
}
fn requireGhAuthentication(allocator: std.mem.Allocator, io: std.Io, gh_path: []const u8, host: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ gh_path, "auth", "status", "--hostname", host } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GitHubAuthenticationFailed;
}
fn hydrateRevisionKeys(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, base_oid: []const u8, generation: *domain.PrGeneration) !void {
    const fetch = try std.process.run(allocator, io, .{ .argv = &.{ "git", "fetch", "--no-tags", "origin", base_oid }, .cwd = .{ .path = cwd } });
    defer allocator.free(fetch.stdout);
    defer allocator.free(fetch.stderr);
    if (fetch.term != .exited or fetch.term.exited != 0) return error.BaseFetchFailed;
    for (generation.files.items) |file| {
        const spec = try std.fmt.allocPrint(allocator, "HEAD:{s}", .{file.path});
        defer allocator.free(spec);
        const blob_result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "rev-parse", "--verify", spec }, .cwd = .{ .path = cwd } });
        defer allocator.free(blob_result.stdout);
        defer allocator.free(blob_result.stderr);
        const blob = if (blob_result.term == .exited and blob_result.term.exited == 0) std.mem.trim(u8, blob_result.stdout, "\r\n") else "DELETION";
        const range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{base_oid});
        defer allocator.free(range);
        const diff_result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "diff", "--no-ext-diff", "--no-color", range, "--", file.path }, .cwd = .{ .path = cwd } });
        defer allocator.free(diff_result.stdout);
        defer allocator.free(diff_result.stderr);
        if (diff_result.term != .exited or diff_result.term.exited != 0) return error.FileDiffFailed;
        const revision = try domain.revisionKey(allocator, file.path, file.change_type, blob, diff_result.stdout);
        defer allocator.free(revision);
        try generation.setRevision(file.path, revision);
    }
}
fn usage() error{InvalidArguments} {
    return error.InvalidArguments;
}

test "launch argv is safe and explicit" {
    const options = try parseLaunch(&.{ "--cwd", "/tmp/w", "--skill-root", "/tmp/s", "--pr", "https://github.com/o/r/pull/1", "--json" });
    try std.testing.expect(options.json);
}
test {
    _ = domain;
}
