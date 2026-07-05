const std = @import("std");
const commands = @import("../commands/mod.zig");
const lib = @import("../lib.zig");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const actuation_afr = @import("../actuation/afr.zig");
const actuation_gcr = @import("../actuation/gcr.zig");
const actuation_hylo = @import("../actuation/hylo.zig");

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

const HyloFixture = struct {
    name: []const u8,
    quality: []const u8,
    failure: ?[]const u8 = null,
    extra_failure: ?[]const u8 = null,
    true_runs: usize = 1,
    hylo_required: usize = 1,
    alsr_present: usize,
    hyl_present: usize,
    hsr_step_count: usize,
    terminal_atcg: usize,
};

const hylo_fixtures = [_]HyloFixture{
    .{ .name = "valid_direct_action_fused", .quality = "present_and_closed", .alsr_present = 0, .hyl_present = 0, .hsr_step_count = 0, .terminal_atcg = 1 },
    .{ .name = "valid_goal_grind_with_alsr_hyl_hsr", .quality = "present_and_closed", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "valid_resolve_three_clean_cas", .quality = "present_and_closed", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "valid_controller_governed_handoff", .quality = "present_and_closed", .alsr_present = 0, .hyl_present = 0, .hsr_step_count = 0, .terminal_atcg = 1 },
    .{ .name = "valid_parallel_review_class_fanout", .quality = "present_and_closed", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "valid_branch_race_common_verifier", .quality = "present_and_closed", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "missing_alsr", .quality = "partial", .failure = "missing_alsr", .alsr_present = 0, .hyl_present = 1, .hsr_step_count = 2, .terminal_atcg = 1 },
    .{ .name = "missing_hyl", .quality = "partial", .failure = "missing_hyl", .alsr_present = 1, .hyl_present = 0, .hsr_step_count = 2, .terminal_atcg = 1 },
    .{ .name = "missing_unfold", .quality = "present_verified", .failure = "missing_unfold", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 0 },
    .{ .name = "mutation_without_unfold", .quality = "present_and_closed", .failure = "mutation_without_unfold", .extra_failure = "missing_unfold", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "action_without_fold", .quality = "present_unverified", .failure = "action_without_fold", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 0 },
    .{ .name = "fold_without_current_artifact", .quality = "contradictory", .failure = "fold_without_current_artifact", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 0 },
    .{ .name = "continue_without_next_seed", .quality = "present_unverified", .failure = "continue_without_next_seed", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 0 },
    .{ .name = "terminal_without_stop_rule", .quality = "present_and_closed", .failure = "terminal_without_stop_rule", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "terminal_without_atcg", .quality = "present_verified", .failure = "terminal_without_atcg", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 0 },
    .{ .name = "stale_hylo_after_diff_change", .quality = "stale", .failure = "stale_hylo_after_diff_change", .extra_failure = "unfold_not_current", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "parallel_fanout_without_fanin", .quality = "present_verified", .failure = "parallel_fanout_without_fanin", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 0 },
    .{ .name = "raw_review_to_patch", .quality = "present_and_closed", .failure = "raw_review_to_patch", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "cached_cas_counted_as_fresh", .quality = "present_verified", .failure = "cached_cas_counted_as_fresh", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 0 },
    .{ .name = "resolve_without_review_fold", .quality = "present_and_closed", .failure = "resolve_without_review_fold", .alsr_present = 1, .hyl_present = 1, .hsr_step_count = 1, .terminal_atcg = 1 },
    .{ .name = "prompt_contamination_control", .quality = "absent", .true_runs = 0, .hylo_required = 0, .alsr_present = 0, .hyl_present = 0, .hsr_step_count = 0, .terminal_atcg = 0 },
};

fn fixturePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "testdata/actuation/hylo/{s}.jsonl", .{name});
}

fn refactorKernelFixturePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "testdata/actuation/refactor_kernel/{s}.jsonl", .{name});
}

fn expectJsonCount(allocator: std.mem.Allocator, got: []const u8, key: []const u8, count: usize) !void {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\": {d}", .{ key, count });
    defer allocator.free(needle);
    try expectContains(got, needle);
}

