const std = @import("std");
const hctp = @import("hctp.zig");
const hctp_fold = @import("hctp_fold.zig");
const fixtures = @import("hctp_fixtures");

const fp_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const fp_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const fp_c = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const fp_d = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const fp_e = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ObjectRequired,
    };
}

fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |items| items,
        else => error.ArrayRequired,
    };
}

fn field(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.RequiredFieldMissing;
}

fn objectField(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(try field(map, key));
}

fn arrayField(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return array(try field(map, key));
}

fn stringField(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try field(map, key)) {
        .string => |text| text,
        else => error.StringRequired,
    };
}

fn numberField(map: std.json.ObjectMap, key: []const u8) !f64 {
    return switch (try field(map, key)) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        else => error.NumberRequired,
    };
}

fn integerField(map: std.json.ObjectMap, key: []const u8) !u64 {
    return switch (try field(map, key)) {
        .integer => |value| if (value >= 0) @intCast(value) else error.IntegerRequired,
        else => error.IntegerRequired,
    };
}

fn parseJson(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

fn replaceFirstAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const index = std.mem.indexOf(u8, bytes, needle) orelse return error.TestFixtureNeedleMissing;
    const result = try allocator.alloc(u8, bytes.len - needle.len + replacement.len);
    @memcpy(result[0..index], bytes[0..index]);
    @memcpy(result[index .. index + replacement.len], replacement);
    @memcpy(result[index + replacement.len ..], bytes[index + needle.len ..]);
    return result;
}

fn replaceCurrent(
    allocator: std.mem.Allocator,
    current: *[]u8,
    needle: []const u8,
    replacement: []const u8,
) !void {
    const next = try replaceFirstAlloc(allocator, current.*, needle, replacement);
    allocator.free(current.*);
    current.* = next;
}

fn replaceAllCurrent(
    allocator: std.mem.Allocator,
    current: *[]u8,
    needle: []const u8,
    replacement: []const u8,
) !void {
    const next = try std.mem.replaceOwned(u8, allocator, current.*, needle, replacement);
    allocator.free(current.*);
    current.* = next;
}

fn bodyAlloc(
    allocator: std.mem.Allocator,
    scenario_id: ?[]const u8,
    attempt_id: ?[]const u8,
    grade_id: ?[]const u8,
    payload_json: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"scenario_id\":");
    if (scenario_id) |value| try std.json.Stringify.value(value, .{}, &out.writer) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"attempt_id\":");
    if (attempt_id) |value| try std.json.Stringify.value(value, .{}, &out.writer) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"grade_id\":");
    if (grade_id) |value| try std.json.Stringify.value(value, .{}, &out.writer) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"payload\":");
    try out.writer.writeAll(payload_json);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn registerTrialBytes(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    trial_bytes: []const u8,
) !void {
    var trial = try parseJson(allocator, trial_bytes);
    defer trial.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, trial.value);
    defer allocator.free(fingerprint);
    const payload = try hctp.registrationPayloadAlloc(allocator, trial_bytes, fingerprint);
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyRegistered(allocator, state, parsed.value, 1, fp_a);
}

fn registerNullTrial(allocator: std.mem.Allocator, state: *hctp.CampaignTrials) !void {
    return registerTrialBytes(allocator, state, fixtures.valid_null_trial);
}

fn startNullLane(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    lane_id: []const u8,
    arm_id: []const u8,
    sequence: u64,
    event_digest: []const u8,
) !void {
    const trial = state.findTrial("trial-null-001") orelse return error.TestExpectedTrial;
    const lane = trial.findLane(lane_id) orelse return error.TestExpectedLane;
    const manifest = try hctp.laneManifestFingerprintAlloc(allocator, lane);
    defer allocator.free(manifest);
    const lease_digest = if (std.mem.eql(u8, arm_id, "arm-0")) fp_e else fp_d;
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"trial_id\":\"trial-null-001\",\"unit_id\":\"unit-null-001\",\"pair_id\":\"pair-null-001\",\"opaque_arm_id\":\"{s}\",\"lane_manifest_fingerprint\":\"{s}\",\"start_lease_digest\":\"{s}\",\"runner_id\":\"cas-trial\",\"runner_contract_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\",\"target_snapshot_fingerprint\":\"{s}\",\"presented_input_fingerprint\":\"sha256:3dbc2a117751f42078d15a82dab707eef4ac2c2b19a8addd9286a873fa6ffb65\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"model_configuration_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\"}}",
        .{ arm_id, manifest, lease_digest, fp_a },
    );
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, "scenario-holdout", lane_id, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyLaneStarted(allocator, state, parsed.value, sequence, event_digest);
}

fn rebindNativeReceiptFingerprint(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var parsed = try parseJson(allocator, bytes);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const native = try objectField(root, "native_receipt");
    const old_fingerprint = try stringField(native, "fingerprint");
    const new_fingerprint = try hctp.digestValueAlloc(allocator, try field(native, "receipt"));
    defer allocator.free(new_fingerprint);
    return std.mem.replaceOwned(u8, allocator, bytes, old_fingerprint, new_fingerprint);
}

fn runReceiptForNullLane(
    allocator: std.mem.Allocator,
    lane_id: []const u8,
    arm_id: []const u8,
    started_event_digest: []const u8,
) ![]u8 {
    var current = try allocator.dupe(u8, fixtures.valid_run_receipt);
    errdefer allocator.free(current);
    if (!std.mem.eql(u8, lane_id, "lane-null-a0")) {
        try replaceAllCurrent(allocator, &current, "lane-null-a0", lane_id);
        const quoted_arm = try std.fmt.allocPrint(allocator, "\"{s}\"", .{arm_id});
        defer allocator.free(quoted_arm);
        try replaceAllCurrent(allocator, &current, "\"arm-0\"", quoted_arm);
        try replaceCurrent(allocator, &current, fp_b, started_event_digest);
        try replaceAllCurrent(allocator, &current, fp_e, fp_d);
        try replaceAllCurrent(allocator, &current, "-a0", "-a1");
        const rebound = try rebindNativeReceiptFingerprint(allocator, current);
        allocator.free(current);
        current = rebound;
    }
    return current;
}

