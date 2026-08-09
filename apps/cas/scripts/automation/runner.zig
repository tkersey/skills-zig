const files = @import("files.zig");
const output_mod = @import("output.zig");
const rrule = @import("rrule.zig");
const scheduler = @import("scheduler.zig");
const store = @import("store.zig");
const std = @import("std");

const MaxCommandOutputBytes = 10 * 1024 * 1024;

pub const RunResult = struct {
    id: []const u8,
    status: []const u8,
    thread_id: []const u8,
    cwd: []const u8,
    next_run_at: ?i64,
    exit_code: ?u8,
    err: ?[]const u8,
};

pub const CodexRunResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    output_text: []u8,
    output_path: []u8,
};

pub fn firstLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const clipped = if (line.len > width) line[0..width] else line;
        return allocator.dupe(u8, clipped);
    }
    return allocator.dupe(u8, "");
}

test "firstLine skips leading blank lines" {
    const line = try firstLine(std.testing.allocator, "\n \t\nhello world\n", 64);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("hello world", line);
}

pub fn firstMeaningfulLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (std.ascii.startsWithIgnoreCase(line, "Echo:")) continue;
        const clipped = if (line.len > width) line[0..width] else line;
        return allocator.dupe(u8, clipped);
    }
    return allocator.dupe(u8, "");
}

pub fn summarizeOutput(allocator: std.mem.Allocator, output: []const u8, width: usize) ![]u8 {
    const line = try firstMeaningfulLine(allocator, output, width);
    if (line.len > 0) return line;
    allocator.free(line);

    const compact = try collapseWhitespace(allocator, output);
    defer allocator.free(compact);
    if (compact.len == 0) return allocator.dupe(u8, "No output captured.");
    const clipped = if (compact.len > width) compact[0..width] else compact;
    return allocator.dupe(u8, clipped);
}

