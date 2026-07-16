const std = @import("std");
const hctp = @import("hctp.zig");
const fixtures = @import("hctp_fixtures");
const retrace_core = @import("retrace_core");
const attestation = retrace_core.hctp_attestation;

// Section 36 case 20 has two owner boundaries. This module exercises the
// portable HCTP target-snapshot check; staged-diff observation requires the
// repository-aware Hylo/Git boundary and is covered by its conformance probe.

const registration_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const start_digest_a0 = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const start_digest_a1 = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const lease_a0 = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const lease_a1 = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const wrong_lease = "sha256:abababababababababababababababababababababababababababababababab";
const presented_input_fingerprint = "sha256:3dbc2a117751f42078d15a82dab707eef4ac2c2b19a8addd9286a873fa6ffb65";
const wrong_target_fingerprint = "sha256:f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0";

const RunOptions = struct {
    terminal_status: []const u8 = "completed",
    lease_digest: ?[]const u8 = null,
    target_snapshot_fingerprint: ?[]const u8 = null,
    hidden_reference_presented: bool = false,
    sibling_output_presented: bool = false,
    effect_policy_violation: bool = false,
    model_id: []const u8 = "test-model",
    model_provider: []const u8 = "test-provider",
    runtime_version: []const u8 = "v1",
    retry_count: u64 = 0,
    runner_id: []const u8 = "cas-trial",
    runner_version: []const u8 = "0.2.76",
    runner_binary_fingerprint: []const u8 = "sha256:3333333333333333333333333333333333333333333333333333333333333333",
    runner_key_id: []const u8 = "runner-key",
};

fn jsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn parseValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.TestExpectedObject,
    };
}

fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |items| items,
        else => error.TestExpectedArray,
    };
}

fn required(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.TestExpectedField;
}

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(try required(map, key));
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return array(try required(map, key));
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try required(map, key)) {
        .string => |value| value,
        else => error.TestExpectedString,
    };
}

fn armFor(trial: std.json.ObjectMap, arm_id: []const u8) !std.json.ObjectMap {
    for ((try requiredArray(trial, "arms")).items) |arm_value| {
        const arm = try object(arm_value);
        if (std.mem.eql(u8, try requiredString(arm, "arm_id"), arm_id)) return arm;
    }
    return error.TestExpectedArm;
}

fn registerFixture(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    fixture: []const u8,
) !void {
    var trial = try parseValue(allocator, fixture);
    defer trial.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, trial.value);
    defer allocator.free(fingerprint);
    const payload_bytes = try hctp.registrationPayloadAlloc(allocator, fixture, fingerprint);
    defer allocator.free(payload_bytes);
    const trial_root = try object(trial.value);
    const complete_payload_bytes = if (std.mem.eql(u8, try requiredString(trial_root, "purpose"), "promotion"))
        try std.fmt.allocPrint(
            allocator,
            "{s},\"calibration_sentinel_bindings\":[]}}",
            .{payload_bytes[0 .. payload_bytes.len - 1]},
        )
    else
        try allocator.dupe(u8, payload_bytes);
    defer allocator.free(complete_payload_bytes);
    var payload = try parseValue(allocator, complete_payload_bytes);
    defer payload.deinit();
    const body = .{
        .scenario_id = @as(?[]const u8, null),
        .attempt_id = @as(?[]const u8, null),
        .grade_id = @as(?[]const u8, null),
        .payload = payload.value,
    };
    const body_bytes = try jsonAlloc(allocator, body);
    defer allocator.free(body_bytes);
    var body_value = try parseValue(allocator, body_bytes);
    defer body_value.deinit();
    try hctp.applyRegistered(allocator, state, body_value.value, 1, registration_digest);
}

