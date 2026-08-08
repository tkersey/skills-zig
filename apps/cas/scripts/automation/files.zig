const output = @import("output.zig");
const std = @import("std");

var automation_root_override: ?[]const u8 = null;

pub fn setAutomationRootOverride(path: ?[]const u8) void {
    automation_root_override = path;
}

pub fn parseCwdsJson(allocator: std.mem.Allocator, raw_json: []const u8) !std.ArrayList([]u8) {
    var result = std.ArrayList([]u8).empty;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw_json,
        .{},
    ) catch return userErrorFmt("cwds_json must be valid JSON", .{});
    defer parsed.deinit();
    if (parsed.value != .array) {
        return userErrorFmt("cwds_json must be a JSON array of strings", .{});
    }
    for (parsed.value.array.items) |item| {
        if (item != .string) return userErrorFmt("cwds_json must be a JSON array of strings", .{});
        try result.append(allocator, try allocator.dupe(u8, item.string));
    }
    return result;
}

pub fn freeOwnedStrings(allocator: std.mem.Allocator, list: std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    var owned = list;
    owned.deinit(allocator);
}

pub fn renderAutomationTomlAlloc(allocator: std.mem.Allocator, row: anytype) ![]u8 {
    const cwds = try parseCwdsJson(allocator, row.cwds_json);
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

    return std.fmt.allocPrint(
        allocator,
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

pub fn defaultAutomationsDir(allocator: std.mem.Allocator) ![]u8 {
    if (automation_root_override) |override| return allocator.dupe(u8, override);
    const home = envString("HOME") orelse return userErrorFmt("HOME is not set", .{});
    return std.fmt.allocPrint(allocator, "{s}/.codex/automations", .{home});
}

pub fn automationDirPath(allocator: std.mem.Allocator, automation_id: []const u8) ![]u8 {
    const base = try defaultAutomationsDir(allocator);
    defer allocator.free(base);
    const safe_id = try validateAutomationId(automation_id);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, safe_id });
}

pub fn readPrompt(
    allocator: std.mem.Allocator,
    inline_prompt: ?[]const u8,
    prompt_file: ?[]const u8,
) ![]u8 {
    if (inline_prompt != null and prompt_file != null) {
        return userErrorFmt("use either --prompt or --prompt-file", .{});
    }
    if (inline_prompt) |text| return allocator.dupe(u8, text);
    if (prompt_file) |path| {
        const raw = std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            allocator,
            .limited(2 * 1024 * 1024),
        ) catch |err| {
            return userErrorFmt(
                "unable to read prompt file ({s}): {s}",
                .{ path, @errorName(err) },
            );
        };
        defer allocator.free(raw);
        return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
    }
    return userErrorFmt("prompt is required (--prompt or --prompt-file)", .{});
}

fn validateAutomationId(raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or
        std.mem.eql(u8, trimmed, ".") or
        std.mem.eql(u8, trimmed, ".."))
    {
        return userErrorFmt("automation id must not be empty", .{});
    }
    if (std.mem.indexOfScalar(u8, trimmed, std.fs.path.sep) != null) {
        return userErrorFmt("automation id must not contain path separators", .{});
    }
    if (std.fs.path.sep == '\\' and
        std.mem.indexOfScalar(u8, trimmed, '/') != null)
    {
        return userErrorFmt("automation id must not contain path separators", .{});
    }
    return trimmed;
}

pub fn writeAutomationFilesForRow(allocator: std.mem.Allocator, row: anytype) !void {
    const target_dir = try automationDirPath(allocator, row.id);
    defer allocator.free(target_dir);
    std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        target_dir,
    ) catch |err| return userErrorFmt(
        "unable to create automation dir ({s}): {s}",
        .{ target_dir, @errorName(err) },
    );

    const toml_text = try renderAutomationTomlAlloc(allocator, row);
    defer allocator.free(toml_text);
    const automation_toml = try std.fmt.allocPrint(allocator, "{s}/automation.toml", .{target_dir});
    defer allocator.free(automation_toml);
    try output.writeFileAtomic(allocator, automation_toml, toml_text);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/memory.md", .{target_dir});
    defer allocator.free(memory_path);
    try createMemoryFileIfMissing(memory_path);
}

