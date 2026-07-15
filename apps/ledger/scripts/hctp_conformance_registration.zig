const std = @import("std");
const hctp = @import("hctp.zig");
const fixtures = @import("hctp_fixtures");

// Section 36 cases 2 and 5 require the admitted-scenario and complete-campaign
// manifest owned by Hylo. The public HCTP API intentionally has no campaign
// context, so those probes belong in the Hylo-owned conformance module rather
// than in a synthetic count-only harness here.

fn replaceExactAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
    expected_count: usize,
) ![]u8 {
    if (std.mem.count(u8, input, needle) != expected_count) return error.UnexpectedFixtureShape;
    return std.mem.replaceOwned(u8, allocator, input, needle, replacement);
}

fn duplicateFirstUnitAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const start_marker = "\"units\": [";
    const end_marker = "\n  ],\n  \"sealing\":";
    const marker_start = std.mem.indexOf(u8, input, start_marker) orelse
        return error.UnexpectedFixtureShape;
    const content_start = marker_start + start_marker.len;
    const content_end = std.mem.indexOfPos(u8, input, content_start, end_marker) orelse
        return error.UnexpectedFixtureShape;
    if (content_start == content_end) return error.UnexpectedFixtureShape;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(input[0..content_end]);
    try out.writer.writeByte(',');
    try out.writer.writeAll(input[content_start..content_end]);
    try out.writer.writeAll(input[content_end..]);
    return out.toOwnedSlice();
}

fn refreshInterventionWitnessFingerprintAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.UnexpectedFixtureShape,
    };
    const factor_value = root.get("factor") orelse return error.UnexpectedFixtureShape;
    const factor = switch (factor_value) {
        .object => |value| value,
        else => return error.UnexpectedFixtureShape,
    };
    const witness = factor.get("intervention_witness") orelse return error.UnexpectedFixtureShape;
    const old_fingerprint = switch (factor.get("intervention_witness_fingerprint") orelse
        return error.UnexpectedFixtureShape) {
        .string => |value| value,
        else => return error.UnexpectedFixtureShape,
    };
    const new_fingerprint = try hctp.digestValueAlloc(allocator, witness);
    defer allocator.free(new_fingerprint);
    return replaceExactAlloc(allocator, input, old_fingerprint, new_fingerprint, 1);
}

fn registrationBodyAlloc(
    allocator: std.mem.Allocator,
    trial_json: []const u8,
    declared_fingerprint: []const u8,
) ![]u8 {
    const payload = try hctp.registrationPayloadAlloc(allocator, trial_json, declared_fingerprint);
    defer allocator.free(payload);
    return std.fmt.allocPrint(
        allocator,
        "{{\"scenario_id\":null,\"attempt_id\":null,\"grade_id\":null," ++
            "\"payload\":{s}}}",
        .{payload},
    );
}

test "HCTP Section 36 case 1: accepts a valid fixed twin trial" {
    var validation = try hctp.validateTrialAlloc(std.testing.allocator, fixtures.valid_trial);
    defer validation.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("trial-valid-001", validation.trial_id);
    try std.testing.expectEqual(@as(usize, 1), validation.unit_count);
    try std.testing.expectEqual(@as(usize, 2), validation.pair_count);
    try std.testing.expectEqual(@as(usize, 4), validation.lane_count);
    try hctp.validateFingerprint(validation.fingerprint);
}

test "HCTP Section 36 case 3: rejects duplicate unit pair and lane identifiers" {
    const duplicate_unit = try duplicateFirstUnitAlloc(std.testing.allocator, fixtures.valid_trial);
    defer std.testing.allocator.free(duplicate_unit);
    try std.testing.expectError(
        error.DuplicateUnit,
        hctp.validateTrialAlloc(std.testing.allocator, duplicate_unit),
    );

    const duplicate_pair = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "pair-001-r2",
        "pair-001-r1",
        1,
    );
    defer std.testing.allocator.free(duplicate_pair);
    try std.testing.expectError(
        error.DuplicatePair,
        hctp.validateTrialAlloc(std.testing.allocator, duplicate_pair),
    );

    const duplicate_lane = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "lane-001-r2-a0",
        "lane-001-r1-a0",
        1,
    );
    defer std.testing.allocator.free(duplicate_lane);
    try std.testing.expectError(
        error.DuplicateLane,
        hctp.validateTrialAlloc(std.testing.allocator, duplicate_lane),
    );
}

