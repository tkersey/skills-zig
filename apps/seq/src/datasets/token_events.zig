const std = @import("std");

pub const token_key_count: usize = 5;
pub const input_idx: usize = 0;
pub const cached_input_idx: usize = 1;
pub const output_idx: usize = 2;
pub const reasoning_output_idx: usize = 3;
pub const total_idx: usize = 4;

const stream_chunk_size: usize = 64 * 1024;
const max_line_bytes: usize = 8 * 1024 * 1024;
const max_root_field_entries: usize = 32;
const max_payload_field_entries: usize = 16;
const max_info_field_entries: usize = 32;
const max_usage_field_entries: usize = 16;

pub const SmallText = struct {
    len: u8 = 0,
    buf: [64]u8 = [_]u8{0} ** 64,

    pub fn fromSlice(text: []const u8) !SmallText {
        if (text.len > 64) return error.TextTooLong;
        var out = SmallText{};
        out.len = @intCast(text.len);
        @memcpy(out.buf[0..text.len], text);
        return out;
    }

    pub fn slice(self: *const SmallText) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Row = struct {
    path: []const u8,
    timestamp: ?SmallText = null,
    day: ?SmallText = null,
    week: ?SmallText = null,
    month: ?SmallText = null,
    model_context_window: ?i64 = null,
    total_input_tokens: ?i64 = null,
    total_cached_input_tokens: ?i64 = null,
    total_output_tokens: ?i64 = null,
    total_reasoning_output_tokens: ?i64 = null,
    total_total_tokens: ?i64 = null,
    last_input_tokens: ?i64 = null,
    last_cached_input_tokens: ?i64 = null,
    last_output_tokens: ?i64 = null,
    last_reasoning_output_tokens: ?i64 = null,
    last_total_tokens: ?i64 = null,
};

pub const ParseOptions = struct {
    dedupe: bool = true,
    derive_timestamp_fields: bool = true,
};

const FieldEntry = struct {
    key_raw: []const u8,
    value: []const u8,
};

const UsageTuple = [token_key_count]?i64;

pub fn parseTokenEvents(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    dedupe: bool,
) !std.ArrayList(Row) {
    return parseTokenEventsWithOptions(allocator, path, content, .{
        .dedupe = dedupe,
        .derive_timestamp_fields = true,
    });
}

pub fn parseTokenEventsWithOptions(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    options: ParseOptions,
) !std.ArrayList(Row) {
    var rows = std.ArrayList(Row).empty;
    errdefer rows.deinit(allocator);

    var prev_total_tokens: ?i64 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        try appendParsedLine(allocator, &rows, path, options, &prev_total_tokens, line);
    }
    return rows;
}

pub fn parseTokenEventsReader(
    allocator: std.mem.Allocator,
    path: []const u8,
    dedupe: bool,
    reader: anytype,
) !std.ArrayList(Row) {
    return parseTokenEventsReaderWithOptions(allocator, path, .{
        .dedupe = dedupe,
        .derive_timestamp_fields = true,
    }, reader);
}

pub fn parseTokenEventsReaderWithOptions(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ParseOptions,
    reader: anytype,
) !std.ArrayList(Row) {
    var rows = std.ArrayList(Row).empty;
    errdefer rows.deinit(allocator);

    var prev_total_tokens: ?i64 = null;
    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    var in = reader;
    var chunk: [stream_chunk_size]u8 = undefined;
    while (true) {
        const read_len = try in.read(chunk[0..]);
        if (read_len == 0) break;

        try carry.appendSlice(allocator, chunk[0..read_len]);
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, carry.items, start, '\n')) |newline_idx| {
            try appendParsedLine(allocator, &rows, path, options, &prev_total_tokens, carry.items[start..newline_idx]);
            start = newline_idx + 1;
        }

        if (start > 0) {
            const remaining = carry.items.len - start;
            @memmove(carry.items[0..remaining], carry.items[start..]);
            carry.items.len = remaining;
        }
        if (carry.items.len > max_line_bytes) return error.LineTooLong;
    }

    if (carry.items.len > 0) {
        try appendParsedLine(allocator, &rows, path, options, &prev_total_tokens, carry.items);
    }
    return rows;
}

