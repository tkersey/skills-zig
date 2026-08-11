const std = @import("std");
const app_meta = @import("app_meta");
const cas_runtime = @import("cas_runtime");
const action_tools = @import("tools.zig");
const config = @import("config.zig");
const domain = @import("domain.zig");

pub const max_visible_events: usize = 1024;
const synoptic_server_request_timeout_ms: u32 = 5 * 60 * 1000;
pub const safe_boundary_timeout_ms: u32 = 5_000;
pub const approval_timeout_ms: u32 = 25_000;
const approval_response_margin_ms: i64 = 50;
const max_approval_records: usize = 64;
const max_approval_decisions: usize = 16;
const max_approval_request_bytes: usize = 512 * 1024;
const safe_boundary_quiescence_ms: u32 = 50;
const review_execution_fields =
    "\"approvalPolicy\":\"on-request\",\"sandbox\":\"read-only\"";
const missing_origin_response = "{\"contentItems\":[{\"type\":\"inputText\"," ++
    "\"text\":\"missing originating thread\"}],\"success\":false}";
const unsupported_action_response = "{\"contentItems\":[{\"type\":\"inputText\"," ++
    "\"text\":\"unsupported action kind\"}],\"success\":false}";
const stale_completion_response = "{\"contentItems\":[{\"type\":\"inputText\"," ++
    "\"text\":\"only the official current-revision session can complete the file\"}]," ++
    "\"success\":false}";
const accepted_domain_response = "{\"contentItems\":[{\"type\":\"inputText\"," ++
    "\"text\":\"accepted for Synoptic domain handling\"}],\"success\":true}";
const missing_authority_response = "{\"contentItems\":[{\"type\":\"inputText\"," ++
    "\"text\":\"initial review or missing explicit human authority\"}]," ++
    "\"success\":false}";
const evidence_unavailable_response = "{\"contentItems\":[{\"type\":\"inputText\"," ++
    "\"text\":\"current PR evidence unavailable\"}],\"success\":false}";

fn authoritativeToolEventKind(tool: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, tool, "synoptic.prepare_github_action")) return "action.prepared";
    if (std.mem.eql(u8, tool, "synoptic.complete_file_review")) {
        return "file.complete.requested";
    }
    if (std.mem.eql(u8, tool, "synoptic.close_session")) return "session.close.requested";
    return null;
}

pub const dynamic_tools_json =
    "[{\"type\":\"namespace\",\"name\":\"synoptic\",\"descr" ++
    "iption\":\"Human-directed Synoptic review operations\"" ++
    ",\"tools\":[" ++
    "{\"name\":\"search_unresolved_threads\",\"description" ++
    "\":\"Search server-owned unresolved current-PR review " ++
    "evidence; use whole-PR only for cross-file concerns\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
    "\"query\":{\"type\":\"string\"},\"paths\":{\"type\":\"" ++
    "array\",\"items\":{\"type\":\"string\"}},\"includeWhol" ++
    "ePullRequest\":{\"type\":\"boolean\"}}}}," ++
    "{\"name\":\"prepare_github_action\",\"description\":\"" ++
    "Only after explicit human instruction, prepare an immu" ++
    "table confirmable GitHub action; forbidden during init" ++
    "ial review\",\"inputSchema\":{\"type\":\"object\",\"re" ++
    "quired\":[\"slot\",\"kind\",\"effectSummary\",\"payloa" ++
    "d\"],\"properties\":{\"slot\":{\"type\":\"string\"},\"" ++
    "kind\":{\"type\":\"string\",\"enum\":[\"add_inline_com" ++
    "ment\",\"reply_thread\",\"resolve_thread\",\"unresolve" ++
    "_thread\",\"update_comment\",\"delete_comment\",\"mark" ++
    "_viewed\",\"unmark_viewed\",\"graphql\"]},\"effectSumm" ++
    "ary\":{\"type\":\"string\"},\"payload\":{\"type\":\"ob" ++
    "ject\"}}}}," ++
    "{\"name\":\"complete_file_review\",\"description\":\"C" ++
    "omplete the official current file only after explicit " ++
    "human instruction\",\"inputSchema\":{\"type\":\"object" ++
    "\"}}," ++
    "{\"name\":\"close_session\",\"description\":\"Close th" ++
    "is local session only after explicit human instruction" ++
    "\",\"inputSchema\":{\"type\":\"object\"}}]}]";
pub const SessionStatus = enum { current, stale_origin, completed, closed };
pub const HumanAuthority = enum {
    github_any,
    add_inline_comment,
    reply_thread,
    resolve_thread,
    unresolve_thread,
    update_comment,
    delete_comment,
    mark_viewed,
    unmark_viewed,
    graphql,
    complete,
    close,
};
pub const Session = struct {
    id: []u8,
    thread_id: []u8,
    turn_id: []u8,
    path: []u8,
    revision: []u8,
    last_injected_revision: []u8,
    status: SessionStatus = .current,
    opening: bool = false,
    initial_turn_active: bool = true,
    turn_active: bool = true,
    turn_starting: bool = false,
    human_authority: ?HumanAuthority = null,
    pending_initial_prompt: ?[]u8 = null,
    pending_skill_path: ?[]u8 = null,
    fn deinit(self: Session, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.thread_id);
        allocator.free(self.turn_id);
        allocator.free(self.path);
        allocator.free(self.revision);
        allocator.free(self.last_injected_revision);
        if (self.pending_initial_prompt) |value| allocator.free(value);
        if (self.pending_skill_path) |value| allocator.free(value);
    }
};
pub const AuthoritativeToolHandler = struct {
    context: *anyopaque,
    handle: *const fn (
        context: *anyopaque,
        event_kind: []const u8,
        raw_json: []const u8,
        session_id: []const u8,
    ) anyerror!void,
    deinit: ?*const fn (context: *anyopaque) void = null,
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
const ReservedAuthoritative = struct {
    session_id: []u8,
    visible_event: VisibleEvent,
    handler: AuthoritativeToolHandler,
};

const FileAdmission = struct {
    path: []u8,
    revision: []u8,

    fn deinit(self: FileAdmission, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.revision);
    }
};

