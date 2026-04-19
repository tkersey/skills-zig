const std = @import("std");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");
const collector = @import("parse_arch_collector");
const eval_suite = @import("parse_arch_eval_suite");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "parse-arch",
    .help_text = UsageText,
};

const UsageText =
    \\parse-arch
    \\
    \\Infer repository architecture signals and validate the parse eval suite.
    \\
    \\Usage:
    \\  parse-arch <command> [options]
    \\  parse-arch collect <repo_path> [--focus-path <path> ...] [--read-limit <n>] [--json] [--format json]
    \\  parse-arch collect --repo-path <repo_path> [--focus-path <path> ...] [--read-limit <n>] [--json] [--format json]
    \\  parse-arch collect --repo <repo_path> [--focus-path <path> ...] [--read-limit <n>] [--json] [--format json]
    \\  parse-arch doctor [--suite <path>] [--repo-path <repo_path>]
    \\
    \\Commands:
    \\  collect               Collect static architecture signals for a repository
    \\  eval                  Run the fixture-based collector eval suite
    \\  doctor                Verify suite path, repo path, and collect readiness
    \\
    \\Collect notes:
    \\  Output is always JSON.
    \\  Use exactly one repo selector: positional <repo_path>, --repo-path, or --repo.
    \\
    \\Global options:
    \\  -h, --help            Show help
    \\  -V, --version         Show version
;

const Command = enum { collect, eval, doctor };
const CollectArgs = struct {
    focus_paths: []const []const u8,
    read_limit: usize,
    repo_path: []const u8,
};

const CollectParseFailure = union(enum) {
    ambiguous_repo_source: []const u8,
    invalid_read_limit: []const u8,
    missing_repo_path: void,
    missing_value: []const u8,
    unknown_flag: []const u8,
    unsupported_format: []const u8,
};

const CollectParseResult = union(enum) {
    help: void,
    ok: CollectArgs,
    err: CollectParseFailure,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;
    const command = resolveCommand(argv[1]) orelse return usageError("Unknown command", argv[1]);
    switch (command) {
        .collect => try cmdCollect(allocator, argv[2..]),
        .eval => try cmdEval(allocator, argv[2..]),
        .doctor => try cmdDoctor(allocator, argv[2..]),
    }
}

fn resolveCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "collect")) return .collect;
    if (std.mem.eql(u8, raw, "eval")) return .eval;
    if (std.mem.eql(u8, raw, "doctor")) return .doctor;
    return null;
}

fn cmdCollect(allocator: std.mem.Allocator, args: []const []const u8) !void {
    switch (try parseCollectArgs(allocator, args)) {
        .help => return printHelp(),
        .err => |failure| switch (failure) {
            .ambiguous_repo_source => |value| return usageError("Ambiguous repo_path source", value),
            .invalid_read_limit => |value| return usageError("Invalid value for --read-limit", value),
            .missing_repo_path => return usageError("Missing repo_path", "collect"),
            .missing_value => |value| return usageError("Missing value for", value),
            .unknown_flag => |value| return usageError("Unknown flag", value),
            .unsupported_format => |value| return usageError("Unsupported value for --format", value),
        },
        .ok => |parsed| {
            defer allocator.free(parsed.focus_paths);
            const payload = try collector.collect(allocator, parsed.repo_path, .{
                .focus_paths = parsed.focus_paths,
                .read_limit = parsed.read_limit,
            });
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try collector.writeJson(&stdout_writer.interface, payload);
        },
    }
}

fn parseCollectArgs(allocator: std.mem.Allocator, args: []const []const u8) !CollectParseResult {
    var focus_paths = std.ArrayList([]const u8).empty;
    var read_limit: usize = collector.default_read_limit;
    var repo_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (core_cli.isHelpArg(arg)) return .help;
        if (std.mem.eql(u8, arg, "--focus-path")) {
            i += 1;
            if (i >= args.len) return .{ .err = .{ .missing_value = "--focus-path" } };
            try focus_paths.append(allocator, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--read-limit")) {
            i += 1;
            if (i >= args.len) return .{ .err = .{ .missing_value = "--read-limit" } };
            read_limit = std.fmt.parseUnsigned(usize, args[i], 10) catch return .{
                .err = .{ .invalid_read_limit = args[i] },
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--repo-path")) {
            i += 1;
            if (i >= args.len) return .{ .err = .{ .missing_value = "--repo-path" } };
            if (repo_path != null) return .{ .err = .{ .ambiguous_repo_source = arg } };
            repo_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i >= args.len) return .{ .err = .{ .missing_value = "--repo" } };
            if (repo_path != null) return .{ .err = .{ .ambiguous_repo_source = arg } };
            repo_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return .{ .err = .{ .missing_value = "--format" } };
            if (!std.mem.eql(u8, args[i], "json")) return .{ .err = .{ .unsupported_format = args[i] } };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return .{ .err = .{ .unknown_flag = arg } };
        if (repo_path != null) return .{ .err = .{ .ambiguous_repo_source = arg } };
        repo_path = arg;
    }
    return .{ .ok = .{
        .focus_paths = try focus_paths.toOwnedSlice(allocator),
        .read_limit = read_limit,
        .repo_path = repo_path orelse return .{ .err = .{ .missing_repo_path = {} } },
    } };
}

fn cmdEval(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var suite_path: []const u8 = eval_suite.default_suite;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (core_cli.isHelpArg(arg)) return printHelp();
        if (std.mem.eql(u8, arg, "--suite")) {
            i += 1;
            if (i >= args.len) return usageError("Missing value for", "--suite");
            suite_path = args[i];
            continue;
        }
        return usageError("Unknown flag", arg);
    }
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const rc = try eval_suite.runEval(allocator, &stdout_writer.interface, .{ .suite_path = suite_path });
    if (rc != 0) std.process.exit(rc);
}