pub fn parseTokenEventsFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    dedupe: bool,
) !std.ArrayList(Row) {
    return parseTokenEventsFileWithOptions(allocator, path, .{
        .dedupe = dedupe,
        .derive_timestamp_fields = true,
    });
}

pub fn parseTokenEventsFileWithOptions(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ParseOptions,
) !std.ArrayList(Row) {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return parseTokenEventsReaderWithOptions(allocator, path, options, file);
}

fn appendParsedLine(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    path: []const u8,
    options: ParseOptions,
    prev_total_tokens: *?i64,
    line: []const u8,
) !void {
    const maybe_row = try parseTokenCountLineWithOptions(line, path, options.derive_timestamp_fields);
    const row = maybe_row orelse return;

    if (options.dedupe and
        prev_total_tokens.* != null and
        row.total_total_tokens != null and
        prev_total_tokens.*.? == row.total_total_tokens.?)
    {
        return;
    }

    if (row.total_total_tokens) |v| prev_total_tokens.* = v;
    try rows.append(allocator, row);
}

pub fn parseTokenCountLine(line: []const u8, path: []const u8) !?Row {
    return parseTokenCountLineWithOptions(line, path, true);
}

fn parseTokenCountLineWithOptions(
    line: []const u8,
    path: []const u8,
    derive_timestamp_fields: bool,
) !?Row {
    const trimmed = trimLine(line);
    if (trimmed.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "event_msg")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "token_count")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "payload")) return null;
    if (trimmed[0] != '{') return null;

    var root_storage: [max_root_field_entries]FieldEntry = undefined;
    const root_fields = indexObjectFields(trimmed, root_storage[0..]) orelse return null;

    const root_type = lookupIndexedField(root_fields, "type") orelse return null;
    if (!valueEqString(root_type, "event_msg")) return null;

    const payload_value = lookupIndexedField(root_fields, "payload") orelse return null;
    const payload = jsonObjectSlice(payload_value) orelse return null;

    var payload_storage: [max_payload_field_entries]FieldEntry = undefined;
    const payload_fields = indexObjectFields(payload, payload_storage[0..]) orelse return null;

    const payload_type = lookupIndexedField(payload_fields, "type") orelse return null;
    if (!valueEqString(payload_type, "token_count")) return null;

    const info_value = lookupIndexedField(payload_fields, "info") orelse return null;
    const info = jsonObjectSlice(info_value) orelse return null;

    var info_storage: [max_info_field_entries]FieldEntry = undefined;
    const info_fields = indexObjectFields(info, info_storage[0..]) orelse return null;

    var row = Row{ .path = path };

    if (derive_timestamp_fields) {
        if (lookupIndexedField(root_fields, "timestamp")) |timestamp_json| {
            if (jsonStringSlice(timestamp_json)) |ts_raw| {
                var ts_buf: [64]u8 = undefined;
                const ts = jsonDecodeStringInto(ts_raw, ts_buf[0..]) catch |err| switch (err) {
                    error.InvalidEscape => return null,
                    error.TextTooLong => return error.TextTooLong,
                };
                row.timestamp = try SmallText.fromSlice(ts);
                if (ts.len >= 10) row.day = try SmallText.fromSlice(ts[0..10]);
                if (ts.len >= 7) row.month = try SmallText.fromSlice(ts[0..7]);
            }
        }
    }

    if (lookupIndexedField(info_fields, "model_context_window")) |model_context_window_value| {
        row.model_context_window = jsonInt(model_context_window_value);
    }

    const total_usage = parseUsageObjectFixed(lookupIndexedField(info_fields, "total_token_usage"));
    row.total_input_tokens = total_usage[input_idx];
    row.total_cached_input_tokens = total_usage[cached_input_idx];
    row.total_output_tokens = total_usage[output_idx];
    row.total_reasoning_output_tokens = total_usage[reasoning_output_idx];
    row.total_total_tokens = total_usage[total_idx];

    const last_usage = parseUsageObjectFixed(lookupIndexedField(info_fields, "last_token_usage"));
    row.last_input_tokens = last_usage[input_idx];
    row.last_cached_input_tokens = last_usage[cached_input_idx];
    row.last_output_tokens = last_usage[output_idx];
    row.last_reasoning_output_tokens = last_usage[reasoning_output_idx];
    row.last_total_tokens = last_usage[total_idx];

    return row;
}

