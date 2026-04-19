const std = @import("std");

pub const MessageRow = struct {
    path: []const u8,
    timestamp: ?[]const u8,
    day: ?[]const u8,
    week: ?[]const u8,
    month: ?[]const u8,
    role: []const u8,
    text: []const u8,
    text_len: usize,

    pub fn deinit(self: MessageRow, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.timestamp) |v| allocator.free(v);
        if (self.day) |v| allocator.free(v);
        if (self.week) |v| allocator.free(v);
        if (self.month) |v| allocator.free(v);
        allocator.free(self.role);
        allocator.free(self.text);
    }
};

pub const ParseOptions = struct {
    include_user: bool = true,
    include_assistant: bool = true,
    strip_echo_assistant: bool = true,
    skip_meta_user_messages: bool = true,
    dedupe_by_role_and_text: bool = true,
    strip_skill_blocks: bool = false,
};

const DateParts = struct {
    year: i32,
    month: u8,
    day: u8,
};

const TimestampFields = struct {
    timestamp: ?[]const u8 = null,
    day: ?[]const u8 = null,
    week: ?[]const u8 = null,
    month: ?[]const u8 = null,

    fn deinit(self: TimestampFields, allocator: std.mem.Allocator) void {
        if (self.timestamp) |v| allocator.free(v);
        if (self.day) |v| allocator.free(v);
        if (self.week) |v| allocator.free(v);
        if (self.month) |v| allocator.free(v);
    }
};

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |obj| obj.get(key),
        else => null,
    };
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .string => |s| s,
        else => null,
    };
}

fn roleAllowed(role: []const u8, options: ParseOptions) bool {
    if (std.mem.eql(u8, role, "user")) return options.include_user;
    if (std.mem.eql(u8, role, "assistant")) return options.include_assistant;
    return false;
}

fn isMessageCandidate(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "event_msg") != null) {
        return std.mem.indexOf(u8, line, "user_message") != null or
            std.mem.indexOf(u8, line, "agent_message") != null;
    }
    if (std.mem.indexOf(u8, line, "response_item") != null) {
        return std.mem.indexOf(u8, line, "\"type\":\"message\"") != null or
            std.mem.indexOf(u8, line, "\"type\": \"message\"") != null;
    }
    return false;
}

fn stripEchoView(text: []const u8) []const u8 {
    const left = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, left, "Echo:")) return text;

    const newline_idx = std.mem.indexOfScalar(u8, left, '\n') orelse return "";
    var rest = left[newline_idx + 1 ..];

    while (rest.len > 0 and rest[0] == '\r') {
        rest = rest[1..];
    }

    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t' or rest[i] == '\r')) : (i += 1) {}
    if (i < rest.len and rest[i] == '\n') {
        rest = rest[i + 1 ..];
    }

    return rest;
}

fn isMetaUserMessage(text: []const u8) bool {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, s, "# AGENTS.md instructions")) return true;
    if (std.mem.startsWith(u8, s, "<environment_context>")) return true;
    if (std.mem.startsWith(u8, s, "<INSTRUCTIONS>")) return true;
    const end = @min(s.len, 200);
    return std.mem.indexOf(u8, s[0..end], "AGENTS.md instructions") != null;
}

fn normalizeText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            try out.append(allocator, '\n');
        } else {
            try out.append(allocator, c);
        }
    }

    const trimmed = std.mem.trim(u8, out.items, " \t\n");
    return allocator.dupe(u8, trimmed);
}

fn stripSkillBlocks(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var remaining = text;
    while (std.mem.indexOf(u8, remaining, "<skill>")) |start| {
        try out.appendSlice(allocator, remaining[0..start]);
        const after_start = remaining[start + "<skill>".len ..];
        const end_rel = std.mem.indexOf(u8, after_start, "</skill>") orelse {
            try out.appendSlice(allocator, remaining[start..]);
            return out.toOwnedSlice(allocator);
        };
        remaining = after_start[end_rel + "</skill>".len ..];
    }

    try out.appendSlice(allocator, remaining);
    return out.toOwnedSlice(allocator);
}