pub fn collapseWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;

    var prev_space = true;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            if (!prev_space) {
                try w.writeByte(' ');
                prev_space = true;
            }
            continue;
        }
        prev_space = false;
        try w.writeByte(ch);
    }

    const trimmed = std.mem.trim(u8, writer_alloc.written(), " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

pub fn cmdRunDue(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    args: anytype,
) !void {
    const maybe_lock = try acquireRunLock(allocator, args.lock_label);
    defer releaseRunLock(allocator, maybe_lock);

    if (maybe_lock == null) {
        try printRunLockHeld(allocator);
        return;
    }

    var db = try store.Db.open(allocator, db_path);
    defer db.close();
    try store.requireStoreSchema(allocator, &db);

    const now = store.nowMs();
    var due = try selectDueAutomations(allocator, &db, now, args.limit, args.automation_id);
    defer {
        for (due.items) |*row| row.deinit(allocator);
        due.deinit(allocator);
    }

    try validateDueBatch(allocator, due.items, now);

    if (due.items.len == 0) {
        try printNoDueAutomations();
        return;
    }

    const codex_exe = if (args.dry_run)
        null
    else
        try store.resolveExecutable(allocator, args.codex_bin);
    defer if (codex_exe) |p| allocator.free(p);
    if (!args.dry_run and codex_exe == null) {
        return userErrorFmt("codex executable not found: {s}", .{args.codex_bin});
    }

    var results = std.ArrayList(RunResult).empty;
    defer {
        for (results.items) |item| {
            allocator.free(item.thread_id);
            allocator.free(item.cwd);
            if (item.err) |err_text| allocator.free(err_text);
        }
        results.deinit(allocator);
    }

    try appendRunDueResults(
        allocator,
        io,
        &db,
        due.items,
        codex_exe orelse "",
        args.dry_run,
        &results,
    );

    try printRunDueResults(allocator, results.items);
}

fn printRunLockHeld(allocator: std.mem.Allocator) !void {
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    const ts = try rrule.timestampStringUtc(allocator, store.nowMs());
    defer allocator.free(ts);
    try stderr.print("{s} skip: lock held\n", .{ts});
}

fn printNoDueAutomations() !void {
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll("no due automations\n");
}

fn printRunDueResults(allocator: std.mem.Allocator, results: []const RunResult) !void {
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const json_text = try output_mod.buildRunResultsJsonAlloc(allocator, results);
    defer allocator.free(json_text);
    try stdout_writer.interface.writeAll(json_text);
}

fn appendRunDueResults(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *store.Db,
    due: []store.AutomationRow,
    codex_exe: []const u8,
    dry_run: bool,
    results: *std.ArrayList(RunResult),
) !void {
    for (due) |*row| {
        const result = runDueAutomation(
            allocator,
            io,
            db,
            row,
            codex_exe,
            dry_run,
        ) catch |err| {
            const err_text = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            const empty_thread = try allocator.dupe(u8, "");
            errdefer allocator.free(empty_thread);
            const empty_cwd = try allocator.dupe(u8, "");
            errdefer allocator.free(empty_cwd);
            try results.append(allocator, .{
                .id = row.id,
                .status = "error",
                .thread_id = empty_thread,
                .cwd = empty_cwd,
                .next_run_at = null,
                .exit_code = null,
                .err = err_text,
            });
            continue;
        };
        try results.append(allocator, result);
    }
}

pub fn selectDueAutomations(
    allocator: std.mem.Allocator,
    db: *store.Db,
    now: i64,
    limit: usize,
    automation_id: ?[]const u8,
) !std.ArrayList(store.AutomationRow) {
    var rows = std.ArrayList(store.AutomationRow).empty;

    if (automation_id) |id_value| {
        const select_by_id_sql =
            "select id, name, prompt, status, next_run_at, last_run_at, " ++
            "cwds, rrule, created_at, updated_at from automations where id = ? " ++
            "and status = 'ACTIVE' and " ++
            "(next_run_at is null or next_run_at <= ?)";
        var stmt = try db.prepare(allocator, select_by_id_sql);
        defer stmt.deinit();
        try stmt.bindAll(&.{ .{ .text = id_value }, .{ .int = now } });

        while (true) { // tiger: event-loop -- SQLite ends the row stream with `.done`.
            switch (try stmt.step()) {
                .done => break,
                .row => try rows.append(
                    allocator,
                    try store.readAutomationRow(allocator, &stmt),
                ),
            }
        }

        return rows;
    }

    const select_due_sql =
        "select id, name, prompt, status, next_run_at, last_run_at, " ++
        "cwds, rrule, created_at, updated_at from automations " ++
        "where status = 'ACTIVE' and " ++
        "(next_run_at is null or next_run_at <= ?) " ++
        "order by coalesce(next_run_at, 0) asc limit ?";
    var stmt = try db.prepare(allocator, select_due_sql);
    defer stmt.deinit();

    try stmt.bindAll(&.{ .{ .int = now }, .{ .int = @intCast(limit) } });

    while (true) { // tiger: event-loop -- SQLite ends the row stream with `.done`.
        switch (try stmt.step()) {
            .done => break,
            .row => try rows.append(
                allocator,
                try store.readAutomationRow(allocator, &stmt),
            ),
        }
    }

    return rows;
}

pub fn validateDueBatch(
    allocator: std.mem.Allocator,
    rows: []const store.AutomationRow,
    now: i64,
) !void {
    for (rows) |*row| {
        if (!std.mem.eql(u8, row.status, "ACTIVE")) {
            return userErrorFmt("due automation {s} is not ACTIVE", .{row.id});
        }
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, row.cwds_json, .{}) catch {
            return userErrorFmt("due automation {s} has malformed cwds JSON", .{row.id});
        };
        defer parsed.deinit();
        if (parsed.value != .array) {
            return userErrorFmt("due automation {s} cwds is not an array", .{row.id});
        }
        for (parsed.value.array.items) |item| {
            if (item != .string or std.mem.trim(u8, item.string, " \t\r\n").len == 0) {
                return userErrorFmt("due automation {s} has an invalid cwd", .{row.id});
            }
        }
        _ = try rrule.computeNextRunAt(allocator, row, now);
    }
}