pub fn totalsTuple(row: Row) [token_key_count]?i64 {
    return .{
        row.total_input_tokens,
        row.total_cached_input_tokens,
        row.total_output_tokens,
        row.total_reasoning_output_tokens,
        row.total_total_tokens,
    };
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

fn skipWs(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    return i;
}

fn scanStringEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '"') return null;
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"') return i + 1;
        if (text[i] == '\\') {
            i += 1;
            if (i >= text.len) return null;
        }
    }
    return null;
}

fn scanCompositeEnd(text: []const u8, start: usize, open: u8, close: u8) ?usize {
    if (start >= text.len or text[start] != open) return null;
    var i = start;
    var depth: usize = 0;
    var in_string = false;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (ch == '\\') {
                i += 1;
                if (i >= text.len) return null;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }

        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch == open) {
            depth += 1;
            continue;
        }
        if (ch == close) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn scanPrimitiveEnd(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ',', '}', ']', ' ', '\t', '\r', '\n' => break,
            else => {},
        }
    }
    if (i == start) return null;
    return i;
}

fn scanValueEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    return switch (text[start]) {
        '"' => scanStringEnd(text, start),
        '{' => scanCompositeEnd(text, start, '{', '}'),
        '[' => scanCompositeEnd(text, start, '[', ']'),
        else => scanPrimitiveEnd(text, start),
    };
}

fn indexObjectFields(object_text: []const u8, storage: []FieldEntry) ?[]const FieldEntry {
    const trimmed = trimLine(object_text);
    if (trimmed.len < 2 or trimmed[0] != '{') return null;

    var count: usize = 0;
    var i: usize = 1;
    while (true) {
        i = skipWs(trimmed, i);
        if (i >= trimmed.len) return null;
        if (trimmed[i] == '}') return storage[0..count];
        if (trimmed[i] != '"') return null;

        const key_end = scanStringEnd(trimmed, i) orelse return null;
        const key_raw = trimmed[i + 1 .. key_end - 1];

        i = skipWs(trimmed, key_end);
        if (i >= trimmed.len or trimmed[i] != ':') return null;
        i = skipWs(trimmed, i + 1);

        const value_end = scanValueEnd(trimmed, i) orelse return null;
        if (count >= storage.len) return null;
        storage[count] = .{
            .key_raw = key_raw,
            .value = trimmed[i..value_end],
        };
        count += 1;

        i = skipWs(trimmed, value_end);
        if (i >= trimmed.len) return null;
        if (trimmed[i] == ',') {
            i += 1;
            continue;
        }
        if (trimmed[i] == '}') return storage[0..count];
        return null;
    }
}

fn lookupIndexedField(fields: []const FieldEntry, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (jsonStringContentEquals(field.key_raw, key)) return field.value;
    }
    return null;
}

fn valueEqString(value_text: []const u8, expected: []const u8) bool {
    const str = jsonStringSlice(value_text) orelse return false;
    return jsonStringContentEquals(str, expected);
}

fn usageKeyIndexFromRaw(raw_key: []const u8) ?usize {
    if (std.mem.eql(u8, raw_key, "input_tokens")) return input_idx;
    if (std.mem.eql(u8, raw_key, "cached_input_tokens")) return cached_input_idx;
    if (std.mem.eql(u8, raw_key, "output_tokens")) return output_idx;
    if (std.mem.eql(u8, raw_key, "reasoning_output_tokens")) return reasoning_output_idx;
    if (std.mem.eql(u8, raw_key, "total_tokens")) return total_idx;
    return null;
}

fn parseUsageObjectFallback(object_text: []const u8) UsageTuple {
    return .{
        objectIntField(object_text, "input_tokens"),
        objectIntField(object_text, "cached_input_tokens"),
        objectIntField(object_text, "output_tokens"),
        objectIntField(object_text, "reasoning_output_tokens"),
        objectIntField(object_text, "total_tokens"),
    };
}

