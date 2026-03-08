const std = @import("std");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");
const collector = @import("parse_arch_collector");
const eval_suite = @import("parse_arch_eval_suite");

const Version = core_cli.normalizeVersion(app_meta.version);

const UsageText =
    \\parse_arch.zig
    \\
    \\Marker: parse_arch.zig
    \\Infer repository architecture signals and validate the parse eval suite.
    \\
    \\Usage:
    \\  parse-arch <command> [options]
    \\
    \\Commands:
    \\  collect               Collect static architecture signals for a repository
    \\  eval                  Run the fixture-based collector eval suite
    \\  doctor                Verify suite path, repo path, and collect readiness
    \\
    \\Global options:
    \\  -h, --help            Show help
    \\  -V, --version         Show version
;

const Command = enum { collect, eval, doctor };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (try core_cli.handleDefaultHelpAndVersion(argv, UsageText, Version)) return;
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
    var focus_paths = std.ArrayList([]const u8).empty;
    var read_limit: usize = collector.default_read_limit;
    var repo_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (core_cli.isHelpArg(arg)) return printHelp();
        if (std.mem.eql(u8, arg, "--focus-path")) {
            i += 1;
            if (i >= args.len) return usageError("Missing value for", "--focus-path");
            try focus_paths.append(allocator, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--read-limit")) {
            i += 1;
            if (i >= args.len) return usageError("Missing value for", "--read-limit");
            read_limit = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return usageError("Unknown flag", arg);
        repo_path = arg;
    }
    const target = repo_path orelse return usageError("Missing repo_path", "collect");
    const payload = try collector.collect(allocator, target, .{ .focus_paths = focus_paths.items, .read_limit = read_limit });
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    try collector.writeJson(&stdout_writer.interface, payload);
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
    var stdout_writer = std.fs.File.stdout().writer(&.{});
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

    var stdout_writer = std.fs.File.stdout().writer(&.{});
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
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;
    try stderr.print("{s}: {s}\n", .{ prefix, value });
    try core_cli.printHelpWithVersion(stderr, UsageText, Version);
    std.process.exit(2);
}

fn printHelp() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    try core_cli.printHelpWithVersion(&stdout_writer.interface, UsageText, Version);
}
