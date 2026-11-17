const std = @import("std");

pub fn parseIsoTimestampMillis(ts: []const u8) ?i64 {
    if (ts.len < 20) return null;
    if (ts[4] != '-' or ts[7] != '-' or ts[10] != 'T' or
        ts[13] != ':' or ts[16] != ':') return null;

    const year = std.fmt.parseInt(i64, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, ts[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, ts[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, ts[17..19], 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(@intCast(year), month)) return null;
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59 or
        second < 0 or second > 59) return null;

    var idx: usize = 19;
    var millis: i64 = 0;
    if (idx < ts.len and ts[idx] == '.') {
        idx += 1;
        var digit_count: usize = 0;
        while (idx < ts.len and std.ascii.isDigit(ts[idx])) : (idx += 1) {
            if (digit_count < 3) millis = millis * 10 + (ts[idx] - '0');
            digit_count += 1;
        }
        if (digit_count == 0) return null;
        while (digit_count < 3) : (digit_count += 1) millis *= 10;
    }

    var offset_seconds: i64 = 0;
    if (idx == ts.len - 1 and ts[idx] == 'Z') {
        idx += 1;
    } else {
        if (idx + 6 != ts.len) return null;
        const sign = ts[idx];
        if (sign != '+' and sign != '-') return null;
        if (ts[idx + 3] != ':') return null;
        const offset_hours = std.fmt.parseInt(i64, ts[idx + 1 .. idx + 3], 10) catch return null;
        const offset_minutes = std.fmt.parseInt(i64, ts[idx + 4 .. idx + 6], 10) catch return null;
        if (offset_hours < 0 or offset_hours > 23 or
            offset_minutes < 0 or offset_minutes > 59) return null;
        offset_seconds = offset_hours * 3600 + offset_minutes * 60;
        if (sign == '-') offset_seconds = -offset_seconds;
        idx += 6;
    }
    if (idx != ts.len) return null;

    const days = daysFromCivil(year, month, day);
    const day_seconds = hour * 3600 + minute * 60 + second - offset_seconds;
    return (days * 86_400 + day_seconds) * 1000 + millis;
}

pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    var adjusted_year = year;
    if (month <= 2) adjusted_year -= 1;
    const era = @divFloor(if (adjusted_year >= 0) adjusted_year else adjusted_year - 399, 400);
    const yoe = adjusted_year - era * 400;
    const shifted_month: i64 = @as(i64, @intCast(month)) +
        (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * shifted_month + 2, 5) + @as(i64, @intCast(day)) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

test "ISO instants reject impossible calendar fields" {
    try std.testing.expectEqual(@as(?i64, 0), parseIsoTimestampMillis("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(
        @as(?i64, 1_794_678_204_397),
        parseIsoTimestampMillis("2026-11-14T17:43:24.397Z"),
    );
    const rejected = [_][]const u8{
        "2026-11-14",           "2026-11-31T00:00:00Z", "2026-02-29T00:00:00Z",
        "2026-11-14T23:59:60Z", "2026-11-14T-1:00:00Z", "2026-11-14T00:00:00+24:00",
    };
    for (rejected) |text| {
        try std.testing.expectEqual(@as(?i64, null), parseIsoTimestampMillis(text));
    }
}