fn parseUsageObjectFixed(object_text: ?[]const u8) UsageTuple {
    var usage: UsageTuple = .{null} ** token_key_count;
    const usage_value = object_text orelse return usage;
    const usage_object = jsonObjectSlice(usage_value) orelse return usage;

    var storage: [max_usage_field_entries]FieldEntry = undefined;
    const usage_fields = indexObjectFields(usage_object, storage[0..]) orelse return parseUsageObjectFallback(usage_object);

    for (usage_fields) |field| {
        if (std.mem.indexOfScalar(u8, field.key_raw, '\\') != null) return parseUsageObjectFallback(usage_object);
        const key_idx = usageKeyIndexFromRaw(field.key_raw) orelse continue;
        if (usage[key_idx] != null) continue;
        usage[key_idx] = jsonInt(field.value);
    }

    return usage;
}

fn objectFieldValueSlice(object_text: []const u8, field_name: []const u8) ?[]const u8 {
    const trimmed = trimLine(object_text);
    if (trimmed.len < 2 or trimmed[0] != '{') return null;

    var i: usize = 1;
    while (true) {
        i = skipWs(trimmed, i);
        if (i >= trimmed.len or trimmed[i] == '}') return null;
        if (trimmed[i] != '"') return null;

        const key_end = scanStringEnd(trimmed, i) orelse return null;
        const key = trimmed[i + 1 .. key_end - 1];
        const key_matches = jsonStringContentEquals(key, field_name);

        i = skipWs(trimmed, key_end);
        if (i >= trimmed.len or trimmed[i] != ':') return null;
        i = skipWs(trimmed, i + 1);

        const value_end = scanValueEnd(trimmed, i) orelse return null;
        if (key_matches) return trimmed[i..value_end];

        i = skipWs(trimmed, value_end);
        if (i >= trimmed.len) return null;
        if (trimmed[i] == ',') {
            i += 1;
            continue;
        }
        if (trimmed[i] == '}') return null;
        return null;
    }
}

fn jsonStringSlice(value_text: []const u8) ?[]const u8 {
    const trimmed = trimLine(value_text);
    const end = scanStringEnd(trimmed, 0) orelse return null;
    if (end != trimmed.len) return null;
    return trimmed[1 .. end - 1];
}

fn jsonObjectSlice(value_text: []const u8) ?[]const u8 {
    const trimmed = trimLine(value_text);
    const end = scanCompositeEnd(trimmed, 0, '{', '}') orelse return null;
    if (end != trimmed.len) return null;
    return trimmed;
}

fn isStrictJsonInteger(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    if (text[0] == '-') {
        if (text.len == 1) return false;
        i = 1;
    }
    if (i >= text.len) return false;

    if (text[i] == '0') return i + 1 == text.len;
    if (!std.ascii.isDigit(text[i])) return false;
    i += 1;

    while (i < text.len) : (i += 1) {
        if (!std.ascii.isDigit(text[i])) return false;
    }
    return true;
}

fn jsonInt(value_text: []const u8) ?i64 {
    const trimmed = trimLine(value_text);
    if (!isStrictJsonInteger(trimmed)) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn hexNibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => 10 + (ch - 'a'),
        'A'...'F' => 10 + (ch - 'A'),
        else => null,
    };
}

fn parseHex4(text: []const u8, start: usize) ?u16 {
    if (start + 4 > text.len) return null;
    var value: u16 = 0;
    for (text[start .. start + 4]) |ch| {
        const nibble = hexNibble(ch) orelse return null;
        value = (value << 4) | @as(u16, nibble);
    }
    return value;
}

fn appendDecodedByte(out: []u8, out_len: *usize, byte: u8) bool {
    if (out_len.* >= out.len) return false;
    out[out_len.*] = byte;
    out_len.* += 1;
    return true;
}

fn appendDecodedCodepoint(out: []u8, out_len: *usize, codepoint: u21) bool {
    var utf8: [4]u8 = undefined;
    const encoded_len = std.unicode.utf8Encode(codepoint, utf8[0..]) catch return false;
    const len: usize = @intCast(encoded_len);
    const end = out_len.* + len;
    if (end > out.len) return false;
    @memcpy(out[out_len.*..end], utf8[0..len]);
    out_len.* = end;
    return true;
}

