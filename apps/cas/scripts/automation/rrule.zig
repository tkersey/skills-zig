const core_calendar = @import("core_calendar");
const std = @import("std");

pub const Day = enum {
    FR,
    MO,
    SA,
    SU,
    TH,
    TU,
    WE,

    pub fn parse(io: std.Io, raw: []const u8) !Day {
        if (std.ascii.eqlIgnoreCase(raw, "MO")) return .MO;
        if (std.ascii.eqlIgnoreCase(raw, "TU")) return .TU;
        if (std.ascii.eqlIgnoreCase(raw, "WE")) return .WE;
        if (std.ascii.eqlIgnoreCase(raw, "TH")) return .TH;
        if (std.ascii.eqlIgnoreCase(raw, "FR")) return .FR;
        if (std.ascii.eqlIgnoreCase(raw, "SA")) return .SA;
        if (std.ascii.eqlIgnoreCase(raw, "SU")) return .SU;
        return userErrorFmt(io, "invalid BYDAY value: {s}", .{raw});
    }

    pub fn asText(self: Day) []const u8 {
        return @tagName(self);
    }

    pub fn weekdayMonIndex(self: Day) u8 {
        return switch (self) {
            .MO => 0,
            .TU => 1,
            .WE => 2,
            .TH => 3,
            .FR => 4,
            .SA => 5,
            .SU => 6,
        };
    }
};

pub const Freq = enum {
    DAILY,
    HOURLY,
    WEEKLY,

    pub fn parse(io: std.Io, raw: []const u8) !Freq {
        if (std.ascii.eqlIgnoreCase(raw, "HOURLY")) return .HOURLY;
        if (std.ascii.eqlIgnoreCase(raw, "DAILY")) return .DAILY;
        if (std.ascii.eqlIgnoreCase(raw, "WEEKLY")) return .WEEKLY;
        return userErrorFmt(io, "unsupported FREQ: {s} (allowed: HOURLY, DAILY, WEEKLY)", .{raw});
    }

    pub fn asText(self: Freq) []const u8 {
        return @tagName(self);
    }
};

pub const RRule = struct {
    freq: Freq,
    interval: u32 = 1,
    byhour: ?u8 = null,
    byminute: ?u8 = null,
    byday: std.ArrayList(Day),

    pub fn init(_: std.mem.Allocator) RRule {
        return .{
            .freq = .DAILY,
            .interval = 1,
            .byhour = null,
            .byminute = null,
            .byday = std.ArrayList(Day).empty,
        };
    }

    pub fn deinit(self: *RRule, allocator: std.mem.Allocator) void {
        self.byday.deinit(allocator);
    }
};

pub fn parseAndCanonicalizeRrule(
    io: std.Io,
    allocator: std.mem.Allocator,
    raw_input: []const u8,
) ![]u8 {
    var input = std.mem.trim(u8, raw_input, " \t\r\n");
    if (input.len == 0) return userErrorFmt(io, "rrule must not be empty", .{});

    if (std.ascii.startsWithIgnoreCase(input, "RRULE:")) {
        input = std.mem.trim(u8, input[6..], " \t\r\n");
    }

    var rule = try parseRrule(io, allocator, input);
    defer rule.deinit(allocator);
    return renderCanonicalRrule(allocator, rule);
}

pub fn parseRrule(io: std.Io, allocator: std.mem.Allocator, raw_rule: []const u8) !RRule {
    var out = RRule.init(allocator);
    errdefer out.deinit(allocator);
    var have_freq = false;
    var have_byminute = false;
    var have_byhour = false;
    var have_byday = false;

    var iter = std.mem.splitScalar(u8, raw_rule, ';');
    while (iter.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;

        var kv = std.mem.splitScalar(u8, part, '=');
        const key_raw = kv.next() orelse
            return userErrorFmt(io, "rrule token missing key: {s}", .{part});
        const value_raw = kv.next() orelse
            return userErrorFmt(io, "rrule token missing value: {s}", .{part});
        if (kv.next() != null) return userErrorFmt(
            io,
            "rrule token has multiple '=': {s}",
            .{part},
        );

        const key = std.mem.trim(u8, key_raw, " \t\r\n");
        const value = std.mem.trim(u8, value_raw, " \t\r\n");

        if (std.ascii.eqlIgnoreCase(key, "FREQ")) {
            out.freq = try Freq.parse(io, value);
            have_freq = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "INTERVAL")) {
            const parsed = try parsePositiveUsize(io, value, "INTERVAL");
            out.interval = std.math.cast(u32, parsed) orelse
                return userErrorFmt(io, "INTERVAL must fit an unsigned 32-bit integer", .{});
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYHOUR")) {
            out.byhour = try parseBoundedU8(io, value, "BYHOUR", 23);
            have_byhour = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYMINUTE")) {
            out.byminute = try parseBoundedU8(io, value, "BYMINUTE", 59);
            have_byminute = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYDAY")) {
            if (value.len == 0) return userErrorFmt(io, "BYDAY must not be empty", .{});
            var days_iter = std.mem.splitScalar(u8, value, ',');
            while (days_iter.next()) |day_raw| {
                const day = try Day.parse(io, std.mem.trim(u8, day_raw, " \t\r\n"));
                if (!containsDay(out.byday.items, day)) try out.byday.append(allocator, day);
            }
            have_byday = out.byday.items.len > 0;
            continue;
        }
        return userErrorFmt(io, "unsupported RRULE token: {s}", .{key});
    }

    if (!have_freq) return userErrorFmt(io, "rrule must include FREQ=...", .{});
    try validateRruleShape(io, out, have_byminute, have_byhour, have_byday);
    return out;
}