fn promotionFixtureAlloc(
    allocator: std.mem.Allocator,
    source_campaign_id: []const u8,
    trusted_source_binary: []const u8,
) ![]u8 {
    const promotion_base = try std.mem.replaceOwned(
        u8,
        allocator,
        fixtures.valid_trial,
        "\"purpose\": \"practice_repair\"",
        "\"purpose\": \"promotion\"",
    );
    defer allocator.free(promotion_base);
    const source_seed = [_]u8{0x5a} ** 32;
    const source_binary = "sha256:abababababababababababababababababababababababababababababababab";
    const source_public_key = try attestation.publicKeyBase64Alloc(allocator, source_seed);
    defer allocator.free(source_public_key);
    var direct_profile = try parseValue(allocator, "{\"kind\":\"direct\"}");
    defer direct_profile.deinit();
    const direct_profile_fingerprint = try hctp.digestValueAlloc(allocator, direct_profile.value);
    defer allocator.free(direct_profile_fingerprint);
    const trust_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"source-owner-policy\",\"keys\":[{{\"key_id\":\"source-owner-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"source_owner\"],\"producer_ids\":[\"seq-source-owner\"],\"producer_binary_fingerprints\":[{f}]}}],\"separation\":{{\"runner_and_pair_grader_distinct\":true,\"materializer_and_pair_grader_distinct\":true,\"human_confirmation_required_for_human_grade\":true}}}}",
        .{ std.json.fmt(source_public_key, .{}), std.json.fmt(trusted_source_binary, .{}) },
    );
    defer allocator.free(trust_text);
    var trust_value = try parseValue(allocator, trust_text);
    defer trust_value.deinit();
    const trust_fingerprint = try hctp.digestValueAlloc(allocator, trust_value.value);
    defer allocator.free(trust_fingerprint);
    const trust_marker = "\"trust_policy_fingerprint\": \"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"";
    const trust_replacement = try std.fmt.allocPrint(
        allocator,
        "\"trust_policy_fingerprint\":{f},\"trust_policy\":{s}",
        .{ std.json.fmt(trust_fingerprint, .{}), trust_text },
    );
    defer allocator.free(trust_replacement);
    const promotion = try std.mem.replaceOwned(u8, allocator, promotion_base, trust_marker, trust_replacement);
    defer allocator.free(promotion);
    const receipt_core = .{
        .schema = "hylo-source-selection-receipt/v1",
        .campaign_id = source_campaign_id,
        .cases = &.{.{
            .unit_id = "unit-001",
            .scenario_id = "scenario-001",
            .split = "practice",
            .independence_cluster_id = "cluster-001",
            .case_visibility = "open",
            .visible_input_fingerprint = presented_input_fingerprint,
            .hidden_reference_fingerprint = "sha256:1212121212121212121212121212121212121212121212121212121212121212",
            .source_episode_projection_version = retrace_core.hctp_adapter.source_episode_projection_version,
            .source_episode_fingerprint = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            .source_profile_fingerprint = direct_profile_fingerprint,
            .source_profile = .{ .kind = "direct" },
        }},
        .duplicate_analysis = .{ .cross_split_exact_duplicates = @as(u64, 0) },
    };
    const core_bytes = try jsonAlloc(allocator, receipt_core);
    defer allocator.free(core_bytes);
    var core_value = try parseValue(allocator, core_bytes);
    defer core_value.deinit();
    const selection_fingerprint = try hctp.digestValueAlloc(allocator, core_value.value);
    defer allocator.free(selection_fingerprint);
    const source_subject_unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-source-selection-attestation-subject/v1\",\"campaign_id\":{f},\"selection_fingerprint\":{f},\"producer\":{{\"id\":\"seq-source-owner\",\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":\"source-owner-key\",\"public_key_base64\":{f}}},\"attestation\":null}}",
        .{
            std.json.fmt(source_campaign_id, .{}),
            std.json.fmt(selection_fingerprint, .{}),
            std.json.fmt(source_binary, .{}),
            std.json.fmt(source_public_key, .{}),
        },
    );
    defer allocator.free(source_subject_unsigned);
    const source_subject = try attestation.signReceiptAlloc(
        allocator,
        source_subject_unsigned,
        .{
            .id = "seq-source-owner",
            .version = "v1",
            .binary_fingerprint = source_binary,
            .key_id = "source-owner-key",
        },
        "source_owner",
        1,
        source_seed,
    );
    defer allocator.free(source_subject);
    const receipt_body = try std.fmt.allocPrint(
        allocator,
        "{s},\"source_owner_attestation\":{s}}}",
        .{ core_bytes[0 .. core_bytes.len - 1], source_subject },
    );
    defer allocator.free(receipt_body);
    var receipt_body_value = try parseValue(allocator, receipt_body);
    defer receipt_body_value.deinit();
    const receipt_fingerprint = try hctp.digestValueAlloc(allocator, receipt_body_value.value);
    defer allocator.free(receipt_fingerprint);
    const receipt_bytes = try std.fmt.allocPrint(
        allocator,
        "{s},\"receipt_fingerprint\":{f}}}",
        .{ receipt_body[0 .. receipt_body.len - 1], std.json.fmt(receipt_fingerprint, .{}) },
    );
    defer allocator.free(receipt_bytes);
    const marker = "\"case_materializer_ref\": null,";
    if (std.mem.count(u8, promotion, marker) != 1) return error.UnexpectedFixtureShape;
    const replacement = try std.fmt.allocPrint(
        allocator,
        "\"source_selection_receipt_ref\":\"artifact:source-selection\"," ++
            "\"source_selection_receipt_fingerprint\":\"{s}\"," ++
            "\"source_selection_receipt\":{s},\"case_materializer_ref\": null,",
        .{ receipt_fingerprint, receipt_bytes },
    );
    defer allocator.free(replacement);
    const with_receipt = try std.mem.replaceOwned(u8, allocator, promotion, marker, replacement);
    defer allocator.free(with_receipt);
    const visible_commitments = try std.fmt.allocPrint(
        allocator,
        "\"visible_input_commitments\": [{f}]",
        .{std.json.fmt(presented_input_fingerprint, .{})},
    );
    defer allocator.free(visible_commitments);
    const with_visible = try std.mem.replaceOwned(
        u8,
        allocator,
        with_receipt,
        "\"visible_input_commitments\": []",
        visible_commitments,
    );
    defer allocator.free(with_visible);
    return std.mem.replaceOwned(
        u8,
        allocator,
        with_visible,
        "\"hidden_reference_commitments\": []",
        "\"hidden_reference_commitments\": [\"sha256:1212121212121212121212121212121212121212121212121212121212121212\"]",
    );
}