fn decodeEscapedCodepoint(raw: []const u8, escape_idx: *usize) ?u21 {
    if (escape_idx.* >= raw.len or raw[escape_idx.*] != 'u') return null;
    const first = parseHex4(raw, escape_idx.* + 1) orelse return null;
    escape_idx.* += 5;

    if (first >= 0xd800 and first <= 0xdbff) {
        if (escape_idx.* + 1 >= raw.len or raw[escape_idx.*] != '\\' or raw[escape_idx.* + 1] != 'u') return null;
        const second = parseHex4(raw, escape_idx.* + 2) orelse return null;
        if (second < 0xdc00 or second > 0xdfff) return null;

        const high: u32 = @as(u32, first) - 0xd800;
        const low: u32 = @as(u32, second) - 0xdc00;
        escape_idx.* += 6;
        return @intCast(0x10000 + ((high << 10) | low));
    }

    if (first >= 0xdc00 and first <= 0xdfff) return null;
    return @intCast(first);
}

fn jsonDecodeStringInto(raw: []const u8, out: []u8) error{ InvalidEscape, TextTooLong }![]const u8 {
    var i: usize = 0;
    var out_len: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            if (!appendDecodedByte(out, &out_len, raw[i])) return error.TextTooLong;
            i += 1;
            continue;
        }

        i += 1;
        if (i >= raw.len) return error.InvalidEscape;
        switch (raw[i]) {
            '"', '\\', '/' => |escaped| {
                if (!appendDecodedByte(out, &out_len, escaped)) return error.TextTooLong;
                i += 1;
            },
            'b' => {
                if (!appendDecodedByte(out, &out_len, 0x08)) return error.TextTooLong;
                i += 1;
            },
            'f' => {
                if (!appendDecodedByte(out, &out_len, 0x0c)) return error.TextTooLong;
                i += 1;
            },
            'n' => {
                if (!appendDecodedByte(out, &out_len, '\n')) return error.TextTooLong;
                i += 1;
            },
            'r' => {
                if (!appendDecodedByte(out, &out_len, '\r')) return error.TextTooLong;
                i += 1;
            },
            't' => {
                if (!appendDecodedByte(out, &out_len, '\t')) return error.TextTooLong;
                i += 1;
            },
            'u' => {
                const codepoint = decodeEscapedCodepoint(raw, &i) orelse return error.InvalidEscape;
                if (!appendDecodedCodepoint(out, &out_len, codepoint)) return error.TextTooLong;
            },
            else => return error.InvalidEscape,
        }
    }
    return out[0..out_len];
}

fn matchDecodedByte(expected: []const u8, matched: *usize, byte: u8) bool {
    if (matched.* >= expected.len) return false;
    if (expected[matched.*] != byte) return false;
    matched.* += 1;
    return true;
}

fn matchDecodedCodepoint(expected: []const u8, matched: *usize, codepoint: u21) bool {
    var utf8: [4]u8 = undefined;
    const encoded_len = std.unicode.utf8Encode(codepoint, utf8[0..]) catch return false;
    const len: usize = @intCast(encoded_len);
    const end = matched.* + len;
    if (end > expected.len) return false;
    if (!std.mem.eql(u8, expected[matched.*..end], utf8[0..len])) return false;
    matched.* = end;
    return true;
}

fn jsonStringContentEquals(raw: []const u8, expected: []const u8) bool {
    var i: usize = 0;
    var matched: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            if (!matchDecodedByte(expected, &matched, raw[i])) return false;
            i += 1;
            continue;
        }

        i += 1;
        if (i >= raw.len) return false;
        switch (raw[i]) {
            '"', '\\', '/' => |escaped| {
                if (!matchDecodedByte(expected, &matched, escaped)) return false;
                i += 1;
            },
            'b' => {
                if (!matchDecodedByte(expected, &matched, 0x08)) return false;
                i += 1;
            },
            'f' => {
                if (!matchDecodedByte(expected, &matched, 0x0c)) return false;
                i += 1;
            },
            'n' => {
                if (!matchDecodedByte(expected, &matched, '\n')) return false;
                i += 1;
            },
            'r' => {
                if (!matchDecodedByte(expected, &matched, '\r')) return false;
                i += 1;
            },
            't' => {
                if (!matchDecodedByte(expected, &matched, '\t')) return false;
                i += 1;
            },
            'u' => {
                const codepoint = decodeEscapedCodepoint(raw, &i) orelse return false;
                if (!matchDecodedCodepoint(expected, &matched, codepoint)) return false;
            },
            else => return false,
        }
    }
    return matched == expected.len;
}

