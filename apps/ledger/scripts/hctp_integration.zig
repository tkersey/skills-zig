const std = @import("std");
const durable_store = @import("durable_store");
const hctp = @import("hctp.zig");
const hctp_fold = @import("hctp_fold.zig");
const integration_paths = @import("hctp_integration_paths");
const retrace_core = @import("retrace_core");
const fixtures = @import("hctp_fixtures");
const attestation = retrace_core.hctp_attestation;

const RegistrationDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const StartDigestA0 = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const StartDigestA1 = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const AnchorDigest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const MaxBytes = 16 * 1024 * 1024;
const ProofSanitizerSeed = [_]u8{0x7c} ** 32;
const RunnerAuthoritySeed = [_]u8{0x71} ** 32;
const ExecutorAuthoritySeed = [_]u8{0x6e} ** 32;
const ProofSanitizerBinary = "sha256:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
const SealedEffectPolicyJson = "{\"filesystem\":\"workspace_write\",\"allowed_paths\":[],\"network\":\"deny\",\"network_allowlist\":[],\"external_side_effects\":\"deny\",\"external_effect_allowlist\":[]}";
const SealedEffectPolicyFingerprint = "sha256:4effcb65690499855ef753fee45992a98cbee9eb4cd0da18d937143f4a4adef0";

const DcpTemplate =
    \\{"decision_context_packet":{
    \\"packet_version":"DCP-v2","packet_id":"DCP-placeholder",
    \\"source":{"session_id":"session-integration","decision_id":"decision-integration","source_episode_id":"session:integration#turn:turn-two"},
    \\"artifact_state":{"reconstructability":"transcript_only"},
    \\"episode":{"question":"Which bounded route should be selected?","selected_route":"route-a","rejected_routes":[],"explicit_rationale":[],"explicit_assumptions":[],"evidence_refs":[],"tools_and_artifacts":[],"skills_and_instructions":[],"outcome_refs":[]},
    \\"turns":{"total_turns":3,"decision_turn_index":2,"decision_turn_id":"turn-two","first_outcome_turn_index":3,"source_turn_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    \\"anchors":{"pre_decision":{"available":true,"keep_through_turn_index":1,"drop_last_n_turns":2,"anchor_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"post_decision_pre_outcome":{"available":true,"keep_through_turn_index":2,"drop_last_n_turns":1,"anchor_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"outcome_aware":{"available":true,"keep_through_turn_index":3,"drop_last_n_turns":0,"anchor_digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}},
    \\"contamination":{"injected_skill_blocks":false,"generated_reports":false,"current_audit_prompt":false,"quoted_material":false},
    \\"limitations":[]}}
;

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const libc = struct {
    extern "c" fn system(command: [*:0]const u8) c_int;
};

fn parseJson(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

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

fn required(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.RequiredFieldMissing;
}

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(try required(map, key));
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return array(try required(map, key));
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try required(map, key)) {
        .string => |text| text,
        else => error.StringRequired,
    };
}

fn requiredBool(map: std.json.ObjectMap, key: []const u8) !bool {
    return switch (try required(map, key)) {
        .bool => |value| value,
        else => error.BoolRequired,
    };
}

fn jsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn replaceExactAlloc(allocator: std.mem.Allocator, bytes: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (std.mem.count(u8, bytes, needle) != 1) return error.FixtureShapeChanged;
    return std.mem.replaceOwned(u8, allocator, bytes, needle, replacement);
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn fileFingerprintAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try durable_store.readFileAlloc(allocator, path, MaxBytes);
    defer allocator.free(bytes);
    return digestBytesAlloc(allocator, bytes);
}

fn bindRunnerContractAlloc(
    allocator: std.mem.Allocator,
    trial: []const u8,
    executor_path: []const u8,
    runner_path: []const u8,
    ledger_path: []const u8,
) ![]u8 {
    const executor_fingerprint = try fileFingerprintAlloc(allocator, executor_path);
    defer allocator.free(executor_fingerprint);
    const runner_binary_fingerprint = try fileFingerprintAlloc(allocator, runner_path);
    defer allocator.free(runner_binary_fingerprint);
    const ledger_fingerprint = try fileFingerprintAlloc(allocator, ledger_path);
    defer allocator.free(ledger_fingerprint);
    const contract_bytes = try jsonAlloc(allocator, .{
        .schema = "cas-hylo-runner/v1",
        .executor_binary_fingerprint = executor_fingerprint,
        .ledger_binary_fingerprint = ledger_fingerprint,
        .executor_authority = .{
            .producer_id = "cas-trial-executor",
            .key_id = "executor-authority-key",
            .binary_fingerprint = executor_fingerprint,
            .authorized_observations = [_][]const u8{ "runtime", "isolation", "effects", "terminal", "evidence", "execution_audit", "native_receipt" },
        },
        .ledger_authority = .{
            .producer_id = "hylo-ledger",
            .key_id = "executor-authority-key",
            .binary_fingerprint = ledger_fingerprint,
        },
        .atomic_claim = true,
        .fresh_workspace = true,
        .fresh_thread = true,
        .materializes_opaque_arm = true,
        .maximum_handles_per_lane = @as(u64, 1),
        .maximum_retries_per_lane = @as(u64, 0),
    });
    defer allocator.free(contract_bytes);
    var contract_parsed = try parseJson(allocator, contract_bytes);
    defer contract_parsed.deinit();
    const contract_fingerprint = try hctp.digestValueAlloc(allocator, contract_parsed.value);
    defer allocator.free(contract_fingerprint);
    const replacement = try std.fmt.allocPrint(
        allocator,
        "\"runner_contract_fingerprint\": \"{s}\",\n    \"runner_contract\": {s}",
        .{ contract_fingerprint, contract_bytes },
    );
    defer allocator.free(replacement);
    const contract_bound = try replaceExactAlloc(
        allocator,
        trial,
        "\"runner_contract_fingerprint\": \"sha256:4444444444444444444444444444444444444444444444444444444444444444\"",
        replacement,
    );
    defer allocator.free(contract_bound);
    const runner_fingerprint = try fileFingerprintAlloc(allocator, runner_path);
    defer allocator.free(runner_fingerprint);
    const runner_replacement = try std.fmt.allocPrint(
        allocator,
        "\"producer_version\": {f},\n      \"binary_fingerprint\": \"{s}\",\n      \"key_id\": \"runner-key\"",
        .{ std.json.fmt(integration_paths.cas_version, .{}), runner_fingerprint },
    );
    defer allocator.free(runner_replacement);
    return replaceExactAlloc(
        allocator,
        contract_bound,
        "\"producer_version\": \"0.2.76\",\n      \"binary_fingerprint\": \"sha256:3333333333333333333333333333333333333333333333333333333333333333\",\n      \"key_id\": \"runner-key\"",
        runner_replacement,
    );
}

fn integrationTrustPolicyAlloc(
    allocator: std.mem.Allocator,
    executor_path: []const u8,
    runner_path: []const u8,
    ledger_path: []const u8,
) ![]u8 {
    const public_key = try attestation.publicKeyBase64Alloc(allocator, ProofSanitizerSeed);
    defer allocator.free(public_key);
    const runner_public_key = try attestation.publicKeyBase64Alloc(allocator, RunnerAuthoritySeed);
    defer allocator.free(runner_public_key);
    const executor_public_key = try attestation.publicKeyBase64Alloc(allocator, ExecutorAuthoritySeed);
    defer allocator.free(executor_public_key);
    const executor_fingerprint = try fileFingerprintAlloc(allocator, executor_path);
    defer allocator.free(executor_fingerprint);
    const runner_fingerprint = try fileFingerprintAlloc(allocator, runner_path);
    defer allocator.free(runner_fingerprint);
    const ledger_fingerprint = try fileFingerprintAlloc(allocator, ledger_path);
    defer allocator.free(ledger_fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"integration-proof-source-owner\",\"keys\":[{{\"key_id\":\"integration-proof-source-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"source_owner\"],\"producer_ids\":[\"integration-proof-sanitizer\"],\"producer_binary_fingerprints\":[\"{s}\"]}},{{\"key_id\":\"runner-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"cas-trial\"],\"producer_binary_fingerprints\":[{f}]}},{{\"key_id\":\"executor-authority-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"cas-trial-executor\",\"hylo-ledger\"],\"producer_binary_fingerprints\":[{f},{f}]}}],\"separation\":{{\"runner_and_pair_grader_distinct\":true,\"materializer_and_pair_grader_distinct\":true,\"human_confirmation_required_for_human_grade\":true}}}}",
        .{ std.json.fmt(public_key, .{}), ProofSanitizerBinary, std.json.fmt(runner_public_key, .{}), std.json.fmt(runner_fingerprint, .{}), std.json.fmt(executor_public_key, .{}), std.json.fmt(executor_fingerprint, .{}), std.json.fmt(ledger_fingerprint, .{}) },
    );
}

fn bindProofSourceOwnerAlloc(
    allocator: std.mem.Allocator,
    trial: []const u8,
    executor_path: []const u8,
    runner_path: []const u8,
    ledger_path: []const u8,
) ![]u8 {
    const trust = try integrationTrustPolicyAlloc(
        allocator,
        executor_path,
        runner_path,
        ledger_path,
    );
    defer allocator.free(trust);
    var trust_parsed = try parseJson(allocator, trust);
    defer trust_parsed.deinit();
    const trust_fingerprint = try hctp.digestValueAlloc(allocator, trust_parsed.value);
    defer allocator.free(trust_fingerprint);
    const replacement = try std.fmt.allocPrint(
        allocator,
        "\"trust_policy_fingerprint\": \"{s}\",\n    \"trust_policy\": {s},",
        .{ trust_fingerprint, trust },
    );
    defer allocator.free(replacement);
    return replaceExactAlloc(
        allocator,
        trial,
        "\"trust_policy_fingerprint\": \"sha256:7777777777777777777777777777777777777777777777777777777777777777\",",
        replacement,
    );
}

fn expectTrustBindsRunnerAuthority(
    trust: std.json.ObjectMap,
    authority: std.json.ObjectMap,
) !void {
    const key_id = try requiredString(authority, "key_id");
    const producer_id = try requiredString(authority, "producer_id");
    const binary_fingerprint = try requiredString(authority, "binary_fingerprint");
    for ((try requiredArray(trust, "keys")).items) |key_value| {
        const key = try object(key_value);
        if (!std.mem.eql(u8, key_id, try requiredString(key, "key_id"))) continue;
        inline for (.{
            .{ "allowed_roles", "runner" },
            .{ "producer_ids", producer_id },
            .{ "producer_binary_fingerprints", binary_fingerprint },
        }) |expected| {
            var found = false;
            for ((try requiredArray(key, expected[0])).items) |item| {
                const value = switch (item) {
                    .string => |text| text,
                    else => return error.StringRequired,
                };
                if (std.mem.eql(u8, value, expected[1])) {
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);
        }
        return;
    }
    return error.RunnerAuthorityTrustKeyMissing;
}

fn bindNullFactorMaterializationAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    trial: []const u8,
) ![]u8 {
    const factor_path = try std.fs.path.join(allocator, &.{ root, "proof-factor.json" });
    defer allocator.free(factor_path);
    const factor_bytes = "{\"schema\":\"hylo-test-factor/v1\",\"instruction\":\"identical\"}";
    try durable_store.writeTextAtomic(allocator, factor_path, factor_bytes);
    const oid_command = try std.fmt.allocPrint(
        allocator,
        "git -C '{s}' hash-object -w proof-factor.json",
        .{root},
    );
    defer allocator.free(oid_command);
    const oid_raw = try runIsolatedCommandAlloc(allocator, root, "proof-factor-oid", oid_command);
    defer allocator.free(oid_raw);
    const oid = std.mem.trim(u8, oid_raw, " \t\r\n");
    var factor = try parseJson(allocator, factor_bytes);
    defer factor.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, factor.value);
    defer allocator.free(fingerprint);
    const ref = try std.fmt.allocPrint(allocator, "git-blob-json:{s}", .{oid});
    defer allocator.free(ref);
    var current = try std.mem.replaceOwned(u8, allocator, trial, "artifact:baseline", ref);
    errdefer allocator.free(current);
    const materialization_field = try std.fmt.allocPrint(
        allocator,
        "\"materialization_fingerprint\": \"{s}\"",
        .{fingerprint},
    );
    defer allocator.free(materialization_field);
    const next = try std.mem.replaceOwned(
        u8,
        allocator,
        current,
        "\"materialization_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"",
        materialization_field,
    );
    allocator.free(current);
    current = next;
    const snapshot_field = try std.fmt.allocPrint(
        allocator,
        "\"snapshot_fingerprint\": \"{s}\"",
        .{fingerprint},
    );
    defer allocator.free(snapshot_field);
    const with_snapshot = try std.mem.replaceOwned(
        u8,
        allocator,
        current,
        "\"snapshot_fingerprint\": \"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"",
        snapshot_field,
    );
    allocator.free(current);
    current = with_snapshot;
    var parsed = try parseJson(allocator, current);
    defer parsed.deinit();
    const witness = try required(try requiredObject(try object(parsed.value), "factor"), "intervention_witness");
    const witness_fingerprint = try hctp.digestValueAlloc(allocator, witness);
    defer allocator.free(witness_fingerprint);
    const result = try std.mem.replaceOwned(
        u8,
        allocator,
        current,
        "sha256:eb611af244ff839ac5e8abe3bf83d404905bf4dda344478970d433f8d7bb03ee",
        witness_fingerprint,
    );
    allocator.free(current);
    return result;
}

fn proofSanitizationReceiptAlloc(
    allocator: std.mem.Allocator,
    artifact_set_bytes: []const u8,
) ![]u8 {
    var artifact_set = try parseJson(allocator, artifact_set_bytes);
    defer artifact_set.deinit();
    const artifact_set_fingerprint = try hctp.digestValueAlloc(allocator, artifact_set.value);
    defer allocator.free(artifact_set_fingerprint);
    const unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-proof-sanitization-receipt/v1\",\"campaign_id\":\"cmp-test\",\"trial_id\":\"trial-null-001\",\"artifact_set\":{s},\"artifact_set_fingerprint\":{f},\"producer\":{{\"id\":\"integration-proof-sanitizer\",\"version\":\"v1\",\"binary_fingerprint\":\"{s}\",\"key_id\":\"integration-proof-source-key\"}},\"attestation\":null}}",
        .{ artifact_set_bytes, std.json.fmt(artifact_set_fingerprint, .{}), ProofSanitizerBinary },
    );
    defer allocator.free(unsigned);
    return attestation.signReceiptAlloc(
        allocator,
        unsigned,
        .{
            .id = "integration-proof-sanitizer",
            .version = "v1",
            .binary_fingerprint = ProofSanitizerBinary,
            .key_id = "integration-proof-source-key",
        },
        "source_owner",
        1,
        ProofSanitizerSeed,
    );
}

fn historicalProfileAlloc(allocator: std.mem.Allocator) ![]u8 {
    const packet_id = try retrace_core.dcp_schema.packetIdForTextExcludingPacketId(allocator, DcpTemplate);
    defer allocator.free(packet_id);
    const dcp = try replaceExactAlloc(allocator, DcpTemplate, "DCP-placeholder", packet_id);
    defer allocator.free(dcp);
    var dcp_parsed = try parseJson(allocator, dcp);
    defer dcp_parsed.deinit();
    const dcp_fingerprint = try hctp.digestValueAlloc(allocator, dcp_parsed.value);
    defer allocator.free(dcp_fingerprint);
    const packet = try requiredObject(try object(dcp_parsed.value), "decision_context_packet");
    const contamination = try requiredObject(packet, "contamination");
    const contamination_json = try retrace_core.dcp_schema.canonicalJsonAlloc(
        allocator,
        .{ .object = contamination },
        false,
    );
    defer allocator.free(contamination_json);
    const contamination_fingerprint = try digestBytesAlloc(allocator, contamination_json);
    defer allocator.free(contamination_fingerprint);
    const governance =
        \\{"source_governance_gate":{"gate_version":"SGG-v1","source_ref":"session:integration#turn:turn-two","source_episode_id":"session:integration#turn:turn-two","evidence_fingerprint":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","verdict":{"state":"authoritative","replay_allowed":true,"allowed_modes":["replay"]},"limitations":[]}}
    ;
    var governance_parsed = try parseJson(allocator, governance);
    defer governance_parsed.deinit();
    const governance_fingerprint = try hctp.digestValueAlloc(allocator, governance_parsed.value);
    defer allocator.free(governance_fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"historical_decision\",\"source_governance_ref\":\"artifact:sgg\",\"source_governance_fingerprint\":\"{s}\",\"source_governance\":{s},\"decision_context_ref\":\"artifact:dcp\",\"decision_context_fingerprint\":\"{s}\",\"decision_context\":{s},\"temporal_horizon\":\"pre_decision\",\"source_target_text_policy\":\"absent\",\"source_target_text_witness\":{{\"schema\":\"hylo-source-target-text-witness/v1\",\"source_ref\":\"session:integration#turn:turn-two\",\"source_episode_id\":\"session:integration#turn:turn-two\",\"source_turn_digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"dcp_contamination_fingerprint\":\"{s}\",\"evidence_ref\":\"seq:integration-target-text-derivation\",\"contamination\":{{\"source_target_text_present\":false,\"within_pre_decision_anchor\":false}},\"sanitization\":{{\"applied\":false,\"sanitized_context_fingerprint\":null,\"target_instruction_count\":1}}}},\"retrace_mode\":\"replay\",\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\",\"reconstructability\":\"transcript_only\",\"limitations\":[]}}",
        .{ governance_fingerprint, governance, dcp_fingerprint, dcp, contamination_fingerprint },
    );
}

fn historicalTrialAlloc(allocator: std.mem.Allocator, direct_trial: []const u8) ![]u8 {
    const profile = try historicalProfileAlloc(allocator);
    defer allocator.free(profile);
    return replaceExactAlloc(allocator, direct_trial, "{\"kind\": \"direct\"}", profile);
}

fn registerTrial(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    trial_bytes: []const u8,
    registration_digest: []const u8,
) !void {
    var validation = try hctp.validateTrialAlloc(allocator, trial_bytes);
    defer validation.deinit(allocator);
    var trial = try parseJson(allocator, trial_bytes);
    defer trial.deinit();
    const payload = try trialRegistrationPayloadAlloc(allocator, validation.fingerprint, trial.value);
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var body_parsed = try parseJson(allocator, body);
    defer body_parsed.deinit();
    try hctp.applyRegistered(allocator, state, body_parsed.value, 1, registration_digest);
}

fn trialRegistrationPayloadAlloc(
    allocator: std.mem.Allocator,
    trial_fingerprint: []const u8,
    trial_value: std.json.Value,
) ![]u8 {
    const trial_json = try hctp.canonicalJsonAlloc(allocator, trial_value);
    defer allocator.free(trial_json);
    return hctp.registrationPayloadAlloc(allocator, trial_json, trial_fingerprint);
}

fn bodyAlloc(
    allocator: std.mem.Allocator,
    scenario_id: ?[]const u8,
    attempt_id: ?[]const u8,
    grade_id: ?[]const u8,
    payload: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"scenario_id\":");
    try writeOptionalString(&out.writer, scenario_id);
    try out.writer.writeAll(",\"attempt_id\":");
    try writeOptionalString(&out.writer, attempt_id);
    try out.writer.writeAll(",\"grade_id\":");
    try writeOptionalString(&out.writer, grade_id);
    try out.writer.writeAll(",\"payload\":");
    try out.writer.writeAll(payload);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| try std.json.Stringify.value(text, .{}, writer) else try writer.writeAll("null");
}

fn armFor(trial: std.json.ObjectMap, arm_id: []const u8) !std.json.ObjectMap {
    for ((try requiredArray(trial, "arms")).items) |arm_value| {
        const arm = try object(arm_value);
        if (std.mem.eql(u8, try requiredString(arm, "arm_id"), arm_id)) return arm;
    }
    return error.ArmMissing;
}

fn startLane(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    lane_id: []const u8,
    lease_digest: []const u8,
    input_fingerprint: []const u8,
    sequence: u64,
    event_digest: []const u8,
) !void {
    const trial = state.findTrial("trial-null-001") orelse return error.TrialMissing;
    const lane = trial.findLane(lane_id) orelse return error.LaneMissing;
    const manifest_fingerprint = try hctp.laneManifestFingerprintAlloc(allocator, lane);
    defer allocator.free(manifest_fingerprint);
    var trial_parsed = try parseJson(allocator, trial.trial_json);
    defer trial_parsed.deinit();
    const trial_root = try object(trial_parsed.value);
    const execution = try requiredObject(trial_root, "execution");
    const arm = try armFor(trial_root, lane.arm_id);
    const payload = try jsonAlloc(allocator, .{
        .trial_id = trial.id,
        .unit_id = lane.unit_id,
        .pair_id = lane.pair_id,
        .opaque_arm_id = lane.arm_id,
        .lane_manifest_fingerprint = manifest_fingerprint,
        .start_lease_digest = lease_digest,
        .runner_id = "cas-trial",
        .runner_contract_fingerprint = try requiredString(execution, "runner_contract_fingerprint"),
        .target_snapshot_fingerprint = try requiredString(arm, "materialization_fingerprint"),
        .presented_input_fingerprint = input_fingerprint,
        .environment_fingerprint = try requiredString(execution, "environment_fingerprint"),
        .replay_policy_fingerprint = try requiredString(execution, "replay_policy_fingerprint"),
        .model_configuration_fingerprint = try requiredString(execution, "model_policy_fingerprint"),
    });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, lane.scenario_id, lane.id, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyLaneStarted(allocator, state, parsed.value, sequence, event_digest);
}

fn runCasLane(
    allocator: std.mem.Allocator,
    cas_trial_path: []const u8,
    executor_path: []const u8,
    root: []const u8,
    trial_path: []const u8,
    lane_id: []const u8,
    lease_path: []const u8,
    input_path: []const u8,
    input_fingerprint: []const u8,
    registration_digest: []const u8,
    start_digest: []const u8,
) ![]u8 {
    const trial_bytes = try durable_store.readFileAlloc(allocator, trial_path, MaxBytes);
    defer allocator.free(trial_bytes);
    var trial_parsed = try parseJson(allocator, trial_bytes);
    defer trial_parsed.deinit();
    const trial_id = try requiredString(try object(trial_parsed.value), "trial_id");
    const current_dir = try std.process.currentPathAlloc(defaultIo(), allocator);
    defer allocator.free(current_dir);
    const executor_resolved = if (std.fs.path.isAbsolute(executor_path))
        try allocator.dupe(u8, executor_path)
    else
        try std.fs.path.resolve(allocator, &.{ current_dir, executor_path });
    defer allocator.free(executor_resolved);
    const ledger_resolved = if (std.fs.path.isAbsolute(integration_paths.ledger_path))
        try allocator.dupe(u8, integration_paths.ledger_path)
    else
        try std.fs.path.resolve(allocator, &.{ current_dir, integration_paths.ledger_path });
    defer allocator.free(ledger_resolved);
    const receipt_dir = try std.fs.path.join(allocator, &.{ root, "receipts" });
    defer allocator.free(receipt_dir);
    const stdout_path = try std.fmt.allocPrint(allocator, "{s}/{s}.cas.stdout", .{ root, lane_id });
    defer allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(allocator, "{s}/{s}.cas.stderr", .{ root, lane_id });
    defer allocator.free(stderr_path);
    const command = try std.fmt.allocPrint(
        allocator,
        "cat '{s}' | (exec 3<&0; cat '{s}' | (exec 4<&0 0</dev/null; exec '{s}' run --trial '{s}' --lane-id '{s}' --repo '{s}' --receipt-dir '{s}' --registration-event-digest '{s}' --start-event-digest '{s}' --lease-fd 3 --input-fd 4 --presented-input-fingerprint '{s}' --executor '{s}' --ledger '{s}' --producer-id cas-trial --json >'{s}' 2>'{s}'))",
        .{ lease_path, input_path, cas_trial_path, trial_path, lane_id, root, receipt_dir, registration_digest, start_digest, input_fingerprint, executor_resolved, ledger_resolved, stdout_path, stderr_path },
    );
    defer allocator.free(command);
    const command_z = try allocator.dupeZ(u8, command);
    defer allocator.free(command_z);
    if (libc.system(command_z.ptr) != 0) {
        const stderr = durable_store.readFileAlloc(allocator, stderr_path, MaxBytes) catch null;
        defer if (stderr) |bytes| allocator.free(bytes);
        std.debug.print("cas_trial failed for {s}:\n{s}\n", .{ lane_id, stderr orelse "CAS stderr unavailable" });
        const executor_stderr_path = try std.fs.path.join(allocator, &.{ receipt_dir, trial_id, lane_id, "executor-result.json.stderr" });
        defer allocator.free(executor_stderr_path);
        const executor_stderr = durable_store.readFileAlloc(allocator, executor_stderr_path, MaxBytes) catch null;
        defer if (executor_stderr) |bytes| allocator.free(bytes);
        std.debug.print("executor failed for {s}:\n{s}\n", .{ lane_id, executor_stderr orelse "executor stderr unavailable" });
        return error.CasTrialFailed;
    }
    const receipt_path = try std.fs.path.join(allocator, &.{ receipt_dir, trial_id, lane_id, "run-receipt.json" });
    defer allocator.free(receipt_path);
    return durable_store.readFileAlloc(allocator, receipt_path, MaxBytes);
}

const NativeCampaignSetup = struct {
    scenario_path: []u8,
    scenario_fingerprint: []u8,
};

fn setupNativeCampaign(
    allocator: std.mem.Allocator,
    root: []const u8,
    ledger_path: []const u8,
    executor_path: []const u8,
    runner_path: []const u8,
) !NativeCampaignSetup {
    const git_init = try std.fmt.allocPrint(allocator, "git init -q '{s}'", .{root});
    defer allocator.free(git_init);
    const git_output = try runIsolatedCommandAlloc(allocator, root, "git-init", git_init);
    defer allocator.free(git_output);
    const exclude_path = try std.fs.path.join(allocator, &.{ root, ".git", "info", "exclude" });
    defer allocator.free(exclude_path);
    try durable_store.writeTextAtomic(allocator, exclude_path, ".ledger/\n");
    var scenario_parsed = try parseJson(allocator, DirectScenario);
    defer scenario_parsed.deinit();
    const scenario_fingerprint = try hctp.digestValueAlloc(allocator, scenario_parsed.value);
    errdefer allocator.free(scenario_fingerprint);
    const scenario = try hctp.canonicalJsonAlloc(allocator, scenario_parsed.value);
    defer allocator.free(scenario);
    const scenario_path = try std.fs.path.join(allocator, &.{ root, "scenario.json" });
    errdefer allocator.free(scenario_path);
    try durable_store.writeTextAtomic(allocator, scenario_path, scenario);
    const campaign = try campaignAlloc(
        allocator,
        scenario_fingerprint,
        executor_path,
        runner_path,
        ledger_path,
    );
    defer allocator.free(campaign);
    const campaign_intent = try artifactIntentAlloc(allocator, "campaign_created", "campaign", campaign, null);
    defer allocator.free(campaign_intent);
    const scenario_intent = try artifactIntentAlloc(allocator, "scenario_admitted", "scenario", scenario, "scenario-holdout");
    defer allocator.free(scenario_intent);
    const campaign_intent_path = try std.fs.path.join(allocator, &.{ root, "campaign-intent.json" });
    defer allocator.free(campaign_intent_path);
    const scenario_intent_path = try std.fs.path.join(allocator, &.{ root, "scenario-intent.json" });
    defer allocator.free(scenario_intent_path);
    try durable_store.writeTextAtomic(allocator, campaign_intent_path, campaign_intent);
    try durable_store.writeTextAtomic(allocator, scenario_intent_path, scenario_intent);
    const append_campaign = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo append --repo '{s}' --json '{s}'",
        .{ ledger_path, root, campaign_intent_path },
    );
    defer allocator.free(append_campaign);
    const campaign_output = try runIsolatedCommandAlloc(allocator, root, "ledger-append-campaign", append_campaign);
    defer allocator.free(campaign_output);
    const append_scenario = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo append --repo '{s}' --json '{s}'",
        .{ ledger_path, root, scenario_intent_path },
    );
    defer allocator.free(append_scenario);
    const scenario_output = try runIsolatedCommandAlloc(allocator, root, "ledger-append-scenario", append_scenario);
    defer allocator.free(scenario_output);
    return .{ .scenario_path = scenario_path, .scenario_fingerprint = scenario_fingerprint };
}

