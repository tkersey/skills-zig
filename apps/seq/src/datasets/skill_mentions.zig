const std = @import("std");
const messages = @import("messages.zig");

pub const SkillMentionRow = struct {
    path: []const u8,
    timestamp: ?[]const u8,
    day: ?[]const u8,
    week: ?[]const u8,
    month: ?[]const u8,
    role: []const u8,
    skill: []const u8,
    types: []const u8,
    snippet: []const u8,

    pub fn deinit(self: SkillMentionRow, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.timestamp) |v| allocator.free(v);
        if (self.day) |v| allocator.free(v);
        if (self.week) |v| allocator.free(v);
        if (self.month) |v| allocator.free(v);
        allocator.free(self.role);
        allocator.free(self.skill);
        allocator.free(self.types);
        allocator.free(self.snippet);
    }
};

pub const ParseOptions = struct {
    include_blocks: bool = true,
    include_dollars: bool = true,
    skip_dollar_in_skill_block: bool = true,
    dedupe_adjacent: bool = true,
    snippet_limit: usize = 240,
    include_user: bool = true,
    include_assistant: bool = true,
};

const TYPE_BLOCK: u8 = 1;
const TYPE_DOLLAR: u8 = 2;

fn freeTypeMapKeys(map: *std.StringHashMap(u8), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
}

fn addSkillType(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(u8),
    skill: []const u8,
    type_bit: u8,
) !void {
    if (skill.len == 0) return;
    if (map.getPtr(skill)) |existing| {
        existing.* |= type_bit;
        return;
    }
    const key = try allocator.dupe(u8, skill);
    errdefer allocator.free(key);
    try map.put(key, type_bit);
}

fn collectBlockSkills(
    allocator: std.mem.Allocator,
    text: []const u8,
    map: *std.StringHashMap(u8),
) !bool {
    var had_name = false;
    var pos: usize = 0;

    while (std.mem.indexOfPos(u8, text, pos, "<skill>")) |skill_start| {
        const block_start = skill_start + "<skill>".len;
        const block_end = std.mem.indexOfPos(u8, text, block_start, "</skill>") orelse break;
        const block = text[block_start..block_end];

        var block_pos: usize = 0;
        while (std.mem.indexOfPos(u8, block, block_pos, "<name>")) |name_start| {
            const value_start = name_start + "<name>".len;
            const name_end = std.mem.indexOfPos(u8, block, value_start, "</name>") orelse break;
            const raw_name = std.mem.trim(u8, block[value_start..name_end], " \t\r\n");
            if (raw_name.len > 0) {
                had_name = true;
                try addSkillType(allocator, map, raw_name, TYPE_BLOCK);
            }
            block_pos = name_end + "</name>".len;
        }

        pos = block_end + "</skill>".len;
    }

    return had_name;
}

fn isSkillStartChar(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isSkillChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
}

fn collectDollarSkills(
    allocator: std.mem.Allocator,
    text: []const u8,
    map: *std.StringHashMap(u8),
) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '$') continue;
        if (i + 1 >= text.len) continue;
        if (!isSkillStartChar(text[i + 1])) continue;

        var j = i + 2;
        while (j < text.len and isSkillChar(text[j])) : (j += 1) {}
        try addSkillType(allocator, map, text[i + 1 .. j], TYPE_DOLLAR);
        i = j - 1;
    }
}

fn typeString(allocator: std.mem.Allocator, bits: u8) ![]const u8 {
    if (bits == TYPE_BLOCK) return allocator.dupe(u8, "block");
    if (bits == TYPE_DOLLAR) return allocator.dupe(u8, "dollar");
    return allocator.dupe(u8, "block+dollar");
}

fn snippetFromText(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]const u8 {
    if (limit == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len and out.items.len < limit) : (i += 1) {
        const c = text[i];
        if (c == '\n' or c == '\r') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, c);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn dupOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn buildRow(
    allocator: std.mem.Allocator,
    msg: messages.MessageRow,
    skill: []const u8,
    bits: u8,
    snippet_limit: usize,
) !SkillMentionRow {
    const path = try allocator.dupe(u8, msg.path);
    errdefer allocator.free(path);
    const timestamp = try dupOptional(allocator, msg.timestamp);
    errdefer if (timestamp) |v| allocator.free(v);
    const day = try dupOptional(allocator, msg.day);
    errdefer if (day) |v| allocator.free(v);
    const week = try dupOptional(allocator, msg.week);
    errdefer if (week) |v| allocator.free(v);
    const month = try dupOptional(allocator, msg.month);
    errdefer if (month) |v| allocator.free(v);
    const role = try allocator.dupe(u8, msg.role);
    errdefer allocator.free(role);
    const skill_copy = try allocator.dupe(u8, skill);
    errdefer allocator.free(skill_copy);
    const types = try typeString(allocator, bits);
    errdefer allocator.free(types);
    const snippet = try snippetFromText(allocator, msg.text, snippet_limit);
    errdefer allocator.free(snippet);

    return .{
        .path = path,
        .timestamp = timestamp,
        .day = day,
        .week = week,
        .month = month,
        .role = role,
        .skill = skill_copy,
        .types = types,
        .snippet = snippet,
    };
}

fn replaceTypeMap(
    allocator: std.mem.Allocator,
    dst: *std.StringHashMap(u8),
    src: *const std.StringHashMap(u8),
) !void {
    freeTypeMapKeys(dst, allocator);
    dst.clearRetainingCapacity();

    var it = src.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        try dst.put(key, entry.value_ptr.*);
    }
}

