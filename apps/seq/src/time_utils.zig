const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("time.h");
});

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,
};

pub const TimeZone = union(enum) {
    utc,
    local,
    fixed_offset_minutes: i32,
};

pub fn parseIsoTimestampMillis(ts: []const u8) ?i64 {
    if (ts.len < 20) return null;
    if (ts[4] != '-' or ts[7] != '-' or ts[10] != 'T' or ts[13] != ':' or ts[16] != ':') return null;

    const year = std.fmt.parseInt(i64, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, ts[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, ts[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, ts[17..19], 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(@intCast(year), month)) return null;
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59) return null;

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
        if (offset_hours < 0 or offset_hours > 23 or offset_minutes < 0 or offset_minutes > 59) return null;
        offset_seconds = offset_hours * 3600 + offset_minutes * 60;
        if (sign == '-') offset_seconds = -offset_seconds;
        idx += 6;
    }
    if (idx != ts.len) return null;

    const days = daysFromCivil(year, month, day);
    const day_seconds = hour * 3600 + minute * 60 + second - offset_seconds;
    return (days * 86_400 + day_seconds) * 1000 + millis;
}

pub fn parseTimeZone(raw_opt: ?[]const u8) !TimeZone {
    const raw = raw_opt orelse return .utc;
    if (std.ascii.eqlIgnoreCase(raw, "utc") or std.mem.eql(u8, raw, "Z")) return .utc;
    if (std.ascii.eqlIgnoreCase(raw, "local")) return .local;
    const mins = parseOffsetMinutes(raw) orelse return error.InvalidTimeZone;
    return .{ .fixed_offset_minutes = mins };
}

pub fn timeZoneLabelAlloc(allocator: std.mem.Allocator, tz: TimeZone) ![]u8 {
    return switch (tz) {
        .utc => allocator.dupe(u8, "utc"),
        .local => allocator.dupe(u8, "local"),
        .fixed_offset_minutes => |mins| formatOffsetMinutesAlloc(allocator, mins),
    };
}

pub fn dateFromTimestampMillis(ts_ms: i64, tz: TimeZone) ?Date {
    return switch (tz) {
        .utc => dateFromTimestampMillisWithOffset(ts_ms, 0),
        .fixed_offset_minutes => |mins| dateFromTimestampMillisWithOffset(ts_ms, mins),
        .local => localDateFromTimestampMillis(ts_ms),
    };
}

pub fn dateFromUtcTimestampMillis(ts_ms: i64) Date {
    return dateFromTimestampMillisWithOffset(ts_ms, 0);
}

pub fn formatDateInto(date: Date, out: *[10]u8) void {
    _ = std.fmt.bufPrint(out[0..], "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(@max(date.year, 0))),
        date.month,
        date.day,
    }) catch unreachable;
}

pub fn parseDayLiteral(text: []const u8) ?Date {
    if (text.len != 10) return null;
    if (text[4] != '-' or text[7] != '-') return null;
    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;
    return .{ .year = year, .month = month, .day = day };
}

pub fn compareIsoInstants(lhs: []const u8, rhs: []const u8) ?std.math.Order {
    const lhs_ms = parseIsoTimestampMillis(lhs) orelse return null;
    const rhs_ms = parseIsoTimestampMillis(rhs) orelse return null;
    return std.math.order(lhs_ms, rhs_ms);
}

pub fn daysBetweenInclusive(start: Date, end: Date) i64 {
    const start_days = daysFromCivil(start.year, start.month, start.day);
    const end_days = daysFromCivil(end.year, end.month, end.day);
    return end_days - start_days + 1;
}

pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    var adjusted_year = year;
    if (month <= 2) adjusted_year -= 1;
    const era = @divFloor(if (adjusted_year >= 0) adjusted_year else adjusted_year - 399, 400);
    const yoe = adjusted_year - era * 400;
    const shifted_month: i64 = @as(i64, @intCast(month)) + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * shifted_month + 2, 5) + @as(i64, @intCast(day)) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn parseOffsetMinutes(text: []const u8) ?i32 {
    if (text.len != 6) return null;
    const sign = text[0];
    if (sign != '+' and sign != '-') return null;
    if (text[3] != ':') return null;
    const hours = std.fmt.parseInt(i32, text[1..3], 10) catch return null;
    const minutes = std.fmt.parseInt(i32, text[4..6], 10) catch return null;
    if (hours < 0 or hours > 23 or minutes < 0 or minutes > 59) return null;
    var total = hours * 60 + minutes;
    if (sign == '-') total = -total;
    return total;
}

fn formatOffsetMinutesAlloc(allocator: std.mem.Allocator, minutes: i32) ![]u8 {
    const sign: u8 = if (minutes < 0) '-' else '+';
    const abs_minutes = @abs(minutes);
    const hours = @divFloor(abs_minutes, 60);
    const mins = @mod(abs_minutes, 60);
    return std.fmt.allocPrint(allocator, "{c}{d:0>2}:{d:0>2}", .{ sign, hours, mins });
}

fn dateFromTimestampMillisWithOffset(ts_ms: i64, offset_minutes: i32) Date {
    const shifted_seconds = @divFloor(ts_ms, 1000) + @as(i64, offset_minutes) * 60;
    const days = @divFloor(shifted_seconds, 86_400);
    return civilFromDays(days);
}

fn localDateFromTimestampMillis(ts_ms: i64) ?Date {
    if (builtin.os.tag == .windows) return null;

    var seconds: c.time_t = @intCast(@divFloor(ts_ms, 1000));
    var tm_buf: c.struct_tm = undefined;
    if (c.localtime_r(&seconds, &tm_buf) == null) return null;
    return .{
        .year = tm_buf.tm_year + 1900,
        .month = @intCast(tm_buf.tm_mon + 1),
        .day = @intCast(tm_buf.tm_mday),
    };
}

fn civilFromDays(days_since_unix_epoch: i64) Date {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    if (month <= 2) year += 1;
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

test "parseIsoTimestampMillis handles offsets" {
    const utc = parseIsoTimestampMillis("2026-03-26T07:00:00Z") orelse unreachable;
    const offset = parseIsoTimestampMillis("2026-03-26T00:00:00-07:00") orelse unreachable;
    try std.testing.expectEqual(utc, offset);
}

test "dateFromTimestampMillisWithOffset rebuckets by offset day" {
    const ts_ms = parseIsoTimestampMillis("2026-04-02T00:52:44.378Z") orelse unreachable;
    const date = dateFromTimestampMillis(ts_ms, .{ .fixed_offset_minutes = -7 * 60 }) orelse unreachable;
    try std.testing.expectEqual(@as(i32, 2026), date.year);
    try std.testing.expectEqual(@as(u8, 4), date.month);
    try std.testing.expectEqual(@as(u8, 1), date.day);
}

test "parseTimeZone accepts local utc and fixed offsets" {
    try std.testing.expectEqual(TimeZone.utc, try parseTimeZone("utc"));
    try std.testing.expectEqual(TimeZone.local, try parseTimeZone("local"));
    const offset = try parseTimeZone("-07:00");
    try std.testing.expectEqual(@as(i32, -7 * 60), offset.fixed_offset_minutes);
}