const NativeTrialRegistration = struct {
    trial_path: []u8,
    event_digest: []u8,
};

fn registerNativeTrial(
    allocator: std.mem.Allocator,
    root: []const u8,
    ledger_path: []const u8,
    trial: []const u8,
) !NativeTrialRegistration {
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    errdefer allocator.free(trial_path);
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    const command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo register-trial --repo '{s}' --trial '{s}'",
        .{ ledger_path, root, trial_path },
    );
    defer allocator.free(command);
    const stdout = try runIsolatedCommandAlloc(allocator, root, "ledger-register-trial", command);
    defer allocator.free(stdout);
    return .{
        .trial_path = trial_path,
        .event_digest = try commandEventDigest(allocator, stdout, "event_digest"),
    };
}

const NativeLaneStart = struct {
    lease_path: []u8,
    lease_digest: []u8,
    start_digest: []u8,
};

fn startNativeLane(
    allocator: std.mem.Allocator,
    root: []const u8,
    ledger_path: []const u8,
    trial_id: []const u8,
    lane_id: []const u8,
) !NativeLaneStart {
    const lease_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ledger.lease", .{ root, lane_id });
    errdefer allocator.free(lease_path);
    const command = try std.fmt.allocPrint(
        allocator,
        "set -o pipefail; rm -f '{s}'; exec 4>&1; '{s}' --source hylo start-lane --repo '{s}' --campaign-id cmp-test --trial-id '{s}' --lane-id '{s}' --runner-id cas-trial --lease-output-fd 3 3>&1 1>&4 | (umask 077; cat >'{s}')",
        .{ lease_path, ledger_path, root, trial_id, lane_id, lease_path },
    );
    defer allocator.free(command);
    const label = try std.fmt.allocPrint(allocator, "ledger-start-{s}", .{lane_id});
    defer allocator.free(label);
    const stdout = try runIsolatedCommandAlloc(allocator, root, label, command);
    defer allocator.free(stdout);
    const lease = try durable_store.readFileAlloc(allocator, lease_path, MaxBytes);
    defer {
        std.crypto.secureZero(u8, lease);
        allocator.free(lease);
    }
    const canonical_lease = std.mem.trim(u8, lease, " \t\r\n");
    if (canonical_lease.len != "HYL1-".len + 64) return error.LaneLeaseInvalid;
    try durable_store.writeTextAtomic(allocator, lease_path, canonical_lease);
    return .{
        .lease_path = lease_path,
        .lease_digest = try digestBytesAlloc(allocator, canonical_lease),
        .start_digest = try commandEventDigest(allocator, stdout, "start_event_digest"),
    };
}

fn finishNativeLane(
    allocator: std.mem.Allocator,
    root: []const u8,
    ledger_path: []const u8,
    trial_id: []const u8,
    lane_id: []const u8,
    lease_path: []const u8,
) !void {
    const receipt_path = try std.fs.path.join(allocator, &.{ root, "receipts", trial_id, lane_id, "run-receipt.json" });
    defer allocator.free(receipt_path);
    const command = try std.fmt.allocPrint(
        allocator,
        "cat '{s}' | (exec 3<&0; exec 0</dev/null; exec '{s}' --source hylo finish-lane --repo '{s}' --receipt '{s}' --lease-input-fd 3)",
        .{ lease_path, ledger_path, root, receipt_path },
    );
    defer allocator.free(command);
    const label = try std.fmt.allocPrint(allocator, "ledger-finish-{s}", .{lane_id});
    defer allocator.free(label);
    const stdout = try runIsolatedCommandAlloc(allocator, root, label, command);
    defer allocator.free(stdout);
}

fn finishLane(allocator: std.mem.Allocator, state: *hctp.CampaignTrials, lane_id: []const u8, receipt_bytes: []const u8, sequence: u64) !void {
    const trial = state.findTrial("trial-null-001") orelse return error.TrialMissing;
    const lane = trial.findLane(lane_id) orelse return error.LaneMissing;
    var receipt = try parseJson(allocator, receipt_bytes);
    defer receipt.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, receipt.value);
    defer allocator.free(fingerprint);
    const payload = try jsonAlloc(allocator, .{
        .trial_id = trial.id,
        .run_receipt_fingerprint = fingerprint,
        .run_receipt = receipt.value,
    });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, lane.scenario_id, lane.id, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyLaneFinished(allocator, state, parsed.value, sequence);
}

fn gradeLane(allocator: std.mem.Allocator, state: *hctp.CampaignTrials, lane_id: []const u8, arm_id: []const u8, grade_id: []const u8) !void {
    const trial = state.findTrial("trial-null-001") orelse return error.TrialMissing;
    const lane = trial.findLane(lane_id) orelse return error.LaneMissing;
    const run_fingerprint = lane.run_receipt_fingerprint orelse return error.ReceiptMissing;
    var grade = try parseJson(allocator, fixtures.valid_grade_receipt);
    defer grade.deinit();
    const root = try objectPtr(&grade.value);
    try root.put(allocator, "lane_id", .{ .string = @constCast(lane_id) });
    try root.put(allocator, "opaque_arm_id", .{ .string = @constCast(arm_id) });
    try root.put(allocator, "run_receipt_fingerprint", .{ .string = run_fingerprint });
    const fingerprint = try hctp.digestValueAlloc(allocator, grade.value);
    defer allocator.free(fingerprint);
    const payload = try jsonAlloc(allocator, .{
        .trial_id = trial.id,
        .pair_id = lane.pair_id,
        .opaque_arm_id = arm_id,
        .grade_receipt_ref = "fixture:absolute-grade",
        .grade_receipt_fingerprint = fingerprint,
        .grade_receipt = grade.value,
    });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, lane.scenario_id, lane.id, grade_id, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    _ = try hctp.applyAbsoluteGrade(allocator, state, parsed.value, 1.0, true, 0);
}

fn objectPtr(value: *std.json.Value) !*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*map| map,
        else => error.ObjectRequired,
    };
}

fn arrayPtr(value: *std.json.Value) !*std.json.Array {
    return switch (value.*) {
        .array => |*items| items,
        else => error.ArrayRequired,
    };
}

fn pairGrade(allocator: std.mem.Allocator, state: *hctp.CampaignTrials) !void {
    var receipt = try parseJson(allocator, fixtures.valid_pair_grade_receipt);
    defer receipt.deinit();
    const trial = state.findTrial("trial-null-001") orelse return error.TrialMissing;
    const left_output = (trial.findLane("lane-null-a0") orelse return error.LaneMissing).output_fingerprint orelse return error.ReceiptMissing;
    const right_output = (trial.findLane("lane-null-a1") orelse return error.LaneMissing).output_fingerprint orelse return error.ReceiptMissing;
    const root = try objectPtr(&receipt.value);
    const presentation_value = root.getPtr("presentation") orelse return error.RequiredFieldMissing;
    const presentation = try objectPtr(presentation_value);
    try presentation.put(allocator, "left_output_fingerprint", .{ .string = left_output });
    try presentation.put(allocator, "right_output_fingerprint", .{ .string = right_output });
    const commitment_body = try jsonAlloc(allocator, .{
        .schema = "hylo-pair-grade-presentation/v1",
        .trial_id = "trial-null-001",
        .pair_id = "pair-null-001",
        .left_lane_id = "lane-null-a0",
        .left_output_fingerprint = left_output,
        .right_lane_id = "lane-null-a1",
        .right_output_fingerprint = right_output,
    });
    defer allocator.free(commitment_body);
    var commitment_parsed = try parseJson(allocator, commitment_body);
    defer commitment_parsed.deinit();
    const commitment = try hctp.digestValueAlloc(allocator, commitment_parsed.value);
    defer allocator.free(commitment);
    try presentation.put(allocator, "position_map_commitment", .{ .string = commitment });
    const fingerprint = try hctp.digestValueAlloc(allocator, receipt.value);
    defer allocator.free(fingerprint);
    const payload = try jsonAlloc(allocator, .{
        .trial_id = "trial-null-001",
        .pair_id = "pair-null-001",
        .pair_grade_receipt_fingerprint = fingerprint,
        .pair_grade_receipt = receipt.value,
    });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyPairGrade(allocator, state, parsed.value);
}

fn reveal(allocator: std.mem.Allocator, state: *hctp.CampaignTrials) !void {
    var receipt = try parseJson(allocator, fixtures.valid_reveal);
    defer receipt.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, receipt.value);
    defer allocator.free(fingerprint);
    const payload = try jsonAlloc(allocator, .{
        .reveal_fingerprint = fingerprint,
        .reveal = receipt.value,
    });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyReveal(allocator, state, parsed.value, 10);
}

const LaneFiles = struct {
    lease_path: []u8,
    input_path: []u8,
    lease_digest: []u8,
    input_fingerprint: []u8,

    fn deinit(self: LaneFiles, allocator: std.mem.Allocator) void {
        allocator.free(self.lease_path);
        allocator.free(self.input_path);
        allocator.free(self.lease_digest);
        allocator.free(self.input_fingerprint);
    }
};

fn laneFiles(allocator: std.mem.Allocator, root: []const u8, lane_id: []const u8) !LaneFiles {
    // The CAS claim store is authoritative across process and repository
    // lifetimes. Each isolated test cohort therefore needs its own lease
    // capability; reusing the old deterministic fixture lease is correctly
    // rejected as a hidden retry on the second test run.
    const root_digest = try digestBytesAlloc(allocator, root);
    defer allocator.free(root_digest);
    const lease_material = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ lane_id, root_digest });
    defer allocator.free(lease_material);
    const lease_nonce_digest = try digestBytesAlloc(allocator, lease_material);
    defer allocator.free(lease_nonce_digest);
    const lease = try std.fmt.allocPrint(allocator, "HYL1-{s}", .{lease_nonce_digest[7..]});
    defer {
        std.crypto.secureZero(u8, lease);
        allocator.free(lease);
    }
    const input = try std.fmt.allocPrint(allocator, "{{\"scenario\":\"{s}\"}}", .{lane_id});
    defer allocator.free(input);
    const lease_path = try std.fmt.allocPrint(allocator, "{s}/{s}.lease", .{ root, lane_id });
    errdefer allocator.free(lease_path);
    const input_path = try std.fmt.allocPrint(allocator, "{s}/{s}.input.json", .{ root, lane_id });
    errdefer allocator.free(input_path);
    try durable_store.writeTextAtomic(allocator, lease_path, lease);
    try durable_store.writeTextAtomic(allocator, input_path, input);
    return .{
        .lease_path = lease_path,
        .input_path = input_path,
        .lease_digest = try digestBytesAlloc(allocator, lease),
        .input_fingerprint = try digestBytesAlloc(allocator, input),
    };
}

const IntegrationBinaries = struct {
    seq: []u8,
    cas: []u8,
    executor: []u8,
    sealed_executor: []u8,
    sealed_source_fixture: []u8,
    sealed_grader_fixture: []u8,
    sealed_grade_materializer_fixture: []u8,
    sealed_role_driver: []u8,
    ledger: []u8,
};

fn integrationPaths(allocator: std.mem.Allocator) !IntegrationBinaries {
    const cwd = try std.process.currentPathAlloc(defaultIo(), allocator);
    defer allocator.free(cwd);
    return .{
        .seq = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.seq_path }),
        .cas = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.cas_trial_path }),
        .executor = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.fixture_executor_path }),
        .sealed_executor = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.sealed_fixture_executor_path }),
        .sealed_source_fixture = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.sealed_source_fixture_path }),
        .sealed_grader_fixture = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.sealed_grader_fixture_path }),
        .sealed_grade_materializer_fixture = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.sealed_grade_materializer_fixture_path }),
        .sealed_role_driver = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.sealed_role_driver_path }),
        .ledger = try std.fs.path.resolve(allocator, &.{ cwd, integration_paths.ledger_path }),
    };
}

const DirectScenario =
    \\{
    \\  "schema": "hylo-scenario/v1",
    \\  "campaign_id": "cmp-test",
    \\  "scenario_id": "scenario-holdout",
    \\  "split": "practice",
    \\  "source_refs": [{"kind": "decision_capsule", "ref": "capsule-integration", "fingerprint": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}],
    \\  "source_episode_fingerprint": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    \\  "request": {"message": "Execute the registered bounded trial.", "visible_context": [], "hidden_reference_ref": "local:hidden-integration"},
    \\  "environment": {
    \\    "fidelity": "controlled_replay",
    \\    "fingerprint": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    \\    "repo_revision": "git:0000000000000000000000000000000000000000",
    \\    "adapter": {"id": "cas-trial", "version": "v1", "contract_ref": "artifact:runner", "contract_fingerprint": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
    \\    "snapshot": {"kind": "git", "ref": "git:0000000000000000000000000000000000000000", "fingerprint": "sha256:3333333333333333333333333333333333333333333333333333333333333333"},
    \\    "setup_ref": "artifact:setup",
    \\    "setup_fingerprint": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
    \\    "toolchain": [{"id": "zig", "version": "0.16.0"}],
    \\    "fixtures": [],
    \\    "effect_policy": {"filesystem": "workspace_write", "allowed_paths": [], "network": "deny", "network_allowlist": [], "external_side_effects": "deny", "external_effect_allowlist": []},
    \\    "limitations": []
    \\  },
    \\  "replay_policy_fingerprint": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    \\  "oracles": [{"id": "required-test", "kind": "deterministic", "critical": true, "observation": "registered behavior passes", "grader_ref": "test:required-test", "grader_fingerprint": "sha256:8888888888888888888888888888888888888888888888888888888888888888"}],
    \\  "mutation": null
    \\}
;

fn campaignAlloc(
    allocator: std.mem.Allocator,
    scenario_fingerprint: []const u8,
    executor_path: []const u8,
    runner_path: []const u8,
    ledger_path: []const u8,
) ![]u8 {
    const public_key = try attestation.publicKeyBase64Alloc(allocator, ProofSanitizerSeed);
    defer allocator.free(public_key);
    const public_key_size = try std.base64.standard.Decoder.calcSizeForSlice(public_key);
    const public_key_bytes = try allocator.alloc(u8, public_key_size);
    defer allocator.free(public_key_bytes);
    try std.base64.standard.Decoder.decode(public_key_bytes, public_key);
    const public_key_fingerprint = try digestBytesAlloc(allocator, public_key_bytes);
    defer allocator.free(public_key_fingerprint);
    const trust = try integrationTrustPolicyAlloc(
        allocator,
        executor_path,
        runner_path,
        ledger_path,
    );
    defer allocator.free(trust);
    var trust_parsed = try parseJson(allocator, trust);
    defer trust_parsed.deinit();
    const trust_fingerprint = try hctp.digestValueAlloc(allocator, trust_parsed.value);
    defer allocator.free(trust_fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-campaign/v1\",\"campaign_id\":\"cmp-test\",\"target\":{{\"kind\":\"skill\",\"id\":\"target-skill\",\"baseline_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}},\"source\":{{\"corpus_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"session_refs\":[{{\"kind\":\"codex_session\",\"ref\":\"session-integration\",\"fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"}}],\"exclusions\":[\"current_session\"]}},\"privacy\":{{\"mode\":\"sanitized\",\"redactions\":[\"secrets\",\"private_reasoning\"],\"redaction_receipt\":{{\"schema\":\"hylo-redaction-receipt/v1\",\"tool\":\"seq\",\"version\":\"v1\",\"source_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"output_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"evidence_refs\":[\"seq:integration\"]}}}},\"rubric\":{{\"id\":\"rubric-test\",\"fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"dimensions\":[{{\"id\":\"correctness\",\"kind\":\"deterministic\",\"weight\":1.0,\"critical\":true,\"grader_ref\":\"test:dimension\",\"grader_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\"}}],\"judge\":{{\"kind\":\"composite\",\"id\":\"test-judge\",\"version\":\"1\",\"config_fingerprint\":\"sha256:6666666666666666666666666666666666666666666666666666666666666666\"}},\"pass_policy\":{{\"minimum_aggregate\":1.0,\"zero_critical_violations\":true}}}},\"replay_policy\":{{\"fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"blind_hidden_reference\":true,\"holdout_blind\":true,\"default_fidelity\":\"controlled_replay\",\"repeat_count\":1}},\"stop_policy\":{{\"max_attempts\":10,\"require_holdout_pass\":false,\"zero_critical_violations\":true}},\"change_policy\":{{\"target_change_authority\":\"apply_via_owner\",\"publication_authority\":\"commit\",\"allowed_paths\":[\"target.txt\"],\"require_clean_scope\":true}},\"scenarios_file\":\"scenarios.jsonl\",\"scenario_manifest\":[{{\"scenario_id\":\"scenario-holdout\",\"scenario_fingerprint\":\"{s}\",\"split\":\"practice\"}}],\"protocol_profiles\":[\"hylo-trial/v1\"],\"canonical_json_profile\":{f},\"trial_policy\":{{\"publication_claims\":[\"absolute_qualification\",\"noninferiority\"],\"proof_authority\":{{\"schema\":\"hylo-proof-authority/v1\",\"key_id\":\"integration-proof-source-key\",\"public_key_base64\":{f},\"public_key_fingerprint\":{f},\"producer_id\":\"integration-proof-sanitizer\",\"producer_binary_fingerprint\":\"{s}\"}},\"proof_trust_policy_fingerprint\":{f},\"proof_trust_policy\":{s}}}}}",
        .{ scenario_fingerprint, std.json.fmt(hctp.CanonicalJsonProfile, .{}), std.json.fmt(public_key, .{}), std.json.fmt(public_key_fingerprint, .{}), ProofSanitizerBinary, std.json.fmt(trust_fingerprint, .{}), trust },
    );
}

fn artifactIntentAlloc(
    allocator: std.mem.Allocator,
    kind: []const u8,
    artifact_key: []const u8,
    artifact_bytes: []const u8,
    scenario_id: ?[]const u8,
) ![]u8 {
    var artifact = try parseJson(allocator, artifact_bytes);
    defer artifact.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, artifact.value);
    defer allocator.free(fingerprint);
    const canonical = try hctp.canonicalJsonAlloc(allocator, artifact.value);
    defer allocator.free(canonical);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-event-intent/v1\",\"campaign_id\":\"cmp-test\",\"kind\":");
    try std.json.Stringify.value(kind, .{}, &out.writer);
    try out.writer.writeAll(",\"scenario_id\":");
    try writeOptionalString(&out.writer, scenario_id);
    try out.writer.writeAll(",\"attempt_id\":null,\"grade_id\":null,\"payload\":{");
    const fingerprint_key = try std.fmt.allocPrint(allocator, "{s}_fingerprint", .{artifact_key});
    defer allocator.free(fingerprint_key);
    try std.json.Stringify.value(fingerprint_key, .{}, &out.writer);
    try out.writer.writeByte(':');
    try std.json.Stringify.value(fingerprint, .{}, &out.writer);
    try out.writer.writeByte(',');
    try std.json.Stringify.value(artifact_key, .{}, &out.writer);
    try out.writer.writeByte(':');
    try out.writer.writeAll(canonical);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn runIsolatedCommandAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    label: []const u8,
    command: []const u8,
) ![]u8 {
    const stdout_path = try std.fmt.allocPrint(allocator, "{s}/{s}.stdout", .{ root, label });
    defer allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(allocator, "{s}/{s}.stderr", .{ root, label });
    defer allocator.free(stderr_path);
    const isolated = try std.fmt.allocPrint(allocator, "({s}) >'{s}' 2>'{s}'", .{ command, stdout_path, stderr_path });
    defer allocator.free(isolated);
    const isolated_z = try allocator.dupeZ(u8, isolated);
    defer allocator.free(isolated_z);
    if (libc.system(isolated_z.ptr) != 0) {
        const stderr = durable_store.readFileAlloc(allocator, stderr_path, MaxBytes) catch null;
        defer if (stderr) |bytes| allocator.free(bytes);
        std.debug.print("{s} failed:\n{s}\n", .{ label, stderr orelse "command stderr unavailable" });
        return error.IntegrationCommandFailed;
    }
    return durable_store.readFileAlloc(allocator, stdout_path, MaxBytes);
}

fn commandEventDigest(allocator: std.mem.Allocator, bytes: []const u8, key: []const u8) ![]u8 {
    var parsed = try parseJson(allocator, bytes);
    defer parsed.deinit();
    return allocator.dupe(u8, try requiredString(try object(parsed.value), key));
}

fn gradeReceiptAlloc(allocator: std.mem.Allocator, lane_id: []const u8, arm_id: []const u8, run_fingerprint: []const u8) ![]u8 {
    var grade = try parseJson(allocator, fixtures.valid_grade_receipt);
    defer grade.deinit();
    const root = try objectPtr(&grade.value);
    try root.put(allocator, "lane_id", .{ .string = @constCast(lane_id) });
    try root.put(allocator, "opaque_arm_id", .{ .string = @constCast(arm_id) });
    try root.put(allocator, "run_receipt_fingerprint", .{ .string = @constCast(run_fingerprint) });
    return hctp.canonicalJsonAlloc(allocator, grade.value);
}

fn resultFingerprintAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var parsed = try parseJson(allocator, bytes);
    defer parsed.deinit();
    return allocator.dupe(u8, try requiredString(try object(parsed.value), "result_fingerprint"));
}

const SealedSourceEvidence = struct {
    receipt: []u8,
    practice_receipt: []u8,
    holdout_receipt: []u8,
    public_metadata: []u8,
};

fn appendJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn runSealedSourceFixtureAlloc(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
) !SealedSourceEvidence {
    const output = try role_driver.requestAlloc(
        "{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"source\"}",
    );
    defer allocator.free(output);
    var parsed = try parseJson(allocator, output);
    defer parsed.deinit();
    const response = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(response, "schema"), "hctp-role-source/v1") or
        try requiredBool(response, "plaintext_returned") or try requiredBool(response, "secret_returned"))
    {
        return error.SealedSourcePlaintextLeak;
    }
    return .{
        .receipt = try hctp.canonicalJsonAlloc(allocator, try required(response, "source_receipt")),
        .practice_receipt = try hctp.canonicalJsonAlloc(
            allocator,
            try required(response, "practice_source_receipt"),
        ),
        .holdout_receipt = try hctp.canonicalJsonAlloc(
            allocator,
            try required(response, "holdout_source_receipt"),
        ),
        .public_metadata = try hctp.canonicalJsonAlloc(allocator, try required(response, "public_metadata")),
    };
}