const OpenAdmission = union(enum) {
    reused: []u8,
    reserved,
};

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
    managed_server: ?cas_runtime.ManagedServer = null,
    transport: Transport = .stdio,
    primary_thread_id: ?[]u8 = null,
    latest_primary_turn_id: ?[]u8 = null,
    primary_start_turn_id: ?[]u8 = null,
    primary_turn_active: bool = false,
    primary_failure_reported: bool = false,
    primary_failure_status: ?PrimaryFailure = null,
    evidence: ?domain.PrGeneration = null,
    notification_count: u64 = 0,
    mutex: RegistryMutex = .{},
    sessions: std.ArrayList(Session) = .empty,
    file_admissions: std.ArrayList(FileAdmission) = .empty,
    visible_events: std.ArrayList(VisibleEvent) = .empty,
    active_command_ids: std.ArrayList([]u8) = .empty,
    completed_turn_ids: std.ArrayList([]u8) = .empty,
    primary_terminals: std.ArrayList(PrimaryTerminal) = .empty,
    approvals: std.ArrayList(PendingApproval) = .empty,
    synchronizing: bool = false,
    exclusions_pending: bool = false,
    next_session_id: u64 = 1,
    next_approval_id: u64 = 1,
    approval_wait_timeout_ms: u32 = approval_timeout_ms,
    max_sessions: usize = config.max_open_sessions,
    io: ?std.Io = null,
    authoritative_tool_handler: ?AuthoritativeToolHandler = null,
    authoritative_reservations: usize = 0,
    visible_overflow_count: u64 = 0,
    visible_overflow_session_id: ?[]u8 = null,

    const PrimaryFailure = enum { failed, interrupted };
    const PrimaryTerminalStatus = enum { completed, failed, interrupted };
    const PrimaryTerminal = struct {
        turn_id: []u8,
        status: PrimaryTerminalStatus,
    };
    const Transport = enum { websocket, stdio };

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        codex_path: []const u8,
    ) !Registry {
        var registry = Registry{ .allocator = allocator, .io = io };
        registry.actor = try cas_runtime.Client.startActor(allocator, .{
            .cwd = cwd,
            .io = io,
            .codex_path = codex_path,
            .read_only = true,
            .file_approval = "decline",
            .client_name = "synoptic",
            .client_title = "Synoptic",
            .client_version = app_meta.version,
        }, .{ .server_request_timeout_ms = synoptic_server_request_timeout_ms });
        return registry;
    }

    pub fn startManagedPreferred(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        receipt_dir: []const u8,
        codex_path: []const u8,
    ) !Registry {
        var managed = cas_runtime.managed_server.startOwnerLivedLoopbackServer(
            allocator,
            cwd,
            receipt_dir,
            codex_path,
            .inherit,
            io,
        ) catch return start(allocator, io, cwd, codex_path);
        var registry = Registry{ .allocator = allocator, .io = io };
        registry.actor = cas_runtime.Client.startActor(allocator, .{
            .cwd = cwd,
            .io = io,
            .codex_path = codex_path,
            .read_only = true,
            .file_approval = "decline",
            .client_name = "synoptic",
            .client_title = "Synoptic",
            .client_version = app_meta.version,
            .transport = .{ .explicit_websocket = managed.listen_url },
        }, .{ .server_request_timeout_ms = synoptic_server_request_timeout_ms }) catch {
            managed.deinit(allocator);
            return start(allocator, io, cwd, codex_path);
        };
        registry.managed_server = managed;
        registry.transport = .websocket;
        return registry;
    }

    pub fn transportName(self: *const Registry) []const u8 {
        return @tagName(self.transport);
    }

    pub fn setAuthoritativeToolHandler(
        self: *Registry,
        handler: AuthoritativeToolHandler,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.authoritative_tool_handler != null) return error.HandlerAlreadyConfigured;
        self.authoritative_tool_handler = handler;
    }

    pub fn deinit(self: *Registry) void {
        self.declineAllApprovals("shutdown");
        if (self.actor) |*actor| actor.deinit();
        if (self.managed_server) |*managed| managed.deinit(self.allocator);
        if (self.authoritative_tool_handler) |handler| {
            if (handler.deinit) |deinit_handler| deinit_handler(handler.context);
        }
        if (self.primary_thread_id) |v| self.allocator.free(v);
        if (self.latest_primary_turn_id) |v| self.allocator.free(v);
        if (self.primary_start_turn_id) |v| self.allocator.free(v);
        if (self.evidence) |*value| value.deinit();
        for (self.sessions.items) |session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.file_admissions.items) |admission| admission.deinit(self.allocator);
        self.file_admissions.deinit(self.allocator);
        for (self.visible_events.items) |event| event.deinit(self.allocator);
        self.visible_events.deinit(self.allocator);
        if (self.visible_overflow_session_id) |value| self.allocator.free(value);
        for (self.active_command_ids.items) |id| self.allocator.free(id);
        self.active_command_ids.deinit(self.allocator);
        for (self.completed_turn_ids.items) |id| self.allocator.free(id);
        self.completed_turn_ids.deinit(self.allocator);
        for (self.primary_terminals.items) |terminal| self.allocator.free(terminal.turn_id);
        self.primary_terminals.deinit(self.allocator);
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
        self.mutex.unlock();
        errdefer self.endSynchronization();
        const started = @divFloor(
            std.Io.Clock.awake.now(io).nanoseconds,
            std.time.ns_per_ms,
        );
        try self.waitForTurnStarts(io, started, timeout_ms);

        self.mutex.lock();
        var turns: std.ArrayList(TurnRef) = .empty;
        defer {
            for (turns.items) |turn| {
                self.allocator.free(turn.thread);
                self.allocator.free(turn.turn);
            }
            turns.deinit(self.allocator);
        }
        if (self.primary_turn_active and self.primary_thread_id != null and
            self.primary_start_turn_id != null) self.appendTurnRef(
            &turns,
            self.primary_thread_id.?,
            self.primary_start_turn_id.?,
        ) catch |err| {
            self.synchronizing = false;
            self.mutex.unlock();
            return err;
        };
        for (self.sessions.items) |session| if (session.turn_active and session.status !=
            .closed) self.appendTurnRef(&turns, session.thread_id, session.turn_id) catch |err| {
            self.synchronizing = false;
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        try self.interruptSynchronizationTurns(io, turns.items, started, timeout_ms);
        try self.waitForSynchronizationQuiescence(io, started, timeout_ms);
    }

    fn waitForTurnStarts(
        self: *Registry,
        io: std.Io,
        started: i128,
        timeout_ms: u32,
    ) !void {
        while (true) { // tiger: event-loop -- bounded by turn admission or deadline.
            self.mutex.lock();
            var starting: usize = 0;
            for (self.sessions.items) |session| {
                if (session.status != .closed and session.turn_starting) starting += 1;
            }
            self.mutex.unlock();
            if (starting == 0) return;
            const now = @divFloor(
                std.Io.Clock.awake.now(io).nanoseconds,
                std.time.ns_per_ms,
            );
            if (now - started >= timeout_ms) return error.ActiveReviewCommandsTimeout;
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch |ignored_error| {
                switch (ignored_error) {
                    else => {},
                }
            };
        }
    }

    fn interruptSynchronizationTurns(
        self: *Registry,
        io: std.Io,
        turns: []const TurnRef,
        started: i128,
        timeout_ms: u32,
    ) !void {
        if (turns.len == 0) return;
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        for (turns) |turn| {
            const params = try std.fmt.allocPrint(
                self.allocator,
                "{{\"threadId\":{f},\"turnId\":{f}}}",
                .{ std.json.fmt(turn.thread, .{}), std.json.fmt(turn.turn, .{}) },
            );
            defer self.allocator.free(params);
            const now = @divFloor(
                std.Io.Clock.awake.now(io).nanoseconds,
                std.time.ns_per_ms,
            );
            if (now - started >= timeout_ms) return error.ActiveReviewCommandsTimeout;
            const remaining: u32 = @intCast(@as(i128, timeout_ms) - (now - started));
            const response = actor.requestJson(
                "turn/interrupt",
                params,
                remaining,
            ) catch return error.TurnInterruptFailed;
            self.allocator.free(response);
            self.markInterruptedTurn(turn.thread, turn.turn);
        }
    }

    fn waitForSynchronizationQuiescence(
        self: *Registry,
        io: std.Io,
        started: i128,
        timeout_ms: u32,
    ) !void {
        var quiet_since: ?i128 = null;
        while (true) { // tiger: event-loop -- bounded by owner state or deadline.
            self.mutex.lock();
            const active = self.activeSynchronizationWorkLocked();
            self.mutex.unlock();
            const now = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
            if (active == 0) {
                if (quiet_since == null) quiet_since = now;
                if (now - quiet_since.? >= safe_boundary_quiescence_ms) return;
            } else quiet_since = null;
            if (now - started >= timeout_ms) return error.ActiveReviewCommandsTimeout;
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |ignored_error| {
                switch (ignored_error) {
                    else => {},
                }
            };
        }
    }

    pub fn endSynchronization(self: *Registry) void {
        self.mutex.lock();
        self.synchronizing = false;
        self.mutex.unlock();
    }

    fn activeSynchronizationWorkLocked(self: *const Registry) usize {
        var active = self.active_command_ids.items.len + self.file_admissions.items.len +
            self.authoritative_reservations + @intFromBool(self.primary_turn_active);
        for (self.sessions.items) |session| {
            if (session.status != .closed and session.turn_active) active += 1;
            if (session.status != .closed and session.turn_starting) active += 1;
        }
        return active;
    }

    pub fn setExclusionsPending(self: *Registry, pending: bool) void {
        self.mutex.lock();
        self.exclusions_pending = pending;
        self.mutex.unlock();
    }

    fn appendTurnRef(
        self: *Registry,
        turns: *std.ArrayList(TurnRef),
        thread: []const u8,
        turn: []const u8,
    ) !void {
        const owned_thread = try self.allocator.dupe(u8, thread);
        errdefer self.allocator.free(owned_thread);
        const owned_turn = try self.allocator.dupe(u8, turn);
        errdefer self.allocator.free(owned_turn);
        try turns.append(self.allocator, .{ .thread = owned_thread, .turn = owned_turn });
    }

    fn markInterruptedTurn(self: *Registry, thread_id: []const u8, turn_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.primary_thread_id) |primary| {
            if (std.mem.eql(u8, primary, thread_id) and self.primary_start_turn_id != null and
                std.mem.eql(u8, self.primary_start_turn_id.?, turn_id))
            {
                self.primary_turn_active = false;
            }
        }
        for (self.sessions.items) |*session| {
            if (!std.mem.eql(u8, session.thread_id, thread_id) or
                !std.mem.eql(u8, session.turn_id, turn_id)) continue;
            session.turn_active = false;
            session.initial_turn_active = false;
        }
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

    pub fn createPrimary(
        self: *Registry,
        io: std.Io,
        cwd: []const u8,
        skill_path: []const u8,
        pr_json: []const u8,
    ) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        try actor.subscribe(.{ .context = self, .handle = onNotification });
        try actor.setServerRequestHandler(.{ .context = self, .handle = onServerRequest });
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"cwd\":{f},\"ephemeral\":true,{s},\"dynamicTools\":{s}}}",
            .{ std.json.fmt(cwd, .{}), review_execution_fields, dynamic_tools_json },
        );
        defer self.allocator.free(params);
        const response = try actor.requestJson("thread/start", params, null);
        defer self.allocator.free(response);
        self.primary_thread_id = try extractString(self.allocator, response, &.{ "thread", "id" });
        const primary_role = try readReference(
            self.allocator,
            io,
            skill_path,
            "primary-context.md",
        );
        defer self.allocator.free(primary_role);
        const untrusted = try readReference(
            self.allocator,
            io,
            skill_path,
            "untrusted-repository-content.md",
        );
        defer self.allocator.free(untrusted);
        const prompt = try std.fmt.allocPrint(
            self.allocator,
            "{s}\n\n{s}\n\nAuthoritative current pull request:\n{s}" ++
                "\nThis primary context is hidden infrastructure. Do no" ++
                "t invoke Synoptic tools or produce publication-ready p" ++
                "er-file review actions.",
            .{ primary_role, untrusted, pr_json },
        );
        defer self.allocator.free(prompt);
        const turn_params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"threadId\":{f},\"input\":[{{\"type\":\"skill\",\"n" ++
                "ame\":\"synoptic\",\"path\":{f}}},{{\"type\":\"text\"," ++
                "\"text\":{f}}}]}}",
            .{
                std.json.fmt(self.primary_thread_id.?, .{}),
                std.json.fmt(skill_path, .{}),
                std.json.fmt(prompt, .{}),
            },
        );
        defer self.allocator.free(turn_params);
        const turn = try actor.requestJson("turn/start", turn_params, null);
        defer self.allocator.free(turn);
        const primary_turn = try extractString(self.allocator, turn, &.{ "turn", "id" });
        self.mutex.lock();
        defer self.mutex.unlock();
        self.installPrimaryTurnLocked(primary_turn);
    }

    pub fn primaryReady(self: *Registry) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.latest_primary_turn_id != null;
    }

    pub fn takePrimaryFailure(self: *Registry) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.primary_failure_reported) return null;
        if (self.primary_failure_status) |failure| {
            self.primary_failure_reported = true;
            return @tagName(failure);
        }
        const actor = if (self.actor) |*value| value else return null;
        const terminal = actor.terminalState();
        if (terminal == .running) return null;
        self.primary_failure_reported = true;
        return @tagName(terminal);
    }

    pub fn sessionCount(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.items.len;
    }
    fn markHumanInstruction(self: *Registry, session_id: []const u8, text: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*session| if (std.mem.eql(u8, session.id, session_id)) {
            session.human_authority = classifyHumanInstruction(text);
            return;
        };
        return error.UnknownSession;
    }
    fn clearHumanInstruction(self: *Registry, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*session| if (std.mem.eql(u8, session.id, session_id)) {
            session.human_authority = null;
            return;
        };
    }
    pub fn closeSession(self: *Registry, session_id: []const u8) !void {
        self.mutex.lock();
        var thread_id: ?[]u8 = null;
        var turn_id: ?[]u8 = null;
        var found = false;
        for (self.sessions.items) |*session| if (std.mem.eql(u8, session.id, session_id)) {
            found = true;
            if (session.turn_active and session.turn_id.len > 0) {
                thread_id = self.allocator.dupe(u8, session.thread_id) catch null;
                if (thread_id != null) {
                    turn_id = self.allocator.dupe(u8, session.turn_id) catch null;
                    if (turn_id == null) {
                        self.allocator.free(thread_id.?);
                        thread_id = null;
                    }
                }
            }
            session.status = .closed;
            session.opening = false;
            session.turn_active = false;
            session.turn_starting = false;
            session.initial_turn_active = false;
            self.declineApprovalsLocked(session_id, .resolved, "session-closed");
            break;
        };
        self.mutex.unlock();
        if (!found) return error.UnknownSession;
        defer if (thread_id) |value| self.allocator.free(value);
        defer if (turn_id) |value| self.allocator.free(value);
        if (thread_id != null and turn_id != null) {
            if (self.actor) |*actor| {
                const params = std.fmt.allocPrint(
                    self.allocator,
                    "{{\"threadId\":{f},\"turnId\":{f}}}",
                    .{ std.json.fmt(thread_id.?, .{}), std.json.fmt(turn_id.?, .{}) },
                ) catch return;
                defer self.allocator.free(params);
                const response = actor.requestJson("turn/interrupt", params, null) catch return;
                self.allocator.free(response);
            }
        }
    }

    pub fn discardOpenedSession(self: *Registry, session_id: []const u8) void {
        self.removeSession(session_id);
    }
    pub fn sessionIdentity(self: *Registry, session_id: []const u8) !SessionIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id)) return .{
            .path = try self.allocator.dupe(u8, session.path),
            .revision = try self.allocator.dupe(u8, session.revision),
            .turn_id = try self.allocator.dupe(u8, session.turn_id),
            .status = session.status,
            .allocator = self.allocator,
        };
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

    pub fn peekVisible(
        self: *Registry,
        allocator: std.mem.Allocator,
    ) !?VisibleEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.visible_events.items.len == 0) return null;
        const event = self.visible_events.items[0];
        const session_id = if (event.session_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (session_id) |value| allocator.free(value);
        const method = try allocator.dupe(u8, event.method);
        errdefer allocator.free(method);
        return .{
            .session_id = session_id,
            .method = method,
            .raw_json = try allocator.dupe(u8, event.raw_json),
        };
    }

    pub fn acknowledgeVisible(self: *Registry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.visible_events.items.len == 0) return error.NoVisibleEvent;
        self.visible_events.orderedRemove(0).deinit(self.allocator);
        self.queueOverflowWarningLocked();
    }

    pub fn queueSystemEvent(self: *Registry, method: []const u8, raw_json: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.appendVisibleLocked(null, method, raw_json);
    }

    pub fn resolveApproval(
        self: *Registry,
        session_id: ?[]const u8,
        approval_id: []const u8,
        choice_json: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.approvals.items) |*approval| if (std.mem.eql(u8, approval.id, approval_id)) {
            if ((approval.session_id == null) != (session_id == null)) {
                return error.CrossSessionApproval;
            }
            if (approval.session_id != null and !std.mem.eql(
                u8,
                approval.session_id.?,
                session_id.?,
            )) return error.CrossSessionApproval;
            switch (approval.state) {
                .pending => {},
                .resolved => return error.ApprovalAlreadyResolved,
                .expired => return error.ApprovalExpired,
            }
            for (approval.decisions.items) |decision| if (std.mem.eql(
                u8,
                decision.choice_json,
                choice_json,
            )) {
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

    pub fn openFile(
        self: *Registry,
        io: std.Io,
        cwd: []const u8,
        path: []const u8,
        revision: []const u8,
        base_oid: []const u8,
        head_oid: []const u8,
        diff: []const u8,
        threads_json: []const u8,
        skill_path: []const u8,
        start_immediately: bool,
    ) !OpenResult {
        switch (try self.admitFile(path, revision)) {
            .reused => |id| return .{
                .reused = true,
                .session_id = id,
                .allocator = self.allocator,
            },
            .reserved => {},
        }
        defer self.releaseFileAdmission(path, revision);
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        const file_thread_id = try self.forkFileThread(actor);
        defer self.allocator.free(file_thread_id);
        const prompt = try self.filePromptAlloc(
            io,
            skill_path,
            path,
            revision,
            base_oid,
            head_oid,
            diff,
            threads_json,
        );
        defer self.allocator.free(prompt);
        const session_id = try self.registerFileSession(
            file_thread_id,
            path,
            revision,
            prompt,
            skill_path,
            start_immediately,
        );
        errdefer {
            self.removeSession(session_id);
            self.allocator.free(session_id);
        }
        if (start_immediately) {
            const file_turn_id = try self.startFileTurn(
                actor,
                cwd,
                file_thread_id,
                skill_path,
                prompt,
            );
            defer self.allocator.free(file_turn_id);
            try self.activateOpeningSession(session_id, file_turn_id);
        }
        return .{ .reused = false, .session_id = session_id, .allocator = self.allocator };
    }

    fn admitFile(self: *Registry, path: []const u8, revision: []const u8) !OpenAdmission {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.synchronizing) return error.WorktreeSynchronizationActive;
        if (self.exclusions_pending) return error.AutomaticExclusionsPending;
        var live_sessions: usize = 0;
        for (self.sessions.items) |session| {
            if (session.status == .closed) continue;
            live_sessions += 1;
            if (!session.opening and session.status == .current and
                std.mem.eql(u8, session.path, path) and
                std.mem.eql(u8, session.revision, revision))
            {
                return .{ .reused = try self.allocator.dupe(u8, session.id) };
            }
        }
        for (self.file_admissions.items) |admission| if (std.mem.eql(
            u8,
            admission.path,
            path,
        ) and std.mem.eql(u8, admission.revision, revision)) {
            return error.SessionOpenInProgress;
        };
        if (live_sessions + self.file_admissions.items.len >= self.max_sessions) {
            return error.SessionLimitExceeded;
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_revision = try self.allocator.dupe(u8, revision);
        errdefer self.allocator.free(owned_revision);
        try self.file_admissions.append(self.allocator, .{
            .path = owned_path,
            .revision = owned_revision,
        });
        return .reserved;
    }

    fn releaseFileAdmission(self: *Registry, path: []const u8, revision: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.file_admissions.items, 0..) |admission, index| {
            if (!std.mem.eql(u8, admission.path, path) or
                !std.mem.eql(u8, admission.revision, revision)) continue;
            self.file_admissions.orderedRemove(index).deinit(self.allocator);
            return;
        }
    }

    fn forkFileThread(self: *Registry, actor: *cas_runtime.Actor) ![]u8 {
        self.mutex.lock();
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
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"threadId\":{f},\"lastTurnId\":{f},\"ephemeral\":tr" ++
                "ue,{s}}}",
            .{
                std.json.fmt(primary_thread, .{}),
                std.json.fmt(primary_turn, .{}),
                review_execution_fields,
            },
        );
        defer self.allocator.free(params);
        const response = try actor.requestJson("thread/fork", params, null);
        defer self.allocator.free(response);
        return extractString(self.allocator, response, &.{ "thread", "id" });
    }

    fn registerFileSession(
        self: *Registry,
        file_thread_id: []const u8,
        path: []const u8,
        revision: []const u8,
        prompt: []const u8,
        skill_path: []const u8,
        start_immediately: bool,
    ) ![]u8 {
        var session_fields_transferred = false;
        const session_id = try std.fmt.allocPrint(
            self.allocator,
            "ses-{d}",
            .{self.next_session_id},
        );
        errdefer if (!session_fields_transferred) self.allocator.free(session_id);
        const thread_id = try self.allocator.dupe(u8, file_thread_id);
        errdefer if (!session_fields_transferred) self.allocator.free(thread_id);
        const turn_id = try self.allocator.dupe(u8, "");
        errdefer if (!session_fields_transferred) self.allocator.free(turn_id);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer if (!session_fields_transferred) self.allocator.free(owned_path);
        const owned_revision = try self.allocator.dupe(u8, revision);
        errdefer if (!session_fields_transferred) self.allocator.free(owned_revision);
        const injected_revision = try self.allocator.dupe(u8, revision);
        errdefer if (!session_fields_transferred) self.allocator.free(injected_revision);
        const pending_prompt = if (start_immediately)
            null
        else
            try self.allocator.dupe(u8, prompt);
        errdefer if (!session_fields_transferred) if (pending_prompt) |value| {
            self.allocator.free(value);
        };
        const pending_skill = if (start_immediately)
            null
        else
            try self.allocator.dupe(u8, skill_path);
        errdefer if (!session_fields_transferred) if (pending_skill) |value| {
            self.allocator.free(value);
        };
        self.mutex.lock();
        self.next_session_id += 1;
        self.sessions.append(self.allocator, .{
            .id = session_id,
            .thread_id = thread_id,
            .turn_id = turn_id,
            .path = owned_path,
            .revision = owned_revision,
            .last_injected_revision = injected_revision,
            .opening = start_immediately,
            .initial_turn_active = start_immediately,
            .turn_active = start_immediately,
            .pending_initial_prompt = pending_prompt,
            .pending_skill_path = pending_skill,
        }) catch |err| {
            self.mutex.unlock();
            return err;
        };
        session_fields_transferred = true;
        if (!start_immediately) self.markPriorPathSessionsStaleLocked(
            session_id,
            path,
        );
        self.mutex.unlock();
        return self.allocator.dupe(u8, session_id);
    }

    fn activateOpeningSession(
        self: *Registry,
        session_id: []const u8,
        turn_id: []const u8,
    ) !void {
        const owned_turn = try self.allocator.dupe(u8, turn_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*session| {
            if (!std.mem.eql(u8, session.id, session_id) or session.status == .closed) continue;
            if (!session.opening) {
                self.allocator.free(owned_turn);
                return error.SessionNotOpening;
            }
            self.allocator.free(session.turn_id);
            session.turn_id = owned_turn;
            session.opening = false;
            const completed = self.turnCompletedLocked(turn_id);
            session.initial_turn_active = !completed;
            session.turn_active = !completed;
            self.markPriorPathSessionsStaleLocked(session_id, session.path);
            return;
        }
        self.allocator.free(owned_turn);
        return error.UnknownSession;
    }

    fn markPriorPathSessionsStaleLocked(
        self: *Registry,
        current_session_id: []const u8,
        path: []const u8,
    ) void {
        for (self.sessions.items) |*session| {
            if (std.mem.eql(u8, session.id, current_session_id)) continue;
            if (session.status == .current and std.mem.eql(u8, session.path, path)) {
                session.status = .stale_origin;
            }
        }
    }

    fn startFileTurn(
        self: *Registry,
        actor: *cas_runtime.Actor,
        cwd: []const u8,
        file_thread_id: []const u8,
        skill_path: []const u8,
        prompt: []const u8,
    ) ![]u8 {
        const turn_params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"threadId\":{f},\"cwd\":{f},\"input\":[{{\"type\":" ++
                "\"skill\",\"name\":\"synoptic\",\"path\":{f}}},{{\"typ" ++
                "e\":\"text\",\"text\":{f}}}]}}",
            .{
                std.json.fmt(file_thread_id, .{}),
                std.json.fmt(cwd, .{}),
                std.json.fmt(skill_path, .{}),
                std.json.fmt(prompt, .{}),
            },
        );
        defer self.allocator.free(turn_params);
        const turn = try actor.requestJson("turn/start", turn_params, null);
        defer self.allocator.free(turn);
        return extractString(
            self.allocator,
            turn,
            &.{ "turn", "id" },
        );
    }

    fn filePromptAlloc(
        self: *Registry,
        io: std.Io,
        skill_path: []const u8,
        path: []const u8,
        revision: []const u8,
        base_oid: []const u8,
        head_oid: []const u8,
        diff: []const u8,
        threads_json: []const u8,
    ) ![]u8 {
        const file_role = try readReference(self.allocator, io, skill_path, "file-review.md");
        defer self.allocator.free(file_role);
        const actions = try readReference(self.allocator, io, skill_path, "github-actions.md");
        defer self.allocator.free(actions);
        const untrusted = try readReference(
            self.allocator,
            io,
            skill_path,
            "untrusted-repository-content.md",
        );
        defer self.allocator.free(untrusted);
        const format = "{s}\n\n{s}\n\n{s}\n\nAssigned path: {s}\nRevision: {s}" ++
            "\nBase: {s}\nHead: {s}\nServer-computed canonical diff:\n{s}" ++
            "\nComplete unresolved assigned-file thread evidence:\n{s}" ++
            "\nPerform the review now; report findings, risk, proposed" ++
            " inline comments, and suspicions. Do not invoke a GitHu" ++
            "b action tool during this initial review. Do not mark v" ++
            "iewed or edit source. Wait for the human.";
        return std.fmt.allocPrint(self.allocator, format, .{
            file_role,
            actions,
            untrusted,
            path,
            revision,
            base_oid,
            head_oid,
            diff,
            threads_json,
        });
    }

    pub fn message(
        self: *Registry,
        session_id: []const u8,
        text: []const u8,
    ) !void {
        var target = try self.messageTarget(session_id);
        defer target.deinit(self.allocator);
        errdefer if (target.start_reserved) self.clearTurnStarting(session_id);
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        const first_turn = target.initial_prompt != null;
        const method = if (target.active and !first_turn) "turn/steer" else "turn/start";
        const combined = if (target.initial_prompt) |prompt| try std.fmt.allocPrint(
            self.allocator,
            "{s}\n\nThe human opened this idle session and now says" ++
                ":\n{s}",
            .{ prompt, text },
        ) else try self.allocator.dupe(u8, text);
        defer self.allocator.free(combined);
        const params = if (first_turn)
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"threadId\":{f},\"input\":[{{\"type\":\"skill\",\"n" ++
                    "ame\":\"synoptic\",\"path\":{f}}},{{\"type\":\"text\"," ++
                    "\"text\":{f}}}]}}",
                .{ std.json.fmt(
                    target.thread_id,
                    .{},
                ), std.json.fmt(target.skill_path.?, .{}), std.json.fmt(combined, .{}) },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"threadId\":{f},\"expectedTurnId\":{f},\"input\":[{" ++
                    "{\"type\":\"text\",\"text\":{f}}}]}}",
                .{ std.json.fmt(
                    target.thread_id,
                    .{},
                ), std.json.fmt(target.turn_id, .{}), std.json.fmt(combined, .{}) },
            );
        defer self.allocator.free(params);
        try self.markHumanInstruction(session_id, text);
        const response = actor.requestJson(method, params, null) catch |err| {
            if (target.active and !first_turn and err == error.RequestFailed and
                self.waitForTurnCompletion(target.turn_id, 250))
            {
                try self.reserveTurnStart(session_id);
                target.start_reserved = true;
                return self.retryCompletedSteer(
                    actor,
                    session_id,
                    target.thread_id,
                    combined,
                ) catch |retry_error| {
                    self.clearHumanInstruction(session_id);
                    return retry_error;
                };
            }
            self.clearHumanInstruction(session_id);
            return err;
        };
        defer self.allocator.free(response);
        if (!target.active or first_turn) return self.recordStartedTurn(
            session_id,
            response,
        );
    }

    fn waitForTurnCompletion(self: *Registry, turn_id: []const u8, timeout_ms: u32) bool {
        const io = self.io orelse return false;
        const deadline = std.Io.Clock.awake.now(io).nanoseconds +
            @as(i128, timeout_ms) * std.time.ns_per_ms;
        while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
            self.mutex.lock();
            const completed = self.turnCompletedLocked(turn_id);
            self.mutex.unlock();
            if (completed) return true;
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch return false;
        }
        return false;
    }

    fn retryCompletedSteer(
        self: *Registry,
        actor: *cas_runtime.Actor,
        session_id: []const u8,
        thread_id: []const u8,
        text: []const u8,
    ) !void {
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"threadId\":{f},\"input\":[{{\"type\":\"text\",\"text\":{f}}}]}}",
            .{ std.json.fmt(thread_id, .{}), std.json.fmt(text, .{}) },
        );
        defer self.allocator.free(params);
        const response = try actor.requestJson("turn/start", params, null);
        defer self.allocator.free(response);
        try self.recordStartedTurn(session_id, response);
    }

    fn recordStartedTurn(
        self: *Registry,
        session_id: []const u8,
        response: []const u8,
    ) !void {
        const next_turn = try extractString(self.allocator, response, &.{ "turn", "id" });
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*session| {
            if (!std.mem.eql(u8, session.id, session_id)) continue;
            self.allocator.free(session.turn_id);
            session.turn_id = next_turn;
            session.turn_active = !self.turnCompletedLocked(next_turn);
            session.turn_starting = false;
            if (session.pending_initial_prompt) |value| self.allocator.free(value);
            if (session.pending_skill_path) |value| self.allocator.free(value);
            session.pending_initial_prompt = null;
            session.pending_skill_path = null;
            return;
        }
        self.allocator.free(next_turn);
        return error.UnknownSession;
    }

    const MessageTarget = struct {
        thread_id: []u8,
        turn_id: []u8,
        initial_prompt: ?[]u8,
        skill_path: ?[]u8,
        active: bool,
        start_reserved: bool,

        fn deinit(self: *MessageTarget, allocator: std.mem.Allocator) void {
            allocator.free(self.thread_id);
            allocator.free(self.turn_id);
            if (self.initial_prompt) |value| allocator.free(value);
            if (self.skill_path) |value| allocator.free(value);
        }
    };

    fn messageTarget(self: *Registry, session_id: []const u8) !MessageTarget {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.synchronizing) return error.WorktreeSynchronizationActive;
        for (self.sessions.items) |*session| {
            if (!std.mem.eql(u8, session.id, session_id) or session.status == .closed) continue;
            if (session.turn_starting) return error.TurnStartAlreadyActive;
            const thread_id = try self.allocator.dupe(u8, session.thread_id);
            errdefer self.allocator.free(thread_id);
            const turn_id = try self.allocator.dupe(u8, session.turn_id);
            errdefer self.allocator.free(turn_id);
            const prompt = if (session.pending_initial_prompt) |value|
                try self.allocator.dupe(u8, value)
            else
                null;
            errdefer if (prompt) |value| self.allocator.free(value);
            const skill = if (session.pending_skill_path) |value|
                try self.allocator.dupe(u8, value)
            else
                null;
            if (session.pending_initial_prompt != null) {
                session.initial_turn_active = true;
                session.human_authority = null;
            }
            const start_reserved = !session.turn_active or
                session.pending_initial_prompt != null;
            if (start_reserved) session.turn_starting = true;
            return .{
                .thread_id = thread_id,
                .turn_id = turn_id,
                .initial_prompt = prompt,
                .skill_path = skill,
                .active = session.turn_active,
                .start_reserved = start_reserved,
            };
        }
        return error.UnknownSession;
    }

    fn reserveTurnStart(self: *Registry, session_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.synchronizing) return error.WorktreeSynchronizationActive;
        for (self.sessions.items) |*session| {
            if (!std.mem.eql(u8, session.id, session_id) or session.status == .closed) continue;
            if (session.turn_starting) return error.TurnStartAlreadyActive;
            session.turn_starting = true;
            return;
        }
        return error.UnknownSession;
    }

    fn clearTurnStarting(self: *Registry, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*session| {
            if (std.mem.eql(u8, session.id, session_id)) session.turn_starting = false;
        }
    }

    fn removeSession(self: *Registry, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items, 0..) |session, index| {
            if (!std.mem.eql(u8, session.id, session_id)) continue;
            var removed = self.sessions.orderedRemove(index);
            removed.deinit(self.allocator);
            return;
        }
    }

    pub fn interrupt(self: *Registry, session_id: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        self.mutex.lock();
        var thread_id: ?[]u8 = null;
        var turn_id: ?[]u8 = null;
        for (self.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id) and
            session.status != .closed)
        {
            thread_id = try self.allocator.dupe(u8, session.thread_id);
            turn_id = try self.allocator.dupe(u8, session.turn_id);
            break;
        };
        self.mutex.unlock();
        defer if (thread_id) |v| self.allocator.free(v);
        defer if (turn_id) |v| self.allocator.free(v);
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"threadId\":{f},\"turnId\":{f}}}",
            .{
                std.json.fmt(thread_id orelse return error.UnknownSession, .{}),
                std.json.fmt(turn_id orelse return error.NoActiveTurn, .{}),
            },
        );
        defer self.allocator.free(params);
        const response = try actor.requestJson("turn/interrupt", params, null);
        defer self.allocator.free(response);
    }

    pub fn markPathChangedAndInject(
        self: *Registry,
        path: []const u8,
        revision: []const u8,
        diff: []const u8,
    ) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        var threads: std.ArrayList([]u8) = .empty;
        defer {
            for (threads.items) |thread| self.allocator.free(thread);
            threads.deinit(self.allocator);
        }
        self.mutex.lock();
        for (self.sessions.items) |*session| {
            if (session.status != .closed and std.mem.eql(u8, session.path, path) and
                !std.mem.eql(
                    u8,
                    session.last_injected_revision,
                    revision,
                ))
            {
                if (!std.mem.eql(u8, session.revision, revision)) {
                    session.status = .stale_origin;
                }
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
            const params = try std.fmt.allocPrint(
                self.allocator,
                "{{\"threadId\":{f},\"items\":[{{\"type\":\"text\",\"te" ++
                    "xt\":{f}}}]}}",
                .{ std.json.fmt(thread, .{}), std.json.fmt(diff, .{}) },
            );
            defer self.allocator.free(params);
            const response = try actor.requestJson("thread/inject_items", params, null);
            defer self.allocator.free(response);
            self.mutex.lock();
            for (self.sessions.items) |*session| {
                if (!std.mem.eql(u8, session.thread_id, thread)) continue;
                const owned = self.allocator.dupe(u8, revision) catch {
                    self.mutex.unlock();
                    return error.OutOfMemory;
                };
                self.allocator.free(session.last_injected_revision);
                session.last_injected_revision = owned;
                break;
            }
            self.mutex.unlock();
        }
    }

    pub fn updatePrimary(self: *Registry, summary: []const u8) !void {
        const actor = &(self.actor orelse return error.AppServerUnavailable);
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"threadId\":{f},\"input\":[{{\"type\":\"text\",\"te" ++
                "xt\":{f}}}]}}",
            .{ std.json.fmt(
                self.primary_thread_id orelse return error.PrimaryNotReady,
                .{},
            ), std.json.fmt(summary, .{}) },
        );
        defer self.allocator.free(params);
        const response = try actor.requestJson("turn/start", params, null);
        defer self.allocator.free(response);
        const next_turn = try extractString(self.allocator, response, &.{ "turn", "id" });
        self.mutex.lock();
        defer self.mutex.unlock();
        self.installPrimaryTurnLocked(next_turn);
    }

    fn onNotification(context: *anyopaque, notification: cas_runtime.Notification) void {
        const self: *Registry = @ptrCast(@alignCast(context));
        self.recordCommandActivity(notification.method, notification.raw_json);
        self.mutex.lock();
        self.notification_count += 1;
        const origin_missing = self.queueNotificationVisibleLocked(notification);
        if (std.mem.eql(u8, notification.method, "turn/completed")) {
            self.recordCompletedTurnLocked(notification.raw_json);
            self.markCompletedThreadLocked(notification.raw_json);
        }
        if (origin_missing) {
            self.mutex.unlock();
            if (std.mem.eql(u8, notification.method, "turn/completed"))
                self.recordPrimaryCompletion(notification.raw_json);
            return;
        }
        self.mutex.unlock();
        if (!std.mem.eql(u8, notification.method, "turn/completed")) return;
        self.recordPrimaryCompletion(notification.raw_json);
    }

    fn queueNotificationVisibleLocked(
        self: *Registry,
        notification: cas_runtime.Notification,
    ) bool {
        if (!visibleMethod(notification.method)) return false;
        const maybe_session = self.sessionForNotificationLocked(notification.raw_json) catch
            return true;
        const session_id = maybe_session orelse return true;
        if (self.visible_events.items.len + self.authoritative_reservations >=
            max_visible_events)
        {
            self.recordVisibleOverflowLocked(session_id);
            self.allocator.free(session_id);
            return false;
        }
        const method = self.allocator.dupe(u8, notification.method) catch {
            self.allocator.free(session_id);
            return false;
        };
        const raw_json = self.allocator.dupe(u8, notification.raw_json) catch {
            self.allocator.free(session_id);
            self.allocator.free(method);
            return false;
        };
        self.visible_events.ensureTotalCapacity(
            self.allocator,
            self.visible_events.items.len + self.authoritative_reservations + 1,
        ) catch {
            self.allocator.free(session_id);
            self.allocator.free(method);
            self.allocator.free(raw_json);
            return false;
        };
        self.visible_events.appendAssumeCapacity(.{
            .session_id = session_id,
            .method = method,
            .raw_json = raw_json,
        });
        return false;
    }

    fn recordVisibleOverflowLocked(self: *Registry, session_id: []const u8) void {
        self.visible_overflow_count +|= 1;
        if (self.visible_overflow_session_id != null) return;
        self.visible_overflow_session_id = self.allocator.dupe(u8, session_id) catch null;
    }

    fn queueOverflowWarningLocked(self: *Registry) void {
        const session_id = self.visible_overflow_session_id orelse return;
        if (self.visible_events.items.len + self.authoritative_reservations >=
            max_visible_events) return;
        const raw = std.fmt.allocPrint(
            self.allocator,
            "{{\"reason\":\"VisibleEventOverflow\",\"dropped\":{d}}}",
            .{self.visible_overflow_count},
        ) catch return;
        const method = self.allocator.dupe(u8, "warning") catch {
            self.allocator.free(raw);
            return;
        };
        self.visible_events.append(self.allocator, .{
            .session_id = session_id,
            .method = method,
            .raw_json = raw,
        }) catch {
            self.allocator.free(method);
            self.allocator.free(raw);
            return;
        };
        self.visible_overflow_session_id = null;
        self.visible_overflow_count = 0;
    }

    fn recordCompletedTurnLocked(self: *Registry, raw_json: []const u8) void {
        const completed = extractString(
            self.allocator,
            raw_json,
            &.{ "params", "turn", "id" },
        ) catch return;
        defer self.allocator.free(completed);
        if (self.turnCompletedLocked(completed)) return;
        const owned = self.allocator.dupe(u8, completed) catch return;
        if (self.completed_turn_ids.items.len >= 512) {
            self.allocator.free(self.completed_turn_ids.orderedRemove(0));
            self.completed_turn_ids.appendAssumeCapacity(owned);
            return;
        }
        self.completed_turn_ids.append(self.allocator, owned) catch self.allocator.free(owned);
    }

    fn markCompletedThreadLocked(self: *Registry, raw_json: []const u8) void {
        const thread = extractString(
            self.allocator,
            raw_json,
            &.{ "params", "threadId" },
        ) catch return;
        defer self.allocator.free(thread);
        const turn = extractString(
            self.allocator,
            raw_json,
            &.{ "params", "turn", "id" },
        ) catch return;
        defer self.allocator.free(turn);
        for (self.sessions.items) |*session| {
            if (session.status == .closed or !std.mem.eql(u8, session.thread_id, thread) or
                !std.mem.eql(u8, session.turn_id, turn)) continue;
            session.initial_turn_active = false;
            session.turn_active = false;
        }
    }

    fn turnCompletedLocked(self: *Registry, turn_id: []const u8) bool {
        for (self.completed_turn_ids.items) |id| if (std.mem.eql(u8, id, turn_id)) return true;
        return false;
    }

    fn recordPrimaryCompletion(self: *Registry, raw_json: []const u8) void {
        const turn_id = extractString(
            self.allocator,
            raw_json,
            &.{ "params", "turn", "id" },
        ) catch return;
        const thread_id = extractString(
            self.allocator,
            raw_json,
            &.{ "params", "threadId" },
        ) catch {
            self.allocator.free(turn_id);
            return;
        };
        const status_text = extractString(
            self.allocator,
            raw_json,
            &.{ "params", "turn", "status" },
        ) catch {
            self.allocator.free(turn_id);
            return;
        };
        defer self.allocator.free(status_text);
        defer self.allocator.free(thread_id);
        const status = primaryTerminalStatus(status_text);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.primary_thread_id) |primary| if (std.mem.eql(u8, primary, thread_id)) {
            if (self.primary_start_turn_id == null or
                !std.mem.eql(u8, self.primary_start_turn_id.?, turn_id))
            {
                self.cachePrimaryTerminalLocked(.{ .turn_id = turn_id, .status = status });
                return;
            }
            self.applyPrimaryTerminalLocked(.{ .turn_id = turn_id, .status = status });
            return;
        };
        self.allocator.free(turn_id);
    }

    fn primaryTerminalStatus(status: []const u8) PrimaryTerminalStatus {
        if (std.mem.eql(u8, status, "completed")) return .completed;
        if (std.mem.eql(u8, status, "interrupted")) return .interrupted;
        return .failed;
    }

    fn installPrimaryTurnLocked(self: *Registry, turn_id: []u8) void {
        if (self.primary_start_turn_id) |old| self.allocator.free(old);
        self.primary_start_turn_id = turn_id;
        for (self.primary_terminals.items, 0..) |terminal, index| {
            if (!std.mem.eql(u8, terminal.turn_id, turn_id)) continue;
            self.applyPrimaryTerminalLocked(self.primary_terminals.orderedRemove(index));
            return;
        }
        self.primary_turn_active = self.latest_primary_turn_id == null or !std.mem.eql(
            u8,
            self.latest_primary_turn_id.?,
            turn_id,
        );
    }

    fn cachePrimaryTerminalLocked(self: *Registry, terminal: PrimaryTerminal) void {
        for (self.primary_terminals.items) |*existing| {
            if (!std.mem.eql(u8, existing.turn_id, terminal.turn_id)) continue;
            existing.status = terminal.status;
            self.allocator.free(terminal.turn_id);
            return;
        }
        if (self.primary_terminals.items.len >= 32) {
            self.allocator.free(self.primary_terminals.orderedRemove(0).turn_id);
        }
        self.primary_terminals.append(self.allocator, terminal) catch
            self.allocator.free(terminal.turn_id);
    }

    fn applyPrimaryTerminalLocked(self: *Registry, terminal: PrimaryTerminal) void {
        self.primary_turn_active = false;
        self.primary_failure_reported = false;
        if (terminal.status != .completed) {
            self.primary_failure_status = if (terminal.status == .interrupted)
                .interrupted
            else
                .failed;
            self.allocator.free(terminal.turn_id);
            return;
        }
        if (self.latest_primary_turn_id) |old| self.allocator.free(old);
        self.latest_primary_turn_id = terminal.turn_id;
        self.primary_failure_status = null;
    }

    fn sessionForNotificationLocked(self: *Registry, raw: []const u8) !?[]u8 {
        const thread = extractString(self.allocator, raw, &.{ "params", "threadId" }) catch
            return null;
        defer self.allocator.free(thread);
        for (self.sessions.items) |session| if (session.status != .closed and
            std.mem.eql(u8, session.thread_id, thread))
            return @as(?[]u8, try self.allocator.dupe(u8, session.id));
        return null;
    }

    fn onServerRequest(
        context: *anyopaque,
        request: cas_runtime.ServerRequest,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const self: *Registry = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, request.method, "item/commandExecution/requestApproval") or
            std.mem.eql(
                u8,
                request.method,
                "item/permissions/requestApproval",
            )) return self.handleApprovalRequest(request, allocator);
        if (std.mem.eql(
            u8,
            request.method,
            "item/fileChange/requestApproval",
        )) return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        if (std.mem.eql(u8, request.method, "applyPatchApproval") or std.mem.eql(
            u8,
            request.method,
            "execCommandApproval",
        )) return allocator.dupe(u8, "{\"decision\":{\"denied\":{\"rejection\":\"Synoptic ne" ++
            "ver authorizes direct file changes or deprecated appro" ++
            "val requests\"}}}");
        if (std.mem.eql(u8, request.method, "item/tool/call")) {
            return self.handleToolCall(request.raw_json, allocator);
        }
        if (std.mem.eql(u8, request.method, "item/tool/requestUserInput")) {
            return allocator.dupe(u8, "{\"answers\":{}}");
        }
        if (std.mem.eql(u8, request.method, "mcpServer/elicitation/request")) {
            return allocator.dupe(
                u8,
                "{\"action\":\"decline\",\"content\":null,\"_meta\":null}",
            );
        }
        if (std.mem.eql(u8, request.method, "currentTime/read")) {
            const io = self.io orelse return error.AppServerUnavailable;
            return std.fmt.allocPrint(
                allocator,
                "{{\"currentTimeAt\":{d}}}",
                .{@as(i64, @intCast(@divFloor(
                    std.Io.Clock.real.now(io).nanoseconds,
                    std.time.ns_per_s,
                )))},
            );
        }
        if (std.mem.eql(u8, request.method, "account/chatgptAuthTokens/refresh")) {
            return error.ChatGptAuthTokensRefreshProviderUnavailable;
        }
        if (std.mem.eql(u8, request.method, "attestation/generate")) {
            return error.AttestationProviderUnavailable;
        }
        return error.UnsupportedServerRequest;
    }

    fn handleToolCall(
        self: *Registry,
        raw_json: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch
            return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        defer parsed.deinit();
        if (parsed.value != .object) return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        const params = parsed.value.object.get("params") orelse
            return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        if (params != .object) return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        const tool = params.object.get("tool") orelse
            return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        if (tool != .string) return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        if (std.mem.eql(u8, tool.string, "synoptic.search_unresolved_threads"))
            return self.searchThreads(raw_json, allocator);
        const event_kind = authoritativeToolEventKind(tool.string) orelse
            return allocator.dupe(u8, "{\"decision\":\"decline\"}");
        return self.handleAuthoritativeTool(raw_json, event_kind, allocator);
    }

    fn handleAuthoritativeTool(
        self: *Registry,
        raw_json: []const u8,
        event_kind: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const origin_thread = extractString(
            self.allocator,
            raw_json,
            &.{ "params", "threadId" },
        ) catch return allocator.dupe(u8, missing_origin_response);
        defer self.allocator.free(origin_thread);
        const requested = requestedAuthority(
            self.allocator,
            event_kind,
            raw_json,
        ) orelse return allocator.dupe(u8, unsupported_action_response);
        self.mutex.lock();
        const reserved = self.reserveAuthoritativeLocked(
            origin_thread,
            requested,
            event_kind,
            raw_json,
            allocator,
        ) catch |err| {
            self.mutex.unlock();
            return authoritativeAdmissionFailureAlloc(allocator, err);
        };
        self.mutex.unlock();
        const admission = reserved orelse
            return allocator.dupe(u8, missing_authority_response);
        defer self.allocator.free(admission.session_id);
        return self.executeAuthoritative(
            admission.handler,
            admission.visible_event,
            event_kind,
            raw_json,
            admission.session_id,
            allocator,
        );
    }

    fn reserveAuthoritativeLocked(
        self: *Registry,
        origin_thread: []const u8,
        requested: HumanAuthority,
        event_kind: []const u8,
        raw_json: []const u8,
        allocator: std.mem.Allocator,
    ) !?ReservedAuthoritative {
        if (self.synchronizing) return error.WorktreeSynchronizationActive;
        for (self.sessions.items) |*session| {
            const eligible = std.mem.eql(u8, session.thread_id, origin_thread) and
                session.status != .closed and !session.initial_turn_active and
                authorityCovers(session.human_authority, requested);
            if (!eligible) continue;
            if (std.mem.eql(u8, event_kind, "file.complete.requested") and
                session.status != .current) return error.StaleOriginSession;
            if (std.mem.eql(u8, event_kind, "action.prepared")) {
                self.validatePreparedAction(allocator, raw_json, session.path) catch
                    return error.UnsupportedAction;
            }
            if (self.visible_events.items.len + self.authoritative_reservations >=
                max_visible_events) return error.EvidenceUnavailable;
            const handler = self.authoritative_tool_handler orelse
                return error.EvidenceUnavailable;
            const event = try self.makeVisibleEvent(session.id, event_kind, raw_json);
            errdefer event.deinit(self.allocator);
            try self.visible_events.ensureTotalCapacity(
                self.allocator,
                self.visible_events.items.len + self.authoritative_reservations + 1,
            );
            const session_id = try self.allocator.dupe(u8, session.id);
            self.authoritative_reservations += 1;
            return .{ .session_id = session_id, .visible_event = event, .handler = handler };
        }
        return null;
    }

    fn validatePreparedAction(
        self: *Registry,
        allocator: std.mem.Allocator,
        raw_json: []const u8,
        session_path: []const u8,
    ) !void {
        _ = self;
        const decoded = try action_tools.decodePreparedAction(allocator, raw_json);
        defer decoded.deinit(allocator);
        try action_tools.validateAgainstSession(decoded, session_path);
    }

    fn executeAuthoritative(
        self: *Registry,
        handler: AuthoritativeToolHandler,
        visible_event: VisibleEvent,
        event_kind: []const u8,
        raw_json: []const u8,
        session_id: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var event = visible_event;
        var event_transferred = false;
        defer if (!event_transferred) event.deinit(self.allocator);
        handler.handle(
            handler.context,
            event_kind,
            raw_json,
            session_id,
        ) catch |err| {
            self.releaseAuthoritativeReservation();
            return authoritativeFailureAlloc(allocator, err);
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        self.visible_events.appendAssumeCapacity(event);
        event_transferred = true;
        self.authoritative_reservations -= 1;
        for (self.sessions.items) |*session| if (std.mem.eql(
            u8,
            session.id,
            session_id,
        )) {
            session.human_authority = null;
            return allocator.dupe(u8, accepted_domain_response);
        };
        return allocator.dupe(u8, missing_origin_response);
    }

    fn releaseAuthoritativeReservation(self: *Registry) void {
        self.mutex.lock();
        self.authoritative_reservations -= 1;
        self.mutex.unlock();
    }

    fn handleApprovalRequest(
        self: *Registry,
        request: cas_runtime.ServerRequest,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        if (request.raw_json.len > max_approval_request_bytes) {
            return declineAlloc(allocator, request.method);
        }
        if (!std.mem.eql(u8, request.method, "item/commandExecution/requestApproval")) {
            return declineAlloc(allocator, request.method);
        }
        const io = self.io orelse return declineAlloc(allocator, request.method);
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            request.raw_json,
            .{},
        ) catch return declineAlloc(allocator, request.method);
        defer parsed.deinit();
        if (parsed.value != .object) return declineAlloc(allocator, request.method);
        const params = parsed.value.object.get("params") orelse
            return declineAlloc(allocator, request.method);
        if (params != .object) return declineAlloc(allocator, request.method);
        const thread_value = params.object.get("threadId") orelse
            return declineAlloc(allocator, request.method);
        if (thread_value != .string) return declineAlloc(allocator, request.method);

        const approval_id = try self.enqueueApproval(
            allocator,
            request,
            thread_value.string,
            params.object,
        );
        defer self.allocator.free(approval_id);
        return self.waitForApproval(
            io,
            allocator,
            approval_id,
            request.method,
            request.deadline_ms,
        );
    }

    fn enqueueApproval(
        self: *Registry,
        allocator: std.mem.Allocator,
        request: cas_runtime.ServerRequest,
        thread_id: []const u8,
        params: std.json.ObjectMap,
    ) ![]u8 {
        self.mutex.lock();
        var approval = self.prepareApprovalLocked(
            thread_id,
            request,
            params,
        ) catch |err| {
            self.mutex.unlock();
            return switch (err) {
                error.MalformedApprovalRequest,
                error.UnknownApprovalOwner,
                error.ApprovalCapacityExceeded,
                error.WorktreeSynchronizationActive,
                => declineAlloc(allocator, request.method),
                else => err,
            };
        };
        var approval_transferred = false;
        errdefer if (!approval_transferred) approval.deinit(self.allocator);
        const approval_id = self.allocator.dupe(u8, approval.id) catch |err| {
            self.mutex.unlock();
            return err;
        };
        const requested_payload = self.approvalRequestedPayloadLocked(approval) catch |err| {
            self.mutex.unlock();
            return err;
        };
        defer self.allocator.free(requested_payload);
        self.appendVisibleLocked(
            approval.session_id,
            "approval.requested",
            requested_payload,
        ) catch |err| {
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
        return approval_id;
    }

    fn prepareApprovalLocked(
        self: *Registry,
        thread_id: []const u8,
        request: cas_runtime.ServerRequest,
        params: std.json.ObjectMap,
    ) !PendingApproval {
        if (self.synchronizing) return error.WorktreeSynchronizationActive;
        var owner: ?[]const u8 = null;
        var owner_count: usize = 0;
        for (self.sessions.items) |session| {
            if (session.status == .closed or !std.mem.eql(u8, session.thread_id, thread_id)) {
                continue;
            }
            owner = session.id;
            owner_count += 1;
        }
        const matches_primary = self.primary_thread_id != null and std.mem.eql(
            u8,
            self.primary_thread_id.?,
            thread_id,
        );
        const primary_owner = owner_count == 0 and matches_primary;
        if ((owner_count == 1 and matches_primary) or (owner_count != 1 and !primary_owner)) {
            return error.UnknownApprovalOwner;
        }
        self.pruneApprovalsLocked();
        if (self.approvals.items.len >= max_approval_records or
            self.visible_events.items.len >= max_visible_events)
        {
            return error.ApprovalCapacityExceeded;
        }
        return self.makeApprovalLocked(
            if (primary_owner) null else owner.?,
            thread_id,
            request.method,
            request.raw_json,
            params,
        );
    }

    fn waitForApproval(
        self: *Registry,
        io: std.Io,
        allocator: std.mem.Allocator,
        approval_id: []const u8,
        method: []const u8,
        request_deadline_ms: i64,
    ) ![]u8 {
        const started = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
        const local_deadline = @min(
            request_deadline_ms -| approval_response_margin_ms,
            started + @as(i64, self.approval_wait_timeout_ms),
        );
        while (true) { // tiger: event-loop -- bounded by owner state or deadline.
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
                if (now >= local_deadline) {
                    pending.result_json = self.allocator.dupe(
                        u8,
                        pending.decline_result_json,
                    ) catch |err| {
                        self.mutex.unlock();
                        return err;
                    };
                    pending.state = .expired;
                    self.queueApprovalResolvedLocked(
                        pending.*,
                        "\"decline\"",
                        "timeout",
                    ) catch |ignored_error| {
                        switch (ignored_error) {
                            else => {},
                        }
                    };
                    const owned = allocator.dupe(u8, pending.result_json.?) catch |err| {
                        self.mutex.unlock();
                        return err;
                    };
                    self.mutex.unlock();
                    return owned;
                }
                self.mutex.unlock();
                std.Io.sleep(io, .fromMilliseconds(2), .awake) catch return allocator.dupe(
                    u8,
                    declineResult(method),
                );
                break;
            };
            if (!found) {
                self.mutex.unlock();
                return allocator.dupe(u8, declineResult(method));
            }
        }
    }

    fn makeApprovalLocked(
        self: *Registry,
        session_id: ?[]const u8,
        thread_id: []const u8,
        method: []const u8,
        raw: []const u8,
        params: std.json.ObjectMap,
    ) !PendingApproval {
        const id = try std.fmt.allocPrint(
            self.allocator,
            "apr-{d}",
            .{self.next_approval_id},
        );
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
        try self.populateApprovalDecisions(&approval, method, params);
        return approval;
    }

    fn populateApprovalDecisions(
        self: *Registry,
        approval: *PendingApproval,
        method: []const u8,
        params: std.json.ObjectMap,
    ) !void {
        if (std.mem.eql(u8, method, "item/commandExecution/requestApproval")) {
            const available = params.get("availableDecisions");
            if (available) |choices| switch (choices) {
                .null => try self.appendStringDecision(
                    &approval.decisions,
                    "decline",
                    true,
                    null,
                ),
                .array => |array| {
                    if (array.items.len == 0 or array.items.len > max_approval_decisions)
                        return error.MalformedApprovalRequest;
                    for (array.items) |choice| {
                        try self.appendCommandDecision(&approval.decisions, choice);
                    }
                },
                else => return error.MalformedApprovalRequest,
            } else try self.appendStringDecision(
                &approval.decisions,
                "decline",
                true,
                null,
            );
        } else {
            const requested = params.get("permissions") orelse
                return error.MalformedApprovalRequest;
            if (requested != .object) return error.MalformedApprovalRequest;
            const requested_json = try stringifyValueAlloc(self.allocator, requested);
            defer self.allocator.free(requested_json);
            const accept = try std.fmt.allocPrint(
                self.allocator,
                "{{\"permissions\":{s},\"scope\":\"turn\"}}",
                .{requested_json},
            );
            defer self.allocator.free(accept);
            const session = try std.fmt.allocPrint(
                self.allocator,
                "{{\"permissions\":{s},\"scope\":\"session\"}}",
                .{requested_json},
            );
            defer self.allocator.free(session);
            try self.appendStringDecision(&approval.decisions, "accept", false, accept);
            try self.appendStringDecision(&approval.decisions, "acceptForSession", false, session);
            try self.appendStringDecision(
                &approval.decisions,
                "decline",
                false,
                "{\"permissions\":{},\"scope\":\"turn\"}",
            );
        }
    }

    fn appendCommandDecision(
        self: *Registry,
        decisions: *std.ArrayList(OfferedDecision),
        value: std.json.Value,
    ) !void {
        const choice = try stringifyValueAlloc(self.allocator, value);
        errdefer self.allocator.free(choice);
        const result = try std.fmt.allocPrint(
            self.allocator,
            "{{\"decision\":{s}}}",
            .{choice},
        );
        errdefer self.allocator.free(result);
        try decisions.append(self.allocator, .{ .choice_json = choice, .result_json = result });
    }

    fn appendStringDecision(
        self: *Registry,
        decisions: *std.ArrayList(OfferedDecision),
        choice: []const u8,
        wrap_command: bool,
        result_json: ?[]const u8,
    ) !void {
        const choice_json = try std.fmt.allocPrint(
            self.allocator,
            "{f}",
            .{std.json.fmt(choice, .{})},
        );
        errdefer self.allocator.free(choice_json);
        const result = if (result_json) |value|
            try self.allocator.dupe(u8, value)
        else if (wrap_command)
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"decision\":{s}}}",
                .{choice_json},
            )
        else
            return error.MissingApprovalResult;
        errdefer self.allocator.free(result);
        try decisions.append(
            self.allocator,
            .{ .choice_json = choice_json, .result_json = result },
        );
    }

    fn approvalRequestedPayloadLocked(self: *Registry, approval: PendingApproval) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const approval_format = "{{\"approvalId\":{f},\"ownerKind\":{f}," ++
            "\"sessionId\":{f},\"threadId\":{f},\"method\":{f}," ++
            "\"request\":{s},\"decisions\":[";
        try out.writer.print(approval_format, .{ std.json.fmt(approval.id, .{}), std.json.fmt(
            if (approval.session_id == null) "primary" else "file",
            .{},
        ), std.json.fmt(approval.session_id, .{}), std.json.fmt(
            approval.thread_id,
            .{},
        ), std.json.fmt(approval.method, .{}), approval.request_json });
        for (approval.decisions.items, 0..) |decision, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(decision.choice_json);
        }
        try out.writer.writeAll("]}");
        return out.toOwnedSlice();
    }

    fn queueApprovalResolvedLocked(
        self: *Registry,
        approval: PendingApproval,
        choice_json: []const u8,
        reason: []const u8,
    ) !void {
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"approvalId\":{f},\"ownerKind\":{f},\"sessionId\":{" ++
                "f},\"decision\":{s},\"reason\":{f}}}",
            .{ std.json.fmt(approval.id, .{}), std.json.fmt(
                if (approval.session_id == null) "primary" else "file",
                .{},
            ), std.json.fmt(approval.session_id, .{}), choice_json, std.json.fmt(reason, .{}) },
        );
        defer self.allocator.free(payload);
        try self.appendVisibleLocked(approval.session_id, "approval.resolved", payload);
    }

    fn declineApprovalsLocked(
        self: *Registry,
        session_id: ?[]const u8,
        state: ApprovalState,
        reason: []const u8,
    ) void {
        for (self.approvals.items) |*approval| {
            const wrong_session = session_id != null and (approval.session_id == null or
                !std.mem.eql(u8, approval.session_id.?, session_id.?));
            if (approval.state != .pending or wrong_session) continue;
            approval.result_json = self.allocator.dupe(u8, approval.decline_result_json) catch
                continue;
            approval.state = state;
            self.queueApprovalResolvedLocked(
                approval.*,
                "\"decline\"",
                reason,
            ) catch |ignored_error| {
                switch (ignored_error) {
                    else => {},
                }
            };
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

    fn appendVisibleLocked(
        self: *Registry,
        session_id: ?[]const u8,
        method: []const u8,
        raw_json: []const u8,
    ) !void {
        if (self.visible_events.items.len + self.authoritative_reservations >=
            max_visible_events)
        {
            return error.VisibleEventLimitExceeded;
        }
        try self.visible_events.ensureTotalCapacity(
            self.allocator,
            self.visible_events.items.len + self.authoritative_reservations + 1,
        );
        const event = try self.makeVisibleEvent(session_id, method, raw_json);
        self.visible_events.appendAssumeCapacity(event);
    }

    fn makeVisibleEvent(
        self: *Registry,
        session_id: ?[]const u8,
        method: []const u8,
        raw_json: []const u8,
    ) !VisibleEvent {
        const owned_session = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_session) |value| self.allocator.free(value);
        const owned_method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned_method);
        const owned_json = try self.allocator.dupe(u8, raw_json);
        errdefer self.allocator.free(owned_json);
        return .{ .session_id = owned_session, .method = owned_method, .raw_json = owned_json };
    }

    fn recordCommandActivity(self: *Registry, method: []const u8, raw: []const u8) void {
        const started = std.mem.eql(u8, method, "item/started");
        const completed = std.mem.eql(u8, method, "item/completed");
        if (!started and !completed) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return;
        defer parsed.deinit();
        const params = if (parsed.value == .object) parsed.value.object.get("params") orelse
            return else return;
        const item = if (params == .object) params.object.get("item") orelse return else return;
        if (item != .object) return;
        const kind = item.object.get("type") orelse return;
        if (kind != .string or (!std.mem.eql(u8, kind.string, "commandExecution") and
            !std.mem.eql(u8, kind.string, "command_execution"))) return;
        const id = item.object.get("id") orelse return;
        if (id != .string) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (
            self.active_command_ids.items,
            0..,
        ) |existing, index| if (std.mem.eql(u8, existing, id.string)) {
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
        if (self.evidence == null) return allocator.dupe(u8, evidence_unavailable_response);
        const generation = &self.evidence.?;
        for (self.sessions.items) |session| if (std.mem.eql(
            u8,
            session.thread_id,
            thread_id.string,
        )) {
            assigned = session.path;
            break;
        };
        const assigned_path = assigned orelse return error.UnknownSession;
        const args = params.object.get("arguments") orelse return error.MalformedToolCall;
        const query_value = if (args == .object) args.object.get("query") else null;
        const query: ?[]const u8 = if (query_value != null and query_value.? == .string)
            query_value.?.string
        else
            null;
        const whole_value = if (args == .object)
            args.object.get("includeWholePullRequest")
        else
            null;
        const whole = whole_value != null and whole_value.? == .bool and whole_value.?.bool;
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);
        if (args == .object) if (args.object.get("paths")) |value| {
            if (value == .array) for (value.array.items) |path| {
                if (path == .string) try paths.append(allocator, path.string);
            };
        };
        const evidence = try generation.unresolvedThreadsJsonAlloc(
            allocator,
            assigned_path,
            query,
            paths.items,
            whole,
        );
        defer allocator.free(evidence);
        return std.fmt.allocPrint(
            allocator,
            "{{\"contentItems\":[{{\"type\":\"inputText\",\"text\":" ++
                "{f}}}],\"success\":true}}",
            .{std.json.fmt(evidence, .{})},
        );
    }

    fn extractString(
        allocator: std.mem.Allocator,
        raw: []const u8,
        path: []const []const u8,
    ) ![]u8 {
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

fn readReference(
    allocator: std.mem.Allocator,
    io: std.Io,
    skill_path: []const u8,
    name: []const u8,
) ![]u8 {
    const root = std.fs.path.dirname(skill_path) orelse return error.InvalidSkillPath;
    const path = try std.fs.path.join(allocator, &.{ root, "references", name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

fn visibleMethod(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "turn/") or
        std.mem.startsWith(u8, method, "item/") or
        std.mem.indexOf(
            u8,
            method,
            "delta",
        ) != null;
}
fn classifyHumanInstruction(text: []const u8) ?HumanAuthority {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (startsAnyIgnoreCase(trimmed, &.{
        "do not ", "don't ", "please do not ", "please don't ", "never ",
    }) or containsAnyIgnoreCase(trimmed, &.{
        "i don't want you to ", "i do not want you to ",
    })) return null;
    const directive = directiveBody(trimmed);
    if (exactDirective(directive, &.{
        "complete this file",
        "complete the file review",
        "mark this file reviewed",
        "mark the file reviewed",
        "mark this file as reviewed",
        "mark the file as reviewed",
    })) return .complete;
    if (exactDirective(directive, &.{
        "close this session", "close the session", "close session",
        "close this tab",     "close the tab",
    })) return .close;
    if (exactDirective(directive, &.{ "take the action", "prepare the action" })) {
        return .github_any;
    }
    const action_object = actionObjectAfterVerb(directive, &.{
        "add",    "remove", "set",     "request", "submit",  "dismiss", "change", "execute",
        "update", "close",  "reopen",  "merge",   "resolve", "reply",   "delete", "unmark",
        "mark",   "post",   "publish", "prepare",
    });
    const github_target = action_object != null and containsAnyIgnoreCase(action_object.?, &.{
        "label",   "reviewer", "assignee", "milestone", "pull request",  "this pr",
        "the pr",  "pr #",     "comment",  "thread",    "github review", "mark viewed",
        "graphql",
    });
    if (github_target) return .github_any;
    return null;
}

fn actionObjectAfterVerb(text: []const u8, verbs: []const []const u8) ?[]const u8 {
    for (verbs) |verb| {
        if (text.len <= verb.len or !std.ascii.eqlIgnoreCase(text[0..verb.len], verb) or
            std.ascii.isAlphanumeric(text[verb.len])) continue;
        const object = std.mem.trim(u8, text[verb.len..], " \t\r\n.!;?");
        if (startsWordAnyIgnoreCase(object, &.{ "me", "us", "you", "your" })) return null;
        return object;
    }
    return null;
}

fn directiveBody(text: []const u8) []const u8 {
    var candidate = std.mem.trim(u8, text, " \t\r\n.!;?");
    const prefixes = [_][]const u8{
        "please ", "can you ", "could you ", "would you ", "will you ",
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (prefixes) |prefix| if (candidate.len >= prefix.len and
            std.ascii.eqlIgnoreCase(candidate[0..prefix.len], prefix))
        {
            candidate = std.mem.trim(u8, candidate[prefix.len..], " \t\r\n.!;?");
            changed = true;
            break;
        };
    }
    return candidate;
}

fn startsWordAnyIgnoreCase(text: []const u8, words: []const []const u8) bool {
    for (words) |word| {
        if (text.len < word.len or !std.ascii.eqlIgnoreCase(text[0..word.len], word)) continue;
        if (text.len == word.len or !std.ascii.isAlphanumeric(text[word.len])) return true;
    }
    return false;
}

fn exactDirective(text: []const u8, directives: []const []const u8) bool {
    var candidate = std.mem.trim(u8, text, " \t\r\n.!;");
    if (candidate.len >= "please ".len and
        std.ascii.eqlIgnoreCase(candidate[0.."please ".len], "please "))
    {
        candidate = std.mem.trim(u8, candidate["please ".len..], " \t\r\n.!;");
    }
    for (directives) |directive| {
        if (std.ascii.eqlIgnoreCase(candidate, directive)) return true;
    }
    return false;
}

fn startsAnyIgnoreCase(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (text.len >= needle.len and std.ascii.eqlIgnoreCase(text[0..needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn containsAnyIgnoreCase(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (containsIgnoreCase(text, needle)) return true;
    return false;
}
fn requestedAuthority(
    allocator: std.mem.Allocator,
    event_kind: []const u8,
    raw: []const u8,
) ?HumanAuthority {
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
    return value == requested or
        (value == .github_any and requested != .complete and requested != .close);
}

fn declineResult(method: []const u8) []const u8 {
    return if (std.mem.eql(u8, method, "item/permissions/requestApproval"))
        "{\"permissions\":{},\"scope\":\"turn\"}"
    else
        "{\"decision\":\"decline\"}";
}

fn declineAlloc(allocator: std.mem.Allocator, method: []const u8) ![]u8 {
    return allocator.dupe(u8, declineResult(method));
}

fn stringifyValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(
        value,
        .{},
        &out.writer,
    );
    return out.toOwnedSlice();
}
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i .. i +
        needle.len], needle)) return true;
    return false;
}

fn authoritativeFailureAlloc(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"contentItems\":[{{\"type\":\"inputText\",\"text\":\"Synoptic domain " ++
            "action failed: {s}\"}}],\"success\":false}}",
        .{@errorName(err)},
    );
}

fn authoritativeAdmissionFailureAlloc(
    allocator: std.mem.Allocator,
    err: anyerror,
) ![]u8 {
    return switch (err) {
        error.StaleOriginSession => allocator.dupe(u8, stale_completion_response),
        error.UnsupportedAction => allocator.dupe(u8, unsupported_action_response),
        error.EvidenceUnavailable => allocator.dupe(u8, evidence_unavailable_response),
        else => err,
    };
}

test "file selection remains gated without completed primary" {
    const registry = Registry{ .allocator = std.testing.allocator };
    try std.testing.expect(registry.latest_primary_turn_id == null);
}

test "session capacity is enforced before any app-server fork" {
    var registry = Registry{
        .allocator = std.testing.allocator,
        .max_sessions = 0,
    };
    defer registry.deinit();
    try std.testing.expectError(
        error.SessionLimitExceeded,
        registry.openFile(
            std.testing.io,
            ".",
            "a.zig",
            "r1",
            "base",
            "head",
            "@@ -1 +1 @@\n-a\n+b\n",
            "[]",
            "/tmp/SKILL.md",
            true,
        ),
    );
}

test "file admission reserves capacity and closed sessions release it" {
    var registry = Registry{
        .allocator = std.testing.allocator,
        .max_sessions = 1,
    };
    defer registry.deinit();
    const first = try registry.admitFile("a.zig", "r1");
    try std.testing.expect(first == .reserved);
    try std.testing.expectError(
        error.SessionOpenInProgress,
        registry.admitFile("a.zig", "r1"),
    );
    try std.testing.expectError(
        error.SessionLimitExceeded,
        registry.admitFile("b.zig", "r1"),
    );
    registry.releaseFileAdmission("a.zig", "r1");
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    try registry.closeSession("ses-1");
    const reopened = try registry.admitFile("b.zig", "r1");
    try std.testing.expect(reopened == .reserved);
    registry.releaseFileAdmission("b.zig", "r1");
}

test "opening session is mapped but not reusable until activation" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-prior", "file-prior");
    registry.sessions.items[0].turn_active = false;
    const admission = try registry.admitFile("a.zig", "r2");
    try std.testing.expect(admission == .reserved);
    defer registry.releaseFileAdmission("a.zig", "r2");
    const opening_id = try registry.registerFileSession(
        "file-current",
        "a.zig",
        "r2",
        "prompt",
        "/skill/SKILL.md",
        true,
    );
    defer std.testing.allocator.free(opening_id);
    try std.testing.expect(registry.sessions.items[1].opening);
    try std.testing.expectEqual(SessionStatus.current, registry.sessions.items[0].status);
    Registry.onNotification(&registry, .{
        .method = "item/agentMessage/delta",
        .raw_json = "{\"params\":{\"threadId\":\"file-current\",\"delta\":\"opening visible\"}}",
    });
    const opening_event = (try registry.peekVisible(std.testing.allocator)).?;
    defer opening_event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(opening_id, opening_event.session_id.?);
    try std.testing.expectEqualStrings("item/agentMessage/delta", opening_event.method);
    try registry.acknowledgeVisible();
    try std.testing.expectError(
        error.SessionOpenInProgress,
        registry.admitFile("a.zig", "r2"),
    );

    registry.recordCompletedTurnLocked(
        "{\"params\":{\"threadId\":\"file-current\",\"turn\":{\"id\":\"turn-current\"}}}",
    );
    try registry.activateOpeningSession(opening_id, "turn-current");
    try std.testing.expect(!registry.sessions.items[1].opening);
    try std.testing.expect(!registry.sessions.items[1].turn_active);
    try std.testing.expectEqual(SessionStatus.stale_origin, registry.sessions.items[0].status);
    const reused = try registry.admitFile("a.zig", "r2");
    try std.testing.expect(reused == .reused);
    std.testing.allocator.free(reused.reused);
}

