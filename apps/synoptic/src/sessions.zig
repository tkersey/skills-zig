const std = @import("std");
const cas_runtime = @import("cas_runtime");
const action_tools = @import("tools.zig");
const domain = @import("domain.zig");

pub const max_visible_events: usize = 1024;
pub const dynamic_tools_json =
    "[{\"type\":\"namespace\",\"name\":\"synoptic\",\"description\":\"Human-directed Synoptic review operations\",\"tools\":[" ++
    "{\"name\":\"search_unresolved_threads\",\"description\":\"Search server-owned unresolved current-PR review evidence; use whole-PR only for cross-file concerns\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"includeWholePullRequest\":{\"type\":\"boolean\"}}}}," ++
    "{\"name\":\"prepare_github_action\",\"description\":\"Only after explicit human instruction, prepare an immutable confirmable GitHub action; forbidden during initial review\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"slot\",\"kind\",\"effectSummary\",\"payload\"],\"properties\":{\"slot\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\",\"enum\":[\"add_inline_comment\",\"reply_thread\",\"resolve_thread\",\"unresolve_thread\",\"update_comment\",\"delete_comment\",\"mark_viewed\",\"unmark_viewed\",\"graphql\"]},\"effectSummary\":{\"type\":\"string\"},\"payload\":{\"type\":\"object\"}}}}," ++
    "{\"name\":\"complete_file_review\",\"description\":\"Complete the official current file only after explicit human instruction\",\"inputSchema\":{\"type\":\"object\"}}," ++
    "{\"name\":\"close_session\",\"description\":\"Close this local session only after explicit human instruction\",\"inputSchema\":{\"type\":\"object\"}}]}]";
