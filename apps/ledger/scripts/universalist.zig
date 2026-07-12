const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;
const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "ledger --source universalist";
const CanonicalPlanDir = ".ledger/universalist";
const CanonicalPlanPrefix = "plan-";
const LegacyPlanDir = ".ledger";
const LegacyPlanPrefix = "universalist-plan-";
const PlanSuffix = ".md";
const PlanIdLen = 30;
const MaxTemplateBytes = 1024 * 1024;
const MaxOrdinal = 9999;
threadlocal var runtime_io: ?std.Io = null;

fn defaultIo() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io orelse Io.io();
}

const UsageText =
    \\ledger --source universalist
    \\
    \\usage: ledger --source universalist [-h] [--repo PATH] {create,latest,path} ...
    \\
    \\Allocate and resolve collision-safe Universalist plan artifacts.
    \\
    \\commands:
    \\  create     Create a fresh timestamp-addressed plan from --template
    \\  latest     Resolve the newest valid plan by sortable plan id
    \\  path       Resolve one plan id to its absolute path
    \\
    \\options:
    \\  --repo PATH       Git repository to address (default: current repository)
    \\  --template FILE   Markdown template for create
    \\  --id PLAN-ID      Plan id for path
    \\  --format FORMAT   json|path for create/latest (default: json)
    \\  -h, --help        Show help
    \\  -V, --version     Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = ProgramName,
    .help_text = UsageText,
};

const Command = enum {
    create,
    latest,
    path,
};

const OutputFormat = enum {
    json,
    path,
};

const PlanLayout = enum {
    canonical,
    legacy,
};

const Args = struct {
    command: ?Command = null,
    repo: []const u8 = ".",
    template_path: ?[]const u8 = null,
    plan_id: ?[]const u8 = null,
    format: OutputFormat = .json,
};

const PlanAddress = struct {
    plan_id: []u8,
    created_at: []u8,
    path: []u8,

    fn deinit(self: *PlanAddress, allocator: std.mem.Allocator) void {
        allocator.free(self.plan_id);
        allocator.free(self.created_at);
        allocator.free(self.path);
        self.* = undefined;
    }
};

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const code = try runWithArgv(allocator, init.io, argv);
    if (code != 0) std.process.exit(code);
}

pub fn runWithArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const previous_io = runtime_io;
    runtime_io = io;
    defer runtime_io = previous_io;
    return runWithArgvInner(allocator, argv) catch |err| {
        try printFailure(allocator, err);
        return 2;
    };
}

