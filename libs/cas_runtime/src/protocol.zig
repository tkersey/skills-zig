const std = @import("std");

/// Correlation identity for an outbound client request.
pub const RequestHandle = struct {
    id: i64,
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
}