pub const SessionStatus = enum { current, stale_origin, completed, closed };
pub const HumanAuthority = enum { github_any, add_inline_comment, reply_thread, resolve_thread, unresolve_thread, update_comment, delete_comment, mark_viewed, unmark_viewed, graphql, complete, close };
pub const Session = struct {
    id: []u8,
    thread_id: []u8,
    turn_id: []u8,
    path: []u8,
    revision: []u8,
    status: SessionStatus = .current,
    initial_turn_active: bool = true,
    human_authority: ?HumanAuthority = null,
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
    turn_id: []u8,
    status: SessionStatus,
    allocator: std.mem.Allocator,
    pub fn deinit(self: SessionIdentity) void {
        self.allocator.free(self.path);
        self.allocator.free(self.revision);
        self.allocator.free(self.turn_id);
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
    evidence: ?domain.PrGeneration = null,
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
        if (self.evidence) |*value| value.deinit();
        for (self.sessions.items) |session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.visible_events.items) |event| event.deinit(self.allocator);
        self.visible_events.deinit(self.allocator);
    }

    pub fn setGenerationEvidence(self: *Registry, generation: *const domain.PrGeneration) !void {
        const next = try generation.clone(self.allocator);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.evidence) |*old| old.deinit();
        self.evidence = next;
    }

    pub fn createPrimary(self: *Registry, io: std.Io, cwd: []const u8, skill_path: []const u8, pr_json: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        try actor.subscribe(.{ .context = self, .handle = onNotification });
        try actor.setServerRequestHandler(.{ .context = self, .handle = onServerRequest });
        const params = try std.fmt.allocPrint(self.allocator, "{{\"cwd\":{f},\"ephemeral\":true,\"dynamicTools\":{s}}}", .{ std.json.fmt(cwd, .{}), dynamic_tools_json });
        defer self.allocator.free(params);
        const response = try actor.requestJson("thread/start", params, null);
        defer self.allocator.free(response);
        self.primary_thread_id = try extractString(self.allocator, response, &.{ "thread", "id" });
        const primary_role = try readReference(self.allocator, io, skill_path, "primary-context.md");
        defer self.allocator.free(primary_role);
        const untrusted = try readReference(self.allocator, io, skill_path, "untrusted-repository-content.md");
        defer self.allocator.free(untrusted);
        const prompt = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}\n\nAuthoritative current pull request:\n{s}\nThis primary context is hidden infrastructure. Do not invoke Synoptic tools or produce publication-ready per-file review actions.", .{ primary_role, untrusted, pr_json });
        defer self.allocator.free(prompt);
        const turn_params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"input\":[{{\"type\":\"skill\",\"name\":\"synoptic\",\"path\":{f}}},{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(self.primary_thread_id.?, .{}), std.json.fmt(skill_path, .{}), std.json.fmt(prompt, .{}) });
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
            session.human_authority = classifyHumanInstruction(text);
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
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id)) return .{ .path = try self.allocator.dupe(u8, session.path), .revision = try self.allocator.dupe(u8, session.revision), .turn_id = try self.allocator.dupe(u8, session.turn_id), .status = session.status, .allocator = self.allocator };
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

    pub fn openFile(self: *Registry, io: std.Io, cwd: []const u8, path: []const u8, revision: []const u8, base_oid: []const u8, head_oid: []const u8, diff: []const u8, threads_json: []const u8, skill_path: []const u8) !OpenResult {
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
        const primary_thread = self.allocator.dupe(u8, self.primary_thread_id orelse {
            self.mutex.unlock();
            return error.PrimaryNotReady;
        }) catch |err| {
            self.mutex.unlock();
            return err;
        };
        const primary_turn = self.allocator.dupe(u8, self.latest_primary_turn_id orelse {
            self.allocator.free(primary_thread);
            self.mutex.unlock();
            return error.PrimaryNotReady;
        }) catch |err| {
            self.allocator.free(primary_thread);
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        defer self.allocator.free(primary_thread);
        defer self.allocator.free(primary_turn);
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"lastTurnId\":{f},\"ephemeral\":true}}", .{ std.json.fmt(primary_thread, .{}), std.json.fmt(primary_turn, .{}) });
        defer self.allocator.free(params);
        const response = try actor.requestJson("thread/fork", params, null);
        defer self.allocator.free(response);
        const file_thread_id = try extractString(self.allocator, response, &.{ "thread", "id" });
        defer self.allocator.free(file_thread_id);
        const file_role = try readReference(self.allocator, io, skill_path, "file-review.md");
        defer self.allocator.free(file_role);
        const actions = try readReference(self.allocator, io, skill_path, "github-actions.md");
        defer self.allocator.free(actions);
        const untrusted = try readReference(self.allocator, io, skill_path, "untrusted-repository-content.md");
        defer self.allocator.free(untrusted);
        const prompt = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}\n\n{s}\n\nAssigned path: {s}\nRevision: {s}\nBase: {s}\nHead: {s}\nServer-computed canonical diff:\n{s}\nComplete unresolved assigned-file thread evidence:\n{s}\nPerform the review now; report findings, risk, proposed inline comments, and suspicions. Do not invoke a GitHub action tool during this initial review. Do not mark viewed or edit source. Wait for the human.", .{ file_role, actions, untrusted, path, revision, base_oid, head_oid, diff, threads_json });
        defer self.allocator.free(prompt);
        const turn_params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"cwd\":{f},\"input\":[{{\"type\":\"skill\",\"name\":\"synoptic\",\"path\":{f}}},{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(file_thread_id, .{}), std.json.fmt(cwd, .{}), std.json.fmt(skill_path, .{}), std.json.fmt(prompt, .{}) });
        defer self.allocator.free(turn_params);
        const turn = try actor.requestJson("turn/start", turn_params, null);
        defer self.allocator.free(turn);
        const file_turn_id = try extractString(self.allocator, turn, &.{ "turn", "id" });
        defer self.allocator.free(file_turn_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        const session_id = try std.fmt.allocPrint(self.allocator, "ses-{d}", .{self.next_session_id});
        self.next_session_id += 1;
        try self.sessions.append(self.allocator, .{ .id = session_id, .thread_id = try self.allocator.dupe(u8, file_thread_id), .turn_id = try self.allocator.dupe(u8, file_turn_id), .path = try self.allocator.dupe(u8, path), .revision = try self.allocator.dupe(u8, revision) });
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
            if (session_id == null) {
                self.mutex.unlock();
                if (std.mem.eql(u8, notification.method, "turn/completed")) self.recordPrimaryCompletion(notification.raw_json);
                return;
            }
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
        self.recordPrimaryCompletion(notification.raw_json);
    }

    fn recordPrimaryCompletion(self: *Registry, raw_json: []const u8) void {
        const turn_id = extractString(self.allocator, raw_json, &.{ "params", "turn", "id" }) catch return;
        const thread_id = extractString(self.allocator, raw_json, &.{ "params", "threadId" }) catch {
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
            if (std.mem.indexOf(u8, request.raw_json, "search_unresolved_threads") != null) return self.searchThreads(request.raw_json, allocator);
            const kind: ?[]const u8 = if (std.mem.indexOf(u8, request.raw_json, "prepare_github_action") != null) "action.prepared" else if (std.mem.indexOf(u8, request.raw_json, "complete_file_review") != null) "file.complete.requested" else if (std.mem.indexOf(u8, request.raw_json, "close_session") != null) "session.close.requested" else null;
            if (kind) |event_kind| {
                const origin_thread = extractString(self.allocator, request.raw_json, &.{ "params", "threadId" }) catch return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"missing originating thread\"}],\"success\":false}");
                defer self.allocator.free(origin_thread);
                self.mutex.lock();
                defer self.mutex.unlock();
                const requested = requestedAuthority(self.allocator, event_kind, request.raw_json) orelse return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"unsupported action kind\"}],\"success\":false}");
                for (self.sessions.items) |*session| if (std.mem.eql(u8, session.thread_id, origin_thread) and session.status != .closed and !session.initial_turn_active and authorityCovers(session.human_authority, requested)) {
                    if (std.mem.eql(u8, event_kind, "file.complete.requested") and session.status != .current) return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"only the official current-revision session can complete the file\"}],\"success\":false}");
                    session.human_authority = null;
                    if (self.visible_events.items.len < max_visible_events) try self.visible_events.append(self.allocator, .{ .session_id = try self.allocator.dupe(u8, session.id), .method = try self.allocator.dupe(u8, event_kind), .raw_json = try self.allocator.dupe(u8, request.raw_json) });
                    return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"accepted for Synoptic domain handling\"}],\"success\":true}");
                };
                return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"initial review or missing explicit human authority\"}],\"success\":false}");
            }
        }
        return allocator.dupe(u8, "{\"decision\":\"decline\"}");
    }

    fn searchThreads(self: *Registry, raw: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params") orelse return error.MalformedToolCall;
        const thread_id = params.object.get("threadId") orelse return error.MalformedToolCall;
        var assigned: ?[]const u8 = null;
        self.mutex.lock();
        defer self.mutex.unlock();
        const generation = if (self.evidence) |*value| value else return allocator.dupe(u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"current PR evidence unavailable\"}],\"success\":false}");
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.thread_id, thread_id.string)) {
            assigned = session.path;
            break;
        };
        const assigned_path = assigned orelse return error.UnknownSession;
        const args = params.object.get("arguments") orelse return error.MalformedToolCall;
        const query: ?[]const u8 = if (args == .object and args.object.get("query") != null and args.object.get("query").? == .string) args.object.get("query").?.string else null;
        const whole = args == .object and args.object.get("includeWholePullRequest") != null and args.object.get("includeWholePullRequest").? == .bool and args.object.get("includeWholePullRequest").?.bool;
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);
        if (args == .object) if (args.object.get("paths")) |value| if (value == .array) for (value.array.items) |path| if (path == .string) try paths.append(allocator, path.string);
        const evidence = try generation.unresolvedThreadsJsonAlloc(allocator, assigned_path, query, paths.items, whole);
        defer allocator.free(evidence);
        return std.fmt.allocPrint(allocator, "{{\"contentItems\":[{{\"type\":\"inputText\",\"text\":{f}}}],\"success\":true}}", .{std.json.fmt(evidence, .{})});
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