fn runWithArgvInner(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (argv.len <= 1 or core_cli.isHelpArg(argv[1])) {
        try printHelp();
        return 0;
    }
    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try core_cli.printVersion(&stdout_writer.interface, Version);
        return 0;
    }

    const args = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    if (core_cli.containsHelpArg(argv[1..])) {
        try printHelp();
        return 0;
    }

    const repo = try durable_store.findGitRootAlloc(allocator, args.repo);
    defer allocator.free(repo);

    switch (args.command orelse return error.MissingCommand) {
        .create => {
            const template = try durable_store.readFileAlloc(allocator, args.template_path.?, MaxTemplateBytes);
            defer allocator.free(template);
            const now_ns: i128 = @intCast(std.Io.Clock.real.now(defaultIo()).nanoseconds);
            var address = try createPlanAtNs(allocator, repo, template, now_ns);
            defer address.deinit(allocator);
            try printAddress(allocator, .create, repo, address, args.format);
        },
        .latest => {
            var address = try latestPlanAddress(allocator, repo);
            defer address.deinit(allocator);
            try printAddress(allocator, .latest, repo, address, args.format);
        },
        .path => {
            var address = try resolvePlanAddress(allocator, repo, args.plan_id.?);
            defer address.deinit(allocator);
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print("{s}\n", .{address.path});
        },
    }
    return 0;
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (core_cli.isHelpArg(token)) continue;
        if (std.mem.eql(u8, token, "--repo")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.repo = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--template")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.template_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.plan_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (std.mem.eql(u8, argv[i], "json")) {
                args.format = .json;
            } else if (std.mem.eql(u8, argv[i], "path")) {
                args.format = .path;
            } else {
                return error.InvalidFormat;
            }
            continue;
        }
        if (!std.mem.startsWith(u8, token, "-") and args.command == null) {
            args.command = parseCommand(token) orelse return error.UnknownCommand;
            continue;
        }
        return error.UnknownOption;
    }

    const command = args.command orelse return error.MissingCommand;
    if (command == .create and args.template_path == null) return error.MissingTemplate;
    if (command == .path and args.plan_id == null) return error.MissingPlanId;
    if (command != .create and args.template_path != null) return error.TemplateNotAllowed;
    if (command != .path and args.plan_id != null) return error.PlanIdNotAllowed;
    if (command == .path and args.format != .json) return error.FormatNotAllowed;
    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn createPlanAtNs(
    allocator: std.mem.Allocator,
    repo: []const u8,
    template: []const u8,
    now_ns: i128,
) !PlanAddress {
    const stamp = try planTimestampAlloc(allocator, now_ns);
    defer allocator.free(stamp);
    const created_at = try isoTimestampAlloc(allocator, now_ns);
    errdefer allocator.free(created_at);

    var ordinal: usize = 0;
    while (ordinal <= MaxOrdinal) : (ordinal += 1) {
        const plan_id = try std.fmt.allocPrint(allocator, "{s}-{d:0>4}", .{ stamp, ordinal });
        errdefer allocator.free(plan_id);
        const path = try planPathAlloc(allocator, repo, plan_id, .canonical);
        errdefer allocator.free(path);
        const legacy_path = try planPathAlloc(allocator, repo, plan_id, .legacy);
        defer allocator.free(legacy_path);
        if (try planPathOccupied(legacy_path)) {
            allocator.free(plan_id);
            allocator.free(path);
            continue;
        }
        const body = try renderPlanAlloc(allocator, plan_id, created_at, template);
        defer allocator.free(body);

        durable_store.writeTextCreateNewAtomic(allocator, path, body, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(plan_id);
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        return .{
            .plan_id = plan_id,
            .created_at = created_at,
            .path = path,
        };
    }
    return error.PlanIdExhausted;
}

fn latestPlanAddress(allocator: std.mem.Allocator, repo: []const u8) !PlanAddress {
    const canonical_id = try latestPlanIdInLayoutAlloc(allocator, repo, .canonical);
    defer if (canonical_id) |plan_id| allocator.free(plan_id);
    const legacy_id = try latestPlanIdInLayoutAlloc(allocator, repo, .legacy);
    defer if (legacy_id) |plan_id| allocator.free(plan_id);

    if (canonical_id) |canonical| {
        if (legacy_id) |legacy| {
            if (std.mem.lessThan(u8, canonical, legacy)) {
                return addressFromIdAtLayout(allocator, repo, legacy, .legacy, false);
            }
        }
        return addressFromIdAtLayout(allocator, repo, canonical, .canonical, false);
    }
    if (legacy_id) |legacy| {
        return addressFromIdAtLayout(allocator, repo, legacy, .legacy, false);
    }
    return error.NoPlans;
}

fn latestPlanIdInLayoutAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    layout: PlanLayout,
) !?[]u8 {
    const relative_dir = planDir(layout);
    const plan_dir = try std.fs.path.join(allocator, &.{ repo, relative_dir });
    defer allocator.free(plan_dir);

    var dir = std.Io.Dir.openDirAbsolute(defaultIo(), plan_dir, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(defaultIo());

    var latest_id: ?[]u8 = null;
    errdefer if (latest_id) |plan_id| allocator.free(plan_id);
    var iter = dir.iterate();
    while (try iter.next(defaultIo())) |entry| {
        const plan_id = planIdFromFilename(entry.name, planPrefix(layout)) orelse continue;
        const stat = dir.statFile(defaultIo(), entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind == .sym_link) return error.SymlinkPlan;
        if (stat.kind != .file) continue;
        if (latest_id == null or std.mem.lessThan(u8, latest_id.?, plan_id)) {
            if (latest_id) |current| allocator.free(current);
            latest_id = try allocator.dupe(u8, plan_id);
        }
    }
    return latest_id;
}

fn resolvePlanAddress(allocator: std.mem.Allocator, repo: []const u8, plan_id: []const u8) !PlanAddress {
    if (!validPlanId(plan_id)) return error.InvalidPlanId;
    return addressFromIdAtLayout(allocator, repo, plan_id, .canonical, true) catch |err| switch (err) {
        error.PlanNotFound => addressFromIdAtLayout(allocator, repo, plan_id, .legacy, true),
        else => return err,
    };
}

fn addressFromIdAtLayout(
    allocator: std.mem.Allocator,
    repo: []const u8,
    plan_id: []const u8,
    layout: PlanLayout,
    require_existing: bool,
) !PlanAddress {
    const owned_id = try allocator.dupe(u8, plan_id);
    errdefer allocator.free(owned_id);
    const created_at = try createdAtFromIdAlloc(allocator, plan_id);
    errdefer allocator.free(created_at);
    const path = try planPathAlloc(allocator, repo, plan_id, layout);
    errdefer allocator.free(path);
    if (require_existing) {
        const stat = std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.PlanNotFound,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkPlan;
        if (stat.kind != .file) return error.PlanNotFile;
    }
    return .{ .plan_id = owned_id, .created_at = created_at, .path = path };
}

fn renderPlanAlloc(
    allocator: std.mem.Allocator,
    plan_id: []const u8,
    created_at: []const u8,
    template: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        "---\nschema: universalist-plan/v1\nplan_id: {s}\ncreated_at: {s}\n---\n\n",
        .{ plan_id, created_at },
    );
    try out.writer.writeAll(template);
    if (template.len == 0 or template[template.len - 1] != '\n') try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn planTimestampAlloc(allocator: std.mem.Allocator, now_ns: i128) ![]u8 {
    const seconds: i64 = @intCast(@divFloor(now_ns, @as(i128, 1_000_000_000)));
    const nanos: u32 = @intCast(now_ns - @as(i128, seconds) * 1_000_000_000);
    var days = @divFloor(seconds, 86_400);
    var seconds_of_day = seconds - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }
    const date = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}{d:0>9}Z", .{
        @as(u32, @intCast(date.year)),
        @as(u32, @intCast(date.month)),
        @as(u32, @intCast(date.day)),
        @as(u32, @intCast(hour)),
        @as(u32, @intCast(minute)),
        @as(u32, @intCast(second)),
        nanos,
    });
}