test "HCTP Section 36 case 4: rejects a pair missing one arm" {
    const missing_arm = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        ",\n            \"arm-1\": {\"lane_id\": \"lane-001-r1-a1\"}",
        "",
        1,
    );
    defer std.testing.allocator.free(missing_arm);
    try std.testing.expectError(
        error.PairShapeInvalid,
        hctp.validateTrialAlloc(std.testing.allocator, missing_arm),
    );
}

test "HCTP Section 36 case 6: rejects a practice purpose containing holdout" {
    const protected_split = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "\"split\": \"practice\"",
        "\"split\": \"holdout\"",
        1,
    );
    defer std.testing.allocator.free(protected_split);
    try std.testing.expectError(
        error.PracticePurposeContainsProtectedSplit,
        hctp.validateTrialAlloc(std.testing.allocator, protected_split),
    );
}

test "HCTP Section 36 case 7: rejects a non-target factor in promotion" {
    const promotion = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "\"purpose\": \"practice_repair\"",
        "\"purpose\": \"promotion\"",
        1,
    );
    defer std.testing.allocator.free(promotion);
    const same_target_epoch = try replaceExactAlloc(
        std.testing.allocator,
        promotion,
        "\"after_target_fingerprint\": \"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"",
        "\"after_target_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"",
        1,
    );
    defer std.testing.allocator.free(same_target_epoch);
    const instruction_factor = try replaceExactAlloc(
        std.testing.allocator,
        same_target_epoch,
        "\"kind\": \"target_snapshot\"",
        "\"kind\": \"instruction_bundle\"",
        1,
    );
    defer std.testing.allocator.free(instruction_factor);
    const factor_verifier = try replaceExactAlloc(
        std.testing.allocator,
        instruction_factor,
        "\"id\": \"git-target-projection\"",
        "\"id\": \"canonical-projection\"",
        2,
    );
    defer std.testing.allocator.free(factor_verifier);
    const witness_kind = try replaceExactAlloc(
        std.testing.allocator,
        factor_verifier,
        "\"factor_kind\": \"target_snapshot\"",
        "\"factor_kind\": \"instruction_bundle\"",
        1,
    );
    defer std.testing.allocator.free(witness_kind);
    const coherent_trial = try refreshInterventionWitnessFingerprintAlloc(
        std.testing.allocator,
        witness_kind,
    );
    defer std.testing.allocator.free(coherent_trial);

    try std.testing.expectError(
        error.PromotionFactorInvalid,
        hctp.validateTrialAlloc(std.testing.allocator, coherent_trial),
    );
}

test "HCTP Section 36 case 8: rejects an arm difference outside allowed roots" {
    const escaped_path = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "codex/skills/hylo/SKILL.md",
        "codex/skills/seq/SKILL.md",
        1,
    );
    defer std.testing.allocator.free(escaped_path);
    const coherent_trial = try refreshInterventionWitnessFingerprintAlloc(
        std.testing.allocator,
        escaped_path,
    );
    defer std.testing.allocator.free(coherent_trial);

    try std.testing.expectError(
        error.UnexpectedFactorDifference,
        hctp.validateTrialAlloc(std.testing.allocator, coherent_trial),
    );
}

test "HCTP Section 36 case 9: rejects identical arms for a non-null trial" {
    const same_value = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        3,
    );
    defer std.testing.allocator.free(same_value);
    const identical_arms = try replaceExactAlloc(
        std.testing.allocator,
        same_value,
        "sha256:3222222222222222222222222222222222222222222222222222222222222222",
        "sha256:2111111111111111111111111111111111111111111111111111111111111111",
        2,
    );
    defer std.testing.allocator.free(identical_arms);

    try std.testing.expectError(
        error.InterventionDifferenceMissing,
        hctp.validateTrialAlloc(std.testing.allocator, identical_arms),
    );
}

