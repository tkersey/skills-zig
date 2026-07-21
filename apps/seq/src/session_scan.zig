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

    messages: []datasets.messages.MessageRow = &.{},
    skill_mentions: []datasets.skill_mentions.SkillMentionRow = &.{},

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.messages.len > 0) datasets.messages.freeRows(allocator, self.messages);
        if (self.skill_mentions.len > 0) datasets.skill_mentions.freeRows(allocator, self.skill_mentions);
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

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{})) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer file.close(io);

    var result = Result{ .path = path };
    errdefer result.deinit(allocator);

    var metrics = datasets.messages.ParseMetrics{};
    var reader = file.reader(io, &.{});
    if (demand.messages) {
        result.messages = try datasets.messages.parseJsonlReader(allocator, path, &reader.interface, .{}, &metrics);
        if (stats) |s| s.json_parse_successes += @intCast(result.messages.len);
        if (demand.skill_mentions) {
            result.skill_mentions = try datasets.skill_mentions.parseMessages(allocator, result.messages, .{});
        }
    } else if (demand.skill_mentions) {
        result.skill_mentions = try datasets.skill_mentions.parseJsonlReader(allocator, path, &reader.interface, .{}, &metrics);
    }
    if (demand.skill_mentions) {
        if (stats) |s| s.json_parse_successes += @intCast(result.skill_mentions.len);
    }

    if (stats) |s| {
        s.files_opened += 1;
        s.bytes_read += @intCast(metrics.bytes_read);
        s.lines_seen += @intCast(metrics.lines_seen);
        s.json_parse_attempts += @intCast(metrics.lines_seen);
    }

    return result;
}