pub fn parseJsonl(
    allocator: std.mem.Allocator,
    path: []const u8,
    jsonl: []const u8,
    options: ParseOptions,
) ![]SkillMentionRow {
    const msg_options = messages.ParseOptions{
        .include_user = options.include_user,
        .include_assistant = options.include_assistant,
        .strip_echo_assistant = true,
        .skip_meta_user_messages = true,
        .dedupe_by_role_and_text = true,
    };

    const parsed_messages = try messages.parseJsonl(allocator, path, jsonl, msg_options);
    defer messages.freeRows(allocator, parsed_messages);

    return parseMessages(allocator, parsed_messages, options);
}

pub fn parseJsonlReader(
    allocator: std.mem.Allocator,
    path: []const u8,
    reader: *std.Io.Reader,
    options: ParseOptions,
    metrics: ?*messages.ParseMetrics,
) ![]SkillMentionRow {
    const msg_options = messages.ParseOptions{
        .include_user = options.include_user,
        .include_assistant = options.include_assistant,
        .strip_echo_assistant = true,
        .skip_meta_user_messages = true,
        .dedupe_by_role_and_text = true,
    };

    const parsed_messages = try messages.parseJsonlReader(allocator, path, reader, msg_options, metrics);
    defer messages.freeRows(allocator, parsed_messages);

    return parseMessages(allocator, parsed_messages, options);
}

pub fn parseMessages(
    allocator: std.mem.Allocator,
    parsed_messages: []const messages.MessageRow,
    options: ParseOptions,
) ![]SkillMentionRow {
    var rows: std.ArrayList(SkillMentionRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    var prev_types: std.StringHashMap(u8) = .init(allocator);
    defer {
        freeTypeMapKeys(&prev_types, allocator);
        prev_types.deinit();
    }

    for (parsed_messages) |msg| {
        var current_types: std.StringHashMap(u8) = .init(allocator);
        defer {
            freeTypeMapKeys(&current_types, allocator);
            current_types.deinit();
        }

        const has_block = if (options.include_blocks)
            try collectBlockSkills(allocator, msg.text, &current_types)
        else
            false;

        if (options.include_dollars and !(options.skip_dollar_in_skill_block and has_block)) {
            try collectDollarSkills(allocator, msg.text, &current_types);
        }

        var it = current_types.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const bits = entry.value_ptr.*;
            if (options.dedupe_adjacent) {
                if (prev_types.get(name)) |prev_bits| {
                    if ((prev_bits & TYPE_BLOCK) != 0 and bits == TYPE_DOLLAR) continue;
                    if ((prev_bits & TYPE_DOLLAR) != 0 and bits == TYPE_BLOCK) continue;
                }
            }

            const row = try buildRow(allocator, msg, name, bits, options.snippet_limit);
            try rows.append(allocator, row);
        }

        try replaceTypeMap(allocator, &prev_types, &current_types);
    }

    return rows.toOwnedSlice(allocator);
}

pub fn freeRows(allocator: std.mem.Allocator, rows: []SkillMentionRow) void {
    for (rows) |row| row.deinit(allocator);
    allocator.free(rows);
}

test "parse skill mentions with default adjacent dedupe" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:11:12Z","payload":{"type":"agent_message","message":"Run $tk now"}}
        \\{"type":"event_msg","timestamp":"2026-02-19T10:12:12Z","payload":{"type":"agent_message","message":"<skill><name>tk</name></skill>"}}
    ;

    const rows = try parseJsonl(allocator, "/tmp/s2.jsonl", jsonl, .{});
    defer freeRows(allocator, rows);

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("assistant", rows[0].role);
    try std.testing.expectEqualStrings("tk", rows[0].skill);
    try std.testing.expectEqualStrings("dollar", rows[0].types);
}
