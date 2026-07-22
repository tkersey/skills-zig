const std = @import("std");
const datasets = @import("datasets/mod.zig");
const retrace_core = @import("retrace_core");
const stats_mod = @import("stats.zig");
const canonical_trace = retrace_core.canonical_trace;

pub const Demand = struct {
    messages: bool = false,
    skill_mentions: bool = false,
    token_events: bool = false,
    tool_invocations: bool = false,
    canonical_trace: bool = false,
    goal_runs: bool = false,
};

pub const StreamMetrics = struct {
    bytes_read: usize = 0,
    lines_seen: usize = 0,
};

/// Visit one JSONL record at a time. Record bytes are valid only for the
/// duration of the visitor call. Aggregate file size is deliberately not a
/// limit; the shared JSONL stream retains only the current record.
pub fn forEachLine(
    allocator: std.mem.Allocator,
    path: []const u8,
    context: anytype,
    comptime visit: anytype,
) !?StreamMetrics {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{})) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer file.close(io);

    var reader = file.reader(io, &.{});
    return try forEachReader(allocator, &reader.interface, context, visit);
}

pub fn forEachLineFromOffset(
    allocator: std.mem.Allocator,
    path: []const u8,
    offset: u64,
    context: anytype,
    comptime visit: anytype,
) !?StreamMetrics {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{})) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer file.close(io);

    return forEachLineFromFileOffset(allocator, &file, offset, context, visit);
}

/// Stream from one already-open descriptor so callers can bind stat, seek,
/// and read to the same file identity across path replacement.
pub fn forEachLineFromFileOffset(
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    offset: u64,
    context: anytype,
    comptime visit: anytype,
) !StreamMetrics {
    const io = std.Io.Threaded.global_single_threaded.io();
    var reader = file.reader(io, &.{});
    try reader.seekTo(offset);
    return try forEachReader(allocator, &reader.interface, context, visit);
}

fn forEachReader(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    context: anytype,
    comptime visit: anytype,
) !StreamMetrics {
    var stream = try retrace_core.jsonl_stream.Stream.init(allocator, reader, .{});
    defer stream.deinit();

    while (try stream.next()) |record| {
        try visit(context, record.bytes, record.number);
    }
    return .{ .bytes_read = stream.bytes_read, .lines_seen = stream.line_number };
}

/// Visit normalized unique messages without retaining their payloads. The
/// SHA-256 identity set preserves role+text dedupe with fixed-size semantic
/// keys; only command-owned evidence survives the visitor call.
pub fn forEachMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: datasets.messages.ParseOptions,
    context: anytype,
    comptime visit: anytype,
) !?StreamMetrics {
    const MessageOnlyContext = struct {
        visitor_context: @TypeOf(context),

        fn accept(self: *@This(), _: []const u8, _: usize, row: ?datasets.messages.MessageRow) !void {
            if (row) |message| try visit(self.visitor_context, message);
        }
    };
    var message_context = MessageOnlyContext{ .visitor_context = context };
    return forEachRecordAndMessage(allocator, path, options, &message_context, MessageOnlyContext.accept);
}

/// Visit every raw record and, when present, its normalized message view in a
/// single pass. Commands may inspect raw protocol records and fold semantic
/// messages without reopening the session.
pub fn forEachRecordAndMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: datasets.messages.ParseOptions,
    context: anytype,
    comptime visit: anytype,
) !?StreamMetrics {
    var seen = std.AutoHashMap([std.crypto.hash.sha2.Sha256.digest_length]u8, void).init(allocator);
    defer seen.deinit();

    const MessageContext = struct {
        allocator: std.mem.Allocator,
        path: []const u8,
        options: datasets.messages.ParseOptions,
        seen: *@TypeOf(seen),
        visitor_context: @TypeOf(context),

        fn accept(self: *@This(), line: []const u8, line_number: usize) !void {
            const maybe_row = try datasets.messages.parseJsonlLine(self.allocator, self.path, line, self.options);
            if (maybe_row == null) return visit(self.visitor_context, line, line_number, null);
            const row = maybe_row.?;
            defer row.deinit(self.allocator);

            if (self.options.dedupe_by_role_and_text) {
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(row.role);
                hasher.update("\x1f");
                hasher.update(row.text);
                var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                hasher.final(&digest);
                const entry = try self.seen.getOrPut(digest);
                if (entry.found_existing) return visit(self.visitor_context, line, line_number, null);
            }
            try visit(self.visitor_context, line, line_number, row);
        }
    };

    var message_context = MessageContext{
        .allocator = allocator,
        .path = path,
        .options = options,
        .seen = &seen,
        .visitor_context = context,
    };
    return forEachLine(allocator, path, &message_context, MessageContext.accept);
}

