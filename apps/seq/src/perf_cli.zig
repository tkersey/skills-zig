const std = @import("std");
const commands = @import("commands/mod.zig");
const lib = @import("lib.zig");

pub const CommandDef = lib.CommandDef;

pub fn commandNames() []const CommandDef {
    return lib.commandNames();
}

pub const PerfCase = enum {
    query_tool_calls,
    skill_success_rank,
    skill_audit,
    skill_blocks,
    tool_audit,
    memory_inventory,
    message_search,
    message_audit,
    skill_cohort,
    tool_search,
    memory_extension_audit,
    token_window,
    workdir_report,
    plan_search,
    reply_latency,
    sessions_limit,
    turns,
    session_detail,
    tool_lifecycle,
    session_graph,
    tail_once,
    token_cost,
    goal_audit,
    workflow_audit,
    memory_map,
    memory_history,
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
        .skill_success_rank => try runCommandWithOutput(allocator, .skill_success_rank, &.{
            "--root",   sessions_root,
            "--skill",  "seq",
            "--format", "json",
        }, output_path),
        .skill_audit => try runCommandWithOutput(allocator, .skill_audit, &.{
            "--root",   sessions_root,
            "--skill",  "seq",
            "--format", "json",
        }, output_path),
        .skill_blocks => try runCommandWithOutput(allocator, .skill_blocks, &.{
            "--path",    sample_path,
            "--skill",   "seq",
            "--history", "distinct",
            "--format",  "json",
        }, output_path),
        .tool_audit => try runCommandWithOutput(allocator, .tool_audit, &.{
            "--root",     sessions_root,
            "--group-by", "executable",
            "--format",   "json",
        }, output_path),
        .memory_inventory => {
            const memory_root = try seedMemoryPerfFixture(allocator, temp_root);
            defer allocator.free(memory_root);
            try runCommandWithOutput(allocator, .memory_inventory, &.{
                "--memory-root", memory_root,
                "--format",      "json",
            }, output_path);
        },
        .message_search => try runCommandWithOutput(allocator, .message_search, &.{
            "--root",     sessions_root,
            "--contains", "seq",
            "--format",   "json",
        }, output_path),
        .message_audit => try runCommandWithOutput(allocator, .message_audit, &.{
            "--root",     sessions_root,
            "--contains", "seq",
            "--format",   "json",
        }, output_path),
        .skill_cohort => try runCommandWithOutput(allocator, .skill_cohort, &.{
            "--root",   sessions_root,
            "--skill",  "seq",
            "--format", "json",
        }, output_path),
        .tool_search => try runCommandWithOutput(allocator, .tool_search, &.{
            "--root",     sessions_root,
            "--contains", "seq",
            "--mode",     "summary",
            "--format",   "json",
        }, output_path),
        .memory_extension_audit => {
            const memory_root = try seedMemoryPerfFixture(allocator, temp_root);
            defer allocator.free(memory_root);
            const extensions_root = try std.fs.path.join(allocator, &.{ memory_root, "extensions" });
            defer allocator.free(extensions_root);
            try runCommandWithOutput(allocator, .memory_extension_audit, &.{
                "--extensions-root", extensions_root,
                "--mode",            "rows",
                "--format",          "json",
            }, output_path);
        },
        .token_window => try runCommandWithOutput(allocator, .token_window, &.{
            "--root",         sessions_root,
            "--window-hours", "24",
            "--format",       "json",
        }, output_path),
        .workdir_report => try runCommandWithOutput(allocator, .workdir_report, &.{
            "--root",   sessions_root,
            "--format", "json",
        }, output_path),
        .plan_search => try runCommandWithOutput(allocator, .plan_search, &.{
            "--path",   sample_path,
            "--format", "json",
        }, output_path),
        .reply_latency => try runCommandWithOutput(allocator, .reply_latency, &.{
            "--path",   sample_path,
            "--format", "json",
        }, output_path),
        .sessions_limit => try runCommandWithOutput(allocator, .sessions, &.{
            "--root",   sessions_root,
            "--limit",  "5",
            "--format", "json",
        }, output_path),
        .turns => try runCommandWithOutput(allocator, .turns, &.{
            "--path",   sample_path,
            "--format", "json",
        }, output_path),
        .session_detail => try runCommandWithOutput(allocator, .session_detail, &.{
            "--path",          sample_path,
            "--include-tools", "--format",
            "json",
        }, output_path),
        .tool_lifecycle => try runCommandWithOutput(allocator, .tool_lifecycle, &.{
            "--path",   sample_path,
            "--format", "json",
        }, output_path),
        .session_graph => try runCommandWithOutput(allocator, .session_graph, &.{
            "--session-id", "019c0000-0000-7000-8000-000000000001",
            "--root",       sessions_root,
            "--format",     "json",
        }, output_path),
        .tail_once => try runCommandWithOutput(allocator, .tail, &.{
            "--path", sample_path,
            "--once", "--format",
            "jsonl",
        }, output_path),
        .token_cost => try runCommandWithOutput(allocator, .token_cost, &.{
            "--root",    sessions_root,
            "--pricing", "codex",
            "--format",  "json",
        }, output_path),
        .goal_audit => try runCommandWithOutput(allocator, .goal_audit, &.{
            "--root",   sessions_root,
            "--format", "json",
        }, output_path),
        .workflow_audit => try runCommandWithOutput(allocator, .workflow_audit, &.{
            "--root",     sessions_root,
            "--workflow", "seq",
            "--format",   "json",
        }, output_path),
        .memory_map => {
            const memory_root = try seedMemoryPerfFixture(allocator, temp_root);
            defer allocator.free(memory_root);
            try runCommandWithOutput(allocator, .memory_map, &.{
                "--memory-root", memory_root,
                "--contains",    "Perf",
                "--format",      "json",
            }, output_path);
        },
        .memory_history => {
            const memory_root = try seedMemoryPerfFixture(allocator, temp_root);
            defer allocator.free(memory_root);
            try runCommandWithOutput(allocator, .memory_history, &.{
                "--memory-root", memory_root,
                "--contains",    "Perf",
                "--format",      "json",
            }, output_path);
        },
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

fn seedMemoryPerfFixture(allocator: std.mem.Allocator, temp_root: []const u8) ![]u8 {
    const memory_root = try std.fs.path.join(allocator, &.{ temp_root, "memories" });
    errdefer allocator.free(memory_root);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), memory_root);

    const rollout_dir = try std.fs.path.join(allocator, &.{ memory_root, "rollout_summaries" });
    defer allocator.free(rollout_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), rollout_dir);
    const extensions_dir = try std.fs.path.join(allocator, &.{ memory_root, "extensions", "perf" });
    defer allocator.free(extensions_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), extensions_dir);

    const memory_file = try std.fs.path.join(allocator, &.{ memory_root, "MEMORY.md" });
    defer allocator.free(memory_file);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = memory_file,
        .data = "# Perf Memory\n\nPerf fixture body for seq memory-map and memory-history.\n",
    });
    const rollout_file = try std.fs.path.join(allocator, &.{ rollout_dir, "perf.md" });
    defer allocator.free(rollout_file);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = rollout_file,
        .data = "# Perf Rollout\n\nthread_id=perf-thread\nrollout_path=/tmp/perf-rollout.jsonl\n",
    });
    const extension_file = try std.fs.path.join(allocator, &.{ extensions_dir, "instructions.md" });
    defer allocator.free(extension_file);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = extension_file,
        .data = "# Perf Extension\n",
    });

    return memory_root;
}

test "runPerfCase covers promoted native seq families" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const cases = [_]PerfCase{
        .query_tool_calls,
        .skill_success_rank,
        .skill_audit,
        .skill_blocks,
        .tool_audit,
        .memory_inventory,
        .message_search,
        .message_audit,
        .skill_cohort,
        .tool_search,
        .memory_extension_audit,
        .token_window,
        .workdir_report,
        .plan_search,
        .reply_latency,
        .sessions_limit,
        .turns,
        .session_detail,
        .tool_lifecycle,
        .session_graph,
        .tail_once,
        .token_cost,
        .goal_audit,
        .workflow_audit,
        .memory_map,
        .memory_history,
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