test "completed turn identity cache rolls after its bounded capacity" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    for (0..513) |index| {
        const raw = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"params\":{{\"turn\":{{\"id\":\"turn-{d}\"}}}}}}",
            .{index},
        );
        defer std.testing.allocator.free(raw);
        registry.recordCompletedTurnLocked(raw);
    }
    try std.testing.expectEqual(@as(usize, 512), registry.completed_turn_ids.items.len);
    try std.testing.expect(!registry.turnCompletedLocked("turn-0"));
    try std.testing.expect(registry.turnCompletedLocked("turn-512"));
}

test "session context dynamic tool namespace exposes the exact authoritative surface" {
    const expected = [_][]const u8{
        "search_unresolved_threads",
        "prepare_github_action",
        "complete_file_review",
        "close_session",
        "\"required\":[\"slot\",\"kind\",\"effectSummary\",\"payload\"]",
    };
    inline for (expected) |needle| try std.testing.expect(std.mem.indexOf(
        u8,
        dynamic_tools_json,
        needle,
    ) != null);
}

test "worktree integrity synchronization waits for commands and times out bounded" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    const command_started = "{\"params\":{\"item\":{\"id\":\"cmd-1\",\"type\":\"com" ++
        "mandExecution\"}}}";
    registry.recordCommandActivity("item/started", command_started);
    try std.testing.expectEqual(@as(usize, 1), registry.activeCommandCount());
    try std.testing.expectError(
        error.ActiveReviewCommandsTimeout,
        registry.beginSynchronization(std.testing.io, 20),
    );
    try std.testing.expect(!registry.synchronizing);
    const command_completed = "{\"params\":{\"item\":{\"id\":\"cmd-1\",\"type\":\"com" ++
        "mandExecution\"}}}";
    registry.recordCommandActivity("item/completed", command_completed);
    try std.testing.expectEqual(@as(usize, 0), registry.activeCommandCount());
    try registry.beginSynchronization(std.testing.io, 100);
    registry.endSynchronization();
}

