const std = @import("std");
const sqlite = @import("opencode_sqlite.zig");

pub const Options = struct {
    opencode_db_path: ?[]const u8 = null,
    opencode_path: ?[]const u8 = null,
    source: sqlite.Source = .auto,
    include_raw: bool = false,
    include_summary_fallback: bool = true,
    session_id: ?[]const u8 = null,
    session_slug: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    time_created_min_ms: ?i64 = null,
    time_created_max_ms: ?i64 = null,
    order_desc: bool = false,
    limit: usize = 0,
};

pub const Row = struct {
    source_kind: []u8,
    source_path: []u8,
    source_record_index: i64,

    session_id: ?[]u8 = null,
    session_slug: ?[]u8 = null,
    session_directory: ?[]u8 = null,
    message_id: ?[]u8 = null,
    message_parent_id: ?[]u8 = null,

    role: []u8,
    mode: ?[]u8 = null,

    prompt_text: []u8,
    prompt_len: usize,
    prompt_from_summary: bool,
    prompt_truncated: bool,

    parts_count: usize,
    text_parts_count: usize,
    file_parts_count: usize,
    part_types: []u8,
    file_paths: []u8,

    time_created_epoch_ms: ?i64 = null,
    time_created_iso: ?[]u8 = null,
    time_updated_epoch_ms: ?i64 = null,
    time_updated_iso: ?[]u8 = null,

    raw_message_json: ?[]u8 = null,
    raw_parts_json: ?[]u8 = null,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.source_kind);
        allocator.free(self.source_path);
        if (self.session_id) |v| allocator.free(v);
        if (self.session_slug) |v| allocator.free(v);
        if (self.session_directory) |v| allocator.free(v);
        if (self.message_id) |v| allocator.free(v);
        if (self.message_parent_id) |v| allocator.free(v);
        allocator.free(self.role);
        if (self.mode) |v| allocator.free(v);
        allocator.free(self.prompt_text);
        allocator.free(self.part_types);
        allocator.free(self.file_paths);
        if (self.time_created_iso) |v| allocator.free(v);
        if (self.time_updated_iso) |v| allocator.free(v);
        if (self.raw_message_json) |v| allocator.free(v);
        if (self.raw_parts_json) |v| allocator.free(v);
    }
};

pub const RowList = std.ArrayList(Row);

const ParsedMessage = struct {
    role: []u8,
    mode: ?[]u8 = null,
    parent_id: ?[]u8 = null,
    summary_body: ?[]u8 = null,

    fn deinit(self: *ParsedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        if (self.mode) |v| allocator.free(v);
        if (self.parent_id) |v| allocator.free(v);
        if (self.summary_body) |v| allocator.free(v);
    }
};

pub fn deinitRows(allocator: std.mem.Allocator, rows: *RowList) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

pub fn collect(allocator: std.mem.Allocator, options: Options) !RowList {
    return switch (options.source) {
        .db => collectFromDb(allocator, options),
        .jsonl => collectFromJsonl(allocator, options),
        .auto => blk: {
            const db_rows = collectFromDb(allocator, options) catch |err| switch (err) {
                error.MissingOpencodeDb,
                error.OpencodeDbOpenFailed,
                error.OpencodeDbPrepareFailed,
                => null,
                else => return err,
            };
            if (db_rows) |rows| break :blk rows;

            break :blk collectFromJsonl(allocator, options) catch |jsonl_err| switch (jsonl_err) {
                error.MissingOpencodeHistory => error.MissingOpencodeSource,
                else => jsonl_err,
            };
        },
    };
}