pub fn runDueAutomation(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *store.Db,
    row: *store.AutomationRow,
    codex_bin: []const u8,
    dry_run: bool,
) !RunResult {
    const started = store.nowMs();
    const next_run = try rrule.computeNextRunAt(allocator, row, started);

    if (!dry_run) {
        try closeStaleRunningRows(allocator, db, row.id, started);
    }

    var cwds = try files.parseCwdsJson(allocator, row.cwds_json);
    defer files.freeOwnedStrings(allocator, cwds);

    if (cwds.items.len == 0) {
        const cwd = try store.currentPathOwned(allocator);
        try cwds.append(allocator, cwd);
    }

    var failures = std.ArrayList([]u8).empty;
    defer {
        for (failures.items) |msg| allocator.free(msg);
        failures.deinit(allocator);
    }

    var final_thread_id: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(final_thread_id);
    var final_cwd: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(final_cwd);

    for (cwds.items) |cwd| {
        const outcome = try runAutomationCwd(
            allocator,
            io,
            db,
            row,
            codex_bin,
            cwd,
            started,
            dry_run,
        );
        allocator.free(final_thread_id);
        allocator.free(final_cwd);
        final_thread_id = outcome.thread_id;
        final_cwd = outcome.cwd;
        if (outcome.failure) |failure| {
            errdefer allocator.free(failure);
            try failures.append(allocator, failure);
        }
    }

    if (dry_run) return dryRunResult(row, final_thread_id, final_cwd, next_run);

    return finalizeAutomationRun(
        allocator,
        db,
        row,
        started,
        next_run,
        cwds.items.len,
        failures.items.len,
        final_thread_id,
        final_cwd,
    );
}

fn dryRunResult(
    row: *const store.AutomationRow,
    thread_id: []u8,
    cwd: []u8,
    next_run: i64,
) RunResult {
    return .{
        .id = row.id,
        .status = "dry_run",
        .thread_id = thread_id,
        .cwd = cwd,
        .next_run_at = next_run,
        .exit_code = null,
        .err = null,
    };
}

const CwdRunOutcome = struct {
    thread_id: []u8,
    cwd: []u8,
    failure: ?[]u8,
};

fn runAutomationCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *store.Db,
    row: *const store.AutomationRow,
    codex_bin: []const u8,
    cwd: []const u8,
    started: i64,
    dry_run: bool,
) !CwdRunOutcome {
    const thread_id = try store.generateUuidV4(allocator);
    errdefer allocator.free(thread_id);
    const owned_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(owned_cwd);

    if (dry_run) return .{ .thread_id = thread_id, .cwd = owned_cwd, .failure = null };
    try insertRunRow(allocator, db, row, thread_id, cwd, started);

    const exec_result = runCodexExec(
        allocator,
        io,
        codex_bin,
        cwd,
        row.prompt,
        thread_id,
    ) catch |err| {
        const summary = try std.fmt.allocPrint(
            allocator,
            "Command failed before completion: {s}",
            .{@errorName(err)},
        );
        defer allocator.free(summary);
        try updateRunRow(
            allocator,
            db,
            thread_id,
            row,
            "FAILED",
            summary,
            summary,
            store.nowMs(),
        );
        const failure = try std.fmt.allocPrint(
            allocator,
            "{s} ({s})",
            .{ cwd, @errorName(err) },
        );
        return .{ .thread_id = thread_id, .cwd = owned_cwd, .failure = failure };
    };
    defer freeCodexRunResult(allocator, exec_result);

    const failure = try persistCodexRunResult(allocator, db, row, thread_id, cwd, exec_result);
    return .{ .thread_id = thread_id, .cwd = owned_cwd, .failure = failure };
}

