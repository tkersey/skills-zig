const std = @import("std");
const observation = @import("observation");

const polls: usize = 1000;
const captured_line = "{\"method\":\"item/completed\",\"params\":{\"turnId\":\"turn\"," ++
    "\"item\":{\"type\":\"agentMessage\",\"text\":\"answer\"}}}";
const expected_params =
    \\{
    \\  "threadId": "synthetic-thread",
    \\  "includeTurns": true
    \\}
;

const Measurement = struct {
    allocations: usize,
    allocated_bytes: usize,
    consumed_bytes: usize,
};

pub fn main(init: std.process.Init) !void {
    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    const writer = &stdout.interface;
    try writer.writeAll(
        "variant\tpolls\tnotifications_per_poll\tallocations\tallocated_bytes\tconsumed_bytes\n",
    );
    for ([_]usize{ 0, 8, 64 }) |notification_count| {
        const baseline = try measure(init.gpa, notification_count, false);
        const candidate = try measure(init.gpa, notification_count, true);
        if (baseline.consumed_bytes != candidate.consumed_bytes) return error.CaptureMismatch;
        try writeMeasurement(writer, "baseline", notification_count, baseline);
        try writeMeasurement(writer, "candidate", notification_count, candidate);
    }
}

fn measure(
    allocator: std.mem.Allocator,
    notification_count: usize,
    comptime retained: bool,
) !Measurement {
    var counted = std.testing.FailingAllocator.init(allocator, .{});
    const consumed = if (retained)
        try captureRetained(counted.allocator(), notification_count)
    else
        try captureBaseline(counted.allocator(), notification_count);
    if (counted.allocated_bytes != counted.freed_bytes) return error.LeakedMemory;
    return .{
        .allocations = counted.allocations,
        .allocated_bytes = counted.allocated_bytes,
        .consumed_bytes = consumed,
    };
}

fn writeMeasurement(
    writer: *std.Io.Writer,
    variant: []const u8,
    notification_count: usize,
    result: Measurement,
) !void {
    try writer.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        variant,            polls,                  notification_count,
        result.allocations, result.allocated_bytes, result.consumed_bytes,
    });
}

fn parameters(allocator: std.mem.Allocator) ![]u8 {
    const result = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .threadId = "synthetic-thread", .includeTurns = true },
        .{ .whitespace = .indent_2 },
    );
    errdefer allocator.free(result);
    if (!std.mem.eql(u8, expected_params, result)) return error.ParametersChanged;
    return result;
}

fn appendNotifications(
    allocator: std.mem.Allocator,
    notifications: *std.ArrayList([]u8),
    count: usize,
) !void {
    for (0..count) |_| {
        const line = try allocator.dupe(u8, captured_line);
        notifications.append(allocator, line) catch |err| {
            allocator.free(line);
            return err;
        };
    }
}

fn captureBaseline(allocator: std.mem.Allocator, notification_count: usize) !usize {
    var bytes: usize = 0;
    for (0..polls) |_| {
        const params = try parameters(allocator);
        defer allocator.free(params);
        var notifications: std.ArrayList([]u8) = .empty;
        defer {
            for (notifications.items) |line| allocator.free(line);
            notifications.deinit(allocator);
        }
        try appendNotifications(allocator, &notifications, notification_count);
        bytes += params.len;
        for (notifications.items) |line| bytes += line.len;
    }
    return bytes;
}

fn captureRetained(allocator: std.mem.Allocator, notification_count: usize) !usize {
    var bytes: usize = 0;
    const params = try parameters(allocator);
    defer allocator.free(params);
    var notifications: std.ArrayList([]u8) = .empty;
    defer {
        observation.clearNotifications(allocator, &notifications);
        notifications.deinit(allocator);
    }
    for (0..polls) |_| {
        defer observation.clearNotifications(allocator, &notifications);
        try appendNotifications(allocator, &notifications, notification_count);
        bytes += params.len;
        for (notifications.items) |line| bytes += line.len;
    }
    return bytes;
}