test "worktree integrity synchronization freezes new file and message work" {
    var registry = Registry{ .allocator = std.testing.allocator, .synchronizing = true };
    defer registry.deinit();
    try std.testing.expectError(
        error.WorktreeSynchronizationActive,
        registry.openFile(
            std.testing.io,
            "/repo",
            "a",
            "r",
            "b",
            "h",
            "",
            "[]",
            "/skill/SKILL.md",
            true,
        ),
    );
    try std.testing.expectError(
        error.WorktreeSynchronizationActive,
        registry.message("missing", "hello"),
    );
}

test "turn start response alone never opens primary gate" {
    var registry = Registry{
        .allocator = std.testing.allocator,
        .primary_start_turn_id = try std.testing.allocator.dupe(u8, "started"),
    };
    defer registry.deinit();
    try std.testing.expect(!registry.primaryReady());
}
test "session authority is immediately governing and close is local" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try registry.sessions.append(
        std.testing.allocator,
        .{
            .id = try std.testing.allocator.dupe(u8, "s"),
            .thread_id = try std.testing.allocator.dupe(u8, "t"),
            .turn_id = try std.testing.allocator.dupe(u8, "u"),
            .path = try std.testing.allocator.dupe(u8, "a"),
            .revision = try std.testing.allocator.dupe(u8, "r"),
            .last_injected_revision = try std.testing.allocator.dupe(u8, "r"),
            .initial_turn_active = false,
            .turn_active = false,
        },
    );
    try registry.markHumanInstruction("s", "please prepare the comment");
    try std.testing.expectEqual(
        HumanAuthority.github_any,
        registry.sessions.items[0].human_authority.?,
    );
    try registry.closeSession("s");
    try std.testing.expectEqual(SessionStatus.closed, registry.sessions.items[0].status);
}