fn freeCodexRunResult(allocator: std.mem.Allocator, result: CodexRunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    allocator.free(result.output_text);
    allocator.free(result.output_path);
}

fn persistCodexRunResult(
    allocator: std.mem.Allocator,
    db: *store.Db,
    row: *const store.AutomationRow,
    thread_id: []const u8,
    cwd: []const u8,
    result: CodexRunResult,
) !?[]u8 {
    const core_text = if (std.mem.trim(u8, result.output_text, " \t\r\n").len > 0)
        result.output_text
    else if (std.mem.trim(u8, result.stdout, " \t\r\n").len > 0)
        result.stdout
    else
        result.stderr;

    var summary = try summarizeOutput(allocator, core_text, 220);
    defer allocator.free(summary);
    if (result.exit_code != 0) {
        const enriched = try std.fmt.allocPrint(
            allocator,
            "Command failed (exit {d}): {s}",
            .{ result.exit_code, summary },
        );
        allocator.free(summary);
        summary = enriched;
    }

    var details = try allocator.dupe(u8, core_text);
    defer allocator.free(details);
    if (result.stderr.len > 0 and std.mem.indexOf(u8, details, result.stderr) == null) {
        const joined = try std.fmt.allocPrint(
            allocator,
            "{s}\n\n--- STDERR ---\n{s}",
            .{ details, result.stderr },
        );
        allocator.free(details);
        details = joined;
    }
    if (std.mem.trim(u8, details, " \t\r\n").len == 0) {
        allocator.free(details);
        details = try allocator.dupe(u8, summary);
    }

    const status = if (result.exit_code == 0) "PENDING_REVIEW" else "FAILED";
    try updateRunRow(
        allocator,
        db,
        thread_id,
        row,
        status,
        summary,
        details,
        store.nowMs(),
    );
    if (result.exit_code == 0) return null;
    const failure = try std.fmt.allocPrint(
        allocator,
        "{s} (exit {d})",
        .{ cwd, result.exit_code },
    );
    return failure;
}

fn finalizeAutomationRun(
    allocator: std.mem.Allocator,
    db: *store.Db,
    row: *const store.AutomationRow,
    started: i64,
    next_run: i64,
    cwds_count: usize,
    failures_count: usize,
    final_thread_id: []u8,
    final_cwd: []u8,
) !RunResult {
    try updateAutomationTimes(allocator, db, row.id, started, next_run);
    try store.syncAutomationFilesAfterCommit(allocator, db, row.id);

    const summary_text = if (failures_count == 0)
        try std.fmt.allocPrint(allocator, "Completed {d} run(s)", .{cwds_count})
    else
        try std.fmt.allocPrint(
            allocator,
            "Completed with failures in {d}/{d} cwd(s)",
            .{ failures_count, cwds_count },
        );
    defer allocator.free(summary_text);
    try files.writeMemorySummary(allocator, row.id, summary_text, started);

    if (failures_count > 0) {
        const err_text = try std.fmt.allocPrint(
            allocator,
            "failed cwds: {d}",
            .{failures_count},
        );
        return .{
            .id = row.id,
            .status = "failed",
            .thread_id = final_thread_id,
            .cwd = final_cwd,
            .next_run_at = next_run,
            .exit_code = 1,
            .err = err_text,
        };
    }
    return .{
        .id = row.id,
        .status = "ok",
        .thread_id = final_thread_id,
        .cwd = final_cwd,
        .next_run_at = next_run,
        .exit_code = 0,
        .err = null,
    };
}

pub fn closeStaleRunningRows(
    allocator: std.mem.Allocator,
    db: *store.Db,
    automation_id: []const u8,
    updated_ms: i64,
) !void {
    const update_sql =
        "update automation_runs set status = ?, inbox_title = ?, " ++
        "inbox_summary = ?, updated_at = ?, archived_reason = ? " ++
        "where automation_id = ? and status = ?";
    try db.exec(
        allocator,
        update_sql,
        &.{
            .{ .text = "FAILED" },
            .{ .text = "Automation run interrupted" },
            .{ .text = "Marked failed because a previous headless run did not close cleanly." },
            .{ .int = updated_ms },
            .{ .text = "headless_runner_interrupted" },
            .{ .text = automation_id },
            .{ .text = "RUNNING" },
        },
    );
}