fn completeNullLane(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    lane_id: []const u8,
    arm_id: []const u8,
    start_sequence: u64,
    finish_sequence: u64,
    started_event_digest: []const u8,
) !void {
    try startNullLane(allocator, state, lane_id, arm_id, start_sequence, started_event_digest);
    const receipt_bytes = try runReceiptForNullLane(allocator, lane_id, arm_id, started_event_digest);
    defer allocator.free(receipt_bytes);
    var receipt = try parseJson(allocator, receipt_bytes);
    defer receipt.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, receipt.value);
    defer allocator.free(fingerprint);
    const canonical = try hctp.canonicalJsonAlloc(allocator, receipt.value);
    defer allocator.free(canonical);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"trial_id\":\"trial-null-001\",\"run_receipt_fingerprint\":\"{s}\",\"run_receipt\":{s}}}",
        .{ fingerprint, canonical },
    );
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, "scenario-holdout", lane_id, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyLaneFinished(allocator, state, parsed.value, finish_sequence);
}

fn gradeReceiptForNullLane(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    lane_id: []const u8,
    arm_id: []const u8,
) ![]u8 {
    const trial = state.findTrial("trial-null-001") orelse return error.TestExpectedTrial;
    const lane = trial.findLane(lane_id) orelse return error.TestExpectedLane;
    const run_fingerprint = lane.run_receipt_fingerprint orelse return error.TestExpectedReceipt;
    var current = try allocator.dupe(u8, fixtures.valid_grade_receipt);
    errdefer allocator.free(current);
    if (!std.mem.eql(u8, lane_id, "lane-null-a0")) {
        try replaceCurrent(allocator, &current, "lane-null-a0", lane_id);
        const quoted_arm = try std.fmt.allocPrint(allocator, "\"{s}\"", .{arm_id});
        defer allocator.free(quoted_arm);
        try replaceCurrent(allocator, &current, "\"arm-0\"", quoted_arm);
    }
    if (!std.mem.eql(u8, run_fingerprint, "sha256:13ae8140be81f58c193d22c75548f24f1d58bd7349b461f666f7f814b2ea6f9b")) {
        try replaceCurrent(
            allocator,
            &current,
            "sha256:13ae8140be81f58c193d22c75548f24f1d58bd7349b461f666f7f814b2ea6f9b",
            run_fingerprint,
        );
    }
    return current;
}

fn applyNullGrade(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    lane_id: []const u8,
    arm_id: []const u8,
    grade_id: []const u8,
    receipt_bytes: []const u8,
) !bool {
    var receipt = try parseJson(allocator, receipt_bytes);
    defer receipt.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, receipt.value);
    defer allocator.free(fingerprint);
    const canonical = try hctp.canonicalJsonAlloc(allocator, receipt.value);
    defer allocator.free(canonical);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"trial_id\":\"trial-null-001\",\"pair_id\":\"pair-null-001\",\"opaque_arm_id\":\"{s}\",\"grade_receipt_ref\":\"fixture:{s}\",\"grade_receipt_fingerprint\":\"{s}\",\"grade_receipt\":{s}}}",
        .{ arm_id, grade_id, fingerprint, canonical },
    );
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, "scenario-holdout", lane_id, grade_id, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    return hctp.applyAbsoluteGrade(allocator, state, parsed.value, 1.0, true, 0);
}

fn applyNullPairGrade(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    receipt_bytes: []const u8,
) !void {
    var receipt = try parseJson(allocator, receipt_bytes);
    defer receipt.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, receipt.value);
    defer allocator.free(fingerprint);
    const canonical = try hctp.canonicalJsonAlloc(allocator, receipt.value);
    defer allocator.free(canonical);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"trial_id\":\"trial-null-001\",\"pair_id\":\"pair-null-001\",\"pair_grade_receipt_fingerprint\":\"{s}\",\"pair_grade_receipt\":{s}}}",
        .{ fingerprint, canonical },
    );
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyPairGrade(allocator, state, parsed.value);
}

fn applyNullReveal(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    reveal_bytes: []const u8,
    sequence: u64,
) !void {
    var reveal = try parseJson(allocator, reveal_bytes);
    defer reveal.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, reveal.value);
    defer allocator.free(fingerprint);
    const canonical = try hctp.canonicalJsonAlloc(allocator, reveal.value);
    defer allocator.free(canonical);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"reveal_fingerprint\":\"{s}\",\"reveal\":{s}}}",
        .{ fingerprint, canonical },
    );
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyReveal(allocator, state, parsed.value, sequence);
}