test "explicit broad GitHub operation grants generic action authority without ordinary questions" {
    try std.testing.expectEqual(
        HumanAuthority.github_any,
        classifyHumanInstruction("please add the release label to this pull request").?,
    );
    try std.testing.expectEqual(
        HumanAuthority.github_any,
        classifyHumanInstruction("close this pull request").?,
    );
    try std.testing.expectEqual(
        HumanAuthority.github_any,
        classifyHumanInstruction("update the pull request title").?,
    );
    try std.testing.expectEqual(
        HumanAuthority.close,
        classifyHumanInstruction("close this session").?,
    );
    const label_question = classifyHumanInstruction(
        "which labels are already on this pull request?",
    );
    try std.testing.expect(label_question == null);
    const label_help = classifyHumanInstruction(
        "tell me how to add a label to the pull request",
    );
    try std.testing.expect(label_help == null);
    try std.testing.expect(classifyHumanInstruction("Should we mark this file reviewed?") == null);
    try std.testing.expect(classifyHumanInstruction("Never mark this file reviewed") == null);
    try std.testing.expect(classifyHumanInstruction(
        "I don't want you to mark this file reviewed",
    ) == null);
    try std.testing.expect(classifyHumanInstruction(
        "I don't want you to delete this comment",
    ) == null);
    try std.testing.expect(classifyHumanInstruction("Summarize changes in this PR") == null);
    try std.testing.expect(classifyHumanInstruction(
        "Update me on this pull request status",
    ) == null);
    try std.testing.expect(classifyHumanInstruction(
        "Explain the findings, then complete this file",
    ) == null);
    try std.testing.expectEqual(
        HumanAuthority.complete,
        classifyHumanInstruction("Please complete this file.").?,
    );
    try std.testing.expectEqual(
        HumanAuthority.github_any,
        classifyHumanInstruction("Add the comment, but do not close this session").?,
    );
    try std.testing.expectEqual(
        HumanAuthority.github_any,
        classifyHumanInstruction("Could you add this label?").?,
    );
}

