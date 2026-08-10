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

fn launch(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const options = try parseLaunch(args);
    try config.validateManifest(allocator, io, options.skill_root);
    const gh_path = environment.get("SYNOPTIC_GH") orelse "gh";
    const codex_path = environment.get("SYNOPTIC_CODEX") orelse "codex";
    const gh_resolved = try @import("cas_runtime").resolveExecutableAlloc(allocator, gh_path);
    defer allocator.free(gh_resolved);
    const codex_resolved = try @import("cas_runtime").resolveExecutableAlloc(allocator, codex_path);
    defer allocator.free(codex_resolved);
    const selector_url = try resolveSelectorUrl(allocator, io, gh_resolved, options.cwd, options.pr);
    defer allocator.free(selector_url);
    const identity = try pr.parseUrl(selector_url);
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_resolved, .host = identity.host };
    var pages = try broker.readGenerationPages(identity.owner, identity.repository, identity.number);
    defer pages.deinit();
    const snapshot_head = try snapshotField(allocator, pages.files.items[0], "headRefOid");
    defer allocator.free(snapshot_head);
    const snapshot_base = try snapshotField(allocator, pages.files.items[0], "baseRefOid");
    defer allocator.free(snapshot_base);
    const pull_request_id = try snapshotField(allocator, pages.files.items[0], "id");
    defer allocator.free(pull_request_id);
    var generation = try domain.PrGeneration.initFull(allocator, snapshot_base, snapshot_head);
    errdefer generation.deinit();
    for (pages.files.items) |page| try loadSnapshotFiles(allocator, page, &generation);
    for (pages.threads.items) |page| try loadThreads(allocator, page, &generation);

    const managed_path = try std.fmt.allocPrint(allocator, "/tmp/synoptic/{d}/worktree", .{std.c.getpid()});
    defer allocator.free(managed_path);
    var custody = try worktree.select(allocator, io, options.cwd, snapshot_head, managed_path);
    defer allocator.free(custody.path());
    const review_cwd = custody.path();
    try hydrateRevisionKeys(allocator, io, review_cwd, snapshot_base, &generation);
    var state = try App.init(allocator, snapshot_head);
    state.replaceGeneration(generation);
    defer state.deinit();

    var registry = try sessions.Registry.start(allocator, io, review_cwd, codex_resolved);
    defer registry.deinit();
    try registry.createPrimary(review_cwd);
    state.primary_ready = registry.primaryReady();
    var server = try http.Server.bind(allocator, io, options.skill_root);
    defer server.deinit();
    var token_buf: [64]u8 = undefined;
    const token = server.tokenHex(&token_buf);
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/?token={s}", .{ server.port(), token });
    defer allocator.free(url);
    var out = std.Io.File.stdout().writer(io, &.{});
    const repository = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ identity.owner, identity.repository });
    defer allocator.free(repository);
    if (options.json) try out.interface.print("{{\"schema\":\"synoptic-launch-ready/v1\",\"status\":\"ready\",\"capabilityState\":\"ready\",\"lifecycle\":\"owner-lived\",\"pid\":{d},\"url\":{f},\"repository\":{f},\"pullRequest\":{d},\"worktree\":{f},\"worktreeKind\":{f},\"transport\":\"stdio\"}}\n", .{ std.c.getpid(), std.json.fmt(url, .{}), std.json.fmt(repository, .{}), identity.number, std.json.fmt(review_cwd, .{}), std.json.fmt(custody.kind(), .{}) }) else try out.interface.print("{s}\n", .{url});
    try out.interface.flush();
    const skill_path = try std.fs.path.join(allocator, &.{ options.skill_root, "SKILL.md" });
    defer allocator.free(skill_path);
    var runtime = http.Runtime{ .app = &state, .registry = &registry, .broker = broker, .owner = identity.owner, .name = identity.repository, .number = identity.number, .pull_request_id = pull_request_id, .cwd = review_cwd, .skill_path = skill_path, .repository_cwd = options.cwd, .custody = custody };
    while (true) {
        state.primary_ready = registry.primaryReady();
        server.serveOne(&runtime) catch |err| switch (err) {
            error.EndOfStream => continue,
            else => return err,
        };
    }
}

fn parseLaunch(args: []const []const u8) !config.LaunchOptions {
    var cwd: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var selector: ?[]const u8 = null;
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            json = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        if (std.mem.eql(u8, args[i], "--cwd")) cwd = args[i + 1] else if (std.mem.eql(u8, args[i], "--skill-root")) root = args[i + 1] else if (std.mem.eql(u8, args[i], "--pr")) selector = args[i + 1] else return error.InvalidArguments;
        i += 1;
    }
    return .{ .cwd = cwd orelse return error.MissingCwd, .skill_root = root orelse return error.MissingSkillRoot, .pr = selector, .json = json };
}

fn snapshotField(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    return allocator.dupe(u8, (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object.get(field).?.string);
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
fn loadThreads(allocator: std.mem.Allocator, raw: []const u8, generation: *domain.PrGeneration) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = (((parsed.value.object.get("data").?).object.get("repository").?).object.get("pullRequest").?).object;
    for (pull.get("reviewThreads").?.object.get("nodes").?.array.items) |node| {
        const o = node.object;
        if (o.get("isResolved").?.bool) continue;
        const line: ?u32 = if (o.get("line").? == .null) null else @intCast(o.get("line").?.integer);
        try generation.addThread(.{ .id = o.get("id").?.string, .path = o.get("path").?.string, .line = line, .outdated = o.get("isOutdated").?.bool });
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