fn objectIntField(object_text: []const u8, key: []const u8) ?i64 {
    const value = objectFieldValueSlice(object_text, key) orelse return null;
    return jsonInt(value);
}

fn parseTokenCountLineStdJson(line: []const u8, path: []const u8) !?Row {
    const trimmed = trimLine(line);
    if (trimmed.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "event_msg")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "token_count")) return null;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    if (!stdJsonFieldEq(root, "type", "event_msg")) return null;

    const payload = stdJsonObjectField(root, "payload") orelse return null;
    if (!stdJsonFieldEq(payload, "type", "token_count")) return null;

    const info = stdJsonObjectField(payload, "info") orelse return null;

    var row = Row{ .path = path };

    if (stdJsonStringField(root, "timestamp")) |ts| {
        row.timestamp = try SmallText.fromSlice(ts);
        if (ts.len >= 10) row.day = try SmallText.fromSlice(ts[0..10]);
        if (ts.len >= 7) row.month = try SmallText.fromSlice(ts[0..7]);
    }

    row.model_context_window = stdJsonIntField(info, "model_context_window");

    const total_usage = stdJsonObjectField(info, "total_token_usage");
    row.total_input_tokens = stdJsonIntFieldMaybe(total_usage, "input_tokens");
    row.total_cached_input_tokens = stdJsonIntFieldMaybe(total_usage, "cached_input_tokens");
    row.total_output_tokens = stdJsonIntFieldMaybe(total_usage, "output_tokens");
    row.total_reasoning_output_tokens = stdJsonIntFieldMaybe(total_usage, "reasoning_output_tokens");
    row.total_total_tokens = stdJsonIntFieldMaybe(total_usage, "total_tokens");

    const last_usage = stdJsonObjectField(info, "last_token_usage");
    row.last_input_tokens = stdJsonIntFieldMaybe(last_usage, "input_tokens");
    row.last_cached_input_tokens = stdJsonIntFieldMaybe(last_usage, "cached_input_tokens");
    row.last_output_tokens = stdJsonIntFieldMaybe(last_usage, "output_tokens");
    row.last_reasoning_output_tokens = stdJsonIntFieldMaybe(last_usage, "reasoning_output_tokens");
    row.last_total_tokens = stdJsonIntFieldMaybe(last_usage, "total_tokens");

    return row;
}

fn stdJsonFieldEq(obj: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = stdJsonStringField(obj, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn stdJsonObjectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |inner| inner,
        else => null,
    };
}

fn stdJsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn stdJsonIntField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn stdJsonIntFieldMaybe(obj: ?std.json.ObjectMap, key: []const u8) ?i64 {
    if (obj == null) return null;
    return stdJsonIntField(obj.?, key);
}

fn expectOptionalSmallTextEqual(got: ?SmallText, want: ?SmallText) !void {
    try std.testing.expectEqual(want != null, got != null);
    if (want) |expected| {
        try std.testing.expectEqualStrings(expected.slice(), got.?.slice());
    }
}

fn expectRowsEqual(got: Row, want: Row) !void {
    try std.testing.expectEqualStrings(want.path, got.path);
    try expectOptionalSmallTextEqual(got.timestamp, want.timestamp);
    try expectOptionalSmallTextEqual(got.day, want.day);
    try expectOptionalSmallTextEqual(got.week, want.week);
    try expectOptionalSmallTextEqual(got.month, want.month);
    try std.testing.expectEqual(want.model_context_window, got.model_context_window);
    try std.testing.expectEqual(want.total_input_tokens, got.total_input_tokens);
    try std.testing.expectEqual(want.total_cached_input_tokens, got.total_cached_input_tokens);
    try std.testing.expectEqual(want.total_output_tokens, got.total_output_tokens);
    try std.testing.expectEqual(want.total_reasoning_output_tokens, got.total_reasoning_output_tokens);
    try std.testing.expectEqual(want.total_total_tokens, got.total_total_tokens);
    try std.testing.expectEqual(want.last_input_tokens, got.last_input_tokens);
    try std.testing.expectEqual(want.last_cached_input_tokens, got.last_cached_input_tokens);
    try std.testing.expectEqual(want.last_output_tokens, got.last_output_tokens);
    try std.testing.expectEqual(want.last_reasoning_output_tokens, got.last_reasoning_output_tokens);
    try std.testing.expectEqual(want.last_total_tokens, got.last_total_tokens);
}