test "visible notification overflow becomes an explicit warning after capacity drains" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try registry.sessions.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "s"),
        .thread_id = try std.testing.allocator.dupe(u8, "t"),
        .turn_id = try std.testing.allocator.dupe(u8, "u"),
        .path = try std.testing.allocator.dupe(u8, "a"),
        .revision = try std.testing.allocator.dupe(u8, "r"),
        .last_injected_revision = try std.testing.allocator.dupe(u8, "r"),
    });
    for (0..max_visible_events) |_| try registry.queueSystemEvent("status", "{}");
    const notification = cas_runtime.Notification{
        .method = "item/agentMessage/delta",
        .raw_json = "{\"params\":{\"threadId\":\"t\"}}",
    };
    Registry.onNotification(&registry, notification);
    try std.testing.expectEqual(@as(u64, 1), registry.visible_overflow_count);
    try registry.acknowledgeVisible();
    try std.testing.expectEqual(@as(usize, max_visible_events), registry.visible_events.items.len);
    const warning = registry.visible_events.items[max_visible_events - 1];
    try std.testing.expectEqualStrings("warning", warning.method);
    try std.testing.expect(std.mem.indexOf(u8, warning.raw_json, "VisibleEventOverflow") != null);
}

test "failed or interrupted primary turns never advance the fork checkpoint" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    registry.primary_thread_id = try std.testing.allocator.dupe(u8, "primary");
    registry.primary_start_turn_id = try std.testing.allocator.dupe(u8, "t1");
    registry.primary_turn_active = true;
    registry.recordPrimaryCompletion(
        "{\"params\":{\"threadId\":\"primary\",\"turn\":{\"id\":\"t1\"," ++
            "\"status\":\"failed\"}}}",
    );
    try std.testing.expect(!registry.primaryReady());
    try std.testing.expectEqualStrings("failed", registry.takePrimaryFailure().?);
    std.testing.allocator.free(registry.primary_start_turn_id.?);
    registry.primary_start_turn_id = try std.testing.allocator.dupe(u8, "t2");
    registry.primary_turn_active = true;
    registry.recordPrimaryCompletion(
        "{\"params\":{\"threadId\":\"primary\",\"turn\":{\"id\":\"t2\"," ++
            "\"status\":\"interrupted\"}}}",
    );
    try std.testing.expect(!registry.primaryReady());
    try std.testing.expectEqualStrings("interrupted", registry.takePrimaryFailure().?);
    std.testing.allocator.free(registry.primary_start_turn_id.?);
    registry.primary_start_turn_id = try std.testing.allocator.dupe(u8, "t3");
    registry.recordPrimaryCompletion(
        "{\"params\":{\"threadId\":\"primary\",\"turn\":{\"id\":\"t3\"," ++
            "\"status\":\"completed\"}}}",
    );
    try std.testing.expect(registry.primaryReady());
    try std.testing.expectEqualStrings("t3", registry.latest_primary_turn_id.?);
}