pub fn insertRunRow(
    allocator: std.mem.Allocator,
    db: *store.Db,
    row: *const store.AutomationRow,
    thread_id: []const u8,
    source_cwd: []const u8,
    started_ms: i64,
) !void {
    const title = blk: {
        const line = try firstLine(allocator, row.prompt, 120);
        if (line.len > 0) break :blk line;
        allocator.free(line);
        break :blk try allocator.dupe(u8, row.name);
    };
    defer allocator.free(title);
    const running_title = try std.fmt.allocPrint(allocator, "{s} running", .{row.name});
    defer allocator.free(running_title);

    const insert_sql =
        "insert into automation_runs (thread_id, automation_id, status, read_at, " ++
        "thread_title, source_cwd, inbox_title, inbox_summary, created_at, " ++
        "updated_at, archived_user_message, archived_assistant_message, " ++
        "archived_reason) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
    try db.exec(
        allocator,
        insert_sql,
        &.{
            .{ .text = thread_id },
            .{ .text = row.id },
            .{ .text = "RUNNING" },
            .null,
            .{ .text = title },
            .{ .text = source_cwd },
            .{ .text = running_title },
            .{ .text = "Headless runner started this automation." },
            .{ .int = started_ms },
            .{ .int = started_ms },
            .null,
            .null,
            .null,
        },
    );
}

pub fn updateRunRow(
    allocator: std.mem.Allocator,
    db: *store.Db,
    thread_id: []const u8,
    row: *const store.AutomationRow,
    status: []const u8,
    summary: []const u8,
    assistant_message: []const u8,
    finished_ms: i64,
) !void {
    const inbox_title = if (std.mem.eql(u8, status, "PENDING_REVIEW"))
        try std.fmt.allocPrint(allocator, "{s} drafted", .{row.name})
    else
        try std.fmt.allocPrint(allocator, "{s} failed", .{row.name});
    defer allocator.free(inbox_title);

    const update_sql =
        "update automation_runs set status = ?, inbox_title = ?, " ++
        "inbox_summary = ?, updated_at = ?, archived_user_message = ?, " ++
        "archived_assistant_message = ?, archived_reason = ? where thread_id = ?";
    try db.exec(
        allocator,
        update_sql,
        &.{
            .{ .text = status },
            .{ .text = inbox_title },
            .{ .text = summary },
            .{ .int = finished_ms },
            .{ .text = row.prompt },
            .{ .text = assistant_message },
            .{ .text = "headless_runner_auto_archive" },
            .{ .text = thread_id },
        },
    );
}

pub fn updateAutomationTimes(
    allocator: std.mem.Allocator,
    db: *store.Db,
    automation_id: []const u8,
    run_started_ms: i64,
    next_run_at: i64,
) !void {
    try db.exec(
        allocator,
        "update automations set last_run_at = ?, next_run_at = ?, updated_at = ? where id = ?",
        &.{
            .{ .int = run_started_ms },
            .{ .int = next_run_at },
            .{ .int = store.nowMs() },
            .{ .text = automation_id },
        },
    );
}

