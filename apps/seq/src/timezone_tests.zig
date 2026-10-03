const std = @import("std");
const time = @import("seq_time");

// The build runs this isolated process with TZ=America/Los_Angeles. Keeping
// timezone configuration outside the test avoids mutating process-global libc
// state while exercising both the translated ABI and the host timezone database.
test "local date conversion preserves DST boundaries and pre-epoch timestamps" {
    const cases = [_]struct { timestamp: []const u8, day: []const u8 }{
        .{ .timestamp = "2026-03-09T06:59:59Z", .day = "2026-03-08" },
        .{ .timestamp = "2026-03-09T07:00:00Z", .day = "2026-03-09" },
        .{ .timestamp = "2026-11-02T07:59:59Z", .day = "2026-11-01" },
        .{ .timestamp = "2026-11-02T08:00:00Z", .day = "2026-11-02" },
        .{ .timestamp = "1970-01-01T00:00:00Z", .day = "1969-12-31" },
        .{ .timestamp = "1969-12-31T23:59:59Z", .day = "1969-12-31" },
    };
    for (cases) |case| {
        const timestamp = time.parseIsoTimestampMillis(case.timestamp).?;
        const date = time.dateFromTimestampMillis(timestamp, .local) orelse
            return error.LocalDateUnavailable;
        var formatted: [10]u8 = undefined;
        time.formatDateInto(date, &formatted);
        try std.testing.expectEqualStrings(case.day, &formatted);
    }
    const before_epoch = time.dateFromTimestampMillis(-1, .utc).?;
    try std.testing.expectEqual(@as(i32, 1969), before_epoch.year);
    try std.testing.expectEqual(@as(u8, 31), before_epoch.day);
}