test "primary turn installation reconciles an earlier terminal notification" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    registry.primary_thread_id = try std.testing.allocator.dupe(u8, "primary");
    registry.recordPrimaryCompletion(
        "{\"params\":{\"threadId\":\"primary\",\"turn\":{" ++
            "\"id\":\"early\",\"status\":\"completed\"}}}",
    );
    try std.testing.expect(!registry.primaryReady());
    registry.mutex.lock();
    registry.installPrimaryTurnLocked(try std.testing.allocator.dupe(u8, "early"));
    registry.mutex.unlock();
    try std.testing.expect(registry.primaryReady());
    try std.testing.expectEqualStrings("early", registry.latest_primary_turn_id.?);
    try std.testing.expect(!registry.primary_turn_active);
}

test "completion notifications correlate exact active turn identity" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try registry.sessions.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "session"),
        .thread_id = try std.testing.allocator.dupe(u8, "thread"),
        .turn_id = try std.testing.allocator.dupe(u8, "current-turn"),
        .path = try std.testing.allocator.dupe(u8, "a.zig"),
        .revision = try std.testing.allocator.dupe(u8, "r1"),
        .last_injected_revision = try std.testing.allocator.dupe(u8, "r1"),
        .initial_turn_active = true,
        .turn_active = true,
    });
    Registry.onNotification(&registry, .{
        .method = "turn/completed",
        .raw_json = "{\"params\":{\"threadId\":\"thread\",\"turn\":{" ++
            "\"id\":\"stale-turn\",\"status\":\"completed\"}}}",
    });
    try std.testing.expect(registry.sessions.items[0].turn_active);
    Registry.onNotification(&registry, .{
        .method = "turn/completed",
        .raw_json = "{\"params\":{\"threadId\":\"thread\",\"turn\":{" ++
            "\"id\":\"current-turn\",\"status\":\"completed\"}}}",
    });
    try std.testing.expect(!registry.sessions.items[0].turn_active);
}

test "primary completion ignores stale turn identity" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    registry.primary_thread_id = try std.testing.allocator.dupe(u8, "primary");
    registry.primary_start_turn_id = try std.testing.allocator.dupe(u8, "current");
    registry.latest_primary_turn_id = try std.testing.allocator.dupe(u8, "prior");
    registry.primary_turn_active = true;
    registry.recordPrimaryCompletion(
        "{\"params\":{\"threadId\":\"primary\",\"turn\":{" ++
            "\"id\":\"stale\",\"status\":\"completed\"}}}",
    );
    try std.testing.expect(registry.primary_turn_active);
    try std.testing.expectEqualStrings("prior", registry.latest_primary_turn_id.?);
    registry.recordPrimaryCompletion(
        "{\"params\":{\"threadId\":\"primary\",\"turn\":{" ++
            "\"id\":\"current\",\"status\":\"completed\"}}}",
    );
    try std.testing.expect(!registry.primary_turn_active);
    try std.testing.expectEqualStrings("current", registry.latest_primary_turn_id.?);
}

test "turn start admission blocks synchronization snapshot" {
    var registry = Registry{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer registry.deinit();
    try registry.sessions.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "session"),
        .thread_id = try std.testing.allocator.dupe(u8, "thread"),
        .turn_id = try std.testing.allocator.dupe(u8, ""),
        .path = try std.testing.allocator.dupe(u8, "a.zig"),
        .revision = try std.testing.allocator.dupe(u8, "r1"),
        .last_injected_revision = try std.testing.allocator.dupe(u8, "r1"),
        .initial_turn_active = false,
        .turn_active = false,
    });
    var target = try registry.messageTarget("session");
    defer target.deinit(std.testing.allocator);
    try std.testing.expect(target.start_reserved);
    try std.testing.expectError(
        error.TurnStartAlreadyActive,
        registry.messageTarget("session"),
    );
    try std.testing.expectError(
        error.ActiveReviewCommandsTimeout,
        registry.beginSynchronization(std.testing.io, 5),
    );
    try std.testing.expect(!registry.synchronizing);
    registry.clearTurnStarting("session");
}

const ApprovalInvocation = struct {
    registry: *Registry,
    method: []const u8,
    raw: []const u8,
    response: ?[]u8 = null,

    fn run(self: *ApprovalInvocation) void {
        const request = cas_runtime.ServerRequest{
            .id = .{ .string = "server-request" },
            .method = self.method,
            .raw_json = self.raw,
        };
        self.response = Registry.onServerRequest(
            self.registry,
            request,
            std.heap.page_allocator,
        ) catch null;
    }
};

fn appendApprovalTestSession(registry: *Registry, id: []const u8, thread: []const u8) !void {
    try registry.sessions.append(registry.allocator, .{
        .id = try registry.allocator.dupe(u8, id),
        .thread_id = try registry.allocator.dupe(u8, thread),
        .turn_id = try registry.allocator.dupe(u8, "turn"),
        .path = try registry.allocator.dupe(u8, "a.zig"),
        .revision = try registry.allocator.dupe(u8, "r1"),
        .last_injected_revision = try registry.allocator.dupe(u8, "r1"),
        .initial_turn_active = false,
        .turn_active = true,
    });
}

const exact_tool_test_request =
    "{\"params\":{\"threadId\":\"file-1\",\"tool\":" ++
    "\"synoptic.prepare_github_action\",\"arguments\":{\"slot\":\"finding\"," ++
    "\"kind\":\"add_inline_comment\",\"effectSummary\":" ++
    "\"mentions synoptic.search_unresolved_threads only as text\"," ++
    "\"payload\":{\"path\":\"a.zig\",\"line\":1,\"side\":\"RIGHT\"," ++
    "\"body\":\"body\"}}}}";

