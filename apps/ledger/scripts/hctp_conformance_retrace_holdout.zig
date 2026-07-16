const std = @import("std");
const hctp = @import("hctp.zig");
const hctp_fold = @import("hctp_fold.zig");
const retrace_core = @import("retrace_core");
const hctp_source = @import("hctp_source");
const fixtures = @import("hctp_fixtures");

const FingerprintA = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const FingerprintB = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const FingerprintC = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const PairProducerFingerprint = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
const DifferentPairProducerFingerprint = "sha256:9999999999999999999999999999999999999999999999999999999999999999";
const PairJudgeContract =
    "{\"schema\":\"hylo-judge-contract/v1\",\"contract_id\":\"blind-pair-judge-v1\",\"version\":\"v1\",\"kind\":\"model\",\"contract_ref\":\"artifact:blind-pair-judge-v1\",\"contract_fingerprint\":\"sha256:9b296a9dec19da50db8597c607eef413f7d43fd173b9a8fd6d94075af9890432\",\"contract\":{\"policy\":\"registered-primary-dimensions\",\"prompt_template\":\"blind-pair-v1\"}}";

const ValidFir =
    \\{"fork_inquiry_receipt":{
    \\"receipt_version":"FIR-v1","receipt_id":"FIR-lane-one-1","inquiry_id":"trial-one","lane_id":"lane-one",
    \\"source":{"source_episode_id":"session:one#turn:one","source_turn_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","lineage_mode":"rollout_transcript"},
    \\"fork":{"approval_policy":"never","anchor":{"temporal_horizon":"pre_decision","exact":true,"anchor_digest_expected":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","anchor_digest_observed":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},
    \\"inquiry":{"mode":"replay","status":"completed"},"answer":{"hindsight_available":false},
    \\"gate":{"lineage_valid":true,"anchor_valid":true,"permissions_valid":true,"approval_or_tool_request_observed":false,"hindsight_label_valid":true,"answer_complete":true,"receipt_valid":true}}}
;

const DcpTemplate =
    \\{"decision_context_packet":{
    \\"packet_version":"DCP-v2","packet_id":"DCP-placeholder",
    \\"source":{"session_id":"session-one","decision_id":"decision-one","source_episode_id":"session:one#turn:one"},
    \\"artifact_state":{"reconstructability":"transcript_only"},
    \\"episode":{"question":"Which route should be selected?","selected_route":"route-a","rejected_routes":[],"explicit_rationale":[],"explicit_assumptions":[],"evidence_refs":[],"tools_and_artifacts":[],"skills_and_instructions":[],"outcome_refs":[]},
    \\"turns":{"total_turns":3,"decision_turn_index":2,"decision_turn_id":"turn-two","first_outcome_turn_index":3,"source_turn_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    \\"anchors":{"pre_decision":{"available":true,"keep_through_turn_index":1,"drop_last_n_turns":2,"anchor_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"post_decision_pre_outcome":{"available":true,"keep_through_turn_index":2,"drop_last_n_turns":1,"anchor_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"outcome_aware":{"available":true,"keep_through_turn_index":3,"drop_last_n_turns":0,"anchor_digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}},
    \\"contamination":{"injected_skill_blocks":false,"generated_reports":false,"current_audit_prompt":false,"quoted_material":false},
    \\"limitations":[]}}
;

const CalibrationCase = enum { biased, insensitive, stale, inapplicable };

fn replaceExactAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (std.mem.count(u8, bytes, needle) != 1) return error.CanonicalFixtureShapeChanged;
    return std.mem.replaceOwned(u8, allocator, bytes, needle, replacement);
}

fn replaceOwnedExact(
    allocator: std.mem.Allocator,
    bytes: *[]u8,
    needle: []const u8,
    replacement: []const u8,
) !void {
    const next = try replaceExactAlloc(allocator, bytes.*, needle, replacement);
    allocator.free(bytes.*);
    bytes.* = next;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ExpectedObject,
    };
}

fn objectPtr(value: *std.json.Value) !*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*map| map,
        else => error.ExpectedObject,
    };
}

