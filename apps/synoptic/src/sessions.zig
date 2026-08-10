const std = @import("std");
const cas_runtime = @import("cas_runtime");
const action_tools = @import("tools.zig");
const domain = @import("domain.zig");

pub const max_visible_events: usize = 1024;
pub const safe_boundary_timeout_ms: u32 = 5_000;
pub const approval_timeout_ms: u32 = 25_000;
const max_approval_records: usize = 64;
const max_approval_decisions: usize = 16;
const max_approval_request_bytes: usize = 512 * 1024;
const safe_boundary_quiescence_ms: u32 = 50;
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
    turn_active: bool = true,
    human_authority: ?HumanAuthority = null,
    pending_initial_prompt: ?[]u8 = null,
    pending_skill_path: ?[]u8 = null,
    fn deinit(self: Session, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.thread_id);
        allocator.free(self.turn_id);
        allocator.free(self.path);
        allocator.free(self.revision);
        if (self.pending_initial_prompt) |value| allocator.free(value);
        if (self.pending_skill_path) |value| allocator.free(value);
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
const TurnRef = struct { thread: []u8, turn: []u8 };

const ApprovalState = enum { pending, resolved, expired };
const OfferedDecision = struct {
    choice_json: []u8,
    result_json: []u8,

    fn deinit(self: OfferedDecision, allocator: std.mem.Allocator) void {
        allocator.free(self.choice_json);
        allocator.free(self.result_json);
    }
};
const PendingApproval = struct {
    id: []u8,
    session_id: ?[]u8,
    thread_id: []u8,
    method: []u8,
    request_json: []u8,
    decisions: std.ArrayList(OfferedDecision) = .empty,
    decline_result_json: []u8,
    result_json: ?[]u8 = null,
    state: ApprovalState = .pending,

    fn deinit(self: *PendingApproval, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.session_id) |value| allocator.free(value);
        allocator.free(self.thread_id);
        allocator.free(self.method);
        allocator.free(self.request_json);
        for (self.decisions.items) |decision| decision.deinit(allocator);
        self.decisions.deinit(allocator);
        allocator.free(self.decline_result_json);
        if (self.result_json) |value| allocator.free(value);
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    actor: ?cas_runtime.Actor = null,
    primary_thread_id: ?[]u8 = null,
    latest_primary_turn_id: ?[]u8 = null,
    primary_start_turn_id: ?[]u8 = null,
    primary_turn_active: bool = false,
    evidence: ?domain.PrGeneration = null,
    notification_count: u64 = 0,
    mutex: RegistryMutex = .{},
    sessions: std.ArrayList(Session) = .empty,
    visible_events: std.ArrayList(VisibleEvent) = .empty,
    active_command_ids: std.ArrayList([]u8) = .empty,
    completed_turn_ids: std.ArrayList([]u8) = .empty,
    approvals: std.ArrayList(PendingApproval) = .empty,
    synchronizing: bool = false,
    next_session_id: u64 = 1,
    next_approval_id: u64 = 1,
    approval_wait_timeout_ms: u32 = approval_timeout_ms,
    io: ?std.Io = null,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, codex_path: []const u8) !Registry {
        var registry = Registry{ .allocator = allocator, .io = io };
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
        self.declineAllApprovals("shutdown");
        if (self.actor) |*actor| actor.deinit();
        if (self.primary_thread_id) |v| self.allocator.free(v);
        if (self.latest_primary_turn_id) |v| self.allocator.free(v);
        if (self.primary_start_turn_id) |v| self.allocator.free(v);
        if (self.evidence) |*value| value.deinit();
        for (self.sessions.items) |session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.visible_events.items) |event| event.deinit(self.allocator);
        self.visible_events.deinit(self.allocator);
        for (self.active_command_ids.items) |id| self.allocator.free(id);
        self.active_command_ids.deinit(self.allocator);
        for (self.completed_turn_ids.items) |id| self.allocator.free(id);
        self.completed_turn_ids.deinit(self.allocator);
        for (self.approvals.items) |*approval| approval.deinit(self.allocator);
        self.approvals.deinit(self.allocator);
    }

    pub fn beginSynchronization(self: *Registry, io: std.Io, timeout_ms: u32) !void {
        self.mutex.lock();
        if (self.synchronizing) {
            self.mutex.unlock();
            return error.SynchronizationAlreadyActive;
        }
        self.synchronizing = true;
        self.declineApprovalsLocked(null, .resolved, "synchronization");
        var turns: std.ArrayList(TurnRef) = .empty;
        defer {
            for (turns.items) |turn| {
                self.allocator.free(turn.thread);
                self.allocator.free(turn.turn);
            }
            turns.deinit(self.allocator);
        }
        if (self.primary_turn_active and self.primary_thread_id != null and self.primary_start_turn_id != null) self.appendTurnRef(&turns, self.primary_thread_id.?, self.primary_start_turn_id.?) catch |err| {
            self.synchronizing = false;
            self.mutex.unlock();
            return err;
        };
        for (self.sessions.items) |session| if (session.turn_active and session.status != .closed) self.appendTurnRef(&turns, session.thread_id, session.turn_id) catch |err| {
            self.synchronizing = false;
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        errdefer self.endSynchronization();
        if (turns.items.len > 0) {
            const actor = &(self.actor orelse return error.AppServerUnavailable);
            for (turns.items) |turn| {
                const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"turnId\":{f}}}", .{ std.json.fmt(turn.thread, .{}), std.json.fmt(turn.turn, .{}) });
                defer self.allocator.free(params);
                const response = actor.requestJson("turn/interrupt", params, null) catch return error.TurnInterruptFailed;
                self.allocator.free(response);
            }
        }
        const started = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
        var quiet_since: ?i128 = null;
        while (true) {
            self.mutex.lock();
            const active = self.active_command_ids.items.len;
            self.mutex.unlock();
            const now = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
            if (active == 0) {
                if (quiet_since == null) quiet_since = now;
                if (now - quiet_since.? >= safe_boundary_quiescence_ms) return;
            } else quiet_since = null;
            if (now - started >= timeout_ms) return error.ActiveReviewCommandsTimeout;
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
        }
    }

    pub fn endSynchronization(self: *Registry) void {
        self.mutex.lock();
        self.synchronizing = false;
        self.mutex.unlock();
    }

    fn appendTurnRef(self: *Registry, turns: *std.ArrayList(TurnRef), thread: []const u8, turn: []const u8) !void {
        const owned_thread = try self.allocator.dupe(u8, thread);
        errdefer self.allocator.free(owned_thread);
        const owned_turn = try self.allocator.dupe(u8, turn);
        errdefer self.allocator.free(owned_turn);
        try turns.append(self.allocator, .{ .thread = owned_thread, .turn = owned_turn });
    }
    pub fn activeCommandCount(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.active_command_ids.items.len;
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
        const primary_turn = try extractString(self.allocator, turn, &.{ "turn", "id" });
        self.mutex.lock();
        defer self.mutex.unlock();
        self.primary_start_turn_id = primary_turn;
        self.primary_turn_active = self.latest_primary_turn_id == null or !std.mem.eql(u8, self.latest_primary_turn_id.?, primary_turn);
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
            self.declineApprovalsLocked(session_id, .resolved, "session-closed");
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

    pub fn queueSystemEvent(self: *Registry, method: []const u8, raw_json: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.visible_events.items.len >= max_visible_events) return error.VisibleEventLimitExceeded;
        const owned_method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned_method);
        const owned_json = try self.allocator.dupe(u8, raw_json);
        errdefer self.allocator.free(owned_json);
        try self.visible_events.append(self.allocator, .{ .session_id = null, .method = owned_method, .raw_json = owned_json });
    }

    pub fn resolveApproval(self: *Registry, session_id: ?[]const u8, approval_id: []const u8, choice_json: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.approvals.items) |*approval| if (std.mem.eql(u8, approval.id, approval_id)) {
            if ((approval.session_id == null) != (session_id == null)) return error.CrossSessionApproval;
            if (approval.session_id != null and !std.mem.eql(u8, approval.session_id.?, session_id.?)) return error.CrossSessionApproval;
            switch (approval.state) {
                .pending => {},
                .resolved => return error.ApprovalAlreadyResolved,
                .expired => return error.ApprovalExpired,
            }
            for (approval.decisions.items) |decision| if (std.mem.eql(u8, decision.choice_json, choice_json)) {
                const result = try self.allocator.dupe(u8, decision.result_json);
                errdefer self.allocator.free(result);
                try self.queueApprovalResolvedLocked(approval.*, choice_json, "human");
                approval.result_json = result;
                approval.state = .resolved;
                return;
            };
            return error.ApprovalDecisionNotOffered;
        };
        return error.UnknownApproval;
    }

    pub fn declineAllApprovals(self: *Registry, reason: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.declineApprovalsLocked(null, .resolved, reason);
    }

    pub fn openFile(self: *Registry, io: std.Io, cwd: []const u8, path: []const u8, revision: []const u8, base_oid: []const u8, head_oid: []const u8, diff: []const u8, threads_json: []const u8, skill_path: []const u8, start_immediately: bool) !OpenResult {
        self.mutex.lock();
        if (self.synchronizing) {
            self.mutex.unlock();
            return error.WorktreeSynchronizationActive;
        }
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
        const actor = &(self.actor orelse return error.AppServerUnavailable);
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
        var file_turn_id = try self.allocator.dupe(u8, "");
        defer self.allocator.free(file_turn_id);
        if (start_immediately) {
            const turn_params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"cwd\":{f},\"input\":[{{\"type\":\"skill\",\"name\":\"synoptic\",\"path\":{f}}},{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(file_thread_id, .{}), std.json.fmt(cwd, .{}), std.json.fmt(skill_path, .{}), std.json.fmt(prompt, .{}) });
            defer self.allocator.free(turn_params);
            const turn = try actor.requestJson("turn/start", turn_params, null);
            defer self.allocator.free(turn);
            self.allocator.free(file_turn_id);
            file_turn_id = try extractString(self.allocator, turn, &.{ "turn", "id" });
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        const session_id = try std.fmt.allocPrint(self.allocator, "ses-{d}", .{self.next_session_id});
        errdefer self.allocator.free(session_id);
        self.next_session_id += 1;
        const already_completed = start_immediately and self.turnCompletedLocked(file_turn_id);
        const thread_id = try self.allocator.dupe(u8, file_thread_id);
        errdefer self.allocator.free(thread_id);
        const turn_id = try self.allocator.dupe(u8, file_turn_id);
        errdefer self.allocator.free(turn_id);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_revision = try self.allocator.dupe(u8, revision);
        errdefer self.allocator.free(owned_revision);
        const pending_prompt = if (start_immediately) null else try self.allocator.dupe(u8, prompt);
        errdefer if (pending_prompt) |value| self.allocator.free(value);
        const pending_skill = if (start_immediately) null else try self.allocator.dupe(u8, skill_path);
        errdefer if (pending_skill) |value| self.allocator.free(value);
        try self.sessions.append(self.allocator, .{ .id = session_id, .thread_id = thread_id, .turn_id = turn_id, .path = owned_path, .revision = owned_revision, .initial_turn_active = start_immediately and !already_completed, .turn_active = start_immediately and !already_completed, .pending_initial_prompt = pending_prompt, .pending_skill_path = pending_skill });
        return .{ .reused = false, .session_id = try self.allocator.dupe(u8, session_id), .allocator = self.allocator };
    }

    pub fn message(self: *Registry, session_id: []const u8, text: []const u8, active: bool) !void {
        self.mutex.lock();
        var locked = true;
        errdefer if (locked) self.mutex.unlock();
        if (self.synchronizing) {
            self.mutex.unlock();
            locked = false;
            return error.WorktreeSynchronizationActive;
        }
        var thread_id: ?[]u8 = null;
        var turn_id: ?[]u8 = null;
        var initial_prompt: ?[]u8 = null;
        var skill_path: ?[]u8 = null;
        for (self.sessions.items) |*session| if (std.mem.eql(u8, session.id, session_id) and session.status != .closed) {
            thread_id = try self.allocator.dupe(u8, session.thread_id);
            turn_id = try self.allocator.dupe(u8, session.turn_id);
            initial_prompt = if (session.pending_initial_prompt) |value| try self.allocator.dupe(u8, value) else null;
            skill_path = if (session.pending_skill_path) |value| try self.allocator.dupe(u8, value) else null;
            if (session.pending_initial_prompt != null) {
                session.initial_turn_active = true;
                session.human_authority = null;
            }
            break;
        };
        self.mutex.unlock();
        locked = false;
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        defer if (thread_id) |v| self.allocator.free(v);
        defer if (turn_id) |v| self.allocator.free(v);
        defer if (initial_prompt) |v| self.allocator.free(v);
        defer if (skill_path) |v| self.allocator.free(v);
        const first_turn = initial_prompt != null;
        const method = if (active and !first_turn) "turn/steer" else "turn/start";
        const combined = if (initial_prompt) |prompt| try std.fmt.allocPrint(self.allocator, "{s}\n\nThe human opened this idle session and now says:\n{s}", .{ prompt, text }) else try self.allocator.dupe(u8, text);
        defer self.allocator.free(combined);
        const params = if (first_turn)
            try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"input\":[{{\"type\":\"skill\",\"name\":\"synoptic\",\"path\":{f}}},{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(thread_id orelse return error.UnknownSession, .{}), std.json.fmt(skill_path.?, .{}), std.json.fmt(combined, .{}) })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{f},\"expectedTurnId\":{f},\"input\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ std.json.fmt(thread_id orelse return error.UnknownSession, .{}), std.json.fmt(turn_id orelse "", .{}), std.json.fmt(combined, .{}) });
        defer self.allocator.free(params);
        const response = try actor.requestJson(method, params, null);
        defer self.allocator.free(response);
        if (!active or first_turn) {
            const next_turn = try extractString(self.allocator, response, &.{ "turn", "id" });
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.sessions.items) |*session| {
                if (std.mem.eql(u8, session.id, session_id)) {
                    self.allocator.free(session.turn_id);
                    session.turn_id = next_turn;
                    session.turn_active = !self.turnCompletedLocked(next_turn);
                    if (session.pending_initial_prompt) |value| self.allocator.free(value);
                    if (session.pending_skill_path) |value| self.allocator.free(value);
                    session.pending_initial_prompt = null;
                    session.pending_skill_path = null;
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
        const next_turn = try extractString(self.allocator, response, &.{ "turn", "id" });
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.primary_start_turn_id) |old| self.allocator.free(old);
        self.primary_start_turn_id = next_turn;
        self.primary_turn_active = self.latest_primary_turn_id == null or !std.mem.eql(u8, self.latest_primary_turn_id.?, next_turn);
    }

    fn onNotification(context: *anyopaque, notification: cas_runtime.Notification) void {
        const self: *Registry = @ptrCast(@alignCast(context));
        self.recordCommandActivity(notification.method, notification.raw_json);
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
            if (extractString(self.allocator, notification.raw_json, &.{ "params", "turn", "id" })) |completed_turn| {
                defer self.allocator.free(completed_turn);
                if (!self.turnCompletedLocked(completed_turn) and self.completed_turn_ids.items.len < 512) if (self.allocator.dupe(u8, completed_turn)) |owned| {
                    self.completed_turn_ids.append(self.allocator, owned) catch self.allocator.free(owned);
                } else |_| {};
            } else |_| {}
            if (extractString(self.allocator, notification.raw_json, &.{ "params", "threadId" })) |thread| {
                defer self.allocator.free(thread);
                for (self.sessions.items) |*session| {
                    if (std.mem.eql(u8, session.thread_id, thread)) {
                        session.initial_turn_active = false;
                        session.turn_active = false;
                    }
                }
            } else |_| {}
        }
        self.mutex.unlock();
        if (!std.mem.eql(u8, notification.method, "turn/completed")) return;
        self.recordPrimaryCompletion(notification.raw_json);
    }

    fn turnCompletedLocked(self: *Registry, turn_id: []const u8) bool {
        for (self.completed_turn_ids.items) |id| if (std.mem.eql(u8, id, turn_id)) return true;
        return false;
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
            self.primary_turn_active = false;
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
        if (std.mem.eql(u8, request.method, "item/commandExecution/requestApproval") or std.mem.eql(u8, request.method, "item/permissions/requestApproval")) return self.handleApprovalRequest(request, allocator);
        if (std.mem.eql(u8, request.method, "item/fileChange/requestApproval")) return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        if (std.mem.eql(u8, request.method, "applyPatchApproval") or std.mem.eql(u8, request.method, "execCommandApproval")) return allocator.dupe(u8, "{\"decision\":{\"denied\":{\"rejection\":\"Synoptic never authorizes direct file changes or deprecated approval requests\"}}}");
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

    fn handleApprovalRequest(self: *Registry, request: cas_runtime.ServerRequest, allocator: std.mem.Allocator) ![]u8 {
        if (request.raw_json.len > max_approval_request_bytes) return allocator.dupe(u8, declineResult(request.method));
        const io = self.io orelse return allocator.dupe(u8, declineResult(request.method));
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request.raw_json, .{}) catch return allocator.dupe(u8, declineResult(request.method));
        defer parsed.deinit();
        const params = if (parsed.value == .object) parsed.value.object.get("params") orelse return allocator.dupe(u8, declineResult(request.method)) else return allocator.dupe(u8, declineResult(request.method));
        if (params != .object) return allocator.dupe(u8, declineResult(request.method));
        const thread_value = params.object.get("threadId") orelse return allocator.dupe(u8, declineResult(request.method));
        if (thread_value != .string) return allocator.dupe(u8, declineResult(request.method));

        self.mutex.lock();
        if (self.synchronizing) {
            self.mutex.unlock();
            return allocator.dupe(u8, declineResult(request.method));
        }
        var owner: ?[]const u8 = null;
        var owner_count: usize = 0;
        for (self.sessions.items) |session| if (session.status != .closed and std.mem.eql(u8, session.thread_id, thread_value.string)) {
            owner = session.id;
            owner_count += 1;
        };
        const matches_primary = self.primary_thread_id != null and std.mem.eql(u8, self.primary_thread_id.?, thread_value.string);
        const primary_owner = owner_count == 0 and matches_primary;
        if ((owner_count == 1 and matches_primary) or (owner_count != 1 and !primary_owner)) {
            self.mutex.unlock();
            return allocator.dupe(u8, declineResult(request.method));
        }
        self.pruneApprovalsLocked();
        if (self.approvals.items.len >= max_approval_records or self.visible_events.items.len >= max_visible_events) {
            self.mutex.unlock();
            return allocator.dupe(u8, declineResult(request.method));
        }
        var approval = self.makeApprovalLocked(if (primary_owner) null else owner.?, thread_value.string, request.method, request.raw_json, params.object) catch |err| {
            self.mutex.unlock();
            return switch (err) {
                error.MalformedApprovalRequest => allocator.dupe(u8, declineResult(request.method)),
                else => err,
            };
        };
        var approval_transferred = false;
        errdefer if (!approval_transferred) approval.deinit(self.allocator);
        const approval_id = self.allocator.dupe(u8, approval.id) catch |err| {
            self.mutex.unlock();
            return err;
        };
        defer self.allocator.free(approval_id);
        const requested_payload = self.approvalRequestedPayloadLocked(approval) catch |err| {
            self.mutex.unlock();
            return err;
        };
        defer self.allocator.free(requested_payload);
        self.appendVisibleLocked(approval.session_id, "approval.requested", requested_payload) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.approvals.append(self.allocator, approval) catch |err| {
            const event = self.visible_events.pop().?;
            event.deinit(self.allocator);
            self.mutex.unlock();
            return err;
        };
        approval_transferred = true;
        self.mutex.unlock();

        const started = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
        while (true) {
            self.mutex.lock();
            var found = false;
            for (self.approvals.items) |*pending| if (std.mem.eql(u8, pending.id, approval_id)) {
                found = true;
                if (pending.result_json) |result| {
                    const owned = allocator.dupe(u8, result) catch |err| {
                        self.mutex.unlock();
                        return err;
                    };
                    self.mutex.unlock();
                    return owned;
                }
                const now = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
                if (now - started >= self.approval_wait_timeout_ms) {
                    pending.result_json = self.allocator.dupe(u8, pending.decline_result_json) catch |err| {
                        self.mutex.unlock();
                        return err;
                    };
                    pending.state = .expired;
                    self.queueApprovalResolvedLocked(pending.*, "\"decline\"", "timeout") catch {};
                    const owned = allocator.dupe(u8, pending.result_json.?) catch |err| {
                        self.mutex.unlock();
                        return err;
                    };
                    self.mutex.unlock();
                    return owned;
                }
                self.mutex.unlock();
                std.Io.sleep(io, .fromMilliseconds(2), .awake) catch return allocator.dupe(u8, declineResult(request.method));
                break;
            };
            if (!found) {
                self.mutex.unlock();
                return allocator.dupe(u8, declineResult(request.method));
            }
        }
    }

    fn makeApprovalLocked(self: *Registry, session_id: ?[]const u8, thread_id: []const u8, method: []const u8, raw: []const u8, params: std.json.ObjectMap) !PendingApproval {
        const id = try std.fmt.allocPrint(self.allocator, "apr-{d}", .{self.next_approval_id});
        errdefer self.allocator.free(id);
        self.next_approval_id += 1;
        var approval = PendingApproval{
            .id = id,
            .session_id = if (session_id) |value| try self.allocator.dupe(u8, value) else null,
            .thread_id = undefined,
            .method = undefined,
            .request_json = undefined,
            .decline_result_json = undefined,
        };
        errdefer if (approval.session_id) |value| self.allocator.free(value);
        approval.thread_id = try self.allocator.dupe(u8, thread_id);
        errdefer self.allocator.free(approval.thread_id);
        approval.method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(approval.method);
        approval.request_json = try self.allocator.dupe(u8, raw);
        errdefer self.allocator.free(approval.request_json);
        approval.decline_result_json = try self.allocator.dupe(u8, declineResult(method));
        errdefer self.allocator.free(approval.decline_result_json);
        errdefer {
            for (approval.decisions.items) |decision| decision.deinit(self.allocator);
            approval.decisions.deinit(self.allocator);
        }
        if (std.mem.eql(u8, method, "item/commandExecution/requestApproval")) {
            const available = params.get("availableDecisions");
            if (available) |choices| switch (choices) {
                .null => inline for (.{ "accept", "acceptForSession", "decline", "cancel" }) |choice| try self.appendStringDecision(&approval.decisions, choice, true, null),
                .array => |array| {
                    if (array.items.len == 0 or array.items.len > max_approval_decisions) return error.MalformedApprovalRequest;
                    for (array.items) |choice| try self.appendCommandDecision(&approval.decisions, choice);
                },
                else => return error.MalformedApprovalRequest,
            } else inline for (.{ "accept", "acceptForSession", "decline", "cancel" }) |choice| try self.appendStringDecision(&approval.decisions, choice, true, null);
        } else {
            const requested = params.get("permissions") orelse return error.MalformedApprovalRequest;
            if (requested != .object) return error.MalformedApprovalRequest;
            const requested_json = try stringifyValueAlloc(self.allocator, requested);
            defer self.allocator.free(requested_json);
            const accept = try std.fmt.allocPrint(self.allocator, "{{\"permissions\":{s},\"scope\":\"turn\"}}", .{requested_json});
            defer self.allocator.free(accept);
            const session = try std.fmt.allocPrint(self.allocator, "{{\"permissions\":{s},\"scope\":\"session\"}}", .{requested_json});
            defer self.allocator.free(session);
            try self.appendStringDecision(&approval.decisions, "accept", false, accept);
            try self.appendStringDecision(&approval.decisions, "acceptForSession", false, session);
            try self.appendStringDecision(&approval.decisions, "decline", false, "{\"permissions\":{},\"scope\":\"turn\"}");
        }
        return approval;
    }

    fn appendCommandDecision(self: *Registry, decisions: *std.ArrayList(OfferedDecision), value: std.json.Value) !void {
        const choice = try stringifyValueAlloc(self.allocator, value);
        errdefer self.allocator.free(choice);
        const result = try std.fmt.allocPrint(self.allocator, "{{\"decision\":{s}}}", .{choice});
        errdefer self.allocator.free(result);
        try decisions.append(self.allocator, .{ .choice_json = choice, .result_json = result });
    }

    fn appendStringDecision(self: *Registry, decisions: *std.ArrayList(OfferedDecision), choice: []const u8, wrap_command: bool, result_json: ?[]const u8) !void {
        const choice_json = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(choice, .{})});
        errdefer self.allocator.free(choice_json);
        const result = if (result_json) |value| try self.allocator.dupe(u8, value) else if (wrap_command) try std.fmt.allocPrint(self.allocator, "{{\"decision\":{s}}}", .{choice_json}) else return error.MissingApprovalResult;
        errdefer self.allocator.free(result);
        try decisions.append(self.allocator, .{ .choice_json = choice_json, .result_json = result });
    }

    fn approvalRequestedPayloadLocked(self: *Registry, approval: PendingApproval) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        try out.writer.print("{{\"approvalId\":{f},\"ownerKind\":{f},\"sessionId\":{f},\"threadId\":{f},\"method\":{f},\"request\":{s},\"decisions\":[", .{ std.json.fmt(approval.id, .{}), std.json.fmt(if (approval.session_id == null) "primary" else "file", .{}), std.json.fmt(approval.session_id, .{}), std.json.fmt(approval.thread_id, .{}), std.json.fmt(approval.method, .{}), approval.request_json });
        for (approval.decisions.items, 0..) |decision, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(decision.choice_json);
        }
        try out.writer.writeAll("]}");
        return out.toOwnedSlice();
    }

    fn queueApprovalResolvedLocked(self: *Registry, approval: PendingApproval, choice_json: []const u8, reason: []const u8) !void {
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"approvalId\":{f},\"ownerKind\":{f},\"sessionId\":{f},\"decision\":{s},\"reason\":{f}}}", .{ std.json.fmt(approval.id, .{}), std.json.fmt(if (approval.session_id == null) "primary" else "file", .{}), std.json.fmt(approval.session_id, .{}), choice_json, std.json.fmt(reason, .{}) });
        defer self.allocator.free(payload);
        try self.appendVisibleLocked(approval.session_id, "approval.resolved", payload);
    }

    fn declineApprovalsLocked(self: *Registry, session_id: ?[]const u8, state: ApprovalState, reason: []const u8) void {
        for (self.approvals.items) |*approval| {
            if (approval.state != .pending or (session_id != null and (approval.session_id == null or !std.mem.eql(u8, approval.session_id.?, session_id.?)))) continue;
            approval.result_json = self.allocator.dupe(u8, approval.decline_result_json) catch continue;
            approval.state = state;
            self.queueApprovalResolvedLocked(approval.*, "\"decline\"", reason) catch {};
        }
    }

    fn pruneApprovalsLocked(self: *Registry) void {
        while (self.approvals.items.len >= max_approval_records) {
            var removable: ?usize = null;
            for (self.approvals.items, 0..) |approval, index| if (approval.state != .pending) {
                removable = index;
                break;
            };
            const index = removable orelse return;
            var removed = self.approvals.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }

    fn appendVisibleLocked(self: *Registry, session_id: ?[]const u8, method: []const u8, raw_json: []const u8) !void {
        if (self.visible_events.items.len >= max_visible_events) return error.VisibleEventLimitExceeded;
        const owned_session = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_session) |value| self.allocator.free(value);
        const owned_method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned_method);
        const owned_json = try self.allocator.dupe(u8, raw_json);
        errdefer self.allocator.free(owned_json);
        try self.visible_events.append(self.allocator, .{ .session_id = owned_session, .method = owned_method, .raw_json = owned_json });
    }

    fn recordCommandActivity(self: *Registry, method: []const u8, raw: []const u8) void {
        const started = std.mem.eql(u8, method, "item/started");
        const completed = std.mem.eql(u8, method, "item/completed");
        if (!started and !completed) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return;
        defer parsed.deinit();
        const params = if (parsed.value == .object) parsed.value.object.get("params") orelse return else return;
        const item = if (params == .object) params.object.get("item") orelse return else return;
        if (item != .object) return;
        const kind = item.object.get("type") orelse return;
        if (kind != .string or (!std.mem.eql(u8, kind.string, "commandExecution") and !std.mem.eql(u8, kind.string, "command_execution"))) return;
        const id = item.object.get("id") orelse return;
        if (id != .string) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.active_command_ids.items, 0..) |existing, index| if (std.mem.eql(u8, existing, id.string)) {
            if (completed) {
                const removed = self.active_command_ids.orderedRemove(index);
                self.allocator.free(removed);
            }
            return;
        };
        if (started) {
            const owned = self.allocator.dupe(u8, id.string) catch return;
            self.active_command_ids.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                return;
            };
        }
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