fn cmdDoctor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var suite_path: []const u8 = eval_suite.default_suite;
    var repo_path: []const u8 = ".";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (core_cli.isHelpArg(arg)) return printHelp();
        if (std.mem.eql(u8, arg, "--suite")) {
            i += 1;
            if (i >= args.len) return usageError("Missing value for", "--suite");
            suite_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--repo-path")) {
            i += 1;
            if (i >= args.len) return usageError("Missing value for", "--repo-path");
            repo_path = args[i];
            continue;
        }
        return usageError("Unknown flag", arg);
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    var failed = false;

    _ = eval_suite.loadSuite(allocator, suite_path) catch {
        failed = true;
        try stdout.print("fail suite {s}\n", .{suite_path});
    };
    if (!failed) try stdout.print("ok suite {s}\n", .{suite_path});
    {
        _ = collector.collect(allocator, repo_path, .{}) catch {
            failed = true;
            try stdout.print("fail collect {s}\n", .{repo_path});
            if (failed) {
                try stdout.print("ok version {s}\n", .{Version});
                std.process.exit(1);
            }
        };
        try stdout.print("ok collect {s}\n", .{repo_path});
    }
    try stdout.print("ok version {s}\n", .{Version});
    if (failed) std.process.exit(1);
}

fn usageError(prefix: []const u8, value: []const u8) !void {
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    try stderr.print("{s}: {s}\n", .{ prefix, value });
    try core_cli.printHelpSurface(stderr, HelpSurface, Version);
    std.process.exit(2);
}

fn printHelp() !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
}

test "collect parser accepts alias forms and json flags" {
    const parsed = switch (try parseCollectArgs(std.testing.allocator, &.{
        "--repo-path",
        "/tmp/repo",
        "--focus-path",
        "src/root.zig",
        "--read-limit",
        "42",
        "--json",
        "--format",
        "json",
    })) {
        .ok => |ok| ok,
        else => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(parsed.focus_paths);

    try std.testing.expectEqualStrings("/tmp/repo", parsed.repo_path);
    try std.testing.expectEqual(@as(usize, 42), parsed.read_limit);
    try std.testing.expectEqual(@as(usize, 1), parsed.focus_paths.len);
    try std.testing.expectEqualStrings("src/root.zig", parsed.focus_paths[0]);
}

test "collect parser accepts --repo alias" {
    const parsed = switch (try parseCollectArgs(std.testing.allocator, &.{
        "--repo",
        "/tmp/repo",
    })) {
        .ok => |ok| ok,
        else => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(parsed.focus_paths);

    try std.testing.expectEqualStrings("/tmp/repo", parsed.repo_path);
    try std.testing.expectEqual(@as(usize, 0), parsed.focus_paths.len);
    try std.testing.expectEqual(collector.default_read_limit, parsed.read_limit);
}

test "collect parser rejects mixed repo selectors" {
    const parsed = try parseCollectArgs(std.testing.allocator, &.{
        "/tmp/repo",
        "--repo-path",
        "/tmp/other",
    });
    switch (parsed) {
        .err => |failure| switch (failure) {
            .ambiguous_repo_source => |value| try std.testing.expectEqualStrings("--repo-path", value),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "collect parser rejects non-json formats" {
    const parsed = try parseCollectArgs(std.testing.allocator, &.{
        "--repo-path",
        "/tmp/repo",
        "--format",
        "table",
    });
    switch (parsed) {
        .err => |failure| switch (failure) {
            .unsupported_format => |value| try std.testing.expectEqualStrings("table", value),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}