fn arrayPtr(value: *std.json.Value) !*std.json.Array {
    return switch (value.*) {
        .array => |*array| array,
        else => error.ExpectedArray,
    };
}

fn requiredObject(parent: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(parent.get(key) orelse return error.MissingField);
}

fn requiredString(parent: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (parent.get(key) orelse return error.MissingField) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn targetTrialJsonAlloc(allocator: std.mem.Allocator, model_grader: bool) ![]u8 {
    var bytes = try allocator.dupe(u8, fixtures.valid_trial);
    errdefer allocator.free(bytes);
    try replaceOwnedExact(
        allocator,
        &bytes,
        "\"purpose\": \"practice_repair\"",
        "\"purpose\": \"promotion\"",
    );
    if (model_grader) {
        try replaceOwnedExact(
            allocator,
            &bytes,
            "\"required_null_sentinel_refs\": []",
            "\"required_null_sentinel_refs\": [\"trial:null-sentinel\"]",
        );
        try replaceOwnedExact(
            allocator,
            &bytes,
            "\"required_positive_sentinel_refs\": []",
            "\"required_positive_sentinel_refs\": [\"trial:positive-sentinel\"]",
        );
    } else {
        try replaceOwnedExact(
            allocator,
            &bytes,
            "\"mode\": \"composite\"",
            "\"mode\": \"independent_absolute\"",
        );
        const marker = "\"judge_contracts\": [";
        const start = std.mem.indexOf(u8, bytes, marker) orelse return error.CanonicalFixtureShapeChanged;
        const end = std.mem.indexOfPos(u8, bytes, start, "],") orelse return error.CanonicalFixtureShapeChanged;
        const next = try std.mem.concat(allocator, u8, &.{
            bytes[0..start],
            "\"judge_contracts\": []",
            bytes[end + 1 ..],
        });
        allocator.free(bytes);
        bytes = next;
    }
    return bytes;
}

fn pairReceiptAlloc(
    allocator: std.mem.Allocator,
    preferred: []const u8,
    producer_fingerprint: []const u8,
) ![]u8 {
    const preferred_json = try std.fmt.allocPrint(allocator, "\"preferred\": \"{s}\"", .{preferred});
    defer allocator.free(preferred_json);
    const verdict_json = try std.fmt.allocPrint(
        allocator,
        "\"verdict\": {{\n    {s}",
        .{preferred_json},
    );
    defer allocator.free(verdict_json);
    var bytes = try replaceExactAlloc(
        allocator,
        fixtures.valid_pair_grade_receipt,
        "\"verdict\": {\n    \"preferred\": \"tie\"",
        verdict_json,
    );
    errdefer allocator.free(bytes);
    if (!std.mem.eql(u8, producer_fingerprint, PairProducerFingerprint)) {
        try replaceOwnedExact(allocator, &bytes, PairProducerFingerprint, producer_fingerprint);
    }
    return bytes;
}

fn calibrationStatusAlloc(allocator: std.mem.Allocator, which: CalibrationCase) ![]u8 {
    const model_grader = which != .inapplicable;
    const target_json = try targetTrialJsonAlloc(allocator, model_grader);
    defer allocator.free(target_json);
    const null_sentinel_json = try replaceExactAlloc(
        allocator,
        target_json,
        "\"purpose\": \"promotion\"",
        "\"purpose\": \"calibration_null\"",
    );
    defer allocator.free(null_sentinel_json);
    const positive_sentinel_json = try replaceExactAlloc(
        allocator,
        target_json,
        "\"purpose\": \"promotion\"",
        "\"purpose\": \"calibration_positive\"",
    );
    defer allocator.free(positive_sentinel_json);
    var grade_a1 = try replaceExactAlloc(
        allocator,
        fixtures.valid_grade_receipt,
        "lane-null-a0",
        "lane-null-a1",
    );
    defer allocator.free(grade_a1);
    try replaceOwnedExact(allocator, &grade_a1, "\"arm-0\"", "\"arm-1\"");

    const null_preference = if (which == .biased) "left" else "tie";
    const positive_preference = if (which == .insensitive) "tie" else "right";
    const sentinel_producer = if (which == .stale)
        DifferentPairProducerFingerprint
    else
        PairProducerFingerprint;
    const null_receipt = try pairReceiptAlloc(allocator, null_preference, sentinel_producer);
    defer allocator.free(null_receipt);
    const positive_receipt = try pairReceiptAlloc(allocator, positive_preference, sentinel_producer);
    defer allocator.free(positive_receipt);

    var target_lanes = [_]hctp.LaneState{
        .{
            .id = @constCast("lane-null-a0"),
            .unit_id = @constCast("unit-target"),
            .scenario_id = @constCast("scenario-target"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-0"),
            .status = .completed,
            .absolute_graded = true,
            .grade_id = @constCast("grade-target-a0"),
            .grade_status = @constCast("pass"),
            .aggregate = 1,
            .grade_receipt_json = @constCast(fixtures.valid_grade_receipt),
        },
        .{
            .id = @constCast("lane-null-a1"),
            .unit_id = @constCast("unit-target"),
            .scenario_id = @constCast("scenario-target"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-1"),
            .status = .completed,
            .absolute_graded = true,
            .grade_id = @constCast("grade-target-a1"),
            .grade_status = @constCast("pass"),
            .aggregate = 1,
            .grade_receipt_json = grade_a1,
        },
    };
    var target_pairs = [_]hctp.PairState{.{
        .id = @constCast("pair-null-001"),
        .unit_id = @constCast("unit-target"),
        .split = @constCast("holdout"),
        .independence_cluster_id = @constCast("cluster-target"),
        .repeat_index = 1,
        .pair_graded = model_grader,
        .pair_grade_receipt_json = if (model_grader)
            @constCast(fixtures.valid_pair_grade_receipt)
        else
            null,
    }};
    var sentinel_lanes = [_]hctp.LaneState{
        .{
            .id = @constCast("lane-null-a0"),
            .unit_id = @constCast("unit-sentinel"),
            .scenario_id = @constCast("scenario-sentinel"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-0"),
            .status = .completed,
            .absolute_graded = true,
            .grade_status = @constCast("pass"),
        },
        .{
            .id = @constCast("lane-null-a1"),
            .unit_id = @constCast("unit-sentinel"),
            .scenario_id = @constCast("scenario-sentinel"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-1"),
            .status = .completed,
            .absolute_graded = true,
            .grade_status = @constCast("pass"),
        },
    };
    var null_pairs = [_]hctp.PairState{.{
        .id = @constCast("pair-null-001"),
        .unit_id = @constCast("unit-null"),
        .split = @constCast("practice"),
        .independence_cluster_id = @constCast("cluster-null"),
        .repeat_index = 1,
        .pair_graded = true,
        .pair_grade_receipt_json = null_receipt,
    }};
    var positive_pairs = [_]hctp.PairState{.{
        .id = @constCast("pair-null-001"),
        .unit_id = @constCast("unit-positive"),
        .split = @constCast("practice"),
        .independence_cluster_id = @constCast("cluster-positive"),
        .repeat_index = 1,
        .pair_graded = true,
        .pair_grade_receipt_json = positive_receipt,
    }};

    const target = hctp.TrialState{
        .id = @constCast("target-promotion"),
        .fingerprint = @constCast(FingerprintA),
        .purpose = @constCast("promotion"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast(FingerprintB),
        .trial_json = target_json,
        .lanes = .{ .items = &target_lanes, .capacity = target_lanes.len },
        .pairs = .{ .items = &target_pairs, .capacity = target_pairs.len },
        .requires_pair_grade = model_grader,
        .registration_sequence = 3,
        .registration_event_digest = @constCast(FingerprintC),
        .revealed = true,
        .baseline_arm = @constCast("arm-0"),
        .candidate_arm = @constCast("arm-1"),
    };
    const null_sentinel = hctp.TrialState{
        .id = @constCast("null-sentinel"),
        .fingerprint = @constCast(FingerprintA),
        .purpose = @constCast("calibration_null"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast(FingerprintB),
        .trial_json = null_sentinel_json,
        .lanes = .{ .items = &sentinel_lanes, .capacity = sentinel_lanes.len },
        .pairs = .{ .items = &null_pairs, .capacity = null_pairs.len },
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast(FingerprintC),
        .revealed = true,
        .closed = true,
        .close_status = @constCast("completed"),
        .close_sequence = 2,
        .close_result_fingerprint = @constCast(FingerprintA),
        .close_result_chain_head = @constCast(FingerprintC),
        .baseline_arm = @constCast("arm-0"),
        .candidate_arm = @constCast("arm-1"),
    };
    const positive_sentinel = hctp.TrialState{
        .id = @constCast("positive-sentinel"),
        .fingerprint = @constCast(FingerprintA),
        .purpose = @constCast("calibration_positive"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast(FingerprintB),
        .trial_json = positive_sentinel_json,
        .lanes = .{ .items = &sentinel_lanes, .capacity = sentinel_lanes.len },
        .pairs = .{ .items = &positive_pairs, .capacity = positive_pairs.len },
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast(FingerprintC),
        .revealed = true,
        .closed = true,
        .close_status = @constCast("completed"),
        .close_sequence = 2,
        .close_result_fingerprint = @constCast(FingerprintB),
        .close_result_chain_head = @constCast(FingerprintC),
        .baseline_arm = @constCast("arm-0"),
        .candidate_arm = @constCast("arm-1"),
    };
    var trial_items = [_]hctp.TrialState{ target, null_sentinel, positive_sentinel };
    const trials = hctp.CampaignTrials{ .trials = .{ .items = &trial_items, .capacity = trial_items.len } };
    var target_value = try std.json.parseFromSlice(std.json.Value, allocator, target_json, .{});
    defer target_value.deinit();
    const sentinel_bindings = try hctp_fold.promotionSentinelBindingsAlloc(
        allocator,
        &trials,
        target_value.value,
        trial_items[0].registration_sequence,
    );
    defer allocator.free(sentinel_bindings);
    trial_items[0].calibration_sentinel_bindings_json = sentinel_bindings;
    const result = try hctp_fold.resultAlloc(
        allocator,
        "campaign-calibration",
        FingerprintB,
        &trials,
        &trial_items[0],
        .{},
    );
    defer allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    return allocator.dupe(
        u8,
        try requiredString(try requiredObject(try object(parsed.value), "calibration"), "status"),
    );
}

fn validDcpAlloc(allocator: std.mem.Allocator) ![]u8 {
    const packet_id = try retrace_core.dcp_schema.packetIdForTextExcludingPacketId(allocator, DcpTemplate);
    defer allocator.free(packet_id);
    const dcp = try replaceExactAlloc(allocator, DcpTemplate, "DCP-placeholder", packet_id);
    var report = try retrace_core.dcp_schema.validateText(allocator, dcp);
    defer report.deinit(allocator);
    if (!report.valid) return error.CanonicalDcpInvalid;
    return dcp;
}

fn historicalPromotionAlloc(
    allocator: std.mem.Allocator,
    governance_state: []const u8,
    replay_allowed: bool,
    temporal_horizon: []const u8,
    retrace_mode: []const u8,
    source_target_text_policy: []const u8,
    source_target_text_outside_anchor: bool,
) ![]u8 {
    const dcp = try validDcpAlloc(allocator);
    defer allocator.free(dcp);
    const allowed_modes = if (replay_allowed) "[\"replay\"]" else "[]";
    var sgg_writer: std.Io.Writer.Allocating = .init(allocator);
    defer sgg_writer.deinit();
    try sgg_writer.writer.writeAll("{\"source_governance_gate\":{\"gate_version\":\"SGG-v1\",\"source_ref\":\"session:one#turn:one\",\"source_episode_id\":\"session:one#turn:one\",\"verdict\":{\"state\":");
    try std.json.Stringify.value(governance_state, .{}, &sgg_writer.writer);
    try sgg_writer.writer.writeAll(",\"replay_allowed\":");
    try sgg_writer.writer.writeAll(if (replay_allowed) "true" else "false");
    try sgg_writer.writer.writeAll(",\"allowed_modes\":");
    try sgg_writer.writer.writeAll(allowed_modes);
    try sgg_writer.writer.writeAll("}}}");
    const sgg = try sgg_writer.toOwnedSlice();
    defer allocator.free(sgg);
    var sgg_parsed = try std.json.parseFromSlice(std.json.Value, allocator, sgg, .{});
    defer sgg_parsed.deinit();
    const sgg_fingerprint = try hctp.digestValueAlloc(allocator, sgg_parsed.value);
    defer allocator.free(sgg_fingerprint);
    var dcp_parsed = try std.json.parseFromSlice(std.json.Value, allocator, dcp, .{});
    defer dcp_parsed.deinit();
    const dcp_fingerprint = try hctp.digestValueAlloc(allocator, dcp_parsed.value);
    defer allocator.free(dcp_fingerprint);
    const outside_anchor = if (source_target_text_outside_anchor)
        ",\"source_target_text_outside_anchor\":true"
    else
        "";
    const profile = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"historical_decision\",\"source_governance_ref\":\"artifact:sgg\",\"source_governance_fingerprint\":\"{s}\",\"source_governance\":{s},\"decision_context_ref\":\"artifact:dcp\",\"decision_context_fingerprint\":\"{s}\",\"decision_context\":{s},\"temporal_horizon\":\"{s}\",\"source_target_text_policy\":\"{s}\"{s},\"retrace_mode\":\"{s}\",\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\",\"reconstructability\":\"transcript_only\",\"limitations\":[]}}",
        .{
            sgg_fingerprint,
            sgg,
            dcp_fingerprint,
            dcp,
            temporal_horizon,
            source_target_text_policy,
            outside_anchor,
            retrace_mode,
        },
    );
    defer allocator.free(profile);

    var trial_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        fixtures.valid_trial,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer trial_parsed.deinit();
    var profile_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        profile,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer profile_parsed.deinit();
    const root = try objectPtr(&trial_parsed.value);
    try root.put(allocator, "purpose", .{ .string = "promotion" });
    const units = try arrayPtr(root.getPtr("units") orelse return error.MissingField);
    const unit = try objectPtr(&units.items[0]);
    try unit.put(allocator, "source_profile", profile_parsed.value);
    return hctp.canonicalJsonAlloc(allocator, trial_parsed.value);
}

fn revealBodyAlloc(allocator: std.mem.Allocator, reveal_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reveal_json, .{});
    defer parsed.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, parsed.value);
    defer allocator.free(fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{{\"scenario_id\":null,\"attempt_id\":null,\"grade_id\":null,\"payload\":{{\"reveal_fingerprint\":\"{s}\",\"reveal\":{s}}}}}",
        .{ fingerprint, reveal_json },
    );
}

fn case55SealedAssuranceAlloc(allocator: std.mem.Allocator) ![]u8 {
    const seed = [_]u8{0x55} ** 32;
    const public_key = try retrace_core.hctp_attestation.publicKeyBase64Alloc(allocator, seed);
    defer allocator.free(public_key);
    const trust_policy = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"case-55-policy\",\"keys\":[{{\"key_id\":\"fixture-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"fixture-runner\"]}}],\"separation\":{{\"runner_and_pair_grader_distinct\":true,\"materializer_and_pair_grader_distinct\":true,\"human_confirmation_required_for_human_grade\":true}}}}",
        .{std.json.fmt(public_key, .{})},
    );
    defer allocator.free(trust_policy);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trust_policy, .{});
    defer parsed.deinit();
    const trust_policy_fingerprint = try hctp.digestValueAlloc(allocator, parsed.value);
    defer allocator.free(trust_policy_fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{{\"assurance\":{{\"required_level\":\"sealed\",\"trust_policy_ref\":\"artifact:case-55-policy\",\"trust_policy_fingerprint\":{f},\"trust_policy\":{s},\"required_distinct_roles\":[]}}}}",
        .{ std.json.fmt(trust_policy_fingerprint, .{}), trust_policy },
    );
}

fn completedRevealLanes() [2]hctp.LaneState {
    return .{
        .{
            .id = @constCast("lane-null-a0"),
            .unit_id = @constCast("unit-null-001"),
            .scenario_id = @constCast("scenario-holdout"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-0"),
            .status = .completed,
            .absolute_graded = true,
            .grade_status = @constCast("pass"),
            .runner_key_id = @constCast("runner-key-a0"),
            .grade_key_id = @constCast("grade-key-a0"),
        },
        .{
            .id = @constCast("lane-null-a1"),
            .unit_id = @constCast("unit-null-001"),
            .scenario_id = @constCast("scenario-holdout"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-1"),
            .status = .completed,
            .absolute_graded = true,
            .grade_status = @constCast("pass"),
            .runner_key_id = @constCast("runner-key-a1"),
            .grade_key_id = @constCast("grade-key-a1"),
        },
    };
}

fn completedRevealPairs() [1]hctp.PairState {
    return .{.{
        .id = @constCast("pair-null-001"),
        .unit_id = @constCast("unit-null-001"),
        .split = @constCast("practice"),
        .independence_cluster_id = @constCast("cluster-null-001"),
        .repeat_index = 1,
        .pair_graded = true,
        .grader_key_id = @constCast("pair-grader-key"),
        .pair_grade_receipt_json = @constCast(fixtures.valid_pair_grade_receipt),
    }};
}

test "HCTP conformance case 45: identical-arm null sentinel detects directional preference" {
    const status = try calibrationStatusAlloc(std.testing.allocator, .biased);
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("biased", status);
}

test "HCTP conformance case 46: positive sentinel detects evaluator insensitivity" {
    const status = try calibrationStatusAlloc(std.testing.allocator, .insensitive);
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("insensitive", status);
}

test "HCTP conformance case 47: mismatched pair-grader calibration is stale" {
    const status = try calibrationStatusAlloc(std.testing.allocator, .stale);
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("stale", status);
}

test "HCTP conformance case 48: deterministic-only promotion needs no model sentinels" {
    const status = try calibrationStatusAlloc(std.testing.allocator, .inapplicable);
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("inapplicable", status);
}

test "HCTP conformance case 49: incidental and absent SGG cannot support promotion replay" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    inline for (.{ "incidental", "absent" }) |governance_state| {
        const invalid = try historicalPromotionAlloc(
            allocator,
            governance_state,
            false,
            "pre_decision",
            "replay",
            "absent",
            false,
        );
        try std.testing.expectError(error.SourceGovernanceReplayForbidden, hctp.validateTrialAlloc(allocator, invalid));
    }
}

test "HCTP conformance case 50: outcome-aware DCP horizon is not blind replay" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const trial = try historicalPromotionAlloc(
        allocator,
        "authoritative",
        true,
        "outcome_aware",
        "replay",
        "absent",
        false,
    );
    try std.testing.expectError(error.OutcomeAwareDecisionContext, hctp.validateTrialAlloc(allocator, trial));
}

test "HCTP conformance case 51: FIR source anchor and lineage must match the lane" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ValidFir, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.FirLineageMismatch,
        retrace_core.hctp_adapter.validateFirForLane(
            std.testing.allocator,
            parsed.value,
            "lane-one",
            "thread_fork",
            FingerprintB,
        ),
    );
    try std.testing.expectError(
        error.FirAnchorMismatch,
        retrace_core.hctp_adapter.validateFirForLane(
            std.testing.allocator,
            parsed.value,
            "lane-one",
            "either",
            FingerprintC,
        ),
    );
}

test "HCTP conformance case 52: one lane receipt cannot hide a fork portfolio" {
    const portfolio = try replaceExactAlloc(
        std.testing.allocator,
        ValidFir,
        "{\"fork_inquiry_receipt\"",
        "{\"portfolio\":[],\"fork_inquiry_receipt\"",
    );
    defer std.testing.allocator.free(portfolio);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, portfolio, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.HiddenForkPortfolio,
        retrace_core.hctp_adapter.validateFirForLane(
            std.testing.allocator,
            parsed.value,
            "lane-one",
            "either",
            FingerprintB,
        ),
    );
}

test "HCTP conformance case 53: promotion execution accepts only Retrace replay mode" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    inline for (.{ "challenge", "compare", "retrospective" }) |mode| {
        const trial = try historicalPromotionAlloc(
            allocator,
            "authoritative",
            true,
            "pre_decision",
            mode,
            "absent",
            false,
        );
        if (std.mem.eql(u8, mode, "compare")) {
            try std.testing.expectError(error.RetraceCompareForbidden, hctp.validateTrialAlloc(allocator, trial));
        } else {
            try std.testing.expectError(error.RetracePromotionModeInvalid, hctp.validateTrialAlloc(allocator, trial));
        }
    }
}

test "HCTP conformance case 53b: every admitted historical profile is CAS replay executable" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const promotion = try historicalPromotionAlloc(
        allocator,
        "authoritative",
        true,
        "pre_decision",
        "challenge",
        "absent",
        false,
    );
    const practice = try replaceExactAlloc(
        allocator,
        promotion,
        "\"purpose\":\"promotion\"",
        "\"purpose\":\"practice_repair\"",
    );
    try std.testing.expectError(error.RetraceReplayRequired, hctp.validateTrialAlloc(allocator, practice));
}

test "HCTP conformance case 54: historical and arm-specific target instructions cannot coexist" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const trial = try historicalPromotionAlloc(
        allocator,
        "authoritative",
        true,
        "pre_decision",
        "replay",
        "preserve",
        false,
    );
    try std.testing.expectError(error.SourceTargetTextContamination, hctp.validateTrialAlloc(allocator, trial));
}

test "HCTP conformance case 55: sealed reveal requires one valid materializer receipt per lane" {
    var lanes = completedRevealLanes();
    var pairs = completedRevealPairs();
    const trial_json = try case55SealedAssuranceAlloc(std.testing.allocator);
    defer std.testing.allocator.free(trial_json);
    var trial_items = [_]hctp.TrialState{.{
        .id = @constCast("trial-null-001"),
        .fingerprint = @constCast(FingerprintA),
        .purpose = @constCast("promotion"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:12a363c4474b3da444d517dceed738aefc7c0dfd552d76209a3c3e65d1da0c4d"),
        .trial_json = trial_json,
        .lanes = .{ .items = &lanes, .capacity = lanes.len },
        .pairs = .{ .items = &pairs, .capacity = pairs.len },
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast(FingerprintB),
    }};
    var trials = hctp.CampaignTrials{ .trials = .{ .items = &trial_items, .capacity = 1 } };
    const body = try revealBodyAlloc(std.testing.allocator, fixtures.valid_reveal);
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.SealedMaterializationMissing,
        hctp.applyReveal(std.testing.allocator, &trials, parsed.value, 2),
    );
}

test "HCTP conformance case 56: campaign holdout reveal cannot occur scenario by scenario" {
    const campaign_scope = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_null_trial,
        "\"reveal_scope\": \"trial\"",
        "\"reveal_scope\": \"campaign_holdout\"",
    );
    defer std.testing.allocator.free(campaign_scope);
    var lanes = completedRevealLanes();
    var pairs = completedRevealPairs();
    var trial_items = [_]hctp.TrialState{.{
        .id = @constCast("trial-null-001"),
        .fingerprint = @constCast(FingerprintA),
        .purpose = @constCast("promotion"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:12a363c4474b3da444d517dceed738aefc7c0dfd552d76209a3c3e65d1da0c4d"),
        .trial_json = campaign_scope,
        .lanes = .{ .items = &lanes, .capacity = lanes.len },
        .pairs = .{ .items = &pairs, .capacity = pairs.len },
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast(FingerprintB),
    }};
    var trials = hctp.CampaignTrials{ .trials = .{ .items = &trial_items, .capacity = 1 } };
    const body = try revealBodyAlloc(std.testing.allocator, fixtures.valid_reveal);
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.RevealScopeInvalid, hctp.applyReveal(std.testing.allocator, &trials, parsed.value, 2));
}