fn isoTimestampAlloc(allocator: std.mem.Allocator, now_ns: i128) ![]u8 {
    const stamp = try planTimestampAlloc(allocator, now_ns);
    defer allocator.free(stamp);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}T{s}:{s}:{s}.{s}Z", .{
        stamp[0..4],
        stamp[4..6],
        stamp[6..8],
        stamp[9..11],
        stamp[11..13],
        stamp[13..15],
        stamp[15..24],
    });
}

fn createdAtFromIdAlloc(allocator: std.mem.Allocator, plan_id: []const u8) ![]u8 {
    if (!validPlanId(plan_id)) return error.InvalidPlanId;
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}T{s}:{s}:{s}.{s}Z", .{
        plan_id[0..4],
        plan_id[4..6],
        plan_id[6..8],
        plan_id[9..11],
        plan_id[11..13],
        plan_id[13..15],
        plan_id[15..24],
    });
}

fn validPlanId(plan_id: []const u8) bool {
    if (plan_id.len != PlanIdLen) return false;
    if (plan_id[8] != 'T' or plan_id[24] != 'Z' or plan_id[25] != '-') return false;
    for (plan_id, 0..) |byte, index| {
        if (index == 8 or index == 24 or index == 25) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }
    const year = parseFixedU32(plan_id[0..4]) orelse return false;
    const month = parseFixedU32(plan_id[4..6]) orelse return false;
    const day = parseFixedU32(plan_id[6..8]) orelse return false;
    const hour = parseFixedU32(plan_id[9..11]) orelse return false;
    const minute = parseFixedU32(plan_id[11..13]) orelse return false;
    const second = parseFixedU32(plan_id[13..15]) orelse return false;
    if (year == 0 or month == 0 or month > 12 or day == 0) return false;
    if (day > daysInMonth(year, month)) return false;
    if (hour > 23 or minute > 59 or second > 59) return false;
    return true;
}