fn sealedTrialAlloc(
    allocator: std.mem.Allocator,
    source_receipt_text: []const u8,
    executor_path: []const u8,
    runner_path: []const u8,
    ledger_path: []const u8,
    materializer_public_key: []const u8,
    runner_public_key: []const u8,
    absolute_grader_public_key: []const u8,
    pair_grader_public_key: []const u8,
    grader_binary_fingerprint: []const u8,
    presentation_materializer_binary_fingerprint: []const u8,
    baseline_revision: []const u8,
    baseline_snapshot_fingerprint: []const u8,
    candidate_snapshot_fingerprint: []const u8,
    target_common_projection: []const u8,
    target_common_projection_fingerprint: []const u8,
    staged_diff_fingerprint: []const u8,
) ![]u8 {
    var source_parsed = try parseJson(allocator, source_receipt_text);
    defer source_parsed.deinit();
    const source = try object(source_parsed.value);
    const source_fingerprint = try requiredString(source, "receipt_fingerprint");
    const source_attestation = try requiredObject(source, "source_owner_attestation");
    const source_producer = try requiredObject(source_attestation, "producer");
    const cases = try requiredArray(source, "cases");
    if (cases.items.len == 0) return error.SealedSourceDenominatorChanged;
    const executor_fingerprint = try fileFingerprintAlloc(allocator, executor_path);
    defer allocator.free(executor_fingerprint);
    const runner_binary_fingerprint = try fileFingerprintAlloc(allocator, runner_path);
    defer allocator.free(runner_binary_fingerprint);
    const ledger_fingerprint = try fileFingerprintAlloc(allocator, ledger_path);
    defer allocator.free(ledger_fingerprint);

    const trust_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"policy-sealed-positive\",\"keys\":[" ++
            "{{\"key_id\":{f},\"public_key_base64\":{f},\"allowed_roles\":[\"source_owner\"],\"producer_ids\":[{f}],\"producer_binary_fingerprints\":[{f}]}}," ++
            "{{\"key_id\":\"runner-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"cas-trial\",\"cas-trial-executor\",\"hylo-ledger\"],\"producer_binary_fingerprints\":[{f},{f},{f}]}}," ++
            "{{\"key_id\":\"absolute-grader-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"absolute_grader\"],\"producer_ids\":[\"deterministic-grader\"],\"producer_binary_fingerprints\":[{f}]}}," ++
            "{{\"key_id\":\"pair-grader-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"pair_grader\"],\"producer_ids\":[\"blind-pair-grader\"],\"producer_binary_fingerprints\":[{f}]}}," ++
            "{{\"key_id\":\"materializer-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"materializer\"],\"producer_ids\":[\"seq-materializer\",\"hctp-grade-broker\"]}}]," ++
            "\"separation\":{{\"runner_and_pair_grader_distinct\":true,\"materializer_and_pair_grader_distinct\":true,\"human_confirmation_required_for_human_grade\":true}}}}",
        .{
            std.json.fmt(try requiredString(source_producer, "key_id"), .{}),
            std.json.fmt(try requiredString(source_producer, "public_key_base64"), .{}),
            std.json.fmt(try requiredString(source_producer, "id"), .{}),
            std.json.fmt(try requiredString(source_producer, "binary_fingerprint"), .{}),
            std.json.fmt(runner_public_key, .{}),
            std.json.fmt(runner_binary_fingerprint, .{}),
            std.json.fmt(executor_fingerprint, .{}),
            std.json.fmt(ledger_fingerprint, .{}),
            std.json.fmt(absolute_grader_public_key, .{}),
            std.json.fmt(grader_binary_fingerprint, .{}),
            std.json.fmt(pair_grader_public_key, .{}),
            std.json.fmt(grader_binary_fingerprint, .{}),
            std.json.fmt(materializer_public_key, .{}),
        },
    );
    defer allocator.free(trust_text);
    var trust_parsed = try parseJson(allocator, trust_text);
    defer trust_parsed.deinit();
    const trust_fingerprint = try hctp.digestValueAlloc(allocator, trust_parsed.value);
    defer allocator.free(trust_fingerprint);

    const materializer_contract_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-case-materializer-contract/v1\",\"controller_id\":\"hylo-controller\",\"runner_id\":\"cas-trial\",\"materializer_id\":\"seq-materializer\",\"materializer_version\":\"v1\",\"materializer_binary_fingerprint\":{f},\"materializer_key_id\":\"materializer-key\",\"runner_key_id\":\"runner-key\",\"capability_delivery\":\"anonymous_fd\",\"visible_input_delivery\":\"anonymous_fd\",\"source_profile_delivery\":\"anonymous_fd\",\"receiver_binding\":\"runner_key\",\"receiver_role\":\"runner\",\"single_use\":true,\"limitations\":[\"role-bound single-use FD capabilities\"]}}",
        .{std.json.fmt(try requiredString(source_producer, "binary_fingerprint"), .{})},
    );
    defer allocator.free(materializer_contract_text);
    var materializer_contract_parsed = try parseJson(allocator, materializer_contract_text);
    defer materializer_contract_parsed.deinit();
    const materializer_contract_fingerprint = try hctp.digestValueAlloc(allocator, materializer_contract_parsed.value);
    defer allocator.free(materializer_contract_fingerprint);

    const runner_contract_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-hylo-runner/v1\"," ++
            "\"executor_binary_fingerprint\":{f}," ++
            "\"ledger_binary_fingerprint\":{f}," ++
            "\"executor_request_schema\":\"cas-trial-executor-request/v2\"," ++
            "\"executor_authority\":{{" ++
            "\"producer_id\":\"cas-trial-executor\"," ++
            "\"key_id\":\"runner-key\",\"binary_fingerprint\":{f}," ++
            "\"authorized_observations\":[\"runtime\",\"isolation\",\"effects\"," ++
            "\"terminal\",\"evidence\",\"execution_audit\",\"native_receipt\"]}}," ++
            "\"ledger_authority\":{{\"producer_id\":\"hylo-ledger\"," ++
            "\"key_id\":\"runner-key\",\"binary_fingerprint\":{f}}}," ++
            "\"capability_seal\":{{\"schema\":\"cas-capability-seal/v1\"," ++
            "\"profile_id\":\"cas-capability-sealed-v1\"," ++
            "\"target_data_mode\":\"cas-content-addressed-pre-post-equality\"," ++
            "\"effect_policy_fingerprint\":{f}," ++
            "\"effect_mediation\":\"attested-executor\"," ++
            "\"default_effect_decision\":\"deny\"," ++
            "\"cas_observations\":[\"target-package-tree\",\"execution-tree\"," ++
            "\"output-carrier\",\"process-group\"],\"os_confinement\":false}}," ++
            "\"capability_delivery\":\"anonymous_fd\"," ++
            "\"receiver_binding\":\"runner_key\",\"single_use\":true," ++
            "\"atomic_claim\":true,\"fresh_workspace\":true,\"fresh_thread\":true," ++
            "\"materializes_opaque_arm\":true,\"maximum_handles_per_lane\":1," ++
            "\"maximum_retries_per_lane\":0}}",
        .{ std.json.fmt(executor_fingerprint, .{}), std.json.fmt(ledger_fingerprint, .{}), std.json.fmt(executor_fingerprint, .{}), std.json.fmt(ledger_fingerprint, .{}), std.json.fmt(SealedEffectPolicyFingerprint, .{}) },
    );
    defer allocator.free(runner_contract_text);
    var runner_contract_parsed = try parseJson(allocator, runner_contract_text);
    defer runner_contract_parsed.deinit();
    const runner_contract_fingerprint = try hctp.digestValueAlloc(allocator, runner_contract_parsed.value);
    defer allocator.free(runner_contract_fingerprint);

    const arm_map_text = "{\"schema\":\"hylo-arm-map/v1\",\"trial_id\":\"trial-sealed-positive\",\"mapping\":{\"arm-0\":\"baseline\",\"arm-1\":\"candidate\"},\"nonce\":\"sealed-positive-00112233445566778899aabbccddeeff\"}";
    var arm_map_parsed = try parseJson(allocator, arm_map_text);
    defer arm_map_parsed.deinit();
    const arm_commitment = try hctp.digestValueAlloc(allocator, arm_map_parsed.value);
    defer allocator.free(arm_commitment);

    const witness_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-intervention-witness/v1\",\"trial_id\":\"trial-sealed-positive\",\"factor_kind\":\"target_snapshot\"," ++
            "\"arm_values\":{{\"arm-0\":{{\"fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"snapshot_fingerprint\":{f}}}," ++
            "\"arm-1\":{{\"fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"snapshot_fingerprint\":{f}}}}}," ++
            "\"common_projection\":{{\"fingerprint\":{f},\"compared_fields\":[\"environment\",\"model_policy\",\"replay_policy\",\"effect_policy\"]}}," ++
            "\"differing_projection\":{{\"allowed_roots\":[\"target.txt\"],\"observed_paths\":[\"target.txt\"],\"diff_fingerprint\":{f}}}," ++
            "\"verifier\":{{\"id\":\"git-target-projection\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\"}},\"verdict\":{{\"one_factor_closed\":true}},\"limitations\":[]}}",
        .{
            std.json.fmt(baseline_snapshot_fingerprint, .{}),
            std.json.fmt(candidate_snapshot_fingerprint, .{}),
            std.json.fmt(target_common_projection_fingerprint, .{}),
            std.json.fmt(staged_diff_fingerprint, .{}),
        },
    );
    defer allocator.free(witness_text);
    var witness_parsed = try parseJson(allocator, witness_text);
    defer witness_parsed.deinit();
    const witness_fingerprint = try hctp.digestValueAlloc(allocator, witness_parsed.value);
    defer allocator.free(witness_fingerprint);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-trial/v1\",\"canonical_json_profile\":");
    try appendJsonString(&out.writer, hctp.CanonicalJsonProfile);
    try out.writer.writeAll(",\"trial_id\":\"trial-sealed-positive\",\"campaign_id\":\"cmp-sealed-positive\",\"purpose\":\"promotion\",\"target_epoch\":{\"change_id\":\"change-sealed-positive\",\"before_target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"after_target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},");
    try out.writer.writeAll("\"hypothesis\":{\"hypothesis_id\":\"hypothesis-sealed-positive\",\"claim\":\"Candidate improves sealed holdout correctness.\",\"predicted_direction\":\"candidate_better\",\"primary_failure_signature\":\"baseline omits the required behavior\",\"competing_explanations\":[],\"falsifier\":\"The cluster-balanced lower bound does not exceed 0.05.\"},");
    try out.writer.print("\"arms\":[{{\"arm_id\":\"arm-0\",\"value_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"materialization_ref\":\"git-revision:{s}\",\"materialization_fingerprint\":{f}}},{{\"arm_id\":\"arm-1\",\"value_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"materialization_ref\":\"git-revision:INDEX\",\"materialization_fingerprint\":{f}}}],", .{ baseline_revision, std.json.fmt(baseline_snapshot_fingerprint, .{}), std.json.fmt(candidate_snapshot_fingerprint, .{}) });
    try out.writer.print(
        "\"arm_map_commitment\":{{\"algorithm\":{f},\"fingerprint\":{f}}},",
        .{ std.json.fmt(hctp.CanonicalJsonSha256Algorithm, .{}), std.json.fmt(arm_commitment, .{}) },
    );
    try out.writer.print("\"factor\":{{\"kind\":\"target_snapshot\",\"verifier\":{{\"id\":\"git-target-projection\",\"version\":\"v1\",\"fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\"}},\"common_projection_fingerprint\":{f},\"allowed_difference_roots\":[\"target.txt\"],\"target_common_projection\":{s},\"intervention_witness_ref\":\"artifact:sealed-positive-witness\",\"intervention_witness_fingerprint\":{f},\"intervention_witness\":{s}}},", .{ std.json.fmt(target_common_projection_fingerprint, .{}), target_common_projection, std.json.fmt(witness_fingerprint, .{}), witness_text });
    try out.writer.writeAll("\"allocation\":{\"method\":\"fixed\",\"seed_commitment\":null,\"position_balance_required\":true},\"units\":[");
    for (cases.items, 0..) |case_value, index| {
        if (index != 0) try out.writer.writeByte(',');
        const case = try object(case_value);
        const unit_id = try requiredString(case, "unit_id");
        const scenario_id = try requiredString(case, "scenario_id");
        const cluster_id = try requiredString(case, "independence_cluster_id");
        try out.writer.writeAll("{\"unit_id\":");
        try appendJsonString(&out.writer, unit_id);
        try out.writer.writeAll(",\"scenario_id\":");
        try appendJsonString(&out.writer, scenario_id);
        try out.writer.writeAll(",\"split\":");
        try appendJsonString(&out.writer, try requiredString(case, "split"));
        try out.writer.writeAll(",\"independence_cluster_id\":");
        try appendJsonString(&out.writer, cluster_id);
        try out.writer.writeAll(",\"source_profile\":");
        const source_profile_json = try hctp.canonicalJsonAlloc(allocator, try required(case, "source_profile"));
        defer allocator.free(source_profile_json);
        try out.writer.writeAll(source_profile_json);
        try out.writer.writeAll(",\"pairs\":[{\"pair_id\":");
        const pair_id = try std.fmt.allocPrint(allocator, "pair-holdout-{d}", .{index + 1});
        defer allocator.free(pair_id);
        const block_id = try std.fmt.allocPrint(allocator, "block-holdout-{d}", .{index + 1});
        defer allocator.free(block_id);
        const lane0 = try std.fmt.allocPrint(allocator, "lane-holdout-{d}-x", .{index + 1});
        defer allocator.free(lane0);
        const lane1 = try std.fmt.allocPrint(allocator, "lane-holdout-{d}-y", .{index + 1});
        defer allocator.free(lane1);
        try appendJsonString(&out.writer, pair_id);
        try out.writer.writeAll(",\"block_id\":");
        try appendJsonString(&out.writer, block_id);
        try out.writer.writeAll(",\"repeat_index\":1,\"order\":[\"arm-0\",\"arm-1\"],\"shared_seed\":null,\"lanes\":{\"arm-0\":{\"lane_id\":");
        try appendJsonString(&out.writer, lane0);
        try out.writer.writeAll("},\"arm-1\":{\"lane_id\":");
        try appendJsonString(&out.writer, lane1);
        try out.writer.writeAll("}}}]}");
    }
    try out.writer.writeAll("],\"sealing\":{\"case_visibility\":\"case_blind\",\"arm_visibility\":\"opaque_until_reveal\",\"grade_visibility\":\"opaque_until_reveal\",\"reveal_scope\":\"campaign_holdout\",\"visible_input_commitments\":[");
    for (cases.items, 0..) |case_value, index| {
        if (index != 0) try out.writer.writeByte(',');
        try appendJsonString(&out.writer, try requiredString(try object(case_value), "visible_input_fingerprint"));
    }
    try out.writer.writeAll("],\"hidden_reference_commitments\":[");
    for (cases.items, 0..) |case_value, index| {
        if (index != 0) try out.writer.writeByte(',');
        try appendJsonString(&out.writer, try requiredString(try object(case_value), "hidden_reference_fingerprint"));
    }
    try out.writer.print("],\"case_materializer_ref\":\"artifact:seq-materializer\",\"case_materializer_fingerprint\":{f},\"case_materializer_contract\":{s},\"source_selection_receipt_ref\":\"artifact:seq-source-selection\",\"source_selection_receipt_fingerprint\":{f},\"source_selection_receipt\":{s}}},", .{ std.json.fmt(materializer_contract_fingerprint, .{}), materializer_contract_text, std.json.fmt(source_fingerprint, .{}), source_receipt_text });
    try out.writer.print("\"execution\":{{\"runner_contract_ref\":\"artifact:cas-hylo-runner\",\"runner_contract_fingerprint\":{f},\"runner_contract\":{s},\"runner_authority\":{{\"producer_id\":\"cas-trial\",\"producer_version\":{f},\"binary_fingerprint\":{f},\"key_id\":\"runner-key\"}},\"reset_policy\":{{\"fresh_thread\":true,\"fresh_workspace\":true,\"clear_target_local_caches\":true,\"sibling_output_isolation\":true}},\"model_policy_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"effect_policy_fingerprint\":{f},\"maximum_lane_duration_ms\":1800000,\"maximum_tokens_per_lane\":120000}},", .{ std.json.fmt(runner_contract_fingerprint, .{}), runner_contract_text, std.json.fmt(integration_paths.cas_version, .{}), std.json.fmt(runner_binary_fingerprint, .{}), std.json.fmt(SealedEffectPolicyFingerprint, .{}) });
    try out.writer.print("\"grading\":{{\"rubric_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"mode\":\"composite\",\"judge_contracts\":[{{\"schema\":\"hylo-judge-contract/v1\",\"contract_id\":\"blind-pair-judge-v1\",\"version\":\"v1\",\"kind\":\"deterministic\",\"contract_ref\":\"artifact:sealed-blind-pair-grader\",\"contract_fingerprint\":\"sha256:9b296a9dec19da50db8597c607eef413f7d43fd173b9a8fd6d94075af9890432\",\"contract\":{{\"policy\":\"registered-primary-dimensions\",\"prompt_template\":\"blind-pair-v1\"}}}}],\"oracle_contracts\":[\"test:required-test\"],\"producer_authorities\":[{{\"role\":\"absolute_grader\",\"producer_id\":\"deterministic-grader\",\"producer_version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":\"absolute-grader-key\"}},{{\"role\":\"pair_grader\",\"producer_id\":\"blind-pair-grader\",\"producer_version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":\"pair-grader-key\"}}],\"presentation_materializer\":{{\"schema\":\"hylo-grade-presentation-materializer/v1\",\"producer_id\":\"hctp-grade-broker\",\"producer_version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":\"materializer-key\",\"role\":\"materializer\",\"single_use_capabilities\":true}},\"critical_policy\":{{\"derived_only\":true,\"model_may_be_sole_critical_authority\":false}},\"require_all_terminal_before_reveal\":true,\"require_all_grades_before_reveal\":true}},", .{ std.json.fmt(grader_binary_fingerprint, .{}), std.json.fmt(grader_binary_fingerprint, .{}), std.json.fmt(presentation_materializer_binary_fingerprint, .{}) });
    try out.writer.writeAll("\"estimand\":{\"primary_dimensions\":[\"correctness\"],\"aggregation_unit\":\"independence_cluster\",\"effect_direction\":\"candidate_minus_baseline\",\"minimum_effects\":{\"correctness\":0.05},\"noninferiority_margins\":{\"correctness\":0.0},\"zero_critical_regressions\":true,\"absolute_candidate_policy\":{\"require_all_candidate_lanes_pass\":true},\"uncertainty\":{\"method\":\"cluster_bootstrap\",\"confidence\":0.95,\"minimum_independent_clusters\":5}},");
    try out.writer.writeAll("\"calibration\":{\"required_null_sentinel_refs\":[],\"required_positive_sentinel_refs\":[],\"null_bias_tolerance\":0.05,\"positive_sensitivity_floor\":0.8},\"stop_policy\":{\"kind\":\"fixed\",\"required_pairs_per_unit\":1,\"maximum_invalid_lanes\":0},");
    try out.writer.print("\"assurance\":{{\"required_level\":\"sealed\",\"trust_policy_ref\":\"artifact:sealed-trust\",\"trust_policy_fingerprint\":{f},\"trust_policy\":{s},\"required_distinct_roles\":[\"runner\",\"absolute_grader\",\"pair_grader\",\"materializer\"]}}}}", .{ std.json.fmt(trust_fingerprint, .{}), trust_text });
    return out.toOwnedSlice();
}

fn sealedScenarioAlloc(
    allocator: std.mem.Allocator,
    case: std.json.ObjectMap,
    grader_binary_fingerprint: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-scenario/v1\",\"campaign_id\":\"cmp-sealed-positive\",\"scenario_id\":{f},\"split\":{f},\"case_visibility\":\"case_blind\",\"source_episode_fingerprint\":{f},\"visible_input_fingerprint\":{f},\"hidden_reference_fingerprint\":{f},\"source_profile_fingerprint\":{f},\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"effect_policy\":{s},\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"oracle_commitments\":[{{\"id\":\"required-test\",\"kind\":\"deterministic\",\"critical\":true,\"grader_ref\":\"hctp:sealed-output-oracle\",\"grader_fingerprint\":{f}}}],\"limitations\":[]}}",
        .{
            std.json.fmt(try requiredString(case, "scenario_id"), .{}),
            std.json.fmt(try requiredString(case, "split"), .{}),
            std.json.fmt(try requiredString(case, "source_episode_fingerprint"), .{}),
            std.json.fmt(try requiredString(case, "visible_input_fingerprint"), .{}),
            std.json.fmt(try requiredString(case, "hidden_reference_fingerprint"), .{}),
            std.json.fmt(try requiredString(case, "source_profile_fingerprint"), .{}),
            SealedEffectPolicyJson,
            std.json.fmt(grader_binary_fingerprint, .{}),
        },
    );
}

fn sealedCampaignAlloc(
    allocator: std.mem.Allocator,
    source_receipt: std.json.ObjectMap,
    grader_binary_fingerprint: []const u8,
    baseline_bundle_fingerprint: []const u8,
) ![]u8 {
    const cases = try requiredArray(source_receipt, "cases");
    var manifest: std.Io.Writer.Allocating = .init(allocator);
    defer manifest.deinit();
    try manifest.writer.writeByte('[');
    for (cases.items, 0..) |case_value, index| {
        if (index != 0) try manifest.writer.writeByte(',');
        const case = try object(case_value);
        const scenario = try sealedScenarioAlloc(allocator, case, grader_binary_fingerprint);
        defer allocator.free(scenario);
        var scenario_parsed = try parseJson(allocator, scenario);
        defer scenario_parsed.deinit();
        const fingerprint = try hctp.digestValueAlloc(allocator, scenario_parsed.value);
        defer allocator.free(fingerprint);
        try manifest.writer.print(
            "{{\"scenario_id\":{f},\"scenario_fingerprint\":{f},\"split\":{f}}}",
            .{
                std.json.fmt(try requiredString(case, "scenario_id"), .{}),
                std.json.fmt(fingerprint, .{}),
                std.json.fmt(try requiredString(case, "split"), .{}),
            },
        );
    }
    try manifest.writer.writeByte(']');
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-campaign/v1\",\"campaign_id\":\"cmp-sealed-positive\",\"target\":{{\"kind\":\"skill\",\"id\":\"target-skill\",\"baseline_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"identity_contract\":\"bundle_snapshot/v1\",\"baseline_bundle_fingerprint\":{f}}},\"source\":{{\"corpus_fingerprint\":{f},\"session_refs\":[{{\"kind\":\"seq_source_selection\",\"ref\":\"sealed-source\",\"fingerprint\":{f}}}],\"exclusions\":[\"current_session\"]}},\"privacy\":{{\"mode\":\"sanitized\",\"redactions\":[\"secrets\",\"private_reasoning\"],\"redaction_receipt\":{{\"schema\":\"hylo-redaction-receipt/v1\",\"tool\":\"seq\",\"version\":\"v1\",\"source_fingerprint\":{f},\"output_fingerprint\":{f},\"evidence_refs\":[\"seq:sealed-source\"]}}}},\"rubric\":{{\"id\":\"rubric-sealed\",\"fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"dimensions\":[{{\"id\":\"correctness\",\"kind\":\"deterministic\",\"weight\":1.0,\"critical\":true,\"grader_ref\":\"hctp:sealed-output\",\"grader_fingerprint\":{f}}}],\"judge\":{{\"kind\":\"deterministic\",\"id\":\"sealed-output-grader\",\"version\":\"v1\",\"config_fingerprint\":\"sha256:6666666666666666666666666666666666666666666666666666666666666666\"}},\"pass_policy\":{{\"minimum_aggregate\":1.0,\"zero_critical_violations\":true}}}},\"replay_policy\":{{\"fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"blind_hidden_reference\":true,\"holdout_blind\":true,\"default_fidelity\":\"controlled_replay\",\"repeat_count\":1}},\"stop_policy\":{{\"max_attempts\":20,\"require_holdout_pass\":true,\"zero_critical_violations\":true}},\"change_policy\":{{\"target_change_authority\":\"apply_via_owner\",\"publication_authority\":\"commit\",\"allowed_paths\":[\"target.txt\"],\"require_clean_scope\":true}},\"scenarios_file\":\"scenarios.jsonl\",\"scenario_manifest\":{s},\"protocol_profiles\":[\"hylo-trial/v1\"],\"canonical_json_profile\":{f},\"trial_policy\":{{\"publication_claims\":[\"absolute_qualification\",\"noninferiority\",\"holdout_improvement\"]}}}}",
        .{
            std.json.fmt(baseline_bundle_fingerprint, .{}),
            std.json.fmt(try requiredString(source_receipt, "receipt_fingerprint"), .{}),
            std.json.fmt(try requiredString(source_receipt, "receipt_fingerprint"), .{}),
            std.json.fmt(try requiredString(source_receipt, "receipt_fingerprint"), .{}),
            std.json.fmt(try requiredString(source_receipt, "receipt_fingerprint"), .{}),
            std.json.fmt(grader_binary_fingerprint, .{}),
            manifest.written(),
            std.json.fmt(hctp.CanonicalJsonProfile, .{}),
        },
    );
}

fn sealedArtifactIntentAlloc(
    allocator: std.mem.Allocator,
    kind: []const u8,
    artifact_key: []const u8,
    artifact_bytes: []const u8,
    scenario_id: ?[]const u8,
) ![]u8 {
    var artifact = try parseJson(allocator, artifact_bytes);
    defer artifact.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, artifact.value);
    defer allocator.free(fingerprint);
    const canonical = try hctp.canonicalJsonAlloc(allocator, artifact.value);
    defer allocator.free(canonical);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-event-intent/v1\",\"campaign_id\":\"cmp-sealed-positive\",\"kind\":");
    try appendJsonString(&out.writer, kind);
    try out.writer.writeAll(",\"scenario_id\":");
    try writeOptionalString(&out.writer, scenario_id);
    try out.writer.writeAll(",\"attempt_id\":null,\"grade_id\":null,\"payload\":{");
    const fingerprint_key = try std.fmt.allocPrint(allocator, "{s}_fingerprint", .{artifact_key});
    defer allocator.free(fingerprint_key);
    try appendJsonString(&out.writer, fingerprint_key);
    try out.writer.writeByte(':');
    try appendJsonString(&out.writer, fingerprint);
    try out.writer.writeByte(',');
    try appendJsonString(&out.writer, artifact_key);
    try out.writer.writeByte(':');
    try out.writer.writeAll(canonical);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

const SealedPracticeTrialIdentity = struct {
    trial_id: []const u8,
    hypothesis_id: []const u8,
    pair_id: []const u8,
    block_id: []const u8,
    lane_a0: []const u8,
    lane_a1: []const u8,
    nonce: []const u8,
};

fn sealedPracticeTrialAlloc(
    allocator: std.mem.Allocator,
    promotion_trial: []const u8,
    practice_source_receipt_text: []const u8,
    factor_ref: []const u8,
    factor_fingerprint: []const u8,
    identity: SealedPracticeTrialIdentity,
) ![]u8 {
    var parsed = try parseJson(allocator, promotion_trial);
    defer parsed.deinit();
    const root = try objectPtr(&parsed.value);
    try root.put(allocator, "trial_id", .{ .string = @constCast(identity.trial_id) });
    try root.put(allocator, "purpose", .{ .string = @constCast("practice_repair") });
    const epoch = try objectPtr(root.getPtr("target_epoch") orelse return error.RequiredFieldMissing);
    try epoch.put(allocator, "change_id", .null);
    try epoch.put(allocator, "after_target_fingerprint", .{ .string = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") });
    const hypothesis = try objectPtr(root.getPtr("hypothesis") orelse return error.RequiredFieldMissing);
    try hypothesis.put(allocator, "hypothesis_id", .{ .string = @constCast(identity.hypothesis_id) });
    try hypothesis.put(allocator, "claim", .{ .string = @constCast("The unchanged baseline remains absolutely unqualified on the sealed practice case.") });
    try hypothesis.put(allocator, "predicted_direction", .{ .string = @constCast("equivalent") });
    try hypothesis.put(allocator, "primary_failure_signature", .{ .string = @constCast("baseline omits the required behavior") });
    try hypothesis.put(allocator, "falsifier", .{ .string = @constCast("Either identical baseline arm passes the absolute gate.") });

    const arms = try arrayPtr(root.getPtr("arms") orelse return error.RequiredFieldMissing);
    if (arms.items.len != 2) return error.PairShapeInvalid;
    for (arms.items) |*arm_value| {
        const arm = try objectPtr(arm_value);
        try arm.put(allocator, "value_fingerprint", .{ .string = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") });
        try arm.put(allocator, "materialization_ref", .{ .string = @constCast(factor_ref) });
        try arm.put(allocator, "materialization_fingerprint", .{ .string = @constCast(factor_fingerprint) });
    }
    const arm_map_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-arm-map/v1\",\"trial_id\":{f},\"mapping\":{{\"arm-0\":\"baseline\",\"arm-1\":\"candidate\"}},\"nonce\":{f}}}",
        .{ std.json.fmt(identity.trial_id, .{}), std.json.fmt(identity.nonce, .{}) },
    );
    defer allocator.free(arm_map_text);
    var arm_map = try parseJson(allocator, arm_map_text);
    defer arm_map.deinit();
    const arm_commitment = try hctp.digestValueAlloc(allocator, arm_map.value);
    defer allocator.free(arm_commitment);
    const commitment = try objectPtr(root.getPtr("arm_map_commitment") orelse return error.RequiredFieldMissing);
    try commitment.put(allocator, "fingerprint", .{ .string = arm_commitment });

    const verifier_fingerprint = "sha256:4444444444444444444444444444444444444444444444444444444444444444";
    const witness_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-intervention-witness/v1\",\"trial_id\":{f},\"factor_kind\":\"null\",\"arm_values\":{{\"arm-0\":{{\"fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"snapshot_fingerprint\":{f}}},\"arm-1\":{{\"fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"snapshot_fingerprint\":{f}}}}},\"common_projection\":{{\"fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\",\"compared_fields\":[\"environment\",\"model_policy\",\"replay_policy\",\"effect_policy\"]}},\"differing_projection\":{{\"allowed_roots\":[],\"observed_paths\":[],\"diff_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"}},\"verifier\":{{\"id\":\"identical-projection\",\"version\":\"v1\",\"binary_fingerprint\":\"{s}\"}},\"verdict\":{{\"one_factor_closed\":true}},\"limitations\":[]}}",
        .{ std.json.fmt(identity.trial_id, .{}), std.json.fmt(factor_fingerprint, .{}), std.json.fmt(factor_fingerprint, .{}), verifier_fingerprint },
    );
    defer allocator.free(witness_text);
    var witness = try parseJson(allocator, witness_text);
    defer witness.deinit();
    const witness_fingerprint = try hctp.digestValueAlloc(allocator, witness.value);
    defer allocator.free(witness_fingerprint);
    const factor_text = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"null\",\"verifier\":{{\"id\":\"identical-projection\",\"version\":\"v1\",\"fingerprint\":\"{s}\"}},\"common_projection_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\",\"allowed_difference_roots\":[],\"intervention_witness_ref\":\"artifact:sealed-bootstrap-witness\",\"intervention_witness_fingerprint\":{f},\"intervention_witness\":{s}}}",
        .{ verifier_fingerprint, std.json.fmt(witness_fingerprint, .{}), witness_text },
    );
    defer allocator.free(factor_text);
    var factor = try parseJson(allocator, factor_text);
    defer factor.deinit();
    try root.put(allocator, "factor", factor.value);

    const units = try arrayPtr(root.getPtr("units") orelse return error.RequiredFieldMissing);
    var practice_index: ?usize = null;
    for (units.items, 0..) |unit_value, index| {
        const unit = try object(unit_value);
        if (std.mem.eql(u8, try requiredString(unit, "split"), "practice")) practice_index = index;
    }
    const unit_index = practice_index orelse return error.PracticeScenarioMissing;
    const practice_unit = units.items[unit_index];
    units.clearRetainingCapacity();
    try units.append(practice_unit);
    const sealing = try objectPtr(root.getPtr("sealing") orelse return error.RequiredFieldMissing);
    try sealing.put(allocator, "reveal_scope", .{ .string = @constCast("trial") });
    var practice_source_receipt = try parseJson(allocator, practice_source_receipt_text);
    defer practice_source_receipt.deinit();
    const practice_source_root = try object(practice_source_receipt.value);
    try sealing.put(
        allocator,
        "source_selection_receipt_ref",
        .{ .string = @constCast("artifact:seq-source-selection-practice") },
    );
    try sealing.put(
        allocator,
        "source_selection_receipt_fingerprint",
        .{ .string = @constCast(try requiredString(practice_source_root, "receipt_fingerprint")) },
    );
    try sealing.put(allocator, "source_selection_receipt", practice_source_receipt.value);
    inline for (.{ "visible_input_commitments", "hidden_reference_commitments" }) |key| {
        const commitments = try arrayPtr(sealing.getPtr(key) orelse return error.RequiredFieldMissing);
        if (unit_index >= commitments.items.len) return error.PracticeScenarioMissing;
        const practice_commitment = commitments.items[unit_index];
        commitments.clearRetainingCapacity();
        try commitments.append(practice_commitment);
    }
    const unit = try objectPtr(&units.items[0]);
    const pairs = try arrayPtr(unit.getPtr("pairs") orelse return error.RequiredFieldMissing);
    if (pairs.items.len != 1) return error.PairShapeInvalid;
    const pair = try objectPtr(&pairs.items[0]);
    try pair.put(allocator, "pair_id", .{ .string = @constCast(identity.pair_id) });
    try pair.put(allocator, "block_id", .{ .string = @constCast(identity.block_id) });
    const lanes = try objectPtr(pair.getPtr("lanes") orelse return error.RequiredFieldMissing);
    const lane0 = try objectPtr(lanes.getPtr("arm-0") orelse return error.RequiredFieldMissing);
    const lane1 = try objectPtr(lanes.getPtr("arm-1") orelse return error.RequiredFieldMissing);
    try lane0.put(allocator, "lane_id", .{ .string = @constCast(identity.lane_a0) });
    try lane1.put(allocator, "lane_id", .{ .string = @constCast(identity.lane_a1) });

    const estimand = try objectPtr(root.getPtr("estimand") orelse return error.RequiredFieldMissing);
    const uncertainty = try objectPtr(estimand.getPtr("uncertainty") orelse return error.RequiredFieldMissing);
    try uncertainty.put(allocator, "method", .{ .string = @constCast("none") });
    try uncertainty.put(allocator, "minimum_independent_clusters", .{ .integer = 1 });
    return hctp.canonicalJsonAlloc(allocator, parsed.value);
}

