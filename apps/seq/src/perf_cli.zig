const std = @import("std");
const commands = @import("commands/mod.zig");
const lib = @import("lib.zig");

pub const CommandDef = lib.CommandDef;

pub fn commandNames() []const CommandDef {
    return lib.commandNames();
}

pub const PerfCase = enum {
    query_tool_calls,
    session_tooling,
    orchestration_concurrency,
    datasets,
    dataset_schema,
    artifact_search,
    find_session,
    session_prompts,
    query_diagnose,
    skills_rank,
    skill_trend,
    skill_report,
    role_breakdown,
    occurrence_export,
    report_bundle,
    section_audit,
    token_usage,
    routing_gap,
};

pub fn runPerfCase(allocator: std.mem.Allocator, perf_case: PerfCase, temp_root: []const u8) !void {
    const output_path = try std.fs.path.join(allocator, &.{ temp_root, "seq-perf-output.json" });
    defer allocator.free(output_path);

    const sessions_root = try resolveFixturePath(allocator, "testdata/golden/sessions");
    defer allocator.free(sessions_root);
    const sample_path = try resolveFixturePath(allocator, "testdata/golden/sessions/sample.jsonl");
    defer allocator.free(sample_path);
    const query_spec = try resolveFixturePath(allocator, "testdata/golden/query-tool-calls.json");
    defer allocator.free(query_spec);
    const routing_gap_spec = try resolveFixturePath(allocator, "testdata/golden/routing-gap-cues.json");
    defer allocator.free(routing_gap_spec);

    const query_spec_arg = try std.fmt.allocPrint(allocator, "@{s}", .{query_spec});
    defer allocator.free(query_spec_arg);
    const routing_gap_spec_arg = try std.fmt.allocPrint(allocator, "@{s}", .{routing_gap_spec});
    defer allocator.free(routing_gap_spec_arg);

    switch (perf_case) {
        .query_tool_calls => try runCommandWithOutput(allocator, .query, &.{
            "--root", sessions_root,
            "--spec", query_spec_arg,
        }, output_path),
        .session_tooling => try runCommandWithOutput(allocator, .session_tooling, &.{
            "--root",     sessions_root,
            "--summary",  "--group-by",
            "executable", "--format",
            "json",
        }, output_path),
        .orchestration_concurrency => try runCommandWithOutput(allocator, .orchestration_concurrency, &.{
            "--path",   sample_path,
            "--format", "json",
        }, output_path),
        .datasets => try runCommandWithOutput(allocator, .datasets, &.{}, output_path),
        .dataset_schema => try runCommandWithOutput(allocator, .dataset_schema, &.{
            "--dataset", "memory_blocks",
            "--format",  "json",
        }, output_path),
        .artifact_search => try runCommandWithOutput(allocator, .artifact_search, &.{
            "--path",     sample_path,
            "--surface",  "messages",
            "--contains", "learnings",
            "--limit",    "5",
            "--format",   "json",
        }, output_path),
        .find_session => try runCommandWithOutput(allocator, .find_session, &.{
            "--root",   sessions_root,
            "--prompt", "artifact-search",
            "--limit",  "5",
            "--format", "json",
        }, output_path),
        .session_prompts => try runCommandWithOutput(allocator, .session_prompts, &.{
            "--path",   sample_path,
            "--format", "json",
        }, output_path),
        .query_diagnose => try runCommandWithOutput(allocator, .query_diagnose, &.{
            "--path",   sample_path,
            "--format", "json",
        }, output_path),
        .skills_rank => try runCommandWithOutput(allocator, .skills_rank, &.{
            "--root",   sessions_root,
            "--format", "json",
        }, output_path),
        .skill_trend => try runCommandWithOutput(allocator, .skill_trend, &.{
            "--root",   sessions_root,
            "--skill",  "mesh",
            "--bucket", "day",
            "--format", "json",
        }, output_path),
        .skill_report => try runCommandWithOutput(allocator, .skill_report, &.{
            "--root",   sessions_root,
            "--skill",  "mesh",
            "--format", "json",
        }, output_path),
        .role_breakdown => try runCommandWithOutput(allocator, .role_breakdown, &.{
            "--root",   sessions_root,
            "--format", "json",
        }, output_path),
        .occurrence_export => try runCommandWithOutput(allocator, .occurrence_export, &.{
            "--root",   sessions_root,
            "--format", "json",
        }, output_path),
        .report_bundle => try runCommandWithOutput(allocator, .report_bundle, &.{
            "--root",   sessions_root,
            "--top",    "5",
            "--format", "json",
        }, output_path),
        .section_audit => try runCommandWithOutput(allocator, .section_audit, &.{
            "--root",     sessions_root,
            "--sections", "Counterexample,Invariants",
            "--format",   "json",
        }, output_path),
        .token_usage => try runCommandWithOutput(allocator, .token_usage, &.{
            "--root",   sessions_root,
            "--format", "json",
        }, output_path),
        .routing_gap => try runCommandWithOutput(allocator, .routing_gap, &.{
            "--cue-spec",         routing_gap_spec_arg,
            "--discovery-skills", "grill-me,prove-it,complexity-mitigator,invariant-ace,tk",
            "--root",             sessions_root,
            "--format",           "json",
        }, output_path),
    }
}

fn resolveFixturePath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), relative_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return std.fs.path.join(allocator, &.{ "apps/seq", relative_path }),
        else => return err,
    };
    return allocator.dupe(u8, relative_path);
}

fn runCommandWithOutput(
    allocator: std.mem.Allocator,
    cmd: lib.Command,
    args: []const []const u8,
    output_path: []const u8,
) !void {
    var all_args: std.ArrayList([]const u8) = .empty;
    defer all_args.deinit(allocator);

    try all_args.appendSlice(allocator, args);
    try all_args.append(allocator, "--output");
    try all_args.append(allocator, output_path);

    try commands.run(allocator, cmd, all_args.items);
}

test "runPerfCase covers promoted native seq families" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const cases = [_]PerfCase{
        .query_tool_calls,
        .session_tooling,
        .orchestration_concurrency,
        .datasets,
        .dataset_schema,
        .artifact_search,
        .find_session,
        .session_prompts,
        .query_diagnose,
        .skills_rank,
        .skill_trend,
        .skill_report,
        .role_breakdown,
        .occurrence_export,
        .report_bundle,
        .section_audit,
        .token_usage,
        .routing_gap,
    };

    for (cases) |perf_case| {
        try runPerfCase(std.testing.allocator, perf_case, root);
    }
}