fn applyStart(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    trial_id: []const u8,
    manifest_lane_id: []const u8,
    body_lane_id: []const u8,
    lease_digest: []const u8,
    sequence: u64,
    event_digest: []const u8,
    target_override: ?[]const u8,
) !void {
    const trial = state.findTrial(trial_id) orelse return error.TestExpectedTrial;
    const lane = trial.findLane(manifest_lane_id) orelse return error.TestExpectedLane;
    var trial_value = try parseValue(allocator, trial.trial_json);
    defer trial_value.deinit();
    const trial_root = try object(trial_value.value);
    const execution = try requiredObject(trial_root, "execution");
    const arm = try armFor(trial_root, lane.arm_id);
    var source_episode_fingerprint: ?[]const u8 = null;
    var source_profile_fingerprint: ?[]const u8 = null;
    const sealing = try requiredObject(trial_root, "sealing");
    if (sealing.get("source_selection_receipt")) |receipt_value| {
        if (receipt_value != .null) {
            for ((try requiredArray(try object(receipt_value), "cases")).items) |case_value| {
                const source_case = try object(case_value);
                if (!std.mem.eql(u8, try requiredString(source_case, "unit_id"), lane.unit_id) or
                    !std.mem.eql(u8, try requiredString(source_case, "scenario_id"), lane.scenario_id)) continue;
                if (source_episode_fingerprint != null) return error.DuplicateSourceCase;
                source_episode_fingerprint = try requiredString(source_case, "source_episode_fingerprint");
                source_profile_fingerprint = try requiredString(source_case, "source_profile_fingerprint");
            }
        }
    }
    const manifest_fingerprint = try hctp.laneManifestFingerprintAlloc(allocator, lane);
    defer allocator.free(manifest_fingerprint);
    const body = .{
        .scenario_id = @as(?[]const u8, lane.scenario_id),
        .attempt_id = @as(?[]const u8, body_lane_id),
        .grade_id = @as(?[]const u8, null),
        .payload = .{
            .trial_id = trial_id,
            .unit_id = lane.unit_id,
            .pair_id = lane.pair_id,
            .opaque_arm_id = lane.arm_id,
            .lane_manifest_fingerprint = manifest_fingerprint,
            .start_lease_digest = lease_digest,
            .runner_id = "cas-trial",
            .runner_contract_fingerprint = try requiredString(execution, "runner_contract_fingerprint"),
            .target_snapshot_fingerprint = target_override orelse
                try requiredString(arm, "materialization_fingerprint"),
            .presented_input_fingerprint = presented_input_fingerprint,
            .source_episode_fingerprint = source_episode_fingerprint,
            .source_profile_fingerprint = source_profile_fingerprint,
            .environment_fingerprint = try requiredString(execution, "environment_fingerprint"),
            .replay_policy_fingerprint = try requiredString(execution, "replay_policy_fingerprint"),
            .model_configuration_fingerprint = try requiredString(execution, "model_policy_fingerprint"),
        },
    };
    const body_bytes = try jsonAlloc(allocator, body);
    defer allocator.free(body_bytes);
    var body_value = try parseValue(allocator, body_bytes);
    defer body_value.deinit();
    try hctp.applyLaneStarted(allocator, state, body_value.value, sequence, event_digest);
}

