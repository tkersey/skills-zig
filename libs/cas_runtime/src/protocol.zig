const std = @import("std");

/// Correlation identity for an outbound client request.
pub const RequestHandle = struct {
    id: i64,
};

pub const TerminalState = enum {
    running,
    poisoned,
    disconnected,
    stopped,
};

/// Borrowed notification envelope delivered by the app-server read loop.
pub const Notification = struct {
    method: []const u8,
    raw_json: []const u8,
};

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
};

/// Borrowed server-initiated request envelope. The receiver must answer the
/// exact `id` before allowing the connection to advance past the request.
pub const ServerRequest = struct {
    id: RequestId,
    method: []const u8,
    raw_json: []const u8,
    deadline_ms: i64 = std.math.maxInt(i64),
};

/// A handler returns an owned exact JSON result. The actor serializes the
/// matching JSON-RPC response and frees the returned bytes after enqueueing.
/// `cancel` must be idempotent and must unblock any active `handle` call. The
/// actor invokes it when the request deadline expires and during shutdown.
pub const ServerRequestHandler = struct {
    context: *anyopaque,
    handle: *const fn (
        context: *anyopaque,
        request: ServerRequest,
        allocator: std.mem.Allocator,
    ) anyerror![]u8,
    cancel: *const fn (context: *anyopaque) void,
};

/// Notification callbacks are invoked serially by the permanent reader. The
/// envelope is borrowed only for the duration of the callback.
pub const NotificationHandler = struct {
    context: *anyopaque,
    handle: *const fn (context: *anyopaque, notification: Notification) void,
};

test "protocol carriers preserve correlation and raw envelopes" {
    const handle = RequestHandle{ .id = 42 };
    const notification = Notification{
        .method = "turn/started",
        .raw_json = "{\"method\":\"turn/started\"}",
    };
    const request = ServerRequest{
        .id = .{ .string = "approval-1" },
        .method = "item/commandExecution/requestApproval",
        .raw_json = "{}",
    };

    try std.testing.expectEqual(@as(i64, 42), handle.id);
    try std.testing.expectEqualStrings("turn/started", notification.method);
    try std.testing.expectEqualStrings(
        "item/commandExecution/requestApproval",
        request.method,
    );
    try std.testing.expectEqual(TerminalState.running, .running);
}