fn collectFromDb(allocator: std.mem.Allocator, options: Options) !RowList {
    const db_path = try sqlite.resolveDefaultDbPath(allocator, options.opencode_db_path);
    defer allocator.free(db_path);

    var db = try sqlite.Db.open(allocator, db_path);
    defer db.close();

    const order_keyword = if (options.order_desc) "DESC" else "ASC";
    const limit_clause = if (options.limit > 0) "LIMIT ?7" else "";
    const messages_sql = try std.fmt.allocPrint(
        allocator,
        \\SELECT
        \\  m.rowid,
        \\  m.id,
        \\  m.session_id,
        \\  m.time_created,
        \\  m.time_updated,
        \\  m.data,
        \\  s.slug,
        \\  s.directory
        \\FROM message m
        \\LEFT JOIN session s ON s.id = m.session_id
        \\WHERE json_extract(m.data, '$.role') = 'user'
        \\  AND (?1 IS NULL OR m.session_id = ?1)
        \\  AND (?2 IS NULL OR s.slug = ?2)
        \\  AND (?3 IS NULL OR m.id = ?3)
        \\  AND (?4 IS NULL OR json_extract(m.data, '$.mode') = ?4)
        \\  AND (?5 IS NULL OR m.time_created >= ?5)
        \\  AND (?6 IS NULL OR m.time_created <= ?6)
        \\ORDER BY m.time_created {s}, m.rowid {s}
        \\{s}
    ,
        .{ order_keyword, order_keyword, limit_clause },
    );
    defer allocator.free(messages_sql);

    var messages_stmt = try db.prepare(allocator, messages_sql);
    defer messages_stmt.deinit();

    const parts_sql = try std.fmt.allocPrint(
        allocator,
        \\SELECT
        \\  p.data
        \\FROM part p
        \\WHERE p.message_id = ?1
        \\ORDER BY p.time_created {s}, p.rowid {s}
    ,
        .{ order_keyword, order_keyword },
    );
    defer allocator.free(parts_sql);

    var parts_stmt = try db.prepare(allocator, parts_sql);
    defer parts_stmt.deinit();

    var rows = RowList.empty;
    errdefer deinitRows(allocator, &rows);

    try messages_stmt.reset();
    try bindOptionalText(&messages_stmt, 1, options.session_id);
    try bindOptionalText(&messages_stmt, 2, options.session_slug);
    try bindOptionalText(&messages_stmt, 3, options.message_id);
    try bindOptionalText(&messages_stmt, 4, options.mode);
    try bindOptionalInt64(&messages_stmt, 5, options.time_created_min_ms);
    try bindOptionalInt64(&messages_stmt, 6, options.time_created_max_ms);
    if (options.limit > 0) try messages_stmt.bindInt64(7, @intCast(options.limit));

    while (try messages_stmt.step() == .row) {
        const source_record_index = messages_stmt.intColumn(0);
        const message_id = try messages_stmt.textColumnAlloc(allocator, 1);
        defer allocator.free(message_id);
        const session_id = try messages_stmt.textColumnAlloc(allocator, 2);
        defer allocator.free(session_id);
        const time_created_epoch_ms = messages_stmt.nullableIntColumn(3);
        const time_updated_epoch_ms = messages_stmt.nullableIntColumn(4);
        const message_json = try messages_stmt.textColumnAlloc(allocator, 5);
        defer allocator.free(message_json);
        const session_slug = try messages_stmt.nullableTextColumnAlloc(allocator, 6);
        defer if (session_slug) |v| allocator.free(v);
        const session_directory = try messages_stmt.nullableTextColumnAlloc(allocator, 7);
        defer if (session_directory) |v| allocator.free(v);

        var parsed_message = try parseMessageJson(allocator, message_json);
        defer parsed_message.deinit(allocator);

        var text_segments: std.ArrayList([]u8) = .empty;
        defer freeStringList(allocator, &text_segments);

        var part_types: std.ArrayList([]u8) = .empty;
        defer freeStringList(allocator, &part_types);

        var file_paths: std.ArrayList([]u8) = .empty;
        defer freeStringList(allocator, &file_paths);

        var raw_parts_builder: std.ArrayList(u8) = .empty;
        defer raw_parts_builder.deinit(allocator);

        var parts_count: usize = 0;
        var text_parts_count: usize = 0;
        var file_parts_count: usize = 0;
        var raw_parts_written: usize = 0;

        try parts_stmt.reset();
        try parts_stmt.bindText(1, message_id);
        while (try parts_stmt.step() == .row) {
            const part_json = try parts_stmt.textColumnAlloc(allocator, 0);
            defer allocator.free(part_json);

            parts_count += 1;

            if (options.include_raw) {
                if (raw_parts_written == 0) {
                    try raw_parts_builder.append(allocator, '[');
                } else {
                    try raw_parts_builder.append(allocator, ',');
                }
                try raw_parts_builder.appendSlice(allocator, part_json);
                raw_parts_written += 1;
            }

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const parsed_part = std.json.parseFromSlice(std.json.Value, arena.allocator(), part_json, .{}) catch continue;
            defer parsed_part.deinit();

            const part_obj = switch (parsed_part.value) {
                .object => |obj| obj,
                else => continue,
            };

            const part_type = stringField(part_obj, "type") orelse continue;
            try appendUnique(&part_types, allocator, part_type);

            if (std.mem.eql(u8, part_type, "text")) {
                text_parts_count += 1;
                if (stringField(part_obj, "text")) |text_value| {
                    try text_segments.append(allocator, try allocator.dupe(u8, text_value));
                }
            } else if (std.mem.eql(u8, part_type, "file")) {
                file_parts_count += 1;
                if (nestedStringField(part_obj, "source", "path")) |path| {
                    try appendUnique(&file_paths, allocator, path);
                } else if (stringField(part_obj, "filename")) |filename| {
                    try appendUnique(&file_paths, allocator, filename);
                }
            }
        }

        const prompt = blk: {
            if (text_segments.items.len > 0) {
                break :blk PromptValue{
                    .text = try joinTextSegments(allocator, text_segments.items),
                    .from_summary = false,
                };
            }
            if (options.include_summary_fallback) {
                if (parsed_message.summary_body) |summary_text| {
                    break :blk PromptValue{
                        .text = try allocator.dupe(u8, summary_text),
                        .from_summary = true,
                    };
                }
            }
            continue;
        };
        defer allocator.free(prompt.text);

        const part_types_csv = try joinSortedCsv(allocator, &part_types);
        defer allocator.free(part_types_csv);
        const file_paths_csv = try joinSortedCsv(allocator, &file_paths);
        defer allocator.free(file_paths_csv);

        const time_created_iso = try sqlite.epochMsToIso8601Alloc(allocator, time_created_epoch_ms);
        defer if (time_created_iso) |v| allocator.free(v);
        const time_updated_iso = try sqlite.epochMsToIso8601Alloc(allocator, time_updated_epoch_ms);
        defer if (time_updated_iso) |v| allocator.free(v);

        const raw_message_json = if (options.include_raw) try allocator.dupe(u8, message_json) else null;
        defer if (raw_message_json) |v| allocator.free(v);

        const raw_parts_json = if (options.include_raw)
            if (raw_parts_written == 0)
                try allocator.dupe(u8, "[]")
            else blk: {
                try raw_parts_builder.append(allocator, ']');
                break :blk try raw_parts_builder.toOwnedSlice(allocator);
            }
        else
            null;
        defer if (raw_parts_json) |v| allocator.free(v);

        var row = Row{
            .source_kind = try allocator.dupe(u8, "db"),
            .source_path = try allocator.dupe(u8, db_path),
            .source_record_index = source_record_index,
            .session_id = try allocator.dupe(u8, session_id),
            .session_slug = if (session_slug) |v| try allocator.dupe(u8, v) else null,
            .session_directory = if (session_directory) |v| try allocator.dupe(u8, v) else null,
            .message_id = try allocator.dupe(u8, message_id),
            .message_parent_id = if (parsed_message.parent_id) |v| try allocator.dupe(u8, v) else null,
            .role = try allocator.dupe(u8, parsed_message.role),
            .mode = if (parsed_message.mode) |v| try allocator.dupe(u8, v) else null,
            .prompt_text = try allocator.dupe(u8, prompt.text),
            .prompt_len = prompt.text.len,
            .prompt_from_summary = prompt.from_summary,
            .prompt_truncated = false,
            .parts_count = parts_count,
            .text_parts_count = text_parts_count,
            .file_parts_count = file_parts_count,
            .part_types = try allocator.dupe(u8, part_types_csv),
            .file_paths = try allocator.dupe(u8, file_paths_csv),
            .time_created_epoch_ms = time_created_epoch_ms,
            .time_created_iso = if (time_created_iso) |v| try allocator.dupe(u8, v) else null,
            .time_updated_epoch_ms = time_updated_epoch_ms,
            .time_updated_iso = if (time_updated_iso) |v| try allocator.dupe(u8, v) else null,
            .raw_message_json = if (raw_message_json) |v| try allocator.dupe(u8, v) else null,
            .raw_parts_json = if (raw_parts_json) |v| try allocator.dupe(u8, v) else null,
        };
        errdefer row.deinit(allocator);

        try rows.append(allocator, row);
    }

    return rows;
}