pub fn collectMessages(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: datasets.messages.ParseOptions,
    stats: ?*stats_mod.SeqStats,
) !?[]datasets.messages.MessageRow {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{})) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer file.close(io);

    var metrics = datasets.messages.ParseMetrics{};
    var reader = file.reader(io, &.{});
    const rows = try datasets.messages.parseJsonlReader(allocator, path, &reader.interface, options, &metrics);
    if (stats) |s| {
        s.files_opened += 1;
        s.bytes_read += @intCast(metrics.bytes_read);
        s.lines_seen += @intCast(metrics.lines_seen);
        s.json_parse_attempts += @intCast(metrics.lines_seen);
        s.json_parse_successes += @intCast(rows.len);
    }
    return rows;
}

pub fn collectSkillMentions(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: datasets.skill_mentions.ParseOptions,
    stats: ?*stats_mod.SeqStats,
) !?[]datasets.skill_mentions.SkillMentionRow {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{})) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer file.close(io);

    var metrics = datasets.messages.ParseMetrics{};
    var reader = file.reader(io, &.{});
    const rows = try datasets.skill_mentions.parseJsonlReader(allocator, path, &reader.interface, options, &metrics);
    if (stats) |s| {
        s.files_opened += 1;
        s.bytes_read += @intCast(metrics.bytes_read);
        s.lines_seen += @intCast(metrics.lines_seen);
        s.json_parse_attempts += @intCast(metrics.lines_seen);
        s.json_parse_successes += @intCast(rows.len);
    }
    return rows;
}

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

pub const ScanOptions = struct {
    messages: datasets.messages.ParseOptions = .{},
    skill_mentions: datasets.skill_mentions.ParseOptions = .{},
};

pub const TraceMode = enum { full, summary };

pub const TraceScanResult = struct {
    trace: canonical_trace.CanonicalSessionTrace,
    metrics: canonical_trace.StreamMetrics,
};

pub const TraceMessagesResult = struct {
    trace: canonical_trace.CanonicalSessionTrace,
    messages: []datasets.messages.MessageRow,
    metrics: canonical_trace.StreamMetrics,

    pub fn deinit(self: *TraceMessagesResult, allocator: std.mem.Allocator) void {
        self.trace.deinit(allocator);
        datasets.messages.freeRows(allocator, self.messages);
    }
};

pub fn scanTraceWithVisitor(
    allocator: std.mem.Allocator,
    path: []const u8,
    trace_options: canonical_trace.TraceParseOptions,
    mode: TraceMode,
    context: anytype,
    comptime visit: anytype,
) !?TraceScanResult {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{})) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    var reader = file.reader(io, &.{});
    var metrics = canonical_trace.StreamMetrics{};
    const trace = switch (mode) {
        .full => try canonical_trace.parseSessionTraceReaderWithVisitorMetrics(
            allocator,
            path,
            &reader.interface,
            stat.mtime.nanoseconds,
            trace_options,
            context,
            visit,
            &metrics,
        ),
        .summary => try canonical_trace.parseSessionSummaryTraceReaderWithVisitorMetrics(
            allocator,
            path,
            &reader.interface,
            stat.mtime.nanoseconds,
            trace_options,
            context,
            visit,
            &metrics,
        ),
    };
    return .{ .trace = trace, .metrics = metrics };
}

