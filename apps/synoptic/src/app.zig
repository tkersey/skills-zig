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

    pub fn init(allocator: std.mem.Allocator, head: []const u8) !App {
        return .{ .allocator = allocator, .generation = try .init(allocator, head) };
    }
    pub fn deinit(self: *App) void {
        self.generation.deinit();
        if (self.open_path) |p| self.allocator.free(p);
    }

    pub fn openFile(self: *App, path: []const u8) ![]u8 {
        if (!self.primary_ready) return error.PrimaryNotReady;
        if (!self.generation.queued(path)) return error.FileNotQueued;
        if (self.open_path) |old| self.allocator.free(old);
        self.open_path = try self.allocator.dupe(u8, path);
        self.seq += 1;
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"path\":{f},\"initialReview\":true}}", .{std.json.fmt(path, .{})}); defer self.allocator.free(payload);
        return ui.envelopeAlloc(self.allocator, "session.opened", self.seq, payload);
    }

    pub fn prepareInline(self: *App, path: []const u8, line: u32, body: []const u8, human_directed: bool) !void {
        if (!tools.initialReviewMayPrepareAction(false, human_directed)) return error.HumanDirectionRequired;
        const card = tools.ActionCard{ .id = "act-1", .slot = "finding-1", .path = path, .line = line, .body = body };
        try tools.validateInline(card, self.open_path orelse return error.NoOpenSession);
        self.pending = card;
    }

    pub fn confirmInline(self: *App, broker: github.Broker, pull_request_id: []const u8, head_oid: []const u8) !void {
        var card = self.pending orelse return error.NoPendingAction;
        try tools.validateInline(card, self.open_path orelse return error.NoOpenSession);
        card.status = .executing; self.pending = card;
        const vars = try std.fmt.allocPrint(self.allocator,
            "{{\"input\":{{\"pullRequestId\":{f},\"commitOID\":{f},\"event\":\"COMMENT\",\"threads\":[{{\"path\":{f},\"line\":{d},\"side\":\"RIGHT\",\"body\":{f}}}]}}}}",
            .{ std.json.fmt(pull_request_id, .{}), std.json.fmt(head_oid, .{}), std.json.fmt(card.path, .{}), card.line, std.json.fmt(card.body, .{}) });
        defer self.allocator.free(vars);
        const response = broker.call(graphql.add_inline_comment_mutation, vars) catch |err| { card.status = .failed; self.pending = card; return err; };
        broker.allocator.free(response); card.status = .succeeded; self.pending = card;
    }

    pub fn complete(self: *App, broker: github.Broker, pull_request_id: []const u8, path: []const u8, human_directed: bool) !void {
        if (!human_directed) return error.HumanDirectionRequired;
        if (self.open_path == null or !std.mem.eql(u8, self.open_path.?, path) or !self.generation.queued(path)) return error.NotOfficialCurrentSession;
        try broker.markViewed(pull_request_id, path);
        try self.generation.markViewed(path);
        self.completed_tab_open = true;
    }

    pub fn close(self: *App) void {
        if (self.open_path) |p| self.allocator.free(p);
        self.open_path = null;
    }

    pub fn bootstrapAlloc(self: *App) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator); errdefer out.deinit();
        try out.writer.print("{{\"schema\":\"synoptic-bootstrap/v1\",\"primaryReady\":{},\"queue\":[", .{self.primary_ready});
        var first = true;
        for (self.generation.files.items) |file| if (file.viewed != .viewed) {
            if (!first) try out.writer.writeByte(','); first = false;
            try out.writer.print("{{\"path\":{f},\"additions\":{d},\"deletions\":{d}}}", .{std.json.fmt(file.path, .{}), file.additions, file.deletions});
        };
        try out.writer.print("],\"completedTabOpen\":{}}}", .{self.completed_tab_open});
        return out.toOwnedSlice();
    }
};

test "close and completion are different transitions" {
    var app = try App.init(std.testing.allocator, "h"); defer app.deinit();
    try app.generation.addFile(.{ .path = "a", .viewed = .unviewed, .revision_key = "r" });
    app.primary_ready = true;
    const event = try app.openFile("a"); defer std.testing.allocator.free(event);
    app.close();
    try std.testing.expect(app.generation.queued("a"));
}

test { _ = pr; _ = sessions; _ = worktree; }
