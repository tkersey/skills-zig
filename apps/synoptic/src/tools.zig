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
test "initial tool call is rejected even with plausible payload" { try std.testing.expectError(error.InitialReviewActionForbidden, authorizeTool(.initial_review, true)); }

test "initial review cannot mutate GitHub" {
    try std.testing.expect(!initialReviewMayPrepareAction(true, true));
}