/// Derive canonical trace state and the command's normalized message view from
/// one JSONL record stream. Neither projection can observe a later reopen.
pub fn scanTraceAndMessages(
    allocator: std.mem.Allocator,
    path: []const u8,
    trace_options: canonical_trace.TraceParseOptions,
    message_options: datasets.messages.ParseOptions,
    mode: TraceMode,
) !?TraceMessagesResult {
    var rows: std.ArrayList(datasets.messages.MessageRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var seen = std.AutoHashMap([std.crypto.hash.sha2.Sha256.digest_length]u8, void).init(allocator);
    defer seen.deinit();
    const Context = struct {
        allocator: std.mem.Allocator,
        path: []const u8,
        options: datasets.messages.ParseOptions,
        seen: *@TypeOf(seen),
        rows: *std.ArrayList(datasets.messages.MessageRow),

        fn visit(self: *@This(), line: []const u8, _: usize) !void {
            try appendUniqueMessage(self.allocator, self.path, line, self.options, self.seen, self.rows);
        }
    };
    var context = Context{
        .allocator = allocator,
        .path = path,
        .options = message_options,
        .seen = &seen,
        .rows = &rows,
    };
    const scan = (try scanTraceWithVisitor(allocator, path, trace_options, mode, &context, Context.visit)) orelse return null;
    var trace = scan.trace;
    errdefer trace.deinit(allocator);
    return .{
        .trace = trace,
        .messages = try rows.toOwnedSlice(allocator),
        .metrics = scan.metrics,
    };
}

pub fn scanFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    demand: Demand,
    stats: ?*stats_mod.SeqStats,
) !?Result {
    return scanFileWithOptions(allocator, path, demand, .{}, stats);
}

pub fn scanFileWithOptions(
    allocator: std.mem.Allocator,
    path: []const u8,
    demand: Demand,
    options: ScanOptions,
    stats: ?*stats_mod.SeqStats,
) !?Result {
    if (!demand.messages and !demand.skill_mentions) return null;

    if (demand.messages and demand.skill_mentions) {
        return scanPairedMessageViews(allocator, path, options, stats);
    }

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
        result.messages = try datasets.messages.parseJsonlReader(allocator, path, &reader.interface, options.messages, &metrics);
        if (stats) |s| s.json_parse_successes += @intCast(result.messages.len);
    } else if (demand.skill_mentions) {
        result.skill_mentions = try datasets.skill_mentions.parseJsonlReader(allocator, path, &reader.interface, options.skill_mentions, &metrics);
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

fn scanPairedMessageViews(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ScanOptions,
    stats: ?*stats_mod.SeqStats,
) !?Result {
    var result = Result{ .path = path };
    errdefer result.deinit(allocator);

    var message_rows: std.ArrayList(datasets.messages.MessageRow) = .empty;
    errdefer {
        for (message_rows.items) |row| row.deinit(allocator);
        message_rows.deinit(allocator);
    }
    var mention_messages: std.ArrayList(datasets.messages.MessageRow) = .empty;
    defer {
        for (mention_messages.items) |row| row.deinit(allocator);
        mention_messages.deinit(allocator);
    }
    var message_seen = std.AutoHashMap([std.crypto.hash.sha2.Sha256.digest_length]u8, void).init(allocator);
    defer message_seen.deinit();
    var mention_seen = std.AutoHashMap([std.crypto.hash.sha2.Sha256.digest_length]u8, void).init(allocator);
    defer mention_seen.deinit();

    const mention_message_options = datasets.messages.ParseOptions{
        .include_user = options.skill_mentions.include_user,
        .include_assistant = options.skill_mentions.include_assistant,
        .strip_echo_assistant = true,
        .skip_meta_user_messages = true,
        .dedupe_by_role_and_text = true,
        .strip_skill_blocks = false,
    };
    const Context = struct {
        allocator: std.mem.Allocator,
        path: []const u8,
        message_options: datasets.messages.ParseOptions,
        mention_message_options: datasets.messages.ParseOptions,
        message_rows: *std.ArrayList(datasets.messages.MessageRow),
        mention_messages: *std.ArrayList(datasets.messages.MessageRow),
        message_seen: *@TypeOf(message_seen),
        mention_seen: *@TypeOf(mention_seen),

        fn visit(self: *@This(), line: []const u8, _: usize) !void {
            try appendUniqueMessage(self.allocator, self.path, line, self.message_options, self.message_seen, self.message_rows);
            try appendUniqueMessage(self.allocator, self.path, line, self.mention_message_options, self.mention_seen, self.mention_messages);
        }
    };
    var context = Context{
        .allocator = allocator,
        .path = path,
        .message_options = options.messages,
        .mention_message_options = mention_message_options,
        .message_rows = &message_rows,
        .mention_messages = &mention_messages,
        .message_seen = &message_seen,
        .mention_seen = &mention_seen,
    };
    const metrics = (try forEachLine(allocator, path, &context, Context.visit)) orelse return null;

    result.messages = try message_rows.toOwnedSlice(allocator);
    result.skill_mentions = try datasets.skill_mentions.parseMessages(allocator, mention_messages.items, options.skill_mentions);
    if (stats) |s| {
        s.files_opened += 1;
        s.bytes_read += @intCast(metrics.bytes_read);
        s.lines_seen += @intCast(metrics.lines_seen);
        s.json_parse_attempts += @intCast(metrics.lines_seen);
        s.json_parse_successes += @intCast(result.messages.len + result.skill_mentions.len);
    }
    return result;
}

fn appendUniqueMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    options: datasets.messages.ParseOptions,
    seen: *std.AutoHashMap([std.crypto.hash.sha2.Sha256.digest_length]u8, void),
    out: *std.ArrayList(datasets.messages.MessageRow),
) !void {
    const maybe_row = try datasets.messages.parseJsonlLine(allocator, path, line, options);
    const row = maybe_row orelse return;
    errdefer row.deinit(allocator);
    if (options.dedupe_by_role_and_text) {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(row.role);
        hasher.update("\x1f");
        hasher.update(row.text);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        const entry = try seen.getOrPut(digest);
        if (entry.found_existing) {
            row.deinit(allocator);
            return;
        }
    }
    try out.append(allocator, row);
}

