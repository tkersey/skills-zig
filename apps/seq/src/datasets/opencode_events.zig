const std = @import("std");
const sqlite = @import("opencode_sqlite.zig");

pub const Options = struct {
    opencode_db_path: ?[]const u8 = null,
    opencode_path: ?[]const u8 = null,
    source: sqlite.Source = .auto,
    include_raw: bool = false,
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
    part_id: ?[]u8 = null,
    event_index: i64,

    role: []u8,
    mode: ?[]u8 = null,
    agent: ?[]u8 = null,
    model_id: ?[]u8 = null,
    provider_id: ?[]u8 = null,

    part_type: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    tool_status: ?[]u8 = null,
    call_id: ?[]u8 = null,

    text: ?[]u8 = null,
    text_len: ?usize = null,
    filename: ?[]u8 = null,
    file_path: ?[]u8 = null,
    mime: ?[]u8 = null,

    time_created_epoch_ms: ?i64 = null,
    time_created_iso: ?[]u8 = null,
    time_updated_epoch_ms: ?i64 = null,
    time_updated_iso: ?[]u8 = null,

    raw_message_json: ?[]u8 = null,
    raw_part_json: ?[]u8 = null,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.source_kind);
        allocator.free(self.source_path);
        if (self.session_id) |v| allocator.free(v);
        if (self.session_slug) |v| allocator.free(v);
        if (self.session_directory) |v| allocator.free(v);
        if (self.message_id) |v| allocator.free(v);
        if (self.message_parent_id) |v| allocator.free(v);
        if (self.part_id) |v| allocator.free(v);
        allocator.free(self.role);
        if (self.mode) |v| allocator.free(v);
        if (self.agent) |v| allocator.free(v);
        if (self.model_id) |v| allocator.free(v);
        if (self.provider_id) |v| allocator.free(v);
        if (self.part_type) |v| allocator.free(v);
        if (self.tool_name) |v| allocator.free(v);
        if (self.tool_status) |v| allocator.free(v);
        if (self.call_id) |v| allocator.free(v);
        if (self.text) |v| allocator.free(v);
        if (self.filename) |v| allocator.free(v);
        if (self.file_path) |v| allocator.free(v);
        if (self.mime) |v| allocator.free(v);
        if (self.time_created_iso) |v| allocator.free(v);
        if (self.time_updated_iso) |v| allocator.free(v);
        if (self.raw_message_json) |v| allocator.free(v);
        if (self.raw_part_json) |v| allocator.free(v);
    }
};

pub const RowList = std.ArrayList(Row);

const ParsedMessage = struct {
    role: []u8,
    mode: ?[]u8 = null,
    parent_id: ?[]u8 = null,
    agent: ?[]u8 = null,
    model_id: ?[]u8 = null,
    provider_id: ?[]u8 = null,

    fn deinit(self: *ParsedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        if (self.mode) |v| allocator.free(v);
        if (self.parent_id) |v| allocator.free(v);
        if (self.agent) |v| allocator.free(v);
        if (self.model_id) |v| allocator.free(v);
        if (self.provider_id) |v| allocator.free(v);
    }
};