fn sealedRevealTemplateAlloc(allocator: std.mem.Allocator, trial_id: []const u8, bootstrap: bool) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-trial-reveal/v1\",\"trial_id\":{f},\"mapping\":{{\"arm-0\":\"baseline\",\"arm-1\":\"candidate\"}},\"nonce\":{f},\"baseline_target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"candidate_target_fingerprint\":{f},\"candidate_change_id\":{f},\"revealed_at_scope\":{f},\"materialization_receipts\":[]}}",
        .{
            std.json.fmt(trial_id, .{}),
            std.json.fmt(if (bootstrap) "sealed-bootstrap-00112233445566778899aabbccddeeff" else "sealed-positive-00112233445566778899aabbccddeeff", .{}),
            std.json.fmt(if (bootstrap) "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .{}),
            std.json.fmt(if (bootstrap) @as(?[]const u8, null) else @as(?[]const u8, "change-sealed-positive"), .{}),
            std.json.fmt(if (bootstrap) "trial" else "campaign_holdout", .{}),
        },
    );
}

fn registerSealedTrial(allocator: std.mem.Allocator, state: *hctp.CampaignTrials, trial_text: []const u8) !void {
    var validation = try hctp.validateTrialAlloc(allocator, trial_text);
    defer validation.deinit(allocator);
    var trial = try parseJson(allocator, trial_text);
    defer trial.deinit();
    const payload = try trialRegistrationPayloadAlloc(allocator, validation.fingerprint, trial.value);
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyRegistered(allocator, state, parsed.value, 1, RegistrationDigest);
}

fn digestLabelAlloc(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    return digestBytesAlloc(allocator, label);
}

fn startSealedLane(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    lane_id: []const u8,
    lease_digest: []const u8,
    input_fingerprint: []const u8,
    sequence: u64,
    start_digest: []const u8,
) !void {
    const trial = state.findTrial("trial-sealed-positive") orelse return error.TrialMissing;
    const lane = trial.findLane(lane_id) orelse return error.LaneMissing;
    const manifest_fingerprint = try hctp.laneManifestFingerprintAlloc(allocator, lane);
    defer allocator.free(manifest_fingerprint);
    var trial_parsed = try parseJson(allocator, trial.trial_json);
    defer trial_parsed.deinit();
    const trial_root = try object(trial_parsed.value);
    const execution = try requiredObject(trial_root, "execution");
    const arm = try armFor(trial_root, lane.arm_id);
    const source_receipt = try requiredObject(try requiredObject(trial_root, "sealing"), "source_selection_receipt");
    var source_case: ?std.json.ObjectMap = null;
    for ((try requiredArray(source_receipt, "cases")).items) |case_value| {
        const candidate = try object(case_value);
        if (!std.mem.eql(u8, try requiredString(candidate, "unit_id"), lane.unit_id) or
            !std.mem.eql(u8, try requiredString(candidate, "scenario_id"), lane.scenario_id)) continue;
        if (source_case != null) return error.DuplicateSourceCase;
        source_case = candidate;
    }
    const signed_case = source_case orelse return error.SourceCaseMissing;
    const payload = try jsonAlloc(allocator, .{
        .trial_id = trial.id,
        .unit_id = lane.unit_id,
        .pair_id = lane.pair_id,
        .opaque_arm_id = lane.arm_id,
        .lane_manifest_fingerprint = manifest_fingerprint,
        .start_lease_digest = lease_digest,
        .runner_id = "cas-trial",
        .runner_contract_fingerprint = try requiredString(execution, "runner_contract_fingerprint"),
        .target_snapshot_fingerprint = try requiredString(arm, "materialization_fingerprint"),
        .presented_input_fingerprint = input_fingerprint,
        .source_episode_fingerprint = try requiredString(signed_case, "source_episode_fingerprint"),
        .source_profile_fingerprint = try requiredString(signed_case, "source_profile_fingerprint"),
        .environment_fingerprint = try requiredString(execution, "environment_fingerprint"),
        .replay_policy_fingerprint = try requiredString(execution, "replay_policy_fingerprint"),
        .model_configuration_fingerprint = try requiredString(execution, "model_policy_fingerprint"),
    });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, lane.scenario_id, lane.id, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyLaneStarted(allocator, state, parsed.value, sequence, start_digest);
}

fn finishSealedLane(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    lane_id: []const u8,
    receipt_text: []const u8,
    sequence: u64,
) !void {
    const trial = state.findTrial("trial-sealed-positive") orelse return error.TrialMissing;
    const lane = trial.findLane(lane_id) orelse return error.LaneMissing;
    var receipt = try parseJson(allocator, receipt_text);
    defer receipt.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, receipt.value);
    defer allocator.free(fingerprint);
    const payload = try jsonAlloc(allocator, .{ .trial_id = trial.id, .run_receipt_fingerprint = fingerprint, .run_receipt = receipt.value });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, lane.scenario_id, lane.id, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyLaneFinished(allocator, state, parsed.value, sequence);
}

fn gradeSealedLane(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    lane_id: []const u8,
    receipt_text: []const u8,
) !void {
    const trial = state.findTrial("trial-sealed-positive") orelse return error.TrialMissing;
    const lane = trial.findLane(lane_id) orelse return error.LaneMissing;
    _ = lane.run_receipt_fingerprint orelse return error.ReceiptMissing;
    var envelope_parsed = try parseJson(allocator, receipt_text);
    defer envelope_parsed.deinit();
    const envelope = try object(envelope_parsed.value);
    if (!std.mem.eql(u8, try requiredString(envelope, "schema"), "hylo-grade-presentation-envelope/v1")) {
        return error.GradeEnvelopeInvalid;
    }
    const receipt_value = try required(envelope, "grade_receipt");
    const grade_id = try std.fmt.allocPrint(allocator, "grade-{s}", .{lane_id});
    defer allocator.free(grade_id);
    const payload = try jsonAlloc(allocator, .{
        .trial_id = trial.id,
        .pair_id = lane.pair_id,
        .opaque_arm_id = lane.arm_id,
        .grade_receipt_ref = try requiredString(envelope, "grade_receipt_ref"),
        .grade_receipt_fingerprint = try requiredString(envelope, "grade_receipt_fingerprint"),
        .grade_receipt = receipt_value,
        .grade_presentation_receipt_ref = try requiredString(envelope, "grade_presentation_receipt_ref"),
        .grade_presentation_receipt_fingerprint = try requiredString(envelope, "grade_presentation_receipt_fingerprint"),
        .grade_presentation_receipt = try required(envelope, "grade_presentation_receipt"),
    });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, lane.scenario_id, lane.id, grade_id, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    _ = try hctp.applyAbsoluteGrade(allocator, state, parsed.value, 1.0, true, 0);
}

fn gradeSealedPair(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    pair_id: []const u8,
    receipt_text: []const u8,
) !void {
    var envelope_parsed = try parseJson(allocator, receipt_text);
    defer envelope_parsed.deinit();
    const envelope = try object(envelope_parsed.value);
    if (!std.mem.eql(u8, try requiredString(envelope, "schema"), "hylo-pair-grade-presentation-envelope/v1")) {
        return error.GradeEnvelopeInvalid;
    }
    const payload = try jsonAlloc(allocator, .{
        .trial_id = "trial-sealed-positive",
        .pair_id = pair_id,
        .pair_grade_receipt_fingerprint = try requiredString(envelope, "pair_grade_receipt_fingerprint"),
        .pair_grade_receipt = try required(envelope, "pair_grade_receipt"),
        .grade_presentation_receipt_ref = try requiredString(envelope, "grade_presentation_receipt_ref"),
        .grade_presentation_receipt_fingerprint = try requiredString(envelope, "grade_presentation_receipt_fingerprint"),
        .grade_presentation_receipt = try required(envelope, "grade_presentation_receipt"),
    });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyPairGrade(allocator, state, parsed.value);
}

fn revealSealedTrial(
    allocator: std.mem.Allocator,
    state: *hctp.CampaignTrials,
    materialization_receipts: []const []const u8,
) !void {
    const trial = state.findTrial("trial-sealed-positive") orelse return error.TrialMissing;
    if (materialization_receipts.len != trial.lanes.items.len) return error.SealedMaterializationMissing;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-trial-reveal/v1\",\"trial_id\":\"trial-sealed-positive\",\"mapping\":{\"arm-0\":\"baseline\",\"arm-1\":\"candidate\"},\"nonce\":\"sealed-positive-00112233445566778899aabbccddeeff\",\"baseline_target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"candidate_target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"candidate_change_id\":\"change-sealed-positive\",\"revealed_at_scope\":\"campaign_holdout\",\"materialization_receipts\":[");
    for (materialization_receipts, 0..) |receipt, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll(receipt);
    }
    try out.writer.writeAll("]}");
    const reveal_text = try out.toOwnedSlice();
    defer allocator.free(reveal_text);
    var reveal_parsed = try parseJson(allocator, reveal_text);
    defer reveal_parsed.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, reveal_parsed.value);
    defer allocator.free(fingerprint);
    const payload = try jsonAlloc(allocator, .{ .reveal_fingerprint = fingerprint, .reveal = reveal_parsed.value });
    defer allocator.free(payload);
    const body = try bodyAlloc(allocator, null, null, null, payload);
    defer allocator.free(body);
    var parsed = try parseJson(allocator, body);
    defer parsed.deinit();
    try hctp.applyReveal(allocator, state, parsed.value, 1000);
}

fn improvementPublicationPolicySupported(result_root: std.json.ObjectMap) !bool {
    const claims = try requiredObject(result_root, "claims");
    inline for (.{ "absolute_qualification", "noninferiority", "holdout_improvement" }) |claim| {
        if (!std.mem.eql(u8, try requiredString(claims, claim), "supported")) return false;
    }
    return (try requiredArray(result_root, "critical_regressions")).items.len == 0;
}

const RoleDriverSession = struct {
    allocator: std.mem.Allocator,
    executable: []u8,
    repo: []u8,
    custody_key: [32]u8,
    child: std.process.Child,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    line_buffer: std.ArrayList(u8) = .empty,
    closed: bool = false,

    const Spawned = struct {
        child: std.process.Child,
        stdin_file: std.Io.File,
        stdout_file: std.Io.File,
    };

    fn setCloseOnExec(fd: std.posix.fd_t) !void {
        const current = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
        if (std.posix.errno(current) != .SUCCESS) return error.FdFlagsUnavailable;
        if (std.posix.errno(std.posix.system.fcntl(
            fd,
            std.posix.F.SETFD,
            @as(usize, @intCast(current)) | std.posix.FD_CLOEXEC,
        )) != .SUCCESS) return error.FdFlagsUnavailable;
    }

    fn spawn(
        allocator: std.mem.Allocator,
        executable: []const u8,
        repo: []const u8,
        custody_key: *const [32]u8,
    ) !Spawned {
        var custody_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&custody_fds) != 0) return error.PipeCreationFailed;
        var read_open = true;
        var write_open = true;
        defer {
            if (read_open) _ = std.c.close(custody_fds[0]);
        }
        defer {
            if (write_open) _ = std.c.close(custody_fds[1]);
        }
        try setCloseOnExec(custody_fds[1]);
        const custody_fd_arg = try std.fmt.allocPrint(allocator, "{d}", .{custody_fds[0]});
        defer allocator.free(custody_fd_arg);
        const argv = [_][]const u8{
            executable,
            "serve",
            "--repo",
            repo,
            "--custody-key-fd",
            custody_fd_arg,
        };
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        var child_owned = true;
        errdefer if (child_owned) child.kill(std.testing.io);
        _ = std.c.close(custody_fds[0]);
        read_open = false;
        const custody_write = std.Io.File{ .handle = custody_fds[1], .flags = .{ .nonblocking = false } };
        try custody_write.writeStreamingAll(std.testing.io, custody_key);
        _ = std.c.close(custody_fds[1]);
        write_open = false;
        const stdin_file = child.stdin orelse return error.RoleDriverStdinMissing;
        const stdout_file = child.stdout orelse return error.RoleDriverStdoutMissing;
        child.stdin = null;
        child.stdout = null;
        child_owned = false;
        return .{ .child = child, .stdin_file = stdin_file, .stdout_file = stdout_file };
    }

    fn init(
        allocator: std.mem.Allocator,
        executable: []const u8,
        repo: []const u8,
    ) !RoleDriverSession {
        const executable_copy = try allocator.dupe(u8, executable);
        errdefer allocator.free(executable_copy);
        const repo_copy = try allocator.dupe(u8, repo);
        errdefer allocator.free(repo_copy);
        var custody_key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &custody_key);
        try std.Io.randomSecure(std.testing.io, &custody_key);
        const started = try spawn(allocator, executable_copy, repo_copy, &custody_key);
        return .{
            .allocator = allocator,
            .executable = executable_copy,
            .repo = repo_copy,
            .custody_key = custody_key,
            .child = started.child,
            .stdin_file = started.stdin_file,
            .stdout_file = started.stdout_file,
        };
    }

    fn reapAfterExit(self: *RoleDriverSession, expected_exit_code: u8) !void {
        self.stdin_file.close(std.testing.io);
        self.stdout_file.close(std.testing.io);
        const term = try self.child.wait(std.testing.io);
        const exit_code: u8 = switch (term) {
            .exited => |code| code,
            else => 255,
        };
        self.closed = true;
        self.line_buffer.clearRetainingCapacity();
        if (exit_code != expected_exit_code) return error.RoleDriverUnexpectedExit;
    }

    fn startWithKey(self: *RoleDriverSession, custody_key: *const [32]u8) !void {
        if (!self.closed) return error.RoleDriverStillRunning;
        const started = try spawn(self.allocator, self.executable, self.repo, custody_key);
        self.child = started.child;
        self.stdin_file = started.stdin_file;
        self.stdout_file = started.stdout_file;
        self.closed = false;
    }

    fn restartAfterExit(self: *RoleDriverSession, expected_exit_code: u8) !void {
        try self.reapAfterExit(expected_exit_code);
        try self.startWithKey(&self.custody_key);
    }

    fn expectRejectedStart(self: *RoleDriverSession, custody_key: *const [32]u8) !void {
        if (!self.closed) return error.RoleDriverStillRunning;
        var started = try spawn(self.allocator, self.executable, self.repo, custody_key);
        started.stdin_file.close(std.testing.io);
        started.stdout_file.close(std.testing.io);
        const term = try started.child.wait(std.testing.io);
        switch (term) {
            .exited => |code| if (code == 0) return error.RoleDriverUnexpectedSuccess,
            else => {},
        }
    }

    fn readLineAlloc(self: *RoleDriverSession) ![]u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.line_buffer.items, '\n')) |index| {
                const line = try self.allocator.dupe(u8, self.line_buffer.items[0..index]);
                const keep_from = index + 1;
                const keep_len = self.line_buffer.items.len - keep_from;
                if (keep_len != 0) {
                    std.mem.copyForwards(
                        u8,
                        self.line_buffer.items[0..keep_len],
                        self.line_buffer.items[keep_from..],
                    );
                }
                self.line_buffer.items.len = keep_len;
                return line;
            }
            var byte: [1]u8 = undefined;
            var reader = self.stdout_file.reader(std.testing.io, &.{});
            const count = try reader.interface.readSliceShort(&byte);
            if (count == 0) return error.RoleDriverClosed;
            if (self.line_buffer.items.len == MaxBytes) return error.RoleDriverResponseTooLarge;
            try self.line_buffer.append(self.allocator, byte[0]);
        }
    }

    fn requestAlloc(self: *RoleDriverSession, request: []const u8) ![]u8 {
        if (self.closed) return error.RoleDriverClosed;
        try self.stdin_file.writeStreamingAll(std.testing.io, request);
        try self.stdin_file.writeStreamingAll(std.testing.io, "\n");
        return self.readLineAlloc();
    }

    fn shutdown(self: *RoleDriverSession) !void {
        const response = try self.requestAlloc(
            "{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"shutdown\"}",
        );
        defer self.allocator.free(response);
        var parsed = try parseJson(self.allocator, response);
        defer parsed.deinit();
        const root = try object(parsed.value);
        if (!std.mem.eql(u8, try requiredString(root, "schema"), "hctp-role-driver-shutdown/v1") or
            !try requiredBool(root, "accepted") or
            !try requiredBool(root, "owned_secret_buffers_zeroed") or
            try requiredBool(root, "semantic_evidence_retained"))
        {
            return error.RoleDriverShutdownInvalid;
        }
        self.stdin_file.close(std.testing.io);
        self.stdout_file.close(std.testing.io);
        const term = try self.child.wait(std.testing.io);
        const exit_code: u8 = switch (term) {
            .exited => |code| code,
            else => 255,
        };
        if (exit_code != 0) return error.RoleDriverFailed;
        self.closed = true;
    }

    fn deinit(self: *RoleDriverSession) void {
        self.line_buffer.deinit(self.allocator);
        if (!self.closed) {
            self.stdin_file.close(std.testing.io);
            self.stdout_file.close(std.testing.io);
            self.child.kill(std.testing.io);
            self.closed = true;
        }
        std.crypto.secureZero(u8, &self.custody_key);
        self.allocator.free(self.executable);
        self.allocator.free(self.repo);
    }
};

fn assertSealedAckNoSemantics(
    response: std.json.ObjectMap,
    expected_schema: []const u8,
    expected_fields: []const []const u8,
) !void {
    if (!std.mem.eql(u8, try requiredString(response, "schema"), expected_schema) or
        !try requiredBool(response, "accepted") or
        try requiredBool(response, "semantic_evidence_returned") or
        response.count() != expected_fields.len)
    {
        return error.SealedEvidenceLeak;
    }
    var iterator = response.iterator();
    while (iterator.next()) |entry| {
        var allowed = false;
        for (expected_fields) |field| {
            if (std.mem.eql(u8, entry.key_ptr.*, field)) allowed = true;
        }
        if (!allowed) return error.SealedEvidenceLeak;
    }
}

fn assertNoGradeSemantics(bytes: []const u8) !void {
    inline for (.{
        "\"status\"",
        "\"score\"",
        "\"pass\"",
        "\"fail\"",
        "\"preferred\"",
        "\"dimensions\"",
        "\"rationale_ref\"",
        "\"evidence_refs\"",
        "grade_receipt",
        "pair_grade_receipt",
    }) |forbidden| {
        if (std.mem.indexOf(u8, bytes, forbidden) != null) return error.SealedEvidenceLeak;
    }
}

fn runRoleLaneAlloc(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
    trial_id: []const u8,
    lane_id: []const u8,
) ![]u8 {
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"materialize-run\",\"trial_id\":{f},\"lane_id\":{f}}}",
        .{ std.json.fmt(trial_id, .{}), std.json.fmt(lane_id, .{}) },
    );
    defer allocator.free(request);
    const output = try role_driver.requestAlloc(request);
    var parsed = try parseJson(allocator, output);
    defer parsed.deinit();
    const response = try object(parsed.value);
    try assertSealedAckNoSemantics(response, "hylo-sealed-lane-ack/v1", &.{
        "schema",
        "trial_id",
        "lane_id",
        "lane_claim_fingerprint",
        "terminal_fingerprint",
        "accepted",
        "semantic_evidence_returned",
    });
    try assertNoGradeSemantics(output);
    return output;
}

fn runRoleGradeAlloc(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
    kind: []const u8,
    left_lane_id: []const u8,
    right_lane_id: ?[]const u8,
) ![]u8 {
    const request = if (std.mem.eql(u8, kind, "absolute"))
        try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"grade-absolute\",\"lane_id\":{f}}}",
            .{std.json.fmt(left_lane_id, .{})},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"grade-pair\",\"left_lane_id\":{f},\"right_lane_id\":{f}}}",
            .{ std.json.fmt(left_lane_id, .{}), std.json.fmt(right_lane_id orelse return error.PairLaneMissing, .{}) },
        );
    defer allocator.free(request);
    const output = try role_driver.requestAlloc(request);
    var parsed = try parseJson(allocator, output);
    defer parsed.deinit();
    const envelope = try object(parsed.value);
    try assertSealedAckNoSemantics(envelope, "hylo-sealed-grade-ack/v1", &.{
        "schema",
        "trial_id",
        "kind",
        "scope_id",
        "grade_claim_fingerprint",
        "terminal_fingerprint",
        "accepted",
        "semantic_evidence_returned",
    });
    try assertNoGradeSemantics(output);
    return output;
}

fn overwriteCustodyByte(path: []const u8, offset: u64, byte: u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{
        .mode = .read_write,
        .follow_symlinks = false,
    });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &.{byte}, offset);
    try file.sync(std.testing.io);
}

fn runRolePairGradeCrashRecoveryAlloc(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
    root: []const u8,
    left_lane_id: []const u8,
    right_lane_id: []const u8,
) ![]u8 {
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"grade-pair-exit-after-commit\",\"left_lane_id\":{f},\"right_lane_id\":{f}}}",
        .{ std.json.fmt(left_lane_id, .{}), std.json.fmt(right_lane_id, .{}) },
    );
    defer allocator.free(request);
    try std.testing.expectError(error.RoleDriverClosed, role_driver.requestAlloc(request));
    const custody_root = try std.fs.path.join(allocator, &.{ root, ".hctp-role-driver" });
    defer allocator.free(custody_root);
    const custody_root_stat = try std.Io.Dir.cwd().statFile(std.testing.io, custody_root, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.directory, custody_root_stat.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), custody_root_stat.permissions.toMode() & 0o777);
    const custody_path = try std.fs.path.join(allocator, &.{ root, ".hctp-role-driver", "private-state.sealed.json" });
    defer allocator.free(custody_path);
    const custody_stat = try std.Io.Dir.cwd().statFile(std.testing.io, custody_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, custody_stat.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), custody_stat.permissions.toMode() & 0o777);
    const custody_envelope = try durable_store.readRegularFileNoSymlink(allocator, custody_path, MaxBytes);
    defer allocator.free(custody_envelope);
    inline for (.{
        "\"hctp-role-driver-private-state/v3\"",
        "\"opening_json\"",
        "\"presentation_receipt_json\"",
        "\"grade_opening\"",
    }) |private_marker| {
        try std.testing.expect(std.mem.indexOf(u8, custody_envelope, private_marker) == null);
    }
    const store_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "hylo", "events.jsonl" });
    defer allocator.free(store_path);
    var persistence = durable_store.PersistentEventStore.init(store_path);
    const store = persistence.eventStore();
    var before = try store.snapshot(allocator, MaxBytes);
    defer before.deinit(allocator);
    try role_driver.reapAfterExit(86);
    var wrong_key = role_driver.custody_key;
    defer std.crypto.secureZero(u8, &wrong_key);
    wrong_key[0] ^= 0xff;
    try role_driver.expectRejectedStart(&wrong_key);
    const ciphertext_marker = "\"ciphertext_base64\":\"";
    const marker_offset = std.mem.indexOf(u8, custody_envelope, ciphertext_marker) orelse
        return error.CustodyCiphertextMissing;
    const ciphertext_offset = marker_offset + ciphertext_marker.len;
    if (ciphertext_offset >= custody_envelope.len or custody_envelope[ciphertext_offset] == '"') {
        return error.CustodyCiphertextMissing;
    }
    const original_byte = custody_envelope[ciphertext_offset];
    const tampered_byte: u8 = if (original_byte == 'A') 'B' else 'A';
    try overwriteCustodyByte(custody_path, @intCast(ciphertext_offset), tampered_byte);
    try role_driver.expectRejectedStart(&role_driver.custody_key);
    try overwriteCustodyByte(custody_path, @intCast(ciphertext_offset), original_byte);
    try role_driver.startWithKey(&role_driver.custody_key);
    const ack = try runRoleGradeAlloc(allocator, role_driver, "pair", left_lane_id, right_lane_id);
    errdefer allocator.free(ack);
    var after = try store.snapshot(allocator, MaxBytes);
    defer after.deinit(allocator);
    try std.testing.expectEqual(before.records.len, after.records.len);
    try std.testing.expectEqualStrings(before.content_digest, after.content_digest);
    const reversed = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"grade-pair\",\"left_lane_id\":{f},\"right_lane_id\":{f}}}",
        .{ std.json.fmt(right_lane_id, .{}), std.json.fmt(left_lane_id, .{}) },
    );
    defer allocator.free(reversed);
    try std.testing.expectError(error.RoleDriverClosed, role_driver.requestAlloc(reversed));
    try role_driver.restartAfterExit(1);
    var after_mismatch = try store.snapshot(allocator, MaxBytes);
    defer after_mismatch.deinit(allocator);
    try std.testing.expectEqual(after.records.len, after_mismatch.records.len);
    try std.testing.expectEqualStrings(after.content_digest, after_mismatch.content_digest);
    return ack;
}

fn sealedPayloadIntentAlloc(allocator: std.mem.Allocator, kind: []const u8, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-event-intent/v1\",\"campaign_id\":\"cmp-sealed-positive\",\"kind\":{f},\"scenario_id\":null,\"attempt_id\":null,\"grade_id\":null,\"payload\":{s}}}",
        .{ std.json.fmt(kind, .{}), payload },
    );
}

fn appendSealedIntent(
    allocator: std.mem.Allocator,
    root: []const u8,
    ledger_path: []const u8,
    label: []const u8,
    intent: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.intent.json", .{ root, label });
    defer allocator.free(path);
    try durable_store.writeTextAtomic(allocator, path, intent);
    const command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo append --repo '{s}' --json '{s}'",
        .{ ledger_path, root, path },
    );
    defer allocator.free(command);
    return runIsolatedCommandAlloc(allocator, root, label, command);
}

const TargetSnapshotReceipt = struct {
    fingerprint: []u8,
    snapshot: []u8,
    target_common_projection: ?[]u8,
    target_common_projection_fingerprint: ?[]u8,

    fn deinit(self: TargetSnapshotReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
        allocator.free(self.snapshot);
        if (self.target_common_projection) |value| allocator.free(value);
        if (self.target_common_projection_fingerprint) |value| allocator.free(value);
    }
};

fn snapshotTargetReceiptAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    ledger_path: []const u8,
    revision: []const u8,
    label: []const u8,
) !TargetSnapshotReceipt {
    const request_path = try std.fmt.allocPrint(allocator, "{s}/{s}.snapshot-request.json", .{ root, label });
    defer allocator.free(request_path);
    try durable_store.writeTextAtomic(
        allocator,
        request_path,
        "{\"schema\":\"hylo-target-snapshot-request/v1\",\"roots\":[\"target.txt\"]}",
    );
    const command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo snapshot-target --repo '{s}' --input '{s}' --revision '{s}'",
        .{ ledger_path, root, request_path, revision },
    );
    defer allocator.free(command);
    const output = try runIsolatedCommandAlloc(allocator, root, label, command);
    var parsed = try parseJson(allocator, output);
    defer parsed.deinit();
    const receipt = try object(parsed.value);
    const common_projection_value = receipt.get("target_common_projection");
    const common_projection = if (common_projection_value != null and common_projection_value.? != .null)
        try hctp.canonicalJsonAlloc(allocator, common_projection_value.?)
    else
        null;
    errdefer if (common_projection) |value| allocator.free(value);
    const common_fingerprint_value = receipt.get("target_common_projection_fingerprint");
    const common_fingerprint = if (common_fingerprint_value != null and common_fingerprint_value.? != .null)
        try allocator.dupe(u8, try requiredString(receipt, "target_common_projection_fingerprint"))
    else
        null;
    errdefer if (common_fingerprint) |value| allocator.free(value);
    return .{
        .fingerprint = try allocator.dupe(u8, try requiredString(receipt, "fingerprint")),
        .snapshot = try hctp.canonicalJsonAlloc(allocator, try required(receipt, "snapshot")),
        .target_common_projection = common_projection,
        .target_common_projection_fingerprint = common_fingerprint,
    };
}

