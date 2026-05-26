const std = @import("std");
const datasets = @import("datasets/mod.zig");
const stats_mod = @import("stats.zig");

pub const Demand = struct {
    messages: bool = false,
    skill_mentions: bool = false,
    token_events: bool = false,
    tool_invocations: bool = false,
    canonical_trace: bool = false,
    goal_runs: bool = false,
};

pub const Result = struct {
    path: []const u8,
    content: ?[]const u8 = null,

    messages: []datasets.messages.MessageRow = &.{},
    skill_mentions: []datasets.skill_mentions.SkillMentionRow = &.{},

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.messages.len > 0) datasets.messages.freeRows(allocator, self.messages);
        if (self.skill_mentions.len > 0) datasets.skill_mentions.freeRows(allocator, self.skill_mentions);
        if (self.content) |content| allocator.free(content);
        self.* = .{ .path = self.path };
    }
};

pub fn scanFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    demand: Demand,
    stats: ?*stats_mod.SeqStats,
) !?Result {
    if (!demand.messages and !demand.skill_mentions) return null;

    const content = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        allocator,
        .limited(256 * 1024 * 1024),
    ) catch return null;
    errdefer allocator.free(content);

    if (stats) |s| {
        s.files_opened += 1;
        s.bytes_read += @intCast(content.len);
        const line_count = countLines(content);
        s.lines_seen += line_count;
        s.json_parse_attempts += line_count;
    }

    var result = Result{
        .path = path,
        .content = content,
    };
    errdefer result.deinit(allocator);

    if (demand.messages) {
        result.messages = try datasets.messages.parseJsonl(allocator, path, content, .{});
        if (stats) |s| s.json_parse_successes += @intCast(result.messages.len);
    }
    if (demand.skill_mentions) {
        result.skill_mentions = try datasets.skill_mentions.parseJsonl(allocator, path, content, .{});
        if (stats) |s| s.json_parse_successes += @intCast(result.skill_mentions.len);
    }

    return result;
}

fn countLines(content: []const u8) i64 {
    if (content.len == 0) return 0;
    var lines: i64 = 0;
    for (content) |byte| {
        if (byte == '\n') lines += 1;
    }
    if (content[content.len - 1] != '\n') lines += 1;
    return lines;
}
