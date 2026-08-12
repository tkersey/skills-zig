const std = @import("std");
const config = @import("config.zig");
const domain = @import("domain.zig");
const github = @import("github.zig");
const pr = @import("pr.zig");
const sessions = @import("sessions.zig");
const tools = @import("tools.zig");
const ui = @import("ui_protocol.zig");
const worktree = @import("worktree.zig");

pub const ExclusionOutcome = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    reason: []u8,
    sync_error: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        reason: []const u8,
        sync_error: ?[]const u8,
    ) !ExclusionOutcome {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_reason = try allocator.dupe(u8, reason);
        errdefer allocator.free(owned_reason);
        const owned_error = if (sync_error) |value| try allocator.dupe(u8, value) else null;
        return .{
            .allocator = allocator,
            .path = owned_path,
            .reason = owned_reason,
            .sync_error = owned_error,
        };
    }

    pub fn deinit(self: ExclusionOutcome) void {
        self.allocator.free(self.path);
        self.allocator.free(self.reason);
        if (self.sync_error) |value| self.allocator.free(value);
    }
};

const ExclusionCandidate = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    revision: []u8,
    reason: []u8,
    client_id: []u8,

    fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        revision: []const u8,
        reason: []const u8,
    ) !ExclusionCandidate {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_revision = try allocator.dupe(u8, revision);
        errdefer allocator.free(owned_revision);
        const owned_reason = try allocator.dupe(u8, reason);
        errdefer allocator.free(owned_reason);
        const client_id = try exclusionMutationIdAlloc(allocator, path, revision);
        return .{
            .allocator = allocator,
            .path = owned_path,
            .revision = owned_revision,
            .reason = owned_reason,
            .client_id = client_id,
        };
    }

    fn deinit(self: ExclusionCandidate) void {
        self.allocator.free(self.path);
        self.allocator.free(self.revision);
        self.allocator.free(self.reason);
        self.allocator.free(self.client_id);
    }
};

const ExclusionProbe = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    previous_path: ?[]u8,
    revision: []u8,
    reason: ?[]u8,

    fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        previous_path: ?[]const u8,
        revision: []const u8,
        reason: ?[]const u8,
    ) !ExclusionProbe {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_previous_path = if (previous_path) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_previous_path) |value| allocator.free(value);
        const owned_revision = try allocator.dupe(u8, revision);
        errdefer allocator.free(owned_revision);
        const owned_reason = if (reason) |value| try allocator.dupe(u8, value) else null;
        return .{
            .allocator = allocator,
            .path = owned_path,
            .previous_path = owned_previous_path,
            .revision = owned_revision,
            .reason = owned_reason,
        };
    }

    fn deinit(self: ExclusionProbe) void {
        self.allocator.free(self.path);
        if (self.previous_path) |value| self.allocator.free(value);
        self.allocator.free(self.revision);
        if (self.reason) |value| self.allocator.free(value);
    }
};

