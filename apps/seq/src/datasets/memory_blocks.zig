const std = @import("std");
const memory_files = @import("memory_files.zig");

pub const Options = struct {
    memory_root: ?[]const u8 = null,
    body_limit: usize = 4096,
};

pub const Row = struct {
    path: []u8,
    relative_path: []u8,
    doc_kind: []u8,
    heading_path: []u8,
    title: []u8,
    body: []u8,
    preview: []u8,
    updated_at: ?[]u8 = null,
    thread_id: ?[]u8 = null,
    rollout_path: ?[]u8 = null,
    keywords: ?[]u8 = null,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.relative_path);
        allocator.free(self.doc_kind);
        allocator.free(self.heading_path);
        allocator.free(self.title);
        allocator.free(self.body);
        allocator.free(self.preview);
        if (self.updated_at) |value| allocator.free(value);
        if (self.thread_id) |value| allocator.free(value);
        if (self.rollout_path) |value| allocator.free(value);
        if (self.keywords) |value| allocator.free(value);
    }
};

pub const RowList = std.ArrayList(Row);

pub fn deinitRows(allocator: std.mem.Allocator, rows: *RowList) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

const Metadata = struct {
    updated_at: ?[]u8 = null,
    thread_id: ?[]u8 = null,
    rollout_path: ?[]u8 = null,
    keywords: ?[]u8 = null,

    fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        if (self.updated_at) |value| allocator.free(value);
        if (self.thread_id) |value| allocator.free(value);
        if (self.rollout_path) |value| allocator.free(value);
        if (self.keywords) |value| allocator.free(value);
    }
};

pub fn collect(allocator: std.mem.Allocator, options: Options) !RowList {
    var rows: RowList = .empty;
    errdefer deinitRows(allocator, &rows);

    const file_options = memory_files.Options{ .memory_root = options.memory_root };
    var files = try memory_files.collect(allocator, file_options);
    defer memory_files.deinitRows(allocator, &files);

    for (files.items) |*file_row| {
        if (!std.mem.eql(u8, file_row.extension, ".md")) continue;

        const content = try readFileAllocOrSkip(allocator, file_row.path);
        if (content == null) continue;
        defer allocator.free(content.?);

        var metadata = try extractMetadata(allocator, content.?);
        defer metadata.deinit(allocator);

        try appendDocumentBlocks(allocator, &rows, file_row, content.?, metadata, options.body_limit);
    }

    return rows;
}

fn readFileAllocOrSkip(allocator: std.mem.Allocator, absolute_path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), absolute_path, .{}) catch return null;
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(256 * 1024)) catch null;
}

fn extractMetadata(allocator: std.mem.Allocator, content: []const u8) !Metadata {
    var out = Metadata{};
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_frontmatter = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) {
            if (in_frontmatter) break;
            continue;
        }
        if (trimmed[0] == '#') break;
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |sep| {
            const key = std.mem.trim(u8, trimmed[0..sep], " \t");
            const value = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
            if (std.mem.eql(u8, key, "updated_at")) {
                out.updated_at = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "thread_id")) {
                out.thread_id = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "rollout_path")) {
                out.rollout_path = try allocator.dupe(u8, value);
            }
        } else {
            in_frontmatter = false;
        }
    }

    if (std.mem.indexOf(u8, content, "### keywords")) |keywords_idx| {
        const after = content[keywords_idx + "### keywords".len ..];
        if (std.mem.indexOf(u8, after, "\n\n")) |end_rel| {
            const section = std.mem.trim(u8, after[0..end_rel], " \t\r\n");
            if (section.len > 0) out.keywords = try allocator.dupe(u8, section);
        }
    }

    return out;
}