fn completeAndGradeNullTrial(allocator: std.mem.Allocator, state: *hctp.CampaignTrials) !void {
    try completeNullLane(allocator, state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    const grade_a0 = try gradeReceiptForNullLane(allocator, state, "lane-null-a0", "arm-0");
    defer allocator.free(grade_a0);
    _ = try applyNullGrade(allocator, state, "lane-null-a0", "arm-0", "grade-null-a0", grade_a0);
    try completeNullLane(allocator, state, "lane-null-a1", "arm-1", 4, 5, fp_c);
    const grade_a1 = try gradeReceiptForNullLane(allocator, state, "lane-null-a1", "arm-1");
    defer allocator.free(grade_a1);
    _ = try applyNullGrade(allocator, state, "lane-null-a1", "arm-1", "grade-null-a1", grade_a1);
    try applyNullPairGrade(allocator, state, fixtures.valid_pair_grade_receipt);
}

const PairSpec = struct {
    pair_id: []const u8,
    unit_id: []const u8,
    split: []const u8,
    cluster_id: []const u8,
    baseline_score: f64,
    candidate_score: f64,
    baseline_critical: bool = false,
    candidate_critical: bool = false,
    candidate_oracle_status: []const u8 = "pass",
};

fn foldGradeAlloc(
    allocator: std.mem.Allocator,
    score: f64,
    critical: bool,
    oracle_status: []const u8,
) ![]u8 {
    const critical_json = if (critical)
        "[{\"violation_id\":\"critical-rule\",\"authority_kind\":\"trace_invariant\",\"authority_id\":\"critical-rule\",\"evidence_refs\":[\"artifact:trace\"]}]"
    else
        "[]";
    return std.fmt.allocPrint(
        allocator,
        "{{\"dimensions\":[{{\"id\":\"correctness\",\"score\":{d},\"grader_kind\":\"deterministic\"}}],\"derived_critical_violations\":{s},\"oracle_results\":[{{\"id\":\"required-test\",\"status\":\"{s}\"}}]}}",
        .{ score, critical_json, oracle_status },
    );
}

fn independentTrialJsonAlloc(allocator: std.mem.Allocator, base: []const u8) ![]u8 {
    var current = try allocator.dupe(u8, base);
    errdefer allocator.free(current);
    try replaceCurrent(allocator, &current, "\"mode\": \"composite\"", "\"mode\": \"independent_absolute\"");
    const marker = "\"judge_contracts\": [";
    const start = std.mem.indexOf(u8, current, marker) orelse return error.TestFixtureNeedleMissing;
    const end = std.mem.indexOfPos(u8, current, start, "],") orelse return error.TestFixtureNeedleMissing;
    const next = try std.mem.concat(allocator, u8, &.{
        current[0..start],
        "\"judge_contracts\": []",
        current[end + 1 ..],
    });
    allocator.free(current);
    current = next;
    return current;
}

fn manualTrialState(
    allocator: std.mem.Allocator,
    trial_json: []const u8,
    trial_id: []const u8,
    purpose: []const u8,
    specs: []const PairSpec,
) !hctp.CampaignTrials {
    var state = hctp.CampaignTrials{};
    errdefer state.deinit(allocator);
    var trial = hctp.TrialState{
        .id = try allocator.dupe(u8, trial_id),
        .fingerprint = try allocator.dupe(u8, fp_a),
        .purpose = try allocator.dupe(u8, purpose),
        .arm0_id = try allocator.dupe(u8, "arm-0"),
        .arm1_id = try allocator.dupe(u8, "arm-1"),
        .arm_map_commitment = try allocator.dupe(u8, fp_b),
        .trial_json = try allocator.dupe(u8, trial_json),
        .requires_pair_grade = false,
        .registration_sequence = 1,
        .registration_event_digest = try allocator.dupe(u8, fp_c),
        .calibration_sentinel_bindings_json = if (std.mem.eql(u8, purpose, "promotion"))
            try allocator.dupe(u8, "[]")
        else
            null,
        .revealed = true,
        .baseline_arm = try allocator.dupe(u8, "arm-0"),
        .candidate_arm = try allocator.dupe(u8, "arm-1"),
    };
    for (specs) |spec| {
        const baseline_lane_id = try std.fmt.allocPrint(allocator, "{s}-a0", .{spec.pair_id});
        errdefer allocator.free(baseline_lane_id);
        const candidate_lane_id = try std.fmt.allocPrint(allocator, "{s}-a1", .{spec.pair_id});
        errdefer allocator.free(candidate_lane_id);
        const baseline_grade_id = try std.fmt.allocPrint(allocator, "grade-{s}-a0", .{spec.pair_id});
        errdefer allocator.free(baseline_grade_id);
        const candidate_grade_id = try std.fmt.allocPrint(allocator, "grade-{s}-a1", .{spec.pair_id});
        errdefer allocator.free(candidate_grade_id);
        const baseline_grade = try foldGradeAlloc(allocator, spec.baseline_score, spec.baseline_critical, "pass");
        errdefer allocator.free(baseline_grade);
        const candidate_grade = try foldGradeAlloc(
            allocator,
            spec.candidate_score,
            spec.candidate_critical,
            spec.candidate_oracle_status,
        );
        errdefer allocator.free(candidate_grade);
        try trial.lanes.append(allocator, .{
            .id = baseline_lane_id,
            .unit_id = try allocator.dupe(u8, spec.unit_id),
            .scenario_id = try allocator.dupe(u8, spec.unit_id),
            .pair_id = try allocator.dupe(u8, spec.pair_id),
            .arm_id = try allocator.dupe(u8, "arm-0"),
            .status = .completed,
            .absolute_graded = true,
            .grade_id = baseline_grade_id,
            .grade_status = try allocator.dupe(u8, "pass"),
            .aggregate = spec.baseline_score,
            .grade_receipt_json = baseline_grade,
            .critical_failure_count = if (spec.baseline_critical) 1 else 0,
        });
        try trial.lanes.append(allocator, .{
            .id = candidate_lane_id,
            .unit_id = try allocator.dupe(u8, spec.unit_id),
            .scenario_id = try allocator.dupe(u8, spec.unit_id),
            .pair_id = try allocator.dupe(u8, spec.pair_id),
            .arm_id = try allocator.dupe(u8, "arm-1"),
            .status = .completed,
            .absolute_graded = true,
            .grade_id = candidate_grade_id,
            .grade_status = try allocator.dupe(u8, "pass"),
            .aggregate = spec.candidate_score,
            .grade_receipt_json = candidate_grade,
            .critical_failure_count = if (spec.candidate_critical or
                !std.mem.eql(u8, spec.candidate_oracle_status, "pass")) 1 else 0,
        });
        try trial.pairs.append(allocator, .{
            .id = try allocator.dupe(u8, spec.pair_id),
            .unit_id = try allocator.dupe(u8, spec.unit_id),
            .split = try allocator.dupe(u8, spec.split),
            .independence_cluster_id = try allocator.dupe(u8, spec.cluster_id),
            .repeat_index = 1,
        });
    }
    try state.trials.append(allocator, trial);
    return state;
}

fn resultFor(
    allocator: std.mem.Allocator,
    state: *const hctp.CampaignTrials,
) ![]u8 {
    return hctp_fold.resultAlloc(
        allocator,
        "cmp-test",
        fp_d,
        state,
        &state.trials.items[0],
        .{},
    );
}

fn resultForLifecycle(
    allocator: std.mem.Allocator,
    state: *const hctp.CampaignTrials,
    lifecycle_status: []const u8,
) ![]u8 {
    return hctp_fold.resultAlloc(
        allocator,
        "cmp-test",
        fp_d,
        state,
        &state.trials.items[0],
        .{ .lifecycle_status = lifecycle_status },
    );
}

test "36.25 rejects a grade before terminal completion" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try std.testing.expectError(
        error.GradeBeforeTerminal,
        applyNullGrade(
            std.testing.allocator,
            &state,
            "lane-null-a0",
            "arm-0",
            "grade-too-early",
            fixtures.valid_grade_receipt,
        ),
    );
}