fn applyMinimalFinish(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    trial_id: []const u8,
    scenario_id: []const u8,
    lane_id: []const u8,
    sequence: u64,
) !void {
    const body = .{
        .scenario_id = @as(?[]const u8, scenario_id),
        .attempt_id = @as(?[]const u8, lane_id),
        .grade_id = @as(?[]const u8, null),
        .payload = .{
            .trial_id = trial_id,
            .run_receipt_fingerprint = registration_digest,
            .run_receipt = .{},
        },
    };
    const body_bytes = try jsonAlloc(allocator, body);
    defer allocator.free(body_bytes);
    var body_value = try parseValue(allocator, body_bytes);
    defer body_value.deinit();
    try hctp.applyLaneFinished(allocator, state, body_value.value, sequence);
}

fn applyFinish(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    trial_id: []const u8,
    lane_id: []const u8,
    sequence: u64,
    options: RunOptions,
) !void {
    const trial = state.findTrial(trial_id) orelse return error.TestExpectedTrial;
    const lane = trial.findLane(lane_id) orelse return error.TestExpectedLane;
    var trial_value = try parseValue(allocator, trial.trial_json);
    defer trial_value.deinit();
    const trial_root = try object(trial_value.value);
    const execution = try requiredObject(trial_root, "execution");
    const arm = try armFor(trial_root, lane.arm_id);
    const lease_digest = options.lease_digest orelse lane.lease_digest orelse lease_a0;
    var source_episode_fingerprint: ?[]const u8 = null;
    var source_profile_fingerprint: ?[]const u8 = null;
    const sealing = try requiredObject(trial_root, "sealing");
    if (sealing.get("source_selection_receipt")) |receipt_value| {
        if (receipt_value != .null) {
            for ((try requiredArray(try object(receipt_value), "cases")).items) |case_value| {
                const source_case = try object(case_value);
                if (!std.mem.eql(u8, try requiredString(source_case, "unit_id"), lane.unit_id) or
                    !std.mem.eql(u8, try requiredString(source_case, "scenario_id"), lane.scenario_id)) continue;
                if (source_episode_fingerprint != null) return error.DuplicateSourceCase;
                source_episode_fingerprint = try requiredString(source_case, "source_episode_fingerprint");
                source_profile_fingerprint = try requiredString(source_case, "source_profile_fingerprint");
            }
        }
    }
    const terminal_completed = std.mem.eql(u8, options.terminal_status, "completed");
    const failure_class: ?[]const u8 = if (terminal_completed) null else "fixture_failure";
    const failure_detail_ref: ?[]const u8 = if (terminal_completed) null else "artifact:failure";
    const output_ref: ?[]const u8 = if (terminal_completed) "artifact:output" else null;
    const output_fingerprint: ?[]const u8 = if (terminal_completed)
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    else
        null;
    const trace_ref: ?[]const u8 = if (terminal_completed) "artifact:trace" else null;
    const trace_fingerprint: ?[]const u8 = if (terminal_completed)
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc"
    else
        null;
    const policy_violations: []const []const u8 = if (options.effect_policy_violation)
        &.{"network_policy_violated"}
    else
        &.{};
    const native_receipt = .{
        .schema = "cas-trial-receipt/v1",
        .trial_id = trial.id,
        .lane_id = lane.id,
        .claim = .{
            .claim_id = "claim-fixture",
            .atomic = true,
            .claimed_before_execution = true,
            .claim_count = @as(u64, 1),
            .lane_lease_digest = lease_digest,
        },
        .execution = .{
            .handle_id = "handle-fixture",
            .handle_count = @as(u64, 1),
            .retry_count = options.retry_count,
            .hidden_fork_count = @as(u64, 0),
            .terminal_receipt_once = true,
        },
        .terminal_status = options.terminal_status,
        .runner_contract_fingerprint = try requiredString(execution, "runner_contract_fingerprint"),
    };
    const native_bytes = try jsonAlloc(allocator, native_receipt);
    defer allocator.free(native_bytes);
    var native_value = try parseValue(allocator, native_bytes);
    defer native_value.deinit();
    const native_fingerprint = try hctp.digestValueAlloc(allocator, native_value.value);
    defer allocator.free(native_fingerprint);
    const run_receipt = .{
        .schema = "hylo-run-receipt/v1",
        .trial_id = trial.id,
        .unit_id = lane.unit_id,
        .scenario_id = lane.scenario_id,
        .pair_id = lane.pair_id,
        .lane_id = lane.id,
        .opaque_arm_id = lane.arm_id,
        .lineage = .{
            .registration_event_digest = trial.registration_event_digest,
            .lane_started_event_digest = lane.started_event_digest orelse start_digest_a0,
            .lane_lease_digest = lease_digest,
        },
        .producer = .{
            .id = options.runner_id,
            .version = options.runner_version,
            .binary_fingerprint = options.runner_binary_fingerprint,
            .key_id = options.runner_key_id,
        },
        .materialization = .{
            .arm_value_fingerprint = try requiredString(arm, "value_fingerprint"),
            .target_snapshot_ref = try requiredString(arm, "materialization_ref"),
            .target_snapshot_fingerprint = options.target_snapshot_fingerprint orelse
                try requiredString(arm, "materialization_fingerprint"),
            .presented_input_ref = "artifact:scenario-input",
            .presented_input_fingerprint = lane.presented_input_fingerprint orelse presented_input_fingerprint,
            .source_episode_fingerprint = source_episode_fingerprint,
            .source_profile_fingerprint = source_profile_fingerprint,
            .hidden_reference_presented = options.hidden_reference_presented,
            .sibling_output_presented = options.sibling_output_presented,
        },
        .runtime = .{
            .environment_fingerprint = try requiredString(execution, "environment_fingerprint"),
            .replay_policy_fingerprint = try requiredString(execution, "replay_policy_fingerprint"),
            .effect_policy_fingerprint = try requiredString(execution, "effect_policy_fingerprint"),
            .model_id = options.model_id,
            .model_provider = options.model_provider,
            .model_configuration_fingerprint = try requiredString(execution, "model_policy_fingerprint"),
            .runtime_version = options.runtime_version,
            .seed = @as(?u64, null),
            .tokens_used = @as(u64, 100),
            .started_at_unix = @as(u64, 1),
            .ended_at_unix = @as(u64, 2),
        },
        .isolation = .{
            .fresh_thread = true,
            .fresh_workspace = true,
            .reset_receipt_ref = "artifact:reset",
            .reset_receipt_fingerprint = "sha256:4444444444444444444444444444444444444444444444444444444444444444",
            .target_cache_cleared = true,
            .shared_mutable_state_detected = false,
            .limitations = @as([]const []const u8, &.{}),
        },
        .effects = .{
            .filesystem_receipt_ref = "artifact:filesystem",
            .filesystem_receipt_fingerprint = "sha256:7777777777777777777777777777777777777777777777777777777777777777",
            .network_receipt_ref = "artifact:network",
            .network_receipt_fingerprint = "sha256:8888888888888888888888888888888888888888888888888888888888888888",
            .external_effect_receipt_ref = "artifact:external",
            .external_effect_receipt_fingerprint = "sha256:9999999999999999999999999999999999999999999999999999999999999999",
            .policy_violations = policy_violations,
        },
        .terminal = .{
            .status = options.terminal_status,
            .failure_class = failure_class,
            .failure_detail_ref = failure_detail_ref,
        },
        .evidence = .{
            .output_ref = output_ref,
            .output_fingerprint = output_fingerprint,
            .trace_ref = trace_ref,
            .trace_fingerprint = trace_fingerprint,
            .world_state_ref = @as(?[]const u8, "artifact:world"),
            .world_state_fingerprint = @as(?[]const u8, "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccd"),
            .metrics_ref = @as(?[]const u8, "artifact:metrics"),
            .metrics_fingerprint = @as(?[]const u8, "sha256:ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddde"),
        },
        .native_receipt = .{
            .kind = "cas-trial-receipt",
            .ref = "artifact:cas-trial-receipt",
            .fingerprint = native_fingerprint,
            .receipt = native_receipt,
        },
        .attestation = @as(?[]const u8, null),
    };
    const receipt_bytes = try jsonAlloc(allocator, run_receipt);
    defer allocator.free(receipt_bytes);
    var receipt_value = try parseValue(allocator, receipt_bytes);
    defer receipt_value.deinit();
    const receipt_fingerprint = try hctp.digestValueAlloc(allocator, receipt_value.value);
    defer allocator.free(receipt_fingerprint);
    const body = .{
        .scenario_id = @as(?[]const u8, lane.scenario_id),
        .attempt_id = @as(?[]const u8, lane.id),
        .grade_id = @as(?[]const u8, null),
        .payload = .{
            .trial_id = trial.id,
            .run_receipt_fingerprint = receipt_fingerprint,
            .run_receipt = receipt_value.value,
        },
    };
    const body_bytes = try jsonAlloc(allocator, body);
    defer allocator.free(body_bytes);
    var body_value = try parseValue(allocator, body_bytes);
    defer body_value.deinit();
    try hctp.applyLaneFinished(allocator, state, body_value.value, sequence);
}