pub const AutomaticExclusionBatch = struct {
    allocator: std.mem.Allocator,
    base_oid: []u8,
    head_oid: []u8,
    probes: std.ArrayList(ExclusionProbe) = .empty,
    candidates: std.ArrayList(ExclusionCandidate) = .empty,

    pub fn deinit(self: *AutomaticExclusionBatch) void {
        for (self.probes.items) |probe| probe.deinit();
        self.probes.deinit(self.allocator);
        for (self.candidates.items) |candidate| candidate.deinit();
        self.candidates.deinit(self.allocator);
        self.allocator.free(self.base_oid);
        self.allocator.free(self.head_oid);
    }

    pub fn classify(
        self: *AutomaticExclusionBatch,
        settings: *const config.Settings,
        broker: github.Broker,
        cwd: []const u8,
    ) !void {
        std.debug.assert(self.candidates.items.len == 0);
        var merge_base: ?[]u8 = null;
        defer if (merge_base) |owned| self.allocator.free(owned);
        for (self.probes.items) |probe| {
            if (probe.reason != null) continue;
            merge_base = github.canonicalMergeBaseAlloc(
                self.allocator,
                broker.io,
                broker.git_path,
                cwd,
                self.base_oid,
                self.head_oid,
                broker.cancelled,
            ) catch |err| switch (err) {
                error.GitDiffCancelled => return err,
                else => null,
            };
            break;
        }
        for (self.probes.items) |probe| {
            if (broker.cancelled) |cancelled| {
                if (cancelled.load(.acquire)) return error.GitDiffCancelled;
            }
            const reason = probe.reason orelse binary: {
                const diff = github.canonicalDiffFromMergeBaseAlloc(
                    self.allocator,
                    broker.io,
                    broker.git_path,
                    cwd,
                    merge_base orelse continue,
                    self.head_oid,
                    probe.path,
                    probe.previous_path,
                    broker.cancelled,
                ) catch |err| switch (err) {
                    error.GitDiffCancelled => return err,
                    else => continue,
                };
                defer self.allocator.free(diff);
                break :binary settings.classifyDiff(diff) orelse continue;
            };
            var candidate = try ExclusionCandidate.init(
                self.allocator,
                probe.path,
                probe.revision,
                reason,
            );
            errdefer candidate.deinit();
            try self.candidates.append(self.allocator, candidate);
        }
    }

    pub fn requestsAlloc(self: *const AutomaticExclusionBatch) ![]github.Broker.ViewedBatchRequest {
        const requests = try self.allocator.alloc(
            github.Broker.ViewedBatchRequest,
            self.candidates.items.len,
        );
        for (self.candidates.items, requests) |candidate, *request| request.* = .{
            .path = candidate.path,
            .client_id = candidate.client_id,
        };
        return requests;
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    generation: domain.PrGeneration,
    primary_ready: bool = false,
    seq: u64 = 0,
    open_path: ?[]u8 = null,
    pending: ?tools.ActionCard = null,
    official_revision: ?[]u8 = null,
    initial_review_active: bool = false,
    tabs: std.ArrayList(domain.Tab) = .empty,
    action_store: tools.ActionStore,
    round: u64 = 1,
    action_state_fresh: bool = true,
    file_review_start_mode: config.FileReviewStartMode = .immediate,
    pull_request: ?domain.OwnedPullRequestHeader = null,

    pub fn init(allocator: std.mem.Allocator, head: []const u8) !App {
        return .{
            .allocator = allocator,
            .generation = try .init(allocator, head),
            .action_store = .{ .allocator = allocator },
        };
    }
    pub fn deinit(self: *App) void {
        self.generation.deinit();
        if (self.open_path) |p| self.allocator.free(p);
        if (self.official_revision) |r| self.allocator.free(r);
        if (self.pull_request) |*header| header.deinit();
        for (self.tabs.items) |tab| {
            self.allocator.free(tab.id);
            self.allocator.free(tab.path);
            self.allocator.free(tab.revision);
            self.allocator.free(tab.diff);
        }
        self.tabs.deinit(self.allocator);
        self.action_store.deinit();
    }

    pub fn replaceGeneration(self: *App, next: domain.PrGeneration) void {
        self.generation.deinit();
        self.generation = next;
        for (self.tabs.items) |*tab| {
            if (domain.revisionFor(&next, tab.path)) |revision| {
                if (!std.mem.eql(u8, tab.revision, revision) and (tab.status == .current or
                    tab.status == .completed)) tab.status = .stale_origin;
            } else if (tab.status == .current or tab.status == .completed) tab.status =
                .stale_origin;
        }
    }

    pub fn setPullRequest(self: *App, value: domain.PullRequestHeader) !void {
        var owned = try domain.OwnedPullRequestHeader.init(self.allocator, value);
        errdefer owned.deinit();
        if (self.pull_request) |*old| old.deinit();
        self.pull_request = owned;
    }

    /// Install one complete GitHub snapshot as a single app-owned state change.
    /// Ownership is acquired before the prior header or generation is retired.
    pub fn replaceGithubSnapshot(
        self: *App,
        next: domain.PrGeneration,
        header: domain.PullRequestHeader,
    ) !void {
        var owned = try domain.OwnedPullRequestHeader.init(self.allocator, header);
        errdefer owned.deinit();
        if (self.pull_request) |*old| old.deinit();
        self.pull_request = owned;
        self.replaceGeneration(next);
    }

    pub fn updatePullRequestGeneration(
        self: *App,
        base_oid: []const u8,
        head_oid: []const u8,
    ) !void {
        if (self.pull_request) |*header| try header.setGeneration(base_oid, head_oid);
    }

    pub fn openFile(self: *App, path: []const u8) ![]u8 {
        if (!self.primary_ready) return error.PrimaryNotReady;
        if (!self.generation.queued(path)) return error.FileNotQueued;
        const current_revision = domain.revisionFor(&self.generation, path) orelse
            return error.MissingRevision;
        const next_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(next_path);
        const next_revision = try self.allocator.dupe(u8, current_revision);
        errdefer self.allocator.free(next_revision);
        var existing = false;
        var appended = false;
        errdefer if (appended) {
            const removed = self.tabs.pop().?;
            self.allocator.free(removed.id);
            self.allocator.free(removed.path);
            self.allocator.free(removed.revision);
            self.allocator.free(removed.diff);
        };
        for (self.tabs.items) |tab| {
            if (tab.status == .current and std.mem.eql(u8, tab.path, path) and
                std.mem.eql(u8, tab.revision, current_revision)) existing = true;
        }
        if (!existing) {
            const id = try std.fmt.allocPrint(
                self.allocator,
                "tab-{d}",
                .{self.tabs.items.len + 1},
            );
            errdefer self.allocator.free(id);
            const tab_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(tab_path);
            const revision = try self.allocator.dupe(u8, current_revision);
            errdefer self.allocator.free(revision);
            const diff = try self.allocator.dupe(u8, "");
            errdefer self.allocator.free(diff);
            try self.tabs.append(
                self.allocator,
                .{ .id = id, .path = tab_path, .revision = revision, .diff = diff },
            );
            appended = true;
        }
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"path\":{f},\"initialReview\":{}}}",
            .{ std.json.fmt(path, .{}), self.file_review_start_mode == .immediate },
        );
        defer self.allocator.free(payload);
        const envelope = try ui.envelopeAlloc(
            self.allocator,
            "session.opened",
            self.seq + 1,
            payload,
        );
        if (self.open_path) |old| self.allocator.free(old);
        self.open_path = next_path;
        if (self.official_revision) |old| self.allocator.free(old);
        self.official_revision = next_revision;
        self.initial_review_active = self.file_review_start_mode == .immediate;
        self.seq += 1;
        return envelope;
    }

    pub fn recordOpenedSession(
        self: *App,
        path: []const u8,
        revision: []const u8,
        session_id: []const u8,
        diff: []const u8,
        reused: bool,
        initial_review: bool,
    ) !void {
        for (self.tabs.items) |*tab| {
            const matches = std.mem.eql(u8, tab.path, path) and
                std.mem.eql(u8, tab.revision, revision) and tab.status == .current;
            if (!matches) continue;
            const id = try self.allocator.dupe(u8, session_id);
            errdefer self.allocator.free(id);
            const content = try self.allocator.dupe(u8, diff);
            self.allocator.free(tab.id);
            self.allocator.free(tab.diff);
            tab.id = id;
            tab.diff = content;
            tab.diff_state = diffDisplayState(diff);
            tab.reused = reused;
            tab.initial_review = initial_review;
            if (!reused) tab.turn_active = initial_review;
            return;
        }
        return error.UnknownTab;
    }

    pub fn rollbackOpenedFile(
        self: *App,
        path: []const u8,
        revision: []const u8,
        reused: bool,
    ) void {
        if (!reused) {
            for (self.tabs.items, 0..) |tab, index| {
                if (!std.mem.eql(u8, tab.path, path) or
                    !std.mem.eql(u8, tab.revision, revision) or
                    tab.status != .current) continue;
                const removed = self.tabs.orderedRemove(index);
                self.allocator.free(removed.id);
                self.allocator.free(removed.path);
                self.allocator.free(removed.revision);
                self.allocator.free(removed.diff);
                break;
            }
        }
        if (self.open_path) |value| self.allocator.free(value);
        self.open_path = null;
        if (self.official_revision) |value| self.allocator.free(value);
        self.official_revision = null;
        self.initial_review_active = false;
    }

    pub fn updateTabDiff(self: *App, path: []const u8, diff: ?[]const u8) !void {
        for (self.tabs.items) |*tab| if (std.mem.eql(u8, tab.path, path) and tab.status !=
            .closed)
        {
            const content = try self.allocator.dupe(u8, diff orelse "");
            self.allocator.free(tab.diff);
            tab.diff = content;
            tab.diff_state = if (diff) |value| diffDisplayState(value) else .unavailable;
        };
    }

    pub fn setTabTurnActive(self: *App, session_id: []const u8, active: bool) void {
        for (self.tabs.items) |*tab| {
            if (!std.mem.eql(u8, tab.id, session_id) or tab.status == .closed) continue;
            tab.turn_active = active;
            return;
        }
    }

    pub fn synchronizeTabTurnStates(self: *App, registry: *sessions.Registry) void {
        for (self.tabs.items) |*tab| {
            if (tab.status == .closed) continue;
            if (registry.sessionTurnActive(tab.id)) |active| tab.turn_active = active;
        }
    }

    pub fn sessionOpenedPayloadAlloc(
        self: *const App,
        path: []const u8,
        revision: []const u8,
    ) ![]u8 {
        for (self.tabs.items) |tab| {
            const matches = std.mem.eql(u8, tab.path, path) and
                std.mem.eql(u8, tab.revision, revision) and tab.status == .current;
            if (!matches) continue;
            const arguments = .{
                std.json.fmt(tab.path, .{}),
                std.json.fmt(tab.revision, .{}),
                std.json.fmt(tab.id, .{}),
                tab.reused,
                tab.initial_review,
                std.json.fmt(@tagName(tab.diff_state), .{}),
                std.json.fmt(if (tab.diff_state == .text) tab.diff else null, .{}),
            };
            return std.fmt.allocPrint(self.allocator, "{{\"path\":{f},\"revisionKey\":{f}," ++
                "\"sessionId\":{f}," ++
                "\"reused\":{},\"initialReview\":{},\"diff\":{{\"state" ++
                "\":{f},\"text\":{f}}}}}", arguments);
        }
        return error.UnknownTab;
    }

    pub fn prepareModelAction(
        self: *App,
        session_id: []const u8,
        source_turn_id: []const u8,
        input: tools.PreparedActionInput,
        repository: []const u8,
        pull_request: u64,
        pull_request_id: []const u8,
        session_path: []const u8,
    ) !tools.ActionCard {
        const resolved_path = try self.actionTargetPath(input, session_path);
        const comment_body_snapshot = try self.commentBodySnapshot(input);
        const card = try self.action_store.prepare(
            session_id,
            source_turn_id,
            input,
            .{
                .repository = repository,
                .pull_request = pull_request,
                .pull_request_id = pull_request_id,
                .base_oid = self.generation.base_oid,
                .head_oid = self.generation.head_oid,
                .session_path = session_path,
                .resolved_path = resolved_path,
                .comment_body_snapshot = comment_body_snapshot,
            },
        );
        self.pending = card.*;
        return card.*;
    }

    fn actionTargetPath(
        self: *const App,
        input: tools.PreparedActionInput,
        session_path: []const u8,
    ) !?[]const u8 {
        if (input.thread_id) |thread_id| {
            for (self.generation.threads.items) |thread| {
                if (!std.mem.eql(u8, thread.id, thread_id)) continue;
                if (!std.mem.eql(u8, thread.path, session_path)) {
                    return error.ActionTargetsAnotherSession;
                }
                return thread.path;
            }
            return error.GitHubActionTargetMissing;
        }
        if (input.comment_id) |comment_id| {
            for (self.generation.threads.items) |thread| {
                for (thread.comments) |comment| {
                    if (!std.mem.eql(u8, comment.id, comment_id)) continue;
                    if (!std.mem.eql(u8, thread.path, session_path)) {
                        return error.ActionTargetsAnotherSession;
                    }
                    return thread.path;
                }
            }
            return error.GitHubActionTargetMissing;
        }
        return input.path;
    }

    fn commentBodySnapshot(
        self: *const App,
        input: tools.PreparedActionInput,
    ) !?[]const u8 {
        if (input.kind != .update_comment and input.kind != .delete_comment) return null;
        const comment_id = input.comment_id orelse return error.InvalidCommentAction;
        for (self.generation.threads.items) |thread| {
            for (thread.comments) |comment| {
                if (std.mem.eql(u8, comment.id, comment_id)) return comment.body;
            }
        }
        return error.GitHubActionTargetMissing;
    }

    pub fn confirmAction(
        self: *App,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card_id: []const u8,
    ) !tools.ActionStatus {
        if (!self.action_state_fresh) return error.GitHubStateStale;
        var card = (try self.action_store.pendingById(card_id)).*;
        var reconciliation_baseline = try broker.captureReconciliationBaseline(
            owner,
            name,
            number,
            card,
        );
        defer reconciliation_baseline.deinit();
        const started_unix_s: i64 =
            @intCast(@divFloor(std.Io.Clock.real.now(broker.io).nanoseconds, std.time.ns_per_s));
        _ = try self.action_store.beginExecute(card.id);
        card.status = .executing;
        self.pending = card;
        if (try self.executeOrReconcile(
            broker,
            owner,
            name,
            number,
            &card,
            started_unix_s,
            &reconciliation_baseline,
        )) |status| return status;
        if (try self.synchronizeViewedAction(broker, owner, name, number, &card)) |status| {
            return status;
        }
        broker.refreshRelevantState(owner, name, number, card) catch {
            self.action_state_fresh = false;
        };
        card.status = .succeeded;
        try self.action_store.setTerminal(card.id, .succeeded);
        self.pending = card;
        return .succeeded;
    }

    fn executeOrReconcile(
        self: *App,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card: *tools.ActionCard,
        started_unix_s: i64,
        reconciliation_baseline: *const github.ReconciliationBaseline,
    ) !?tools.ActionStatus {
        broker.executeAction(card.*) catch |err| {
            if (err == error.GitHubTransportAmbiguous) {
                const reconciled = broker.reconcileAction(
                    owner,
                    name,
                    number,
                    card.*,
                    started_unix_s,
                    reconciliation_baseline,
                ) catch false;
                if (reconciled) {
                    self.action_state_fresh = true;
                    return null;
                }
                card.status = .outcome_unknown;
            } else card.status = .failed;
            self.action_store.setTerminal(card.id, card.status) catch |terminal_err| {
                switch (terminal_err) {
                    else => {},
                }
            };
            self.pending = card.*;
            self.action_state_fresh = card.status == .succeeded;
            return card.status;
        };
        return null;
    }

    fn synchronizeViewedAction(
        self: *App,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card: *tools.ActionCard,
    ) !?tools.ActionStatus {
        if (card.kind != .mark_viewed and card.kind != .unmark_viewed) return null;
        const expected_viewed = card.kind == .mark_viewed;
        const synchronized = broker.viewedStateAfterMutation(
            owner,
            name,
            number,
            card.target.base_oid,
            card.target.head_oid,
            card.target.path.?,
            expected_viewed,
        ) catch {
            self.action_state_fresh = false;
            card.status = .outcome_unknown;
            try self.action_store.setTerminal(card.id, .outcome_unknown);
            self.pending = card.*;
            return .outcome_unknown;
        };
        if (!synchronized) {
            self.action_state_fresh = false;
            card.status = .failed;
            try self.action_store.setTerminal(card.id, .failed);
            self.pending = card.*;
            return .failed;
        }
        try self.generation.setViewed(
            card.target.path.?,
            if (expected_viewed) .viewed else .unviewed,
        );
        return null;
    }

    pub fn rejectAction(self: *App, card_id: []const u8) !void {
        try self.action_store.reject(card_id);
        try self.synchronizePendingCard(card_id);
    }

    pub fn invalidateAction(self: *App, card_id: []const u8) !void {
        try self.action_store.invalidate(card_id);
        try self.synchronizePendingCard(card_id);
    }

    fn synchronizePendingCard(self: *App, card_id: []const u8) !void {
        for (self.action_store.cards.items) |card| if (std.mem.eql(u8, card.id, card_id)) {
            self.pending = card;
            return;
        };
        return error.UnknownAction;
    }

    pub fn complete(
        self: *App,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
        path: []const u8,
        human_directed: bool,
    ) !void {
        if (!human_directed) return error.HumanDirectionRequired;
        if (self.open_path == null or !std.mem.eql(u8, self.open_path.?, path) or
            !self.generation.queued(path)) return error.NotOfficialCurrentSession;
        const revision = self.official_revision orelse return error.NotOfficialCurrentSession;
        for (self.generation.files.items) |file| if (std.mem.eql(u8, file.path, path) and
            !std.mem.eql(u8, file.revision_key, revision)) return error.StaleOriginSession;
        try broker.validateCurrentPath(
            owner,
            name,
            number,
            self.generation.base_oid,
            self.generation.head_oid,
            path,
        );
        try broker.markViewed(pull_request_id, path);
        if (!try broker.viewedAfterMutation(
            owner,
            name,
            number,
            self.generation.base_oid,
            self.generation.head_oid,
            path,
        )) return error.MarkViewedReadbackFailed;
        try self.generation.markViewed(path);
        for (self.tabs.items) |*tab| {
            if (tab.status == .current and std.mem.eql(u8, tab.path, path)) tab.status = .completed;
        }
    }
    pub fn completeRevision(
        self: *App,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
        path: []const u8,
        revision: []const u8,
    ) !void {
        if (!self.action_state_fresh) return error.GitHubStateStale;
        const current = domain.revisionFor(&self.generation, path) orelse
            return error.FileNotQueued;
        if (!std.mem.eql(u8, current, revision)) return error.StaleOriginSession;
        try broker.validateCurrentPath(
            owner,
            name,
            number,
            self.generation.base_oid,
            self.generation.head_oid,
            path,
        );
        broker.markViewed(pull_request_id, path) catch |err| {
            if (err != error.GitHubTransportAmbiguous) return err;
        };
        if (!try broker.viewedAfterMutation(
            owner,
            name,
            number,
            self.generation.base_oid,
            self.generation.head_oid,
            path,
        )) return error.MarkViewedReadbackFailed;
        try self.generation.markViewed(path);
        for (self.tabs.items) |*tab| {
            if (std.mem.eql(u8, tab.path, path) and std.mem.eql(u8, tab.revision, revision) and
                tab.status == .current) tab.status = .completed;
        }
    }

    pub fn close(self: *App) void {
        if (self.open_path) |p| self.allocator.free(p);
        self.open_path = null;
        self.initial_review_active = false;
        for (self.tabs.items) |*tab| {
            if (tab.status != .closed and (self.official_revision == null or std.mem.eql(
                u8,
                tab.revision,
                self.official_revision.?,
            ))) tab.status = .closed;
        }
    }
    pub fn closeTabById(self: *App, session_id: []const u8) !void {
        for (self.tabs.items, 0..) |tab, index| {
            if (!std.mem.eql(u8, tab.id, session_id) or tab.status == .closed) continue;
            const removed = self.tabs.orderedRemove(index);
            self.allocator.free(removed.id);
            self.allocator.free(removed.path);
            self.allocator.free(removed.revision);
            self.allocator.free(removed.diff);
            return;
        }
        return error.UnknownTab;
    }

    pub fn nextEnvelope(self: *App, event_type: []const u8, payload: []const u8) ![]u8 {
        self.seq += 1;
        return ui.envelopeAlloc(self.allocator, event_type, self.seq, payload);
    }
    pub fn finishRound(self: *App) u64 {
        self.round += 1;
        return self.round;
    }

    pub fn applyAutomaticExclusions(
        self: *App,
        settings: *const config.Settings,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
        cwd: []const u8,
    ) !std.ArrayList(ExclusionOutcome) {
        var batch = try self.captureAutomaticExclusions(settings);
        defer batch.deinit();
        try batch.classify(settings, broker, cwd);
        const requests = try batch.requestsAlloc();
        defer self.allocator.free(requests);
        const results = try broker.synchronizeViewedBatch(
            owner,
            name,
            number,
            pull_request_id,
            batch.base_oid,
            batch.head_oid,
            requests,
        );
        defer self.allocator.free(results);
        return self.applyAutomaticExclusionResults(&batch, results);
    }

    pub fn captureAutomaticExclusions(
        self: *App,
        settings: *const config.Settings,
    ) !AutomaticExclusionBatch {
        const base_oid = try self.allocator.dupe(u8, self.generation.base_oid);
        const head_oid = self.allocator.dupe(u8, self.generation.head_oid) catch |err| {
            self.allocator.free(base_oid);
            return err;
        };
        var batch = AutomaticExclusionBatch{
            .allocator = self.allocator,
            .base_oid = base_oid,
            .head_oid = head_oid,
        };
        errdefer batch.deinit();
        if (!settings.exclusions_enabled) return batch;
        for (self.generation.files.items) |file| {
            if (file.viewed == .viewed) continue;
            var probe = try ExclusionProbe.init(
                self.allocator,
                file.path,
                file.previous_path,
                file.revision_key,
                settings.classifyPath(file.path),
            );
            errdefer probe.deinit();
            try batch.probes.append(self.allocator, probe);
        }
        return batch;
    }

    pub fn applyAutomaticExclusionResults(
        self: *App,
        batch: *const AutomaticExclusionBatch,
        results: []const github.Broker.ViewedBatchResult,
    ) !std.ArrayList(ExclusionOutcome) {
        if (!std.mem.eql(u8, self.generation.base_oid, batch.base_oid) or
            !std.mem.eql(u8, self.generation.head_oid, batch.head_oid))
        {
            return error.ExclusionGenerationChanged;
        }
        var outcomes: std.ArrayList(ExclusionOutcome) = .empty;
        errdefer {
            for (outcomes.items) |outcome| outcome.deinit();
            outcomes.deinit(self.allocator);
        }
        try self.applyExclusionResults(batch.candidates.items, results, &outcomes);
        return outcomes;
    }

    fn applyExclusionResults(
        self: *App,
        candidates: []const ExclusionCandidate,
        results: []const github.Broker.ViewedBatchResult,
        outcomes: *std.ArrayList(ExclusionOutcome),
    ) !void {
        for (candidates, results) |candidate, result| {
            const applied = try self.recordAutomaticExclusion(
                candidate.path,
                candidate.revision,
                candidate.reason,
                result.error_name,
                result.viewed,
            );
            if (!applied) return error.ExclusionGenerationChanged;
            try outcomes.append(
                self.allocator,
                try ExclusionOutcome.init(
                    self.allocator,
                    candidate.path,
                    candidate.reason,
                    result.error_name,
                ),
            );
        }
    }

    pub fn recordAutomaticExclusion(
        self: *App,
        path: []const u8,
        revision: []const u8,
        reason: []const u8,
        sync_error: ?[]const u8,
        viewed: bool,
    ) !bool {
        for (self.generation.files.items, 0..) |file, index| {
            if (!std.mem.eql(u8, file.path, path) or
                !std.mem.eql(u8, file.revision_key, revision)) continue;
            try self.generation.setExclusion(path, reason, sync_error);
            if (viewed) self.generation.files.items[index].viewed = .viewed;
            return true;
        }
        return false;
    }

    pub fn bootstrapAlloc(self: *App) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        try out.writer.writeAll("{\"schema\":\"synoptic-bootstrap/v1\",\"pullRequest\":");
        try self.writePullRequest(&out.writer);
        try out.writer.print(",\"primaryReady\":{},\"queue\":[", .{self.primary_ready});
        try self.writeQueue(&out.writer);
        try out.writer.writeAll("],\"tabs\":[");
        try self.writeTabs(&out.writer);
        try out.writer.writeAll("],\"actions\":[");
        for (self.action_store.cards.items, 0..) |card, i| {
            if (i > 0) try out.writer.writeByte(',');
            const encoded = try tools.cardJsonAlloc(self.allocator, card);
            defer self.allocator.free(encoded);
            try out.writer.writeAll(encoded);
        }
        try out.writer.print("],\"completedTabOpen\":{},\"actionStateFresh\":{},\"se" ++
            "q\":{d},\"round\":{d}}}", .{
            self.hasOpenCompletedTab(),
            self.action_state_fresh,
            self.seq,
            self.round,
        });
        return out.toOwnedSlice();
    }

    fn hasOpenCompletedTab(self: *const App) bool {
        for (self.tabs.items) |tab| if (tab.status == .completed) return true;
        return false;
    }

    fn writePullRequest(self: *const App, writer: *std.Io.Writer) !void {
        const format = "{{\"repository\":{f},\"number\":{d},\"title\":{f},\"ur" ++
            "l\":{f},\"baseRefName\":{f},\"baseRefOid\":{f},\"headR" ++
            "efName\":{f},\"headRefOid\":{f},\"state\":{f},\"isDraf" ++
            "t\":{}}}";
        if (self.pull_request) |header| try writer.print(format, .{
            std.json.fmt(header.repository, .{}),
            header.number,
            std.json.fmt(header.title, .{}),
            std.json.fmt(header.url, .{}),
            std.json.fmt(header.base_ref_name, .{}),
            std.json.fmt(header.base_ref_oid, .{}),
            std.json.fmt(header.head_ref_name, .{}),
            std.json.fmt(header.head_ref_oid, .{}),
            std.json.fmt(header.state, .{}),
            header.is_draft,
        }) else try writer.writeAll("null");
    }

    fn writeQueue(self: *const App, writer: *std.Io.Writer) !void {
        var first = true;
        for (self.generation.files.items) |file| if (file.viewed != .viewed) {
            if (!first) try writer.writeByte(',');
            first = false;
            const active = self.currentSessionId(file.path, file.revision_key);
            const arguments = .{
                std.json.fmt(file.path, .{}),
                file.additions,
                file.deletions,
                std.json.fmt(file.change_type, .{}),
                std.json.fmt(viewedStateName(file.viewed), .{}),
                std.json.fmt(file.revision_key, .{}),
                std.json.fmt(active, .{}),
                active != null,
                std.json.fmt(file.exclusion_reason, .{}),
                std.json.fmt(file.exclusion_sync_error, .{}),
            };
            try writer.print("{{\"path\":{f},\"additions\":{d},\"deletions\":{d},\"c" ++
                "hangeType\":{f},\"viewedState\":{f},\"revisionKey\":{f" ++
                "},\"activeSessionId\":{f},\"currentRevisionSession\":{" ++
                "},\"exclusionReason\":{f},\"exclusionSyncError\":{f}}}", arguments);
        };
    }

    fn writeTabs(self: *const App, writer: *std.Io.Writer) !void {
        var first = true;
        for (self.tabs.items) |tab| {
            if (tab.status == .closed) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            const arguments = .{
                std.json.fmt(tab.id, .{}),
                std.json.fmt(tab.id, .{}),
                std.json.fmt(tab.path, .{}),
                std.json.fmt(tab.revision, .{}),
                std.json.fmt(@tagName(tab.status), .{}),
                tab.reused,
                tab.initial_review,
                tab.turn_active,
                std.json.fmt(@tagName(tab.diff_state), .{}),
                std.json.fmt(if (tab.diff_state == .text) tab.diff else null, .{}),
            };
            try writer.print("{{\"id\":{f},\"sessionId\":{f},\"path\":{f},\"revision" ++
                "Key\":{f},\"status\":{f},\"reused\":{},\"initialReview" ++
                "\":{},\"turnActive\":{},\"diff\":{{\"state\":{f},\"text\":{f}}}}}", arguments);
        }
    }

    fn currentSessionId(self: *const App, path: []const u8, revision: []const u8) ?[]const u8 {
        for (self.tabs.items) |tab| {
            const matches = tab.status == .current and std.mem.eql(u8, tab.path, path) and
                std.mem.eql(u8, tab.revision, revision);
            if (matches) return tab.id;
        }
        return null;
    }
};

