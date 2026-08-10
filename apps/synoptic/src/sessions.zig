const std = @import("std");
const cas_runtime = @import("cas_runtime");

pub const max_visible_events: usize = 1024;
pub const SessionStatus = enum { current, stale_origin, completed, closed };
pub const Session = struct {
    id: []u8,
    thread_id: []u8,
    turn_id: []u8,
    path: []u8,
    revision: []u8,
    status: SessionStatus = .current,
    initial_turn_active: bool = true,
    human_action_authorized: bool = false,
    fn deinit(self: Session, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.thread_id);
        allocator.free(self.turn_id);
        allocator.free(self.path);
        allocator.free(self.revision);
    }
};
pub const OpenResult = struct {
    reused: bool,
    session_id: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: OpenResult) void {
        self.allocator.free(self.session_id);
    }
};
pub const SessionIdentity = struct {
    path: []u8,
    revision: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: SessionIdentity) void {
        self.allocator.free(self.path);
        self.allocator.free(self.revision);
    }
};
pub const VisibleEvent = struct {
    session_id: ?[]u8,
    method: []u8,
    raw_json: []u8,
    pub fn deinit(self: VisibleEvent, allocator: std.mem.Allocator) void {
        if (self.session_id) |v| allocator.free(v);
        allocator.free(self.method);
        allocator.free(self.raw_json);
    }
};
const RegistryMutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *RegistryMutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *RegistryMutex) void {
        self.state.unlock();
    }
};

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
    mutex: RegistryMutex = .{},
    sessions: std.ArrayList(Session) = .empty,
    visible_events: std.ArrayList(VisibleEvent) = .empty,
    next_session_id: u64 = 1,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, codex_path: []const u8) !Registry {
        var registry = Registry{ .allocator = allocator };
        registry.actor = try cas_runtime.Client.startActor(allocator, .{
            .cwd = cwd,
            .io = io,
            .codex_path = codex_path,
            .read_only = true,
            .file_approval = "decline",
            .client_name = "synoptic",
            .client_title = "Synoptic",
            .client_version = "0.1.0",
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
        for (self.sessions.items) |session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.visible_events.items) |event| event.deinit(self.allocator);
        self.visible_events.deinit(self.allocator);
    }

    pub fn createPrimary(self: *Registry, cwd: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        try actor.subscribe(.{ .context = self, .handle = onNotification });
        try actor.setServerRequestHandler(.{ .context = self, .handle = onServerRequest });
        const params = try std.fmt.allocPrint(self.allocator, "{{\"cwd\":{f},\"ephemeral\":true}}", .{std.json.fmt(cwd, .{})});
        defer self.allocator.free(params);
        const response = try actor.requestJson("thread/start", params, null);
        defer self.allocator.free(response);
        self.primary_thread_id = try extractString(self.allocator, response, &.{ "thread", "id" });
        const turn_params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"input\":[{{\"type\":\"text\",\"text\":\"Build common PR context. Do not take GitHub actions.\"}}]}}", .{std.json.fmt(self.primary_thread_id.?, .{})});
        defer self.allocator.free(turn_params);
        const turn = try actor.requestJson("turn/start", turn_params, null);
        defer self.allocator.free(turn);
        self.primary_start_turn_id = try extractString(self.allocator, turn, &.{ "turn", "id" });
    }

    pub fn primaryReady(self: *Registry) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.latest_primary_turn_id != null;
    }

    pub fn sessionCount(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.items.len;
    }
    pub fn markHumanInstruction(self: *Registry, session_id: []const u8, text: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*session| if (std.mem.eql(u8, session.id, session_id)) {
            session.human_action_authorized = explicitActionInstruction(text);
            return;
        };
        return error.UnknownSession;
    }
    pub fn closeSession(self: *Registry, session_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*session| if (std.mem.eql(u8, session.id, session_id)) {
            session.status = .closed;
            return;
        };
        return error.UnknownSession;
    }
    pub fn sessionIdentity(self: *Registry, session_id: []const u8) !SessionIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id)) return .{ .path = try self.allocator.dupe(u8, session.path), .revision = try self.allocator.dupe(u8, session.revision), .allocator = self.allocator };
        return error.UnknownSession;
    }
    pub fn markCompleted(self: *Registry, session_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*session| if (std.mem.eql(u8, session.id, session_id)) {
            if (session.status != .current) return error.NotOfficialCurrentSession;
            session.status = .completed;
            return;
        };
        return error.UnknownSession;
    }

    pub fn drainVisible(self: *Registry, allocator: std.mem.Allocator) !std.ArrayList(VisibleEvent) {
        self.mutex.lock();
        defer self.mutex.unlock();
        var result: std.ArrayList(VisibleEvent) = .empty;
        for (self.visible_events.items) |event| try result.append(allocator, .{ .session_id = if (event.session_id) |v| try allocator.dupe(u8, v) else null, .method = try allocator.dupe(u8, event.method), .raw_json = try allocator.dupe(u8, event.raw_json) });
        for (self.visible_events.items) |event| event.deinit(self.allocator);
        self.visible_events.clearRetainingCapacity();
        return result;
    }

    pub fn openFile(self: *Registry, cwd: []const u8, path: []const u8, revision: []const u8, base_oid: []const u8, head_oid: []const u8, diff: []const u8, threads_json: []const u8, skill_path: []const u8) !OpenResult {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        self.mutex.lock();
        for (self.sessions.items) |session| if (session.status == .current and std.mem.eql(u8, session.path, path) and std.mem.eql(u8, session.revision, revision)) {
            const id = try self.allocator.dupe(u8, session.id);
            self.mutex.unlock();
            return .{ .reused = true, .session_id = id, .allocator = self.allocator };
        };
        for (self.sessions.items) |*session| {
            if (session.status == .current and std.mem.eql(u8, session.path, path)) session.status = .stale_origin;
        }
        self.mutex.unlock();
        if (self.file_thread_id) |old_thread| {
            const inject = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"items\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(old_thread, .{}), std.json.fmt(diff, .{}) });
            defer self.allocator.free(inject);
            const injected = try actor.requestJson("thread/inject_items", inject, null);
            defer self.allocator.free(injected);
        }
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"lastTurnId\":{f},\"ephemeral\":true}}", .{ std.json.fmt(self.primary_thread_id orelse return error.PrimaryNotReady, .{}), std.json.fmt(self.latest_primary_turn_id orelse return error.PrimaryNotReady, .{}) });
        defer self.allocator.free(params);
        const response = try actor.requestJson("thread/fork", params, null);
        defer self.allocator.free(response);
        if (self.file_thread_id) |old| self.allocator.free(old);
        self.file_thread_id = try extractString(self.allocator, response, &.{ "thread", "id" });
        if (self.file_path) |old| self.allocator.free(old);
        self.file_path = try self.allocator.dupe(u8, path);
        if (self.file_revision) |old| self.allocator.free(old);
        self.file_revision = try self.allocator.dupe(u8, revision);
        const prompt = try std.fmt.allocPrint(self.allocator, "Review {s} against base {s} at head {s}. Diff:\n{s}\nUnresolved file threads: {s}\nPerform the review now; report findings, risk, proposed inline comments, and suspicions. Do not invoke GitHub tools, mark viewed, edit source, or act during this initial turn. Wait for the human.", .{ path, base_oid, head_oid, diff, threads_json });
        defer self.allocator.free(prompt);
        const turn_params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"cwd\":{f},\"input\":[{{\"type\":\"skill\",\"path\":{f}}},{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(self.file_thread_id.?, .{}), std.json.fmt(cwd, .{}), std.json.fmt(skill_path, .{}), std.json.fmt(prompt, .{}) });
        defer self.allocator.free(turn_params);
        const turn = try actor.requestJson("turn/start", turn_params, null);
        defer self.allocator.free(turn);
        if (self.file_turn_id) |old| self.allocator.free(old);
        self.file_turn_id = try extractString(self.allocator, turn, &.{ "turn", "id" });
        self.mutex.lock();
        defer self.mutex.unlock();
        const session_id = try std.fmt.allocPrint(self.allocator, "ses-{d}", .{self.next_session_id});
        self.next_session_id += 1;
        try self.sessions.append(self.allocator, .{ .id = session_id, .thread_id = try self.allocator.dupe(u8, self.file_thread_id.?), .turn_id = try self.allocator.dupe(u8, self.file_turn_id.?), .path = try self.allocator.dupe(u8, path), .revision = try self.allocator.dupe(u8, revision) });
        return .{ .reused = false, .session_id = try self.allocator.dupe(u8, session_id), .allocator = self.allocator };
    }

    pub fn message(self: *Registry, session_id: []const u8, text: []const u8, active: bool) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        self.mutex.lock();
        var thread_id: ?[]u8 = null;
        var turn_id: ?[]u8 = null;
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id) and session.status != .closed) {
            thread_id = try self.allocator.dupe(u8, session.thread_id);
            turn_id = try self.allocator.dupe(u8, session.turn_id);
            break;
        };
        self.mutex.unlock();
        defer if (thread_id) |v| self.allocator.free(v);
        defer if (turn_id) |v| self.allocator.free(v);
        const method = if (active) "turn/steer" else "turn/start";
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"expectedTurnId\":{f},\"input\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(thread_id orelse return error.UnknownSession, .{}), std.json.fmt(turn_id orelse "", .{}), std.json.fmt(text, .{}) });
        defer self.allocator.free(params);
        const response = try actor.requestJson(method, params, null);
        defer self.allocator.free(response);
        if (!active) {
            const next_turn = try extractString(self.allocator, response, &.{ "turn", "id" });
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.sessions.items) |*session| {
                if (std.mem.eql(u8, session.id, session_id)) {
                    self.allocator.free(session.turn_id);
                    session.turn_id = next_turn;
                    return;
                }
            }
            self.allocator.free(next_turn);
            return error.UnknownSession;
        }
    }

    pub fn interrupt(self: *Registry, session_id: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        self.mutex.lock();
        var thread_id: ?[]u8 = null;
        var turn_id: ?[]u8 = null;
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id) and session.status != .closed) {
            thread_id = try self.allocator.dupe(u8, session.thread_id);
            turn_id = try self.allocator.dupe(u8, session.turn_id);
            break;
        };
        self.mutex.unlock();
        defer if (thread_id) |v| self.allocator.free(v);
        defer if (turn_id) |v| self.allocator.free(v);
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"turnId\":{f}}}", .{ std.json.fmt(thread_id orelse return error.UnknownSession, .{}), std.json.fmt(turn_id orelse return error.NoActiveTurn, .{}) });
        defer self.allocator.free(params);
        const response = try actor.requestJson("turn/interrupt", params, null);
        defer self.allocator.free(response);
    }

    pub fn markPathChangedAndInject(self: *Registry, path: []const u8, revision: []const u8, diff: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        var threads: std.ArrayList([]u8) = .empty;
        defer {
            for (threads.items) |thread| self.allocator.free(thread);
            threads.deinit(self.allocator);
        }
        self.mutex.lock();
        for (self.sessions.items) |*session| {
            if ((session.status == .current or session.status == .completed) and std.mem.eql(u8, session.path, path) and !std.mem.eql(u8, session.revision, revision)) {
                session.status = .stale_origin;
                threads.append(self.allocator, self.allocator.dupe(u8, session.thread_id) catch {
                    self.mutex.unlock();
                    return error.OutOfMemory;
                }) catch {
                    self.mutex.unlock();
                    return error.OutOfMemory;
                };
            }
        }
        self.mutex.unlock();
        for (threads.items) |thread| {
            const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"items\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(thread, .{}), std.json.fmt(diff, .{}) });
            defer self.allocator.free(params);
            const response = try actor.requestJson("thread/inject_items", params, null);
            defer self.allocator.free(response);
        }
    }

    pub fn updatePrimary(self: *Registry, summary: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"input\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(self.primary_thread_id orelse return error.PrimaryNotReady, .{}), std.json.fmt(summary, .{}) });
        defer self.allocator.free(params);
        const response = try actor.requestJson("turn/start", params, null);
        defer self.allocator.free(response);
    }

    fn onNotification(context: *anyopaque, notification: cas_runtime.Notification) void {
        const self: *Registry = @ptrCast(@alignCast(context));
        self.mutex.lock();
        self.notification_count += 1;
        if (visibleMethod(notification.method) and self.visible_events.items.len < max_visible_events) {
            const session_id = self.sessionForNotificationLocked(notification.raw_json) catch null;
            self.visible_events.append(self.allocator, .{ .session_id = session_id, .method = self.allocator.dupe(u8, notification.method) catch {
                self.mutex.unlock();
                return;
            }, .raw_json = self.allocator.dupe(u8, notification.raw_json) catch {
                self.mutex.unlock();
                return;
            } }) catch {
                self.mutex.unlock();
                return;
            };
        }
        if (std.mem.eql(u8, notification.method, "turn/completed")) {
            if (extractString(self.allocator, notification.raw_json, &.{ "params", "threadId" })) |thread| {
                defer self.allocator.free(thread);
                for (self.sessions.items) |*session| {
                    if (std.mem.eql(u8, session.thread_id, thread)) session.initial_turn_active = false;
                }
            } else |_| {}
        }
        self.mutex.unlock();
        if (!std.mem.eql(u8, notification.method, "turn/completed")) return;
        const turn_id = extractString(self.allocator, notification.raw_json, &.{ "params", "turn", "id" }) catch return;
        const thread_id = extractString(self.allocator, notification.raw_json, &.{ "params", "threadId" }) catch {
            self.allocator.free(turn_id);
            return;
        };
        defer self.allocator.free(thread_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.primary_thread_id) |primary| if (std.mem.eql(u8, primary, thread_id)) {
            if (self.latest_primary_turn_id) |old| self.allocator.free(old);
            self.latest_primary_turn_id = turn_id;
            return;
        };
        self.allocator.free(turn_id);
    }

    fn sessionForNotificationLocked(self: *Registry, raw: []const u8) !?[]u8 {
        const thread = extractString(self.allocator, raw, &.{ "params", "threadId" }) catch return null;
        defer self.allocator.free(thread);
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.thread_id, thread)) return @as(?[]u8, try self.allocator.dupe(u8, session.id));
        return null;
    }

    fn onServerRequest(context: *anyopaque, request: cas_runtime.ServerRequest, allocator: std.mem.Allocator) ![]u8 {
        const self: *Registry = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, request.method, "item/fileChange/requestApproval")) return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        if (std.mem.eql(u8, request.method, "item/tool/call")) {
            const kind: ?[]const u8 = if (std.mem.indexOf(u8, request.raw_json, "prepare_github_action") != null) "action.prepared" else if (std.mem.indexOf(u8, request.raw_json, "complete_file_review") != null) "file.complete.requested" else if (std.mem.indexOf(u8, request.raw_json, "close_session") != null) "session.close.requested" else null;
            if (kind) |event_kind| {
                const origin_thread = extractString(self.allocator, request.raw_json, &.{ "params", "threadId" }) catch return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"missing originating thread\"}],\"success\":false}");
                defer self.allocator.free(origin_thread);
                self.mutex.lock();
                defer self.mutex.unlock();
                for (self.sessions.items) |*session| if (std.mem.eql(u8, session.thread_id, origin_thread) and session.status == .current and !session.initial_turn_active and session.human_action_authorized) {
                    session.human_action_authorized = false;
                    if (self.visible_events.items.len < max_visible_events) try self.visible_events.append(self.allocator, .{ .session_id = try self.allocator.dupe(u8, session.id), .method = try self.allocator.dupe(u8, event_kind), .raw_json = try self.allocator.dupe(u8, request.raw_json) });
                    return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"accepted for Synoptic domain handling\"}],\"success\":true}");
                };
                return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"initial review or missing explicit human authority\"}],\"success\":false}");
            }
        }
        return allocator.dupe(u8, "{\"decision\":\"decline\"}");
    }

    fn extractString(allocator: std.mem.Allocator, raw: []const u8, path: []const []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        var value = parsed.value;
        for (path) |name| value = switch (value) {
            .object => |o| o.get(name) orelse return error.MissingAppServerField,
            else => return error.MissingAppServerField,
        };
        return switch (value) {
            .string => |s| allocator.dupe(u8, s),
            else => error.MissingAppServerField,
        };
    }
};