fn applyNullReveal(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    sequence: u64,
) !void {
    var reveal = try parseValue(allocator, fixtures.valid_reveal);
    defer reveal.deinit();
    const reveal_fingerprint = try hctp.digestValueAlloc(allocator, reveal.value);
    defer allocator.free(reveal_fingerprint);
    const body = .{
        .scenario_id = @as(?[]const u8, null),
        .attempt_id = @as(?[]const u8, null),
        .grade_id = @as(?[]const u8, null),
        .payload = .{
            .reveal_fingerprint = reveal_fingerprint,
            .reveal = reveal.value,
        },
    };
    const body_bytes = try jsonAlloc(allocator, body);
    defer allocator.free(body_bytes);
    var body_value = try parseValue(allocator, body_bytes);
    defer body_value.deinit();
    try hctp.applyReveal(allocator, state, body_value.value, sequence);
}

test "HCTP 36.12 rejects finish without start" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);

    try std.testing.expectError(
        error.LaneFinishWithoutStart,
        applyMinimalFinish(
            std.testing.allocator,
            &state,
            "trial-null-001",
            "scenario-holdout",
            "lane-null-a0",
            2,
        ),
    );
    const lane = state.findTrial("trial-null-001").?.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.registered, lane.status);
    try std.testing.expectEqual(@as(?u64, null), lane.started_sequence);
    try std.testing.expectEqual(@as(?u64, null), lane.terminal_sequence);
}

