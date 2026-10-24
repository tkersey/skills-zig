const Operation = @import("operation.zig").Operation;
const core_calendar = @import("core_calendar");
const output = @import("output.zig");
const std = @import("std");

pub fn parseCwdsJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    raw_json: []const u8,
) !std.ArrayList([]u8) {
    var result = std.ArrayList([]u8).empty;
    errdefer freeOwnedStrings(allocator, result);
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return userErrorFmt(io, "cwds_json must be valid JSON", .{}),
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        return userErrorFmt(io, "cwds_json must be a JSON array of strings", .{});
    }
    for (parsed.value.array.items) |item| {
        if (item != .string) return userErrorFmt(
            io,
            "cwds_json must be a JSON array of strings",
            .{},
        );
        const owned = try allocator.dupe(u8, item.string);
        errdefer allocator.free(owned);
        try result.append(allocator, owned);
    }
    return result;
}

pub fn freeOwnedStrings(allocator: std.mem.Allocator, list: std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    var owned = list;
    owned.deinit(allocator);
}

pub fn renderAutomationTomlAlloc(io: std.Io, allocator: std.mem.Allocator, row: anytype) ![]u8 {
    const cwds = try parseCwdsJson(io, allocator, row.cwds_json);
    defer freeOwnedStrings(allocator, cwds);

    var cwds_view = std.ArrayList([]const u8).empty;
    defer cwds_view.deinit(allocator);
    for (cwds.items) |item| try cwds_view.append(allocator, item);
    const cwds_toml = try output.renderTomlStringArray(allocator, cwds_view.items);
    defer allocator.free(cwds_toml);

    const id_toml = try output.tomlQuoteAlloc(allocator, row.id);
    defer allocator.free(id_toml);
    const name_toml = try output.tomlQuoteAlloc(allocator, row.name);
    defer allocator.free(name_toml);
    const prompt_toml = try output.tomlQuoteAlloc(allocator, row.prompt);
    defer allocator.free(prompt_toml);
    const status_toml = try output.tomlQuoteAlloc(allocator, row.status);
    defer allocator.free(status_toml);
    const rrule_toml = try output.tomlQuoteAlloc(allocator, row.rrule);
    defer allocator.free(rrule_toml);

    return allocator.print(
        "version = 1\n" ++
            "id = {s}\n" ++
            "name = {s}\n" ++
            "prompt = {s}\n" ++
            "status = {s}\n" ++
            "rrule = {s}\n" ++
            "cwds = {s}\n" ++
            "created_at = {d}\n" ++
            "updated_at = {d}\n",
        .{
            id_toml,
            name_toml,
            prompt_toml,
            status_toml,
            rrule_toml,
            cwds_toml,
            row.created_at,
            row.updated_at,
        },
    );
}

pub fn defaultAutomationsDir(operation: Operation, allocator: std.mem.Allocator) ![]u8 {
    if (operation.automation_root) |override| return allocator.dupe(u8, override);
    const home = operation.environment.get("HOME") orelse return userErrorFmt(
        operation.io,
        "HOME is not set",
        .{},
    );
    return allocator.print("{s}/.codex/automations", .{home});
}

pub fn automationDirPath(
    operation: Operation,
    allocator: std.mem.Allocator,
    automation_id: []const u8,
) ![]u8 {
    const base = try defaultAutomationsDir(operation, allocator);
    defer allocator.free(base);
    const safe_id = try validateAutomationId(operation.io, automation_id);
    return allocator.print("{s}/{s}", .{ base, safe_id });
}

pub fn readPrompt(
    operation: Operation,
    allocator: std.mem.Allocator,
    inline_prompt: ?[]const u8,
    prompt_file: ?[]const u8,
) ![]u8 {
    if (inline_prompt != null and prompt_file != null) {
        return userErrorFmt(operation.io, "use either --prompt or --prompt-file", .{});
    }
    if (inline_prompt) |text| return allocator.dupe(u8, text);
    if (prompt_file) |path| {
        const raw = operation.cwd.readFileAlloc(
            operation.io,
            path,
            allocator,
            .limited(2 * 1024 * 1024),
        ) catch |err| {
            return userErrorFmt(
                operation.io,
                "unable to read prompt file ({s}): {s}",
                .{ path, @errorName(err) },
            );
        };
        defer allocator.free(raw);
        return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
    }
    return userErrorFmt(operation.io, "prompt is required (--prompt or --prompt-file)", .{});
}

fn validateAutomationId(io: std.Io, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or
        std.mem.eql(u8, trimmed, ".") or
        std.mem.eql(u8, trimmed, ".."))
    {
        return userErrorFmt(io, "automation id must not be empty", .{});
    }
    if (std.mem.indexOfScalar(u8, trimmed, std.fs.path.sep) != null) {
        return userErrorFmt(io, "automation id must not contain path separators", .{});
    }
    if (std.fs.path.sep == '\\' and
        std.mem.indexOfScalar(u8, trimmed, '/') != null)
    {
        return userErrorFmt(io, "automation id must not contain path separators", .{});
    }
    return trimmed;
}