fn sealedTargetAdmissionPayloadAlloc(
    allocator: std.mem.Allocator,
    target_fingerprint: []const u8,
    bundle: retrace_core.target_bundle.BuiltBundle,
    snapshot_revision: []const u8,
    snapshot: TargetSnapshotReceipt,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-target-bundle-admission/v1\",\"target_fingerprint\":{f},\"bundle_fingerprint\":{f},\"target_content_fingerprint\":{f},\"bundle\":{s},\"target_snapshot_revision\":{f},\"target_snapshot_fingerprint\":{f},\"target_snapshot\":{s},\"materialization\":[{{\"bundle_path\":\"SKILL.md\",\"snapshot_path\":\"target.txt\"}}]}}",
        .{
            std.json.fmt(target_fingerprint, .{}),
            std.json.fmt(bundle.bundle_fingerprint, .{}),
            std.json.fmt(bundle.target_content_fingerprint, .{}),
            bundle.json,
            std.json.fmt(snapshot_revision, .{}),
            std.json.fmt(snapshot.fingerprint, .{}),
            snapshot.snapshot,
        },
    );
}

fn runRoleRevealAlloc(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
    trial_id: []const u8,
    template: []const u8,
) ![]u8 {
    var template_parsed = try parseJson(allocator, template);
    defer template_parsed.deinit();
    const canonical_template = try hctp.canonicalJsonAlloc(allocator, template_parsed.value);
    defer allocator.free(canonical_template);
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"reveal-trial\",\"trial_id\":{f},\"template\":{s}}}",
        .{ std.json.fmt(trial_id, .{}), canonical_template },
    );
    defer allocator.free(request);
    const output = try role_driver.requestAlloc(request);
    var parsed = try parseJson(allocator, output);
    defer parsed.deinit();
    const response = try object(parsed.value);
    try assertSealedAckNoSemantics(response, "hylo-sealed-reveal-ack/v1", &.{
        "schema",
        "trial_id",
        "reveal_claim_fingerprint",
        "terminal_fingerprint",
        "accepted",
        "semantic_evidence_returned",
    });
    try assertNoGradeSemantics(output);
    return output;
}

fn runRoleRevealCrashRecoveryAlloc(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
    root: []const u8,
    trial_id: []const u8,
    template: []const u8,
) ![]u8 {
    var template_parsed = try parseJson(allocator, template);
    defer template_parsed.deinit();
    const canonical_template = try hctp.canonicalJsonAlloc(allocator, template_parsed.value);
    defer allocator.free(canonical_template);
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"reveal-trial-exit-after-commit\",\"trial_id\":{f},\"template\":{s}}}",
        .{ std.json.fmt(trial_id, .{}), canonical_template },
    );
    defer allocator.free(request);
    try std.testing.expectError(error.RoleDriverClosed, role_driver.requestAlloc(request));
    const store_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "hylo", "events.jsonl" });
    defer allocator.free(store_path);
    var persistence = durable_store.PersistentEventStore.init(store_path);
    const store = persistence.eventStore();
    var before = try store.snapshot(allocator, MaxBytes);
    defer before.deinit(allocator);
    try role_driver.restartAfterExit(87);
    const ack = try runRoleRevealAlloc(allocator, role_driver, trial_id, template);
    defer allocator.free(ack);
    var after = try store.snapshot(allocator, MaxBytes);
    defer after.deinit(allocator);
    try std.testing.expectEqual(before.records.len, after.records.len);
    try std.testing.expectEqualStrings(before.content_digest, after.content_digest);
    const altered_template = try std.fmt.allocPrint(
        allocator,
        "{s},\"retry_probe\":true}}",
        .{canonical_template[0 .. canonical_template.len - 1]},
    );
    defer allocator.free(altered_template);
    const altered_request = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"reveal-trial\",\"trial_id\":{f},\"template\":{s}}}",
        .{ std.json.fmt(trial_id, .{}), altered_template },
    );
    defer allocator.free(altered_request);
    try std.testing.expectError(error.RoleDriverClosed, role_driver.requestAlloc(altered_request));
    try role_driver.restartAfterExit(1);
    const exact_ack = try runRoleRevealAlloc(allocator, role_driver, trial_id, template);
    errdefer allocator.free(exact_ack);
    var after_mismatch = try store.snapshot(allocator, MaxBytes);
    defer after_mismatch.deinit(allocator);
    try std.testing.expectEqual(after.records.len, after_mismatch.records.len);
    try std.testing.expectEqualStrings(after.content_digest, after_mismatch.content_digest);
    return exact_ack;
}

fn runRoleRevealAtomicityAlloc(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
    trial_id: []const u8,
    template: []const u8,
) ![]u8 {
    var template_parsed = try parseJson(allocator, template);
    defer template_parsed.deinit();
    const canonical_template = try hctp.canonicalJsonAlloc(allocator, template_parsed.value);
    defer allocator.free(canonical_template);
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"assert-reveal-atomicity\",\"trial_id\":{f},\"template\":{s}}}",
        .{ std.json.fmt(trial_id, .{}), canonical_template },
    );
    defer allocator.free(request);
    const output = try role_driver.requestAlloc(request);
    var parsed = try parseJson(allocator, output);
    defer parsed.deinit();
    const response = try object(parsed.value);
    try assertSealedAckNoSemantics(response, "hylo-sealed-reveal-atomicity-ack/v1", &.{
        "schema",
        "trial_id",
        "rejection_code",
        "rejected",
        "store_revision_unchanged",
        "store_content_digest_unchanged",
        "store_record_count_unchanged",
        "accepted",
        "semantic_evidence_returned",
    });
    try std.testing.expectEqualStrings(
        "GradeOpeningCommitmentMismatch",
        try requiredString(response, "rejection_code"),
    );
    inline for (.{
        "rejected",
        "store_revision_unchanged",
        "store_content_digest_unchanged",
        "store_record_count_unchanged",
    }) |field| try std.testing.expect(try requiredBool(response, field));
    try assertNoGradeSemantics(output);
    return output;
}

fn closeSealedTrialAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    ledger_path: []const u8,
    trial_id: []const u8,
) ![]u8 {
    const command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo close-trial --repo '{s}' --trial-id '{s}' --status completed --reason 'sealed fixed cohort completed'",
        .{ ledger_path, root, trial_id },
    );
    defer allocator.free(command);
    const label = try std.fmt.allocPrint(allocator, "close-{s}", .{trial_id});
    return runIsolatedCommandAlloc(allocator, root, label, command);
}

fn sealedTrialResultAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    ledger_path: []const u8,
    trial_id: []const u8,
) ![]u8 {
    const command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo trial-result --repo '{s}' --trial-id '{s}' --format json",
        .{ ledger_path, root, trial_id },
    );
    defer allocator.free(command);
    const label = try std.fmt.allocPrint(allocator, "result-{s}", .{trial_id});
    return runIsolatedCommandAlloc(allocator, root, label, command);
}

test "HCTP integration binders join every runner authority to frozen trust" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const binaries = try integrationPaths(allocator);
    const source_owned = try bindProofSourceOwnerAlloc(
        allocator,
        fixtures.valid_null_trial,
        binaries.executor,
        binaries.cas,
        binaries.ledger,
    );
    const trial = try bindRunnerContractAlloc(
        allocator,
        source_owned,
        binaries.executor,
        binaries.cas,
        binaries.ledger,
    );
    var parsed = try parseJson(allocator, trial);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const execution = try requiredObject(root, "execution");
    const contract = try requiredObject(execution, "runner_contract");
    const assurance = try requiredObject(root, "assurance");
    const trial_trust_value = try required(assurance, "trust_policy");
    const trust = try object(trial_trust_value);
    try expectTrustBindsRunnerAuthority(trust, try requiredObject(execution, "runner_authority"));
    try expectTrustBindsRunnerAuthority(trust, try requiredObject(contract, "executor_authority"));
    try expectTrustBindsRunnerAuthority(trust, try requiredObject(contract, "ledger_authority"));

    const campaign = try campaignAlloc(
        allocator,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        binaries.executor,
        binaries.cas,
        binaries.ledger,
    );
    var campaign_parsed = try parseJson(allocator, campaign);
    defer campaign_parsed.deinit();
    const trial_policy = try requiredObject(try object(campaign_parsed.value), "trial_policy");
    const campaign_trust_value = try required(trial_policy, "proof_trust_policy");
    const trial_trust_fingerprint = try hctp.digestValueAlloc(allocator, trial_trust_value);
    const campaign_trust_fingerprint = try hctp.digestValueAlloc(allocator, campaign_trust_value);
    try std.testing.expectEqualStrings(trial_trust_fingerprint, campaign_trust_fingerprint);
    try std.testing.expectEqualStrings(
        trial_trust_fingerprint,
        try requiredString(assurance, "trust_policy_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        trial_trust_fingerprint,
        try requiredString(trial_policy, "proof_trust_policy_fingerprint"),
    );
}

const PublicLaneStart = struct {
    start_digest: []u8,
    registration_digest: []u8,
    lease_digest: []u8,

    fn deinit(self: PublicLaneStart, allocator: std.mem.Allocator) void {
        allocator.free(self.start_digest);
        allocator.free(self.registration_digest);
        allocator.free(self.lease_digest);
    }
};

fn laneEventCount(
    allocator: std.mem.Allocator,
    snapshot: durable_store.EventSnapshot,
    kind: []const u8,
    lane_id: []const u8,
) !usize {
    var count: usize = 0;
    for (snapshot.records) |record| {
        var parsed = try parseJson(allocator, record.payload);
        defer parsed.deinit();
        const event = try object(parsed.value);
        if (!std.mem.eql(u8, try requiredString(event, "kind"), kind)) continue;
        const body = try requiredObject(event, "body");
        if (std.mem.eql(u8, try requiredString(body, "attempt_id"), lane_id)) count += 1;
    }
    return count;
}

fn publicLaneStartAlloc(
    allocator: std.mem.Allocator,
    snapshot: durable_store.EventSnapshot,
    lane_id: []const u8,
    registration_digest: []const u8,
) !PublicLaneStart {
    var matched: ?PublicLaneStart = null;
    errdefer if (matched) |value| value.deinit(allocator);
    for (snapshot.records) |record| {
        var parsed = try parseJson(allocator, record.payload);
        defer parsed.deinit();
        const event = try object(parsed.value);
        if (!std.mem.eql(u8, try requiredString(event, "kind"), "lane_started")) continue;
        const body = try requiredObject(event, "body");
        if (!std.mem.eql(u8, try requiredString(body, "attempt_id"), lane_id)) continue;
        if (matched != null) return error.DuplicateLaneStart;
        const payload = try requiredObject(body, "payload");
        matched = .{
            .start_digest = try allocator.dupe(u8, try requiredString(event, "event_digest")),
            .registration_digest = try allocator.dupe(u8, registration_digest),
            .lease_digest = try allocator.dupe(u8, try requiredString(payload, "start_lease_digest")),
        };
    }
    return matched orelse error.LaneStartMissing;
}

fn roleLaneCrashRequestAlloc(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
    operation: []const u8,
    trial_id: []const u8,
    lane_id: []const u8,
    expected_exit: u8,
) !void {
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":{f},\"trial_id\":{f},\"lane_id\":{f}}}",
        .{ std.json.fmt(operation, .{}), std.json.fmt(trial_id, .{}), std.json.fmt(lane_id, .{}) },
    );
    defer allocator.free(request);
    try std.testing.expectError(error.RoleDriverClosed, role_driver.requestAlloc(request));
    try role_driver.restartAfterExit(expected_exit);
}

fn expectLegacySealedStartRejected(
    allocator: std.mem.Allocator,
    ledger_path: []const u8,
    root: []const u8,
    trial_id: []const u8,
    lane_id: []const u8,
) !void {
    const store_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "hylo", "events.jsonl" });
    var persistence = durable_store.PersistentEventStore.init(store_path);
    const store = persistence.eventStore();
    var before = try store.snapshot(allocator, MaxBytes);
    defer before.deinit(allocator);
    const lease_sink = try std.fs.path.join(allocator, &.{ root, "legacy-sealed-start.lease" });
    const command = try std.fmt.allocPrint(
        allocator,
        "set -o pipefail; rm -f '{s}'; exec 4>&1; '{s}' --source hylo start-lane --repo '{s}' --campaign-id cmp-sealed-positive --trial-id '{s}' --lane-id '{s}' --runner-id cas-trial --lease-output-fd 3 3>&1 1>&4 | (umask 077; cat >'{s}')",
        .{ lease_sink, ledger_path, root, trial_id, lane_id, lease_sink },
    );
    try std.testing.expectError(
        error.IntegrationCommandFailed,
        runIsolatedCommandAlloc(allocator, root, "sealed-legacy-start-rejected", command),
    );
    const stderr_path = try std.fs.path.join(
        allocator,
        &.{ root, "sealed-legacy-start-rejected.stderr" },
    );
    const stderr = try durable_store.readRegularFileNoSymlink(allocator, stderr_path, MaxBytes);
    try std.testing.expect(std.mem.indexOf(
        u8,
        stderr,
        "SealedLaneStartRequiresRetainedLease",
    ) != null);
    var after = try store.snapshot(allocator, MaxBytes);
    defer after.deinit(allocator);
    try std.testing.expectEqual(before.records.len, after.records.len);
    try std.testing.expectEqualStrings(before.revision, after.revision);
    try std.testing.expectEqualStrings(before.content_digest, after.content_digest);
    try std.testing.expectEqual(@as(usize, 0), try laneEventCount(allocator, after, "lane_started", lane_id));
}

const RecoveryProbeMode = enum { terminal_adoption, claimed_fail_closed };

fn authoritativeClaimStoreAlloc(allocator: std.mem.Allocator) ![]u8 {
    var passwd: std.c.passwd = undefined;
    var storage: [64 * 1024]u8 = undefined;
    var result: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(
        std.c.getuid(),
        &passwd,
        &storage,
        storage.len,
        &result,
    ) != 0 or result == null) {
        return error.RunnerIdentityLookupFailed;
    }
    const home_pointer = passwd.dir orelse return error.RunnerHomeMissing;
    const home = std.mem.span(home_pointer);
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.RunnerHomeInvalid;
    return std.fs.path.resolve(allocator, &.{ home, ".codex", "cas", "hctp-claims-v1" });
}

fn authoritativeWorkspaceStoreAlloc(allocator: std.mem.Allocator) ![]u8 {
    var passwd: std.c.passwd = undefined;
    var storage: [64 * 1024]u8 = undefined;
    var result: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(
        std.c.getuid(),
        &passwd,
        &storage,
        storage.len,
        &result,
    ) != 0 or result == null) {
        return error.RunnerIdentityLookupFailed;
    }
    const home_pointer = passwd.dir orelse return error.RunnerHomeMissing;
    const home = std.mem.span(home_pointer);
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.RunnerHomeInvalid;
    return std.fs.path.resolve(allocator, &.{ home, ".codex", "cas", "hctp-workspaces-v1" });
}

fn expectPrivatePathMode(
    path: []const u8,
    kind: std.Io.File.Kind,
    mode: std.posix.mode_t,
) !void {
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(kind, stat.kind);
    try std.testing.expectEqual(mode, stat.permissions.toMode() & 0o777);
}