fn acceptTestAuthoritativeTool(
    raw_context: *anyopaque,
    event_kind: []const u8,
    raw_json: []const u8,
    session_id: []const u8,
) !void {
    _ = event_kind;
    _ = raw_json;
    _ = session_id;
    const calls: *usize = @ptrCast(@alignCast(raw_context));
    calls.* += 1;
}

test "dynamic tool dispatch binds the exact parsed tool name" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    registry.sessions.items[0].human_authority = .github_any;
    var calls: usize = 0;
    try registry.setAuthoritativeToolHandler(.{
        .context = &calls,
        .handle = acceptTestAuthoritativeTool,
    });
    const response = try registry.handleToolCall(exact_tool_test_request, std.testing.allocator);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings(accepted_domain_response, response);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqualStrings("action.prepared", registry.visible_events.items[0].method);
}

test "authoritative tools fail closed without a domain handler" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    registry.sessions.items[0].human_authority = .github_any;
    const response = try registry.handleToolCall(exact_tool_test_request, std.testing.allocator);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings(evidence_unavailable_response, response);
    try std.testing.expectEqual(@as(usize, 0), registry.visible_events.items.len);
    try std.testing.expectEqual(
        HumanAuthority.github_any,
        registry.sessions.items[0].human_authority.?,
    );
}

test "authoritative tool backpressure preserves human authority" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    registry.sessions.items[0].human_authority = .github_any;
    for (0..max_visible_events) |_| try registry.queueSystemEvent("status", "{}");
    const response = try registry.handleToolCall(exact_tool_test_request, std.testing.allocator);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings(evidence_unavailable_response, response);
    try std.testing.expectEqual(
        HumanAuthority.github_any,
        registry.sessions.items[0].human_authority.?,
    );
}

test "visible events remain retained until delivery is acknowledged" {
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try registry.queueSystemEvent("warning", "{\"code\":\"retry\"}");
    const first = (try registry.peekVisible(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    const retry = (try registry.peekVisible(std.testing.allocator)).?;
    defer retry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.raw_json, retry.raw_json);
    try registry.acknowledgeVisible();
    try std.testing.expect((try registry.peekVisible(std.testing.allocator)) == null);
}

fn waitForApproval(registry: *Registry) !void {
    for (0..200) |_| {
        registry.mutex.lock();
        const pending = registry.approvals.items.len > 0 and
            registry.approvals.items[registry.approvals.items.len - 1].state == .pending;
        registry.mutex.unlock();
        if (pending) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch |ignored_error| {
            switch (ignored_error) {
                else => {},
            }
        };
    }
    return error.ExpectedApprovalMissing;
}

test "command approvals accept exact offered decisions only" {
    var registry = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    var invocation = ApprovalInvocation{
        .registry = &registry,
        .method = "item/commandExecution/requestApproval",
        .raw = "{\"id\":7,\"method\":\"item/commandExecution/requestAp" ++
            "proval\",\"params\":{\"threadId\":\"file-1\",\"turnId" ++
            "\":\"turn\",\"itemId\":\"cmd\",\"startedAtMs\":1,\"com" ++
            "mand\":\"make test\",\"availableDecisions\":[\"accept" ++
            "\",\"decline\"]}}",
    };
    const thread = try std.Thread.spawn(.{}, ApprovalInvocation.run, .{&invocation});
    try waitForApproval(&registry);
    try std.testing.expectError(
        error.CrossSessionApproval,
        registry.resolveApproval("ses-2", "apr-1", "\"accept\""),
    );
    try std.testing.expectError(
        error.ApprovalDecisionNotOffered,
        registry.resolveApproval("ses-1", "apr-1", "\"invented\""),
    );
    try registry.resolveApproval("ses-1", "apr-1", "\"accept\"");
    thread.join();
    defer if (invocation.response) |response| std.heap.page_allocator.free(response);
    try std.testing.expectEqualStrings("{\"decision\":\"accept\"}", invocation.response.?);
    try std.testing.expectError(
        error.ApprovalAlreadyResolved,
        registry.resolveApproval("ses-1", "apr-1", "\"accept\""),
    );
}

test "command approval without offered decisions fails closed to decline" {
    var registry = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    var invocation = ApprovalInvocation{
        .registry = &registry,
        .method = "item/commandExecution/requestApproval",
        .raw = "{\"id\":7,\"method\":\"item/commandExecution/requestApproval\"," ++
            "\"params\":{\"threadId\":\"file-1\",\"turnId\":\"turn\"," ++
            "\"itemId\":\"cmd\",\"startedAtMs\":1,\"command\":\"make test\"}}",
    };
    const thread = try std.Thread.spawn(.{}, ApprovalInvocation.run, .{&invocation});
    try waitForApproval(&registry);
    registry.mutex.lock();
    const decision_count = registry.approvals.items[0].decisions.items.len;
    const decline_only = decision_count == 1 and std.mem.eql(
        u8,
        registry.approvals.items[0].decisions.items[0].choice_json,
        "\"decline\"",
    );
    registry.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), decision_count);
    try std.testing.expect(decline_only);
    try std.testing.expectError(
        error.ApprovalDecisionNotOffered,
        registry.resolveApproval("ses-1", "apr-1", "\"acceptForSession\""),
    );
    try registry.resolveApproval("ses-1", "apr-1", "\"decline\"");
    thread.join();
    defer if (invocation.response) |response| std.heap.page_allocator.free(response);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", invocation.response.?);
}

test "filesystem and permission escalation requests decline before browser routing" {
    var registry = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    const raw = "{\"id\":8,\"method\":\"item/permissions/requestApproval\"," ++
        "\"params\":{\"threadId\":\"file-1\",\"permissions\":{" ++
        "\"fsWrite\":[\"/repo\"]}}}";
    const decline = try Registry.onServerRequest(
        &registry,
        .{
            .id = .{ .integer = 9 },
            .method = "item/permissions/requestApproval",
            .raw_json = raw,
        },
        std.heap.page_allocator,
    );
    defer std.heap.page_allocator.free(decline);
    try std.testing.expectEqualStrings("{\"permissions\":{},\"scope\":\"turn\"}", decline);
    try std.testing.expectEqual(@as(usize, 0), registry.approvals.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.visible_events.items.len);
}

test "command approvals timeout close and synchronization conservatively decline" {
    var timed = Registry{
        .allocator = std.heap.page_allocator,
        .io = std.testing.io,
        .approval_wait_timeout_ms = 5,
    };
    defer timed.deinit();
    try appendApprovalTestSession(&timed, "ses-1", "file-1");
    const request_json = "{\"id\":1,\"method\":\"item/commandExecution/requestAp" ++
        "proval\",\"params\":{\"threadId\":\"file-1\",\"turnId" ++
        "\":\"turn\",\"itemId\":\"cmd\",\"startedAtMs\":1,\"ava" ++
        "ilableDecisions\":[\"accept\",\"decline\"]}}";
    const request = cas_runtime.ServerRequest{
        .id = .{ .integer = 1 },
        .method = "item/commandExecution/requestApproval",
        .raw_json = request_json,
    };
    const timeout_response = try Registry.onServerRequest(&timed, request, std.heap.page_allocator);
    defer std.heap.page_allocator.free(timeout_response);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", timeout_response);
    try std.testing.expectError(
        error.ApprovalExpired,
        timed.resolveApproval("ses-1", "apr-1", "\"accept\""),
    );

    var closed = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer closed.deinit();
    try appendApprovalTestSession(&closed, "ses-1", "file-1");
    var invocation = ApprovalInvocation{
        .registry = &closed,
        .method = request.method,
        .raw = request.raw_json,
    };
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
    var sync_invocation = ApprovalInvocation{
        .registry = &syncing,
        .method = request.method,
        .raw = request.raw_json,
    };
    const sync_thread = try std.Thread.spawn(.{}, ApprovalInvocation.run, .{&sync_invocation});
    try waitForApproval(&syncing);
    try syncing.beginSynchronization(std.testing.io, 100);
    syncing.endSynchronization();
    sync_thread.join();
    defer if (sync_invocation.response) |response| std.heap.page_allocator.free(response);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", sync_invocation.response.?);
}

test "approval wait is capped by the original actor request deadline" {
    var registry = Registry{
        .allocator = std.heap.page_allocator,
        .io = std.testing.io,
        .approval_wait_timeout_ms = 25_000,
    };
    defer registry.deinit();
    try appendApprovalTestSession(&registry, "ses-1", "file-1");
    const now_ms: i64 = @intCast(@divFloor(
        std.Io.Clock.awake.now(std.testing.io).nanoseconds,
        std.time.ns_per_ms,
    ));
    const response = try Registry.onServerRequest(&registry, .{
        .id = .{ .integer = 44 },
        .method = "item/commandExecution/requestApproval",
        .raw_json = "{\"params\":{\"threadId\":\"file-1\"," ++
            "\"availableDecisions\":[\"accept\",\"decline\"]}}",
        .deadline_ms = now_ms + 5,
    }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(response);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", response);
    const finished_ms: i64 = @intCast(@divFloor(
        std.Io.Clock.awake.now(std.testing.io).nanoseconds,
        std.time.ns_per_ms,
    ));
    try std.testing.expect(finished_ms - now_ms < 250);
}

test "file change and unowned approvals decline while sandboxed commands remain reviewable" {
    var registry = Registry{ .allocator = std.heap.page_allocator, .io = std.testing.io };
    defer registry.deinit();
    const file = try Registry.onServerRequest(
        &registry,
        .{
            .id = .{ .integer = 1 },
            .method = "item/fileChange/requestApproval",
            .raw_json = "{}",
        },
        std.heap.page_allocator,
    );
    defer std.heap.page_allocator.free(file);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", file);
    const deprecated = try Registry.onServerRequest(
        &registry,
        .{ .id = .{ .integer = 2 }, .method = "applyPatchApproval", .raw_json = "{}" },
        std.heap.page_allocator,
    );
    defer std.heap.page_allocator.free(deprecated);
    try std.testing.expect(std.mem.indexOf(
        u8,
        deprecated,
        "denied",
    ) != null);
    const unowned_request = cas_runtime.ServerRequest{
        .id = .{ .integer = 3 },
        .method = "item/commandExecution/requestApproval",
        .raw_json = "{\"params\":{\"threadId\":\"primary\",\"availableDecis" ++
            "ions\":[\"accept\",\"decline\"]}}",
    };
    const unowned = try Registry.onServerRequest(
        &registry,
        unowned_request,
        std.heap.page_allocator,
    );
    defer std.heap.page_allocator.free(unowned);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", unowned);
    try appendApprovalTestSession(&registry, "ses-edit", "file-edit");
    const edit = try Registry.onServerRequest(&registry, .{
        .id = .{ .integer = 4 },
        .method = "item/commandExecution/requestApproval",
        .raw_json = "{\"params\":{\"threadId\":\"file-edit\"," ++
            "\"command\":\"sed -i s/a/b/ src/a.zig\"," ++
            "\"availableDecisions\":[\"accept\",\"decline\"]}}",
    }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(edit);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", edit);
    registry.primary_thread_id = try std.heap.page_allocator.dupe(u8, "shared");
    try appendApprovalTestSession(&registry, "ses-1", "shared");
    const ambiguous = try Registry.onServerRequest(&registry, .{
        .id = .{ .integer = 5 },
        .method = "item/commandExecution/requestApproval",
        .raw_json = "{\"params\":{\"threadId\":\"shared\"," ++
            "\"availableDecisions\":[\"accept\",\"decline\"]}}",
    }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(ambiguous);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", ambiguous);
    try std.testing.expectEqual(@as(usize, 2), registry.visible_events.items.len);
}

test "non-approval server requests return method-specific fail-closed results" {
    var registry = Registry{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer registry.deinit();

    const user_input = try Registry.onServerRequest(&registry, .{
        .id = .{ .integer = 1 },
        .method = "item/tool/requestUserInput",
        .raw_json = "{}",
    }, std.testing.allocator);
    defer std.testing.allocator.free(user_input);
    try std.testing.expectEqualStrings("{\"answers\":{}}", user_input);

    const elicitation = try Registry.onServerRequest(&registry, .{
        .id = .{ .integer = 2 },
        .method = "mcpServer/elicitation/request",
        .raw_json = "{}",
    }, std.testing.allocator);
    defer std.testing.allocator.free(elicitation);
    try std.testing.expectEqualStrings(
        "{\"action\":\"decline\",\"content\":null,\"_meta\":null}",
        elicitation,
    );

    const current_time = try Registry.onServerRequest(&registry, .{
        .id = .{ .integer = 3 },
        .method = "currentTime/read",
        .raw_json = "{}",
    }, std.testing.allocator);
    defer std.testing.allocator.free(current_time);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        current_time,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("currentTimeAt").? == .integer);

    try std.testing.expectError(
        error.ChatGptAuthTokensRefreshProviderUnavailable,
        Registry.onServerRequest(&registry, .{
            .id = .{ .integer = 4 },
            .method = "account/chatgptAuthTokens/refresh",
            .raw_json = "{}",
        }, std.testing.allocator),
    );
    try std.testing.expectError(
        error.AttestationProviderUnavailable,
        Registry.onServerRequest(&registry, .{
            .id = .{ .integer = 5 },
            .method = "attestation/generate",
            .raw_json = "{}",
        }, std.testing.allocator),
    );
    try std.testing.expectError(
        error.UnsupportedServerRequest,
        Registry.onServerRequest(&registry, .{
            .id = .{ .integer = 6 },
            .method = "future/serverRequest",
            .raw_json = "{}",
        }, std.testing.allocator),
    );
}

test "thread construction fixes review execution to read-only" {
    try std.testing.expectEqualStrings(
        "\"approvalPolicy\":\"on-request\",\"sandbox\":\"read-only\"",
        review_execution_fields,
    );
}