fn validateRruleShape(
    io: std.Io,
    rule: RRule,
    have_byminute: bool,
    have_byhour: bool,
    have_byday: bool,
) !void {
    switch (rule.freq) {
        .HOURLY => {
            if (!have_byminute) return userErrorFmt(io, "HOURLY rrules must include BYMINUTE", .{});
            if (have_byhour) return userErrorFmt(io, "HOURLY rrules must not include BYHOUR", .{});
            if (have_byday) return userErrorFmt(io, "HOURLY rrules must not include BYDAY", .{});
        },
        .DAILY => {
            if (!have_byhour or !have_byminute) {
                return userErrorFmt(io, "DAILY rrules must include BYHOUR and BYMINUTE", .{});
            }
            if (have_byday) return userErrorFmt(io, "DAILY rrules must not include BYDAY", .{});
        },
        .WEEKLY => if (!have_byday or !have_byhour or !have_byminute) {
            return userErrorFmt(
                io,
                "WEEKLY rrules must include BYDAY, BYHOUR, and BYMINUTE",
                .{},
            );
        },
    }
}

pub fn renderCanonicalRrule(allocator: std.mem.Allocator, rule: RRule) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeAll("RRULE:FREQ=");
    try w.writeAll(rule.freq.asText());
    if (rule.interval != 1) try w.print(";INTERVAL={d}", .{rule.interval});
    if (rule.byday.items.len > 0) {
        try w.writeAll(";BYDAY=");
        for (rule.byday.items, 0..) |day, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.writeAll(day.asText());
        }
    }
    if (rule.byhour) |hour| try w.print(";BYHOUR={d}", .{hour});
    if (rule.byminute) |minute| try w.print(";BYMINUTE={d}", .{minute});
    return writer_alloc.toOwnedSlice();
}

pub fn containsDay(items: []const Day, needle: Day) bool {
    for (items) |day| if (day == needle) return true;
    return false;
}

fn parsePositiveUsize(io: std.Io, raw: []const u8, field: []const u8) !usize {
    const parsed = std.fmt.parseInt(usize, raw, 10) catch
        return userErrorFmt(io, "{s} must be a positive integer", .{field});
    if (parsed == 0) return userErrorFmt(io, "{s} must be a positive integer", .{field});
    return parsed;
}

fn parseBoundedU8(io: std.Io, raw: []const u8, field: []const u8, max: u8) !u8 {
    const parsed = std.fmt.parseInt(i64, raw, 10) catch
        return userErrorFmt(io, "{s} must be an integer 0..{d}", .{ field, max });
    if (parsed < 0 or parsed > max) {
        return userErrorFmt(io, "{s} must be in 0..{d}", .{ field, max });
    }
    return @intCast(parsed);
}

const userErrorFmt = @import("output.zig").userErrorFmt;

pub fn alignMsToMinute(io: std.Io, ms: i64) !i64 {
    const minute = @divFloor(ms, 60_000);
    return std.math.mul(i64, minute, 60_000) catch
        return userErrorFmt(io, "aligned minute is outside the timestamp range", .{});
}

const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

pub fn civilFromDays(days_since_unix_epoch: i64) CivilDate {
    const date = core_calendar.civilFromDays(days_since_unix_epoch, .gregorian);
    return .{
        .year = @intCast(date.year),
        .month = @intCast(date.month),
        .day = @intCast(date.day),
    };
}