fn createMemoryFileIfMissing(memory_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().createFile(
        io,
        memory_path,
        .{ .exclusive = true },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return userErrorFmt(
            "unable to create memory.md ({s}): {s}",
            .{ memory_path, @errorName(err) },
        ),
    };
    file.close(io);
}

pub fn deleteAutomationFiles(allocator: std.mem.Allocator, automation_id: []const u8) !void {
    const target_dir = try automationDirPath(allocator, automation_id);
    defer allocator.free(target_dir);
    var dir = std.Io.Dir.cwd().openDir(
        std.Io.Threaded.global_single_threaded.io(),
        target_dir,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return userErrorFmt(
            "unable to open automation dir ({s}): {s}",
            .{ target_dir, @errorName(err) },
        ),
    };
    dir.close(std.Io.Threaded.global_single_threaded.io());
    std.Io.Dir.cwd().deleteTree(
        std.Io.Threaded.global_single_threaded.io(),
        target_dir,
    ) catch |err| {
        return userErrorFmt(
            "unable to delete automation dir ({s}): {s}",
            .{ target_dir, @errorName(err) },
        );
    };
}

pub fn writeMemorySummary(
    allocator: std.mem.Allocator,
    automation_id: []const u8,
    summary: []const u8,
    started_ms: i64,
) !void {
    const folder = try automationDirPath(allocator, automation_id);
    defer allocator.free(folder);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), folder);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/memory.md", .{folder});
    defer allocator.free(memory_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        memory_path,
        allocator,
        .limited(10 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return userErrorFmt(
            "failed reading memory file ({s}): {s}",
            .{ memory_path, @errorName(err) },
        ),
    };
    defer allocator.free(existing);

    const date = try dateStringUtc(allocator, started_ms);
    defer allocator.free(date);
    const ts = try timestampStringUtc(allocator, started_ms);
    defer allocator.free(ts);

    const block = try std.fmt.allocPrint(
        allocator,
        "Last run summary ({s}): {s}\nRun time: {s}\n",
        .{ date, summary, ts },
    );
    defer allocator.free(block);

    const merged = if (existing.len == 0)
        try allocator.dupe(u8, block)
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}\n\n{s}",
            .{ std.mem.trim(u8, existing, "\n"), block },
        );
    defer allocator.free(merged);

    try output.writeFileAtomic(allocator, memory_path, merged);
}

const CivilDate = struct { year: i64, month: u8, day: u8 };

fn civilFromDays(days_since_unix_epoch: i64) CivilDate {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1_460) +
            @divFloor(doe, 36_524) -
            @divFloor(doe, 146_096),
        365,
    );
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    return .{
        .year = y + (if (m <= 2) @as(i64, 1) else @as(i64, 0)),
        .month = @intCast(m),
        .day = @intCast(d),
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
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +0000",
        .{ d.year, d.month, d.day, parts.hour, parts.minute, parts.second },
    );
}

fn dateStringUtc(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const parts = parseHmsFromMs(ms);
    const d = civilFromDays(parts.days);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

fn envString(key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

fn userErrorFmt(comptime fmt: []const u8, args: anytype) error{UserInput} {
    return output.userErrorFmt(fmt, args);
}

test "memory creation never follows a dangling symlink" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
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

    try createMemoryFileIfMissing(memory_path);
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
    try createMemoryFileIfMissing(regular_path);
    const existing = try tmp.dir.readFileAlloc(
        io,
        "regular/memory.md",
        allocator,
        .limited(64),
    );
    defer allocator.free(existing);
    try std.testing.expectEqualStrings("preserve\n", existing);
}