test "HCTP supporting invariant: revealed trial state rejects further lane mutation" {
    // The exact post-holdout target-change guard is Hylo-owned and private to
    // hylo.zig. This is the strongest public HCTP assertion in this file; the
    // Hylo-owned conformance probe covers HoldoutRepairForbidden itself.
    var lanes = completedRevealLanes();
    var pairs = completedRevealPairs();
    var trial_items = [_]hctp.TrialState{.{
        .id = @constCast("trial-null-001"),
        .fingerprint = @constCast(FingerprintA),
        .purpose = @constCast("promotion"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:12a363c4474b3da444d517dceed738aefc7c0dfd552d76209a3c3e65d1da0c4d"),
        .trial_json = @constCast(fixtures.valid_null_trial),
        .lanes = .{ .items = &lanes, .capacity = lanes.len },
        .pairs = .{ .items = &pairs, .capacity = pairs.len },
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast(FingerprintB),
    }};
    defer {
        if (trial_items[0].baseline_arm) |value| std.testing.allocator.free(value);
        if (trial_items[0].candidate_arm) |value| std.testing.allocator.free(value);
        if (trial_items[0].reveal_json) |value| std.testing.allocator.free(value);
    }
    var trials = hctp.CampaignTrials{ .trials = .{ .items = &trial_items, .capacity = 1 } };
    const reveal_body = try revealBodyAlloc(std.testing.allocator, fixtures.valid_reveal);
    defer std.testing.allocator.free(reveal_body);
    var reveal_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reveal_body, .{});
    defer reveal_parsed.deinit();
    try hctp.applyReveal(std.testing.allocator, &trials, reveal_parsed.value, 2);
    try std.testing.expect(trial_items[0].revealed);

    const start_body =
        "{\"scenario_id\":\"scenario-holdout\",\"attempt_id\":\"lane-null-a0\",\"grade_id\":null,\"payload\":{\"trial_id\":\"trial-null-001\"}}";
    var start_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, start_body, .{});
    defer start_parsed.deinit();
    try std.testing.expectError(
        error.LaneStartAfterReveal,
        hctp.applyLaneStarted(std.testing.allocator, &trials, start_parsed.value, 3, FingerprintC),
    );
}