test "HCTP Section 36 case 10: rejects differing arms for a null sentinel" {
    const differing_arm = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_null_trial,
        "\"arm_id\": \"arm-1\",\n" ++
            "      \"value_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\n" ++
            "      \"materialization_ref\": \"artifact:baseline\",\n" ++
            "      \"materialization_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"",
        "\"arm_id\": \"arm-1\",\n" ++
            "      \"value_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\n" ++
            "      \"materialization_ref\": \"artifact:baseline\",\n" ++
            "      \"materialization_fingerprint\": \"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"",
        1,
    );
    defer std.testing.allocator.free(differing_arm);

    try std.testing.expectError(
        error.NullSentinelArmsDiffer,
        hctp.validateTrialAlloc(std.testing.allocator, differing_arm),
    );
}

test "HCTP randomized blocks replay a versioned allocation receipt and reject same-seed order drift" {
    const seed = "00000000000000000000000000000006";
    const receipt_json =
        "{\"schema\":\"hylo-allocation-receipt/v1\",\"algorithm\":\"sha256-balanced-block-order/v1\",\"seed\":\"" ++ seed ++ "\"," ++
        "\"assignments\":[" ++
        "{\"unit_id\":\"unit-001\",\"pair_id\":\"pair-001-r1\",\"block_id\":\"block-001-r1\",\"repeat_index\":1,\"order\":[\"arm-0\",\"arm-1\"],\"lane_order\":[\"lane-001-r1-a0\",\"lane-001-r1-a1\"]}," ++
        "{\"unit_id\":\"unit-001\",\"pair_id\":\"pair-001-r2\",\"block_id\":\"block-001-r2\",\"repeat_index\":2,\"order\":[\"arm-1\",\"arm-0\"],\"lane_order\":[\"lane-001-r2-a1\",\"lane-001-r2-a0\"]}]}";
    var receipt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, receipt_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer receipt.deinit();
    const receipt_fingerprint = try hctp.digestValueAlloc(std.testing.allocator, receipt.value);
    defer std.testing.allocator.free(receipt_fingerprint);
    const seed_commitment = try hctp.allocationSeedCommitmentAlloc(std.testing.allocator, seed);
    defer std.testing.allocator.free(seed_commitment);
    const allocation = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"allocation\": {{\"method\":\"randomized_blocks\",\"seed_commitment\":{f},\"position_balance_required\":true,\"allocation_receipt_fingerprint\":{f},\"allocation_receipt\":{s}}}",
        .{ std.json.fmt(seed_commitment, .{}), std.json.fmt(receipt_fingerprint, .{}), receipt_json },
    );
    defer std.testing.allocator.free(allocation);
    const randomized = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "\"allocation\": {\n    \"method\": \"balanced_ab_ba\",\n    \"seed_commitment\": null,\n    \"position_balance_required\": true\n  }",
        allocation,
        1,
    );
    defer std.testing.allocator.free(randomized);
    var validation = try hctp.validateTrialAlloc(std.testing.allocator, randomized);
    validation.deinit(std.testing.allocator);

    const first_swapped = try replaceExactAlloc(
        std.testing.allocator,
        randomized,
        "\"pair_id\": \"pair-001-r1\",\n          \"block_id\": \"block-001-r1\",\n          \"repeat_index\": 1,\n          \"order\": [\"arm-0\", \"arm-1\"]",
        "\"pair_id\": \"pair-001-r1\",\n          \"block_id\": \"block-001-r1\",\n          \"repeat_index\": 1,\n          \"order\": [\"arm-1\", \"arm-0\"]",
        1,
    );
    defer std.testing.allocator.free(first_swapped);
    const both_swapped = try replaceExactAlloc(
        std.testing.allocator,
        first_swapped,
        "\"pair_id\": \"pair-001-r2\",\n          \"block_id\": \"block-001-r2\",\n          \"repeat_index\": 2,\n          \"order\": [\"arm-1\", \"arm-0\"]",
        "\"pair_id\": \"pair-001-r2\",\n          \"block_id\": \"block-001-r2\",\n          \"repeat_index\": 2,\n          \"order\": [\"arm-0\", \"arm-1\"]",
        1,
    );
    defer std.testing.allocator.free(both_swapped);
    try std.testing.expectError(
        error.AllocationReceiptInvalid,
        hctp.validateTrialAlloc(std.testing.allocator, both_swapped),
    );
}

