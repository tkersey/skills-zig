const std = @import("std");
const sqlite = @import("codex_state_sqlite.zig");

pub const Options = struct {
    state_db_path: ?[]const u8 = null,
};

pub const Row = struct {
    thread_id: []u8,
    source_updated_at: ?[]u8 = null,
    generated_at: ?[]u8 = null,
    rollout_slug: ?[]u8 = null,
    usage_count: ?i64 = null,
    last_usage: ?[]u8 = null,
    selected_for_phase2: bool,
    selected_for_phase2_source_updated_at: ?[]u8 = null,
    rollout_path: []u8,
    cwd: []u8,
    git_branch: ?[]u8 = null,
    source: []u8,
    title: []u8,
    memory_mode: []u8,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.thread_id);
        if (self.source_updated_at) |value| allocator.free(value);
        if (self.generated_at) |value| allocator.free(value);
        if (self.rollout_slug) |value| allocator.free(value);
        if (self.last_usage) |value| allocator.free(value);
        if (self.selected_for_phase2_source_updated_at) |value| allocator.free(value);
        allocator.free(self.rollout_path);
        allocator.free(self.cwd);
        if (self.git_branch) |value| allocator.free(value);
        allocator.free(self.source);
        allocator.free(self.title);
        allocator.free(self.memory_mode);
    }
};

pub const RowList = std.ArrayList(Row);

pub fn deinitRows(allocator: std.mem.Allocator, rows: *RowList) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

const REQUIRED_STAGE1_COLUMNS = [_][]const u8{
    "thread_id",
    "source_updated_at",
    "generated_at",
    "rollout_slug",
    "usage_count",
    "last_usage",
    "selected_for_phase2",
    "selected_for_phase2_source_updated_at",
};

const REQUIRED_THREADS_COLUMNS = [_][]const u8{
    "id",
    "rollout_path",
    "cwd",
    "git_branch",
    "source",
    "title",
    "memory_mode",
};

pub fn collect(allocator: std.mem.Allocator, options: Options) !RowList {
    const db_path = try sqlite.resolveDefaultDbPath(allocator, options.state_db_path);
    defer allocator.free(db_path);

    var db = try sqlite.Db.open(allocator, db_path);
    defer db.close();

    try requireColumns(allocator, &db, "stage1_outputs", &REQUIRED_STAGE1_COLUMNS);
    try requireColumns(allocator, &db, "threads", &REQUIRED_THREADS_COLUMNS);

    var rows: RowList = .empty;
    errdefer deinitRows(allocator, &rows);

    var stmt = try db.prepare(
        allocator,
        \\SELECT
        \\  s.thread_id,
        \\  s.source_updated_at,
        \\  s.generated_at,
        \\  s.rollout_slug,
        \\  s.usage_count,
        \\  s.last_usage,
        \\  s.selected_for_phase2,
        \\  s.selected_for_phase2_source_updated_at,
        \\  t.rollout_path,
        \\  t.cwd,
        \\  t.git_branch,
        \\  t.source,
        \\  t.title,
        \\  t.memory_mode
        \\FROM stage1_outputs s
        \\JOIN threads t ON t.id = s.thread_id
        \\ORDER BY s.source_updated_at DESC, s.thread_id DESC
    );
    defer stmt.deinit();

    while (try stmt.step() == .row) {
        var row = Row{
            .thread_id = try stmt.textColumnAlloc(allocator, 0),
            .source_updated_at = try sqlite.epochSecondsToIso8601Alloc(allocator, stmt.nullableIntColumn(1)),
            .generated_at = try sqlite.epochSecondsToIso8601Alloc(allocator, stmt.nullableIntColumn(2)),
            .rollout_slug = try stmt.nullableTextColumnAlloc(allocator, 3),
            .usage_count = stmt.nullableIntColumn(4),
            .last_usage = try sqlite.epochSecondsToIso8601Alloc(allocator, stmt.nullableIntColumn(5)),
            .selected_for_phase2 = stmt.intColumn(6) != 0,
            .selected_for_phase2_source_updated_at = try sqlite.epochSecondsToIso8601Alloc(allocator, stmt.nullableIntColumn(7)),
            .rollout_path = try stmt.textColumnAlloc(allocator, 8),
            .cwd = try stmt.textColumnAlloc(allocator, 9),
            .git_branch = try stmt.nullableTextColumnAlloc(allocator, 10),
            .source = try stmt.textColumnAlloc(allocator, 11),
            .title = try stmt.textColumnAlloc(allocator, 12),
            .memory_mode = try stmt.textColumnAlloc(allocator, 13),
        };
        errdefer row.deinit(allocator);
        try rows.append(allocator, row);
    }

    return rows;
}