fn parseFixedU32(raw: []const u8) ?u32 {
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn planIdFromFilename(name: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, PlanSuffix)) return null;
    const plan_id = name[prefix.len .. name.len - PlanSuffix.len];
    return if (validPlanId(plan_id)) plan_id else null;
}

fn planDir(layout: PlanLayout) []const u8 {
    return switch (layout) {
        .canonical => CanonicalPlanDir,
        .legacy => LegacyPlanDir,
    };
}

fn planPrefix(layout: PlanLayout) []const u8 {
    return switch (layout) {
        .canonical => CanonicalPlanPrefix,
        .legacy => LegacyPlanPrefix,
    };
}

fn planPathAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    plan_id: []const u8,
    layout: PlanLayout,
) ![]u8 {
    if (!validPlanId(plan_id)) return error.InvalidPlanId;
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ planPrefix(layout), plan_id, PlanSuffix });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ repo, planDir(layout), filename });
}

fn planPathOccupied(path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkPlan;
    return true;
}

fn civilFromDays(days_since_unix_epoch: i64) Date {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    var m = mp + 3;
    if (m > 12) m -= 12;
    if (m <= 2) y += 1;
    return .{ .year = y, .month = m, .day = d };
}

fn printHelp() !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
}

fn printFailure(allocator: std.mem.Allocator, err: anyerror) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"universalist-plan-error/v1\",\"verdict\":\"blocked\",\"error\":");
    try std.json.Stringify.value(@errorName(err), .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn printAddress(
    allocator: std.mem.Allocator,
    command: Command,
    repo: []const u8,
    address: PlanAddress,
    format: OutputFormat,
) !void {
    if (format == .path) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try stdout_writer.interface.print("{s}\n", .{address.path});
        return;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"schema\":\"universalist-plan-address/v1\",\"command\":\"{s}\",\"repo\":", .{@tagName(command)});
    try std.json.Stringify.value(repo, .{}, &out.writer);
    try out.writer.writeAll(",\"plan_id\":");
    try std.json.Stringify.value(address.plan_id, .{}, &out.writer);
    try out.writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(address.created_at, .{}, &out.writer);
    try out.writer.writeAll(",\"path\":");
    try std.json.Stringify.value(address.path, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try std.Io.File.stdout().writeStreamingAll(defaultIo(), bytes);
}

test "plan ids embed a sortable nanosecond UTC timestamp" {
    const stamp = try planTimestampAlloc(std.testing.allocator, 1_234_567_890);
    defer std.testing.allocator.free(stamp);
    try std.testing.expectEqualStrings("19700101T000001234567890Z", stamp);

    const plan_id = try std.fmt.allocPrint(std.testing.allocator, "{s}-0000", .{stamp});
    defer std.testing.allocator.free(plan_id);
    try std.testing.expect(validPlanId(plan_id));
    const created_at = try createdAtFromIdAlloc(std.testing.allocator, plan_id);
    defer std.testing.allocator.free(created_at);
    try std.testing.expectEqualStrings("1970-01-01T00:00:01.234567890Z", created_at);
    try std.testing.expect(!validPlanId("20261301T000000000000000Z-0000"));
    try std.testing.expect(!validPlanId("20260229T000000000000000Z-0000"));
    try std.testing.expect(validPlanId("20240229T235959999999999Z-9999"));
}

test "create retries a colliding timestamp without overwriting and latest finds the second plan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);

    var first = try createPlanAtNs(std.testing.allocator, repo, "# Universalist Plan\n", 1_234_567_890);
    defer first.deinit(std.testing.allocator);
    var second = try createPlanAtNs(std.testing.allocator, repo, "# Universalist Plan\n", 1_234_567_890);
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("19700101T000001234567890Z-0000", first.plan_id);
    try std.testing.expectEqualStrings("19700101T000001234567890Z-0001", second.plan_id);
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
    const expected_first_path = try std.fs.path.join(std.testing.allocator, &.{
        repo,
        ".ledger",
        "universalist",
        "plan-19700101T000001234567890Z-0000.md",
    });
    defer std.testing.allocator.free(expected_first_path);
    try std.testing.expectEqualStrings(expected_first_path, first.path);

    const first_bytes = try durable_store.readFileAlloc(std.testing.allocator, first.path, MaxTemplateBytes);
    defer std.testing.allocator.free(first_bytes);
    try std.testing.expect(std.mem.indexOf(u8, first_bytes, "plan_id: 19700101T000001234567890Z-0000") != null);

    var latest = try latestPlanAddress(std.testing.allocator, repo);
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(second.plan_id, latest.plan_id);
    try std.testing.expectEqualStrings(second.path, latest.path);
}

