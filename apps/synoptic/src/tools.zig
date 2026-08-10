const std = @import("std");

pub const ActionStatus = enum { pending, superseded, rejected, executing, succeeded, failed, outcome_unknown, invalidated };
pub const ActionCard = struct { id: []const u8, slot: []const u8, path: []const u8, line: u32, body: []const u8, status: ActionStatus = .pending };
pub const ToolPhase = enum { initial_review, conversation };

pub fn validateInline(card: ActionCard, current_path: []const u8) !void {
    if (card.status != .pending) return error.ActionNotPending;
    if (card.line == 0 or !std.mem.eql(u8, card.path, current_path) or card.body.len == 0) return error.InvalidInlineAction;
}

pub fn authorizeTool(phase: ToolPhase, human_directed: bool) !void {
    if (phase == .initial_review) return error.InitialReviewActionForbidden;
    if (!human_directed) return error.HumanDirectionRequired;
}

pub fn initialReviewMayPrepareAction(initial_turn: bool, human_directed: bool) bool {
    return !initial_turn and human_directed;
}
pub const ActionStore = struct {
    allocator: std.mem.Allocator,
    cards: std.ArrayList(ActionCard) = .empty,
    next_id: u64 = 1,
    pub fn deinit(self: *ActionStore) void {
        for (self.cards.items) |card| {
            self.allocator.free(card.id);
            self.allocator.free(card.slot);
            self.allocator.free(card.path);
            self.allocator.free(card.body);
        }
        self.cards.deinit(self.allocator);
    }
    pub fn prepare(self: *ActionStore, slot: []const u8, path: []const u8, line: u32, body: []const u8) !*ActionCard {
        for (self.cards.items) |*card| {
            if (card.status == .pending and std.mem.eql(u8, card.slot, slot)) card.status = .superseded;
        }
        const id = try std.fmt.allocPrint(self.allocator, "act-{d}", .{self.next_id});
        self.next_id += 1;
        try self.cards.append(self.allocator, .{ .id = id, .slot = try self.allocator.dupe(u8, slot), .path = try self.allocator.dupe(u8, path), .line = line, .body = try self.allocator.dupe(u8, body) });
        return &self.cards.items[self.cards.items.len - 1];
    }
    pub fn beginExecute(self: *ActionStore, id: []const u8) !*ActionCard {
        for (self.cards.items) |*card| if (std.mem.eql(u8, card.id, id)) {
            if (card.status != .pending) return error.ActionNotPending;
            card.status = .executing;
            return card;
        };
        return error.UnknownAction;
    }
    pub fn setTerminal(self: *ActionStore, id: []const u8, status: ActionStatus) !void {
        if (status != .succeeded and status != .failed and status != .outcome_unknown and status != .invalidated) return error.InvalidTerminalStatus;
        for (self.cards.items) |*card| if (std.mem.eql(u8, card.id, id)) {
            if (card.status != .executing) return error.ActionNotExecuting;
            card.status = status;
            return;
        };
        return error.UnknownAction;
    }
};
test "initial tool call is rejected even with plausible payload" {
    try std.testing.expectError(error.InitialReviewActionForbidden, authorizeTool(.initial_review, true));
}

test "initial review cannot mutate GitHub" {
    try std.testing.expect(!initialReviewMayPrepareAction(true, true));
}
test "same slot supersedes immutable prior card and execution is once" {
    var store = ActionStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    _ = try store.prepare("finding", "a", 1, "one");
    _ = try store.prepare("finding", "a", 2, "two");
    try std.testing.expectEqual(ActionStatus.superseded, store.cards.items[0].status);
    const current = try store.beginExecute("act-2");
    try std.testing.expectEqual(ActionStatus.executing, current.status);
    try std.testing.expectError(error.ActionNotPending, store.beginExecute("act-2"));
}