fn requireColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    table_name: []const u8,
    required: []const []const u8,
) !void {
    const sql = try std.fmt.allocPrint(allocator, "PRAGMA table_info({s})", .{table_name});
    defer allocator.free(sql);

    var stmt = try db.prepare(allocator, sql);
    defer stmt.deinit();

    const seen = try allocator.alloc(bool, required.len);
    defer allocator.free(seen);
    @memset(seen, false);

    while (try stmt.step() == .row) {
        const name = try stmt.textColumnAlloc(allocator, 1);
        defer allocator.free(name);
        for (required, 0..) |column, idx| {
            if (std.mem.eql(u8, name, column)) {
                seen[idx] = true;
            }
        }
    }

    for (seen) |column_seen| {
        if (!column_seen) return error.UnsupportedCodexStateDbSchema;
    }
}

test "collect reads joined stage1 and thread rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "state_5.sqlite", .data = "" });
    const db_path = try tmp.dir.realpathAlloc(std.testing.allocator, "state_5.sqlite");
    defer std.testing.allocator.free(db_path);

    var db = try sqlite.Db.open(std.testing.allocator, db_path);
    defer db.close();
    try db.exec(std.testing.allocator,
        \\CREATE TABLE stage1_outputs (
        \\  thread_id TEXT PRIMARY KEY,
        \\  source_updated_at INTEGER NOT NULL,
        \\  raw_memory TEXT NOT NULL,
        \\  rollout_summary TEXT NOT NULL,
        \\  generated_at INTEGER NOT NULL,
        \\  rollout_slug TEXT,
        \\  usage_count INTEGER,
        \\  last_usage INTEGER,
        \\  selected_for_phase2 INTEGER NOT NULL DEFAULT 0,
        \\  selected_for_phase2_source_updated_at INTEGER
        \\);
        \\CREATE TABLE threads (
        \\  id TEXT PRIMARY KEY,
        \\  rollout_path TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL DEFAULT 0,
        \\  updated_at INTEGER NOT NULL DEFAULT 0,
        \\  source TEXT NOT NULL,
        \\  model_provider TEXT NOT NULL DEFAULT '',
        \\  cwd TEXT NOT NULL,
        \\  title TEXT NOT NULL,
        \\  sandbox_policy TEXT NOT NULL DEFAULT '',
        \\  approval_mode TEXT NOT NULL DEFAULT '',
        \\  tokens_used INTEGER NOT NULL DEFAULT 0,
        \\  has_user_event INTEGER NOT NULL DEFAULT 0,
        \\  archived INTEGER NOT NULL DEFAULT 0,
        \\  archived_at INTEGER,
        \\  git_sha TEXT,
        \\  git_branch TEXT,
        \\  git_origin_url TEXT,
        \\  cli_version TEXT NOT NULL DEFAULT '',
        \\  first_user_message TEXT NOT NULL DEFAULT '',
        \\  agent_nickname TEXT,
        \\  agent_role TEXT,
        \\  memory_mode TEXT NOT NULL DEFAULT 'enabled',
        \\  model TEXT,
        \\  reasoning_effort TEXT,
        \\  agent_path TEXT
        \\);
        \\INSERT INTO threads (id, rollout_path, source, cwd, title, git_branch, memory_mode)
        \\VALUES ('thread-a', '/tmp/rollout-a.jsonl', 'interactive', '/tmp/repo', 'Title A', 'main', 'enabled');
        \\INSERT INTO stage1_outputs (thread_id, source_updated_at, raw_memory, rollout_summary, generated_at, rollout_slug, usage_count, last_usage, selected_for_phase2, selected_for_phase2_source_updated_at)
        \\VALUES ('thread-a', 1772550556, 'raw', 'summary', 1772550000, 'example', 12, 1772600000, 1, 1772550556);
    );

    var rows = try collect(std.testing.allocator, .{ .state_db_path = db_path });
    defer deinitRows(std.testing.allocator, &rows);

    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("thread-a", rows.items[0].thread_id);
    try std.testing.expectEqualStrings("/tmp/rollout-a.jsonl", rows.items[0].rollout_path);
    try std.testing.expect(rows.items[0].selected_for_phase2);
    try std.testing.expectEqual(@as(?i64, 12), rows.items[0].usage_count);
    try std.testing.expect(rows.items[0].source_updated_at != null);
}

test "collect fails closed when required schema columns are missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "state_5.sqlite", .data = "" });
    const db_path = try tmp.dir.realpathAlloc(std.testing.allocator, "state_5.sqlite");
    defer std.testing.allocator.free(db_path);

    var db = try sqlite.Db.open(std.testing.allocator, db_path);
    defer db.close();
    try db.exec(std.testing.allocator,
        \\CREATE TABLE stage1_outputs (
        \\  thread_id TEXT PRIMARY KEY,
        \\  source_updated_at INTEGER NOT NULL,
        \\  raw_memory TEXT NOT NULL,
        \\  rollout_summary TEXT NOT NULL,
        \\  generated_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE threads (
        \\  id TEXT PRIMARY KEY,
        \\  rollout_path TEXT NOT NULL,
        \\  cwd TEXT NOT NULL,
        \\  source TEXT NOT NULL,
        \\  title TEXT NOT NULL
        \\);
    );

    try std.testing.expectError(
        error.UnsupportedCodexStateDbSchema,
        collect(std.testing.allocator, .{ .state_db_path = db_path }),
    );
}