pub fn writeAutomationFilesForRow(
    operation: Operation,
    allocator: std.mem.Allocator,
    row: anytype,
) !void {
    const target_dir = try automationDirPath(operation, allocator, row.id);
    defer allocator.free(target_dir);
    operation.cwd.createDirPath(
        operation.io,
        target_dir,
    ) catch |err| return userErrorFmt(
        operation.io,
        "unable to create automation dir ({s}): {s}",
        .{ target_dir, @errorName(err) },
    );

    const toml_text = try renderAutomationTomlAlloc(operation.io, allocator, row);
    defer allocator.free(toml_text);
    const automation_toml = try allocator.print("{s}/automation.toml", .{target_dir});
    defer allocator.free(automation_toml);
    try output.writeFileAtomic(operation, allocator, automation_toml, toml_text);

    const memory_path = try allocator.print("{s}/memory.md", .{target_dir});
    defer allocator.free(memory_path);
    try createMemoryFileIfMissing(operation, memory_path);
}

fn createMemoryFileIfMissing(operation: Operation, memory_path: []const u8) !void {
    var file = operation.cwd.createFile(
        operation.io,
        memory_path,
        .{ .exclusive = true },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return userErrorFmt(
            operation.io,
            "unable to create memory.md ({s}): {s}",
            .{ memory_path, @errorName(err) },
        ),
    };
    file.close(operation.io);
}

pub fn deleteAutomationFiles(
    operation: Operation,
    allocator: std.mem.Allocator,
    automation_id: []const u8,
) !void {
    const target_dir = try automationDirPath(operation, allocator, automation_id);
    defer allocator.free(target_dir);
    var dir = operation.cwd.openDir(
        operation.io,
        target_dir,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return userErrorFmt(
            operation.io,
            "unable to open automation dir ({s}): {s}",
            .{ target_dir, @errorName(err) },
        ),
    };
    dir.close(operation.io);
    operation.cwd.deleteTree(
        operation.io,
        target_dir,
    ) catch |err| {
        return userErrorFmt(
            operation.io,
            "unable to delete automation dir ({s}): {s}",
            .{ target_dir, @errorName(err) },
        );
    };
}

pub fn writeMemorySummary(
    operation: Operation,
    allocator: std.mem.Allocator,
    automation_id: []const u8,
    summary: []const u8,
    started_ms: i64,
) !void {
    const folder = try automationDirPath(operation, allocator, automation_id);
    defer allocator.free(folder);
    try operation.cwd.createDirPath(operation.io, folder);

    const memory_path = try allocator.print("{s}/memory.md", .{folder});
    defer allocator.free(memory_path);

    const existing = try readExistingMemory(operation, allocator, memory_path);
    defer allocator.free(existing);

    const date = try dateStringUtc(allocator, started_ms);
    defer allocator.free(date);
    const ts = try timestampStringUtc(allocator, started_ms);
    defer allocator.free(ts);

    const block = try allocator.print(
        "Last run summary ({s}): {s}\nRun time: {s}\n",
        .{ date, summary, ts },
    );
    defer allocator.free(block);

    const merged = if (existing.len == 0)
        try allocator.dupe(u8, block)
    else
        try allocator.print(
            "{s}\n\n{s}",
            .{ std.mem.trim(u8, existing, "\n"), block },
        );
    defer allocator.free(merged);

    try output.writeFileAtomic(operation, allocator, memory_path, merged);
}

fn readExistingMemory(
    operation: Operation,
    allocator: std.mem.Allocator,
    memory_path: []const u8,
) ![]u8 {
    const stat = operation.cwd.statFile(
        operation.io,
        memory_path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, ""),
        else => return userErrorFmt(
            operation.io,
            "failed inspecting memory file ({s}): {s}",
            .{ memory_path, @errorName(err) },
        ),
    };
    if (stat.kind != .file) {
        return userErrorFmt(
            operation.io,
            "refusing non-regular memory file ({s})",
            .{memory_path},
        );
    }
    return operation.cwd.readFileAlloc(
        operation.io,
        memory_path,
        allocator,
        .limited(10 * 1024 * 1024),
    ) catch |err| return userErrorFmt(
        operation.io,
        "failed reading memory file ({s}): {s}",
        .{ memory_path, @errorName(err) },
    );
}

const CivilDate = struct { year: i64, month: u8, day: u8 };

fn civilFromDays(days_since_unix_epoch: i64) CivilDate {
    const date = core_calendar.civilFromDays(days_since_unix_epoch, .gregorian);
    return .{
        .year = @intCast(date.year),
        .month = @intCast(date.month),
        .day = @intCast(date.day),
    };
}