fn assertCaseBlindHistoricalLaneAndCleanup(
    allocator: std.mem.Allocator,
    binaries: IntegrationBinaries,
    root: []const u8,
    trial_id: []const u8,
    lane_id: []const u8,
    public_source_receipt: []const u8,
    public_trial: []const u8,
) !void {
    const receipt_dir = try std.fs.path.resolve(
        allocator,
        &.{ root, ".hctp-role-driver", "runner-receipts" },
    );
    defer allocator.free(receipt_dir);
    const receipt_store_fingerprint = try digestBytesAlloc(allocator, receipt_dir);
    defer allocator.free(receipt_store_fingerprint);
    const workspace_store = try authoritativeWorkspaceStoreAlloc(allocator);
    defer allocator.free(workspace_store);
    const workspace = try std.fs.path.join(
        allocator,
        &.{ workspace_store, receipt_store_fingerprint["sha256:".len..], trial_id, lane_id },
    );
    defer allocator.free(workspace);
    const replay_root = try std.fs.path.join(allocator, &.{ workspace, "historical-replay" });
    defer allocator.free(replay_root);
    const dcp_path = try std.fs.path.join(
        allocator,
        &.{ replay_root, "decision-context.dcp.json" },
    );
    defer allocator.free(dcp_path);
    const rip_path = try std.fs.path.join(allocator, &.{ replay_root, "replay-plan.rip.json" });
    defer allocator.free(rip_path);
    try expectPrivatePathMode(workspace, .directory, 0o700);
    try expectPrivatePathMode(replay_root, .directory, 0o700);
    try expectPrivatePathMode(dcp_path, .file, 0o600);
    try expectPrivatePathMode(rip_path, .file, 0o600);

    const request_path = try std.fs.path.join(allocator, &.{ workspace, "request.json" });
    defer allocator.free(request_path);
    const request_bytes = try durable_store.readRegularFileNoSymlink(
        allocator,
        request_path,
        MaxBytes,
    );
    defer allocator.free(request_bytes);
    var request_parsed = try parseJson(allocator, request_bytes);
    defer request_parsed.deinit();
    const request = try object(request_parsed.value);
    try std.testing.expectEqualStrings(
        "cas-trial-executor-request/v2",
        try requiredString(request, "schema"),
    );
    try std.testing.expectEqualStrings(
        "source_profile_fd",
        try requiredString(request, "source_profile_body_delivery"),
    );
    try std.testing.expectEqualStrings(dcp_path, try requiredString(request, "historical_dcp_ref"));
    try std.testing.expectEqualStrings(rip_path, try requiredString(request, "historical_rip_ref"));
    const dcp_fingerprint = try fileFingerprintAlloc(allocator, dcp_path);
    defer allocator.free(dcp_fingerprint);
    const rip_fingerprint = try fileFingerprintAlloc(allocator, rip_path);
    defer allocator.free(rip_fingerprint);
    try std.testing.expectEqualStrings(
        dcp_fingerprint,
        try requiredString(request, "historical_dcp_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        rip_fingerprint,
        try requiredString(request, "historical_rip_fingerprint"),
    );

    const run_receipt_path = try std.fs.path.join(
        allocator,
        &.{ receipt_dir, trial_id, lane_id, "run-receipt.json" },
    );
    defer allocator.free(run_receipt_path);
    const run_receipt_bytes = try durable_store.readRegularFileNoSymlink(
        allocator,
        run_receipt_path,
        MaxBytes,
    );
    defer allocator.free(run_receipt_bytes);
    var run_receipt_parsed = try parseJson(allocator, run_receipt_bytes);
    defer run_receipt_parsed.deinit();
    const run_receipt = try object(run_receipt_parsed.value);
    const materialization = try requiredObject(run_receipt, "materialization");
    const profile_fingerprint = try requiredString(request, "source_profile_fingerprint");
    const lineage = try requiredString(request, "required_lineage");
    try std.testing.expectEqualStrings(
        profile_fingerprint,
        try requiredString(materialization, "source_profile_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        dcp_fingerprint,
        try requiredString(materialization, "historical_dcp_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        rip_fingerprint,
        try requiredString(materialization, "historical_rip_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        "source_profile_fd",
        try requiredString(materialization, "source_profile_body_delivery"),
    );
    const native = try requiredObject(run_receipt, "native_receipt");
    try std.testing.expectEqualStrings("FIR-v1", try requiredString(native, "kind"));
    try std.testing.expectEqualStrings(
        profile_fingerprint,
        try requiredString(native, "source_profile_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        dcp_fingerprint,
        try requiredString(native, "decision_context_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        rip_fingerprint,
        try requiredString(native, "replay_plan_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        "source_profile_fd",
        try requiredString(native, "source_profile_body_delivery"),
    );
    const fir = try object(try required(native, "receipt"));
    const replay_binding = try requiredObject(fir, "replay_binding");
    try std.testing.expectEqualStrings(trial_id, try requiredString(replay_binding, "trial_id"));
    try std.testing.expectEqualStrings(lane_id, try requiredString(replay_binding, "lane_id"));
    try std.testing.expectEqualStrings(
        profile_fingerprint,
        try requiredString(replay_binding, "source_profile_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        dcp_fingerprint,
        try requiredString(replay_binding, "historical_dcp_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        rip_fingerprint,
        try requiredString(replay_binding, "historical_rip_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        lineage,
        try requiredString(replay_binding, "required_lineage"),
    );

    const materialization_receipt_path = try std.fs.path.join(
        allocator,
        &.{ root, ".hctp-role-driver", "lanes", trial_id, lane_id, "materialization-receipt.json" },
    );
    defer allocator.free(materialization_receipt_path);
    const materialization_receipt = try durable_store.readRegularFileNoSymlink(
        allocator,
        materialization_receipt_path,
        MaxBytes,
    );
    defer allocator.free(materialization_receipt);
    var materialization_parsed = try parseJson(allocator, materialization_receipt);
    defer materialization_parsed.deinit();
    try std.testing.expectEqualStrings(
        profile_fingerprint,
        try requiredString(try object(materialization_parsed.value), "source_profile_fingerprint"),
    );

    const claim_store = try authoritativeClaimStoreAlloc(allocator);
    defer allocator.free(claim_store);
    const registration_digest = try requiredString(
        try requiredObject(run_receipt, "lineage"),
        "registration_event_digest",
    );
    const claim_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/{s}.json",
        .{ claim_store, trial_id, lane_id, registration_digest["sha256:".len..] },
    );
    defer allocator.free(claim_path);
    const claim_bytes = try durable_store.readRegularFileNoSymlink(allocator, claim_path, MaxBytes);
    defer allocator.free(claim_bytes);
    var claim_parsed = try parseJson(allocator, claim_bytes);
    defer claim_parsed.deinit();
    const claim = try object(claim_parsed.value);
    try std.testing.expectEqualStrings(
        profile_fingerprint,
        try requiredString(claim, "source_profile_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        dcp_fingerprint,
        try requiredString(claim, "historical_dcp_fingerprint"),
    );
    try std.testing.expectEqualStrings(
        rip_fingerprint,
        try requiredString(claim, "historical_rip_fingerprint"),
    );
    try std.testing.expectEqualStrings(lineage, try requiredString(claim, "required_lineage"));
    try std.testing.expectEqualStrings(
        "cas-trial-executor-request/v2",
        try requiredString(claim, "executor_request_schema"),
    );

    inline for (.{
        public_source_receipt,
        public_trial,
        materialization_receipt,
    }) |public_artifact| {
        inline for (.{
            "\"decision_context\":",
            "\"source_governance\":",
            "route-private-source",
            "\"historical_dcp_ref\":",
            "\"historical_rip_ref\":",
        }) |forbidden| {
            try std.testing.expect(
                std.mem.indexOf(u8, public_artifact, forbidden) == null,
            );
        }
    }

    const cleanup_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' cleanup --trial-id '{s}' --lane-id '{s}' --receipt-dir '{s}' --json",
        .{ binaries.cas, trial_id, lane_id, receipt_dir },
    );
    defer allocator.free(cleanup_command);
    const cleanup = try runIsolatedCommandAlloc(
        allocator,
        root,
        "sealed-historical-cleanup",
        cleanup_command,
    );
    defer allocator.free(cleanup);
    var cleanup_parsed = try parseJson(allocator, cleanup);
    defer cleanup_parsed.deinit();
    const cleanup_receipt = try object(cleanup_parsed.value);
    try std.testing.expect(try requiredBool(cleanup_receipt, "workspace_removed"));
    try std.testing.expect(try requiredBool(cleanup_receipt, "claim_preserved"));
    try std.testing.expect(try requiredBool(cleanup_receipt, "receipt_preserved"));
    try std.testing.expect(try requiredBool(cleanup_receipt, "evidence_preserved"));
    inline for (.{
        "\"decision_context\":",
        "\"source_governance\":",
        "route-private-source",
        "\"historical_dcp_ref\":",
        "\"historical_rip_ref\":",
    }) |forbidden| try std.testing.expect(std.mem.indexOf(u8, cleanup, forbidden) == null);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, workspace, .{ .follow_symlinks = false }),
    );
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, claim_path, .{ .follow_symlinks = false });
    _ = try std.Io.Dir.cwd().statFile(
        std.testing.io,
        run_receipt_path,
        .{ .follow_symlinks = false },
    );
    const evidence_path = try std.fs.path.join(
        allocator,
        &.{ receipt_dir, trial_id, lane_id, "evidence" },
    );
    defer allocator.free(evidence_path);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, evidence_path, .{ .follow_symlinks = false });
    _ = try std.Io.Dir.cwd().statFile(
        std.testing.io,
        try requiredString(cleanup_receipt, "cleanup_ref"),
        .{ .follow_symlinks = false },
    );
}

fn persistVerifiedCasClaim(
    allocator: std.mem.Allocator,
    trial_id: []const u8,
    lane_id: []const u8,
    start: PublicLaneStart,
) !void {
    const claim_store = try authoritativeClaimStoreAlloc(allocator);
    const claim_root = try std.fs.path.join(allocator, &.{ claim_store, trial_id, lane_id });
    try durable_store.ensureDirectoryPathNoSymlinks(claim_root);
    const claim_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.json",
        .{ claim_root, start.registration_digest["sha256:".len..] },
    );
    const claim = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-trial-claim/v1\",\"trial_id\":{f},\"lane_id\":{f},\"claim_id\":{f},\"registration_event_digest\":{f},\"lane_started_event_digest\":{f},\"atomic\":true,\"claimed_before_execution\":true,\"claim_count\":1,\"expected_lane_lease_digest\":{f},\"lane_lease_digest\":{f}}}\n",
        .{
            std.json.fmt(trial_id, .{}),
            std.json.fmt(lane_id, .{}),
            std.json.fmt(lane_id, .{}),
            std.json.fmt(start.registration_digest, .{}),
            std.json.fmt(start.start_digest, .{}),
            std.json.fmt(start.lease_digest, .{}),
            std.json.fmt(start.lease_digest, .{}),
        },
    );
    try durable_store.writeTextCreateNewAtomic(allocator, claim_path, claim, .{});
    var file = try std.Io.Dir.openFileAbsolute(defaultIo(), claim_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(defaultIo());
    try file.setPermissions(defaultIo(), .fromMode(0o400));
}

fn runSealedLaneRecoveryProbe(
    allocator: std.mem.Allocator,
    binaries: IntegrationBinaries,
    mode: RecoveryProbeMode,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(defaultIo(), ".", allocator);
    const suffix = if (mode == .terminal_adoption) "terminal" else "claimed";
    const root_digest = try digestBytesAlloc(allocator, root);
    // Keep the random test identity opaque without allowing a digest prefix such
    // as `2026...` to resemble a date token under the grader-visible ID law.
    const identity_suffix = try std.fmt.allocPrint(
        allocator,
        "x{s}",
        .{root_digest["sha256:".len .. "sha256:".len + 12]},
    );
    defer allocator.free(identity_suffix);
    const trial_id = try std.fmt.allocPrint(
        allocator,
        "trial-sealed-recovery-{s}-{s}",
        .{ suffix, identity_suffix },
    );
    const lane_a0 = try std.fmt.allocPrint(
        allocator,
        "lane-sealed-recovery-{s}-{s}-a0",
        .{ suffix, identity_suffix },
    );
    const lane_a1 = try std.fmt.allocPrint(
        allocator,
        "lane-sealed-recovery-{s}-{s}-a1",
        .{ suffix, identity_suffix },
    );

    const git_init = try std.fmt.allocPrint(allocator, "git -C '{s}' init -q", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "recovery-git-init", git_init);
    const git_user_name = try std.fmt.allocPrint(allocator, "git -C '{s}' config user.name 'HCTP Fixture'", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "recovery-git-user-name", git_user_name);
    const git_user_email = try std.fmt.allocPrint(allocator, "git -C '{s}' config user.email 'hctp-fixture@example.invalid'", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "recovery-git-user-email", git_user_email);
    const exclude_path = try std.fs.path.join(allocator, &.{ root, ".git", "info", "exclude" });
    try durable_store.writeTextAtomic(allocator, exclude_path, ".ledger/\n.hctp-role-driver/\n");
    var role_driver = try RoleDriverSession.init(allocator, binaries.sealed_role_driver, root);
    defer role_driver.deinit();

    const target_path = try std.fs.path.join(allocator, &.{ root, "target.txt" });
    try durable_store.writeTextAtomic(allocator, target_path, "baseline\n");
    const add_baseline = try std.fmt.allocPrint(allocator, "git -C '{s}' add -- target.txt", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "recovery-add-baseline", add_baseline);
    const commit_baseline = try std.fmt.allocPrint(allocator, "git -C '{s}' commit -qm 'sealed baseline'", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "recovery-commit-baseline", commit_baseline);
    const revision_command = try std.fmt.allocPrint(allocator, "git -C '{s}' rev-parse HEAD", .{root});
    const revision_raw = try runIsolatedCommandAlloc(allocator, root, "recovery-baseline-revision", revision_command);
    const baseline_revision = std.mem.trim(u8, revision_raw, " \t\r\n");
    const baseline_snapshot = try snapshotTargetReceiptAlloc(
        allocator,
        root,
        binaries.ledger,
        baseline_revision,
        "recovery-baseline-snapshot",
    );
    defer baseline_snapshot.deinit(allocator);
    try durable_store.writeTextAtomic(allocator, target_path, "candidate\n");
    const add_candidate = try std.fmt.allocPrint(allocator, "git -C '{s}' add -- target.txt", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "recovery-add-candidate", add_candidate);
    const candidate_snapshot = try snapshotTargetReceiptAlloc(
        allocator,
        root,
        binaries.ledger,
        "INDEX",
        "recovery-candidate-snapshot",
    );
    defer candidate_snapshot.deinit(allocator);
    var baseline_bundle = try retrace_core.target_bundle.buildSkillBundleAlloc(
        allocator,
        "target-skill",
        "baseline\n",
        "baseline-target/SKILL.md",
    );
    defer baseline_bundle.deinit(allocator);
    var candidate_bundle = try retrace_core.target_bundle.buildSkillBundleAlloc(
        allocator,
        "target-skill",
        "candidate\n",
        "candidate-target/SKILL.md",
    );
    defer candidate_bundle.deinit(allocator);
    const staged_diff_command = try std.fmt.allocPrint(
        allocator,
        "git -C '{s}' diff --cached --binary --full-index --no-ext-diff --no-color HEAD --",
        .{root},
    );
    const staged_diff = try runIsolatedCommandAlloc(allocator, root, "recovery-staged-diff", staged_diff_command);
    const staged_diff_fingerprint = try digestBytesAlloc(allocator, staged_diff);
    const factor_path = try std.fs.path.join(allocator, &.{ root, "proof-factor.json" });
    const factor_bytes = "{\"schema\":\"hylo-test-factor/v1\",\"instruction\":\"identical\"}";
    try durable_store.writeTextAtomic(allocator, factor_path, factor_bytes);
    const factor_oid_command = try std.fmt.allocPrint(allocator, "git -C '{s}' hash-object -w -- proof-factor.json", .{root});
    const factor_oid_raw = try runIsolatedCommandAlloc(allocator, root, "recovery-factor-oid", factor_oid_command);
    const factor_ref = try std.fmt.allocPrint(
        allocator,
        "git-blob-json:{s}",
        .{std.mem.trim(u8, factor_oid_raw, " \t\r\n")},
    );
    var factor_parsed = try parseJson(allocator, factor_bytes);
    defer factor_parsed.deinit();
    const factor_fingerprint = try hctp.digestValueAlloc(allocator, factor_parsed.value);

    const source_evidence = try runSealedSourceFixtureAlloc(allocator, &role_driver);
    var public_metadata_parsed = try parseJson(allocator, source_evidence.public_metadata);
    defer public_metadata_parsed.deinit();
    const public_metadata = try object(public_metadata_parsed.value);
    const grader_binary_fingerprint = try fileFingerprintAlloc(allocator, binaries.sealed_grader_fixture);
    const presentation_materializer_binary_fingerprint = try fileFingerprintAlloc(
        allocator,
        binaries.sealed_grade_materializer_fixture,
    );
    var source_parsed = try parseJson(allocator, source_evidence.receipt);
    defer source_parsed.deinit();
    const source_root = try object(source_parsed.value);
    const template = try sealedTrialAlloc(
        allocator,
        source_evidence.receipt,
        binaries.sealed_executor,
        binaries.cas,
        binaries.ledger,
        try requiredString(public_metadata, "materializer_public_key_base64"),
        try requiredString(public_metadata, "runner_public_key_base64"),
        try requiredString(public_metadata, "absolute_grader_public_key_base64"),
        try requiredString(public_metadata, "pair_grader_public_key_base64"),
        grader_binary_fingerprint,
        presentation_materializer_binary_fingerprint,
        baseline_revision,
        baseline_snapshot.fingerprint,
        candidate_snapshot.fingerprint,
        baseline_snapshot.target_common_projection orelse return error.TargetCommonProjectionMissing,
        baseline_snapshot.target_common_projection_fingerprint orelse return error.TargetCommonProjectionMissing,
        staged_diff_fingerprint,
    );
    const campaign_text = try sealedCampaignAlloc(
        allocator,
        source_root,
        grader_binary_fingerprint,
        baseline_bundle.bundle_fingerprint,
    );
    const campaign_intent = try sealedArtifactIntentAlloc(
        allocator,
        "campaign_created",
        "campaign",
        campaign_text,
        null,
    );
    _ = try appendSealedIntent(allocator, root, binaries.ledger, "recovery-campaign", campaign_intent);
    const baseline_admission_payload = try sealedTargetAdmissionPayloadAlloc(
        allocator,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        baseline_bundle,
        baseline_revision,
        baseline_snapshot,
    );
    const baseline_admission_intent = try sealedPayloadIntentAlloc(
        allocator,
        "target_bundle_admitted",
        baseline_admission_payload,
    );
    _ = try appendSealedIntent(
        allocator,
        root,
        binaries.ledger,
        "recovery-baseline-target-admission",
        baseline_admission_intent,
    );
    const candidate_admission_payload = try sealedTargetAdmissionPayloadAlloc(
        allocator,
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        candidate_bundle,
        "INDEX",
        candidate_snapshot,
    );
    const candidate_admission_intent = try sealedPayloadIntentAlloc(
        allocator,
        "target_bundle_admitted",
        candidate_admission_payload,
    );
    _ = try appendSealedIntent(
        allocator,
        root,
        binaries.ledger,
        "recovery-candidate-target-admission",
        candidate_admission_intent,
    );
    const source_cases = try requiredArray(source_root, "cases");
    for (source_cases.items, 0..) |case_value, index| {
        const source_case = try object(case_value);
        const scenario_text = try sealedScenarioAlloc(allocator, source_case, grader_binary_fingerprint);
        const scenario_intent = try sealedArtifactIntentAlloc(
            allocator,
            "scenario_admitted",
            "scenario",
            scenario_text,
            try requiredString(source_case, "scenario_id"),
        );
        const label = try std.fmt.allocPrint(allocator, "recovery-scenario-{s}-{d}", .{ suffix, index + 1 });
        _ = try appendSealedIntent(allocator, root, binaries.ledger, label, scenario_intent);
    }
    const trial = try sealedPracticeTrialAlloc(
        allocator,
        template,
        source_evidence.practice_receipt,
        factor_ref,
        factor_fingerprint,
        .{
            .trial_id = trial_id,
            .hypothesis_id = if (mode == .terminal_adoption)
                "hypothesis-sealed-recovery-terminal"
            else
                "hypothesis-sealed-recovery-claimed",
            .pair_id = if (mode == .terminal_adoption)
                "pair-sealed-recovery-terminal"
            else
                "pair-sealed-recovery-claimed",
            .block_id = if (mode == .terminal_adoption)
                "block-sealed-recovery-terminal"
            else
                "block-sealed-recovery-claimed",
            .lane_a0 = lane_a0,
            .lane_a1 = lane_a1,
            .nonce = if (mode == .terminal_adoption)
                "sealed-recovery-terminal-00112233445566778899aabbccddeeff"
            else
                "sealed-recovery-claimed-00112233445566778899aabbccddeeff",
        },
    );
    const registration = try registerNativeTrial(allocator, root, binaries.ledger, trial);
    const store_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "hylo", "events.jsonl" });
    var persistence = durable_store.PersistentEventStore.init(store_path);
    const store = persistence.eventStore();

    if (mode == .terminal_adoption) {
        try expectLegacySealedStartRejected(
            allocator,
            binaries.ledger,
            root,
            trial_id,
            lane_a0,
        );
        var before_prepare = try store.snapshot(allocator, MaxBytes);
        defer before_prepare.deinit(allocator);
        try roleLaneCrashRequestAlloc(
            allocator,
            &role_driver,
            "materialize-run-exit-after-prepare",
            trial_id,
            lane_a0,
            83,
        );
        var after_prepare = try store.snapshot(allocator, MaxBytes);
        defer after_prepare.deinit(allocator);
        try std.testing.expectEqual(before_prepare.records.len, after_prepare.records.len);
        try std.testing.expectEqualStrings(before_prepare.content_digest, after_prepare.content_digest);
        const custody_path = try std.fs.path.join(
            allocator,
            &.{ root, ".hctp-role-driver", "private-state.sealed.json" },
        );
        const custody_envelope = try durable_store.readRegularFileNoSymlink(allocator, custody_path, MaxBytes);
        inline for (.{
            "\"hctp-role-driver-private-state/v3\"",
            "\"pending_lane\"",
            "\"lease\"",
            "\"resume_secrets\"",
            "\"seal_key_base64\"",
            "\"materializer_seed_base64\"",
            "\"runner_seed_base64\"",
            "HYL1-",
        }) |private_marker| {
            try std.testing.expect(std.mem.indexOf(u8, custody_envelope, private_marker) == null);
        }
        const mismatch_request = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"materialize-run\",\"trial_id\":{f},\"lane_id\":{f}}}",
            .{ std.json.fmt(trial_id, .{}), std.json.fmt(lane_a1, .{}) },
        );
        try std.testing.expectError(error.RoleDriverClosed, role_driver.requestAlloc(mismatch_request));
        try role_driver.restartAfterExit(1);
        var after_mismatch = try store.snapshot(allocator, MaxBytes);
        defer after_mismatch.deinit(allocator);
        try std.testing.expectEqual(after_prepare.records.len, after_mismatch.records.len);
        try std.testing.expectEqualStrings(after_prepare.content_digest, after_mismatch.content_digest);
        try std.testing.expectError(
            error.RoleDriverClosed,
            role_driver.requestAlloc(
                "{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"shutdown\"}",
            ),
        );
        try role_driver.restartAfterExit(1);
        var after_rejected_shutdown = try store.snapshot(allocator, MaxBytes);
        defer after_rejected_shutdown.deinit(allocator);
        try std.testing.expectEqual(after_prepare.records.len, after_rejected_shutdown.records.len);
        try std.testing.expectEqualStrings(after_prepare.content_digest, after_rejected_shutdown.content_digest);

        try roleLaneCrashRequestAlloc(
            allocator,
            &role_driver,
            "materialize-run-exit-after-start-commit",
            trial_id,
            lane_a0,
            84,
        );
        var after_commit = try store.snapshot(allocator, MaxBytes);
        defer after_commit.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), try laneEventCount(allocator, after_commit, "lane_started", lane_a0));
        try roleLaneCrashRequestAlloc(
            allocator,
            &role_driver,
            "materialize-run-exit-after-cas-terminal",
            trial_id,
            lane_a0,
            88,
        );
        var after_cas_terminal = try store.snapshot(allocator, MaxBytes);
        defer after_cas_terminal.deinit(allocator);
        try std.testing.expectEqual(after_commit.records.len, after_cas_terminal.records.len);
        try std.testing.expectEqual(@as(usize, 0), try laneEventCount(allocator, after_cas_terminal, "lane_finished", lane_a0));
        const receipt_dir = try std.fs.path.join(
            allocator,
            &.{ root, ".hctp-role-driver", "runner-receipts" },
        );
        const status_command = try std.fmt.allocPrint(
            allocator,
            "'{s}' status --trial-id '{s}' --lane-id '{s}' --receipt-dir '{s}' --json",
            .{ binaries.cas, trial_id, lane_a0, receipt_dir },
        );
        const status_output = try runIsolatedCommandAlloc(
            allocator,
            root,
            "recovery-terminal-status",
            status_command,
        );
        var status_parsed = try parseJson(allocator, status_output);
        defer status_parsed.deinit();
        try std.testing.expectEqualStrings("terminal", try requiredString(try object(status_parsed.value), "state"));

        try roleLaneCrashRequestAlloc(
            allocator,
            &role_driver,
            "materialize-run-exit-after-finish",
            trial_id,
            lane_a0,
            85,
        );
        const lane_ack = try runRoleLaneAlloc(allocator, &role_driver, trial_id, lane_a0);
        const lane_retry_ack = try runRoleLaneAlloc(allocator, &role_driver, trial_id, lane_a0);
        try std.testing.expectEqualStrings(lane_ack, lane_retry_ack);
        var completed = try store.snapshot(allocator, MaxBytes);
        defer completed.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), try laneEventCount(allocator, completed, "lane_started", lane_a0));
        try std.testing.expectEqual(@as(usize, 1), try laneEventCount(allocator, completed, "lane_finished", lane_a0));
    } else {
        try roleLaneCrashRequestAlloc(
            allocator,
            &role_driver,
            "materialize-run-exit-after-start-commit",
            trial_id,
            lane_a0,
            84,
        );
        var started = try store.snapshot(allocator, MaxBytes);
        defer started.deinit(allocator);
        const public_start = try publicLaneStartAlloc(
            allocator,
            started,
            lane_a0,
            registration.event_digest,
        );
        defer public_start.deinit(allocator);
        try persistVerifiedCasClaim(allocator, trial_id, lane_a0, public_start);
        const receipt_dir = try std.fs.path.join(
            allocator,
            &.{ root, ".hctp-role-driver", "runner-receipts" },
        );
        const status_command = try std.fmt.allocPrint(
            allocator,
            "'{s}' status --trial-id '{s}' --lane-id '{s}' --receipt-dir '{s}' --json",
            .{ binaries.cas, trial_id, lane_a0, receipt_dir },
        );
        const status_output = try runIsolatedCommandAlloc(
            allocator,
            root,
            "recovery-claimed-status",
            status_command,
        );
        var status_parsed = try parseJson(allocator, status_output);
        defer status_parsed.deinit();
        try std.testing.expectEqualStrings("claimed", try requiredString(try object(status_parsed.value), "state"));
        var before_retry = try store.snapshot(allocator, MaxBytes);
        defer before_retry.deinit(allocator);
        const request = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"materialize-run\",\"trial_id\":{f},\"lane_id\":{f}}}",
            .{ std.json.fmt(trial_id, .{}), std.json.fmt(lane_a0, .{}) },
        );
        try std.testing.expectError(error.RoleDriverClosed, role_driver.requestAlloc(request));
        try role_driver.restartAfterExit(1);
        var after_retry = try store.snapshot(allocator, MaxBytes);
        defer after_retry.deinit(allocator);
        try std.testing.expectEqual(before_retry.records.len, after_retry.records.len);
        try std.testing.expectEqualStrings(before_retry.content_digest, after_retry.content_digest);
        try std.testing.expectEqual(@as(usize, 1), try laneEventCount(allocator, after_retry, "lane_started", lane_a0));
        try std.testing.expectEqual(@as(usize, 0), try laneEventCount(allocator, after_retry, "lane_finished", lane_a0));
    }
}

fn runSealedRoleTrial(
    allocator: std.mem.Allocator,
    role_driver: *RoleDriverSession,
    ledger_path: []const u8,
    root: []const u8,
    trial_id: []const u8,
    pair_lanes: []const [2][]const u8,
    reveal_template: []const u8,
    prove_first_pair_quarantine: bool,
    prove_final_pair_crash_recovery: bool,
) ![]u8 {
    for (pair_lanes, 0..) |lanes, pair_index| {
        for (lanes) |lane_id| {
            const lane_ack = try runRoleLaneAlloc(allocator, role_driver, trial_id, lane_id);
            defer allocator.free(lane_ack);
            const lane_retry_ack = try runRoleLaneAlloc(allocator, role_driver, trial_id, lane_id);
            defer allocator.free(lane_retry_ack);
            try std.testing.expectEqualStrings(lane_ack, lane_retry_ack);
            const grade_ack = try runRoleGradeAlloc(allocator, role_driver, "absolute", lane_id, null);
            defer allocator.free(grade_ack);
        }
        const pair_ack = if (prove_final_pair_crash_recovery and pair_index + 1 == pair_lanes.len)
            try runRolePairGradeCrashRecoveryAlloc(allocator, role_driver, root, lanes[0], lanes[1])
        else
            try runRoleGradeAlloc(allocator, role_driver, "pair", lanes[0], lanes[1]);
        defer allocator.free(pair_ack);
        if (prove_first_pair_quarantine and pair_index == 0) {
            inline for (.{ "grade", "pair-grade" }) |kind| {
                const inspect = try std.fmt.allocPrint(
                    allocator,
                    "'{s}' --source hylo inspect --repo '{s}' --trial-id '{s}' --kind '{s}'",
                    .{ ledger_path, root, trial_id, kind },
                );
                defer allocator.free(inspect);
                const label = try std.fmt.allocPrint(allocator, "sealed-pre-reveal-{s}", .{kind});
                defer allocator.free(label);
                try std.testing.expectError(
                    error.IntegrationCommandFailed,
                    runIsolatedCommandAlloc(allocator, root, label, inspect),
                );
            }
        }
    }
    if (!prove_final_pair_crash_recovery) {
        const rejection_ack = try runRoleRevealAtomicityAlloc(allocator, role_driver, trial_id, reveal_template);
        defer allocator.free(rejection_ack);
    }
    const reveal_ack = if (prove_final_pair_crash_recovery)
        try runRoleRevealCrashRecoveryAlloc(allocator, role_driver, root, trial_id, reveal_template)
    else
        try runRoleRevealAlloc(allocator, role_driver, trial_id, reveal_template);
    defer allocator.free(reveal_ack);
    _ = try closeSealedTrialAlloc(allocator, root, ledger_path, trial_id);
    return sealedTrialResultAlloc(allocator, root, ledger_path, trial_id);
}