fn declineResult(method: []const u8) []const u8 {
    return if (std.mem.eql(u8, method, "item/permissions/requestApproval"))
        "{\"permissions\":{},\"scope\":\"turn\"}"
    else
        "{\"decision\":\"decline\"}";
}

fn stringifyValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
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

test "worktree integrity synchronization waits for commands and times out bounded" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    registry.recordCommandActivity("item/started", "{\"params\":{\"item\":{\"id\":\"cmd-1\",\"type\":\"commandExecution\"}}}");
    try std.testing.expectEqual(@as(usize, 1), registry.activeCommandCount());
    try std.testing.expectError(error.ActiveReviewCommandsTimeout, registry.beginSynchronization(std.testing.io, 20));
    try std.testing.expect(!registry.synchronizing);
    registry.recordCommandActivity("item/completed", "{\"params\":{\"item\":{\"id\":\"cmd-1\",\"type\":\"commandExecution\"}}}");
    try std.testing.expectEqual(@as(usize, 0), registry.activeCommandCount());
    try registry.beginSynchronization(std.testing.io, 100);
    registry.endSynchronization();
}

test "worktree integrity synchronization freezes new file and message work" {
    var registry = Registry{ .allocator = std.testing.allocator, .synchronizing = true };
    defer registry.deinit();
    try std.testing.expectError(error.WorktreeSynchronizationActive, registry.openFile(std.testing.io, "/repo", "a", "r", "b", "h", "", "[]", "/skill/SKILL.md", true));
    try std.testing.expectError(error.WorktreeSynchronizationActive, registry.message("missing", "hello", false));
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

const ApprovalInvocation = struct {
    registry: *Registry,
    method: []const u8,
    raw: []const u8,
    response: ?[]u8 = null,

    fn run(self: *ApprovalInvocation) void {
        const request = cas_runtime.ServerRequest{ .id = .{ .string = "server-request" }, .method = self.method, .raw_json = self.raw };
        self.response = Registry.onServerRequest(self.registry, request, std.heap.page_allocator) catch null;
    }
};

fn appendApprovalTestSession(registry: *Registry, id: []const u8, thread: []const u8) !void {
    try registry.sessions.append(registry.allocator, .{
        .id = try registry.allocator.dupe(u8, id),
        .thread_id = try registry.allocator.dupe(u8, thread),
        .turn_id = try registry.allocator.dupe(u8, "turn"),
        .path = try registry.allocator.dupe(u8, "a.zig"),
        .revision = try registry.allocator.dupe(u8, "r1"),
        .initial_turn_active = false,
        .turn_active = true,
    });
}

fn waitForApproval(registry: *Registry) !void {
    for (0..200) |_| {
        registry.mutex.lock();
        const pending = registry.approvals.items.len > 0 and registry.approvals.items[registry.approvals.items.len - 1].state == .pending;
        registry.mutex.unlock();
        if (pending) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.ExpectedApprovalMissing;
}

test "command approvals block for exact offered decision and reject spoof duplicate and invented choices" {
    var registry = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    var invocation = ApprovalInvocation{
        .registry = &registry,
        .method = "item/commandExecution/requestApproval",
        .raw = "{\"id\":7,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"file-1\",\"turnId\":\"turn\",\"itemId\":\"cmd\",\"startedAtMs\":1,\"command\":\"make test\",\"availableDecisions\":[\"accept\",\"decline\"]}}",
    };
    const thread = try std.Thread.spawn(.{}, ApprovalInvocation.run, .{&invocation});
    try waitForApproval(&registry);
    try std.testing.expectError(error.CrossSessionApproval, registry.resolveApproval("ses-2", "apr-1", "\"accept\""));
    try std.testing.expectError(error.ApprovalDecisionNotOffered, registry.resolveApproval("ses-1", "apr-1", "\"invented\""));
    try registry.resolveApproval("ses-1", "apr-1", "\"accept\"");
    thread.join();
    defer if (invocation.response) |response| std.heap.page_allocator.free(response);
    try std.testing.expectEqualStrings("{\"decision\":\"accept\"}", invocation.response.?);
    try std.testing.expectError(error.ApprovalAlreadyResolved, registry.resolveApproval("ses-1", "apr-1", "\"accept\""));
}

test "command approvals permissions grant only the exact requested carrier and scope" {
    var registry = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    var invocation = ApprovalInvocation{
        .registry = &registry,
        .method = "item/permissions/requestApproval",
        .raw = "{\"id\":8,\"method\":\"item/permissions/requestApproval\",\"params\":{\"threadId\":\"file-1\",\"turnId\":\"turn\",\"itemId\":\"permission\",\"startedAtMs\":1,\"cwd\":\"/repo\",\"permissions\":{\"network\":{\"enabled\":true}}}}",
    };
    const thread = try std.Thread.spawn(.{}, ApprovalInvocation.run, .{&invocation});
    try waitForApproval(&registry);
    try registry.resolveApproval("ses-1", "apr-1", "\"acceptForSession\"");
    thread.join();
    defer if (invocation.response) |response| std.heap.page_allocator.free(response);
    try std.testing.expectEqualStrings("{\"permissions\":{\"network\":{\"enabled\":true}},\"scope\":\"session\"}", invocation.response.?);
    registry.approval_wait_timeout_ms = 5;
    const decline = try Registry.onServerRequest(&registry, .{ .id = .{ .integer = 9 }, .method = invocation.method, .raw_json = invocation.raw }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(decline);
    try std.testing.expectEqualStrings("{\"permissions\":{},\"scope\":\"turn\"}", decline);
}

test "command approvals timeout close and synchronization conservatively decline" {
    var timed = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io, .approval_wait_timeout_ms = 5 };
    defer timed.deinit();
    try appendApprovalTestSession(&timed, "ses-1", "file-1");
    const request = cas_runtime.ServerRequest{ .id = .{ .integer = 1 }, .method = "item/commandExecution/requestApproval", .raw_json = "{\"id\":1,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"file-1\",\"turnId\":\"turn\",\"itemId\":\"cmd\",\"startedAtMs\":1,\"availableDecisions\":[\"accept\",\"decline\"]}}" };
    const timeout_response = try Registry.onServerRequest(&timed, request, std.heap.page_allocator);
    defer std.heap.page_allocator.free(timeout_response);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", timeout_response);
    try std.testing.expectError(error.ApprovalExpired, timed.resolveApproval("ses-1", "apr-1", "\"accept\""));

    var closed = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer closed.deinit();
    try appendApprovalTestSession(&closed, "ses-1", "file-1");
    var invocation = ApprovalInvocation{ .registry = &closed, .method = request.method, .raw = request.raw_json };
    const thread = try std.Thread.spawn(.{}, ApprovalInvocation.run, .{&invocation});
    try waitForApproval(&closed);
    try closed.closeSession("ses-1");
    thread.join();
    defer if (invocation.response) |response| std.heap.page_allocator.free(response);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", invocation.response.?);

    var syncing = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer syncing.deinit();
    try appendApprovalTestSession(&syncing, "ses-1", "file-1");
    syncing.sessions.items[0].turn_active = false;
    var sync_invocation = ApprovalInvocation{ .registry = &syncing, .method = request.method, .raw = request.raw_json };
    const sync_thread = try std.Thread.spawn(.{}, ApprovalInvocation.run, .{&sync_invocation});
    try waitForApproval(&syncing);
    try syncing.beginSynchronization(std.testing.io, 100);
    syncing.endSynchronization();
    sync_thread.join();
    defer if (sync_invocation.response) |response| std.heap.page_allocator.free(response);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", sync_invocation.response.?);
}

test "command approvals direct file change deprecated and unowned requests hard decline without browser events" {
    var registry = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer registry.deinit();
    const file = try Registry.onServerRequest(&registry, .{ .id = .{ .integer = 1 }, .method = "item/fileChange/requestApproval", .raw_json = "{}" }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(file);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", file);
    const deprecated = try Registry.onServerRequest(&registry, .{ .id = .{ .integer = 2 }, .method = "applyPatchApproval", .raw_json = "{}" }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(deprecated);
    try std.testing.expect(std.mem.indexOf(u8, deprecated, "denied") != null);
    const unowned = try Registry.onServerRequest(&registry, .{ .id = .{ .integer = 3 }, .method = "item/commandExecution/requestApproval", .raw_json = "{\"params\":{\"threadId\":\"primary\",\"availableDecisions\":[\"accept\",\"decline\"]}}" }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(unowned);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", unowned);
    registry.primary_thread_id = try std.heap.page_allocator.dupe(u8, "shared");
    try appendApprovalTestSession(&registry, "ses-1", "shared");
    const ambiguous = try Registry.onServerRequest(&registry, .{ .id = .{ .integer = 4 }, .method = "item/commandExecution/requestApproval", .raw_json = "{\"params\":{\"threadId\":\"shared\",\"availableDecisions\":[\"accept\",\"decline\"]}}" }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(ambiguous);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", ambiguous);
    try std.testing.expectEqual(@as(usize, 0), registry.visible_events.items.len);
}
