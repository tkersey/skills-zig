const std = @import("std");

pub const Row = struct {
    path: []u8,
    timestamp: ?[]u8 = null,
    day: ?[]u8 = null,
    week: ?[]u8 = null,
    month: ?[]u8 = null,
    kind: []u8,
    tool: ?[]u8 = null,
    call_id: ?[]u8 = null,
    arguments_len: ?usize = null,
    input_len: ?usize = null,
    status: ?[]u8 = null,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.timestamp) |v| allocator.free(v);
        if (self.day) |v| allocator.free(v);
        if (self.week) |v| allocator.free(v);
        if (self.month) |v| allocator.free(v);
        allocator.free(self.kind);
        if (self.tool) |v| allocator.free(v);
        if (self.call_id) |v| allocator.free(v);
        if (self.status) |v| allocator.free(v);
    }
};

const DateParts = struct {
    year: i32,
    month: u8,
    day: u8,
};

pub const RowList = std.ArrayList(Row);

pub const Iterator = struct {
    rows: []const Row,
    index: usize = 0,

    pub fn next(self: *Iterator) ?Row {
        if (self.index >= self.rows.len) return null;
        defer self.index += 1;
        return self.rows[self.index];
    }
};

pub fn iter(rows: []const Row) Iterator {
    return .{ .rows = rows };
}

pub fn deinitRows(allocator: std.mem.Allocator, rows: *RowList) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

pub fn collect(allocator: std.mem.Allocator, sessions_root: []const u8) !RowList {
    var rows = RowList.empty;
    errdefer deinitRows(allocator, &rows);

    const root_abs = try toAbsolutePath(allocator, sessions_root);
    defer allocator.free(root_abs);

    var jsonl_paths = try collectJsonlPaths(allocator, root_abs);
    defer {
        for (jsonl_paths.items) |path| allocator.free(path);
        jsonl_paths.deinit(allocator);
    }

    for (jsonl_paths.items) |path| {
        const file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch continue;
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
        const content = reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024)) catch continue;
        defer allocator.free(content);

        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            const maybe_row = try parseLine(allocator, path, line);
            if (maybe_row) |row| {
                try rows.append(allocator, row);
            }
        }
    }

    return rows;
}

fn parseLine(allocator: std.mem.Allocator, path: []const u8, line: []const u8) !?Row {
    if (line.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "response_item")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "function_call") and
        !std.mem.containsAtLeast(u8, line, 1, "custom_tool_call")) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    if (!fieldStringEq(root, "type", "response_item")) return null;

    const payload_value = root.get("payload") orelse return null;
    const payload = switch (payload_value) {
        .object => |obj| obj,
        else => return null,
    };

    const kind = fieldString(payload, "type") orelse return null;
    const is_function_call = std.mem.eql(u8, kind, "function_call");
    const is_custom_tool_call = std.mem.eql(u8, kind, "custom_tool_call");
    if (!is_function_call and !is_custom_tool_call) return null;

    var row = Row{
        .path = try allocator.dupe(u8, path),
        .kind = try allocator.dupe(u8, kind),
        .tool = if (fieldString(payload, "name")) |s| try allocator.dupe(u8, s) else null,
        .call_id = if (fieldString(payload, "call_id")) |s| try allocator.dupe(u8, s) else null,
    };
    errdefer row.deinit(allocator);

    const ts_fields = try buildTimestampFields(allocator, fieldString(root, "timestamp"));
    row.timestamp = ts_fields.timestamp;
    row.day = ts_fields.day;
    row.week = ts_fields.week;
    row.month = ts_fields.month;

    if (is_function_call) {
        if (fieldString(payload, "arguments")) |s| {
            row.arguments_len = s.len;
        }
    } else {
        if (fieldString(payload, "input")) |s| {
            row.input_len = s.len;
        }
        if (fieldString(payload, "status")) |s| {
            row.status = try allocator.dupe(u8, s);
        }
    }

    return row;
}

fn collectJsonlPaths(allocator: std.mem.Allocator, root_abs: []const u8) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    var root_dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), root_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out,
        else => return err,
    };
    defer root_dir.close(std.Io.Threaded.global_single_threaded.io());

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;

        const absolute_path = try std.fs.path.join(allocator, &.{ root_abs, entry.path });
        try out.append(allocator, absolute_path);
    }

    std.mem.sort([]u8, out.items, {}, lessThanString);
    return out;
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn toAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);

    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn fieldString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn fieldStringEq(obj: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = fieldString(obj, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn buildTimestampFields(allocator: std.mem.Allocator, ts_raw: ?[]const u8) !struct {
    timestamp: ?[]u8,
    day: ?[]u8,
    week: ?[]u8,
    month: ?[]u8,
} {
    const ts = ts_raw orelse return .{
        .timestamp = null,
        .day = null,
        .week = null,
        .month = null,
    };

    const normalized_ts = try normalizeTimestamp(allocator, ts);
    const date = parseDateFromTimestamp(ts) orelse return .{
        .timestamp = normalized_ts,
        .day = null,
        .week = null,
        .month = null,
    };

    const iso = isoWeekAndYear(date);
    const date_year_u: u32 = @intCast(@max(date.year, 0));
    const iso_year_u: u32 = @intCast(@max(iso.year, 0));

    return .{
        .timestamp = normalized_ts,
        .day = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ date_year_u, date.month, date.day }),
        .week = try std.fmt.allocPrint(allocator, "{d:0>4}-W{d:0>2}", .{ iso_year_u, iso.week }),
        .month = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}", .{ date_year_u, date.month }),
    };
}

fn normalizeTimestamp(allocator: std.mem.Allocator, ts: []const u8) ![]u8 {
    if (ts.len > 0 and ts[ts.len - 1] == 'Z') {
        return std.fmt.allocPrint(allocator, "{s}+00:00", .{ts[0 .. ts.len - 1]});
    }
    return allocator.dupe(u8, ts);
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

test "tool_calls collect parses function_call rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "session.jsonl",
        .data =
        \\{"type":"response_item","timestamp":"2026-02-19T10:00:00Z","payload":{"type":"function_call","name":"search","call_id":"call-1","arguments":"{\\\"q\\\":1}"}}
        \\{"type":"response_item","timestamp":"2026-02-19T10:00:01Z","payload":{"type":"message"}}
        \\{"type":"response_item","timestamp":"2026-02-20T11:00:00Z","payload":{"type":"custom_tool_call","name":"shell","call_id":"call-2","input":"ls","status":"ok"}}
        ,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    var rows = try collect(std.testing.allocator, root_abs);
    defer deinitRows(std.testing.allocator, &rows);

    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("function_call", rows.items[0].kind);
    try std.testing.expectEqualStrings("search", rows.items[0].tool.?);
    try std.testing.expectEqual(@as(?usize, 9), rows.items[0].arguments_len);
    try std.testing.expectEqualStrings("2026-02-19T10:00:00+00:00", rows.items[0].timestamp.?);
    try std.testing.expectEqualStrings("2026-02-19", rows.items[0].day.?);
    try std.testing.expectEqualStrings("2026-W08", rows.items[0].week.?);
    try std.testing.expectEqualStrings("2026-02", rows.items[0].month.?);

    try std.testing.expectEqualStrings("custom_tool_call", rows.items[1].kind);
    try std.testing.expectEqualStrings("shell", rows.items[1].tool.?);
    try std.testing.expectEqual(@as(?usize, 2), rows.items[1].input_len);
    try std.testing.expectEqualStrings("2026-02-20", rows.items[1].day.?);

    var it = iter(rows.items);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}