fn extractResponseItemText(allocator: std.mem.Allocator, payload: std.json.Value) ![]u8 {
    const content = objectField(payload, "content") orelse return allocator.dupe(u8, "");
    const arr = switch (content) {
        .array => |a| a,
        else => return allocator.dupe(u8, ""),
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (arr.items) |part| {
        const part_type = stringField(part, "type") orelse continue;
        if (!std.mem.eql(u8, part_type, "input_text") and !std.mem.eql(u8, part_type, "output_text")) continue;
        const part_text = stringField(part, "text") orelse "";
        try out.appendSlice(allocator, part_text);
    }

    return out.toOwnedSlice(allocator);
}

fn parseDateFromTimestamp(ts: []const u8) ?DateParts {
    if (ts.len < 10) return null;
    if (ts[4] != '-' or ts[7] != '-') return null;

    const year = std.fmt.parseInt(i32, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;

    return .{ .year = year, .month = month, .day = day };
}

fn normalizeTimestamp(allocator: std.mem.Allocator, ts: []const u8) ![]u8 {
    if (ts.len > 0 and ts[ts.len - 1] == 'Z') {
        return std.fmt.allocPrint(allocator, "{s}+00:00", .{ts[0 .. ts.len - 1]});
    }
    return allocator.dupe(u8, ts);
}

fn buildTimestampFields(allocator: std.mem.Allocator, ts_raw: ?[]const u8) !TimestampFields {
    var out = TimestampFields{};
    errdefer out.deinit(allocator);

    const ts = ts_raw orelse return out;
    const date = parseDateFromTimestamp(ts) orelse return out;
    const iso = isoWeekAndYear(date);

    const date_year_u: u32 = @intCast(@max(date.year, 0));
    const iso_year_u: u32 = @intCast(@max(iso.year, 0));

    out.timestamp = try normalizeTimestamp(allocator, ts);
    out.day = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ date_year_u, date.month, date.day });
    out.week = try std.fmt.allocPrint(allocator, "{d:0>4}-W{d:0>2}", .{ iso_year_u, iso.week });
    out.month = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}", .{ date_year_u, date.month });
    return out;
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

fn dayOfYear(date: DateParts) u16 {
    var total: u16 = 0;
    var m: u8 = 1;
    while (m < date.month) : (m += 1) {
        total += daysInMonth(date.year, m);
    }
    return total + date.day;
}

fn weekdayMondayOne(date: DateParts) u8 {
    var y = date.year;
    if (date.month < 3) y -= 1;
    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const month_idx: usize = @intCast(date.month - 1);
    const weekday_sun_zero = @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + t[month_idx] + date.day, 7);
    if (weekday_sun_zero == 0) return 7;
    return @intCast(weekday_sun_zero);
}

fn isoWeeksInYear(year: i32) u8 {
    const jan1 = DateParts{ .year = year, .month = 1, .day = 1 };
    const jan1_weekday = weekdayMondayOne(jan1);
    if (jan1_weekday == 4 or (jan1_weekday == 3 and isLeapYear(year))) return 53;
    return 52;
}

fn isoWeekAndYear(date: DateParts) struct { year: i32, week: u8 } {
    const doy: i32 = dayOfYear(date);
    const dow: i32 = weekdayMondayOne(date);

    var week = @divFloor(doy - dow + 10, 7);
    var iso_year = date.year;

    if (week < 1) {
        iso_year -= 1;
        week = isoWeeksInYear(iso_year);
    } else {
        const max_week = isoWeeksInYear(date.year);
        if (week > max_week) {
            iso_year += 1;
            week = 1;
        }
    }

    return .{ .year = iso_year, .week = @intCast(week) };
}

