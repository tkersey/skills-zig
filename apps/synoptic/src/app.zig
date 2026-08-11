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

pub const App = struct {
    allocator: std.mem.Allocator,
    generation: domain.PrGeneration,
    primary_ready: bool = false,
    seq: u64 = 0,
    open_path: ?[]u8 = null,
    completed_tab_open: bool = false,
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
        const card = try self.action_store.prepare(
            session_id,
            source_turn_id,
            input,
            .{
                .repository = repository,
                .pull_request = pull_request,
                .pull_request_id = pull_request_id,
                .head_oid = self.generation.head_oid,
                .session_path = session_path,
            },
        );
        self.pending = card.*;
        return card.*;
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
    ) !?tools.ActionStatus {
        broker.executeAction(card.*) catch |err| {
            if (err == error.GitHubTransportAmbiguous) {
                const reconciled = broker.reconcileAction(
                    owner,
                    name,
                    number,
                    card.*,
                    started_unix_s,
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
        for (self.action_store.cards.items) |card| if (std.mem.eql(u8, card.id, card_id)) {
            self.pending = card;
            return;
        };
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
            self.generation.head_oid,
            path,
        );
        try broker.markViewed(pull_request_id, path);
        if (!try broker.viewedAfterMutation(
            owner,
            name,
            number,
            self.generation.head_oid,
            path,
        )) return error.MarkViewedReadbackFailed;
        try self.generation.markViewed(path);
        self.completed_tab_open = true;
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
            self.generation.head_oid,
            path,
        )) return error.MarkViewedReadbackFailed;
        try self.generation.markViewed(path);
        for (self.tabs.items) |*tab| {
            if (std.mem.eql(u8, tab.path, path) and std.mem.eql(u8, tab.revision, revision) and
                tab.status == .current) tab.status = .completed;
        }
        self.completed_tab_open = true;
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
    pub fn closeTab(self: *App, path: []const u8, revision: []const u8) !void {
        for (self.tabs.items) |*tab| {
            if (std.mem.eql(u8, tab.path, path) and std.mem.eql(u8, tab.revision, revision) and
                tab.status != .closed)
            {
                tab.status = .closed;
                return;
            }
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
        var outcomes: std.ArrayList(ExclusionOutcome) = .empty;
        errdefer {
            for (outcomes.items) |outcome| outcome.deinit();
            outcomes.deinit(self.allocator);
        }
        for (0..self.generation.files.items.len) |index| {
            if (!settings.exclusions_enabled) break;
            const outcome = try self.excludeFile(
                settings,
                broker,
                owner,
                name,
                number,
                pull_request_id,
                cwd,
                index,
            ) orelse continue;
            try outcomes.append(self.allocator, outcome);
        }
        return outcomes;
    }

    fn excludeFile(
        self: *App,
        settings: *const config.Settings,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
        cwd: []const u8,
        index: usize,
    ) !?ExclusionOutcome {
        const file = self.generation.files.items[index];
        if (file.viewed == .viewed) return null;
        const reason = settings.classifyPath(file.path) orelse binary: {
            const diff = github.canonicalDiffAlloc(
                self.allocator,
                broker.io,
                cwd,
                self.generation.base_oid,
                self.generation.head_oid,
                file.path,
            ) catch return null;
            defer self.allocator.free(diff);
            break :binary settings.classifyDiff(diff) orelse return null;
        };
        const client_id = try exclusionMutationIdAlloc(
            self.allocator,
            file.path,
            file.revision_key,
        );
        defer self.allocator.free(client_id);
        var mutation_error: ?[]const u8 = null;
        broker.markViewedWithId(pull_request_id, file.path, client_id) catch |err| {
            mutation_error = @errorName(err);
        };
        var readback_error: ?[]const u8 = null;
        const viewed = broker.viewedAfterMutation(
            owner,
            name,
            number,
            self.generation.head_oid,
            file.path,
        ) catch |err| blk: {
            readback_error = @errorName(err);
            break :blk false;
        };
        const sync_error: ?[]const u8 = if (viewed) null else readback_error orelse
            mutation_error orelse "MarkViewedReadbackFailed";
        if (viewed) self.generation.files.items[index].viewed = .viewed;
        try self.generation.setExclusion(file.path, reason, sync_error);
        return try ExclusionOutcome.init(self.allocator, file.path, reason, sync_error);
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
            self.completed_tab_open,
            self.action_state_fresh,
            self.seq,
            self.round,
        });
        return out.toOwnedSlice();
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
                std.json.fmt(@tagName(tab.diff_state), .{}),
                std.json.fmt(if (tab.diff_state == .text) tab.diff else null, .{}),
            };
            try writer.print("{{\"id\":{f},\"sessionId\":{f},\"path\":{f},\"revision" ++
                "Key\":{f},\"status\":{f},\"reused\":{},\"initialReview" ++
                "\":{},\"diff\":{{\"state\":{f},\"text\":{f}}}}}", arguments);
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

fn exclusionMutationIdAlloc(
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

test {
    _ = pr;
    _ = sessions;
    _ = worktree;
}