test "lookup preserves legacy flat plans and prefers a canonical duplicate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);

    var canonical = try createPlanAtNs(std.testing.allocator, repo, "# Canonical\n", 1_234_567_890);
    defer canonical.deinit(std.testing.allocator);

    const legacy_id = "19700101T000002234567890Z-0000";
    const legacy_path = try planPathAlloc(std.testing.allocator, repo, legacy_id, .legacy);
    defer std.testing.allocator.free(legacy_path);
    try durable_store.writeTextCreateNewAtomic(std.testing.allocator, legacy_path, "# Legacy\n", .{});

    var resolved_legacy = try resolvePlanAddress(std.testing.allocator, repo, legacy_id);
    defer resolved_legacy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(legacy_path, resolved_legacy.path);

    var latest_legacy = try latestPlanAddress(std.testing.allocator, repo);
    defer latest_legacy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(legacy_id, latest_legacy.plan_id);
    try std.testing.expectEqualStrings(legacy_path, latest_legacy.path);

    const canonical_duplicate_path = try planPathAlloc(std.testing.allocator, repo, legacy_id, .canonical);
    defer std.testing.allocator.free(canonical_duplicate_path);
    try durable_store.writeTextCreateNewAtomic(std.testing.allocator, canonical_duplicate_path, "# Canonical duplicate\n", .{});

    var resolved_canonical = try resolvePlanAddress(std.testing.allocator, repo, legacy_id);
    defer resolved_canonical.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(canonical_duplicate_path, resolved_canonical.path);

    var latest_canonical = try latestPlanAddress(std.testing.allocator, repo);
    defer latest_canonical.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(legacy_id, latest_canonical.plan_id);
    try std.testing.expectEqualStrings(canonical_duplicate_path, latest_canonical.path);
}

test "create does not reuse a legacy flat plan id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);

    const legacy_id = "19700101T000001234567890Z-0000";
    const legacy_path = try planPathAlloc(std.testing.allocator, repo, legacy_id, .legacy);
    defer std.testing.allocator.free(legacy_path);
    try durable_store.writeTextCreateNewAtomic(std.testing.allocator, legacy_path, "# Legacy\n", .{});

    var created = try createPlanAtNs(std.testing.allocator, repo, "# Canonical\n", 1_234_567_890);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("19700101T000001234567890Z-0001", created.plan_id);
}

test "path resolution rejects traversal-shaped ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);

    try std.testing.expectError(error.InvalidPlanId, resolvePlanAddress(std.testing.allocator, repo, "../../escape"));
    try std.testing.expectError(error.PlanNotFound, resolvePlanAddress(std.testing.allocator, repo, "19700101T000001234567890Z-0000"));
}

test "create requires a template and path requires an id" {
    try std.testing.expectError(error.MissingTemplate, parseArgs(&.{ "ledger", "create" }));
    try std.testing.expectError(error.MissingPlanId, parseArgs(&.{ "ledger", "path" }));
    const parsed = try parseArgs(&.{ "ledger", "latest", "--format", "path", "--repo", "/tmp/repo" });
    try std.testing.expectEqual(Command.latest, parsed.command.?);
    try std.testing.expectEqual(OutputFormat.path, parsed.format);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.repo);
}