fn diffDisplayState(diff: []const u8) domain.DiffDisplayState {
    const binary = std.mem.indexOf(u8, diff, "GIT binary patch") != null or
        std.mem.indexOf(u8, diff, "Binary files ") != null;
    if (binary) return .binary;
    return .text;
}

fn viewedStateName(state: domain.ViewedState) []const u8 {
    return switch (state) {
        .viewed => "VIEWED",
        .unviewed => "UNVIEWED",
        .dismissed => "DISMISSED",
    };
}

pub fn exclusionMutationIdAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    revision: []const u8,
) ![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(path);
    hash.update(&.{0});
    hash.update(revision);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.allocPrint(allocator, "synoptic-auto-exclusion-{x}", .{digest});
}

test "close and completion are different transitions" {
    var app = try App.init(std.testing.allocator, "h");
    defer app.deinit();
    try app.generation.addFile(.{ .path = "a", .viewed = .unviewed, .revision_key = "r" });
    app.primary_ready = true;
    const event = try app.openFile("a");
    defer std.testing.allocator.free(event);
    app.close();
    try std.testing.expect(app.generation.queued("a"));
}

test "automatic exclusion results bind the complete base head generation" {
    const allocator = std.testing.allocator;
    var state = try App.init(allocator, "head");
    defer state.deinit();
    const current = try domain.PrGeneration.initFull(allocator, "base-b", "head");
    state.replaceGeneration(current);
    var batch = AutomaticExclusionBatch{
        .allocator = allocator,
        .base_oid = try allocator.dupe(u8, "base-a"),
        .head_oid = try allocator.dupe(u8, "head"),
    };
    defer batch.deinit();
    try std.testing.expectError(
        error.ExclusionGenerationChanged,
        state.applyAutomaticExclusionResults(&batch, &.{}),
    );
}

test "action invalidation updates the application snapshot" {
    var state = try App.init(std.testing.allocator, "h");
    defer state.deinit();
    const card = try state.action_store.prepare("s", "t", .{
        .slot = @constCast("finding"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("comment"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a.zig"),
        .line = 1,
        .body = @constCast("body"),
    }, .{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .base_oid = "unknown-base",
        .head_oid = "h",
        .session_path = "a.zig",
    });
    state.pending = card.*;
    try state.invalidateAction(card.id);
    try std.testing.expectEqual(tools.ActionStatus.invalidated, state.pending.?.status);
}

test {
    _ = pr;
    _ = sessions;
    _ = worktree;
}