fn appendDocumentBlocks(
    allocator: std.mem.Allocator,
    rows: *RowList,
    file_row: *memory_files.Row,
    content: []const u8,
    metadata: Metadata,
    body_limit: usize,
) !void {
    var headings = std.ArrayList([]u8).empty;
    defer {
        for (headings.items) |value| allocator.free(value);
        headings.deinit(allocator);
    }

    var current_start: usize = 0;
    var current_title: ?[]u8 = null;
    var current_depth: usize = 0;

    var line_start: usize = 0;
    while (line_start <= content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = content[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const heading = parseHeading(trimmed);
        if (heading != null) {
            if (current_title != null) {
                try emitBlock(allocator, rows, file_row, headings.items, current_title.?, current_depth, content[current_start..line_start], metadata, body_limit);
            }

            const parsed = heading.?;
            while (headings.items.len >= parsed.depth) {
                allocator.free(headings.pop().?);
            }
            const title_copy = try allocator.dupe(u8, parsed.title);
            try headings.append(allocator, title_copy);
            current_title = title_copy;
            current_depth = parsed.depth;
            current_start = if (line_end < content.len) line_end + 1 else line_end;
        }
        if (line_end == content.len) break;
        line_start = line_end + 1;
    }

    if (current_title != null) {
        try emitBlock(allocator, rows, file_row, headings.items, current_title.?, current_depth, content[current_start..], metadata, body_limit);
    } else {
        try emitBlock(
            allocator,
            rows,
            file_row,
            &.{},
            file_row.name,
            1,
            content,
            metadata,
            body_limit,
        );
    }
}

const Heading = struct {
    depth: usize,
    title: []const u8,
};

fn parseHeading(line: []const u8) ?Heading {
    if (line.len < 2 or line[0] != '#') return null;
    var depth: usize = 0;
    while (depth < line.len and line[depth] == '#') : (depth += 1) {}
    if (depth == 0 or depth >= line.len or line[depth] != ' ') return null;
    const title = std.mem.trim(u8, line[depth + 1 ..], " \t");
    if (title.len == 0) return null;
    return .{ .depth = depth, .title = title };
}

fn emitBlock(
    allocator: std.mem.Allocator,
    rows: *RowList,
    file_row: *memory_files.Row,
    headings: []const []u8,
    title_text: []const u8,
    depth: usize,
    raw_body: []const u8,
    metadata: Metadata,
    body_limit: usize,
) !void {
    _ = depth;
    const normalized = try normalizeBody(allocator, raw_body, body_limit);
    defer allocator.free(normalized);
    if (normalized.len == 0) return;

    const preview = firstNonEmptyLine(normalized) orelse normalized[0..@min(normalized.len, 200)];
    const heading_path = try joinHeadings(allocator, headings);
    errdefer allocator.free(heading_path);

    var row = Row{
        .path = try allocator.dupe(u8, file_row.path),
        .relative_path = try allocator.dupe(u8, file_row.relative_path),
        .doc_kind = try allocator.dupe(u8, docKind(file_row.relative_path)),
        .heading_path = heading_path,
        .title = try allocator.dupe(u8, title_text),
        .body = try allocator.dupe(u8, normalized),
        .preview = try allocator.dupe(u8, preview),
    };
    errdefer row.deinit(allocator);

    if (metadata.updated_at) |value| row.updated_at = try allocator.dupe(u8, value);
    if (metadata.thread_id) |value| row.thread_id = try allocator.dupe(u8, value);
    if (metadata.rollout_path) |value| row.rollout_path = try allocator.dupe(u8, value);
    if (metadata.keywords) |value| row.keywords = try allocator.dupe(u8, value);

    try rows.append(allocator, row);
}

fn normalizeBody(allocator: std.mem.Allocator, raw_body: []const u8, body_limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var last_was_space = false;
    while (i < raw_body.len and out.items.len < body_limit) : (i += 1) {
        const c = raw_body[i];
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            if (!last_was_space and out.items.len > 0) try out.append(allocator, ' ');
            last_was_space = true;
        } else {
            try out.append(allocator, c);
            last_was_space = false;
        }
    }

    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) return trimmed[0..@min(trimmed.len, 200)];
    }
    return null;
}

fn joinHeadings(allocator: std.mem.Allocator, headings: []const []u8) ![]u8 {
    if (headings.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (headings, 0..) |heading, idx| {
        if (idx > 0) try out.appendSlice(allocator, " > ");
        try out.appendSlice(allocator, heading);
    }
    return out.toOwnedSlice(allocator);
}

fn docKind(relative_path: []const u8) []const u8 {
    if (std.mem.eql(u8, relative_path, "memory_summary.md")) return "memory_summary";
    if (std.mem.eql(u8, relative_path, "MEMORY.md")) return "memory_registry";
    if (std.mem.startsWith(u8, relative_path, "rollout_summaries/")) return "rollout_summary";
    if (std.mem.startsWith(u8, relative_path, "skills/")) return "memory_skill";
    return "memory_doc";
}

test "collect parses rollout summary headings into blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "rollout_summaries");
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "rollout_summaries/example.md",
        .data = "thread_id: abc\nupdated_at: 2026-03-11T00:00:00Z\nrollout_path: /tmp/run.jsonl\n\n# Title\n\nIntro text.\n\n## Task 1\n\nOutcome: success\n",
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    var rows = try collect(std.testing.allocator, .{ .memory_root = root_abs });
    defer deinitRows(std.testing.allocator, &rows);

    try std.testing.expect(rows.items.len >= 2);
    try std.testing.expectEqualStrings("rollout_summary", rows.items[0].doc_kind);
    try std.testing.expect(rows.items[0].thread_id != null);
    try std.testing.expect(rows.items[0].rollout_path != null);
}