fn expectHyloFixture(allocator: std.mem.Allocator, fixture: HyloFixture) !void {
    const path = try fixturePath(allocator, fixture.name);
    defer allocator.free(path);
    const out_path = try std.fmt.allocPrint(allocator, ".zig-cache/actuation-hylo-{s}.json", .{fixture.name});
    defer allocator.free(out_path);
    const args = [_][]const u8{ "--path", path, "--mode", "hylo", "--format", "json" };
    const got = try runAndReadOutput(allocator, .actuation_audit, args[0..], out_path);
    defer allocator.free(got);

    try expectJsonCount(allocator, got, "true_runs", fixture.true_runs);
    try expectJsonCount(allocator, got, "hylo_required", fixture.hylo_required);
    try expectJsonCount(allocator, got, "alsr_present", fixture.alsr_present);
    try expectJsonCount(allocator, got, "hyl_present", fixture.hyl_present);
    try expectJsonCount(allocator, got, "hsr_step_count", fixture.hsr_step_count);
    try expectJsonCount(allocator, got, "atcg_after_terminal_fold", fixture.terminal_atcg);
    try expectJsonCount(allocator, got, fixture.quality, if (fixture.hylo_required == 1) 1 else 0);

    if (fixture.failure) |failure| {
        const needle = try std.fmt.allocPrint(allocator, "\"{s}\":1", .{failure});
        defer allocator.free(needle);
        try expectContains(got, needle);
    } else {
        try expectContains(got, "\"failure_classes\": {}");
    }
    if (fixture.extra_failure) |failure| {
        const needle = try std.fmt.allocPrint(allocator, "\"{s}\":1", .{failure});
        defer allocator.free(needle);
        try expectContains(got, needle);
    }
}

fn hyloFailureCovered(name: []const u8) bool {
    for (hylo_fixtures) |fixture| {
        if (fixture.failure) |failure| if (std.mem.eql(u8, failure, name)) return true;
        if (fixture.extra_failure) |failure| if (std.mem.eql(u8, failure, name)) return true;
    }
    return false;
}

fn fixtureByName(name: []const u8) ?HyloFixture {
    for (hylo_fixtures) |fixture| {
        if (std.mem.eql(u8, fixture.name, name)) return fixture;
    }
    return null;
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn jsonArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonIntField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |count| count,
        else => null,
    };
}

fn expectObjectField(obj: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = obj.get(key) orelse {
        std.debug.print("missing object field: {s}\n", .{key});
        return error.MissingExpectedField;
    };
    return jsonObject(value) orelse {
        std.debug.print("field is not object: {s}\n", .{key});
        return error.InvalidExpectedField;
    };
}

fn expectStringField(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return jsonStringField(obj, key) orelse {
        std.debug.print("missing string field: {s}\n", .{key});
        return error.MissingExpectedField;
    };
}

fn expectBoolField(obj: std.json.ObjectMap, key: []const u8) !bool {
    return jsonBoolField(obj, key) orelse {
        std.debug.print("missing bool field: {s}\n", .{key});
        return error.MissingExpectedField;
    };
}

fn expectNullableFailureMatches(obj: std.json.ObjectMap, fixture: HyloFixture) !void {
    const value = obj.get("expected_failure_class") orelse {
        std.debug.print("missing expected_failure_class for fixture {s}\n", .{fixture.name});
        return error.MissingExpectedField;
    };
    switch (value) {
        .null => {
            if (fixture.failure != null) return error.ManifestFixtureMismatch;
        },
        .string => |failure| {
            if (fixture.failure == null or !std.mem.eql(u8, fixture.failure.?, failure)) return error.ManifestFixtureMismatch;
        },
        else => return error.InvalidExpectedField,
    }
}

fn expectExtraFailureMatches(obj: std.json.ObjectMap, fixture: HyloFixture) !void {
    const value = obj.get("expected_failure_classes");
    if (fixture.extra_failure) |extra| {
        const array = if (value) |present| jsonArray(present) orelse return error.InvalidExpectedField else return error.MissingExpectedField;
        for (array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, extra)) return;
        }
        return error.ManifestFixtureMismatch;
    }
    if (value != null) return error.ManifestFixtureMismatch;
}

fn expectDetectionMatches(obj: std.json.ObjectMap, fixture: HyloFixture) !void {
    const detection = try expectObjectField(obj, "expected_detection");
    if ((try expectBoolField(detection, "alsr_present")) != (fixture.alsr_present > 0)) return error.ManifestFixtureMismatch;
    if ((try expectBoolField(detection, "hyl_present")) != (fixture.hyl_present > 0)) return error.ManifestFixtureMismatch;
    if ((jsonIntField(detection, "hsr_step_count") orelse return error.MissingExpectedField) != @as(i64, @intCast(fixture.hsr_step_count))) return error.ManifestFixtureMismatch;
    if ((try expectBoolField(detection, "terminal_atcg")) != (fixture.terminal_atcg > 0)) return error.ManifestFixtureMismatch;
}