test "HCTP 36.13 rejects duplicate start" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);

    try std.testing.expectError(
        error.LaneAlreadyStarted,
        applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a1, 3, start_digest_a1, null),
    );
    const lane = state.findTrial("trial-null-001").?.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.started, lane.status);
    try std.testing.expectEqual(@as(?u64, 2), lane.started_sequence);
    try std.testing.expectEqualStrings(lease_a0, lane.lease_digest.?);
}

test "HCTP declared pair order rejects the second sibling before the first is terminal" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);

    try std.testing.expectError(
        error.PairOrderInvalid,
        applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a1", "lane-null-a1", lease_a1, 2, start_digest_a1, null),
    );
    const trial = state.findTrial("trial-null-001").?;
    try std.testing.expectEqual(hctp.LaneTerminal.registered, trial.findLane("lane-null-a1").?.status);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);
    try std.testing.expectError(
        error.PairOrderInvalid,
        applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a1", "lane-null-a1", lease_a1, 3, start_digest_a1, null),
    );
    try applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{});
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a1", "lane-null-a1", lease_a1, 4, start_digest_a1, null);
    try std.testing.expectEqual(hctp.LaneTerminal.started, trial.findLane("lane-null-a1").?.status);
}

test "HCTP 36.14 rejects duplicate terminal receipt" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);
    try applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{});

    try std.testing.expectError(
        error.LaneAlreadyTerminal,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 4, .{}),
    );
    const lane = state.findTrial("trial-null-001").?.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.completed, lane.status);
    try std.testing.expectEqual(@as(?u64, 3), lane.terminal_sequence);
    try std.testing.expect(lane.run_receipt_fingerprint != null);
}

