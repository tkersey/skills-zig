const std = @import("std");
const cas_session_inquiry = @import("cas_session_inquiry");
const durable_store = @import("durable_store");

const MaxBytes = 96 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 5 or
        !std.mem.eql(u8, argv[1], "--request") or
        !std.mem.eql(u8, argv[3], "--result"))
    {
        return error.InvalidArguments;
    }

    const request_bytes = try durable_store.readFileAlloc(allocator, argv[2], MaxBytes);
    defer allocator.free(request_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const request = try object(parsed.value);
    const workspace = try requiredString(request, "workspace");
    const executable_fingerprint = try fileFingerprintAlloc(allocator, argv[0]);
    defer allocator.free(executable_fingerprint);
    const presented_input = try durable_store.readFileAlloc(
        allocator,
        try requiredString(request, "presented_input_ref"),
        MaxBytes,
    );
    defer allocator.free(presented_input);
    const lane_id = try requiredString(request, "lane_id");
    const tamper_factor_observation = std.mem.indexOf(u8, presented_input, "\"tamper_factor_observation\":true") != null or
        std.mem.indexOf(u8, lane_id, "observation") != null;
    const mutate_factor_archive = std.mem.indexOf(u8, presented_input, "\"mutate_factor_archive\":true") != null or
        std.mem.indexOf(u8, lane_id, "mutation") != null;
    const mutate_target_carrier = std.mem.indexOf(u8, presented_input, "\"mutate_target_carrier\":true") != null;
    const target_carrier_fingerprint = optionalString(request, "target_materialization_carrier_fingerprint");
    if (target_carrier_fingerprint) |fingerprint| {
        const carrier_ref = try requiredString(request, "target_materialization_ref");
        const observed = try fileFingerprintAlloc(allocator, carrier_ref);
        defer allocator.free(observed);
        if (!std.mem.eql(u8, observed, fingerprint)) return error.TargetMaterializationFingerprintMismatch;
        _ = try requiredString(request, "target_materialization_package_ref");
        if (mutate_target_carrier) try durable_store.writeTextAtomic(allocator, carrier_ref, "{\"tampered\":true}\n");
    }
    if (request.get("factor_materialization_ref")) |factor_ref| switch (factor_ref) {
        .null => {},
        .string => {
            const archive_ref = try requiredString(request, "factor_materialization_archive_ref");
            const archive_fingerprint = try fileFingerprintAlloc(allocator, archive_ref);
            defer allocator.free(archive_fingerprint);
            if (!std.mem.eql(
                u8,
                archive_fingerprint,
                try requiredString(request, "factor_materialization_fingerprint"),
            )) return error.FactorMaterializationFingerprintMismatch;
            if (!std.mem.eql(u8, archive_ref, try requiredString(request, "target_materialization_ref"))) {
                return error.FactorMaterializationPathMismatch;
            }
            if (mutate_factor_archive) {
                try durable_store.writeTextAtomic(allocator, archive_ref, "{\"tampered\":true}");
            }
        },
        else => return error.FactorMaterializationReferenceInvalid,
    };
    if (request.get("source_episode_id") != null and request.get("source_episode_id").? != .null) {
        const context_ref = try requiredString(request, "decision_context_ref");
        const context_fingerprint = try fileFingerprintAlloc(allocator, context_ref);
        defer allocator.free(context_fingerprint);
        if (!std.mem.eql(
            u8,
            context_fingerprint,
            try requiredString(request, "decision_context_fingerprint"),
        )) return error.DecisionContextFingerprintMismatch;
    }

    const output_path = try writeEvidence(allocator, workspace, "output.json", "{\"answer\":\"bounded\"}\n");
    defer allocator.free(output_path.path);
    defer allocator.free(output_path.fingerprint);
    const trace_path = try writeEvidence(allocator, workspace, "trace.json", "{\"events\":[\"one-execution\"]}\n");
    defer allocator.free(trace_path.path);
    defer allocator.free(trace_path.fingerprint);
    const world_path = try writeEvidence(allocator, workspace, "world.json", "{\"state\":\"isolated\"}\n");
    defer allocator.free(world_path.path);
    defer allocator.free(world_path.fingerprint);
    const metrics_path = try writeEvidence(allocator, workspace, "metrics.json", "{\"tokens\":1}\n");
    defer allocator.free(metrics_path.path);
    defer allocator.free(metrics_path.fingerprint);
    const reset_path = try writeEvidence(allocator, workspace, "reset.json", "{\"fresh\":true}\n");
    defer allocator.free(reset_path.path);
    defer allocator.free(reset_path.fingerprint);
    const filesystem_path = try writeEvidence(allocator, workspace, "filesystem.json", "{\"violations\":[]}\n");
    defer allocator.free(filesystem_path.path);
    defer allocator.free(filesystem_path.fingerprint);
    const network_path = try writeEvidence(allocator, workspace, "network.json", "{\"attempts\":0}\n");
    defer allocator.free(network_path.path);
    defer allocator.free(network_path.fingerprint);
    const external_path = try writeEvidence(allocator, workspace, "external.json", "{\"effects\":[]}\n");
    defer allocator.free(external_path.path);
    defer allocator.free(external_path.fingerprint);
    const trial_id = try requiredString(request, "trial_id");
    const execution_audit_json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-trial-execution-audit/v1\",\"trial_id\":{f},\"lane_id\":{f},\"model_execution_count\":1,\"retry_count\":0,\"hidden_fork_count\":0,\"complete\":true}}\n",
        .{ std.json.fmt(trial_id, .{}), std.json.fmt(lane_id, .{}) },
    );
    defer allocator.free(execution_audit_json);
    const execution_audit_path = try writeEvidence(allocator, workspace, "execution-audit.json", execution_audit_json);
    defer allocator.free(execution_audit_path.path);
    defer allocator.free(execution_audit_path.fingerprint);

    const source_episode_id = switch (request.get("source_episode_id") orelse .null) {
        .string => |value| value,
        .null => "direct:fixture",
        else => return error.SourceEpisodeIdInvalid,
    };
    const fir_json = try cas_session_inquiry.packagedFirReceiptJsonAlloc(allocator, .{
        .receipt_id = "FIR-fixture-1",
        .inquiry_id = trial_id,
        .lane_id = lane_id,
        .capsule_id = "DCP-fixture",
        .source_episode_id = source_episode_id,
        .source_thread_id = "",
        .source_thread_id_present = false,
        .source_rollout_path = "fixture:rollout",
        .source_artifact_reconstructability = "transcript_only",
        .source_turn_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .lineage_mode = "rollout_transcript",
        .fork_thread_id = "fixture-fork",
        .forked_from_id = "",
        .temporal_horizon = "pre_decision",
        .turns_before = 3,
        .turns_dropped = 2,
        .turns_after = 1,
        .anchor_digest_expected = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .anchor_digest_observed = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .anchor_exact = true,
        .model = "fixture-model",
        .model_provider = "fixture-provider",
        .service_tier = "fixture",
        .codex_version = "fixture",
        .ephemeral = true,
        .permissions = "read-only",
        .sandbox = "read-only",
        .hooks = "inherit",
        .workspace_mode = "transcript_only",
        .workspace_path = workspace,
        .inquiry_mode = "replay",
        .question = "Which bounded route should be selected?",
        .client_user_message_id = "fixture-user-message",
        .turn_id = "fixture-turn",
        .started_at = 1,
        .ended_at = 2,
        .status = "completed",
        .reconstructed_decision = "bounded decision",
        .selected_route = "route-a",
        .rejected_routes = &[_][]const u8{},
        .evidence_refs = &[_][]const u8{},
        .assumptions = &[_][]const u8{},
        .alternatives = &[_][]const u8{},
        .route_flip_conditions = &[_][]const u8{},
        .uncertainty = "low",
        .hindsight_available = false,
        .unsupported_claims = &[_][]const u8{},
        .final_text_ref = output_path.path,
        .event_log_ref = trace_path.path,
        .archived = false,
        .deleted = false,
        .cleanup_status = "ephemeral_runtime_closed",
        .permissions_valid = true,
        .approval_or_tool_request_observed = false,
        .hindsight_label_valid = true,
        .answer_complete = true,
        .receipt_valid = true,
    });
    defer allocator.free(fir_json);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"cas-trial-executor-result/v1\",\"trial_id\":");
    try writeString(&out.writer, trial_id);
    try out.writer.writeAll(",\"lane_id\":");
    try writeString(&out.writer, lane_id);
    try out.writer.writeAll(",\"executor_binary_fingerprint\":");
    try writeString(&out.writer, executable_fingerprint);
    try out.writer.writeAll(",\"presented_input_fingerprint_observed\":");
    try writeString(&out.writer, try requiredString(request, "presented_input_fingerprint"));
    try out.writer.writeAll(",\"target_snapshot_fingerprint_observed\":");
    try writeString(&out.writer, try requiredString(request, "target_snapshot_fingerprint"));
    try out.writer.writeAll(",\"target_materialization_carrier_fingerprint_observed\":");
    try std.json.Stringify.value(request.get("target_materialization_carrier_fingerprint") orelse .null, .{}, &out.writer);
    try out.writer.writeAll(",\"factor_materialization_ref_observed\":");
    if (tamper_factor_observation and request.get("factor_materialization_ref") != null and request.get("factor_materialization_ref").? != .null) {
        try writeString(&out.writer, "git-blob-json:0000000000000000000000000000000000000000");
    } else {
        try std.json.Stringify.value(request.get("factor_materialization_ref") orelse .null, .{}, &out.writer);
    }
    try out.writer.writeAll(",\"factor_materialization_fingerprint_observed\":");
    try std.json.Stringify.value(request.get("factor_materialization_fingerprint") orelse .null, .{}, &out.writer);
    try out.writer.writeAll(",\"execution_audit_ref\":");
    try writeString(&out.writer, execution_audit_path.path);
    try out.writer.writeAll(",\"execution_audit_fingerprint\":");
    try writeString(&out.writer, execution_audit_path.fingerprint);
    try out.writer.writeAll(",\"hidden_reference_presented\":false,\"sibling_output_presented\":false,");
    try out.writer.writeAll("\"runtime\":{\"environment_fingerprint\":");
    try writeString(&out.writer, try requiredString(request, "environment_fingerprint"));
    try out.writer.writeAll(",\"replay_policy_fingerprint\":");
    try writeString(&out.writer, try requiredString(request, "replay_policy_fingerprint"));
    try out.writer.writeAll(",\"effect_policy_fingerprint\":");
    try writeString(&out.writer, try requiredString(request, "effect_policy_fingerprint"));
    try out.writer.writeAll(",\"model_configuration_fingerprint\":");
    try writeString(&out.writer, try requiredString(request, "model_configuration_fingerprint"));
    try out.writer.writeAll(",\"model_id\":\"fixture-model\",\"model_provider\":\"fixture-provider\",\"runtime_version\":\"v1\",\"seed\":null,\"tokens_used\":1,\"started_at_unix\":1,\"ended_at_unix\":2},");
    try out.writer.writeAll("\"isolation\":{\"fresh_thread\":true,\"fresh_workspace\":true,\"reset_receipt_ref\":");
    try writeString(&out.writer, reset_path.path);
    try out.writer.writeAll(",\"reset_receipt_fingerprint\":");
    try writeString(&out.writer, reset_path.fingerprint);
    try out.writer.writeAll(",\"target_cache_cleared\":true,\"shared_mutable_state_detected\":false,\"limitations\":[]},");
    try out.writer.writeAll("\"effects\":{\"filesystem_receipt_ref\":");
    try writeString(&out.writer, filesystem_path.path);
    try out.writer.writeAll(",\"filesystem_receipt_fingerprint\":");
    try writeString(&out.writer, filesystem_path.fingerprint);
    try out.writer.writeAll(",\"network_receipt_ref\":");
    try writeString(&out.writer, network_path.path);
    try out.writer.writeAll(",\"network_receipt_fingerprint\":");
    try writeString(&out.writer, network_path.fingerprint);
    try out.writer.writeAll(",\"external_effect_receipt_ref\":");
    try writeString(&out.writer, external_path.path);
    try out.writer.writeAll(",\"external_effect_receipt_fingerprint\":");
    try writeString(&out.writer, external_path.fingerprint);
    try out.writer.writeAll(",\"policy_violations\":[]},\"terminal\":{\"status\":\"completed\",\"failure_class\":null,\"failure_detail_ref\":null},");
    try out.writer.writeAll("\"evidence\":{\"output_path\":");
    try writeString(&out.writer, output_path.path);
    try out.writer.writeAll(",\"trace_path\":");
    try writeString(&out.writer, trace_path.path);
    try out.writer.writeAll(",\"world_state_path\":");
    try writeString(&out.writer, world_path.path);
    try out.writer.writeAll(",\"metrics_path\":");
    try writeString(&out.writer, metrics_path.path);
    try out.writer.writeAll("},\"target_instruction_count\":1,\"source_target_text_presented\":false,\"fir_receipt\":");
    try out.writer.writeAll(fir_json);
    try out.writer.writeAll("}\n");
    const result = try out.toOwnedSlice();
    defer allocator.free(result);
    try durable_store.writeTextAtomic(allocator, argv[4], result);
}

const Evidence = struct {
    path: []u8,
    fingerprint: []u8,
};

fn writeEvidence(allocator: std.mem.Allocator, workspace: []const u8, name: []const u8, bytes: []const u8) !Evidence {
    const path = try std.fs.path.join(allocator, &.{ workspace, name });
    errdefer allocator.free(path);
    try durable_store.writeTextAtomic(allocator, path, bytes);
    return .{ .path = path, .fingerprint = try digestBytesAlloc(allocator, bytes) };
}

fn fileFingerprintAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try durable_store.readFileAlloc(allocator, path, MaxBytes);
    defer allocator.free(bytes);
    return digestBytesAlloc(allocator, bytes);
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ObjectRequired,
    };
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (map.get(key) orelse return error.RequiredFieldMissing) {
        .string => |text| text,
        else => error.StringRequired,
    };
}

fn optionalString(map: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (map.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}