fn readReference(allocator: std.mem.Allocator, io: std.Io, skill_path: []const u8, name: []const u8) ![]u8 {
    const root = std.fs.path.dirname(skill_path) orelse return error.InvalidSkillPath;
    const path = try std.fs.path.join(allocator, &.{ root, "references", name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

fn visibleMethod(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "turn/") or std.mem.startsWith(u8, method, "item/") or std.mem.indexOf(u8, method, "delta") != null;
}
fn classifyHumanInstruction(text: []const u8) ?HumanAuthority {
    if (containsIgnoreCase(text, "do not") or containsIgnoreCase(text, "don't") or containsIgnoreCase(text, "without taking") or containsIgnoreCase(text, "not prepare")) return null;
    const informational = containsIgnoreCase(text, "how do") or containsIgnoreCase(text, "how can") or containsIgnoreCase(text, "how would") or containsIgnoreCase(text, "tell me how") or containsIgnoreCase(text, "explain how") or containsIgnoreCase(text, "what ") or containsIgnoreCase(text, "which ") or containsIgnoreCase(text, "why ") or containsIgnoreCase(text, "when ") or containsIgnoreCase(text, "where ");
    if (informational) return null;
    if (containsIgnoreCase(text, "complete this file") or containsIgnoreCase(text, "complete the file review") or containsIgnoreCase(text, "mark this file reviewed") or containsIgnoreCase(text, "mark the file reviewed")) return .complete;
    if (containsIgnoreCase(text, "close this session") or containsIgnoreCase(text, "close the session") or containsIgnoreCase(text, "close session") or containsIgnoreCase(text, "close this tab") or containsIgnoreCase(text, "close the tab")) return .close;
    if (containsIgnoreCase(text, "take the action") or containsIgnoreCase(text, "prepare the action")) return .github_any;
    const action_verb = containsIgnoreCase(text, "add") or containsIgnoreCase(text, "remove") or containsIgnoreCase(text, "set") or containsIgnoreCase(text, "request") or containsIgnoreCase(text, "submit") or containsIgnoreCase(text, "dismiss") or containsIgnoreCase(text, "change") or containsIgnoreCase(text, "execute") or containsIgnoreCase(text, "update") or containsIgnoreCase(text, "close") or containsIgnoreCase(text, "reopen") or containsIgnoreCase(text, "merge") or containsIgnoreCase(text, "resolve") or containsIgnoreCase(text, "reply") or containsIgnoreCase(text, "delete") or containsIgnoreCase(text, "unmark") or containsIgnoreCase(text, "mark") or containsIgnoreCase(text, "post") or containsIgnoreCase(text, "publish") or containsIgnoreCase(text, "prepare");
    const github_target = containsIgnoreCase(text, "label") or containsIgnoreCase(text, "reviewer") or containsIgnoreCase(text, "assignee") or containsIgnoreCase(text, "milestone") or containsIgnoreCase(text, "pull request") or containsIgnoreCase(text, "this pr") or containsIgnoreCase(text, "the pr") or containsIgnoreCase(text, " pr #") or containsIgnoreCase(text, "comment") or containsIgnoreCase(text, "thread") or containsIgnoreCase(text, "github review") or containsIgnoreCase(text, "mark viewed") or containsIgnoreCase(text, "graphql");
    if (action_verb and github_target) return .github_any;
    return null;
}
fn requestedAuthority(allocator: std.mem.Allocator, event_kind: []const u8, raw: []const u8) ?HumanAuthority {
    if (std.mem.eql(u8, event_kind, "file.complete.requested")) return .complete;
    if (std.mem.eql(u8, event_kind, "session.close.requested")) return .close;
    if (!std.mem.eql(u8, event_kind, "action.prepared")) return null;
    const decoded = action_tools.decodePreparedAction(allocator, raw) catch return null;
    defer decoded.deinit(allocator);
    return switch (decoded.kind) {
        .add_inline_comment => .add_inline_comment,
        .reply_thread => .reply_thread,
        .resolve_thread => .resolve_thread,
        .unresolve_thread => .unresolve_thread,
        .update_comment => .update_comment,
        .delete_comment => .delete_comment,
        .mark_viewed => .mark_viewed,
        .unmark_viewed => .unmark_viewed,
        .graphql => .graphql,
    };
}
fn authorityCovers(granted: ?HumanAuthority, requested: HumanAuthority) bool {
    const value = granted orelse return false;
    return value == requested or (value == .github_any and requested != .complete and requested != .close);
}
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    return false;
}

test "file selection remains gated without completed primary" {
    const registry = Registry{ .allocator = std.testing.allocator };
    try std.testing.expect(registry.latest_primary_turn_id == null);
}

test "session context dynamic tool namespace exposes the exact authoritative surface" {
    inline for (.{ "search_unresolved_threads", "prepare_github_action", "complete_file_review", "close_session", "\"required\":[\"slot\",\"kind\",\"effectSummary\",\"payload\"]" }) |needle| try std.testing.expect(std.mem.indexOf(u8, dynamic_tools_json, needle) != null);
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
    try std.testing.expectEqual(HumanAuthority.github_any, registry.sessions.items[0].human_authority.?);
    try registry.closeSession("s");
    try std.testing.expectEqual(SessionStatus.closed, registry.sessions.items[0].status);
}

test "explicit broad GitHub operation grants generic action authority without ordinary questions" {
    try std.testing.expectEqual(HumanAuthority.github_any, classifyHumanInstruction("please add the release label to this pull request").?);
    try std.testing.expectEqual(HumanAuthority.github_any, classifyHumanInstruction("close this pull request").?);
    try std.testing.expectEqual(HumanAuthority.github_any, classifyHumanInstruction("update the pull request title").?);
    try std.testing.expectEqual(HumanAuthority.close, classifyHumanInstruction("close this session").?);
    try std.testing.expect(classifyHumanInstruction("which labels are already on this pull request?") == null);
    try std.testing.expect(classifyHumanInstruction("tell me how to add a label to the pull request") == null);
}