fn parseHmsFromMs(ms: i64) struct { hour: u8, minute: u8, second: u8, days: i64 } {
    const sec = @divFloor(ms, 1000);
    const days = @divFloor(sec, 86_400);
    const sec_of_day = sec - days * 86_400;
    const hour = @divFloor(sec_of_day, 3600);
    const rem = sec_of_day - hour * 3600;
    const minute = @divFloor(rem, 60);
    const second = rem - minute * 60;
    return .{
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .days = days,
    };
}

fn timestampStringUtc(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const parts = parseHmsFromMs(ms);
    const d = civilFromDays(parts.days);
    return allocator.print(
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +0000",
        .{ d.year, d.month, d.day, parts.hour, parts.minute, parts.second },
    );
}

fn dateStringUtc(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const parts = parseHmsFromMs(ms);
    const d = civilFromDays(parts.days);
    return allocator.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

const userErrorFmt = output.userErrorFmt;

test "memory creation never follows a dangling symlink" {
    const operation: Operation = .{
        .io = std.testing.io,
        .cwd = std.Io.Dir.cwd(),
        .cwd_path = ".",
        .environment = &.init(std.testing.allocator),
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "automation", .default_dir);
    try tmp.dir.symLink(io, "../outside.md", "automation/memory.md", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const memory_path = try std.fs.path.join(
        allocator,
        &.{ root, "automation", "memory.md" },
    );
    defer allocator.free(memory_path);

    try createMemoryFileIfMissing(operation, memory_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "outside.md", .{}));
    const link = try tmp.dir.statFile(
        io,
        "automation/memory.md",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link.kind);

    try tmp.dir.createDir(io, "regular", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "regular/memory.md", .data = "preserve\n" });
    const regular_path = try std.fs.path.join(
        allocator,
        &.{ root, "regular", "memory.md" },
    );
    defer allocator.free(regular_path);
    try createMemoryFileIfMissing(operation, regular_path);
    const existing = try tmp.dir.readFileAlloc(
        io,
        "regular/memory.md",
        allocator,
        .limited(64),
    );
    defer allocator.free(existing);
    try std.testing.expectEqualStrings("preserve\n", existing);
}

test "memory summary rejects symlink and non-file memory targets" {
    var capture = @import("testing.zig").StderrCapture.init(std.testing.allocator);
    defer capture.deinit();
    var operation: Operation = .{
        .io = capture.io(),
        .cwd = std.Io.Dir.cwd(),
        .cwd_path = ".",
        .environment = &.init(std.testing.allocator),
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "automations", .default_dir);
    try tmp.dir.createDir(io, "automations/row", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.md", .data = "outside\n" });
    try tmp.dir.symLink(io, "../../outside.md", "automations/row/memory.md", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const automation_root = try std.fs.path.join(allocator, &.{ root, "automations" });
    defer allocator.free(automation_root);
    const memory_path = try std.fs.path.join(allocator, &.{ automation_root, "row", "memory.md" });
    defer allocator.free(memory_path);
    const expected = try std.fmt.allocPrint(
        allocator,
        "error: refusing non-regular memory file ({s})\n",
        .{memory_path},
    );
    defer allocator.free(expected);

    operation.automation_root = automation_root;

    try std.testing.expectError(
        error.UserInput,
        writeMemorySummary(operation, allocator, "row", "must not escape", 0),
    );
    try capture.expectEqual(expected);
    const outside = try tmp.dir.readFileAlloc(io, "outside.md", allocator, .limited(64));
    defer allocator.free(outside);
    try std.testing.expectEqualStrings("outside\n", outside);
    const link = try tmp.dir.statFile(
        io,
        "automations/row/memory.md",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link.kind);

    try tmp.dir.deleteFile(io, "automations/row/memory.md");
    try tmp.dir.createDir(io, "automations/row/memory.md", .default_dir);
    try std.testing.expectError(
        error.UserInput,
        writeMemorySummary(operation, allocator, "row", "must stay a file", 0),
    );
    try capture.expectEqual(expected);
}

fn parseCwdsWithAllocator(allocator: std.mem.Allocator, io: std.Io) !void {
    const result = try parseCwdsJson(io, allocator, "[\"one\",\"two\",\"three\"]");
    defer freeOwnedStrings(allocator, result);
    try std.testing.expectEqual(@as(usize, 3), result.items.len);
    try std.testing.expectEqualStrings("three", result.items[2]);
}

test "cwd JSON releases partially built output under allocation failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        parseCwdsWithAllocator,
        .{std.testing.io},
    );
}

test "cwd JSON rejects a malformed later element without leaking prior strings" {
    var capture = @import("testing.zig").StderrCapture.init(std.testing.allocator);
    defer capture.deinit();
    try std.testing.expectError(
        error.UserInput,
        parseCwdsJson(capture.io(), std.testing.allocator, "[\"one\",\"two\",3]"),
    );
    try capture.expectEqual("error: cwds_json must be a JSON array of strings\n");
}