test "HCTP 36.15 rejects invalid or reused lane lease" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);

    try std.testing.expectError(
        error.LaneLeaseInvalid,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{ .lease_digest = wrong_lease }),
    );
    const lane_a0 = state.findTrial("trial-null-001").?.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.started, lane_a0.status);
    try std.testing.expectEqual(@as(?u64, null), lane_a0.terminal_sequence);

    try applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{});
    try std.testing.expectError(
        error.LaneLeaseReused,
        applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a1", "lane-null-a1", lease_a0, 4, start_digest_a1, null),
    );
    const lane_a1 = state.findTrial("trial-null-001").?.findLane("lane-null-a1").?;
    try std.testing.expectEqual(hctp.LaneTerminal.registered, lane_a1.status);
    try std.testing.expectEqual(@as(?[]u8, null), lane_a1.lease_digest);
}

test "HCTP 36.16 keeps started but unfinished lane visibly pending" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);

    const trial = state.findTrial("trial-null-001").?;
    const lane = trial.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.started, lane.status);
    try std.testing.expectEqual(@as(?u64, 2), lane.started_sequence);
    try std.testing.expectEqual(@as(?u64, null), lane.terminal_sequence);
    try std.testing.expectEqual(@as(?[]u8, null), lane.run_receipt_fingerprint);
    try std.testing.expect(!trial.allLanesTerminal());
}

test "HCTP 36.17 rejects reveal with one pending lane" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);

    try std.testing.expectError(
        error.RevealBeforeTerminal,
        applyNullReveal(std.testing.allocator, &state, 3),
    );
    const trial = state.findTrial("trial-null-001").?;
    try std.testing.expect(!trial.revealed);
    try std.testing.expectEqual(hctp.LaneTerminal.started, trial.findLane("lane-null-a0").?.status);
    try std.testing.expectEqual(hctp.LaneTerminal.registered, trial.findLane("lane-null-a1").?.status);
}

test "HCTP 36.18 rejects undeclared retry lane" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);
    try applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{});

    try std.testing.expectError(
        error.LaneNotRegistered,
        applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0-retry", lease_a1, 4, start_digest_a1, null),
    );
    const trial = state.findTrial("trial-null-001").?;
    try std.testing.expect(trial.findLane("lane-null-a0-retry") == null);
    try std.testing.expectEqual(hctp.LaneTerminal.completed, trial.findLane("lane-null-a0").?.status);
    try std.testing.expectEqual(@as(?u64, 3), trial.findLane("lane-null-a0").?.terminal_sequence);
}

test "HCTP 36.19 rejects replacement of invalid promotion lane" {
    const promotion_fixture = try promotionFixtureAlloc(
        std.testing.allocator,
        "campaign-valid-001",
        "sha256:abababababababababababababababababababababababababababababababab",
    );
    defer std.testing.allocator.free(promotion_fixture);
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, promotion_fixture);
    try applyStart(std.testing.allocator, &state, "trial-valid-001", "lane-001-r1-a0", "lane-001-r1-a0", lease_a0, 2, start_digest_a0, null);
    try applyFinish(std.testing.allocator, &state, "trial-valid-001", "lane-001-r1-a0", 3, .{ .terminal_status = "invalid" });

    const trial = state.findTrial("trial-valid-001").?;
    try std.testing.expectEqualStrings("promotion", trial.purpose);
    try std.testing.expectEqual(hctp.LaneTerminal.invalid, trial.findLane("lane-001-r1-a0").?.status);
    try std.testing.expectError(
        error.LaneNotRegistered,
        applyStart(std.testing.allocator, &state, "trial-valid-001", "lane-001-r1-a0", "lane-001-r1-a0-replacement", lease_a1, 4, start_digest_a1, null),
    );
    try std.testing.expect(trial.findLane("lane-001-r1-a0-replacement") == null);
    try std.testing.expectEqual(hctp.LaneTerminal.registered, trial.findLane("lane-001-r1-a1").?.status);
}