test "HCTP sealed promotion Section 36 case 67 positive witness: supported holdout improvement is published" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const binaries = try integrationPaths(allocator);
    try runSealedLaneRecoveryProbe(allocator, binaries, .terminal_adoption);
    try runSealedLaneRecoveryProbe(allocator, binaries, .claimed_fail_closed);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);

    const git_init = try std.fmt.allocPrint(allocator, "git -C '{s}' init -q", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "sealed-git-init", git_init);
    const git_user_name = try std.fmt.allocPrint(allocator, "git -C '{s}' config user.name 'HCTP Fixture'", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "sealed-git-user-name", git_user_name);
    const git_user_email = try std.fmt.allocPrint(allocator, "git -C '{s}' config user.email 'hctp-fixture@example.invalid'", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "sealed-git-user-email", git_user_email);
    const exclude_path = try std.fs.path.join(allocator, &.{ root, ".git", "info", "exclude" });
    try durable_store.writeTextAtomic(allocator, exclude_path, ".ledger/\n.hctp-role-driver/\n");
    var role_driver = try RoleDriverSession.init(allocator, binaries.sealed_role_driver, root);
    defer role_driver.deinit();
    const target_path = try std.fs.path.join(allocator, &.{ root, "target.txt" });
    try durable_store.writeTextAtomic(allocator, target_path, "baseline\n");
    const git_add_baseline = try std.fmt.allocPrint(allocator, "git -C '{s}' add -- target.txt", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "sealed-git-add-baseline", git_add_baseline);
    const git_commit_baseline = try std.fmt.allocPrint(allocator, "git -C '{s}' commit -qm 'sealed baseline'", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "sealed-git-commit-baseline", git_commit_baseline);
    const baseline_revision_command = try std.fmt.allocPrint(allocator, "git -C '{s}' rev-parse HEAD", .{root});
    const baseline_revision_raw = try runIsolatedCommandAlloc(allocator, root, "sealed-baseline-revision", baseline_revision_command);
    const baseline_revision = std.mem.trim(u8, baseline_revision_raw, " \t\r\n");
    const baseline_snapshot = try snapshotTargetReceiptAlloc(
        allocator,
        root,
        binaries.ledger,
        baseline_revision,
        "sealed-baseline-snapshot",
    );
    defer baseline_snapshot.deinit(allocator);
    try durable_store.writeTextAtomic(allocator, target_path, "candidate\n");
    const git_add_candidate = try std.fmt.allocPrint(allocator, "git -C '{s}' add -- target.txt", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "sealed-git-add-candidate", git_add_candidate);
    const candidate_snapshot = try snapshotTargetReceiptAlloc(
        allocator,
        root,
        binaries.ledger,
        "INDEX",
        "sealed-candidate-snapshot",
    );
    defer candidate_snapshot.deinit(allocator);
    var baseline_bundle = try retrace_core.target_bundle.buildSkillBundleAlloc(
        allocator,
        "target-skill",
        "baseline\n",
        "baseline-target/SKILL.md",
    );
    defer baseline_bundle.deinit(allocator);
    var candidate_bundle = try retrace_core.target_bundle.buildSkillBundleAlloc(
        allocator,
        "target-skill",
        "candidate\n",
        "candidate-target/SKILL.md",
    );
    defer candidate_bundle.deinit(allocator);
    const staged_diff_command = try std.fmt.allocPrint(
        allocator,
        "git -C '{s}' diff --cached --binary --full-index --no-ext-diff --no-color HEAD --",
        .{root},
    );
    const staged_diff = try runIsolatedCommandAlloc(allocator, root, "sealed-staged-diff", staged_diff_command);
    const staged_diff_fingerprint = try digestBytesAlloc(allocator, staged_diff);

    const factor_path = try std.fs.path.join(allocator, &.{ root, "proof-factor.json" });
    const factor_bytes = "{\"schema\":\"hylo-test-factor/v1\",\"instruction\":\"identical\"}";
    try durable_store.writeTextAtomic(allocator, factor_path, factor_bytes);
    const factor_oid_command = try std.fmt.allocPrint(allocator, "git -C '{s}' hash-object -w -- proof-factor.json", .{root});
    const factor_oid_raw = try runIsolatedCommandAlloc(allocator, root, "sealed-factor-oid", factor_oid_command);
    const factor_ref = try std.fmt.allocPrint(
        allocator,
        "git-blob-json:{s}",
        .{std.mem.trim(u8, factor_oid_raw, " \t\r\n")},
    );
    var factor_parsed = try parseJson(allocator, factor_bytes);
    defer factor_parsed.deinit();
    const factor_fingerprint = try hctp.digestValueAlloc(allocator, factor_parsed.value);

    const source_evidence = try runSealedSourceFixtureAlloc(
        allocator,
        &role_driver,
    );
    var public_metadata_parsed = try parseJson(allocator, source_evidence.public_metadata);
    defer public_metadata_parsed.deinit();
    const public_metadata = try object(public_metadata_parsed.value);
    const materializer_public_key = try requiredString(public_metadata, "materializer_public_key_base64");
    const runner_public_key = try requiredString(public_metadata, "runner_public_key_base64");
    const absolute_grader_public_key = try requiredString(public_metadata, "absolute_grader_public_key_base64");
    const pair_grader_public_key = try requiredString(public_metadata, "pair_grader_public_key_base64");
    const grader_binary_fingerprint = try fileFingerprintAlloc(allocator, binaries.sealed_grader_fixture);
    const presentation_materializer_binary_fingerprint = try fileFingerprintAlloc(
        allocator,
        binaries.sealed_grade_materializer_fixture,
    );
    try std.testing.expect(!(try requiredBool(public_metadata, "seal_key_disclosed")));
    try std.testing.expect(!(try requiredBool(public_metadata, "signing_seed_disclosed")));

    var source_parsed = try parseJson(allocator, source_evidence.receipt);
    defer source_parsed.deinit();
    const source_root = try object(source_parsed.value);
    const source_owner = try requiredObject(source_root, "source_owner_attestation");
    const source_producer = try requiredObject(source_owner, "producer");
    try std.testing.expectEqualStrings(
        try requiredString(public_metadata, "source_owner_key_id"),
        try requiredString(source_producer, "key_id"),
    );
    try std.testing.expectEqualStrings(
        try requiredString(public_metadata, "source_owner_public_key_base64"),
        try requiredString(source_producer, "public_key_base64"),
    );
    const denominator = try requiredObject(source_root, "denominator");
    try std.testing.expectEqual(@as(i64, 6), switch (try required(denominator, "source_cases")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    });
    try std.testing.expectEqual(@as(i64, 6), switch (try required(denominator, "independence_clusters")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    });
    const source_cases = try requiredArray(source_root, "cases");
    for (source_cases.items) |case_value| {
        const case = try object(case_value);
        try std.testing.expect(case.get("visible_input") == null);
        try std.testing.expect(case.get("hidden_reference") == null);
        _ = try requiredObject(case, "sealed_case");
    }

    var holdout_source_parsed = try parseJson(allocator, source_evidence.holdout_receipt);
    defer holdout_source_parsed.deinit();
    const holdout_source_root = try object(holdout_source_parsed.value);
    const holdout_denominator = try requiredObject(holdout_source_root, "denominator");
    inline for (.{ "source_cases", "independence_clusters", "holdout" }) |field| {
        try std.testing.expectEqual(@as(i64, 5), switch (try required(holdout_denominator, field)) {
            .integer => |value| value,
            else => return error.IntegerRequired,
        });
    }
    inline for (.{ "practice", "challenge" }) |field| {
        try std.testing.expectEqual(@as(i64, 0), switch (try required(holdout_denominator, field)) {
            .integer => |value| value,
            else => return error.IntegerRequired,
        });
    }
    const holdout_cases = try requiredArray(holdout_source_root, "cases");
    try std.testing.expectEqual(@as(usize, 5), holdout_cases.items.len);
    for (holdout_cases.items) |case_value| {
        try std.testing.expectEqualStrings("holdout", try requiredString(try object(case_value), "split"));
    }
    const historical_holdout_profile = try requiredObject(
        try object(holdout_cases.items[0]),
        "source_profile",
    );
    try std.testing.expectEqualStrings(
        "historical_decision",
        try requiredString(historical_holdout_profile, "kind"),
    );
    try std.testing.expectEqualStrings(
        "source_profile_fd",
        try requiredString(historical_holdout_profile, "profile_body_delivery"),
    );
    try std.testing.expect(historical_holdout_profile.get("decision_context") == null);
    try std.testing.expect(historical_holdout_profile.get("source_governance") == null);

    const bootstrap_template = try sealedTrialAlloc(
        allocator,
        source_evidence.receipt,
        binaries.sealed_executor,
        binaries.cas,
        binaries.ledger,
        materializer_public_key,
        runner_public_key,
        absolute_grader_public_key,
        pair_grader_public_key,
        grader_binary_fingerprint,
        presentation_materializer_binary_fingerprint,
        baseline_revision,
        baseline_snapshot.fingerprint,
        candidate_snapshot.fingerprint,
        baseline_snapshot.target_common_projection orelse return error.TargetCommonProjectionMissing,
        baseline_snapshot.target_common_projection_fingerprint orelse return error.TargetCommonProjectionMissing,
        staged_diff_fingerprint,
    );
    const trial_text = try sealedTrialAlloc(
        allocator,
        source_evidence.holdout_receipt,
        binaries.sealed_executor,
        binaries.cas,
        binaries.ledger,
        materializer_public_key,
        runner_public_key,
        absolute_grader_public_key,
        pair_grader_public_key,
        grader_binary_fingerprint,
        presentation_materializer_binary_fingerprint,
        baseline_revision,
        baseline_snapshot.fingerprint,
        candidate_snapshot.fingerprint,
        baseline_snapshot.target_common_projection orelse return error.TargetCommonProjectionMissing,
        baseline_snapshot.target_common_projection_fingerprint orelse return error.TargetCommonProjectionMissing,
        staged_diff_fingerprint,
    );
    try std.testing.expect(std.mem.indexOf(u8, trial_text, "\"request\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, trial_text, "\"expected\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, trial_text, "role-bound single-use FD capabilities") != null);
    var sealed_trial_parsed = try parseJson(allocator, trial_text);
    defer sealed_trial_parsed.deinit();
    const sealed_runner_contract = try requiredObject(
        try requiredObject(try object(sealed_trial_parsed.value), "execution"),
        "runner_contract",
    );
    try std.testing.expectEqualStrings(
        "cas-trial-executor-request/v2",
        try requiredString(sealed_runner_contract, "executor_request_schema"),
    );
    var validation = try hctp.validateTrialAlloc(allocator, trial_text);
    defer validation.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), validation.unit_count);
    try std.testing.expectEqual(@as(usize, 5), validation.pair_count);
    try std.testing.expectEqual(@as(usize, 10), validation.lane_count);

    const campaign_text = try sealedCampaignAlloc(
        allocator,
        source_root,
        grader_binary_fingerprint,
        baseline_bundle.bundle_fingerprint,
    );
    const campaign_intent = try sealedArtifactIntentAlloc(allocator, "campaign_created", "campaign", campaign_text, null);
    _ = try appendSealedIntent(allocator, root, binaries.ledger, "sealed-campaign", campaign_intent);
    const baseline_admission_payload = try sealedTargetAdmissionPayloadAlloc(
        allocator,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        baseline_bundle,
        baseline_revision,
        baseline_snapshot,
    );
    const baseline_admission_intent = try sealedPayloadIntentAlloc(
        allocator,
        "target_bundle_admitted",
        baseline_admission_payload,
    );
    _ = try appendSealedIntent(
        allocator,
        root,
        binaries.ledger,
        "sealed-baseline-target-admission",
        baseline_admission_intent,
    );
    const candidate_admission_payload = try sealedTargetAdmissionPayloadAlloc(
        allocator,
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        candidate_bundle,
        "INDEX",
        candidate_snapshot,
    );
    const candidate_admission_intent = try sealedPayloadIntentAlloc(
        allocator,
        "target_bundle_admitted",
        candidate_admission_payload,
    );
    _ = try appendSealedIntent(
        allocator,
        root,
        binaries.ledger,
        "sealed-candidate-target-admission",
        candidate_admission_intent,
    );
    for (source_cases.items, 0..) |case_value, index| {
        const source_case = try object(case_value);
        const scenario_text = try sealedScenarioAlloc(allocator, source_case, grader_binary_fingerprint);
        const scenario_intent = try sealedArtifactIntentAlloc(
            allocator,
            "scenario_admitted",
            "scenario",
            scenario_text,
            try requiredString(source_case, "scenario_id"),
        );
        const label = try std.fmt.allocPrint(allocator, "sealed-scenario-{d}", .{index + 1});
        _ = try appendSealedIntent(allocator, root, binaries.ledger, label, scenario_intent);
    }

    const bootstrap_trial = try sealedPracticeTrialAlloc(
        allocator,
        bootstrap_template,
        source_evidence.practice_receipt,
        factor_ref,
        factor_fingerprint,
        .{
            .trial_id = "trial-sealed-bootstrap",
            .hypothesis_id = "hypothesis-sealed-bootstrap",
            .pair_id = "pair-practice-bootstrap",
            .block_id = "block-practice-bootstrap",
            .lane_a0 = "lane-practice-bootstrap-a0",
            .lane_a1 = "lane-practice-bootstrap-a1",
            .nonce = "sealed-bootstrap-00112233445566778899aabbccddeeff",
        },
    );
    var bootstrap_validation = try hctp.validateTrialAlloc(allocator, bootstrap_trial);
    defer bootstrap_validation.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), bootstrap_validation.unit_count);
    try std.testing.expectEqual(@as(usize, 1), bootstrap_validation.pair_count);
    try std.testing.expectEqual(@as(usize, 2), bootstrap_validation.lane_count);
    _ = try registerNativeTrial(allocator, root, binaries.ledger, bootstrap_trial);
    const bootstrap_pairs = [_][2][]const u8{.{
        "lane-practice-bootstrap-a0",
        "lane-practice-bootstrap-a1",
    }};
    const bootstrap_reveal = try sealedRevealTemplateAlloc(allocator, "trial-sealed-bootstrap", true);
    const bootstrap_result = try runSealedRoleTrial(
        allocator,
        &role_driver,
        binaries.ledger,
        root,
        "trial-sealed-bootstrap",
        &bootstrap_pairs,
        bootstrap_reveal,
        false,
        false,
    );
    var bootstrap_result_parsed = try parseJson(allocator, bootstrap_result);
    defer bootstrap_result_parsed.deinit();
    const bootstrap_result_root = try object(bootstrap_result_parsed.value);
    try std.testing.expectEqualStrings("completed", try requiredString(bootstrap_result_root, "status"));
    try std.testing.expectEqualStrings("practice_repair", try requiredString(bootstrap_result_root, "purpose"));
    try std.testing.expectEqualStrings(
        "unsupported",
        try requiredString(try requiredObject(bootstrap_result_root, "claims"), "absolute_qualification"),
    );
    const bootstrap_result_fingerprint = try allocator.dupe(
        u8,
        try requiredString(bootstrap_result_root, "result_fingerprint"),
    );

    const change_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"change_id\":\"change-sealed-positive\",\"status\":\"applied\",\"before_target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"after_target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"before_target_bundle_fingerprint\":{f},\"after_target_bundle_fingerprint\":{f},\"before_target_snapshot_fingerprint\":{f},\"after_target_snapshot_fingerprint\":{f},\"owner_route\":\"skill-owner\",\"authority_ref\":\"user:test\",\"paths\":[\"target.txt\"],\"diff_ref\":\"git-index:HEAD\",\"diff_fingerprint\":{f},\"motivation_grade_ids\":[],\"motivation_trial_ids\":[\"trial-sealed-bootstrap\"],\"motivation_result_fingerprints\":[{f}],\"feedback_ids\":[],\"validation_refs\":[\"test:sealed-bootstrap\"]}}",
        .{
            std.json.fmt(baseline_bundle.bundle_fingerprint, .{}),
            std.json.fmt(candidate_bundle.bundle_fingerprint, .{}),
            std.json.fmt(baseline_snapshot.fingerprint, .{}),
            std.json.fmt(candidate_snapshot.fingerprint, .{}),
            std.json.fmt(staged_diff_fingerprint, .{}),
            std.json.fmt(bootstrap_result_fingerprint, .{}),
        },
    );
    const change_intent = try sealedPayloadIntentAlloc(allocator, "change_recorded", change_payload);
    _ = try appendSealedIntent(allocator, root, binaries.ledger, "sealed-applied-change", change_intent);

    _ = try registerNativeTrial(allocator, root, binaries.ledger, trial_text);
    var promotion_pairs: std.ArrayList([2][]const u8) = .empty;
    for (0..holdout_cases.items.len) |index| {
        try promotion_pairs.append(allocator, .{
            try std.fmt.allocPrint(allocator, "lane-holdout-{d}-x", .{index + 1}),
            try std.fmt.allocPrint(allocator, "lane-holdout-{d}-y", .{index + 1}),
        });
    }
    const promotion_reveal = try sealedRevealTemplateAlloc(allocator, "trial-sealed-positive", false);
    const result = try runSealedRoleTrial(
        allocator,
        &role_driver,
        binaries.ledger,
        root,
        "trial-sealed-positive",
        promotion_pairs.items,
        promotion_reveal,
        true,
        true,
    );
    try assertCaseBlindHistoricalLaneAndCleanup(
        allocator,
        binaries,
        root,
        "trial-sealed-positive",
        "lane-holdout-1-x",
        source_evidence.holdout_receipt,
        trial_text,
    );
    var result_parsed = try parseJson(allocator, result);
    defer result_parsed.deinit();
    const result_root = try object(result_parsed.value);
    try std.testing.expectEqualStrings("completed", try requiredString(result_root, "status"));
    try std.testing.expectEqualStrings("inapplicable", try requiredString(try requiredObject(result_root, "calibration"), "status"));
    const completeness = try requiredObject(result_root, "completeness");
    try std.testing.expectEqual(@as(i64, 10), switch (try required(completeness, "lanes_terminal")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    });
    const holdout = try requiredObject(try requiredObject(result_root, "split_results"), "holdout");
    try std.testing.expectEqual(@as(i64, 5), switch (try required(holdout, "independent_clusters")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    });
    const correctness = try requiredObject(try requiredObject(holdout, "dimensions"), "correctness");
    const effect = switch (try required(correctness, "effect")) {
        .float => |value| value,
        .integer => |value| @as(f64, @floatFromInt(value)),
        else => return error.NumberRequired,
    };
    const lower = switch (try required(correctness, "lower")) {
        .float => |value| value,
        .integer => |value| @as(f64, @floatFromInt(value)),
        else => return error.NumberRequired,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), effect, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), lower, 1e-12);
    try std.testing.expect(lower > 0.05);
    try std.testing.expectEqualStrings("supported", try requiredString(try requiredObject(result_root, "claims"), "holdout_improvement"));
    try std.testing.expectEqual(@as(usize, 0), (try requiredArray(result_root, "critical_regressions")).items.len);
    try std.testing.expect(try improvementPublicationPolicySupported(result_root));

    const commit_command = try std.fmt.allocPrint(
        allocator,
        "git -C '{s}' commit -qm 'sealed candidate'",
        .{root},
    );
    _ = try runIsolatedCommandAlloc(allocator, root, "sealed-candidate-commit", commit_command);
    const commit_sha_command = try std.fmt.allocPrint(allocator, "git -C '{s}' rev-parse HEAD", .{root});
    const commit_sha_raw = try runIsolatedCommandAlloc(
        allocator,
        root,
        "sealed-candidate-commit-sha",
        commit_sha_command,
    );
    const commit_sha = std.mem.trim(u8, commit_sha_raw, " \t\r\n");
    const commit_tree_command = try std.fmt.allocPrint(allocator, "git -C '{s}' rev-parse 'HEAD^{{tree}}'", .{root});
    const commit_tree_raw = try runIsolatedCommandAlloc(
        allocator,
        root,
        "sealed-candidate-commit-tree",
        commit_tree_command,
    );
    const commit_tree = std.mem.trim(u8, commit_tree_raw, " \t\r\n");

    var publication: std.Io.Writer.Allocating = .init(allocator);
    try publication.writer.writeAll("{\"publication_id\":\"publication-sealed-positive\",\"status\":\"committed\",\"change_id\":\"change-sealed-positive\",\"authority_ref\":\"user:test\",\"candidate_target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"commit_sha\":");
    try appendJsonString(&publication.writer, commit_sha);
    try publication.writer.writeAll(",\"candidate_target_bundle_fingerprint\":");
    try appendJsonString(&publication.writer, candidate_bundle.bundle_fingerprint);
    try publication.writer.writeAll(",\"candidate_target_snapshot_fingerprint\":");
    try appendJsonString(&publication.writer, candidate_snapshot.fingerprint);
    try publication.writer.writeAll(",\"commit_tree_ref\":");
    const commit_tree_ref = try std.fmt.allocPrint(allocator, "git-tree:{s}", .{commit_tree});
    try appendJsonString(&publication.writer, commit_tree_ref);
    try publication.writer.writeAll(",\"paths\":[\"target.txt\"],\"validation_refs\":[\"test:sealed-promotion\"],\"promotion_grade_ids\":[");
    for (0..holdout_cases.items.len) |index| {
        if (index != 0) try publication.writer.writeByte(',');
        const grade_id = try std.fmt.allocPrint(allocator, "grade-lane-holdout-{d}-y", .{index + 1});
        try appendJsonString(&publication.writer, grade_id);
    }
    try publication.writer.writeAll("],\"promotion_trial_id\":\"trial-sealed-positive\",\"promotion_trial_result_fingerprint\":");
    try appendJsonString(&publication.writer, try requiredString(result_root, "result_fingerprint"));
    try publication.writer.writeAll(",\"practice_trial_ids\":[\"trial-sealed-bootstrap\"],\"calibration_trial_ids\":[],\"claim_requirements_satisfied\":[\"absolute_qualification\",\"noninferiority\",\"holdout_improvement\"]}");
    const publication_payload = try publication.toOwnedSlice();
    const publication_intent = try sealedPayloadIntentAlloc(
        allocator,
        "publication_recorded",
        publication_payload,
    );
    const publication_ack = try appendSealedIntent(
        allocator,
        root,
        binaries.ledger,
        "sealed-positive-publication",
        publication_intent,
    );
    var publication_ack_parsed = try parseJson(allocator, publication_ack);
    defer publication_ack_parsed.deinit();
    const publication_ack_root = try object(publication_ack_parsed.value);
    try std.testing.expectEqualStrings("hylo-ledger-append-receipt/v1", try requiredString(publication_ack_root, "schema"));
    try std.testing.expectEqualStrings("publication_recorded", try requiredString(publication_ack_root, "kind"));

    // Both commands start new Ledger processes and therefore reload the
    // persistent EventStore rather than observing the append in memory.
    const reloaded_result = try sealedTrialResultAlloc(
        allocator,
        root,
        binaries.ledger,
        "trial-sealed-positive",
    );
    var reloaded_result_parsed = try parseJson(allocator, reloaded_result);
    defer reloaded_result_parsed.deinit();
    try std.testing.expectEqualStrings(
        try requiredString(result_root, "result_fingerprint"),
        try requiredString(try object(reloaded_result_parsed.value), "result_fingerprint"),
    );
    const report_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo trial-result --repo '{s}' --trial-id 'trial-sealed-positive' --format markdown",
        .{ binaries.ledger, root },
    );
    const reloaded_report = try runIsolatedCommandAlloc(
        allocator,
        root,
        "sealed-positive-publication-report",
        report_command,
    );
    try std.testing.expect(std.mem.indexOf(u8, reloaded_report, "publication-sealed-positive") != null);
    try std.testing.expect(std.mem.indexOf(u8, reloaded_report, "committed") != null);

    // This completed promotion is evidence for publication only. It is not a
    // repair-eligible practice trial; Hylo's owner boundary rejects it as a
    // change motivation (Section 36 case 57).
    try std.testing.expectEqualStrings("promotion", try requiredString(result_root, "purpose"));
    try role_driver.shutdown();
    const custody_path = try std.fs.path.join(allocator, &.{ root, ".hctp-role-driver", "private-state.sealed.json" });
    defer allocator.free(custody_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, custody_path, .{ .follow_symlinks = false }),
    );
}

test "HCTP end-to-end: registered twin lanes use actual CAS receipts before blind grading and reveal" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const binaries = try integrationPaths(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const native_campaign = try setupNativeCampaign(allocator, root, binaries.ledger, binaries.executor, binaries.cas);
    const source_owned = try bindProofSourceOwnerAlloc(allocator, fixtures.valid_null_trial, binaries.executor, binaries.cas, binaries.ledger);
    const factor_bound = try bindNullFactorMaterializationAlloc(allocator, root, source_owned);
    const trial = try bindRunnerContractAlloc(allocator, factor_bound, binaries.executor, binaries.cas, binaries.ledger);
    const registration = try registerNativeTrial(allocator, root, binaries.ledger, trial);

    var state: hctp.CampaignTrials = .{};
    defer state.deinit(allocator);
    try registerTrial(allocator, &state, trial, registration.event_digest);

    const invented_lease_path = try std.fs.path.join(allocator, &.{ root, "invented.lease" });
    try durable_store.writeTextAtomic(allocator, invented_lease_path, "HYL1-invented-private-retry");
    try std.testing.expectError(
        error.CasTrialFailed,
        runCasLane(
            allocator,
            binaries.cas,
            binaries.executor,
            root,
            registration.trial_path,
            "lane-null-a0",
            invented_lease_path,
            native_campaign.scenario_path,
            native_campaign.scenario_fingerprint,
            RegistrationDigest,
            StartDigestA0,
        ),
    );

    const start_a0 = try startNativeLane(allocator, root, binaries.ledger, "trial-null-001", "lane-null-a0");
    try startLane(allocator, &state, "lane-null-a0", start_a0.lease_digest, native_campaign.scenario_fingerprint, 2, start_a0.start_digest);
    const receipt_a0 = try runCasLane(allocator, binaries.cas, binaries.executor, root, registration.trial_path, "lane-null-a0", start_a0.lease_path, native_campaign.scenario_path, native_campaign.scenario_fingerprint, registration.event_digest, start_a0.start_digest);
    try finishNativeLane(allocator, root, binaries.ledger, "trial-null-001", "lane-null-a0", start_a0.lease_path);
    try finishLane(allocator, &state, "lane-null-a0", receipt_a0, 3);
    try gradeLane(allocator, &state, "lane-null-a0", "arm-0", "grade-null-a0");

    const start_a1 = try startNativeLane(allocator, root, binaries.ledger, "trial-null-001", "lane-null-a1");
    try startLane(allocator, &state, "lane-null-a1", start_a1.lease_digest, native_campaign.scenario_fingerprint, 4, start_a1.start_digest);
    const receipt_a1 = try runCasLane(allocator, binaries.cas, binaries.executor, root, registration.trial_path, "lane-null-a1", start_a1.lease_path, native_campaign.scenario_path, native_campaign.scenario_fingerprint, registration.event_digest, start_a1.start_digest);
    try finishNativeLane(allocator, root, binaries.ledger, "trial-null-001", "lane-null-a1", start_a1.lease_path);
    try finishLane(allocator, &state, "lane-null-a1", receipt_a1, 5);
    try gradeLane(allocator, &state, "lane-null-a1", "arm-1", "grade-null-a1");
    try pairGrade(allocator, &state);
    try reveal(allocator, &state);

    const registered = state.findTrial("trial-null-001") orelse return error.TrialMissing;
    try std.testing.expect(registered.revealed);
    try std.testing.expectEqual(@as(usize, 2), registered.lanes.items.len);
    for (registered.lanes.items) |lane| {
        try std.testing.expectEqual(hctp.LaneTerminal.completed, lane.status);
        try std.testing.expect(lane.absolute_graded);
        try std.testing.expect(lane.run_receipt_fingerprint != null);
    }
    try std.testing.expect(registered.pairs.items[0].pair_graded);
    const result = try hctp_fold.resultAlloc(allocator, "cmp-test", start_a1.start_digest, &state, registered, .{});
    var result_parsed = try parseJson(allocator, result);
    defer result_parsed.deinit();
    const claims = try requiredObject(try object(result_parsed.value), "claims");
    try std.testing.expectEqualStrings("supported", try requiredString(claims, "absolute_qualification"));
    const result_again = try hctp_fold.resultAlloc(allocator, "cmp-test", start_a1.start_digest, &state, registered, .{});
    try std.testing.expectEqualStrings(result, result_again);
    const proof_fingerprint = try hctp.digestValueAlloc(allocator, result_parsed.value);
    try hctp.validateFingerprint(proof_fingerprint);
}

test "HCTP end-to-end: CAS executor failure remains one account-able terminal receipt" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const binaries = try integrationPaths(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const executor = binaries.seq;
    const native_campaign = try setupNativeCampaign(allocator, root, binaries.ledger, executor, binaries.cas);
    const source_owned = try bindProofSourceOwnerAlloc(allocator, fixtures.valid_null_trial, executor, binaries.cas, binaries.ledger);
    const factor_bound = try bindNullFactorMaterializationAlloc(allocator, root, source_owned);
    const trial = try bindRunnerContractAlloc(allocator, factor_bound, executor, binaries.cas, binaries.ledger);
    const registration = try registerNativeTrial(allocator, root, binaries.ledger, trial);

    var state: hctp.CampaignTrials = .{};
    defer state.deinit(allocator);
    try registerTrial(allocator, &state, trial, registration.event_digest);
    const native_start = try startNativeLane(allocator, root, binaries.ledger, "trial-null-001", "lane-null-a0");
    try startLane(
        allocator,
        &state,
        "lane-null-a0",
        native_start.lease_digest,
        native_campaign.scenario_fingerprint,
        2,
        native_start.start_digest,
    );
    const receipt = try runCasLane(
        allocator,
        binaries.cas,
        executor,
        root,
        registration.trial_path,
        "lane-null-a0",
        native_start.lease_path,
        native_campaign.scenario_path,
        native_campaign.scenario_fingerprint,
        registration.event_digest,
        native_start.start_digest,
    );
    try finishNativeLane(allocator, root, binaries.ledger, "trial-null-001", "lane-null-a0", native_start.lease_path);
    try finishLane(allocator, &state, "lane-null-a0", receipt, 3);

    const registered = state.findTrial("trial-null-001") orelse return error.TrialMissing;
    const lane = registered.findLane("lane-null-a0") orelse return error.LaneMissing;
    try std.testing.expectEqual(hctp.LaneTerminal.failed, lane.status);
    try std.testing.expect(lane.run_receipt_fingerprint != null);
    try std.testing.expect(!lane.absolute_graded);
    var parsed = try parseJson(allocator, receipt);
    defer parsed.deinit();
    const root_receipt = try object(parsed.value);
    const terminal = try requiredObject(root_receipt, "terminal");
    try std.testing.expectEqualStrings("failed", try requiredString(terminal, "status"));
    try std.testing.expectEqualStrings("executor_exit_nonzero", try requiredString(terminal, "failure_class"));
    try std.testing.expect((try requiredArray(try requiredObject(root_receipt, "effects"), "policy_violations")).items.len == 1);
}

test "HCTP end-to-end: historical executor failure terminalizes once without FIR or comparison" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const binaries = try integrationPaths(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const executor = binaries.seq;
    const native_campaign = try setupNativeCampaign(allocator, root, binaries.ledger, executor, binaries.cas);
    const source_owned = try bindProofSourceOwnerAlloc(
        allocator,
        fixtures.valid_null_trial,
        executor,
        binaries.cas,
        binaries.ledger,
    );
    const factor_bound = try bindNullFactorMaterializationAlloc(allocator, root, source_owned);
    const direct = try bindRunnerContractAlloc(
        allocator,
        factor_bound,
        executor,
        binaries.cas,
        binaries.ledger,
    );
    const trial = try historicalTrialAlloc(allocator, direct);
    const registration = try registerNativeTrial(allocator, root, binaries.ledger, trial);

    var state: hctp.CampaignTrials = .{};
    defer state.deinit(allocator);
    try registerTrial(allocator, &state, trial, registration.event_digest);
    const native_start = try startNativeLane(
        allocator,
        root,
        binaries.ledger,
        "trial-null-001",
        "lane-null-a0",
    );
    try startLane(
        allocator,
        &state,
        "lane-null-a0",
        native_start.lease_digest,
        native_campaign.scenario_fingerprint,
        2,
        native_start.start_digest,
    );
    const receipt = try runCasLane(
        allocator,
        binaries.cas,
        executor,
        root,
        registration.trial_path,
        "lane-null-a0",
        native_start.lease_path,
        native_campaign.scenario_path,
        native_campaign.scenario_fingerprint,
        registration.event_digest,
        native_start.start_digest,
    );
    var receipt_parsed = try parseJson(allocator, receipt);
    defer receipt_parsed.deinit();
    const receipt_root = try object(receipt_parsed.value);
    const terminal = try requiredObject(receipt_root, "terminal");
    try std.testing.expectEqualStrings("failed", try requiredString(terminal, "status"));
    try std.testing.expectEqualStrings("executor_exit_nonzero", try requiredString(terminal, "failure_class"));
    try std.testing.expect((try required(receipt_root, "attestation")) == .null);
    const native = try requiredObject(receipt_root, "native_receipt");
    try std.testing.expectEqualStrings("cas-historical-terminal-receipt", try requiredString(native, "kind"));
    const native_receipt = try requiredObject(native, "receipt");
    try std.testing.expectEqualStrings(
        "cas-historical-terminal-receipt/v1",
        try requiredString(native_receipt, "schema"),
    );
    const execution = try requiredObject(native_receipt, "execution");
    try std.testing.expectEqual(@as(i64, 1), switch (try required(execution, "handle_count")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    });
    try std.testing.expectEqual(@as(i64, 0), switch (try required(execution, "retry_count")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    });
    const fir = try requiredObject(native_receipt, "fir");
    try std.testing.expectEqualStrings("unavailable", try requiredString(fir, "status"));
    try std.testing.expectEqualStrings("executor_exit_nonzero", try requiredString(fir, "reason"));

    try finishNativeLane(
        allocator,
        root,
        binaries.ledger,
        "trial-null-001",
        "lane-null-a0",
        native_start.lease_path,
    );
    try finishLane(allocator, &state, "lane-null-a0", receipt, 3);
    const registered = state.findTrial("trial-null-001") orelse return error.TrialMissing;
    const lane = registered.findLane("lane-null-a0") orelse return error.LaneMissing;
    try std.testing.expectEqual(hctp.LaneTerminal.failed, lane.status);
    try std.testing.expect(!lane.absolute_graded);
    try std.testing.expect(!registered.pairs.items[0].pair_graded);

    try std.testing.expectError(
        error.IntegrationCommandFailed,
        finishNativeLane(
            allocator,
            root,
            binaries.ledger,
            "trial-null-001",
            "lane-null-a0",
            native_start.lease_path,
        ),
    );
    try std.testing.expectError(
        error.CasTrialFailed,
        runCasLane(
            allocator,
            binaries.cas,
            executor,
            root,
            registration.trial_path,
            "lane-null-a0",
            native_start.lease_path,
            native_campaign.scenario_path,
            native_campaign.scenario_fingerprint,
            registration.event_digest,
            native_start.start_digest,
        ),
    );

    const native_result = try sealedTrialResultAlloc(
        allocator,
        root,
        binaries.ledger,
        "trial-null-001",
    );
    var native_result_parsed = try parseJson(allocator, native_result);
    defer native_result_parsed.deinit();
    const completeness = try requiredObject(try object(native_result_parsed.value), "completeness");
    try std.testing.expectEqual(@as(i64, 1), switch (try required(completeness, "lanes_terminal")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    });
    try std.testing.expectEqual(@as(i64, 1), switch (try required(completeness, "lanes_failed")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    });
}