fn expectMaybeRowsEqual(got: ?Row, want: ?Row) !void {
    try std.testing.expectEqual(want != null, got != null);
    if (want) |expected| try expectRowsEqual(got.?, expected);
}

fn fuzzTokenCountParity(_: void, input: []const u8) !void {
    const path = "fuzz.jsonl";
    const got = parseTokenCountLine(input, path) catch |err| switch (err) {
        error.TextTooLong => null,
        else => return err,
    };
    const want = parseTokenCountLineStdJson(input, path) catch |err| switch (err) {
        error.TextTooLong => null,
        else => return err,
    };
    try expectMaybeRowsEqual(got, want);
}

fn parseTokenEventsWithAlloc(alloc: std.mem.Allocator, content: []const u8) !void {
    var rows = try parseTokenEvents(alloc, "alloc.jsonl", content, true);
    rows.deinit(alloc);
}

fn parseTokenEventsStdJson(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    dedupe: bool,
) !std.ArrayList(Row) {
    var rows = std.ArrayList(Row).empty;
    errdefer rows.deinit(allocator);

    var prev_total_tokens: ?i64 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const maybe_row = try parseTokenCountLineStdJson(line, path);
        const row = maybe_row orelse continue;
        if (dedupe and
            prev_total_tokens != null and
            row.total_total_tokens != null and
            prev_total_tokens.? == row.total_total_tokens.?)
        {
            continue;
        }
        if (row.total_total_tokens) |v| prev_total_tokens = v;
        try rows.append(allocator, row);
    }
    return rows;
}

test "parseTokenCountLine parity with std.json reference" {
    const line =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"model_context_window":9999,"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":13},"last_token_usage":{"input_tokens":2,"cached_input_tokens":1,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":3}}}}
    ;
    const got = try parseTokenCountLine(line, "session.jsonl");
    const want = try parseTokenCountLineStdJson(line, "session.jsonl");
    try expectMaybeRowsEqual(got, want);
}

test "parseTokenCountLine parity with escaped keys and values" {
    const line =
        \\{"\u0074ype":"event_\u006dsg","timestamp":"2026-02-19T10:10:00Z","pay\u006coad":{"\u0074ype":"token_\u0063ount","\u0069nfo":{"model_context_window":9999,"total_token_us\u0061ge":{"\u0069nput_tokens":10,"cached_input_tokens":5,"output_tokens":3,"reasoning_output_tokens":1,"tot\u0061l_tokens":13},"last_token_usage":{"input_tokens":2,"cached_input_tokens":1,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":3}}}}
    ;
    const got = try parseTokenCountLine(line, "session.jsonl");
    const want = try parseTokenCountLineStdJson(line, "session.jsonl");
    try expectMaybeRowsEqual(got, want);
}

test "jsonDecodeStringInto handles escapes and surrogate pairs" {
    var out: [64]u8 = undefined;
    const decoded = try jsonDecodeStringInto("event_\\u006dsg\\n\\t\\uD83D\\uDE80", out[0..]);
    try std.testing.expectEqualStrings("event_msg\n\t\xF0\x9F\x9A\x80", decoded);
}

test "jsonDecodeStringInto rejects malformed escapes" {
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidEscape, jsonDecodeStringInto("\\u12G4", out[0..]));
    try std.testing.expectError(error.InvalidEscape, jsonDecodeStringInto("\\uDE80", out[0..]));
    try std.testing.expectError(error.InvalidEscape, jsonDecodeStringInto("\\uD83Dx", out[0..]));
    try std.testing.expectError(error.InvalidEscape, jsonDecodeStringInto("abc\\", out[0..]));
}

test "parseTokenCountLine parity with escaped timestamp" {
    const line =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00\u005a","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":13}}}}
    ;
    const got = try parseTokenCountLine(line, "session.jsonl");
    const want = try parseTokenCountLineStdJson(line, "session.jsonl");
    try expectMaybeRowsEqual(got, want);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("2026-02-19T10:10:00Z", got.?.timestamp.?.slice());
}

test "parseTokenCountLine parity with escaped non-required strings" {
    const line =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"note":"q\\\" b\\\\ s\\/ snowman:\\u2603","total_token_usage":{"total_tokens":13}}}}
    ;
    const got = try parseTokenCountLine(line, "session.jsonl");
    const want = try parseTokenCountLineStdJson(line, "session.jsonl");
    try expectMaybeRowsEqual(got, want);
}

