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
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), out_path, allocator, .limited(1 * 1024 * 1024));
}

fn readExpected(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1 * 1024 * 1024));
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

test "golden routing-gap json" {
    const args = [_][]const u8{
        "--root",
        "testdata/golden/sessions",
        "--cue-spec",
        "@testdata/golden/routing-gap-cues.json",
        "--discovery-skills",
        "mesh",
        "--format",
        "json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .routing_gap, args[0..], ".zig-cache/golden-routing-gap.json");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/routing-gap.json");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden reply-latency default json" {
    const args = [_][]const u8{
        "--root",
        "testdata/golden/reply-latency/sessions",
        "--format",
        "json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .reply_latency, args[0..], ".zig-cache/golden-reply-latency-default.json");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/reply-latency-default.json");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden reply-latency contiguous jsonl" {
    const args = [_][]const u8{
        "--root",
        "testdata/golden/reply-latency/sessions",
        "--mode",
        "contiguous",
        "--format",
        "jsonl",
    };

    const got = try runAndReadOutput(std.testing.allocator, .reply_latency, args[0..], ".zig-cache/golden-reply-latency-contiguous.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/reply-latency-contiguous.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden opencode-prompts jsonl" {
    const args = [_][]const u8{
        "--source",
        "jsonl",
        "--opencode-path",
        "testdata/golden/opencode/prompt-history.jsonl",
        "--select",
        "source_kind,source_record_index,prompt_text,mode,parts_count,text_parts_count,file_parts_count,part_types,file_paths",
        "--format",
        "jsonl",
    };

    const got = try runAndReadOutput(std.testing.allocator, .opencode_prompts, args[0..], ".zig-cache/golden-opencode-prompts.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/opencode-prompts.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden query opencode-prompts jsonl" {
    const args = [_][]const u8{
        "--spec",
        "@testdata/golden/query-opencode-prompts.json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .query, args[0..], ".zig-cache/golden-query-opencode-prompts.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/query-opencode-prompts.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden opencode-events jsonl" {
    const args = [_][]const u8{
        "--source",
        "jsonl",
        "--opencode-path",
        "testdata/golden/opencode/prompt-history.jsonl",
        "--select",
        "source_kind,source_record_index,event_index,role,mode,part_type,text,text_len,filename",
        "--format",
        "jsonl",
    };

    const got = try runAndReadOutput(std.testing.allocator, .opencode_events, args[0..], ".zig-cache/golden-opencode-events.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/opencode-events.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden query opencode-events jsonl" {
    const args = [_][]const u8{
        "--spec",
        "@testdata/golden/query-opencode-events.json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .query, args[0..], ".zig-cache/golden-query-opencode-events.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/query-opencode-events.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden query opencode-tool-calls jsonl" {
    const args = [_][]const u8{
        "--spec",
        "@testdata/golden/query-opencode-tool-calls.json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .query, args[0..], ".zig-cache/golden-query-opencode-tool-calls.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/query-opencode-tool-calls.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}

test "golden query opencode-sessions jsonl" {
    const args = [_][]const u8{
        "--spec",
        "@testdata/golden/query-opencode-sessions.json",
    };

    const got = try runAndReadOutput(std.testing.allocator, .query, args[0..], ".zig-cache/golden-query-opencode-sessions.jsonl");
    defer std.testing.allocator.free(got);

    const expected = try readExpected(std.testing.allocator, "testdata/golden/expected/query-opencode-sessions.jsonl");
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, got);
}