test "36.26 rejects a grade after reveal" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeAndGradeNullTrial(std.testing.allocator, &state);
    try applyNullReveal(std.testing.allocator, &state, fixtures.valid_reveal, 6);
    const receipt = try gradeReceiptForNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0");
    defer std.testing.allocator.free(receipt);
    try std.testing.expectError(
        error.GradeAfterReveal,
        applyNullGrade(std.testing.allocator, &state, "lane-null-a0", "arm-0", "grade-after-reveal", receipt),
    );
}

test "36.27 rejects an absolute grade with semantic arm identity visible" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    const receipt = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_grade_receipt,
        "\"semantic_arm_identity_visible\": false",
        "\"semantic_arm_identity_visible\": true",
    );
    defer std.testing.allocator.free(receipt);
    try std.testing.expectError(
        error.GradeNotBlind,
        applyNullGrade(std.testing.allocator, &state, "lane-null-a0", "arm-0", "grade-leaked", receipt),
    );
}

test "36.28 rejects a pair grade before both siblings are terminal" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try std.testing.expectError(
        error.PairGradeBeforeSiblingsTerminal,
        applyNullPairGrade(std.testing.allocator, &state, fixtures.valid_pair_grade_receipt),
    );
}

test "36.29 rejects duplicate comparison-eligible pair grades" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a1", "arm-1", 4, 5, fp_c);
    try applyNullPairGrade(std.testing.allocator, &state, fixtures.valid_pair_grade_receipt);
    try std.testing.expectError(
        error.PairGradeDuplicate,
        applyNullPairGrade(std.testing.allocator, &state, fixtures.valid_pair_grade_receipt),
    );
}

test "36.30 rejects absolute grader authority drift" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    const receipt = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_grade_receipt,
        "\"id\": \"deterministic-grader\"",
        "\"id\": \"undeclared-grader\"",
    );
    defer std.testing.allocator.free(receipt);
    try std.testing.expectError(
        error.GradeReceiptInvalid,
        applyNullGrade(std.testing.allocator, &state, "lane-null-a0", "arm-0", "grade-authority-drift", receipt),
    );
}

test "pair grades bind the exact registered judge contract bytes" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a1", "arm-1", 4, 5, fp_c);
    const stale_contract = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_pair_grade_receipt,
        "sha256:9b296a9dec19da50db8597c607eef413f7d43fd173b9a8fd6d94075af9890432",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    defer std.testing.allocator.free(stale_contract);
    try std.testing.expectError(
        error.JudgeContractMismatch,
        applyNullPairGrade(std.testing.allocator, &state, stale_contract),
    );
}

test "HCTP absolute grading does not confuse estimand primary dimensions with the campaign rubric" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    const unrelated_dimension = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_grade_receipt,
        "\"id\": \"correctness\"",
        "\"id\": \"route_quality\"",
    );
    defer std.testing.allocator.free(unrelated_dimension);
    try std.testing.expect(try applyNullGrade(
        std.testing.allocator,
        &state,
        "lane-null-a0",
        "arm-0",
        "grade-campaign-rubric-dimension",
        unrelated_dimension,
    ));
}

test "36.31 rejects a free-form critical violation without frozen authority" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    const receipt = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_grade_receipt,
        "\"derived_critical_violations\": []",
        "\"derived_critical_violations\": [{\"violation_id\":\"free-form\",\"authority_kind\":\"free_form\",\"authority_id\":\"none\",\"evidence_refs\":[\"artifact:claim\"]}]",
    );
    defer std.testing.allocator.free(receipt);
    try std.testing.expectError(
        error.FreeFormCriticalViolationForbidden,
        applyNullGrade(std.testing.allocator, &state, "lane-null-a0", "arm-0", "grade-free-form", receipt),
    );
}