test "HCTP source-selection receipts join the registered campaign and anchored source owner" {
    const wrong_campaign = try promotionFixtureAlloc(
        std.testing.allocator,
        "campaign-other",
        "sha256:abababababababababababababababababababababababababababababababab",
    );
    defer std.testing.allocator.free(wrong_campaign);
    try std.testing.expectError(
        error.SourceSelectionReceiptInvalid,
        hctp.validateTrialAlloc(std.testing.allocator, wrong_campaign),
    );

    const untrusted_binary = try promotionFixtureAlloc(
        std.testing.allocator,
        "campaign-valid-001",
        "sha256:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
    );
    defer std.testing.allocator.free(untrusted_binary);
    try std.testing.expectError(
        error.SourceOwnerAttestationInvalid,
        hctp.validateTrialAlloc(std.testing.allocator, untrusted_binary),
    );
}

test "HCTP 36.20 rejects target drift at lane start" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);

    try std.testing.expectError(
        error.LaneManifestMismatch,
        applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, wrong_target_fingerprint),
    );
    const lane = state.findTrial("trial-null-001").?.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.registered, lane.status);
    try std.testing.expectEqual(@as(?u64, null), lane.started_sequence);
    try std.testing.expectEqual(@as(?[]u8, null), lane.lease_digest);
}

test "HCTP 36.21 rejects run receipt target differing from registered arm" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);

    try std.testing.expectError(
        error.RunReceiptInvalid,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{ .target_snapshot_fingerprint = wrong_target_fingerprint }),
    );
    const lane = state.findTrial("trial-null-001").?.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.started, lane.status);
    try std.testing.expectEqual(@as(?u64, null), lane.terminal_sequence);
    try std.testing.expectEqual(@as(?[]u8, null), lane.run_receipt_fingerprint);
}

test "HCTP 36.22 rejects hidden-reference or sibling-output leak" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);

    try std.testing.expectError(
        error.HiddenReferenceLeak,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{ .hidden_reference_presented = true }),
    );
    try std.testing.expectError(
        error.SiblingOutputLeak,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{ .sibling_output_presented = true }),
    );
    const lane = state.findTrial("trial-null-001").?.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.started, lane.status);
    try std.testing.expectEqual(@as(?u64, null), lane.terminal_sequence);
}

test "HCTP 36.23 rejects effect-policy violations" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);

    try std.testing.expectError(
        error.EffectPolicyViolation,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{ .effect_policy_violation = true }),
    );
    const lane = state.findTrial("trial-null-001").?.findLane("lane-null-a0").?;
    try std.testing.expectEqual(hctp.LaneTerminal.started, lane.status);
    try std.testing.expectEqual(@as(?u64, null), lane.terminal_sequence);
    try std.testing.expectEqual(@as(?[]u8, null), lane.run_receipt_fingerprint);
}

test "HCTP 36.24 rejects runtime or model revision drift within pair" {
    var state = hctp.CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try registerFixture(std.testing.allocator, &state, fixtures.valid_null_trial);
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", "lane-null-a0", lease_a0, 2, start_digest_a0, null);
    try applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a0", 3, .{});
    try applyStart(std.testing.allocator, &state, "trial-null-001", "lane-null-a1", "lane-null-a1", lease_a1, 4, start_digest_a1, null);

    try std.testing.expectError(
        error.RuntimeDrift,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a1", 5, .{ .model_id = "test-model-revision-2" }),
    );
    try std.testing.expectError(
        error.RuntimeDrift,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a1", 5, .{ .runtime_version = "v2" }),
    );
    try std.testing.expectError(
        error.RunnerRoleUnauthorized,
        applyFinish(std.testing.allocator, &state, "trial-null-001", "lane-null-a1", 5, .{
            .runner_binary_fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        }),
    );
    const trial = state.findTrial("trial-null-001").?;
    try std.testing.expectEqual(hctp.LaneTerminal.completed, trial.findLane("lane-null-a0").?.status);
    try std.testing.expectEqual(@as(?u64, 3), trial.findLane("lane-null-a0").?.terminal_sequence);
    try std.testing.expectEqual(hctp.LaneTerminal.started, trial.findLane("lane-null-a1").?.status);
    try std.testing.expectEqual(@as(?u64, null), trial.findLane("lane-null-a1").?.terminal_sequence);
}