fn validateHyloManifest(allocator: std.mem.Allocator) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "testdata/actuation/hylo/manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = jsonObject(parsed.value) orelse return error.InvalidManifest;
    const fixtures_value = root.get("fixtures") orelse return error.MissingExpectedField;
    const fixtures = jsonArray(fixtures_value) orelse return error.InvalidManifest;
    try std.testing.expectEqual(@as(usize, hylo_fixtures.len), fixtures.items.len);

    for (fixtures.items) |entry_value| {
        const entry = jsonObject(entry_value) orelse return error.InvalidManifest;
        const fixture_obj = try expectObjectField(entry, "fixture");
        const name = try expectStringField(fixture_obj, "name");
        const fixture = fixtureByName(name) orelse {
            std.debug.print("manifest fixture missing from test matrix: {s}\n", .{name});
            return error.ManifestFixtureMismatch;
        };
        try std.testing.expectEqualStrings(fixture.quality, try expectStringField(fixture_obj, "expected_quality"));
        try expectNullableFailureMatches(fixture_obj, fixture);
        try expectExtraFailureMatches(fixture_obj, fixture);
        _ = try expectStringField(fixture_obj, "transcript_excerpt");
        const artifact_state = try expectObjectField(fixture_obj, "artifact_state");
        _ = try expectStringField(artifact_state, "branch");
        _ = try expectStringField(artifact_state, "head");
        _ = try expectStringField(artifact_state, "diff_digest");
        try expectDetectionMatches(fixture_obj, fixture);
    }

    for (hylo_fixtures) |fixture| {
        var found = false;
        for (fixtures.items) |entry_value| {
            const entry = jsonObject(entry_value) orelse return error.InvalidManifest;
            const fixture_obj = try expectObjectField(entry, "fixture");
            if (std.mem.eql(u8, try expectStringField(fixture_obj, "name"), fixture.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("test matrix fixture missing from manifest: {s}\n", .{fixture.name});
            return error.ManifestFixtureMismatch;
        }
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
        "--mode",   "runs",
        "--format", "json",
    };
    const got = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], ".zig-cache/actuation-summary.json");
    defer std.testing.allocator.free(got);

    try expectContains(got, "\"session_id\":\"actuation-long-run\"");
    try expectContains(got, "\"true_actuating\":true");
    try expectContains(got, "\"verdict\":\"projection_inversion\"");
    try expectContains(got, "\"graph.compile_attempts\":21");
    try expectContains(got, "\"graph.compile_failures\":20");
    try expectContains(got, "\"graph.mutations_without_gcr\":1");
    try expectContains(got, "\"projection.update_plan_calls\":192");
    try expectContains(got, "\"surface.churn.apply_patch_calls\":1");
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

test "actuation audit hylo regression fixtures classify expected legal and failure states" {
    for (hylo_fixtures) |fixture| {
        try expectHyloFixture(std.testing.allocator, fixture);
    }
}

test "actuation audit hylo manifest mirrors regression fixture matrix" {
    try validateHyloManifest(std.testing.allocator);
}

test "actuation audit hylo fixture matrix covers every registered failure class" {
    for (actuation_hylo.failure_class_names) |name| {
        if (!hyloFailureCovered(name)) {
            std.debug.print("missing hylo failure fixture coverage: {s}\n", .{name});
            return error.MissingHyloFixtureCoverage;
        }
    }
}

test "actuation audit hylo json output is stable for every fixture run" {
    for (hylo_fixtures) |matrix_fixture| {
        const fixture = try fixturePath(std.testing.allocator, matrix_fixture.name);
        defer std.testing.allocator.free(fixture);
        const args = [_][]const u8{ "--path", fixture, "--mode", "hylo", "--format", "json" };
        const first_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/actuation-hylo-stable-{s}-a.json", .{matrix_fixture.name});
        defer std.testing.allocator.free(first_path);
        const second_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/actuation-hylo-stable-{s}-b.json", .{matrix_fixture.name});
        defer std.testing.allocator.free(second_path);
        const first = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], first_path);
        defer std.testing.allocator.free(first);
        const second = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], second_path);
        defer std.testing.allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    }
}

test "actuation audit hylo mode excludes prompt contamination fixture" {
    const args = [_][]const u8{ "--path", "testdata/actuation/hylo/prompt_contamination_control.jsonl", "--mode", "hylo", "--format", "json" };
    const got = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], ".zig-cache/actuation-hylo-contamination.json");
    defer std.testing.allocator.free(got);

    try expectContains(got, "\"true_runs\": 0");
    try expectContains(got, "\"hylo_required\": 0");
    try expectContains(got, "\"alsr_present\": 0");
    try expectContains(got, "\"hyl_present\": 0");
    try expectContains(got, "\"hsr_step_count\": 0");
    try expectContains(got, "\"terminal_folds\": 0");
    try expectContains(got, "\"atcg_after_terminal_fold\": 0");
    try expectContains(got, "\"failure_classes\": {}");
}