fn collectFromJsonl(allocator: std.mem.Allocator, options: Options) !RowList {
    const source_path = try sqlite.resolveDefaultJsonlPath(allocator, options.opencode_path);
    defer allocator.free(source_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, source_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.MissingOpencodeHistory,
        else => return err,
    };
    defer file.close(io);

    var rows = RowList.empty;
    errdefer deinitRows(allocator, &rows);

    var line_number: i64 = 0;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);

    read_loop: while (true) {
        const read_n = try reader.interface.readSliceShort(buf[0..]);
        if (read_n == 0) break;

        var start: usize = 0;
        for (buf[0..read_n], 0..) |byte, idx| {
            if (byte != '\n') continue;

            if (idx > start) {
                try pending.appendSlice(allocator, buf[start..idx]);
                if (pending.items.len > 8 * 1024 * 1024) return error.StreamTooLong;
            }
            line_number += 1;
            const line = std.mem.trim(u8, pending.items, "\r");
            if (line.len > 0) {
                const maybe_row = try parseJsonlLine(allocator, source_path, line, line_number, options);
                if (maybe_row) |row| {
                    try rows.append(allocator, row);
                    if (!options.order_desc and options.limit > 0 and rows.items.len >= options.limit) break :read_loop;
                }
            }
            pending.clearRetainingCapacity();
            start = idx + 1;
        }

        if (start < read_n) {
            try pending.appendSlice(allocator, buf[start..read_n]);
            if (pending.items.len > 8 * 1024 * 1024) return error.StreamTooLong;
        }
    }

    if (pending.items.len > 0) {
        line_number += 1;
        const line = std.mem.trim(u8, pending.items, "\r");
        if (line.len > 0) {
            const maybe_row = try parseJsonlLine(allocator, source_path, line, line_number, options);
            if (maybe_row) |row| {
                try rows.append(allocator, row);
            }
        }
    }

    if (options.order_desc) reverseRows(&rows);
    if (options.limit > 0 and rows.items.len > options.limit) {
        trimRows(allocator, &rows, options.limit);
    }

    return rows;
}

