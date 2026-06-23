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
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), out_path, allocator, .limited(2 * 1024 * 1024));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing substring: {s}\noutput:\n{s}\n", .{ needle, haystack });
        return error.MissingExpectedSubstring;
    }
}

fn writePastedSkillFixture(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir);
    }
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var file_writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const out = &file_writer.interface;
    try out.writeAll(
        \\{"type":"session_meta","timestamp":"2026-06-01T11:00:00Z","payload":{"id":"actuation-pasted-skill","cwd":"/repo/seq-audit","model":"gpt-5"}}
        \\{"type":"event_msg","timestamp":"2026-06-01T11:00:01Z","payload":{"type":"task_started","turn_id":"t1"}}
        \\{"type":"event_msg","timestamp":"2026-06-01T11:00:02Z","payload":{"type":"agent_message","turn_id":"t1","message":"<skill><name>actuating</name><body>$actuating example block</body></skill>"}}
        \\{"type":"event_msg","timestamp":"2026-06-01T11:00:03Z","payload":{"type":"task_complete","turn_id":"t1","duration_ms":1000}}
        \\
    );
    try out.flush();
}

test "actuation audit regression fixture exposes projection inversion signals" {
    const fixture = "testdata/actuation/long-run-regression.jsonl";

    const args = [_][]const u8{
        "--path", fixture,
        "--mode", "summary",
        "--format", "json",
    };
    const got = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], ".zig-cache/actuation-summary.json");
    defer std.testing.allocator.free(got);

    try expectContains(got, "\"session_id\": \"actuation-long-run\"");
    try expectContains(got, "\"true_actuating\": true");
    try expectContains(got, "\"verdict\": \"projection_inversion\"");
    try expectContains(got, "\"graph.compile_attempts\": 21");
    try expectContains(got, "\"graph.compile_failures\": 20");
    try expectContains(got, "\"graph.mutations_without_gcr\": 1");
    try expectContains(got, "\"projection.update_plan_calls\": 192");
    try expectContains(got, "\"surface.churn.apply_patch_calls\": 1");
}

test "actuation audit datasets expose lineage proof compaction and query rows" {
    const fixture = "testdata/actuation/long-run-regression.jsonl";

    const proof_args = [_][]const u8{ "--path", fixture, "--mode", "proof", "--format", "json" };
    const proofs = try runAndReadOutput(std.testing.allocator, .actuation_audit, proof_args[0..], ".zig-cache/actuation-proof.json");
    defer std.testing.allocator.free(proofs);
    try expectContains(proofs, "\"scope\": \"focused\"");
    try expectContains(proofs, "\"scope\": \"affected_aggregate\"");
    try expectContains(proofs, "\"scope\": \"full_closure\"");

    const compaction_args = [_][]const u8{ "--path", fixture, "--mode", "compactions", "--format", "json" };
    const compactions = try runAndReadOutput(std.testing.allocator, .actuation_audit, compaction_args[0..], ".zig-cache/actuation-compactions.json");
    defer std.testing.allocator.free(compactions);
    try expectContains(compactions, "\"compactions\": 1");
    try expectContains(compactions, "\"compactions_with_resume_artifact\": 1");
    try expectContains(compactions, "\"skill_reads_after_compaction\": 1");

    const slice_args = [_][]const u8{ "--path", fixture, "--mode", "slices", "--format", "json" };
    const slices = try runAndReadOutput(std.testing.allocator, .actuation_audit, slice_args[0..], ".zig-cache/actuation-slices.json");
    defer std.testing.allocator.free(slices);
    try expectContains(slices, "\"afr_valid\": true");
    try expectContains(slices, "\"valid_realizations\": 1");

    const query_spec =
        \\{"dataset":"actuation_runs","params":{"path":"testdata/actuation/long-run-regression.jsonl"},"where":[{"field":"verdict","op":"eq","value":"projection_inversion"}],"select":["session_id","graph.compile_failures","projection.update_plan_calls"],"format":"json"}
    ;
    const query_args = [_][]const u8{ "--root", ".zig-cache", "--spec", query_spec };
    const query_out = try runAndReadOutput(std.testing.allocator, .query, query_args[0..], ".zig-cache/actuation-query.json");
    defer std.testing.allocator.free(query_out);
    try expectContains(query_out, "\"session_id\": \"actuation-long-run\"");
    try expectContains(query_out, "\"graph.compile_failures\": 20");
    try expectContains(query_out, "\"projection.update_plan_calls\": 192");
}

test "actuation audit excludes pasted skill blocks as true runs" {
    const fixture = ".zig-cache/actuation-pasted-skill.jsonl";
    try writePastedSkillFixture(fixture);

    const args = [_][]const u8{ "--path", fixture, "--mode", "summary", "--format", "json" };
    const got = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], ".zig-cache/actuation-pasted-skill-summary.json");
    defer std.testing.allocator.free(got);

    try expectContains(got, "\"session_id\": \"actuation-pasted-skill\"");
    try expectContains(got, "\"true_actuating\": false");
    try expectContains(got, "\"verdict\": \"insufficient_evidence\"");
}