const ParsedPart = struct {
    part_type: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    tool_status: ?[]u8 = null,
    call_id: ?[]u8 = null,
    text: ?[]u8 = null,
    filename: ?[]u8 = null,
    file_path: ?[]u8 = null,
    mime: ?[]u8 = null,

    fn deinit(self: *ParsedPart, allocator: std.mem.Allocator) void {
        if (self.part_type) |v| allocator.free(v);
        if (self.tool_name) |v| allocator.free(v);
        if (self.tool_status) |v| allocator.free(v);
        if (self.call_id) |v| allocator.free(v);
        if (self.text) |v| allocator.free(v);
        if (self.filename) |v| allocator.free(v);
        if (self.file_path) |v| allocator.free(v);
        if (self.mime) |v| allocator.free(v);
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

    var messages_stmt = try db.prepare(allocator,
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
        \\ORDER BY m.time_created ASC, m.rowid ASC
    );
    defer messages_stmt.deinit();

    var parts_stmt = try db.prepare(allocator,
        \\SELECT
        \\  p.id,
        \\  p.time_created,
        \\  p.time_updated,
        \\  p.data
        \\FROM part p
        \\WHERE p.message_id = ?1
        \\ORDER BY p.time_created ASC, p.rowid ASC
    );
    defer parts_stmt.deinit();

    var rows = RowList.empty;
    errdefer deinitRows(allocator, &rows);

    while (try messages_stmt.step() == .row) {
        const source_record_index = messages_stmt.intColumn(0);
        const message_id = try messages_stmt.textColumnAlloc(allocator, 1);
        defer allocator.free(message_id);
        const session_id = try messages_stmt.textColumnAlloc(allocator, 2);
        defer allocator.free(session_id);
        const message_time_created = messages_stmt.nullableIntColumn(3);
        const message_time_updated = messages_stmt.nullableIntColumn(4);
        const message_json = try messages_stmt.textColumnAlloc(allocator, 5);
        defer allocator.free(message_json);
        const session_slug = try messages_stmt.nullableTextColumnAlloc(allocator, 6);
        defer if (session_slug) |v| allocator.free(v);
        const session_directory = try messages_stmt.nullableTextColumnAlloc(allocator, 7);
        defer if (session_directory) |v| allocator.free(v);

        var parsed_message = try parseMessageJson(allocator, message_json);
        defer parsed_message.deinit(allocator);

        var event_index: i64 = 0;
        var emitted_any = false;

        try parts_stmt.reset();
        try parts_stmt.bindText(1, message_id);
        while (try parts_stmt.step() == .row) {
            emitted_any = true;
            event_index += 1;

            const part_id = try parts_stmt.textColumnAlloc(allocator, 0);
            defer allocator.free(part_id);
            const part_time_created = parts_stmt.nullableIntColumn(1);
            const part_time_updated = parts_stmt.nullableIntColumn(2);
            const part_json = try parts_stmt.textColumnAlloc(allocator, 3);
            defer allocator.free(part_json);

            var parsed_part = try parsePartJson(allocator, part_json);
            defer parsed_part.deinit(allocator);

            const created_iso = try sqlite.epochMsToIso8601Alloc(allocator, part_time_created);
            defer if (created_iso) |v| allocator.free(v);
            const updated_iso = try sqlite.epochMsToIso8601Alloc(allocator, part_time_updated);
            defer if (updated_iso) |v| allocator.free(v);

            var row = Row{
                .source_kind = try allocator.dupe(u8, "db"),
                .source_path = try allocator.dupe(u8, db_path),
                .source_record_index = source_record_index,
                .session_id = try allocator.dupe(u8, session_id),
                .session_slug = if (session_slug) |v| try allocator.dupe(u8, v) else null,
                .session_directory = if (session_directory) |v| try allocator.dupe(u8, v) else null,
                .message_id = try allocator.dupe(u8, message_id),
                .message_parent_id = if (parsed_message.parent_id) |v| try allocator.dupe(u8, v) else null,
                .part_id = try allocator.dupe(u8, part_id),
                .event_index = event_index,
                .role = try allocator.dupe(u8, parsed_message.role),
                .mode = if (parsed_message.mode) |v| try allocator.dupe(u8, v) else null,
                .agent = if (parsed_message.agent) |v| try allocator.dupe(u8, v) else null,
                .model_id = if (parsed_message.model_id) |v| try allocator.dupe(u8, v) else null,
                .provider_id = if (parsed_message.provider_id) |v| try allocator.dupe(u8, v) else null,
                .part_type = if (parsed_part.part_type) |v| try allocator.dupe(u8, v) else null,
                .tool_name = if (parsed_part.tool_name) |v| try allocator.dupe(u8, v) else null,
                .tool_status = if (parsed_part.tool_status) |v| try allocator.dupe(u8, v) else null,
                .call_id = if (parsed_part.call_id) |v| try allocator.dupe(u8, v) else null,
                .text = if (parsed_part.text) |v| try allocator.dupe(u8, v) else null,
                .text_len = if (parsed_part.text) |v| v.len else null,
                .filename = if (parsed_part.filename) |v| try allocator.dupe(u8, v) else null,
                .file_path = if (parsed_part.file_path) |v| try allocator.dupe(u8, v) else null,
                .mime = if (parsed_part.mime) |v| try allocator.dupe(u8, v) else null,
                .time_created_epoch_ms = part_time_created,
                .time_created_iso = if (created_iso) |v| try allocator.dupe(u8, v) else null,
                .time_updated_epoch_ms = part_time_updated,
                .time_updated_iso = if (updated_iso) |v| try allocator.dupe(u8, v) else null,
                .raw_message_json = if (options.include_raw) try allocator.dupe(u8, message_json) else null,
                .raw_part_json = if (options.include_raw) try allocator.dupe(u8, part_json) else null,
            };
            errdefer row.deinit(allocator);

            try rows.append(allocator, row);
        }

        if (!emitted_any) {
            const created_iso = try sqlite.epochMsToIso8601Alloc(allocator, message_time_created);
            defer if (created_iso) |v| allocator.free(v);
            const updated_iso = try sqlite.epochMsToIso8601Alloc(allocator, message_time_updated);
            defer if (updated_iso) |v| allocator.free(v);

            var row = Row{
                .source_kind = try allocator.dupe(u8, "db"),
                .source_path = try allocator.dupe(u8, db_path),
                .source_record_index = source_record_index,
                .session_id = try allocator.dupe(u8, session_id),
                .session_slug = if (session_slug) |v| try allocator.dupe(u8, v) else null,
                .session_directory = if (session_directory) |v| try allocator.dupe(u8, v) else null,
                .message_id = try allocator.dupe(u8, message_id),
                .message_parent_id = if (parsed_message.parent_id) |v| try allocator.dupe(u8, v) else null,
                .part_id = null,
                .event_index = 0,
                .role = try allocator.dupe(u8, parsed_message.role),
                .mode = if (parsed_message.mode) |v| try allocator.dupe(u8, v) else null,
                .agent = if (parsed_message.agent) |v| try allocator.dupe(u8, v) else null,
                .model_id = if (parsed_message.model_id) |v| try allocator.dupe(u8, v) else null,
                .provider_id = if (parsed_message.provider_id) |v| try allocator.dupe(u8, v) else null,
                .time_created_epoch_ms = message_time_created,
                .time_created_iso = if (created_iso) |v| try allocator.dupe(u8, v) else null,
                .time_updated_epoch_ms = message_time_updated,
                .time_updated_iso = if (updated_iso) |v| try allocator.dupe(u8, v) else null,
                .raw_message_json = if (options.include_raw) try allocator.dupe(u8, message_json) else null,
                .raw_part_json = null,
            };
            errdefer row.deinit(allocator);

            try rows.append(allocator, row);
        }
    }

    return rows;
}

fn collectFromJsonl(allocator: std.mem.Allocator, options: Options) !RowList {
    const source_path = try sqlite.resolveDefaultJsonlPath(allocator, options.opencode_path);
    defer allocator.free(source_path);

    const file = std.fs.openFileAbsolute(source_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.MissingOpencodeHistory,
        else => return err,
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch return error.MissingOpencodeHistory;
    defer allocator.free(content);

    var rows = RowList.empty;
    errdefer deinitRows(allocator, &rows);

    var line_number: i64 = 0;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        try parseJsonlLine(allocator, source_path, line, line_number, options.include_raw, &rows);
    }

    return rows;
}

fn parseJsonlLine(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    line: []const u8,
    line_number: i64,
    include_raw: bool,
    rows: *RowList,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{}) catch return;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |entries| entries,
        else => return,
    };

    const input = stringField(obj, "input");
    const mode = stringField(obj, "mode");
    const parts_value = valueField(obj, "parts");

    var emitted_any = false;
    switch (parts_value) {
        .array => |arr| {
            for (arr.items, 0..) |part, idx| {
                const part_obj = switch (part) {
                    .object => |entry| entry,
                    else => continue,
                };

                const part_type = stringField(part_obj, "type");
                const part_text = stringField(part_obj, "text");
                const part_filename = stringField(part_obj, "filename");
                const part_file_path = nestedStringField(part_obj, "source", "path");
                const part_mime = stringField(part_obj, "mime");
                const part_tool = stringField(part_obj, "tool");
                const part_status = nestedStringField(part_obj, "state", "status");
                const part_call_id = stringField(part_obj, "callID");

                const raw_part_json = if (include_raw)
                    try std.json.Stringify.valueAlloc(allocator, part, .{})
                else
                    null;
                defer if (raw_part_json) |v| allocator.free(v);

                var row = Row{
                    .source_kind = try allocator.dupe(u8, "jsonl"),
                    .source_path = try allocator.dupe(u8, source_path),
                    .source_record_index = line_number,
                    .event_index = @intCast(idx + 1),
                    .role = try allocator.dupe(u8, "user"),
                    .mode = if (mode) |v| try allocator.dupe(u8, v) else null,
                    .part_type = if (part_type) |v| try allocator.dupe(u8, v) else null,
                    .tool_name = if (part_tool) |v| try allocator.dupe(u8, v) else null,
                    .tool_status = if (part_status) |v| try allocator.dupe(u8, v) else null,
                    .call_id = if (part_call_id) |v| try allocator.dupe(u8, v) else null,
                    .text = if (part_text) |v| try allocator.dupe(u8, v) else null,
                    .text_len = if (part_text) |v| v.len else null,
                    .filename = if (part_filename) |v| try allocator.dupe(u8, v) else null,
                    .file_path = if (part_file_path) |v| try allocator.dupe(u8, v) else null,
                    .mime = if (part_mime) |v| try allocator.dupe(u8, v) else null,
                    .raw_message_json = if (include_raw) try allocator.dupe(u8, line) else null,
                    .raw_part_json = if (raw_part_json) |v| try allocator.dupe(u8, v) else null,
                };
                errdefer row.deinit(allocator);

                try rows.append(allocator, row);
                emitted_any = true;
            }
        },
        else => {},
    }

    if (!emitted_any and input != null) {
        const text = input.?;
        var row = Row{
            .source_kind = try allocator.dupe(u8, "jsonl"),
            .source_path = try allocator.dupe(u8, source_path),
            .source_record_index = line_number,
            .event_index = 1,
            .role = try allocator.dupe(u8, "user"),
            .mode = if (mode) |v| try allocator.dupe(u8, v) else null,
            .part_type = try allocator.dupe(u8, "text"),
            .text = try allocator.dupe(u8, text),
            .text_len = text.len,
            .raw_message_json = if (include_raw) try allocator.dupe(u8, line) else null,
            .raw_part_json = if (include_raw) try allocator.dupe(u8, "null") else null,
        };
        errdefer row.deinit(allocator);
        try rows.append(allocator, row);
    }
}

