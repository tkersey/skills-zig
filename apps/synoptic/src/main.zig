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

fn printVersion(io: std.Io) !void { var out = std.Io.File.stdout().writer(io, &.{}); try out.interface.print("synoptic {s}\n", .{app_meta.version}); try out.interface.flush(); }
fn printCapabilities(io: std.Io, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[0], "--format") and std.mem.eql(u8, args[1], "json");
    if (!json and args.len != 0) return error.InvalidArguments;
    var out = std.Io.File.stdout().writer(io, &.{});
    if (json) try out.interface.print("{{\"synopticCapabilities\":{{\"version\":{f},\"platform\":\"macos\",\"skillAbi\":\"{s}\",\"uiAbi\":\"{s}\",\"features\":{{\"casRuntimeV1\":true,\"githubViewedQueueV1\":false,\"ephemeralFileSessionsV1\":false,\"githubActionCardsV1\":false,\"verticalSlicePreviewV1\":true}}}}}}\n", .{ std.json.fmt(app_meta.version, .{}), config.skill_abi, config.ui_abi })
    else try out.interface.print("synoptic {s}\n{s}\n{s}\n", .{ app_meta.version, config.skill_abi, config.ui_abi });
    try out.interface.flush();
}

fn launch(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const options = try parseLaunch(args);
    try config.validateManifest(allocator, io, options.skill_root);
    const gh_path = environment.get("SYNOPTIC_GH") orelse "gh";
    const codex_path = environment.get("SYNOPTIC_CODEX") orelse "codex";
    const gh_resolved = try @import("cas_runtime").resolveExecutableAlloc(allocator, gh_path); defer allocator.free(gh_resolved);
    const codex_resolved = try @import("cas_runtime").resolveExecutableAlloc(allocator, codex_path); defer allocator.free(codex_resolved);
    if (!try worktree.isClean(io, allocator, options.cwd)) return error.DirtyCheckoutRequiresManagedWorktree;

    const selector = options.pr orelse return error.PullRequestSelectorRequired;
    const identity = try pr.parseUrl(selector);
    const vars = try std.fmt.allocPrint(allocator, "{{\"owner\":{f},\"name\":{f},\"number\":{d},\"after\":null}}", .{ std.json.fmt(identity.owner, .{}), std.json.fmt(identity.repository, .{}), identity.number }); defer allocator.free(vars);
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_resolved, .host = identity.host };
    const snapshot = try broker.call(graphql.snapshot_query, vars); defer allocator.free(snapshot);
    const snapshot_head = try snapshotHead(allocator, snapshot); defer allocator.free(snapshot_head);
    var state = try App.init(allocator, snapshot_head); defer state.deinit();
    try loadSnapshotFiles(allocator, snapshot, &state);

    var registry = try sessions.Registry.start(allocator, options.cwd, codex_resolved); defer registry.deinit();
    try registry.createPrimary(options.cwd); state.primary_ready = registry.latest_primary_turn_id != null;
    var server = try http.Server.bind(allocator, io, options.skill_root); defer server.deinit();
    var token_buf: [64]u8 = undefined; const token = server.tokenHex(&token_buf);
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/?token={s}", .{ server.port(), token }); defer allocator.free(url);
    var out = std.Io.File.stdout().writer(io, &.{});
    const repository = try std.fmt.allocPrint(allocator, "{s}/{s}", .{identity.owner, identity.repository}); defer allocator.free(repository);
    if (options.json) try out.interface.print("{{\"schema\":\"synoptic-launch-ready/v1\",\"status\":\"ready\",\"pid\":{d},\"url\":{f},\"repository\":{f},\"pullRequest\":{d},\"worktree\":{f},\"worktreeKind\":\"reused-current\",\"transport\":\"stdio\"}}\n", .{ std.c.getpid(), std.json.fmt(url, .{}), std.json.fmt(repository, .{}), identity.number, std.json.fmt(options.cwd, .{}) })
    else try out.interface.print("{s}\n", .{url});
    try out.interface.flush();
    while (true) server.serveOne(&state) catch |err| switch (err) { error.EndOfStream => continue, else => return err };
}

fn parseLaunch(args: []const []const u8) !config.LaunchOptions {
    var cwd: ?[]const u8 = null; var root: ?[]const u8 = null; var selector: ?[]const u8 = null; var json = false; var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) { json = true; continue; }
        if (i + 1 >= args.len) return error.InvalidArguments;
        if (std.mem.eql(u8, args[i], "--cwd")) cwd = args[i + 1]
        else if (std.mem.eql(u8, args[i], "--skill-root")) root = args[i + 1]
        else if (std.mem.eql(u8, args[i], "--pr")) selector = args[i + 1]
        else return error.InvalidArguments;
        i += 1;
    }
    return .{ .cwd = cwd orelse return error.MissingCwd, .skill_root = root orelse return error.MissingSkillRoot, .pr = selector, .json = json };
}

fn snapshotHead(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{}); defer parsed.deinit();
    return allocator.dupe(u8, (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object.get("headRefOid").?.string);
}
fn loadSnapshotFiles(allocator: std.mem.Allocator, raw: []const u8, app: *App) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{}); defer parsed.deinit();
    const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
    const nodes = (pull.get("files") orelse return error.InvalidSnapshot).object.get("nodes").?.array.items;
    for (nodes) |node| { const o = node.object; const state = o.get("viewerViewedState").?.string; try app.generation.addFile(.{ .path = o.get("path").?.string, .additions = @intCast(o.get("additions").?.integer), .deletions = @intCast(o.get("deletions").?.integer), .viewed = if (std.mem.eql(u8, state, "VIEWED")) .viewed else if (std.mem.eql(u8, state, "DISMISSED")) .dismissed else .unviewed, .revision_key = o.get("path").?.string }); }
}
fn usage() error{InvalidArguments} { return error.InvalidArguments; }

test "launch argv is safe and explicit" {
    const options = try parseLaunch(&.{ "--cwd", "/tmp/w", "--skill-root", "/tmp/s", "--pr", "https://github.com/o/r/pull/1", "--json" });
    try std.testing.expect(options.json);
}
test { _ = domain; }