test "36.32 derives aggregate and pass-fail instead of trusting caller labels" {
    var aggregate_state = hctp.CampaignTrials{};
    defer aggregate_state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &aggregate_state);
    try completeNullLane(std.testing.allocator, &aggregate_state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    const mismatched_aggregate = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_grade_receipt,
        "\"dimensions\": [",
        "\"aggregate\": 0.0, \"dimensions\": [",
    );
    defer std.testing.allocator.free(mismatched_aggregate);
    try std.testing.expectError(
        error.GradeAggregateMismatch,
        applyNullGrade(std.testing.allocator, &aggregate_state, "lane-null-a0", "arm-0", "grade-bad-aggregate", mismatched_aggregate),
    );

    var label_state = hctp.CampaignTrials{};
    defer label_state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &label_state);
    try completeNullLane(std.testing.allocator, &label_state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    const false_failure = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_grade_receipt,
        "\"status\": \"pass\"",
        "\"status\": \"fail\"",
    );
    defer std.testing.allocator.free(false_failure);
    try std.testing.expectError(
        error.FailSatisfiesPassPolicy,
        applyNullGrade(std.testing.allocator, &label_state, "lane-null-a0", "arm-0", "grade-false-fail", false_failure),
    );

    var valid_state = hctp.CampaignTrials{};
    defer valid_state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &valid_state);
    try completeNullLane(std.testing.allocator, &valid_state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    try std.testing.expect(try applyNullGrade(
        std.testing.allocator,
        &valid_state,
        "lane-null-a0",
        "arm-0",
        "grade-derived",
        fixtures.valid_grade_receipt,
    ));
    const trial = valid_state.findTrial("trial-null-001") orelse return error.TestExpectedTrial;
    const lane = trial.findLane("lane-null-a0") orelse return error.TestExpectedLane;
    try std.testing.expectApproxEqAbs(@as(f64, 1), lane.aggregate orelse -1, 1e-12);
    try std.testing.expectEqualStrings("pass", lane.grade_status orelse "");
}

test "36.33 rejects a model judge as sole critical authority" {
    const trial = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_null_trial,
        "\"model_may_be_sole_critical_authority\": false",
        "\"model_may_be_sole_critical_authority\": true",
    );
    defer std.testing.allocator.free(trial);
    try std.testing.expectError(
        error.ModelSoleCriticalAuthority,
        hctp.validateTrialAlloc(std.testing.allocator, trial),
    );
}

test "36.34 rejects reveal before every required grade exists" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a1", "arm-1", 4, 5, fp_c);
    try std.testing.expectError(
        error.RevealBeforeGrades,
        applyNullReveal(std.testing.allocator, &state, fixtures.valid_reveal, 6),
    );
}

test "sealed grade commitment requires complete opening coverage" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try state.trials.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "trial-sealed-commitment"),
        .fingerprint = try std.testing.allocator.dupe(u8, fp_a),
        .purpose = try std.testing.allocator.dupe(u8, "promotion"),
        .arm0_id = try std.testing.allocator.dupe(u8, "arm-0"),
        .arm1_id = try std.testing.allocator.dupe(u8, "arm-1"),
        .arm_map_commitment = try std.testing.allocator.dupe(u8, fp_b),
        .trial_json = try std.testing.allocator.dupe(u8, "{}"),
        .requires_pair_grade = false,
        .requires_grade_commitments = true,
        .registration_sequence = 1,
        .registration_event_digest = try std.testing.allocator.dupe(u8, fp_c),
    });
    const trial = &state.trials.items[0];
    try trial.lanes.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "lane-sealed-commitment"),
        .unit_id = try std.testing.allocator.dupe(u8, "unit-sealed-commitment"),
        .scenario_id = try std.testing.allocator.dupe(u8, "scenario-sealed-commitment"),
        .pair_id = try std.testing.allocator.dupe(u8, "pair-sealed-commitment"),
        .arm_id = try std.testing.allocator.dupe(u8, "arm-0"),
        .status = .completed,
    });
    var reveal = try parseJson(
        std.testing.allocator,
        "{\"grade_openings\":[],\"grade_presentation_evidence\":[]}",
    );
    defer reveal.deinit();
    const reveal_object = try object(reveal.value);
    try std.testing.expectError(
        error.RevealBeforeGradeCommitments,
        hctp.gradeOpeningBodiesAlloc(std.testing.allocator, trial, reveal_object),
    );
    trial.lanes.items[0].grade_commitment_fingerprint = try std.testing.allocator.dupe(u8, fp_d);
    try std.testing.expectError(
        error.GradeOpeningCoverageMismatch,
        hctp.gradeOpeningBodiesAlloc(std.testing.allocator, trial, reveal_object),
    );
}

test "sealed grade commitment rejects an independent pair commitment without mutation" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{.{
        .pair_id = "pair-independent-commitment",
        .unit_id = "unit-independent-commitment",
        .split = "practice",
        .cluster_id = "cluster-independent-commitment",
        .baseline_score = 1.0,
        .candidate_score = 1.0,
    }};
    var state = try manualTrialState(
        std.testing.allocator,
        trial_json,
        "trial-independent-commitment",
        "practice_repair",
        &specs,
    );
    defer state.deinit(std.testing.allocator);
    const trial = &state.trials.items[0];
    trial.requires_grade_commitments = true;
    trial.revealed = false;
    const payload =
        "{\"trial_id\":\"trial-independent-commitment\",\"pair_id\":\"pair-independent-commitment\"," ++
        "\"grade_commitment_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"," ++
        "\"grade_commitment\":{}}";
    const body = try bodyAlloc(std.testing.allocator, null, null, null, payload);
    defer std.testing.allocator.free(body);
    var parsed = try parseJson(std.testing.allocator, body);
    defer parsed.deinit();
    try std.testing.expectError(
        error.PairGradeCommitmentNotRequired,
        hctp.applyPairGradeCommitment(std.testing.allocator, &state, parsed.value),
    );
    const pair = &trial.pairs.items[0];
    try std.testing.expect(pair.grade_commitment_fingerprint == null);
    try std.testing.expect(pair.grade_commitment_json == null);
    try std.testing.expect(pair.grade_commitment_key_id == null);
}

test "36.35 rejects a reveal with the wrong arm-map nonce" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeAndGradeNullTrial(std.testing.allocator, &state);
    const reveal = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_reveal,
        "00112233445566778899aabbccddeeff",
        "ffeeddccbbaa99887766554433221100",
    );
    defer std.testing.allocator.free(reveal);
    try std.testing.expectError(
        error.RevealCommitmentMismatch,
        applyNullReveal(std.testing.allocator, &state, reveal, 6),
    );
}

