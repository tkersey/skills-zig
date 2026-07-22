const std = @import("std");
const messages = @import("messages.zig");

pub const SkillBlockRow = struct {
    path: []const u8,
    timestamp: ?[]const u8,
    day: ?[]const u8,
    week: ?[]const u8,
    month: ?[]const u8,
    role: []const u8,
    skill: []const u8,
    skill_path: ?[]const u8,
    block_hash: []const u8,
    block_text: []const u8,

    pub fn deinit(self: SkillBlockRow, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.timestamp) |v| allocator.free(v);
        if (self.day) |v| allocator.free(v);
        if (self.week) |v| allocator.free(v);
        if (self.month) |v| allocator.free(v);
        allocator.free(self.role);
        allocator.free(self.skill);
        if (self.skill_path) |v| allocator.free(v);
        allocator.free(self.block_hash);
        allocator.free(self.block_text);
    }
};

pub const ParseOptions = struct {
    include_user: bool = true,
    include_assistant: bool = true,
};

fn dupOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn blockTagValue(block: []const u8, tag_name: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(open_buf[0..], "<{s}>", .{tag_name}) catch return null;
    const close = std.fmt.bufPrint(close_buf[0..], "</{s}>", .{tag_name}) catch return null;

    const start = std.mem.indexOf(u8, block, open) orelse return null;
    const value_start = start + open.len;
    const end = std.mem.indexOfPos(u8, block, value_start, close) orelse return null;
    const trimmed = std.mem.trim(u8, block[value_start..end], " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn extractSkillName(block: []const u8) ?[]const u8 {
    var pos: usize = 0;
    var unique_name: ?[]const u8 = null;

    while (std.mem.indexOfPos(u8, block, pos, "<name>")) |name_start| {
        const value_start = name_start + "<name>".len;
        const name_end = std.mem.indexOfPos(u8, block, value_start, "</name>") orelse return null;
        const raw_name = std.mem.trim(u8, block[value_start..name_end], " \t\r\n");
        pos = name_end + "</name>".len;
        if (raw_name.len == 0) continue;

        if (unique_name == null) {
            unique_name = raw_name;
            continue;
        }
        if (!std.mem.eql(u8, unique_name.?, raw_name)) return null;
    }

    return unique_name;
}

fn hashBlockHex(allocator: std.mem.Allocator, block_text: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(block_text, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn buildRow(
    allocator: std.mem.Allocator,
    msg: messages.MessageRow,
    skill_name: []const u8,
    skill_path: ?[]const u8,
    block_text: []const u8,
) !SkillBlockRow {
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
    const skill = try allocator.dupe(u8, skill_name);
    errdefer allocator.free(skill);
    const skill_path_copy = try dupOptional(allocator, skill_path);
    errdefer if (skill_path_copy) |v| allocator.free(v);
    const block_text_copy = try allocator.dupe(u8, block_text);
    errdefer allocator.free(block_text_copy);
    const block_hash = try hashBlockHex(allocator, block_text_copy);
    errdefer allocator.free(block_hash);

    return .{
        .path = path,
        .timestamp = timestamp,
        .day = day,
        .week = week,
        .month = month,
        .role = role,
        .skill = skill,
        .skill_path = skill_path_copy,
        .block_hash = block_hash,
        .block_text = block_text_copy,
    };
}

pub fn parseJsonl(
    allocator: std.mem.Allocator,
    path: []const u8,
    jsonl: []const u8,
    options: ParseOptions,
) ![]SkillBlockRow {
    const msg_options = messages.ParseOptions{
        .include_user = options.include_user,
        .include_assistant = options.include_assistant,
        .strip_echo_assistant = true,
        .skip_meta_user_messages = true,
        .dedupe_by_role_and_text = false,
        .strip_skill_blocks = false,
    };
    const parsed_messages = try messages.parseJsonl(allocator, path, jsonl, msg_options);
    defer messages.freeRows(allocator, parsed_messages);

    return parseMessages(allocator, parsed_messages);
}

pub fn parseMessages(
    allocator: std.mem.Allocator,
    parsed_messages: []const messages.MessageRow,
) ![]SkillBlockRow {
    var rows: std.ArrayList(SkillBlockRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    for (parsed_messages) |msg| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, msg.text, pos, "<skill>")) |skill_start| {
            const close_start = std.mem.indexOfPos(u8, msg.text, skill_start + "<skill>".len, "</skill>") orelse break;
            const block_end = close_start + "</skill>".len;
            const block_text = msg.text[skill_start..block_end];
            const block_inner = msg.text[skill_start + "<skill>".len .. close_start];

            const skill_name = extractSkillName(block_inner) orelse {
                pos = block_end;
                continue;
            };
            const skill_path = blockTagValue(block_inner, "path");
            const row = try buildRow(allocator, msg, skill_name, skill_path, block_text);
            try rows.append(allocator, row);
            pos = block_end;
        }
    }

    return rows.toOwnedSlice(allocator);
}

pub fn freeRows(allocator: std.mem.Allocator, rows: []SkillBlockRow) void {
    for (rows) |row| row.deinit(allocator);
    allocator.free(rows);
}

test "parse skill blocks preserves exact envelope and extracts path" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","timestamp":"2026-03-10T10:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Before\n<skill>\n<name>accretive</name>\n<path>/tmp/accretive/SKILL.md</path>\n---\nname: accretive\n---\n# Accretive\n</skill>\nAfter"}]}}
    ;

    const rows = try parseJsonl(allocator, "/tmp/session.jsonl", jsonl, .{});
    defer freeRows(allocator, rows);

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("accretive", rows[0].skill);
    try std.testing.expectEqualStrings("/tmp/accretive/SKILL.md", rows[0].skill_path.?);
    try std.testing.expect(std.mem.indexOf(u8, rows[0].block_text, "<skill>\n<name>accretive</name>") != null);
    try std.testing.expect(std.mem.endsWith(u8, rows[0].block_text, "</skill>"));
    try std.testing.expectEqual(@as(usize, 64), rows[0].block_hash.len);
}

test "parse skill blocks skips conflicting name tags" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","timestamp":"2026-03-10T10:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<skill>\n<name>one</name>\n<name>two</name>\n</skill>"}]}}
    ;

    const rows = try parseJsonl(allocator, "/tmp/session.jsonl", jsonl, .{});
    defer freeRows(allocator, rows);

    try std.testing.expectEqual(@as(usize, 0), rows.len);
}