test "HCTP positive sentinels require an explicitly frozen arm direction" {
    const positive = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "\"purpose\": \"practice_repair\"",
        "\"purpose\": \"calibration_positive\"",
        1,
    );
    defer std.testing.allocator.free(positive);
    const difference_factor = try replaceExactAlloc(
        std.testing.allocator,
        positive,
        "\"kind\": \"target_snapshot\"",
        "\"kind\": \"instruction_bundle\"",
        1,
    );
    defer std.testing.allocator.free(difference_factor);
    const stable_target = try replaceExactAlloc(
        std.testing.allocator,
        difference_factor,
        "\"after_target_fingerprint\": \"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"",
        "\"after_target_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"",
        1,
    );
    defer std.testing.allocator.free(stable_target);
    const unknown_direction = try replaceExactAlloc(
        std.testing.allocator,
        stable_target,
        "\"predicted_direction\": \"candidate_better\"",
        "\"predicted_direction\": \"detect_known_difference\"",
        1,
    );
    defer std.testing.allocator.free(unknown_direction);
    try std.testing.expectError(
        error.PositiveSentinelDirectionMissing,
        hctp.validateTrialAlloc(std.testing.allocator, unknown_direction),
    );
}

test "HCTP preserves legacy shared keys outside the source-owner role" {
    const trust_text =
        "{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"legacy-shared-key\"," ++
        "\"keys\":[" ++
        "{\"key_id\":\"runner-key\",\"public_key_base64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"," ++
        "\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"runner\"]}," ++
        "{\"key_id\":\"grader-key\",\"public_key_base64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"," ++
        "\"allowed_roles\":[\"absolute_grader\"],\"producer_ids\":[\"grader\"]}]," ++
        "\"separation\":{\"runner_and_pair_grader_distinct\":true," ++
        "\"materializer_and_pair_grader_distinct\":true," ++
        "\"human_confirmation_required_for_human_grade\":true}}";
    var trust = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, trust_text, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trust.deinit();
    const trust_fingerprint = try hctp.digestValueAlloc(std.testing.allocator, trust.value);
    defer std.testing.allocator.free(trust_fingerprint);
    const trust_replacement = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"trust_policy_fingerprint\":{f},\"trust_policy\":{s}",
        .{ std.json.fmt(trust_fingerprint, .{}), trust_text },
    );
    defer std.testing.allocator.free(trust_replacement);
    const trial = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "\"trust_policy_fingerprint\": \"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"",
        trust_replacement,
        1,
    );
    defer std.testing.allocator.free(trial);
    var validation = try hctp.validateTrialAlloc(std.testing.allocator, trial);
    defer validation.deinit(std.testing.allocator);
}

test "HCTP source-owner role separation requires a non-null receipt" {
    const null_receipt = try replaceExactAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "\"case_materializer_ref\": null,",
        "\"source_selection_receipt\": null,\n    \"case_materializer_ref\": null,",
        1,
    );
    defer std.testing.allocator.free(null_receipt);
    const required_source_owner = try replaceExactAlloc(
        std.testing.allocator,
        null_receipt,
        "\"required_distinct_roles\": []",
        "\"required_distinct_roles\": [\"source_owner\"]",
        1,
    );
    defer std.testing.allocator.free(required_source_owner);
    try std.testing.expectError(
        error.RoleSeparationInvalid,
        hctp.validateTrialAlloc(std.testing.allocator, required_source_owner),
    );
}

test "HCTP Section 36 case 11: failed registration leaves HCTP state unchanged" {
    const body_json = try registrationBodyAlloc(
        std.testing.allocator,
        fixtures.valid_trial,
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    );
    defer std.testing.allocator.free(body_json);
    var body = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer body.deinit();
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.TrialFingerprintMismatch,
        hctp.applyRegistered(
            std.testing.allocator,
            &state,
            body.value,
            1,
            "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), state.trials.items.len);
}