test "36.36 rejects reveal target fingerprints inconsistent with the committed mapping" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeAndGradeNullTrial(std.testing.allocator, &state);
    const reveal = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_reveal,
        "\"baseline_target_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"",
        "\"baseline_target_fingerprint\": \"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"",
    );
    defer std.testing.allocator.free(reveal);
    try std.testing.expectError(
        error.RevealTargetMismatch,
        applyNullReveal(std.testing.allocator, &state, reveal, 6),
    );
}

test "36.36 target snapshots reject a committed semantic inversion of before and after" {
    const nonce = "00112233445566778899aabbccddeeff";
    const arm_map_json =
        "{\"schema\":\"hylo-arm-map/v1\",\"trial_id\":\"trial-valid-001\"," ++
        "\"mapping\":{\"arm-0\":\"candidate\",\"arm-1\":\"baseline\"}," ++
        "\"nonce\":\"" ++ nonce ++ "\"}";
    var arm_map = try parseJson(std.testing.allocator, arm_map_json);
    defer arm_map.deinit();
    const commitment = try hctp.digestValueAlloc(std.testing.allocator, arm_map.value);
    defer std.testing.allocator.free(commitment);
    const trial_bytes = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "sha256:da53dc0c43de582545d4c0472985a7c9647141ea457178cdd3bb956946bb7a71",
        commitment,
    );
    defer std.testing.allocator.free(trial_bytes);
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerTrialBytes(std.testing.allocator, &state, trial_bytes);
    const trial = state.findTrial("trial-valid-001") orelse return error.TestExpectedTrial;
    for (trial.lanes.items) |*lane| {
        lane.status = .completed;
        lane.absolute_graded = true;
        lane.grade_status = try std.testing.allocator.dupe(u8, "pass");
    }
    for (trial.pairs.items) |*pair| pair.pair_graded = true;
    const reveal =
        "{\"schema\":\"hylo-trial-reveal/v1\",\"trial_id\":\"trial-valid-001\"," ++
        "\"mapping\":{\"arm-0\":\"candidate\",\"arm-1\":\"baseline\"}," ++
        "\"nonce\":\"" ++ nonce ++ "\"," ++
        "\"baseline_target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"candidate_target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"candidate_change_id\":\"change-001\",\"revealed_at_scope\":\"trial\"," ++
        "\"materialization_receipts\":[]}";
    try std.testing.expectError(
        error.RevealTargetMismatch,
        applyNullReveal(std.testing.allocator, &state, reveal, 6),
    );
    try std.testing.expect(!trial.revealed);
}

test "36.37 makes reveal irreversible" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeAndGradeNullTrial(std.testing.allocator, &state);
    try applyNullReveal(std.testing.allocator, &state, fixtures.valid_reveal, 6);
    try std.testing.expectError(
        error.RevealAlreadyRecorded,
        applyNullReveal(std.testing.allocator, &state, fixtures.valid_reveal, 7),
    );
    try std.testing.expectError(
        error.LaneStartAfterReveal,
        startNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 7, fp_d),
    );
}

test "HCTP pair grades bind exact sibling outputs and the presentation commitment" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerNullTrial(std.testing.allocator, &state);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a0", "arm-0", 2, 3, fp_b);
    try completeNullLane(std.testing.allocator, &state, "lane-null-a1", "arm-1", 4, 5, fp_c);

    const wrong_output = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_pair_grade_receipt,
        "\"left_output_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab\"",
        "\"left_output_fingerprint\": \"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"",
    );
    defer std.testing.allocator.free(wrong_output);
    try std.testing.expectError(
        error.PairGradeReceiptInvalid,
        applyNullPairGrade(std.testing.allocator, &state, wrong_output),
    );

    const wrong_commitment = try replaceFirstAlloc(
        std.testing.allocator,
        fixtures.valid_pair_grade_receipt,
        "sha256:8cabd2cbd17f12e545a8f013b3f007251d1676beea8f47cb3321004974d33af8",
        fp_a,
    );
    defer std.testing.allocator.free(wrong_commitment);
    try std.testing.expectError(
        error.PairGradeReceiptInvalid,
        applyNullPairGrade(std.testing.allocator, &state, wrong_commitment),
    );
}

test "36.38 reproduces pair unit cluster and split effects deterministically" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{
        .{ .pair_id = "pair-1", .unit_id = "unit-1", .split = "practice", .cluster_id = "cluster-1", .baseline_score = 0.2, .candidate_score = 0.8 },
        .{ .pair_id = "pair-2", .unit_id = "unit-1", .split = "practice", .cluster_id = "cluster-1", .baseline_score = 0.4, .candidate_score = 0.6 },
    };
    var state = try manualTrialState(std.testing.allocator, trial_json, "trial-valid-001", "practice_repair", &specs);
    defer state.deinit(std.testing.allocator);
    const first = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(first);
    const second = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    var parsed = try parseJson(std.testing.allocator, first);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const units = try arrayField(root, "unit_results");
    const unit_effects = try objectField(try object(units.items[0]), "effects");
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), try numberField(unit_effects, "correctness"), 1e-12);
    const clusters = try arrayField(root, "cluster_results");
    const cluster_effects = try objectField(try object(clusters.items[0]), "effects");
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), try numberField(cluster_effects, "correctness"), 1e-12);
    const practice = try objectField(try objectField(root, "split_results"), "practice");
    const correctness = try objectField(try objectField(practice, "dimensions"), "correctness");
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), try numberField(correctness, "effect"), 1e-12);
}