pub fn runCodexExec(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_bin: []const u8,
    cwd: []const u8,
    prompt: []const u8,
    thread_id: []const u8,
) !CodexRunResult {
    const tmp_dir = try tmpAutomationRunnerDir(allocator);
    defer allocator.free(tmp_dir);
    try std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        tmp_dir,
    );

    const output_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.txt",
        .{ tmp_dir, thread_id },
    );

    const argv = [_][]const u8{
        codex_bin,
        "exec",
        "--full-auto",
        "--skip-git-repo-check",
        "--cd",
        cwd,
        "--output-last-message",
        output_path,
        prompt,
    };

    const child = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(MaxCommandOutputBytes),
        .stderr_limit = .limited(MaxCommandOutputBytes),
    });

    const output_text = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        output_path,
        allocator,
        .limited(MaxCommandOutputBytes),
    ) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return userErrorFmt(
            "failed to read codex output file ({s}): {s}",
            .{ output_path, @errorName(err) },
        ),
    };

    const exit_code: u8 = switch (child.term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(
            @as(u32, 128) + @intFromEnum(signal),
            @as(u32, 255),
        )),
        .stopped, .unknown => 1,
    };

    return .{
        .exit_code = exit_code,
        .stdout = child.stdout,
        .stderr = child.stderr,
        .output_text = output_text,
        .output_path = output_path,
    };
}

pub fn tmpAutomationRunnerDir(allocator: std.mem.Allocator) ![]u8 {
    const home = envString("HOME") orelse return userErrorFmt("HOME is not set", .{});
    return std.fmt.allocPrint(allocator, "{s}/.codex/tmp/automation-runner", .{home});
}

pub const RunLock = struct {
    file: std.Io.File,
    path: []u8,
};

pub fn acquireRunLock(allocator: std.mem.Allocator, label: []const u8) !?RunLock {
    const home = envString("HOME") orelse return userErrorFmt("HOME is not set", .{});
    const validated_label = try scheduler.validateSchedulerLabel(label);

    const lock_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/Library/Caches/{s}",
        .{ home, validated_label },
    );
    defer allocator.free(lock_dir);
    try std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        lock_dir,
    );

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/run.lock", .{lock_dir});
    defer allocator.free(lock_path);

    return acquireExclusiveLockWithStaleRetry(allocator, lock_path);
}

pub fn acquireExclusiveLockWithStaleRetry(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
) !?RunLock {
    return acquireExclusiveLockWithAttempt(allocator, lock_path, false);
}

pub fn acquireExclusiveLockWithAttempt(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    _: bool,
) !?RunLock {
    var file = std.Io.Dir.cwd().createFile(
        std.Io.Threaded.global_single_threaded.io(),
        lock_path,
        .{ .exclusive = true, .read = true, .truncate = false },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => return null,
        else => return userErrorFmt(
            "unable to create lock ({s}): {s}",
            .{ lock_path, @errorName(err) },
        ),
    };

    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "started_ms={d}\n", .{store.nowMs()});
    file.writeStreamingAll(
        std.Io.Threaded.global_single_threaded.io(),
        text,
    ) catch |err| {
        file.close(std.Io.Threaded.global_single_threaded.io());
        std.Io.Dir.cwd().deleteFile(
            std.Io.Threaded.global_single_threaded.io(),
            lock_path,
        ) catch |delete_err| {
            return userErrorFmt(
                "unable to remove unwritten lock ({s}): {s}",
                .{ lock_path, @errorName(delete_err) },
            );
        };
        return userErrorFmt(
            "unable to write lock ({s}): {s}",
            .{ lock_path, @errorName(err) },
        );
    };

    return .{ .file = file, .path = try allocator.dupe(u8, lock_path) };
}

pub fn releaseRunLock(allocator: std.mem.Allocator, lock: ?RunLock) void {
    if (lock) |state| {
        state.file.close(std.Io.Threaded.global_single_threaded.io());
        std.Io.Dir.cwd().deleteFile(
            std.Io.Threaded.global_single_threaded.io(),
            state.path,
        ) catch |err| {
            const report_err = output_mod.userErrorFmt(
                "unable to remove lock ({s}): {s}",
                .{ state.path, @errorName(err) },
            );
            std.debug.assert(report_err == error.UserInput);
        };
        allocator.free(state.path);
    }
}

fn envString(key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

fn userErrorFmt(comptime fmt: []const u8, args: anytype) error{UserInput} {
    return output_mod.userErrorFmt(fmt, args);
}
