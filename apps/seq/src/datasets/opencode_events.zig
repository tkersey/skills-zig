const std = @import("std");
const sqlite = @import("opencode_sqlite.zig");

pub const Options = struct {
    opencode_db_path: ?[]const u8 = null,
    opencode_path: ?[]const u8 = null,
    source: sqlite.Source = .auto,
    include_raw: bool = false,
    session_id: ?[]const u8 = null,
    session_slug: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    role: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    part_type: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_status: ?[]const u8 = null,
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
    tool_start_epoch_ms: ?i64 = null,
    tool_end_epoch_ms: ?i64 = null,
    tool_duration_ms: ?i64 = null,
    tool_exit_code: ?i64 = null,
    tool_command: ?[]u8 = null,
    tool_output_len: ?usize = null,
    part_time_start_epoch_ms: ?i64 = null,
    part_time_end_epoch_ms: ?i64 = null,
    has_reasoning_encrypted_content: bool = false,

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
        if (self.tool_command) |v| allocator.free(v);
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
    tool_start_epoch_ms: ?i64 = null,
    tool_end_epoch_ms: ?i64 = null,
    tool_duration_ms: ?i64 = null,
    tool_exit_code: ?i64 = null,
    tool_command: ?[]u8 = null,
    tool_output_len: ?usize = null,
    part_time_start_epoch_ms: ?i64 = null,
    part_time_end_epoch_ms: ?i64 = null,
    has_reasoning_encrypted_content: bool = false,
    text: ?[]u8 = null,
    filename: ?[]u8 = null,
    file_path: ?[]u8 = null,
    mime: ?[]u8 = null,

    fn deinit(self: *ParsedPart, allocator: std.mem.Allocator) void {
        if (self.part_type) |v| allocator.free(v);
        if (self.tool_name) |v| allocator.free(v);
        if (self.tool_status) |v| allocator.free(v);
        if (self.call_id) |v| allocator.free(v);
        if (self.tool_command) |v| allocator.free(v);
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

    const order_keyword = if (options.order_desc) "DESC" else "ASC";
    const limit_clause = if (options.limit > 0) "LIMIT ?8" else "";
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
        \\WHERE (?1 IS NULL OR m.session_id = ?1)
        \\  AND (?2 IS NULL OR s.slug = ?2)
        \\  AND (?3 IS NULL OR m.id = ?3)
        \\  AND (?4 IS NULL OR json_extract(m.data, '$.role') = ?4)
        \\  AND (?5 IS NULL OR json_extract(m.data, '$.mode') = ?5)
        \\  AND (?6 IS NULL OR m.time_created >= ?6)
        \\  AND (?7 IS NULL OR m.time_created <= ?7)
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
        \\  p.id,
        \\  p.time_created,
        \\  p.time_updated,
        \\  p.data
        \\FROM part p
        \\WHERE p.message_id = ?1
        \\  AND (?2 IS NULL OR json_extract(p.data, '$.type') = ?2)
        \\  AND (?3 IS NULL OR json_extract(p.data, '$.tool') = ?3)
        \\  AND (?4 IS NULL OR json_extract(p.data, '$.state.status') = ?4)
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
    try bindOptionalText(&messages_stmt, 4, options.role);
    try bindOptionalText(&messages_stmt, 5, options.mode);
    try bindOptionalInt64(&messages_stmt, 6, options.time_created_min_ms);
    try bindOptionalInt64(&messages_stmt, 7, options.time_created_max_ms);
    if (options.limit > 0) try messages_stmt.bindInt64(8, @intCast(options.limit));

    message_loop: while (try messages_stmt.step() == .row) {
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
        try bindOptionalText(&parts_stmt, 2, options.part_type);
        try bindOptionalText(&parts_stmt, 3, options.tool_name);
        try bindOptionalText(&parts_stmt, 4, options.tool_status);
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
                .tool_start_epoch_ms = parsed_part.tool_start_epoch_ms,
                .tool_end_epoch_ms = parsed_part.tool_end_epoch_ms,
                .tool_duration_ms = parsed_part.tool_duration_ms,
                .tool_exit_code = parsed_part.tool_exit_code,
                .tool_command = if (parsed_part.tool_command) |v| try allocator.dupe(u8, v) else null,
                .tool_output_len = parsed_part.tool_output_len,
                .part_time_start_epoch_ms = parsed_part.part_time_start_epoch_ms,
                .part_time_end_epoch_ms = parsed_part.part_time_end_epoch_ms,
                .has_reasoning_encrypted_content = parsed_part.has_reasoning_encrypted_content,
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
            if (options.limit > 0 and rows.items.len >= options.limit) break :message_loop;
        }

        if (!emitted_any and options.part_type == null and options.tool_name == null and options.tool_status == null) {
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
            if (options.limit > 0 and rows.items.len >= options.limit) break :message_loop;
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

    var rows = RowList.empty;
    errdefer deinitRows(allocator, &rows);

    var line_number: i64 = 0;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var buf: [64 * 1024]u8 = undefined;

    read_loop: while (true) {
        const read_n = try file.read(&buf);
        if (read_n == 0) break;

        var start: usize = 0;
        for (buf[0..read_n], 0..) |byte, idx| {
            if (byte != '\n') continue;

            if (idx > start) {
                try pending.appendSlice(allocator, buf[start..idx]);
                if (pending.items.len > 8 * 1024 * 1024) return error.StreamTooLong;
            }
            line_number += 1;
            const line = std.mem.trimRight(u8, pending.items, "\r");
            if (line.len > 0) {
                try parseJsonlLine(allocator, source_path, line, line_number, options, &rows);
                if (!options.order_desc and options.limit > 0 and rows.items.len >= options.limit) break :read_loop;
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
        const line = std.mem.trimRight(u8, pending.items, "\r");
        if (line.len > 0) {
            try parseJsonlLine(allocator, source_path, line, line_number, options, &rows);
        }
    }

    if (options.order_desc) reverseRows(&rows);
    if (options.limit > 0 and rows.items.len > options.limit) {
        trimRows(allocator, &rows, options.limit);
    }

    return rows;
}

fn parseJsonlLine(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    line: []const u8,
    line_number: i64,
    options: Options,
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

    if (options.session_id != null or options.session_slug != null or options.message_id != null) return;
    if (options.time_created_min_ms != null or options.time_created_max_ms != null) return;
    if (options.role) |expected_role| {
        if (!std.mem.eql(u8, expected_role, "user")) return;
    }

    const input = stringField(obj, "input");
    const mode = stringField(obj, "mode");
    if (options.mode) |expected_mode| {
        if (mode == null or !std.mem.eql(u8, mode.?, expected_mode)) return;
    }
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
                const tool_start_epoch_ms = nestedIntField3(part_obj, "state", "time", "start");
                const tool_end_epoch_ms = nestedIntField3(part_obj, "state", "time", "end");
                const tool_duration_ms = durationMs(tool_start_epoch_ms, tool_end_epoch_ms);
                const tool_exit_code = nestedIntField3(part_obj, "state", "metadata", "exit") orelse nestedIntField(part_obj, "metadata", "exit");
                const tool_command = nestedStringField3(part_obj, "state", "input", "command");
                const tool_output = nestedStringField(part_obj, "state", "output") orelse nestedStringField3(part_obj, "state", "metadata", "output");
                const part_time_start_epoch_ms = nestedIntField(part_obj, "time", "start");
                const part_time_end_epoch_ms = nestedIntField(part_obj, "time", "end");
                const has_reasoning_encrypted_content = nestedStringField3(part_obj, "metadata", "openai", "reasoningEncryptedContent") != null;
                const event_time_epoch_ms = part_time_end_epoch_ms orelse part_time_start_epoch_ms orelse tool_end_epoch_ms orelse tool_start_epoch_ms;
                const event_time_iso = try sqlite.epochMsToIso8601Alloc(allocator, event_time_epoch_ms);
                defer if (event_time_iso) |v| allocator.free(v);

                if (options.part_type) |expected| {
                    if (part_type == null or !std.mem.eql(u8, part_type.?, expected)) continue;
                }
                if (options.tool_name) |expected| {
                    if (part_tool == null or !std.mem.eql(u8, part_tool.?, expected)) continue;
                }
                if (options.tool_status) |expected| {
                    if (part_status == null or !std.mem.eql(u8, part_status.?, expected)) continue;
                }

                const raw_part_json = if (options.include_raw)
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
                    .tool_start_epoch_ms = tool_start_epoch_ms,
                    .tool_end_epoch_ms = tool_end_epoch_ms,
                    .tool_duration_ms = tool_duration_ms,
                    .tool_exit_code = tool_exit_code,
                    .tool_command = if (tool_command) |v| try allocator.dupe(u8, v) else null,
                    .tool_output_len = if (tool_output) |v| v.len else null,
                    .part_time_start_epoch_ms = part_time_start_epoch_ms,
                    .part_time_end_epoch_ms = part_time_end_epoch_ms,
                    .has_reasoning_encrypted_content = has_reasoning_encrypted_content,
                    .text = if (part_text) |v| try allocator.dupe(u8, v) else null,
                    .text_len = if (part_text) |v| v.len else null,
                    .filename = if (part_filename) |v| try allocator.dupe(u8, v) else null,
                    .file_path = if (part_file_path) |v| try allocator.dupe(u8, v) else null,
                    .mime = if (part_mime) |v| try allocator.dupe(u8, v) else null,
                    .time_created_epoch_ms = event_time_epoch_ms,
                    .time_created_iso = if (event_time_iso) |v| try allocator.dupe(u8, v) else null,
                    .time_updated_epoch_ms = event_time_epoch_ms,
                    .time_updated_iso = if (event_time_iso) |v| try allocator.dupe(u8, v) else null,
                    .raw_message_json = if (options.include_raw) try allocator.dupe(u8, line) else null,
                    .raw_part_json = if (raw_part_json) |v| try allocator.dupe(u8, v) else null,
                };
                errdefer row.deinit(allocator);

                try rows.append(allocator, row);
                emitted_any = true;
            }
        },
        else => {},
    }

    if (!emitted_any and input != null and options.part_type == null and options.tool_name == null and options.tool_status == null) {
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
            .raw_message_json = if (options.include_raw) try allocator.dupe(u8, line) else null,
            .raw_part_json = if (options.include_raw) try allocator.dupe(u8, "null") else null,
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
    out.tool_start_epoch_ms = nestedIntField3(obj, "state", "time", "start");
    out.tool_end_epoch_ms = nestedIntField3(obj, "state", "time", "end");
    out.tool_duration_ms = durationMs(out.tool_start_epoch_ms, out.tool_end_epoch_ms);
    out.tool_exit_code = nestedIntField3(obj, "state", "metadata", "exit") orelse nestedIntField(obj, "metadata", "exit");
    if (nestedStringField3(obj, "state", "input", "command")) |value| out.tool_command = try allocator.dupe(u8, value);
    if (nestedStringField(obj, "state", "output")) |value| {
        out.tool_output_len = value.len;
    } else if (nestedStringField3(obj, "state", "metadata", "output")) |value| {
        out.tool_output_len = value.len;
    }
    out.part_time_start_epoch_ms = nestedIntField(obj, "time", "start");
    out.part_time_end_epoch_ms = nestedIntField(obj, "time", "end");
    out.has_reasoning_encrypted_content = nestedStringField3(obj, "metadata", "openai", "reasoningEncryptedContent") != null;
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

fn nestedStringField3(obj: std.json.ObjectMap, k1: []const u8, k2: []const u8, k3: []const u8) ?[]const u8 {
    const parent_obj = objectField(obj, k1) orelse return null;
    return nestedStringField(parent_obj, k2, k3);
}

fn valueAsInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| blk: {
            if (!std.math.isFinite(number)) break :blk null;
            const min = @as(f64, @floatFromInt(std.math.minInt(i64)));
            const max = @as(f64, @floatFromInt(std.math.maxInt(i64)));
            if (number < min or number > max) break :blk null;
            break :blk @intFromFloat(number);
        },
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return valueAsInt(value);
}

fn nestedIntField(obj: std.json.ObjectMap, parent_key: []const u8, child_key: []const u8) ?i64 {
    const parent_obj = objectField(obj, parent_key) orelse return null;
    return intField(parent_obj, child_key);
}

fn nestedIntField3(obj: std.json.ObjectMap, k1: []const u8, k2: []const u8, k3: []const u8) ?i64 {
    const parent_obj = objectField(obj, k1) orelse return null;
    return nestedIntField(parent_obj, k2, k3);
}

fn durationMs(start_ms: ?i64, end_ms: ?i64) ?i64 {
    const start = start_ms orelse return null;
    const end = end_ms orelse return null;
    if (end < start) return null;
    return end - start;
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