test "HCTP end-to-end: one historical Hylo lane normalizes one FIR and rejects outcome leakage" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const binaries = try integrationPaths(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const native_campaign = try setupNativeCampaign(allocator, root, binaries.ledger, binaries.executor, binaries.cas);
    const source_owned = try bindProofSourceOwnerAlloc(allocator, fixtures.valid_null_trial, binaries.executor, binaries.cas, binaries.ledger);
    const factor_bound = try bindNullFactorMaterializationAlloc(allocator, root, source_owned);
    const direct = try bindRunnerContractAlloc(allocator, factor_bound, binaries.executor, binaries.cas, binaries.ledger);
    const trial = try historicalTrialAlloc(allocator, direct);
    const registration = try registerNativeTrial(allocator, root, binaries.ledger, trial);

    var state: hctp.CampaignTrials = .{};
    defer state.deinit(allocator);
    try registerTrial(allocator, &state, trial, registration.event_digest);
    const native_start = try startNativeLane(allocator, root, binaries.ledger, "trial-null-001", "lane-null-a0");
    try startLane(allocator, &state, "lane-null-a0", native_start.lease_digest, native_campaign.scenario_fingerprint, 2, native_start.start_digest);
    const receipt = try runCasLane(allocator, binaries.cas, binaries.executor, root, registration.trial_path, "lane-null-a0", native_start.lease_path, native_campaign.scenario_path, native_campaign.scenario_fingerprint, registration.event_digest, native_start.start_digest);
    try finishNativeLane(allocator, root, binaries.ledger, "trial-null-001", "lane-null-a0", native_start.lease_path);
    try finishLane(allocator, &state, "lane-null-a0", receipt, 3);

    var parsed = try parseJson(allocator, receipt);
    defer parsed.deinit();
    const receipt_root = try object(parsed.value);
    const terminal = try requiredObject(receipt_root, "terminal");
    if (!std.mem.eql(u8, try requiredString(terminal, "status"), "completed")) {
        const detail = try durable_store.readFileAlloc(allocator, try requiredString(terminal, "failure_detail_ref"), MaxBytes);
        std.debug.print("historical runner failure: {s}\n", .{detail});
    }
    const native = try requiredObject(receipt_root, "native_receipt");
    try std.testing.expectEqualStrings("FIR-v1", try requiredString(native, "kind"));
    try std.testing.expect(native.get("forks") == null);
    try std.testing.expect(native.get("portfolio") == null);
    const fir_value = try required(native, "receipt");
    const fir_root = try requiredObject(try object(fir_value), "fork_inquiry_receipt");
    const fir_source = try requiredObject(fir_root, "source");
    try std.testing.expectEqualStrings(
        "session:integration#turn:turn-two",
        try requiredString(fir_source, "source_episode_id"),
    );
    var fir = try retrace_core.hctp_adapter.validateFirForLane(
        allocator,
        fir_value,
        "lane-null-a0",
        "either",
        AnchorDigest,
    );
    defer fir.deinit(allocator);
    try std.testing.expectEqualStrings("lane-null-a0", fir.lane_id);

    const profile_json = try historicalProfileAlloc(allocator);
    defer allocator.free(profile_json);
    var profile_parsed = try parseJson(allocator, profile_json);
    defer profile_parsed.deinit();
    var profile_report = try retrace_core.hctp_adapter.validateHistoricalProfile(
        allocator,
        profile_parsed.value,
        true,
    );
    defer profile_report.deinit(allocator);
    var joined_fir = try retrace_core.hctp_adapter.validateFirForHistoricalLane(
        allocator,
        fir_value,
        &profile_report,
        "trial-null-001",
        "lane-null-a0",
        "either",
    );
    defer joined_fir.deinit(allocator);
    try std.testing.expect(joined_fir.episode_identity_fingerprint != null);

    const fir_canonical = try hctp.canonicalJsonAlloc(allocator, fir_value);
    const wrong_episode = try replaceExactAlloc(
        allocator,
        fir_canonical,
        "session:integration#turn:turn-two",
        "session:integration#turn:wrong",
    );
    var wrong_episode_parsed = try parseJson(allocator, wrong_episode);
    defer wrong_episode_parsed.deinit();
    try std.testing.expectError(
        error.FirSourceEpisodeMismatch,
        retrace_core.hctp_adapter.validateFirForHistoricalLane(
            allocator,
            wrong_episode_parsed.value,
            &profile_report,
            "trial-null-001",
            "lane-null-a0",
            "either",
        ),
    );
    const leaked = try replaceExactAlloc(allocator, fir_canonical, "\"hindsight_available\":false", "\"hindsight_available\":true");
    var leaked_parsed = try parseJson(allocator, leaked);
    defer leaked_parsed.deinit();
    try std.testing.expectError(
        error.OutcomeAwareDecisionContext,
        retrace_core.hctp_adapter.validateFirForLane(
            allocator,
            leaked_parsed.value,
            "lane-null-a0",
            "either",
            AnchorDigest,
        ),
    );
}

test "HCTP end-to-end: actual Ledger CLI reproduces a completed CAS trial result from its verified proof" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const binaries = try integrationPaths(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);

    const git_init = try std.fmt.allocPrint(allocator, "git init -q '{s}'", .{root});
    _ = try runIsolatedCommandAlloc(allocator, root, "git-init", git_init);
    const exclude_path = try std.fs.path.join(allocator, &.{ root, ".git", "info", "exclude" });
    try durable_store.writeTextAtomic(allocator, exclude_path, ".ledger/\n");

    var scenario_parsed = try parseJson(allocator, DirectScenario);
    defer scenario_parsed.deinit();
    const scenario_fingerprint = try hctp.digestValueAlloc(allocator, scenario_parsed.value);
    const scenario = try hctp.canonicalJsonAlloc(allocator, scenario_parsed.value);
    const scenario_path = try std.fs.path.join(allocator, &.{ root, "scenario.json" });
    try durable_store.writeTextAtomic(allocator, scenario_path, scenario);
    const campaign = try campaignAlloc(allocator, scenario_fingerprint, binaries.executor, binaries.cas, binaries.ledger);
    const campaign_intent = try artifactIntentAlloc(allocator, "campaign_created", "campaign", campaign, null);
    const scenario_intent = try artifactIntentAlloc(allocator, "scenario_admitted", "scenario", scenario, "scenario-holdout");
    const campaign_intent_path = try std.fs.path.join(allocator, &.{ root, "campaign-intent.json" });
    const scenario_intent_path = try std.fs.path.join(allocator, &.{ root, "scenario-intent.json" });
    try durable_store.writeTextAtomic(allocator, campaign_intent_path, campaign_intent);
    try durable_store.writeTextAtomic(allocator, scenario_intent_path, scenario_intent);

    const append_campaign = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo append --repo '{s}' --json '{s}'",
        .{ binaries.ledger, root, campaign_intent_path },
    );
    _ = try runIsolatedCommandAlloc(allocator, root, "ledger-append-campaign", append_campaign);
    const append_scenario = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo append --repo '{s}' --json '{s}'",
        .{ binaries.ledger, root, scenario_intent_path },
    );
    _ = try runIsolatedCommandAlloc(allocator, root, "ledger-append-scenario", append_scenario);

    const source_owned_trial = try bindProofSourceOwnerAlloc(allocator, fixtures.valid_null_trial, binaries.executor, binaries.cas, binaries.ledger);
    const factor_bound_trial = try bindNullFactorMaterializationAlloc(allocator, root, source_owned_trial);
    const trial = try bindRunnerContractAlloc(allocator, factor_bound_trial, binaries.executor, binaries.cas, binaries.ledger);
    const trial_path = try std.fs.path.join(allocator, &.{ root, "trial.json" });
    try durable_store.writeTextAtomic(allocator, trial_path, trial);
    const register_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo register-trial --repo '{s}' --trial '{s}'",
        .{ binaries.ledger, root, trial_path },
    );
    const registration_stdout = try runIsolatedCommandAlloc(allocator, root, "ledger-register-trial", register_command);
    const registration_digest = try commandEventDigest(allocator, registration_stdout, "event_digest");

    inline for (.{
        .{ "lane-null-a0", "arm-0", "a0" },
        .{ "lane-null-a1", "arm-1", "a1" },
    }, 0..) |lane_spec, lane_index| {
        const lane_id = lane_spec[0];
        const arm_id = lane_spec[1];
        const label = lane_spec[2];
        const lease_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ledger.lease", .{ root, lane_id });
        const start_command = try std.fmt.allocPrint(
            allocator,
            "set -o pipefail; rm -f '{s}'; exec 4>&1; '{s}' --source hylo start-lane --repo '{s}' --campaign-id cmp-test --trial-id trial-null-001 --lane-id '{s}' --runner-id cas-trial --lease-output-fd 3 3>&1 1>&4 | (umask 077; cat >'{s}')",
            .{ lease_path, binaries.ledger, root, lane_id, lease_path },
        );
        const start_label = try std.fmt.allocPrint(allocator, "ledger-start-{s}", .{label});
        const start_stdout = try runIsolatedCommandAlloc(allocator, root, start_label, start_command);
        const start_digest = try commandEventDigest(allocator, start_stdout, "start_event_digest");
        const delivered_lease = try durable_store.readRegularFileNoSymlink(allocator, lease_path, MaxBytes);
        defer std.crypto.secureZero(u8, delivered_lease);
        const canonical_lease = std.mem.trim(u8, delivered_lease, " \t\r\n");
        if (canonical_lease.len != "HYL1-".len + 64) return error.LaneLeaseInvalid;
        try durable_store.writeTextAtomic(allocator, lease_path, canonical_lease);
        const receipt = try runCasLane(
            allocator,
            binaries.cas,
            binaries.executor,
            root,
            trial_path,
            lane_id,
            lease_path,
            scenario_path,
            scenario_fingerprint,
            registration_digest,
            start_digest,
        );
        var receipt_parsed = try parseJson(allocator, receipt);
        defer receipt_parsed.deinit();
        const run_fingerprint = try hctp.digestValueAlloc(allocator, receipt_parsed.value);
        const receipt_path = try std.fs.path.join(allocator, &.{ root, "receipts", "trial-null-001", lane_id, "run-receipt.json" });
        const finish_command = try std.fmt.allocPrint(
            allocator,
            "cat '{s}' | (exec 3<&0; exec 0</dev/null; exec '{s}' --source hylo finish-lane --repo '{s}' --receipt '{s}' --lease-input-fd 3)",
            .{ lease_path, binaries.ledger, root, receipt_path },
        );
        const finish_label = try std.fmt.allocPrint(allocator, "ledger-finish-{s}", .{label});
        _ = try runIsolatedCommandAlloc(allocator, root, finish_label, finish_command);

        const grade = try gradeReceiptAlloc(allocator, lane_id, arm_id, run_fingerprint);
        const grade_path = try std.fmt.allocPrint(allocator, "{s}/{s}.grade.json", .{ root, lane_id });
        try durable_store.writeTextAtomic(allocator, grade_path, grade);
        const grade_command = try std.fmt.allocPrint(
            allocator,
            "'{s}' --source hylo grade-lane --repo '{s}' --receipt '{s}'",
            .{ binaries.ledger, root, grade_path },
        );
        const grade_label = try std.fmt.allocPrint(allocator, "ledger-grade-{s}", .{label});
        _ = try runIsolatedCommandAlloc(allocator, root, grade_label, grade_command);
        _ = lane_index;
    }

    const pair_grade_path = try std.fs.path.join(allocator, &.{ root, "pair-grade.json" });
    const pair_outputs = try std.mem.replaceOwned(
        u8,
        allocator,
        fixtures.valid_pair_grade_receipt,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab",
        "sha256:e8a8d14cae81e2faf1c0afccc2db54fdbbd1f53c23a42ec0fb62aa12e813170d",
    );
    const pair_grade = try replaceExactAlloc(
        allocator,
        pair_outputs,
        "sha256:8cabd2cbd17f12e545a8f013b3f007251d1676beea8f47cb3321004974d33af8",
        "sha256:84bc8162fa2bafa3e4621d2235d8b4e244226d767b7b7d9e75fd399a9585be7c",
    );
    try durable_store.writeTextAtomic(allocator, pair_grade_path, pair_grade);
    const pair_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo grade-pair --repo '{s}' --receipt '{s}'",
        .{ binaries.ledger, root, pair_grade_path },
    );
    _ = try runIsolatedCommandAlloc(allocator, root, "ledger-grade-pair", pair_command);
    const reveal_path = try std.fs.path.join(allocator, &.{ root, "reveal.json" });
    try durable_store.writeTextAtomic(allocator, reveal_path, fixtures.valid_reveal);
    const reveal_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo reveal-trial --repo '{s}' --reveal '{s}'",
        .{ binaries.ledger, root, reveal_path },
    );
    _ = try runIsolatedCommandAlloc(allocator, root, "ledger-reveal", reveal_command);
    const close_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo close-trial --repo '{s}' --trial-id trial-null-001 --status completed --reason 'fixed cohort completed'",
        .{ binaries.ledger, root },
    );
    _ = try runIsolatedCommandAlloc(allocator, root, "ledger-close", close_command);

    const result_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo trial-result --repo '{s}' --trial-id trial-null-001 --format json",
        .{ binaries.ledger, root },
    );
    const live_result = try runIsolatedCommandAlloc(allocator, root, "ledger-result", result_command);
    const live_fingerprint = try resultFingerprintAlloc(allocator, live_result);
    const artifact_set_path = try std.fs.path.join(allocator, &.{ root, "proof-artifact-set.json" });
    const artifact_set_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo proof-artifact-set --repo '{s}' --trial-id trial-null-001 --output '{s}'",
        .{ binaries.ledger, root, artifact_set_path },
    );
    _ = try runIsolatedCommandAlloc(allocator, root, "ledger-proof-artifact-set", artifact_set_command);
    const artifact_set = try durable_store.readFileAlloc(allocator, artifact_set_path, MaxBytes);
    const sanitization_receipt = try proofSanitizationReceiptAlloc(allocator, artifact_set);
    const sanitization_receipt_path = try std.fs.path.join(allocator, &.{ root, "proof-sanitization-receipt.json" });
    try durable_store.writeTextAtomic(allocator, sanitization_receipt_path, sanitization_receipt);
    const proof_path = try std.fs.path.join(allocator, &.{ root, "proof.tar" });
    const export_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo export-proof --repo '{s}' --trial-id trial-null-001 --output '{s}' --sanitization-receipt '{s}'",
        .{ binaries.ledger, root, proof_path, sanitization_receipt_path },
    );
    _ = try runIsolatedCommandAlloc(allocator, root, "ledger-export-proof", export_command);
    const verify_command = try std.fmt.allocPrint(
        allocator,
        "'{s}' --source hylo verify-proof --repo '{s}' --input '{s}'",
        .{ binaries.ledger, root, proof_path },
    );
    const verification = try runIsolatedCommandAlloc(allocator, root, "ledger-verify-proof", verify_command);
    try std.testing.expect(std.mem.indexOf(u8, verification, "\"status\":\"valid\"") != null);

    const extract_command = try std.fmt.allocPrint(
        allocator,
        "/usr/bin/tar -xOf '{s}' trial/result.json",
        .{proof_path},
    );
    const bundled_result = try runIsolatedCommandAlloc(allocator, root, "proof-extract-result", extract_command);
    const bundled_fingerprint = try resultFingerprintAlloc(allocator, bundled_result);
    try std.testing.expectEqualStrings(live_fingerprint, bundled_fingerprint);
    var live_parsed = try parseJson(allocator, live_result);
    defer live_parsed.deinit();
    var bundled_parsed = try parseJson(allocator, bundled_result);
    defer bundled_parsed.deinit();
    const live_canonical = try hctp.canonicalJsonAlloc(allocator, live_parsed.value);
    const bundled_canonical = try hctp.canonicalJsonAlloc(allocator, bundled_parsed.value);
    try std.testing.expectEqualStrings(live_canonical, bundled_canonical);
}

fn factorRunnerTrialAlloc(
    allocator: std.mem.Allocator,
    base_trial: []const u8,
    trial_id: []const u8,
    lane_left: []const u8,
    lane_right: []const u8,
    left_ref: []const u8,
    left_fingerprint: []const u8,
    right_ref: []const u8,
    right_fingerprint: []const u8,
) ![]u8 {
    var parsed = try parseJson(allocator, base_trial);
    defer parsed.deinit();
    const tree_allocator = parsed.arena.allocator();
    const root = try objectPtr(&parsed.value);
    try root.put(tree_allocator, "trial_id", .{ .string = try tree_allocator.dupe(u8, trial_id) });
    try root.put(tree_allocator, "purpose", .{ .string = try tree_allocator.dupe(u8, "calibration_positive") });
    const hypothesis_value = root.getPtr("hypothesis") orelse return error.RequiredFieldMissing;
    const hypothesis = try objectPtr(hypothesis_value);
    try hypothesis.put(tree_allocator, "predicted_direction", .{ .string = try tree_allocator.dupe(u8, "candidate_better") });
    const arms_value = root.getPtr("arms") orelse return error.RequiredFieldMissing;
    const arms = try arrayPtr(arms_value);
    if (arms.items.len != 2) return error.FixtureShapeChanged;
    const left = try objectPtr(&arms.items[0]);
    try left.put(tree_allocator, "value_fingerprint", .{ .string = try tree_allocator.dupe(u8, left_fingerprint) });
    try left.put(tree_allocator, "materialization_ref", .{ .string = try tree_allocator.dupe(u8, left_ref) });
    try left.put(tree_allocator, "materialization_fingerprint", .{ .string = try tree_allocator.dupe(u8, left_fingerprint) });
    const right = try objectPtr(&arms.items[1]);
    try right.put(tree_allocator, "value_fingerprint", .{ .string = try tree_allocator.dupe(u8, right_fingerprint) });
    try right.put(tree_allocator, "materialization_ref", .{ .string = try tree_allocator.dupe(u8, right_ref) });
    try right.put(tree_allocator, "materialization_fingerprint", .{ .string = try tree_allocator.dupe(u8, right_fingerprint) });
    const common_projection_fingerprint = try digestBytesAlloc(
        allocator,
        "{\"instruction\":{\"$hylo_omitted_factor\":true},\"required\":{\"$hylo_omitted_factor\":true}}",
    );
    defer allocator.free(common_projection_fingerprint);

    const witness_text = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-intervention-witness/v1\",\"trial_id\":{f},\"factor_kind\":\"instruction_bundle\",\"arm_values\":{{\"arm-0\":{{\"fingerprint\":{f},\"snapshot_fingerprint\":{f}}},\"arm-1\":{{\"fingerprint\":{f},\"snapshot_fingerprint\":{f}}}}},\"common_projection\":{{\"fingerprint\":{f},\"compared_fields\":[\"all-except-declared-factor\"]}},\"differing_projection\":{{\"allowed_roots\":[\"/instruction\",\"/required\"],\"observed_paths\":[\"/instruction\",\"/required\"],\"diff_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\"}},\"verifier\":{{\"id\":\"canonical-projection\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:3333333333333333333333333333333333333333333333333333333333333333\"}},\"verdict\":{{\"one_factor_closed\":true}},\"limitations\":[]}}",
        .{ std.json.fmt(trial_id, .{}), std.json.fmt(left_fingerprint, .{}), std.json.fmt(left_fingerprint, .{}), std.json.fmt(right_fingerprint, .{}), std.json.fmt(right_fingerprint, .{}), std.json.fmt(common_projection_fingerprint, .{}) },
    );
    defer allocator.free(witness_text);
    var witness_parsed = try parseJson(allocator, witness_text);
    defer witness_parsed.deinit();
    const witness_fingerprint = try hctp.digestValueAlloc(allocator, witness_parsed.value);
    defer allocator.free(witness_fingerprint);
    const factor_text = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"instruction_bundle\",\"verifier\":{{\"id\":\"canonical-projection\",\"version\":\"v1\",\"fingerprint\":\"sha256:3333333333333333333333333333333333333333333333333333333333333333\"}},\"common_projection_fingerprint\":{f},\"allowed_difference_roots\":[\"/instruction\",\"/required\"],\"intervention_witness_ref\":\"artifact:instruction-intervention\",\"intervention_witness_fingerprint\":{f},\"intervention_witness\":{s}}}",
        .{ std.json.fmt(common_projection_fingerprint, .{}), std.json.fmt(witness_fingerprint, .{}), witness_text },
    );
    defer allocator.free(factor_text);
    const factor_value = try std.json.parseFromSliceLeaky(std.json.Value, tree_allocator, factor_text, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    try root.put(tree_allocator, "factor", factor_value);

    const units_value = root.getPtr("units") orelse return error.RequiredFieldMissing;
    const units = try arrayPtr(units_value);
    const unit = try objectPtr(&units.items[0]);
    const pairs_value = unit.getPtr("pairs") orelse return error.RequiredFieldMissing;
    const pairs = try arrayPtr(pairs_value);
    const pair = try objectPtr(&pairs.items[0]);
    const lanes_value = pair.getPtr("lanes") orelse return error.RequiredFieldMissing;
    const lanes = try objectPtr(lanes_value);
    const left_lane_value = lanes.getPtr("arm-0") orelse return error.RequiredFieldMissing;
    try (try objectPtr(left_lane_value)).put(tree_allocator, "lane_id", .{ .string = try tree_allocator.dupe(u8, lane_left) });
    const right_lane_value = lanes.getPtr("arm-1") orelse return error.RequiredFieldMissing;
    try (try objectPtr(right_lane_value)).put(tree_allocator, "lane_id", .{ .string = try tree_allocator.dupe(u8, lane_right) });
    return jsonAlloc(allocator, parsed.value);
}

fn runFactorMaterializationCase(
    allocator: std.mem.Allocator,
    root: []const u8,
    native_campaign: NativeCampaignSetup,
    case_id: []const u8,
    left_ref: []const u8,
    left_fingerprint: []const u8,
    right_ref: []const u8,
    right_fingerprint: []const u8,
    input: []const u8,
) ![]u8 {
    _ = input;
    const pid = std.c.getpid();
    const trial_id = try std.fmt.allocPrint(allocator, "trial-factor-{d}-{s}", .{ pid, case_id });
    defer allocator.free(trial_id);
    const lane_left = try std.fmt.allocPrint(allocator, "lane-x-{d}-{s}", .{ pid, case_id });
    defer allocator.free(lane_left);
    const lane_right = try std.fmt.allocPrint(allocator, "lane-y-{d}-{s}", .{ pid, case_id });
    defer allocator.free(lane_right);
    const source_owned = try bindProofSourceOwnerAlloc(
        allocator,
        fixtures.valid_null_trial,
        integration_paths.fixture_executor_path,
        integration_paths.cas_trial_path,
        integration_paths.ledger_path,
    );
    defer allocator.free(source_owned);
    const contract_bound = try bindRunnerContractAlloc(
        allocator,
        source_owned,
        integration_paths.fixture_executor_path,
        integration_paths.cas_trial_path,
        integration_paths.ledger_path,
    );
    defer allocator.free(contract_bound);
    const trial = try factorRunnerTrialAlloc(
        allocator,
        contract_bound,
        trial_id,
        lane_left,
        lane_right,
        left_ref,
        left_fingerprint,
        right_ref,
        right_fingerprint,
    );
    defer allocator.free(trial);
    var validation = try hctp.validateTrialAlloc(allocator, trial);
    validation.deinit(allocator);
    inline for (.{ left_ref, right_ref }, 0..) |ref, index| {
        const object_id = ref["git-blob-json:".len..];
        const command = try std.fmt.allocPrint(allocator, "git -C '{s}' cat-file -t '{s}'", .{ root, object_id });
        defer allocator.free(command);
        const label = try std.fmt.allocPrint(allocator, "factor-object-{d}", .{index});
        defer allocator.free(label);
        const output = try runIsolatedCommandAlloc(allocator, root, label, command);
        defer allocator.free(output);
        try std.testing.expectEqualStrings("blob", std.mem.trim(u8, output, " \t\r\n"));
    }
    const registration = try registerNativeTrial(allocator, root, integration_paths.ledger_path, trial);
    defer allocator.free(registration.trial_path);
    defer allocator.free(registration.event_digest);
    const start = try startNativeLane(allocator, root, integration_paths.ledger_path, trial_id, lane_left);
    defer allocator.free(start.lease_path);
    defer allocator.free(start.lease_digest);
    defer allocator.free(start.start_digest);
    const receipt = try runCasLane(
        allocator,
        integration_paths.cas_trial_path,
        integration_paths.fixture_executor_path,
        root,
        registration.trial_path,
        lane_left,
        start.lease_path,
        native_campaign.scenario_path,
        native_campaign.scenario_fingerprint,
        registration.event_digest,
        start.start_digest,
    );
    try finishNativeLane(allocator, root, integration_paths.ledger_path, trial_id, lane_left, start.lease_path);
    return receipt;
}

test "HCTP CAS factor materialization: positive sentinel binds immutable canonical blobs and rejects mutation or observed-ref tampering" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const init_command = try std.fmt.allocPrint(allocator, "git -C '{s}' init -q", .{root});
    defer allocator.free(init_command);
    const init_stdout = try runIsolatedCommandAlloc(allocator, root, "factor-git-init", init_command);
    defer allocator.free(init_stdout);
    const native_campaign = try setupNativeCampaign(
        allocator,
        root,
        integration_paths.ledger_path,
        integration_paths.fixture_executor_path,
        integration_paths.cas_trial_path,
    );
    defer allocator.free(native_campaign.scenario_path);
    defer allocator.free(native_campaign.scenario_fingerprint);
    const left_bytes = "{\"instruction\":\"known-defect\",\"required\":false}\n";
    const right_bytes = "{\"instruction\":\"known-control\",\"required\":true}\n";
    const left_path = try std.fs.path.join(allocator, &.{ root, "factor-left.json" });
    defer allocator.free(left_path);
    const right_path = try std.fs.path.join(allocator, &.{ root, "factor-right.json" });
    defer allocator.free(right_path);
    try durable_store.writeTextAtomic(allocator, left_path, left_bytes);
    try durable_store.writeTextAtomic(allocator, right_path, right_bytes);
    const left_oid_command = try std.fmt.allocPrint(
        allocator,
        "git -C '{s}' hash-object -w -- factor-left.json",
        .{root},
    );
    defer allocator.free(left_oid_command);
    const left_oid_raw = try runIsolatedCommandAlloc(allocator, root, "factor-left-oid", left_oid_command);
    defer allocator.free(left_oid_raw);
    const right_oid_command = try std.fmt.allocPrint(
        allocator,
        "git -C '{s}' hash-object -w -- factor-right.json",
        .{root},
    );
    defer allocator.free(right_oid_command);
    const right_oid_raw = try runIsolatedCommandAlloc(allocator, root, "factor-right-oid", right_oid_command);
    defer allocator.free(right_oid_raw);
    const left_ref = try std.fmt.allocPrint(allocator, "git-blob-json:{s}", .{std.mem.trim(u8, left_oid_raw, " \t\r\n")});
    defer allocator.free(left_ref);
    const right_ref = try std.fmt.allocPrint(allocator, "git-blob-json:{s}", .{std.mem.trim(u8, right_oid_raw, " \t\r\n")});
    defer allocator.free(right_ref);
    var left_parsed = try parseJson(allocator, left_bytes);
    defer left_parsed.deinit();
    const left_fingerprint = try hctp.digestValueAlloc(allocator, left_parsed.value);
    defer allocator.free(left_fingerprint);
    var right_parsed = try parseJson(allocator, right_bytes);
    defer right_parsed.deinit();
    const right_fingerprint = try hctp.digestValueAlloc(allocator, right_parsed.value);
    defer allocator.free(right_fingerprint);

    const good = try runFactorMaterializationCase(
        allocator,
        root,
        native_campaign,
        "good",
        left_ref,
        left_fingerprint,
        right_ref,
        right_fingerprint,
        "{\"request\":\"positive-sentinel\"}",
    );
    defer allocator.free(good);
    var good_parsed = try parseJson(allocator, good);
    defer good_parsed.deinit();
    const good_root = try object(good_parsed.value);
    const good_terminal = try requiredObject(good_root, "terminal");
    const good_status = try requiredString(good_terminal, "status");
    if (!std.mem.eql(u8, good_status, "completed")) {
        const failure_ref = try requiredString(good_terminal, "failure_detail_ref");
        const failure_bytes = try durable_store.readFileAlloc(allocator, failure_ref, MaxBytes);
        defer allocator.free(failure_bytes);
        std.debug.print("factor materialization good lane failed:\n{s}\n", .{failure_bytes});
    }
    try std.testing.expectEqualStrings("completed", good_status);
    const materialization = try requiredObject(good_root, "materialization");
    try std.testing.expectEqualStrings(left_ref, try requiredString(materialization, "factor_materialization_ref"));
    try std.testing.expectEqualStrings(left_fingerprint, try requiredString(materialization, "factor_materialization_fingerprint"));
    try std.testing.expectEqualStrings(left_fingerprint, try requiredString(materialization, "factor_materialization_archive_fingerprint"));
    const archive_ref = try requiredString(materialization, "factor_materialization_archive_ref");
    const archive_fingerprint = try fileFingerprintAlloc(allocator, archive_ref);
    defer allocator.free(archive_fingerprint);
    try std.testing.expectEqualStrings(left_fingerprint, archive_fingerprint);

    inline for (.{
        .{ "observation", "{\"tamper_factor_observation\":true}", "FactorMaterializationObservationMismatch" },
        .{ "mutation", "{\"mutate_factor_archive\":true}", "ArchivedEvidenceFingerprintMismatch" },
    }) |case| {
        const receipt = try runFactorMaterializationCase(
            allocator,
            root,
            native_campaign,
            case[0],
            left_ref,
            left_fingerprint,
            right_ref,
            right_fingerprint,
            case[1],
        );
        defer allocator.free(receipt);
        var parsed = try parseJson(allocator, receipt);
        defer parsed.deinit();
        const receipt_root = try object(parsed.value);
        try std.testing.expectEqualStrings("invalid", try requiredString(try requiredObject(receipt_root, "terminal"), "status"));
        const failure_ref = try requiredString(try requiredObject(receipt_root, "terminal"), "failure_detail_ref");
        const failure_bytes = try durable_store.readFileAlloc(allocator, failure_ref, MaxBytes);
        defer allocator.free(failure_bytes);
        try std.testing.expect(std.mem.indexOf(u8, failure_bytes, case[2]) != null);
    }
}
