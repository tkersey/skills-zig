const std = @import("std");
const audit_module = @import("audit.zig");
const diff = @import("diff.zig");
const limits = @import("limits.zig");

const Io = std.Io.Threaded.global_single_threaded;

const usage =
    \\tiger_style
    \\
    \\Usage:
    \\  tiger_style audit-diff --base SHA --head SHA
    \\  tiger_style audit-files PATH...
    \\
    \\The diff mode audits all added Zig lines and fully audits new Zig files.
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_writer = std.Io.File.stdout().writer(Io.io(), &.{});
    const stdout = &stdout_writer.interface;
    var stderr_writer = std.Io.File.stderr().writer(Io.io(), &.{});
    const stderr = &stderr_writer.interface;

    if (argv.len < 2 or isHelp(argv[1])) {
        try stdout.writeAll(usage);
        return;
    }

    var audit = audit_module.Audit{};
    if (std.mem.eql(u8, argv[1], "audit-diff")) {
        const options = parseDiffOptions(argv) catch |err| {
            try stderr.print(
                "invalid audit-diff arguments: {s}\n\n{s}",
                .{ @errorName(err), usage },
            );
            std.process.exit(64);
        };
        try diff.run(allocator, init.io, stderr, options, &audit);
    } else if (std.mem.eql(u8, argv[1], "audit-files")) {
        try runAuditFiles(allocator, init.io, stderr, argv, &audit);
    } else {
        try stderr.print("unknown command: {s}\n\n{s}", .{ argv[1], usage });
        std.process.exit(64);
    }

    try writeSummary(stderr, audit);
    if (audit.diagnostics > 0) std.process.exit(2);
}

fn runAuditFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    argv: []const []const u8,
    audit: *audit_module.Audit,
) !void {
    if (argv.len < 3) {
        try writer.writeAll("audit-files requires at least one path\n\n");
        try writer.writeAll(usage);
        std.process.exit(64);
    }
    for (argv[2..]) |path| {
        try audit_module.file(allocator, io, writer, path, audit, true);
    }
}

fn isHelp(argument: []const u8) bool {
    return std.mem.eql(u8, argument, "--help") or
        std.mem.eql(u8, argument, "-h") or
        std.mem.eql(u8, argument, "help");
}

fn parseDiffOptions(argv: []const []const u8) !diff.Options {
    var base: ?[]const u8 = null;
    var head: ?[]const u8 = null;
    var index: usize = 2;

    while (index < argv.len) {
        const argument = argv[index];
        if (std.mem.eql(u8, argument, "--base")) {
            index += 1;
            if (index >= argv.len or base != null) return error.InvalidBase;
            base = argv[index];
        } else if (std.mem.eql(u8, argument, "--head")) {
            index += 1;
            if (index >= argv.len or head != null) return error.InvalidHead;
            head = argv[index];
        } else {
            return error.UnknownArgument;
        }
        index += 1;
    }

    if (base == null) return error.MissingBase;
    if (head == null) return error.MissingHead;
    if (!revisionValid(base.?)) return error.InvalidBase;
    if (!revisionValid(head.?)) return error.InvalidHead;
    return .{ .base = base.?, .head = head.? };
}

fn revisionValid(revision: []const u8) bool {
    if (revision.len == 0 or revision.len > limits.revision_bytes_max) return false;
    if (revision[0] == '-') return false;
    for (revision) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) return false;
    }
    return true;
}

fn writeSummary(writer: anytype, audit: audit_module.Audit) !void {
    if (audit.diagnostics == 0) {
        try writer.print(
            "TigerStyle passed: files={d} lines={d} diagnostics=0\n",
            .{ audit.files, audit.lines },
        );
    } else {
        try writer.print(
            "TigerStyle failed: files={d} lines={d} diagnostics={d}\n",
            .{ audit.files, audit.lines, audit.diagnostics },
        );
    }
}

test "diff options require one base and one head" {
    const valid = [_][]const u8{ "tiger_style", "audit-diff", "--base", "a", "--head", "b" };
    const options = try parseDiffOptions(&valid);
    try std.testing.expectEqualStrings("a", options.base);
    try std.testing.expectEqualStrings("b", options.head);

    const missing = [_][]const u8{ "tiger_style", "audit-diff", "--base", "a" };
    try std.testing.expectError(error.MissingHead, parseDiffOptions(&missing));

    const option = [_][]const u8{
        "tiger_style",
        "audit-diff",
        "--base",
        "--output=unsafe",
        "--head",
        "b",
    };
    try std.testing.expectError(error.InvalidBase, parseDiffOptions(&option));
}

test "revision validation covers the byte boundary" {
    const at_limit = [_]u8{'a'} ** limits.revision_bytes_max;
    const above_limit = [_]u8{'a'} ** (limits.revision_bytes_max + 1);
    try std.testing.expect(revisionValid(&at_limit));
    try std.testing.expect(!revisionValid(&above_limit));
    try std.testing.expect(!revisionValid("has space"));
    try std.testing.expect(!revisionValid(""));
}