pub fn weekdayMon(days_since_unix_epoch: i64) u8 {
    const idx = @mod(days_since_unix_epoch + 3, 7);
    return @intCast(if (idx < 0) idx + 7 else idx);
}

pub fn parseHmsFromMs(ms: i64) struct { hour: u8, minute: u8, second: u8, days: i64 } {
    const sec = @divFloor(ms, 1000);
    const days = @divFloor(sec, 86_400);
    const sec_of_day = sec - days * 86_400;
    const hour = @divFloor(sec_of_day, 3600);
    const rem = sec_of_day - hour * 3600;
    const minute = @divFloor(rem, 60);
    const second = rem - minute * 60;
    return .{
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .days = days,
    };
}

pub fn timestampStringUtc(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const parts = parseHmsFromMs(ms);
    const d = civilFromDays(parts.days);
    return allocator.print(
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +0000",
        .{ d.year, d.month, d.day, parts.hour, parts.minute, parts.second },
    );
}

pub fn dateStringUtc(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const parts = parseHmsFromMs(ms);
    const d = civilFromDays(parts.days);
    return allocator.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

pub fn computeNextRunAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    row: anytype,
    run_started_ms: i64,
) !i64 {
    const raw = std.mem.trim(u8, row.rrule, " \t\r\n");
    if (raw.len == 0) return userErrorFmt(io, "automation {s} has empty rrule", .{row.id});

    const rule_text = if (std.ascii.startsWithIgnoreCase(raw, "RRULE:"))
        std.mem.trim(u8, raw[6..], " \t\r\n")
    else
        raw;
    if (rule_text.len == 0) return userErrorFmt(
        io,
        "automation {s} has malformed rrule",
        .{row.id},
    );

    var rule = try parseRrule(io, allocator, rule_text);
    defer rule.deinit(allocator);

    const dtstart_ms: i64 = if (row.next_run_at) |next_ms|
        next_ms
    else if (row.last_run_at) |last_ms|
        last_ms
    else
        row.created_at;

    const dtstart = try alignMsToMinute(io, dtstart_ms);
    const anchor = try alignMsToMinute(io, run_started_ms);

    return switch (rule.freq) {
        .HOURLY => nextHourly(io, rule, dtstart, anchor),
        .DAILY => nextDaily(io, rule, dtstart, anchor),
        .WEEKLY => nextWeekly(io, rule, dtstart, anchor),
    };
}

pub fn nextHourly(io: std.Io, rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const minute = rule.byminute orelse return userErrorFmt(
        io,
        "HOURLY rrule missing BYMINUTE",
        .{},
    );

    const base_sec = @divFloor(dtstart_ms, 1000);
    const anchor_sec = @divFloor(anchor_ms, 1000);

    const base_hour = @divFloor(base_sec, 3600);
    var hour = @max(base_hour, @divFloor(anchor_sec, 3600) - 1);

    while (hour < base_hour + 24 * 365 * 10) : (hour += 1) {
        if (@mod(hour - base_hour, @as(i64, rule.interval)) != 0) continue;
        const candidate_sec = hour * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;
        return checkedTimestampMillis(io, candidate_sec);
    }

    return userErrorFmt(io, "unable to compute next HOURLY run", .{});
}

pub fn nextDaily(io: std.Io, rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const hour = rule.byhour orelse return userErrorFmt(io, "DAILY rrule missing BYHOUR", .{});
    const minute = rule.byminute orelse return userErrorFmt(
        io,
        "DAILY rrule missing BYMINUTE",
        .{},
    );

    const base_sec = @divFloor(dtstart_ms, 1000);
    const anchor_sec = @divFloor(anchor_ms, 1000);

    const base_day = @divFloor(base_sec, 86_400);
    var day = @max(base_day, @divFloor(anchor_sec, 86_400) - 1);

    while (day < base_day + 366 * 20) : (day += 1) {
        if (@mod(day - base_day, @as(i64, rule.interval)) != 0) continue;
        const candidate_sec = day * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;
        return checkedTimestampMillis(io, candidate_sec);
    }

    return userErrorFmt(io, "unable to compute next DAILY run", .{});
}