const PromptValue = struct {
    text: []u8,
    from_summary: bool,
};

fn parseJsonlLine(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    line: []const u8,
    line_number: i64,
    options: Options,
) !?Row {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |entries| entries,
        else => return null,
    };

    if (options.session_id != null or options.session_slug != null or options.message_id != null) return null;
    if (options.time_created_min_ms != null or options.time_created_max_ms != null) return null;

    const prompt_text = stringField(obj, "input") orelse return null;
    const mode = stringField(obj, "mode");
    if (options.mode) |expected_mode| {
        if (mode == null or !std.mem.eql(u8, mode.?, expected_mode)) return null;
    }
    const parts_value = valueField(obj, "parts");

    var part_types: std.ArrayList([]u8) = .empty;
    defer freeStringList(allocator, &part_types);
    var file_paths: std.ArrayList([]u8) = .empty;
    defer freeStringList(allocator, &file_paths);

    var parts_count: usize = 0;
    var text_parts_count: usize = 0;
    var file_parts_count: usize = 0;

    switch (parts_value) {
        .array => |arr| {
            parts_count = arr.items.len;
            for (arr.items) |part| {
                const part_obj = switch (part) {
                    .object => |entry| entry,
                    else => continue,
                };
                const part_type = stringField(part_obj, "type") orelse continue;
                try appendUnique(&part_types, allocator, part_type);
                if (std.mem.eql(u8, part_type, "text")) {
                    text_parts_count += 1;
                } else if (std.mem.eql(u8, part_type, "file")) {
                    file_parts_count += 1;
                    if (nestedStringField(part_obj, "source", "path")) |path| {
                        try appendUnique(&file_paths, allocator, path);
                    } else if (stringField(part_obj, "filename")) |filename| {
                        try appendUnique(&file_paths, allocator, filename);
                    }
                }
            }
        },
        else => {},
    }

    const part_types_csv = try joinSortedCsv(allocator, &part_types);
    errdefer allocator.free(part_types_csv);
    const file_paths_csv = try joinSortedCsv(allocator, &file_paths);
    errdefer allocator.free(file_paths_csv);

    const raw_parts_json = if (options.include_raw)
        try stringifyParts(allocator, parts_value)
    else
        null;
    errdefer if (raw_parts_json) |v| allocator.free(v);

    var row = Row{
        .source_kind = try allocator.dupe(u8, "jsonl"),
        .source_path = try allocator.dupe(u8, source_path),
        .source_record_index = line_number,
        .role = try allocator.dupe(u8, "user"),
        .mode = if (mode) |value| try allocator.dupe(u8, value) else null,
        .prompt_text = try allocator.dupe(u8, prompt_text),
        .prompt_len = prompt_text.len,
        .prompt_from_summary = false,
        .prompt_truncated = false,
        .parts_count = parts_count,
        .text_parts_count = text_parts_count,
        .file_parts_count = file_parts_count,
        .part_types = part_types_csv,
        .file_paths = file_paths_csv,
        .raw_message_json = if (options.include_raw) try allocator.dupe(u8, line) else null,
        .raw_parts_json = raw_parts_json,
    };
    errdefer row.deinit(allocator);

    return row;
}

