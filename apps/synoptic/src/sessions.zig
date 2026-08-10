const std = @import("std");
const cas_runtime = @import("cas_runtime");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    actor: ?cas_runtime.Actor = null,
    primary_thread_id: ?[]u8 = null,
    latest_primary_turn_id: ?[]u8 = null,
    primary_start_turn_id: ?[]u8 = null,
    file_thread_id: ?[]u8 = null,
    file_turn_id: ?[]u8 = null,
    file_path: ?[]u8 = null,
    file_revision: ?[]u8 = null,
    notification_count: u64 = 0,

    pub fn start(allocator: std.mem.Allocator, cwd: []const u8, codex_path: []const u8) !Registry {
        var registry = Registry{ .allocator = allocator };
        registry.actor = try cas_runtime.Client.startActor(allocator, .{
            .cwd = cwd, .codex_path = codex_path, .read_only = true,
            .file_approval = "decline", .client_name = "synoptic", .client_title = "Synoptic", .client_version = "0.1.0",
        }, .{});
        return registry;
    }

    pub fn deinit(self: *Registry) void {
        if (self.actor) |*actor| actor.deinit();
        if (self.primary_thread_id) |v| self.allocator.free(v);
        if (self.latest_primary_turn_id) |v| self.allocator.free(v);
        if (self.primary_start_turn_id) |v| self.allocator.free(v);
        if (self.file_thread_id) |v| self.allocator.free(v);
        if (self.file_turn_id) |v| self.allocator.free(v);
        if (self.file_path) |v| self.allocator.free(v);
        if (self.file_revision) |v| self.allocator.free(v);
    }

    pub fn createPrimary(self: *Registry, cwd: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        const params = try std.fmt.allocPrint(self.allocator, "{{\"cwd\":{f},\"ephemeral\":true}}", .{std.json.fmt(cwd, .{})}); defer self.allocator.free(params);
        const response = try actor.requestJson("thread/start", params, null); defer self.allocator.free(response);
        self.primary_thread_id = try extractString(self.allocator, response, &.{ "result", "thread", "id" });
        const turn_params = try std.fmt.allocPrint(self.allocator,
            "{{\"threadId\":{f},\"input\":[{{\"type\":\"text\",\"text\":\"Build common PR context. Do not take GitHub actions.\"}}]}}",
            .{std.json.fmt(self.primary_thread_id.?, .{})});
        defer self.allocator.free(turn_params);
        const turn = try actor.requestJson("turn/start", turn_params, null); defer self.allocator.free(turn);
        self.primary_start_turn_id = try extractString(self.allocator, turn, &.{ "result", "turn", "id" });
        try actor.subscribe(.{ .context = self, .handle = onNotification });
        try actor.setServerRequestHandler(.{ .context = self, .handle = onServerRequest });
    }

    pub fn primaryReady(self: *const Registry) bool { return self.latest_primary_turn_id != null; }

    pub fn openFile(self: *Registry, cwd: []const u8, path: []const u8, revision: []const u8, base_oid: []const u8, head_oid: []const u8, diff: []const u8, threads_json: []const u8, skill_path: []const u8) !bool {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        if (self.file_path) |old_path| if (self.file_revision) |old_revision| if (std.mem.eql(u8, old_path, path) and std.mem.eql(u8, old_revision, revision)) return true;
        if (self.file_thread_id) |old_thread| {
            const inject = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"items\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(old_thread, .{}), std.json.fmt(diff, .{}) }); defer self.allocator.free(inject);
            const injected = try actor.requestJson("thread/inject_items", inject, null); defer self.allocator.free(injected);
        }
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"lastTurnId\":{f},\"ephemeral\":true}}", .{ std.json.fmt(self.primary_thread_id orelse return error.PrimaryNotReady, .{}), std.json.fmt(self.latest_primary_turn_id orelse return error.PrimaryNotReady, .{}) }); defer self.allocator.free(params);
        const response = try actor.requestJson("thread/fork", params, null); defer self.allocator.free(response);
        if (self.file_thread_id) |old| self.allocator.free(old);
        self.file_thread_id = try extractString(self.allocator, response, &.{ "result", "thread", "id" });
        if (self.file_path) |old| self.allocator.free(old); self.file_path = try self.allocator.dupe(u8, path);
        if (self.file_revision) |old| self.allocator.free(old); self.file_revision = try self.allocator.dupe(u8, revision);
        const prompt = try std.fmt.allocPrint(self.allocator,
            "Review {s} against base {s} at head {s}. Diff:\n{s}\nUnresolved file threads: {s}\nPerform the review now; report findings, risk, proposed inline comments, and suspicions. Do not invoke GitHub tools, mark viewed, edit source, or act during this initial turn. Wait for the human.",
            .{ path, base_oid, head_oid, diff, threads_json }); defer self.allocator.free(prompt);
        const turn_params = try std.fmt.allocPrint(self.allocator,
            "{{\"threadId\":{f},\"cwd\":{f},\"input\":[{{\"type\":\"skill\",\"path\":{f}}},{{\"type\":\"text\",\"text\":{f}}}]}}",
            .{ std.json.fmt(self.file_thread_id.?, .{}), std.json.fmt(cwd, .{}), std.json.fmt(skill_path, .{}), std.json.fmt(prompt, .{}) }); defer self.allocator.free(turn_params);
        const turn = try actor.requestJson("turn/start", turn_params, null); defer self.allocator.free(turn);
        if (self.file_turn_id) |old| self.allocator.free(old);
        self.file_turn_id = try extractString(self.allocator, turn, &.{ "result", "turn", "id" });
        return false;
    }

    pub fn message(self: *Registry, text: []const u8, active: bool) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        const method = if (active) "turn/steer" else "turn/start";
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"expectedTurnId\":{f},\"input\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(self.file_thread_id orelse return error.NoFileSession, .{}), std.json.fmt(self.file_turn_id orelse "", .{}), std.json.fmt(text, .{}) }); defer self.allocator.free(params);
        const response = try actor.requestJson(method, params, null); defer self.allocator.free(response);
    }

    pub fn interrupt(self: *Registry) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"turnId\":{f}}}", .{ std.json.fmt(self.file_thread_id orelse return error.NoFileSession, .{}), std.json.fmt(self.file_turn_id orelse return error.NoActiveTurn, .{}) }); defer self.allocator.free(params);
        const response = try actor.requestJson("turn/interrupt", params, null); defer self.allocator.free(response);
    }

    fn onNotification(context: *anyopaque, notification: cas_runtime.Notification) void {
        const self: *Registry = @ptrCast(@alignCast(context)); self.notification_count += 1;
        if (!std.mem.eql(u8, notification.method, "turn/completed")) return;
        const turn_id = extractString(self.allocator, notification.raw_json, &.{ "params", "turn", "id" }) catch return;
        const thread_id = extractString(self.allocator, notification.raw_json, &.{ "params", "threadId" }) catch { self.allocator.free(turn_id); return; };
        defer self.allocator.free(thread_id);
        if (self.primary_thread_id) |primary| if (std.mem.eql(u8, primary, thread_id)) {
            if (self.latest_primary_turn_id) |old| self.allocator.free(old);
            self.latest_primary_turn_id = turn_id; return;
        };
        self.allocator.free(turn_id);
    }

    fn onServerRequest(_: *anyopaque, request: cas_runtime.ServerRequest, allocator: std.mem.Allocator) ![]u8 {
        if (std.mem.eql(u8, request.method, "item/fileChange/requestApproval")) return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        if (std.mem.eql(u8, request.method, "item/tool/call") and std.mem.indexOf(u8, request.raw_json, "prepare_github_action") != null) return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"initial review actions are forbidden\"}],\"success\":false}");
        return allocator.dupe(u8, "{\"decision\":\"decline\"}");
    }

    fn extractString(allocator: std.mem.Allocator, raw: []const u8, path: []const []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{}); defer parsed.deinit();
        var value = parsed.value;
        for (path) |name| value = switch (value) { .object => |o| o.get(name) orelse return error.MissingAppServerField, else => return error.MissingAppServerField };
        return switch (value) { .string => |s| allocator.dupe(u8, s), else => error.MissingAppServerField };
    }
};

test "file selection remains gated without completed primary" {
    const registry = Registry{ .allocator = std.testing.allocator };
    try std.testing.expect(registry.latest_primary_turn_id == null);
}

test "turn start response alone never opens primary gate" {
    var registry = Registry{ .allocator = std.testing.allocator, .primary_start_turn_id = try std.testing.allocator.dupe(u8, "started") }; defer registry.deinit();
    try std.testing.expect(!registry.primaryReady());
}
