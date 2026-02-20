const std = @import("std");
const commands = @import("../commands/mod.zig");
const lib = @import("../lib.zig");

fn runAndReadOutput(
    allocator: std.mem.Allocator,
    cmd: lib.Command,
    args: []const []const u8,
    out_path: []const u8,
) ![]u8 {
    var all_args: std.ArrayList([]const u8) = .empty;
    defer all_args.deinit(allocator);

    try all_args.appendSlice(allocator, args);
    try all_args.append(allocator, "--output");
    try all_args.append(allocator, out_path);

    try commands.run(allocator, cmd, all_args.items);
    return std.fs.cwd().readFileAlloc(allocator, out_path, 1 * 1024 * 1024);
}

fn readExpected(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024);
}

test "golden role-breakdown json" {
    const args = [_][]const u8{
        "--root",
        "testdata/golden/sessions",
        "--format",
        "json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .role_breakdown, args[0..], ".zig-cache/golden-role-breakdown.json");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/role-breakdown.json");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden token-usage jsonl" {
    const args = [_][]const u8{
        "--root",
        "testdata/golden/sessions",
        "--format",
        "jsonl",
    };

    const got = try runAndReadOutput(std.testing.allocator, .token_usage, args[0..], ".zig-cache/golden-token-usage.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/token-usage.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden query tool-calls jsonl" {
    const args = [_][]const u8{
        "--root",
        "testdata/golden/sessions",
        "--spec",
        "@testdata/golden/query-tool-calls.json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .query, args[0..], ".zig-cache/golden-query-tool-calls.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/query-tool-calls.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden skill-trend mesh day json" {
    const args = [_][]const u8{
        "--root",
        "testdata/golden/sessions",
        "--skill",
        "mesh",
        "--bucket",
        "day",
        "--format",
        "json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .skill_trend, args[0..], ".zig-cache/golden-skill-trend-mesh-day.json");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/skill-trend-mesh-day.json");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}
