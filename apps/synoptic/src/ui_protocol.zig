const std = @import("std");

pub const schema = "synoptic-ui/v1";

pub fn envelopeAlloc(
    allocator: std.mem.Allocator,
    event_type: []const u8,
    seq: u64,
    payload_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"");
    try out.writer.writeAll(schema);
    try out.writer.writeAll("\",\"type\":");
    try std.json.Stringify.value(event_type, .{}, &out.writer);
    try out.writer.print(",\"seq\":{d},\"payload\":", .{seq});
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn commandType(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidUiCommand,
    };
    const value = obj.get("type") orelse return error.InvalidUiCommand;
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.InvalidUiCommand,
    };
}

pub const allowed_commands = [_][]const u8{
    "file.open",
    "session.message",
    "session.interrupt",
    "session.close",
    "approval.resolve",
    "action.confirm",
    "action.reject",
    "snapshot.get",
    "pr.refresh",
    "round.finish",
    "app.stop",
};
pub const autonomous_events = [_][]const u8{
    "session.item.delta",
    "approval.requested",
    "approval.resolved",
    "action.prepared",
    "action.superseded",
    "action.status",
    "file.completed",
    "session.closed",
    "app.stopped",
};
pub fn commandAllowed(value: []const u8) bool {
    for (allowed_commands) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

pub fn visibleEventPayloadAlloc(
    allocator: std.mem.Allocator,
    session_id: ?[]const u8,
    method: []const u8,
    raw: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"sessionId\":{f},\"method\":{f},\"raw\":{f}}}",
        .{
            std.json.fmt(session_id orelse "", .{}),
            std.json.fmt(method, .{}),
            std.json.fmt(raw, .{}),
        },
    );
}

test "domain envelopes are versioned and sequenced" {
    const bytes = try envelopeAlloc(std.testing.allocator, "queue.updated", 7, "{}");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"seq\":7") != null);
}
test "browser cannot bypass model action authority" {
    try std.testing.expect(!commandAllowed("action.prepare"));
    try std.testing.expect(!commandAllowed("file.complete"));
    try std.testing.expect(!commandAllowed("events.poll"));
}