test "actuation audit renders refactor-kernel run fixture classifications" {
    const cases = [_]struct {
        name: []const u8,
        classification: []const u8,
        confidence: []const u8,
        hidden: bool = false,
    }{
        .{ .name = "explicit_hidden", .classification = "potential_hidden_refactor_kernel_explicit", .confidence = "high", .hidden = true },
        .{ .name = "inferred_hidden", .classification = "potential_hidden_refactor_kernel_inferred", .confidence = "medium", .hidden = true },
        .{ .name = "governed_complete", .classification = "governed_refactor_kernel", .confidence = "formal" },
        .{ .name = "governed_control_violation", .classification = "governed_refactor_kernel_with_control_violation", .confidence = "formal" },
        .{ .name = "decision_missing_outcome", .classification = "refactor_kernel_decision_missing_outcome", .confidence = "formal" },
        .{ .name = "large_unclassified", .classification = "large_graph_bypass_unclassified", .confidence = "low" },
        .{ .name = "ordinary_graph_bypass", .classification = "ordinary_graph_bypass", .confidence = "low" },
        .{ .name = "report_contamination", .classification = "none", .confidence = "none" },
    };

    for (cases) |case| {
        const path = try refactorKernelFixturePath(std.testing.allocator, case.name);
        defer std.testing.allocator.free(path);
        const out_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/actuation-rk-{s}.json", .{case.name});
        defer std.testing.allocator.free(out_path);
        const args = [_][]const u8{ "--path", path, "--mode", "runs", "--format", "json" };
        const got = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], out_path);
        defer std.testing.allocator.free(got);

        try expectContains(got, "\"refactor_kernel\"");
        const class_needle = try std.fmt.allocPrint(std.testing.allocator, "\"classification\":\"{s}\"", .{case.classification});
        defer std.testing.allocator.free(class_needle);
        try expectContains(got, class_needle);
        const conf_needle = try std.fmt.allocPrint(std.testing.allocator, "\"confidence\":\"{s}\"", .{case.confidence});
        defer std.testing.allocator.free(conf_needle);
        try expectContains(got, conf_needle);
        try expectContains(got, if (case.hidden) "\"potential_hidden_kernel\":true" else "\"potential_hidden_kernel\":false");
    }
}

test "actuation audit aggregates refactor-kernel summary json" {
    const args = [_][]const u8{ "--path", "testdata/actuation/refactor_kernel/explicit_hidden.jsonl", "--mode", "summary", "--format", "json" };
    const got = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], ".zig-cache/actuation-rk-summary.json");
    defer std.testing.allocator.free(got);

    try expectContains(got, "\"refactor_kernel\"");
    try expectContains(got, "\"potential_hidden_refactor_kernel_explicit\": 1");
    try expectContains(got, "\"potential_hidden_patch_calls\": 5");
    try expectContains(got, "\"potential_hidden_mutations_without_graph_control\": 5");
}

test "actuation audit excludes pasted skill blocks as true runs" {
    const fixture = ".zig-cache/actuation-pasted-skill.jsonl";
    try writePastedSkillFixture(fixture);

    const args = [_][]const u8{ "--path", fixture, "--mode", "runs", "--format", "json" };
    const got = try runAndReadOutput(std.testing.allocator, .actuation_audit, args[0..], ".zig-cache/actuation-pasted-skill-summary.json");
    defer std.testing.allocator.free(got);

    try expectContains(got, "\"session_id\":\"actuation-pasted-skill\"");
    try expectContains(got, "\"true_actuating\":false");
    try expectContains(got, "\"verdict\":\"insufficient_evidence\"");
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
        .command_text = try std.testing.allocator.dupe(u8, "gcr compile aperture"),
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
        .command_text = try std.testing.allocator.dupe(u8, "gcr compile aperture"),
        .output_text = try std.testing.allocator.dupe(u8, "{ \"graph_control_receipt\": { \"gcr_id\": \"GCR-2\", \"execution_allowed\": false, \"blocking_debt\": [] } }"),
        .exit_code = 0,
    });
    var denied_graph = try actuation_gcr.analyzeTrace(std.testing.allocator, denied_trace);
    defer denied_graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(actuation_gcr.AttemptResult.gate_fail, denied_graph.compile_attempts[0].result);
    try std.testing.expectEqual(actuation_gcr.GcrState.execution_denied, denied_graph.gcr_state_at_end);
}