test "36.39 collapses repeats before independence-cluster inference" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{
        .{ .pair_id = "repeat-1", .unit_id = "unit-repeat", .split = "practice", .cluster_id = "cluster-repeat", .baseline_score = 0.1, .candidate_score = 0.9 },
        .{ .pair_id = "repeat-2", .unit_id = "unit-repeat", .split = "practice", .cluster_id = "cluster-repeat", .baseline_score = 0.9, .candidate_score = 0.1 },
    };
    var state = try manualTrialState(std.testing.allocator, trial_json, "trial-valid-001", "practice_repair", &specs);
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const root = try object(parsed.value);
    try std.testing.expectEqual(@as(usize, 1), (try arrayField(root, "unit_results")).items.len);
    try std.testing.expectEqual(@as(usize, 1), (try arrayField(root, "cluster_results")).items.len);
    const practice = try objectField(try objectField(root, "split_results"), "practice");
    try std.testing.expectEqual(@as(u64, 1), try integerField(practice, "independent_clusters"));
    const correctness = try objectField(try objectField(practice, "dimensions"), "correctness");
    try std.testing.expectApproxEqAbs(@as(f64, 0), try numberField(correctness, "effect"), 1e-12);
}

test "36.40 keeps practice and holdout denominators separate" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{
        .{ .pair_id = "practice-pair", .unit_id = "practice-unit", .split = "practice", .cluster_id = "practice-cluster", .baseline_score = 0.2, .candidate_score = 0.7 },
        .{ .pair_id = "holdout-pair", .unit_id = "holdout-unit", .split = "holdout", .cluster_id = "holdout-cluster", .baseline_score = 0.7, .candidate_score = 0.4 },
    };
    var state = try manualTrialState(std.testing.allocator, trial_json, "trial-valid-001", "practice_repair", &specs);
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const splits = try objectField(try object(parsed.value), "split_results");
    const practice = try objectField(splits, "practice");
    const holdout = try objectField(splits, "holdout");
    try std.testing.expectEqual(@as(u64, 1), try integerField(practice, "independent_clusters"));
    try std.testing.expectEqual(@as(u64, 1), try integerField(holdout, "independent_clusters"));
    const practice_correctness = try objectField(try objectField(practice, "dimensions"), "correctness");
    const holdout_correctness = try objectField(try objectField(holdout, "dimensions"), "correctness");
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try numberField(practice_correctness, "effect"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.3), try numberField(holdout_correctness, "effect"), 1e-12);
}

test "36.41 reports insufficient holdout evidence below the minimum cluster count" {
    var trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    try replaceCurrent(std.testing.allocator, &trial_json, "\"purpose\": \"practice_repair\"", "\"purpose\": \"promotion\"");
    try replaceCurrent(std.testing.allocator, &trial_json, "\"case_visibility\": \"open\"", "\"case_visibility\": \"case_blind\"");
    try replaceCurrent(std.testing.allocator, &trial_json, "\"required_level\": \"precommitted\"", "\"required_level\": \"sealed\"");
    try replaceCurrent(std.testing.allocator, &trial_json, "\"method\": \"none\"", "\"method\": \"cluster_bootstrap\"");
    try replaceCurrent(std.testing.allocator, &trial_json, "\"minimum_independent_clusters\": 1", "\"minimum_independent_clusters\": 2");
    const specs = [_]PairSpec{.{
        .pair_id = "holdout-one",
        .unit_id = "holdout-one",
        .split = "holdout",
        .cluster_id = "only-cluster",
        .baseline_score = 0.2,
        .candidate_score = 0.9,
    }};
    var state = try manualTrialState(std.testing.allocator, trial_json, "trial-valid-001", "promotion", &specs);
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const holdout = try objectField(try objectField(root, "split_results"), "holdout");
    try std.testing.expectEqual(@as(u64, 1), try integerField(holdout, "independent_clusters"));
    try std.testing.expectEqualStrings(
        "inconclusive",
        try stringField(try objectField(root, "claims"), "holdout_improvement"),
    );
    try std.testing.expectEqualStrings(
        "supported",
        try stringField(try objectField(root, "claims"), "absolute_qualification"),
    );
    try std.testing.expectEqualStrings(
        "inconclusive",
        try stringField(try objectField(root, "claims"), "noninferiority"),
    );
}

test "HCTP uncertainty floors preserve absolute qualification while gating inferential claims" {
    var trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    try replaceCurrent(std.testing.allocator, &trial_json, "\"method\": \"none\"", "\"method\": \"cluster_bootstrap\"");
    try replaceCurrent(std.testing.allocator, &trial_json, "\"minimum_independent_clusters\": 1", "\"minimum_independent_clusters\": 2");
    const specs = [_]PairSpec{.{
        .pair_id = "practice-one",
        .unit_id = "practice-one",
        .split = "practice",
        .cluster_id = "only-practice-cluster",
        .baseline_score = 0.2,
        .candidate_score = 0.9,
    }};
    var state = try manualTrialState(
        std.testing.allocator,
        trial_json,
        "trial-valid-001",
        "practice_repair",
        &specs,
    );
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const claims = try objectField(try object(parsed.value), "claims");
    try std.testing.expectEqualStrings("supported", try stringField(claims, "absolute_qualification"));
    try std.testing.expectEqualStrings("inconclusive", try stringField(claims, "noninferiority"));
    try std.testing.expectEqualStrings("inconclusive", try stringField(claims, "practice_gain"));
}

test "36.42 blocks qualification and reopens evidence after a critical regression" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{.{
        .pair_id = "critical-pair",
        .unit_id = "critical-unit",
        .split = "practice",
        .cluster_id = "critical-cluster",
        .baseline_score = 0.8,
        .candidate_score = 0.9,
        .candidate_critical = true,
    }};
    var state = try manualTrialState(std.testing.allocator, trial_json, "trial-valid-001", "practice_repair", &specs);
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const root = try object(parsed.value);
    try std.testing.expectEqual(@as(usize, 1), (try arrayField(root, "critical_regressions")).items.len);
    const claims = try objectField(root, "claims");
    try std.testing.expectEqualStrings("supported", try stringField(claims, "regression"));
    try std.testing.expectEqualStrings("unsupported", try stringField(claims, "absolute_qualification"));
}