fn parseMessageJson(allocator: std.mem.Allocator, message_json: []const u8) !ParsedMessage {
    var out = ParsedMessage{ .role = try allocator.dupe(u8, "assistant") };
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
    if (stringField(obj, "agent")) |agent_value| {
        out.agent = try allocator.dupe(u8, agent_value);
    }
    if (stringField(obj, "modelID")) |model_id| {
        out.model_id = try allocator.dupe(u8, model_id);
    }
    if (stringField(obj, "providerID")) |provider_id| {
        out.provider_id = try allocator.dupe(u8, provider_id);
    }

    return out;
}

fn parsePartJson(allocator: std.mem.Allocator, part_json: []const u8) !ParsedPart {
    var out = ParsedPart{};
    errdefer out.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), part_json, .{}) catch return out;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |entries| entries,
        else => return out,
    };

    if (stringField(obj, "type")) |value| out.part_type = try allocator.dupe(u8, value);
    if (stringField(obj, "tool")) |value| out.tool_name = try allocator.dupe(u8, value);
    if (nestedStringField(obj, "state", "status")) |value| out.tool_status = try allocator.dupe(u8, value);
    if (stringField(obj, "callID")) |value| out.call_id = try allocator.dupe(u8, value);
    if (stringField(obj, "text")) |value| out.text = try allocator.dupe(u8, value);
    if (stringField(obj, "filename")) |value| out.filename = try allocator.dupe(u8, value);
    if (nestedStringField(obj, "source", "path")) |value| out.file_path = try allocator.dupe(u8, value);
    if (stringField(obj, "mime")) |value| out.mime = try allocator.dupe(u8, value);

    return out;
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

test "collect jsonl fallback emits synthetic text event when parts missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "prompt-history.jsonl",
        .data =
        \\{"input":"first","parts":[],"mode":"normal"}
        \\{"input":"second","parts":[{"type":"file","filename":"a.txt"},{"type":"text","text":"hello"}],"mode":"review"}
        ,
    });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_abs);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "prompt-history.jsonl" });
    defer std.testing.allocator.free(source_path);

    var rows = try collect(std.testing.allocator, .{
        .opencode_path = source_path,
        .source = .jsonl,
        .include_raw = true,
    });
    defer deinitRows(std.testing.allocator, &rows);

    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try std.testing.expectEqualStrings("text", rows.items[0].part_type.?);
    try std.testing.expectEqualStrings("first", rows.items[0].text.?);
    try std.testing.expect(rows.items[0].raw_message_json != null);

    try std.testing.expectEqualStrings("file", rows.items[1].part_type.?);
    try std.testing.expectEqualStrings("a.txt", rows.items[1].filename.?);
    try std.testing.expectEqualStrings("text", rows.items[2].part_type.?);
    try std.testing.expectEqualStrings("hello", rows.items[2].text.?);
}