test "parseTokenCountLine usage parser keeps first duplicate key" {
    const line =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":13,"total_tokens":99}}}}
    ;
    const got = try parseTokenCountLine(line, "session.jsonl");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(?i64, 13), got.?.total_total_tokens);
}

test "parseTokenCountLine usage parser fallback handles escaped usage keys" {
    const line =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"\u0074otal_tokens":13}}}}
    ;
    const got = try parseTokenCountLine(line, "session.jsonl");
    const want = try parseTokenCountLineStdJson(line, "session.jsonl");
    try expectMaybeRowsEqual(got, want);
}

test "parseTokenCountLine ignores info null to match reference behavior" {
    const line =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":null}}
    ;
    const got = try parseTokenCountLine(line, "session.jsonl");
    const want = try parseTokenCountLineStdJson(line, "session.jsonl");
    try expectMaybeRowsEqual(got, want);
}

test "parseTokenCountLine parity when total_token_usage is absent" {
    const line =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"model_context_window":1234,"last_token_usage":{"total_tokens":3}}}}
    ;
    const got = try parseTokenCountLine(line, "session.jsonl");
    const want = try parseTokenCountLineStdJson(line, "session.jsonl");
    try expectMaybeRowsEqual(got, want);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(?i64, null), got.?.total_total_tokens);
    try std.testing.expectEqual(@as(?i64, 3), got.?.last_total_tokens);
}

test "parseTokenCountLine parity on malformed truncated input" {
    const line = "{\"type\":\"event_msg\",\"payload\":";
    const got = try parseTokenCountLine(line, "session.jsonl");
    const want = try parseTokenCountLineStdJson(line, "session.jsonl");
    try expectMaybeRowsEqual(got, want);
}

test "parseTokenEventsReader keeps dedupe/reset semantics" {
    const content =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}
        \\{"type":"event_msg","timestamp":"2026-02-19T10:11:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}
        \\{"type":"event_msg","timestamp":"2026-02-19T10:12:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5}}}}
    ;

    var fbs = std.io.fixedBufferStream(content);
    var streamed = try parseTokenEventsReader(std.testing.allocator, "stream.jsonl", true, fbs.reader());
    defer streamed.deinit(std.testing.allocator);

    var from_slice = try parseTokenEvents(std.testing.allocator, "stream.jsonl", content, true);
    defer from_slice.deinit(std.testing.allocator);

    try std.testing.expectEqual(from_slice.items.len, streamed.items.len);
    for (from_slice.items, 0..) |expected, idx| {
        try expectRowsEqual(streamed.items[idx], expected);
    }
}

test "parseTokenEventsWithOptions can skip timestamp derivation" {
    const content =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}
    ;
    var rows = try parseTokenEventsWithOptions(std.testing.allocator, "stream.jsonl", content, .{
        .dedupe = true,
        .derive_timestamp_fields = false,
    });
    defer rows.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(?i64, 10), rows.items[0].total_total_tokens);
    try std.testing.expect(rows.items[0].timestamp == null);
    try std.testing.expect(rows.items[0].day == null);
    try std.testing.expect(rows.items[0].month == null);
}

test "parseTokenEvents parity with std.json reference on golden sample" {
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, "testdata/golden/sessions/sample.jsonl", 256 * 1024);
    defer std.testing.allocator.free(content);

    var got = try parseTokenEvents(std.testing.allocator, "sample.jsonl", content, true);
    defer got.deinit(std.testing.allocator);
    var want = try parseTokenEventsStdJson(std.testing.allocator, "sample.jsonl", content, true);
    defer want.deinit(std.testing.allocator);

    try std.testing.expectEqual(want.items.len, got.items.len);
    for (want.items, 0..) |expected, idx| {
        try expectRowsEqual(got.items[idx], expected);
    }
}

test "allocation failures in parseTokenEvents are surfaced" {
    const content =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}
    ;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseTokenEventsWithAlloc, .{content});
}

test "fuzz parseTokenCountLine parity with std.json reference" {
    try std.testing.fuzz({}, fuzzTokenCountParity, .{});
}
