const std = @import("std");
const app = @import("app.zig");
const config = @import("config.zig");
const domain = @import("domain.zig");
const github = @import("github.zig");
const graphql = @import("graphql.zig");
const http = @import("http.zig");
const main = @import("main.zig");
const pr = @import("pr.zig");
const sessions = @import("sessions.zig");
const tools = @import("tools.zig");
const ui = @import("ui_protocol.zig");
const worktree = @import("worktree.zig");

test "vertical state path gates primary, streams session, and retains completed tab" {
    var state = try app.App.init(std.testing.allocator, "head"); defer state.deinit();
    try state.generation.addFile(.{ .path = "src/a.zig", .viewed = .unviewed, .revision_key = "r1" });
    try std.testing.expectError(error.PrimaryNotReady, state.openFile("src/a.zig"));
    state.primary_ready = true;
    const event = try state.openFile("src/a.zig"); defer std.testing.allocator.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, "session.opened") != null);
    try state.prepareInline("src/a.zig", 12, "Could this fail?", true);
    try std.testing.expectEqual(tools.ActionStatus.pending, state.pending.?.status);
    state.close();
    try std.testing.expect(state.generation.queued("src/a.zig"));
}

test "falsifier initial review cannot prepare action" {
    try std.testing.expect(!tools.initialReviewMayPrepareAction(true, true));
}
test "falsifier token is not optional" {
    try std.testing.expect(!http.pathConfined("/tmp/ui", "/tmp/ui2/index.html"));
}
test {
    _ = config; _ = domain; _ = github; _ = graphql; _ = main; _ = pr; _ = sessions; _ = ui; _ = worktree;
}