pub fn parseJsonlLine(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    options: ParseOptions,
) !?MessageRow {
    const trimmed_line = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed_line.len == 0) return null;
    if (!isMessageCandidate(trimmed_line)) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed_line, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    const obj_type = stringField(root, "type") orelse return null;
    const payload = objectField(root, "payload") orelse return null;
    const timestamp_raw = stringField(root, "timestamp");

    var role_raw: []const u8 = undefined;
    var raw_text: []u8 = undefined;

    if (std.mem.eql(u8, obj_type, "response_item")) {
        const payload_type = stringField(payload, "type") orelse return null;
        if (!std.mem.eql(u8, payload_type, "message")) return null;
        role_raw = stringField(payload, "role") orelse return null;
        raw_text = try extractResponseItemText(allocator, payload);
    } else if (std.mem.eql(u8, obj_type, "event_msg")) {
        const payload_type = stringField(payload, "type") orelse return null;
        if (std.mem.eql(u8, payload_type, "user_message")) {
            role_raw = "user";
        } else if (std.mem.eql(u8, payload_type, "agent_message")) {
            role_raw = "assistant";
        } else {
            return null;
        }
        const msg = stringField(payload, "message") orelse "";
        raw_text = try allocator.dupe(u8, msg);
    } else {
        return null;
    }
    var raw_text_owned = true;
    defer if (raw_text_owned) allocator.free(raw_text);

    if (!roleAllowed(role_raw, options)) return null;

    if (std.mem.eql(u8, role_raw, "assistant") and options.strip_echo_assistant) {
        const stripped = stripEchoView(raw_text);
        if (!std.mem.eql(u8, stripped, raw_text)) {
            const copy = try allocator.dupe(u8, stripped);
            allocator.free(raw_text);
            raw_text = copy;
        }
    }

    if (std.mem.eql(u8, role_raw, "user") and options.skip_meta_user_messages and isMetaUserMessage(raw_text)) {
        return null;
    }

    if (options.strip_skill_blocks) {
        const stripped = try stripSkillBlocks(allocator, raw_text);
        allocator.free(raw_text);
        raw_text = stripped;
    }

    const normalized_text = try normalizeText(allocator, raw_text);
    allocator.free(raw_text);
    raw_text = normalized_text;
    if (raw_text.len == 0) return null;

    const ts_fields = try buildTimestampFields(allocator, timestamp_raw);
    errdefer ts_fields.deinit(allocator);

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    const role_copy = try allocator.dupe(u8, role_raw);
    errdefer allocator.free(role_copy);

    raw_text_owned = false;
    return MessageRow{
        .path = path_copy,
        .timestamp = ts_fields.timestamp,
        .day = ts_fields.day,
        .week = ts_fields.week,
        .month = ts_fields.month,
        .role = role_copy,
        .text = raw_text,
        .text_len = raw_text.len,
    };
}

fn freeMapKeys(map: *std.StringHashMap(void), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
}

pub fn parseJsonl(
    allocator: std.mem.Allocator,
    path: []const u8,
    jsonl: []const u8,
    options: ParseOptions,
) ![]MessageRow {
    var rows: std.ArrayList(MessageRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    var seen: std.StringHashMap(void) = .init(allocator);
    defer {
        freeMapKeys(&seen, allocator);
        seen.deinit();
    }

    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        const maybe_row = try parseJsonlLine(allocator, path, line, options);
        if (maybe_row) |row| {
            if (options.dedupe_by_role_and_text) {
                const key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ row.role, row.text });
                if (seen.contains(key)) {
                    allocator.free(key);
                    row.deinit(allocator);
                    continue;
                }
                try seen.put(key, {});
            }
            try rows.append(allocator, row);
        }
    }

    return rows.toOwnedSlice(allocator);
}

pub fn freeRows(allocator: std.mem.Allocator, rows: []MessageRow) void {
    for (rows) |row| row.deinit(allocator);
    allocator.free(rows);
}

test "parse messages from response_item and event_msg with echo stripping" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","timestamp":"2026-02-19T10:11:12Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"First "},{"type":"output_text","text":"Second"},{"type":"ignored","text":"x"}]}}
        \\{"type":"event_msg","timestamp":"2026-02-19T10:12:12Z","payload":{"type":"agent_message","message":"Echo: test\n\nAnswer"}}
    ;

    const rows = try parseJsonl(allocator, "/tmp/s1.jsonl", jsonl, .{});
    defer freeRows(allocator, rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("user", rows[0].role);
    try std.testing.expectEqualStrings("First Second", rows[0].text);
    try std.testing.expectEqualStrings("2026-02-19", rows[0].day.?);
    try std.testing.expectEqualStrings("2026-W08", rows[0].week.?);
    try std.testing.expectEqualStrings("2026-02", rows[0].month.?);
    try std.testing.expectEqualStrings("2026-02-19T10:11:12+00:00", rows[0].timestamp.?);

    try std.testing.expectEqualStrings("assistant", rows[1].role);
    try std.testing.expectEqualStrings("Answer", rows[1].text);
}

test "parse messages strips skill blocks before normalization" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","timestamp":"2026-03-10T10:11:12Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Before\n<skill>\n<name>seq</name>\n</skill>\nAfter"}]}}
    ;

    const rows = try parseJsonl(allocator, "/tmp/s2.jsonl", jsonl, .{ .strip_skill_blocks = true });
    defer freeRows(allocator, rows);

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("Before\n\nAfter", rows[0].text);
}

test "parse messages drops rows emptied by skill-block stripping" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","timestamp":"2026-03-10T10:11:12Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<skill>\n<name>seq</name>\n</skill>"}]}}
    ;

    const rows = try parseJsonl(allocator, "/tmp/s3.jsonl", jsonl, .{ .strip_skill_blocks = true });
    defer freeRows(allocator, rows);

    try std.testing.expectEqual(@as(usize, 0), rows.len);
}
