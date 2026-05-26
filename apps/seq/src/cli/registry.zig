const std = @import("std");
const lib = @import("../lib.zig");
const output = @import("../output/mod.zig");

pub const FlagValueKind = enum {
    bool,
    string,
    int,
    duration,
    csv,
    format,
    path,
    json_or_at_file,
};

pub const FlagSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    value_kind: FlagValueKind,
    required: bool = false,
    help: []const u8,
};

pub const CommandSpec = struct {
    name: []const u8,
    command: lib.Command,
    summary: []const u8,
    usage: []const u8,
    examples: []const []const u8 = &.{},
    flags: []const FlagSpec = &.{},
    default_format: output.Format = .table,
    allowed_formats: []const output.Format = &.{ .table, .json, .csv, .jsonl },
};

const query_flags = [_]FlagSpec{
    .{ .name = "--spec", .value_kind = .json_or_at_file, .required = true, .help = "Query spec JSON or @file" },
    .{ .name = "--root", .value_kind = .path, .help = "Codex sessions root" },
    .{ .name = "--stats", .value_kind = .bool, .help = "Emit SeqStats counters" },
};

const session_flags = [_]FlagSpec{
    .{ .name = "--root", .value_kind = .path, .help = "Codex sessions root" },
    .{ .name = "--limit", .value_kind = .int, .help = "Maximum rows" },
    .{ .name = "--stats", .value_kind = .bool, .help = "Emit SeqStats counters" },
};

pub fn commandNames() []const lib.CommandDef {
    return lib.commandNames();
}

pub fn parseCommand(name: []const u8) lib.Command {
    return lib.parseCommand(name);
}

pub fn commandName(command: lib.Command) []const u8 {
    return lib.commandName(command);
}

pub fn commandSpec(command: lib.Command) ?CommandSpec {
    if (command == .unknown) return null;
    const name = lib.commandName(command);
    if (std.mem.eql(u8, name, "unknown")) return null;
    return .{
        .name = name,
        .command = command,
        .summary = summaryFor(command),
        .usage = usageFor(command),
        .flags = flagsFor(command),
        .default_format = defaultFormatFor(command),
        .allowed_formats = allowedFormatsFor(command),
    };
}

fn summaryFor(command: lib.Command) []const u8 {
    return switch (command) {
        .query => "Run a dataset query spec over local session artifacts",
        .sessions => "List canonical session summaries",
        .turns => "List canonical session turns",
        .tool_lifecycle => "List canonical tool lifecycle records",
        .tail => "Tail the current or selected session",
        else => lib.commandName(command),
    };
}

fn usageFor(command: lib.Command) []const u8 {
    return switch (command) {
        .query => "seq query --spec <json|@path> [--root <path>] [--stats]",
        .sessions => "seq sessions [--root <path>] [--limit N] [--stats]",
        else => "seq <command> [options]",
    };
}

fn flagsFor(command: lib.Command) []const FlagSpec {
    return switch (command) {
        .query => query_flags[0..],
        .sessions => session_flags[0..],
        else => &.{},
    };
}

fn defaultFormatFor(command: lib.Command) output.Format {
    return switch (command) {
        .query => .jsonl,
        .sessions => .table,
        else => .table,
    };
}

fn allowedFormatsFor(command: lib.Command) []const output.Format {
    return switch (command) {
        .session_graph => &.{ .table, .json, .jsonl, .dot },
        .session_detail => &.{ .json, .markdown },
        .tail => &.{ .table, .jsonl },
        else => &.{ .table, .json, .csv, .jsonl },
    };
}

test "registry covers every command and parses names" {
    var seen = std.AutoHashMap(lib.Command, void).init(std.testing.allocator);
    defer seen.deinit();

    for (commandNames()) |def| {
        const entry = commandSpec(def.cmd) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(def.cmd, parseCommand(entry.name));
        try std.testing.expect(std.mem.eql(u8, entry.name, commandName(def.cmd)));
        try std.testing.expect(entry.usage.len > 0);
        try std.testing.expect(entry.summary.len > 0);
        try seen.put(def.cmd, {});
    }

    inline for (std.meta.fields(lib.Command)) |field| {
        const command: lib.Command = @enumFromInt(field.value);
        if (command == .unknown) continue;
        try std.testing.expect(seen.contains(command));
    }
}

test "registry exposes listed flags for query and sessions" {
    const query = commandSpec(.query) orelse return error.TestExpectedEqual;
    try std.testing.expect(query.flags.len >= 2);
    try std.testing.expect(std.mem.eql(u8, query.flags[0].name, "--spec"));
    try std.testing.expect(query.flags[0].required);

    const sessions = commandSpec(.sessions) orelse return error.TestExpectedEqual;
    var has_stats = false;
    for (sessions.flags) |flag| {
        if (std.mem.eql(u8, flag.name, "--stats")) has_stats = true;
    }
    try std.testing.expect(has_stats);
}
