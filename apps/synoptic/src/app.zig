const std = @import("std");
const domain = @import("domain.zig");
const github = @import("github.zig");
const graphql = @import("graphql.zig");
const pr = @import("pr.zig");
const sessions = @import("sessions.zig");
const tools = @import("tools.zig");
const ui = @import("ui_protocol.zig");
const worktree = @import("worktree.zig");

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

    pub fn init(allocator: std.mem.Allocator, head: []const u8) !App {
        return .{ .allocator = allocator, .generation = try .init(allocator, head), .action_store = .{ .allocator = allocator } };
    }
    pub fn deinit(self: *App) void {
        self.generation.deinit();
        if (self.open_path) |p| self.allocator.free(p);
        if (self.official_revision) |r| self.allocator.free(r);
        for (self.tabs.items) |tab| {
            self.allocator.free(tab.id);
            self.allocator.free(tab.path);
            self.allocator.free(tab.revision);
        }
        self.tabs.deinit(self.allocator);
        self.action_store.deinit();
    }

    pub fn replaceGeneration(self: *App, next: domain.PrGeneration) void {
        self.generation.deinit();
        self.generation = next;
        for (self.tabs.items) |*tab| {
            if (domain.revisionFor(&next, tab.path)) |revision| {
                if (!std.mem.eql(u8, tab.revision, revision) and tab.status == .current) tab.status = .stale_origin;
            }
        }
    }

    pub fn openFile(self: *App, path: []const u8) ![]u8 {
        if (!self.primary_ready) return error.PrimaryNotReady;
        if (!self.generation.queued(path)) return error.FileNotQueued;
        if (self.open_path) |old| self.allocator.free(old);
        self.open_path = try self.allocator.dupe(u8, path);
        if (self.official_revision) |old| self.allocator.free(old);
        for (self.generation.files.items) |file| if (std.mem.eql(u8, file.path, path)) {
            self.official_revision = try self.allocator.dupe(u8, file.revision_key);
            break;
        };
        self.initial_review_active = true;
        var existing = false;
        for (self.tabs.items) |tab| {
            if (tab.status == .current and std.mem.eql(u8, tab.path, path) and std.mem.eql(u8, tab.revision, self.official_revision.?)) existing = true;
        }
        if (!existing) {
            const id = try std.fmt.allocPrint(self.allocator, "tab-{d}", .{self.tabs.items.len + 1});
            try self.tabs.append(self.allocator, .{ .id = id, .path = try self.allocator.dupe(u8, path), .revision = try self.allocator.dupe(u8, self.official_revision.?) });
        }
        self.seq += 1;
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"path\":{f},\"initialReview\":true}}", .{std.json.fmt(path, .{})});
        defer self.allocator.free(payload);
        return ui.envelopeAlloc(self.allocator, "session.opened", self.seq, payload);
    }

    pub fn prepareInline(self: *App, path: []const u8, line: u32, body: []const u8, human_directed: bool) !void {
        try tools.authorizeTool(if (self.initial_review_active) .initial_review else .conversation, human_directed);
        const proposed = tools.ActionCard{ .id = "pending", .slot = "finding-1", .path = path, .line = line, .body = body };
        try tools.validateInline(proposed, self.open_path orelse return error.NoOpenSession);
        const card = try self.action_store.prepare("finding-1", path, line, body);
        self.pending = card.*;
    }

    pub fn confirmInline(self: *App, broker: github.Broker, pull_request_id: []const u8, head_oid: []const u8) !void {
        var card = self.pending orelse return error.NoPendingAction;
        try tools.validateInline(card, self.open_path orelse return error.NoOpenSession);
        _ = try self.action_store.beginExecute(card.id);
        card.status = .executing;
        self.pending = card;
        const vars = try std.fmt.allocPrint(self.allocator, "{{\"input\":{{\"pullRequestId\":{f},\"commitOID\":{f},\"event\":\"COMMENT\",\"threads\":[{{\"path\":{f},\"line\":{d},\"side\":\"RIGHT\",\"body\":{f}}}]}}}}", .{ std.json.fmt(pull_request_id, .{}), std.json.fmt(head_oid, .{}), std.json.fmt(card.path, .{}), card.line, std.json.fmt(card.body, .{}) });
        defer self.allocator.free(vars);
        const response = broker.call(graphql.add_inline_comment_mutation, vars) catch |err| {
            card.status = if (err == error.GitHubTransportAmbiguous) .outcome_unknown else .failed;
            self.action_store.setTerminal(card.id, card.status) catch {};
            self.pending = card;
            return err;
        };
        broker.allocator.free(response);
        card.status = .succeeded;
        try self.action_store.setTerminal(card.id, .succeeded);
        self.pending = card;
    }

    pub fn complete(self: *App, broker: github.Broker, owner: []const u8, name: []const u8, number: u64, pull_request_id: []const u8, path: []const u8, human_directed: bool) !void {
        if (!human_directed) return error.HumanDirectionRequired;
        if (self.open_path == null or !std.mem.eql(u8, self.open_path.?, path) or !self.generation.queued(path)) return error.NotOfficialCurrentSession;
        const revision = self.official_revision orelse return error.NotOfficialCurrentSession;
        for (self.generation.files.items) |file| if (std.mem.eql(u8, file.path, path) and !std.mem.eql(u8, file.revision_key, revision)) return error.StaleOriginSession;
        try broker.markViewed(pull_request_id, path);
        if (!try broker.viewedAfterMutation(owner, name, number, self.generation.head_oid, path)) return error.MarkViewedReadbackFailed;
        try self.generation.markViewed(path);
        self.completed_tab_open = true;
        for (self.tabs.items) |*tab| {
            if (tab.status == .current and std.mem.eql(u8, tab.path, path)) tab.status = .completed;
        }
    }

    pub fn close(self: *App) void {
        if (self.open_path) |p| self.allocator.free(p);
        self.open_path = null;
        self.initial_review_active = false;
        for (self.tabs.items) |*tab| {
            if (tab.status != .closed and (self.official_revision == null or std.mem.eql(u8, tab.revision, self.official_revision.?))) tab.status = .closed;
        }
    }

    pub fn nextEnvelope(self: *App, event_type: []const u8, payload: []const u8) ![]u8 {
        self.seq += 1;
        return ui.envelopeAlloc(self.allocator, event_type, self.seq, payload);
    }
    pub fn finishRound(self: *App) u64 {
        self.round += 1;
        return self.round;
    }

    pub fn bootstrapAlloc(self: *App) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        try out.writer.print("{{\"schema\":\"synoptic-bootstrap/v1\",\"primaryReady\":{},\"queue\":[", .{self.primary_ready});
        var first = true;
        for (self.generation.files.items) |file| if (file.viewed != .viewed) {
            if (!first) try out.writer.writeByte(',');
            first = false;
            try out.writer.print("{{\"path\":{f},\"additions\":{d},\"deletions\":{d}}}", .{ std.json.fmt(file.path, .{}), file.additions, file.deletions });
        };
        try out.writer.print("],\"tabs\":[", .{});
        for (self.tabs.items, 0..) |tab, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.print("{{\"id\":{f},\"path\":{f},\"revision\":{f},\"status\":{f}}}", .{ std.json.fmt(tab.id, .{}), std.json.fmt(tab.path, .{}), std.json.fmt(tab.revision, .{}), std.json.fmt(@tagName(tab.status), .{}) });
        }
        try out.writer.print("],\"completedTabOpen\":{},\"seq\":{d},\"round\":{d}}}", .{ self.completed_tab_open, self.seq, self.round });
        return out.toOwnedSlice();
    }
};

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
