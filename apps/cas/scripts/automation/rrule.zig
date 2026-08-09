const std = @import("std");

pub const Day = enum {
    FR,
    MO,
    SA,
    SU,
    TH,
    TU,
    WE,

    pub fn parse(raw: []const u8) !Day {
        if (std.ascii.eqlIgnoreCase(raw, "MO")) return .MO;
        if (std.ascii.eqlIgnoreCase(raw, "TU")) return .TU;
        if (std.ascii.eqlIgnoreCase(raw, "WE")) return .WE;
        if (std.ascii.eqlIgnoreCase(raw, "TH")) return .TH;
        if (std.ascii.eqlIgnoreCase(raw, "FR")) return .FR;
        if (std.ascii.eqlIgnoreCase(raw, "SA")) return .SA;
        if (std.ascii.eqlIgnoreCase(raw, "SU")) return .SU;
        return userErrorFmt("invalid BYDAY value: {s}", .{raw});
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

    pub fn parse(raw: []const u8) !Freq {
        if (std.ascii.eqlIgnoreCase(raw, "HOURLY")) return .HOURLY;
        if (std.ascii.eqlIgnoreCase(raw, "DAILY")) return .DAILY;
        if (std.ascii.eqlIgnoreCase(raw, "WEEKLY")) return .WEEKLY;
        return userErrorFmt("unsupported FREQ: {s} (allowed: HOURLY, DAILY, WEEKLY)", .{raw});
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

pub fn parseAndCanonicalizeRrule(allocator: std.mem.Allocator, raw_input: []const u8) ![]u8 {
    var input = std.mem.trim(u8, raw_input, " \t\r\n");
    if (input.len == 0) return userErrorFmt("rrule must not be empty", .{});

    if (std.ascii.startsWithIgnoreCase(input, "RRULE:")) {
        input = std.mem.trim(u8, input[6..], " \t\r\n");
    }

    var rule = try parseRrule(allocator, input);
    defer rule.deinit(allocator);
    return renderCanonicalRrule(allocator, rule);
}

pub fn parseRrule(allocator: std.mem.Allocator, raw_rule: []const u8) !RRule {
    var out = RRule.init(allocator);
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
            return userErrorFmt("rrule token missing key: {s}", .{part});
        const value_raw = kv.next() orelse
            return userErrorFmt("rrule token missing value: {s}", .{part});
        if (kv.next() != null) return userErrorFmt("rrule token has multiple '=': {s}", .{part});

        const key = std.mem.trim(u8, key_raw, " \t\r\n");
        const value = std.mem.trim(u8, value_raw, " \t\r\n");

        if (std.ascii.eqlIgnoreCase(key, "FREQ")) {
            out.freq = try Freq.parse(value);
            have_freq = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "INTERVAL")) {
            const parsed = try parsePositiveUsize(value, "INTERVAL");
            out.interval = @intCast(parsed);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYHOUR")) {
            out.byhour = try parseBoundedU8(value, "BYHOUR", 23);
            have_byhour = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYMINUTE")) {
            out.byminute = try parseBoundedU8(value, "BYMINUTE", 59);
            have_byminute = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYDAY")) {
            if (value.len == 0) return userErrorFmt("BYDAY must not be empty", .{});
            var days_iter = std.mem.splitScalar(u8, value, ',');
            while (days_iter.next()) |day_raw| {
                const day = try Day.parse(std.mem.trim(u8, day_raw, " \t\r\n"));
                if (!containsDay(out.byday.items, day)) try out.byday.append(allocator, day);
            }
            have_byday = out.byday.items.len > 0;
            continue;
        }
        return userErrorFmt("unsupported RRULE token: {s}", .{key});
    }

    if (!have_freq) return userErrorFmt("rrule must include FREQ=...", .{});
    try validateRruleShape(out, have_byminute, have_byhour, have_byday);
    return out;
}

fn validateRruleShape(
    rule: RRule,
    have_byminute: bool,
    have_byhour: bool,
    have_byday: bool,
) !void {
    switch (rule.freq) {
        .HOURLY => {
            if (!have_byminute) return userErrorFmt("HOURLY rrules must include BYMINUTE", .{});
            if (have_byhour) return userErrorFmt("HOURLY rrules must not include BYHOUR", .{});
            if (have_byday) return userErrorFmt("HOURLY rrules must not include BYDAY", .{});
        },
        .DAILY => {
            if (!have_byhour or !have_byminute) {
                return userErrorFmt("DAILY rrules must include BYHOUR and BYMINUTE", .{});
            }
            if (have_byday) return userErrorFmt("DAILY rrules must not include BYDAY", .{});
        },
        .WEEKLY => if (!have_byday or !have_byhour or !have_byminute) {
            return userErrorFmt(
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

fn parsePositiveUsize(raw: []const u8, field: []const u8) !usize {
    const parsed = std.fmt.parseInt(usize, raw, 10) catch
        return userErrorFmt("{s} must be a positive integer", .{field});
    if (parsed == 0) return userErrorFmt("{s} must be a positive integer", .{field});
    return parsed;
}

fn parseBoundedU8(raw: []const u8, field: []const u8, max: u8) !u8 {
    const parsed = std.fmt.parseInt(i64, raw, 10) catch
        return userErrorFmt("{s} must be an integer 0..{d}", .{ field, max });
    if (parsed < 0 or parsed > max) {
        return userErrorFmt("{s} must be in 0..{d}", .{ field, max });
    }
    return @intCast(parsed);
}

fn userErrorFmt(comptime fmt: []const u8, args: anytype) error{UserInput} {
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    stderr.print("error: " ++ fmt ++ "\n", args) catch return error.UserInput;
    return error.UserInput;
}

pub fn alignMsToMinute(ms: i64) i64 {
    const sec = @divFloor(ms, 1000);
    return @as(i64, @intCast(@divFloor(sec, 60) * 60 * 1000));
}

const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

pub fn civilFromDays(days_since_unix_epoch: i64) CivilDate {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1_460) +
            @divFloor(doe, 36_524) -
            @divFloor(doe, 146_096),
        365,
    );
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    return .{
        .year = y + (if (m <= 2) @as(i64, 1) else @as(i64, 0)),
        .month = @intCast(m),
        .day = @intCast(d),
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
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +0000",
        .{ d.year, d.month, d.day, parts.hour, parts.minute, parts.second },
    );
}

pub fn dateStringUtc(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const parts = parseHmsFromMs(ms);
    const d = civilFromDays(parts.days);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

pub fn computeNextRunAt(allocator: std.mem.Allocator, row: anytype, run_started_ms: i64) !i64 {
    const raw = std.mem.trim(u8, row.rrule, " \t\r\n");
    if (raw.len == 0) return userErrorFmt("automation {s} has empty rrule", .{row.id});

    const rule_text = if (std.ascii.startsWithIgnoreCase(raw, "RRULE:"))
        std.mem.trim(u8, raw[6..], " \t\r\n")
    else
        raw;
    if (rule_text.len == 0) return userErrorFmt("automation {s} has malformed rrule", .{row.id});

    var rule = try parseRrule(allocator, rule_text);
    defer rule.deinit(allocator);

    const dtstart_ms: i64 = if (row.next_run_at) |next_ms|
        next_ms
    else if (row.last_run_at) |last_ms|
        last_ms
    else
        row.created_at;

    const dtstart = alignMsToMinute(dtstart_ms);
    const anchor = alignMsToMinute(run_started_ms);

    return switch (rule.freq) {
        .HOURLY => nextHourly(rule, dtstart, anchor),
        .DAILY => nextDaily(rule, dtstart, anchor),
        .WEEKLY => nextWeekly(rule, dtstart, anchor),
    };
}

pub fn nextHourly(rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const minute = rule.byminute orelse return userErrorFmt("HOURLY rrule missing BYMINUTE", .{});

    const base_sec = @divFloor(dtstart_ms, 1000);
    const anchor_sec = @divFloor(anchor_ms, 1000);

    const base_hour = @divFloor(base_sec, 3600);
    var hour = @max(base_hour, @divFloor(anchor_sec, 3600) - 1);

    while (hour < base_hour + 24 * 365 * 10) : (hour += 1) {
        if (@mod(hour - base_hour, @as(i64, @intCast(rule.interval))) != 0) continue;
        const candidate_sec = hour * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;
        return candidate_sec * 1000;
    }

    return userErrorFmt("unable to compute next HOURLY run", .{});
}

pub fn nextDaily(rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const hour = rule.byhour orelse return userErrorFmt("DAILY rrule missing BYHOUR", .{});
    const minute = rule.byminute orelse return userErrorFmt("DAILY rrule missing BYMINUTE", .{});

    const base_sec = @divFloor(dtstart_ms, 1000);
    const anchor_sec = @divFloor(anchor_ms, 1000);

    const base_day = @divFloor(base_sec, 86_400);
    var day = @max(base_day, @divFloor(anchor_sec, 86_400) - 1);

    while (day < base_day + 366 * 20) : (day += 1) {
        if (@mod(day - base_day, @as(i64, @intCast(rule.interval))) != 0) continue;
        const candidate_sec = day * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;
        return candidate_sec * 1000;
    }

    return userErrorFmt("unable to compute next DAILY run", .{});
}

pub fn nextWeekly(rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const hour = rule.byhour orelse return userErrorFmt("WEEKLY rrule missing BYHOUR", .{});
    const minute = rule.byminute orelse return userErrorFmt("WEEKLY rrule missing BYMINUTE", .{});
    if (rule.byday.items.len == 0) return userErrorFmt("WEEKLY rrule missing BYDAY", .{});

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
        if (@mod(week_index, @as(i64, @intCast(rule.interval))) != 0) continue;

        const candidate_sec = day * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;

        return candidate_sec * 1000;
    }

    return userErrorFmt("unable to compute next WEEKLY run", .{});
}

pub fn weekdayAllowed(days: []const Day, weekday_index_mon: u8) bool {
    for (days) |day| {
        if (day.weekdayMonIndex() == weekday_index_mon) return true;
    }
    return false;
}