test "HCTP conformance case 58: protected-split evidence cannot become repair motivation" {
    const holdout_practice_trial = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "\"split\": \"practice\"",
        "\"split\": \"holdout\"",
    );
    defer std.testing.allocator.free(holdout_practice_trial);
    try std.testing.expectError(
        error.PracticePurposeContainsProtectedSplit,
        hctp.validateTrialAlloc(std.testing.allocator, holdout_practice_trial),
    );
}

test "HCTP conformance case 59: exact source episodes cannot cross practice and holdout" {
    const manifest =
        \\{"schema":"hylo-source-selection-request/v1","campaign_id":"campaign-duplicate-source","case_visibility":"open","cases":[
        \\{"unit_id":"unit-practice","scenario_id":"scenario-practice","split":"practice","source_episode_id":"episode-one","visible_input":{"request":"same governed request"},"hidden_reference":null,"source_profile":{"kind":"direct"}},
        \\{"unit_id":"unit-holdout","scenario_id":"scenario-holdout","split":"holdout","source_episode_id":"episode-one","visible_input":{"request":"same governed request"},"hidden_reference":null,"source_profile":{"kind":"direct"}}]}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try tmp.dir.createFile(io, "manifest.json", .{});
    try file.writeStreamingAll(io, manifest);
    file.close(io);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "manifest.json" });
    defer std.testing.allocator.free(manifest_path);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root, "receipt.json" });
    defer std.testing.allocator.free(output_path);
    var seed_writer = try tmp.dir.createFile(io, "source-seed.bin", .{});
    try seed_writer.writeStreamingAll(io, &([_]u8{0x5a} ** 32));
    seed_writer.close(io);
    var seed_reader = try tmp.dir.openFile(io, "source-seed.bin", .{});
    defer seed_reader.close(io);
    var fd_buffer: [32]u8 = undefined;
    const seed_fd = try std.fmt.bufPrint(&fd_buffer, "{d}", .{seed_reader.handle});
    try std.testing.expectError(
        error.DuplicateSourceAcrossSplits,
        hctp_source.run(std.testing.allocator, &.{
            "compile",
            "--manifest",
            manifest_path,
            "--output",
            output_path,
            "--source-signing-seed-fd",
            seed_fd,
        }),
    );
}