pub fn nextWeekly(io: std.Io, rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const hour = rule.byhour orelse return userErrorFmt(io, "WEEKLY rrule missing BYHOUR", .{});
    const minute = rule.byminute orelse return userErrorFmt(
        io,
        "WEEKLY rrule missing BYMINUTE",
        .{},
    );
    if (rule.byday.items.len == 0) return userErrorFmt(io, "WEEKLY rrule missing BYDAY", .{});

    const base_sec = @divFloor(dtstart_ms, 1000);
    const anchor_sec = @divFloor(anchor_ms, 1000);

    const base_day = @divFloor(base_sec, 86_400);
    const base_week_start = base_day - @as(i64, weekdayMon(base_day));

    var day = @max(base_day, @divFloor(anchor_sec, 86_400) - 1);
    const max_day = base_day + 366 * 30;

    while (day < max_day) : (day += 1) {
        const wd = weekdayMon(day);
        if (!weekdayAllowed(rule.byday.items, wd)) continue;

        const week_start = day - @as(i64, wd);
        const week_index = @divFloor(week_start - base_week_start, 7);
        if (week_index < 0) continue;
        if (@mod(week_index, @as(i64, rule.interval)) != 0) continue;

        const candidate_sec = day * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;

        return checkedTimestampMillis(io, candidate_sec);
    }

    return userErrorFmt(io, "unable to compute next WEEKLY run", .{});
}

pub fn weekdayAllowed(days: []const Day, weekday_index_mon: u8) bool {
    for (days) |day| {
        if (day.weekdayMonIndex() == weekday_index_mon) return true;
    }
    return false;
}

fn checkedTimestampMillis(io: std.Io, seconds: i64) !i64 {
    return std.math.mul(i64, seconds, 1000) catch
        return userErrorFmt(io, "next run is outside the timestamp range", .{});
}

test "minute alignment preserves negative floors and rejects an unrepresentable floor" {
    try std.testing.expectEqual(@as(i64, -60_000), try alignMsToMinute(std.testing.io, -1));
    try std.testing.expectEqual(@as(i64, 60_000), try alignMsToMinute(std.testing.io, 60_001));
    var capture = @import("testing.zig").StderrCapture.init(std.testing.allocator);
    defer capture.deinit();
    try std.testing.expectError(
        error.UserInput,
        alignMsToMinute(capture.io(), std.math.minInt(i64)),
    );
    try capture.expectEqual("error: aligned minute is outside the timestamp range\n");
}

test "hourly recurrence preserves the largest representable interval" {
    var rule = RRule.init(std.testing.allocator);
    defer rule.deinit(std.testing.allocator);
    rule.interval = std.math.maxInt(u32);
    rule.byminute = 1;
    try std.testing.expectEqual(@as(i64, 60_000), try nextHourly(std.testing.io, rule, 0, 0));
}

test "hourly recurrence reports when the next timestamp exceeds i64" {
    var capture = @import("testing.zig").StderrCapture.init(std.testing.allocator);
    defer capture.deinit();
    var rule = RRule.init(std.testing.allocator);
    defer rule.deinit(std.testing.allocator);
    rule.byminute = 59;
    const last = std.math.maxInt(i64);
    try std.testing.expectError(error.UserInput, nextHourly(capture.io(), rule, last, last));
    try capture.expectEqual("error: next run is outside the timestamp range\n");
}

fn parseWeeklyWithAllocator(allocator: std.mem.Allocator, io: std.Io) !void {
    var rule = try parseRrule(io, allocator, "FREQ=WEEKLY;BYDAY=MO,TU,WE;BYHOUR=1;BYMINUTE=2");
    defer rule.deinit(allocator);
}

test "recurrence parser releases accumulated days on allocation or shape failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        parseWeeklyWithAllocator,
        .{std.testing.io},
    );
    var capture = @import("testing.zig").StderrCapture.init(std.testing.allocator);
    defer capture.deinit();
    try std.testing.expectError(
        error.UserInput,
        parseRrule(capture.io(), std.testing.allocator, "FREQ=WEEKLY;BYDAY=MO,TU;BYHOUR=1"),
    );
    try capture.expectEqual("error: WEEKLY rrules must include BYDAY, BYHOUR, and BYMINUTE\n");
}

test "recurrence parser rejects intervals that do not fit the stored representation" {
    var capture = @import("testing.zig").StderrCapture.init(std.testing.allocator);
    defer capture.deinit();
    try std.testing.expectError(
        error.UserInput,
        parseRrule(
            capture.io(),
            std.testing.allocator,
            "FREQ=HOURLY;BYMINUTE=0;INTERVAL=4294967296",
        ),
    );
    try capture.expectEqual("error: INTERVAL must fit an unsigned 32-bit integer\n");
}