test "36.43 rejects an improvement claim when the candidate only qualifies" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{.{
        .pair_id = "qualified-tie",
        .unit_id = "qualified-unit",
        .split = "practice",
        .cluster_id = "qualified-cluster",
        .baseline_score = 1.0,
        .candidate_score = 1.0,
    }};
    var state = try manualTrialState(std.testing.allocator, trial_json, "trial-valid-001", "practice_repair", &specs);
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const claims = try objectField(try object(parsed.value), "claims");
    try std.testing.expectEqualStrings("supported", try stringField(claims, "absolute_qualification"));
    try std.testing.expectEqualStrings("inconclusive", try stringField(claims, "practice_gain"));
    try std.testing.expectEqualStrings("unsupported", try stringField(claims, "regression"));
}

test "36.44 rejects holdout improvement without configured assurance and uncertainty" {
    var trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    try replaceCurrent(std.testing.allocator, &trial_json, "\"purpose\": \"practice_repair\"", "\"purpose\": \"promotion\"");
    const specs = [_]PairSpec{.{
        .pair_id = "weak-holdout",
        .unit_id = "weak-holdout-unit",
        .split = "holdout",
        .cluster_id = "weak-holdout-cluster",
        .baseline_score = 0.1,
        .candidate_score = 0.9,
    }};
    var state = try manualTrialState(std.testing.allocator, trial_json, "trial-valid-001", "promotion", &specs);
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const claims = try objectField(root, "claims");
    try std.testing.expectEqualStrings("supported", try stringField(claims, "absolute_qualification"));
    try std.testing.expectEqualStrings("inconclusive", try stringField(claims, "holdout_improvement"));
    try std.testing.expect(std.mem.indexOf(u8, result, "uncertainty interval not estimated") != null);
}

test "HCTP claim invariant: a candidate may qualify absolutely while materially regressing" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{.{
        .pair_id = "material-regression",
        .unit_id = "regression-unit",
        .split = "practice",
        .cluster_id = "regression-cluster",
        .baseline_score = 1.0,
        .candidate_score = 0.5,
    }};
    var state = try manualTrialState(
        std.testing.allocator,
        trial_json,
        "trial-valid-001",
        "practice_repair",
        &specs,
    );
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const claims = try objectField(try object(parsed.value), "claims");
    try std.testing.expectEqualStrings("supported", try stringField(claims, "absolute_qualification"));
    try std.testing.expectEqualStrings("supported", try stringField(claims, "regression"));
    try std.testing.expectEqualStrings("inconclusive", try stringField(claims, "noninferiority"));
}

test "HCTP qualification requires zero authoritative candidate critical failures even when baseline shares them" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{.{
        .pair_id = "shared-critical",
        .unit_id = "shared-critical-unit",
        .split = "practice",
        .cluster_id = "shared-critical-cluster",
        .baseline_score = 1.0,
        .candidate_score = 1.0,
        .baseline_critical = true,
        .candidate_critical = true,
    }};
    var state = try manualTrialState(
        std.testing.allocator,
        trial_json,
        "trial-valid-001",
        "practice_repair",
        &specs,
    );
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const root = try object(parsed.value);
    try std.testing.expectEqual(@as(usize, 0), (try arrayField(root, "critical_regressions")).items.len);
    const claims = try objectField(root, "claims");
    try std.testing.expectEqualStrings("unsupported", try stringField(claims, "absolute_qualification"));
}

test "HCTP non-completed trial closures cannot retain supported semantic claims" {
    const trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    const specs = [_]PairSpec{.{
        .pair_id = "favorable-invalid-close",
        .unit_id = "favorable-invalid-unit",
        .split = "practice",
        .cluster_id = "favorable-invalid-cluster",
        .baseline_score = 0.0,
        .candidate_score = 1.0,
    }};
    var state = try manualTrialState(
        std.testing.allocator,
        trial_json,
        "trial-valid-001",
        "practice_repair",
        &specs,
    );
    defer state.deinit(std.testing.allocator);
    inline for (.{ "invalid", "abandoned", "superseded" }) |lifecycle_status| {
        const result = try resultForLifecycle(std.testing.allocator, &state, lifecycle_status);
        defer std.testing.allocator.free(result);
        var parsed = try parseJson(std.testing.allocator, result);
        defer parsed.deinit();
        const claims = try objectField(try object(parsed.value), "claims");
        inline for (.{
            "absolute_qualification",
            "noninferiority",
            "practice_gain",
            "holdout_improvement",
            "regression",
            "mechanism_effect",
        }) |claim| {
            try std.testing.expect(!std.mem.eql(u8, try stringField(claims, claim), "supported"));
        }
    }
}

test "HCTP claim invariant: mechanism effects follow the registered direction without becoming practice gain" {
    var trial_json = try independentTrialJsonAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(trial_json);
    try replaceCurrent(
        std.testing.allocator,
        &trial_json,
        "\"predicted_direction\": \"candidate_better\"",
        "\"predicted_direction\": \"baseline_better\"",
    );
    const specs = [_]PairSpec{.{
        .pair_id = "mechanism-direction",
        .unit_id = "mechanism-unit",
        .split = "practice",
        .cluster_id = "mechanism-cluster",
        .baseline_score = 0.9,
        .candidate_score = 0.1,
    }};
    var state = try manualTrialState(
        std.testing.allocator,
        trial_json,
        "trial-valid-001",
        "mechanism_probe",
        &specs,
    );
    defer state.deinit(std.testing.allocator);
    const result = try resultFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(result);
    var parsed = try parseJson(std.testing.allocator, result);
    defer parsed.deinit();
    const claims = try objectField(try object(parsed.value), "claims");
    try std.testing.expectEqualStrings("supported", try stringField(claims, "mechanism_effect"));
    try std.testing.expectEqualStrings("inconclusive", try stringField(claims, "practice_gain"));
}