fn visibleMethod(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "turn/") or std.mem.startsWith(u8, method, "item/") or std.mem.indexOf(u8, method, "delta") != null;
}
fn explicitActionInstruction(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "comment") != null or std.mem.indexOf(u8, text, "complete") != null or std.mem.indexOf(u8, text, "close") != null or std.mem.indexOf(u8, text, "mark") != null;
}

test "file selection remains gated without completed primary" {
    const registry = Registry{ .allocator = std.testing.allocator };
    try std.testing.expect(registry.latest_primary_turn_id == null);
}

test "turn start response alone never opens primary gate" {
    var registry = Registry{ .allocator = std.testing.allocator, .primary_start_turn_id = try std.testing.allocator.dupe(u8, "started") };
    defer registry.deinit();
    try std.testing.expect(!registry.primaryReady());
}
test "session authority is immediately governing and close is local" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try registry.sessions.append(std.testing.allocator, .{ .id = try std.testing.allocator.dupe(u8, "s"), .thread_id = try std.testing.allocator.dupe(u8, "t"), .turn_id = try std.testing.allocator.dupe(u8, "u"), .path = try std.testing.allocator.dupe(u8, "a"), .revision = try std.testing.allocator.dupe(u8, "r") });
    try registry.markHumanInstruction("s", "please prepare the comment");
    try std.testing.expect(registry.sessions.items[0].human_action_authorized);
    try registry.closeSession("s");
    try std.testing.expectEqual(SessionStatus.closed, registry.sessions.items[0].status);
}