test "paired message views preserve independent projections in one scan" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jsonl =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-07-21T00:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Use $seq\\n<skill><name>hidden</name></skill>\"}]}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "session.jsonl", .data = jsonl });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "session.jsonl" });
    defer std.testing.allocator.free(path);

    var result = (try scanFileWithOptions(std.testing.allocator, path, .{
        .messages = true,
        .skill_mentions = true,
    }, .{
        .messages = .{ .strip_skill_blocks = true },
        .skill_mentions = .{ .include_blocks = false },
    }, null)).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.messages.len);
    try std.testing.expect(std.mem.indexOf(u8, result.messages[0].text, "hidden") == null);
    try std.testing.expectEqual(@as(usize, 1), result.skill_mentions.len);
    try std.testing.expectEqualStrings("seq", result.skill_mentions[0].skill);
}

test "trace and messages share one record stream" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jsonl =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-21T00:00:00Z\",\"payload\":{\"id\":\"paired-trace\",\"cwd\":\"/tmp/paired\"}}\n" ++
        "{\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"paired message\"}]},\"type\":\"response_item\",\"timestamp\":\"2026-07-21T00:00:01Z\"}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "session.jsonl", .data = jsonl });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "session.jsonl" });
    defer std.testing.allocator.free(path);

    var result = (try scanTraceAndMessages(std.testing.allocator, path, .{}, .{}, .full)).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("paired-trace", result.trace.session.session_id.?);
    try std.testing.expectEqual(@as(usize, 1), result.messages.len);
    try std.testing.expectEqualStrings("paired message", result.messages[0].text);
    try std.testing.expectEqual(@as(usize, jsonl.len), result.metrics.bytes_read);
    try std.testing.expectEqual(@as(usize, 2), result.metrics.lines_seen);
}

test "held-descriptor offset scan ignores path replacement" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "session.jsonl" });
    defer std.testing.allocator.free(source_path);
    const replacement_path = try std.fs.path.join(std.testing.allocator, &.{ root, "replacement.jsonl" });
    defer std.testing.allocator.free(replacement_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "session.jsonl", .data = "old-a\nold-b\n" });
    var held = try std.Io.Dir.openFileAbsolute(io, source_path, .{});
    defer held.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "replacement.jsonl", .data = "new-a\n" });
    try std.Io.Dir.renameAbsolute(replacement_path, source_path, io);

    const Context = struct {
        count: usize = 0,

        fn visit(self: *@This(), line: []const u8, _: usize) !void {
            const expected = [_][]const u8{ "old-a", "old-b" };
            try std.testing.expect(self.count < expected.len);
            try std.testing.expectEqualStrings(expected[self.count], line);
            self.count += 1;
        }
    };
    var context = Context{};
    const metrics = try forEachLineFromFileOffset(std.testing.allocator, &held, 0, &context, Context.visit);
    try std.testing.expectEqual(@as(usize, 2), context.count);
    try std.testing.expectEqual(@as(usize, "old-a\nold-b\n".len), metrics.bytes_read);
}