fn parseMessageJson(allocator: std.mem.Allocator, message_json: []const u8) !ParsedMessage {
    var out = ParsedMessage{
        .role = try allocator.dupe(u8, "user"),
    };
    errdefer out.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), message_json, .{}) catch return out;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |entries| entries,
        else => return out,
    };

    if (stringField(obj, "role")) |role_value| {
        allocator.free(out.role);
        out.role = try allocator.dupe(u8, role_value);
    }
    if (stringField(obj, "mode")) |mode_value| {
        out.mode = try allocator.dupe(u8, mode_value);
    }
    if (stringField(obj, "parentID")) |parent_value| {
        out.parent_id = try allocator.dupe(u8, parent_value);
    }
    if (objectField(obj, "summary")) |summary_obj| {
        if (stringField(summary_obj, "body")) |summary_body| {
            out.summary_body = try allocator.dupe(u8, summary_body);
        }
    }

    return out;
}

fn stringifyParts(allocator: std.mem.Allocator, parts_value: std.json.Value) ![]u8 {
    return switch (parts_value) {
        .array => |arr| std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = arr }, .{}),
        .null => allocator.dupe(u8, "[]"),
        else => allocator.dupe(u8, "[]"),
    };
}

fn joinTextSegments(allocator: std.mem.Allocator, segments: []const []u8) ![]u8 {
    if (segments.len == 0) return allocator.dupe(u8, "");
    if (segments.len == 1) return allocator.dupe(u8, segments[0]);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    for (segments, 0..) |segment, idx| {
        if (idx != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, segment);
    }

    return out.toOwnedSlice(allocator);
}

fn joinSortedCsv(allocator: std.mem.Allocator, values: *std.ArrayList([]u8)) ![]u8 {
    if (values.items.len == 0) return allocator.dupe(u8, "");

    std.mem.sort([]u8, values.items, {}, lessThanString);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    for (values.items, 0..) |value, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, value);
    }

    return out.toOwnedSlice(allocator);
}

fn lessThanString(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn appendUnique(list: *std.ArrayList([]u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn valueField(obj: std.json.ObjectMap, key: []const u8) std.json.Value {
    return obj.get(key) orelse .null;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |nested| nested,
        else => null,
    };
}

fn nestedStringField(obj: std.json.ObjectMap, parent_key: []const u8, child_key: []const u8) ?[]const u8 {
    const parent_obj = objectField(obj, parent_key) orelse return null;
    return stringField(parent_obj, child_key);
}

fn bindOptionalText(stmt: *sqlite.Stmt, idx: c_int, value: ?[]const u8) !void {
    if (value) |text| {
        try stmt.bindText(idx, text);
    } else {
        try stmt.bindNull(idx);
    }
}

fn bindOptionalInt64(stmt: *sqlite.Stmt, idx: c_int, value: ?i64) !void {
    if (value) |number| {
        try stmt.bindInt64(idx, number);
    } else {
        try stmt.bindNull(idx);
    }
}

fn reverseRows(rows: *RowList) void {
    if (rows.items.len <= 1) return;
    var left: usize = 0;
    var right: usize = rows.items.len - 1;
    while (left < right) {
        const tmp = rows.items[left];
        rows.items[left] = rows.items[right];
        rows.items[right] = tmp;
        left += 1;
        right -= 1;
    }
}

fn trimRows(allocator: std.mem.Allocator, rows: *RowList, keep: usize) void {
    if (keep >= rows.items.len) return;
    var idx = keep;
    while (idx < rows.items.len) : (idx += 1) {
        rows.items[idx].deinit(allocator);
    }
    rows.items.len = keep;
}

test "collect jsonl fallback returns db-native shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "prompt-history.jsonl",
        .data =
        \\{"input":"one","parts":[],"mode":"normal"}
        \\{"input":"two","parts":[{"type":"file","filename":"a.txt"},{"type":"text","text":"x"}],"mode":"review"}
        ,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "prompt-history.jsonl" });
    defer std.testing.allocator.free(source_path);

    var rows = try collect(std.testing.allocator, .{
        .opencode_path = source_path,
        .source = .jsonl,
        .include_raw = true,
    });
    defer deinitRows(std.testing.allocator, &rows);

    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("jsonl", rows.items[0].source_kind);
    try std.testing.expectEqual(@as(i64, 1), rows.items[0].source_record_index);
    try std.testing.expectEqualStrings("one", rows.items[0].prompt_text);
    try std.testing.expectEqual(@as(usize, 0), rows.items[0].parts_count);
    try std.testing.expect(rows.items[0].raw_message_json != null);
    try std.testing.expect(rows.items[0].raw_parts_json != null);

    try std.testing.expectEqual(@as(i64, 2), rows.items[1].source_record_index);
    try std.testing.expectEqualStrings("file,text", rows.items[1].part_types);
    try std.testing.expectEqualStrings("a.txt", rows.items[1].file_paths);
}
