const std = @import("std");
const commands = @import("../commands/mod.zig");
const lib = @import("../lib.zig");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const actuation_afr = @import("../actuation/afr.zig");
const actuation_gcr = @import("../actuation/gcr.zig");

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
        \\{"type":"event_msg","timestamp":"2026-06-01T11:00:02Z","payload":{"type":"agent_message","turn_id":"t1","message":"<skill><name>actuating</name><body>$actuating example block with AFR-v1 and actuation_frontier</body></skill>"}}
        \\{"type":"event_msg","timestamp":"2026-06-01T11:00:03Z","payload":{"type":"task_complete","turn_id":"t1","duration_ms":1000}}
        \\
    );
    try out.flush();
}

fn writeHyloFixture(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir);
    }
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var file_writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const out = &file_writer.interface;
    try out.writeAll(
        \\{"type":"session_meta","timestamp":"2026-07-02T10:00:00Z","payload":{"id":"actuation-hylo-governed","cwd":"/repo/seq-audit","model":"gpt-5","git":{"branch":"feature/hylo","commit_hash":"base"}}}
        \\{"type":"event_msg","timestamp":"2026-07-02T10:00:01Z","payload":{"type":"task_started","turn_id":"t1"}}
        \\{"type":"event_msg","timestamp":"2026-07-02T10:00:02Z","payload":{"type":"user_message","turn_id":"t1","message":"$actuating implement governed feature. Detection markers: receipt_version: ALSR-v1 machine_version: HYL-v1 receipt_version: HSR-v1"}}
        \\{"type":"event_msg","timestamp":"2026-07-02T10:00:03Z","payload":{"type":"agent_message","turn_id":"t1","message":"agent_loop_scheme_receipt:\n  receipt_version: ALSR-v1\nactuation_hylomorphism:\n  machine_version: HYL-v1\nhylo_step_receipt:\n  receipt_version: HSR-v1\n  unfold:\n    produced: work_node\n  action:\n    effect: edit\n  fold:\n    verdict: complete\n    current_artifact_bound: yes\n  stop_rule:\n    success: done\nATCG-v1:\n  can_mark_goal_complete: yes"}}
        \\{"type":"response_item","timestamp":"2026-07-02T10:00:04Z","payload":{"type":"function_call","name":"apply_patch","call_id":"patch-1","arguments":"*** Begin Patch\n*** Update File: a\n+ok\n*** End Patch"}}
        \\{"type":"response_item","timestamp":"2026-07-02T10:00:05Z","payload":{"type":"function_call_output","call_id":"patch-1","output":"Success. Updated the following files:\nM a\n"}}
        \\{"type":"event_msg","timestamp":"2026-07-02T10:00:06Z","payload":{"type":"task_complete","turn_id":"t1","duration_ms":5000}}
        \\
    );
    try out.flush();
}

test "actuation audit regression fixture exposes projection inversion signals" {
    const fixture = "testdata/actuation/long-run-regression.jsonl";

    const args = [_][]const u8{
        "--path",   fixture,
        "--mode",   "summary",
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

    const filtered_query_spec =
        \\{"dataset":"actuation_runs","params":{"path":"testdata/actuation/long-run-regression.jsonl","repo":"/different/repo"},"select":["session_id"],"format":"json"}
    ;
    const filtered_query_args = [_][]const u8{ "--root", ".zig-cache", "--spec", filtered_query_spec };
    const filtered = try runAndReadOutput(std.testing.allocator, .query, filtered_query_args[0..], ".zig-cache/actuation-query-filtered.json");
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqualStrings("[\n]\n", filtered);
}

test "actuation audit hylo mode emits object-shaped governance summary" {
    const fixture = ".zig-cache/actuation-hylo-governed.jsonl";
    try writeHyloFixture(fixture);

    const args = [_][]const u8{ "--path", fixture, "--mode", "hylo", "--format", "json" };
    const got = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], ".zig-cache/actuation-hylo.json");
    defer std.testing.allocator.free(got);

    try expectContains(got, "\"true_runs\": 1");
    try expectContains(got, "\"hylo_required\": 1");
    try expectContains(got, "\"alsr_present\": 1");
    try expectContains(got, "\"hyl_present\": 1");
    try expectContains(got, "\"hsr_step_count\": 1");
    try expectContains(got, "\"mutations\": 1");
    try expectContains(got, "\"mutations_with_unfold\": 1");
    try expectContains(got, "\"actions_without_fold\": 0");
    try expectContains(got, "\"continues_without_next_state\": 0");
    try expectContains(got, "\"terminal_folds\": 1");
    try expectContains(got, "\"atcg_after_terminal_fold\": 1");
    try expectContains(got, "\"graph_bypass\": 0");
    try expectContains(got, "\"present_and_closed\": 1");
    try expectContains(got, "\"failure_classes\": {}");
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

test "actuation audit parses embedded artifacts and GCR edge cases" {
    const embedded =
        \\frontier:
        \\```json
        \\{"actuation_frontier":{"run_id":"run","slice_id":"slice","afr_id":"afr","graph_binding":{"gcr_id":"GCR-1"},"decision":{"selected_route":"route"}}}
        \\```
    ;
    var artifact = try actuation_afr.parseArtifact(std.testing.allocator, embedded);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(artifact.valid);
    try std.testing.expectEqual(actuation_afr.ArtifactKind.afr, artifact.kind);

    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/run.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"),
        .kind = .exec_command,
        .command_text = try std.testing.allocator.dupe(u8, "st compile aperture"),
        .output_text = try std.testing.allocator.dupe(u8, "{\"graph_control_receipt\":{\"gcr_id\":\"GCR-1\",\"execution_allowed\": true,\"blocking_debt\":[]}}"),
        .exit_code = 0,
    });
    try trace.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"),
        .kind = .patch_apply,
        .patch_success = false,
    });
    var graph = try actuation_gcr.analyzeTrace(std.testing.allocator, trace);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), graph.material_mutations);
    try std.testing.expectEqual(actuation_gcr.AttemptResult.pass, graph.compile_attempts[0].result);

    var denied_trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/denied.jsonl") };
    defer denied_trace.deinit(std.testing.allocator);
    try denied_trace.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/denied.jsonl"),
        .kind = .exec_command,
        .command_text = try std.testing.allocator.dupe(u8, "st compile aperture"),
        .output_text = try std.testing.allocator.dupe(u8, "{ \"graph_control_receipt\": { \"gcr_id\": \"GCR-2\", \"execution_allowed\": false, \"blocking_debt\": [] } }"),
        .exit_code = 0,
    });
    var denied_graph = try actuation_gcr.analyzeTrace(std.testing.allocator, denied_trace);
    defer denied_graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(actuation_gcr.AttemptResult.gate_fail, denied_graph.compile_attempts[0].result);
    try std.testing.expectEqual(actuation_gcr.GcrState.execution_denied, denied_graph.gcr_state_at_end);
}
