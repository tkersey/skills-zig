const core_calendar = @import("core_calendar");
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c_time");
const iso_time = @import("trace_core").iso_time;

pub const parseIsoTimestampMillis = iso_time.parseIsoTimestampMillis;
pub const daysFromCivil = iso_time.daysFromCivil;
const daysInMonth = iso_time.daysInMonth;

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
    const year: u32 = @intCast(@max(date.year, 0));
    // This public fixed-width surface has always required fields to fit their columns.
    std.debug.assert(year <= 9999);
    std.debug.assert(date.month <= 99 and date.day <= 99);
    out.* = .{
        @intCast('0' + year / 1000),
        @intCast('0' + year / 100 % 10),
        @intCast('0' + year / 10 % 10),
        @intCast('0' + year % 10),
        '-',
        '0' + date.month / 10,
        '0' + date.month % 10,
        '-',
        '0' + date.day / 10,
        '0' + date.day % 10,
    };
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
    return allocator.print("{c}{d:0>2}:{d:0>2}", .{ sign, hours, mins });
}

fn dateFromTimestampMillisWithOffset(ts_ms: i64, offset_minutes: i32) Date {
    const shifted_seconds = @divFloor(ts_ms, 1000) + @as(i64, offset_minutes) * 60;
    const days = @divFloor(shifted_seconds, 86_400);
    return civilFromDays(days);
}

fn localDateFromTimestampMillis(ts_ms: i64) ?Date {
    if (builtin.target.os.tag == .windows) return null;

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
    const date = core_calendar.civilFromDays(days_since_unix_epoch, .legacy_negative_era);
    return .{
        .year = @intCast(date.year),
        .month = @intCast(date.month),
        .day = @intCast(date.day),
    };
}

test "parseIsoTimestampMillis handles offsets" {
    const utc = parseIsoTimestampMillis("2026-03-26T07:00:00Z") orelse unreachable;
    const offset = parseIsoTimestampMillis("2026-03-26T00:00:00-07:00") orelse unreachable;
    try std.testing.expectEqual(utc, offset);
}

test "fixed date formatting preserves padding and historical negative-year clipping" {
    var output: [10]u8 = undefined;
    formatDateInto(.{ .year = 2026, .month = 9, .day = 7 }, &output);
    try std.testing.expectEqualStrings("2026-09-07", &output);
    formatDateInto(.{ .year = -1, .month = 12, .day = 31 }, &output);
    try std.testing.expectEqualStrings("0000-12-31", &output);
    formatDateInto(.{ .year = 9999, .month = 12, .day = 31 }, &output);
    try std.testing.expectEqualStrings("9999-12-31", &output);
}

test "dateFromTimestampMillisWithOffset rebuckets by offset day" {
    const ts_ms = parseIsoTimestampMillis("2026-04-02T00:52:44.378Z") orelse unreachable;
    const date = dateFromTimestampMillis(
        ts_ms,
        .{ .fixed_offset_minutes = -7 * 60 },
    ) orelse unreachable;
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
