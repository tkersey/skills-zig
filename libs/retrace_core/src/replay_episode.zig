const std = @import("std");
const canonical_json = @import("canonical_json.zig");
const portable_credentials = @import("portable_credentials.zig");

/// Shared admission ceiling for portable CRF JSON artifacts.
pub const max_portable_artifact_bytes: usize = 256 * 1024 * 1024;

pub fn finalizeStimulusAlloc(allocator: std.mem.Allocator, base_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, base_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = try objectPtr(&parsed.value);
    const slot = root.getPtr("stimulus_fingerprint") orelse return error.StimulusFingerprintMissing;
    const fingerprint = try stimulusFingerprintAlloc(allocator, parsed.value);
    defer allocator.free(fingerprint);
    slot.* = .{ .string = fingerprint };
    return canonical_json.canonicalJsonAlloc(allocator, parsed.value);
}

pub fn stimulusFingerprintAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const root = try object(value);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-stimulus-fingerprint-basis/v1\",\"messages\":[");
    const messages = try requiredArray(root, "messages");
    for (messages.items, 0..) |message_value, index| {
        if (index != 0) try out.writer.writeByte(',');
        const message = try object(message_value);
        try out.writer.writeAll("{\"ordinal\":");
        try writeCanonical(allocator, &out.writer, message.get("ordinal") orelse return error.MissingField);
        try out.writer.writeAll(",\"role\":");
        try writeCanonical(allocator, &out.writer, message.get("role") orelse return error.MissingField);
        try out.writer.writeAll(",\"content\":");
        try writeCanonical(allocator, &out.writer, message.get("content") orelse return error.MissingField);
        try out.writer.writeAll(",\"timestamp_policy\":");
        try writeCanonical(allocator, &out.writer, message.get("timestamp_policy") orelse return error.MissingField);
        try out.writer.writeAll(",\"visibility\":");
        try writeCanonical(allocator, &out.writer, message.get("visibility") orelse return error.MissingField);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"instructions\":[");
    const instructions = try requiredArray(root, "instructions");
    for (instructions.items, 0..) |instruction_value, index| {
        if (index != 0) try out.writer.writeByte(',');
        const instruction = try object(instruction_value);
        try out.writer.writeAll("{\"class\":");
        try writeCanonical(allocator, &out.writer, instruction.get("class") orelse return error.MissingField);
        if (instruction.get("slot")) |slot| {
            try out.writer.writeAll(",\"slot\":");
            try writeCanonical(allocator, &out.writer, slot);
        }
        try out.writer.writeAll(",\"content_ref\":");
        try writeCanonical(allocator, &out.writer, instruction.get("content_ref") orelse return error.MissingField);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"attachments\":");
    try writeCanonical(allocator, &out.writer, root.get("attachments") orelse return error.MissingField);
    try out.writer.writeAll(",\"initial_goal_state\":");
    try writeCanonical(allocator, &out.writer, root.get("initial_goal_state") orelse return error.MissingField);
    try out.writer.writeAll(",\"context_policy\":");
    try writeCanonical(allocator, &out.writer, root.get("context_policy") orelse return error.MissingField);
    try out.writer.writeByte('}');
    return digestWriterValueAlloc(allocator, &out);
}

pub fn finalizeEpisodeAlloc(allocator: std.mem.Allocator, base_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, base_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = try objectPtr(&parsed.value);
    const slot = root.getPtr("episode_fingerprint") orelse return error.EpisodeFingerprintMissing;
    const fingerprint = try episodeFingerprintAlloc(allocator, parsed.value);
    defer allocator.free(fingerprint);
    slot.* = .{ .string = fingerprint };
    return canonical_json.canonicalJsonAlloc(allocator, parsed.value);
}

pub fn episodeFingerprintAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const root = try object(value);
    const target = try requiredObject(root, "target");
    const cut = try requiredObject(root, "cut");
    const hidden = try requiredObject(root, "hidden_reference");
    const fidelity = try requiredObject(root, "fidelity");
    const privacy = try requiredObject(root, "privacy");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-episode-fingerprint-basis/v1\"");
    try writeRequiredMember(allocator, &out.writer, root, "episode_family_id");
    try out.writer.writeAll(",\"target\":{");
    try writeNamedRequiredMember(allocator, &out.writer, target, "kind", false);
    try writeNamedRequiredMember(allocator, &out.writer, target, "target_id", true);
    try writeNamedRequiredMember(allocator, &out.writer, target, "replaceable_slot", true);
    try out.writer.writeAll("},\"cut\":{");
    var first = true;
    for ([_][]const u8{ "kind", "confidence", "last_fixed_turn_index", "last_fixed_event_ref", "first_regenerated_event_ref", "rationale" }) |name| {
        try writeNamedRequiredMember(allocator, &out.writer, cut, name, !first);
        first = false;
    }
    try out.writer.writeByte('}');
    for ([_][]const u8{
        "stimulus_fingerprint",
        "world_fingerprint",
        "world_availability_fingerprint",
        "runtime_fingerprint",
        "oracle_contract_refs",
    }) |name| try writeRequiredMember(allocator, &out.writer, root, name);
    try out.writer.writeAll(",\"hidden_reference\":{");
    try writeNamedRequiredMember(allocator, &out.writer, hidden, "historical_response_ref", false);
    try writeNamedRequiredMember(allocator, &out.writer, hidden, "historical_trace_ref", true);
    try writeNamedRequiredMember(allocator, &out.writer, hidden, "future_outcome_ref", true);
    try out.writer.writeAll("},\"privacy\":{");
    try writeNamedRequiredMember(allocator, &out.writer, privacy, "redaction_receipt_ref", false);
    try writeNamedRequiredMember(allocator, &out.writer, privacy, "redaction_receipt_fingerprint", true);
    try out.writer.writeByte('}');
    try out.writer.writeAll(",\"fidelity\":");
    try writeCanonical(allocator, &out.writer, .{ .object = fidelity });
    try writeRequiredMember(allocator, &out.writer, root, "split");
    try out.writer.writeByte('}');
    return digestWriterValueAlloc(allocator, &out);
}

pub fn projectRunnerInputAlloc(allocator: std.mem.Allocator, episode_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, episode_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = try object(parsed.value);
    if (!try validateEpisodeValue(allocator, parsed.value)) return error.InvalidReplayEpisode;
    const target = try requiredObject(root, "target");
    const cut = try requiredObject(root, "cut");
    if (equalsString(cut, "confidence", "ambiguous")) return error.DiagnosticEpisodeNotRunnable;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-runner-input/v1\"");
    try writeRequiredMember(allocator, &out.writer, root, "episode_id");
    try writeRequiredMember(allocator, &out.writer, root, "episode_fingerprint");
    try out.writer.writeAll(",\"target\":{");
    try writeNamedRequiredMember(allocator, &out.writer, target, "kind", false);
    try writeNamedRequiredMember(allocator, &out.writer, target, "target_id", true);
    try writeNamedRequiredMember(allocator, &out.writer, target, "replaceable_slot", true);
    try out.writer.writeByte('}');
    try out.writer.writeAll(",\"cut\":{");
    var first = true;
    for ([_][]const u8{ "kind", "confidence", "last_fixed_turn_index", "last_fixed_event_ref", "first_regenerated_event_ref", "rationale" }) |name| {
        try writeNamedRequiredMember(allocator, &out.writer, cut, name, !first);
        first = false;
    }
    try out.writer.writeByte('}');
    for ([_][]const u8{
        "stimulus_ref",
        "stimulus_fingerprint",
        "world_snapshot_ref",
        "world_fingerprint",
        "world_availability_ref",
        "world_availability_fingerprint",
        "runtime_contract_ref",
        "runtime_fingerprint",
        "oracle_contract_refs",
        "fidelity",
        "split",
    }) |name| try writeRequiredMember(allocator, &out.writer, root, name);
    try out.writer.writeAll(",\"effect_policy\":\"deny_external\",\"runner_input_fingerprint\":\"\"}");
    const base = try out.toOwnedSlice();
    defer allocator.free(base);
    return canonical_json.finalizeFingerprintAlloc(allocator, base, "runner_input_fingerprint");
}

pub fn validateEpisodeValue(allocator: std.mem.Allocator, value: std.json.Value) !bool {
    const root = object(value) catch return false;
    if (!hasExactKeys(root, &.{
        "schema",             "episode_id",        "episode_family_id",      "source",                         "target",               "cut",                 "stimulus",         "stimulus_ref",         "stimulus_fingerprint",
        "world_snapshot_ref", "world_fingerprint", "world_availability_ref", "world_availability_fingerprint", "runtime_contract_ref", "runtime_fingerprint", "hidden_reference", "oracle_contract_refs", "privacy",
        "fidelity",           "split",             "episode_fingerprint",
    }) or
        !equalsString(root, "schema", "hylo-replay-episode/v1") or
        !nonblankString(root.get("episode_id")) or
        !nonblankString(root.get("episode_family_id")) or
        !equalsString(root, "stimulus_ref", "artifact:stimulus.json") or
        !equalsString(root, "world_snapshot_ref", "artifact:world.json") or
        !equalsString(root, "world_availability_ref", "artifact:world-availability.json") or
        !equalsString(root, "runtime_contract_ref", "artifact:runtime.json") or
        !oneOf(stringValue(root.get("split")) orelse return false, &.{ "practice", "holdout", "challenge" })) return false;
    portable_credentials.validateJson(value) catch return false;
    for ([_][]const u8{ "stimulus_fingerprint", "world_fingerprint", "world_availability_fingerprint", "runtime_fingerprint", "episode_fingerprint" }) |name| {
        if (!canonical_json.isFingerprint(stringValue(root.get(name)) orelse return false)) return false;
    }

    const source = requiredObject(root, "source") catch return false;
    if (!hasExactKeys(source, &.{ "session_id", "rollout_ref", "rollout_fingerprint", "source_turn_ids", "source_event_range" }) or
        !nonblankString(source.get("session_id")) or
        !nonblankString(source.get("rollout_ref")) or
        !canonical_json.isFingerprint(stringValue(source.get("rollout_fingerprint")) orelse return false)) return false;
    const source_turn_ids = arrayValue(source.get("source_turn_ids")) orelse return false;
    if (source_turn_ids.items.len == 0 or !allNonblankStrings(source_turn_ids)) return false;
    const source_range = requiredObject(source, "source_event_range") catch return false;
    if (!hasExactKeys(source_range, &.{ "first_line", "last_fixed_line" }) or intValue(source_range.get("first_line")) != 1) return false;

    const target = requiredObject(root, "target") catch return false;
    if (!hasExactKeys(target, &.{ "kind", "target_id", "activation_refs", "replaceable_slot", "source_bundle_fingerprint" }) or
        !equalsString(target, "kind", "skill") or
        !nonblankString(target.get("target_id")) or
        !canonical_json.isFingerprint(stringValue(target.get("source_bundle_fingerprint")) orelse return false)) return false;
    const expected_slot = try std.fmt.allocPrint(allocator, "skill://{s}", .{stringValue(target.get("target_id")).?});
    defer allocator.free(expected_slot);
    if (!equalsString(target, "replaceable_slot", expected_slot)) return false;
    const activation_refs = arrayValue(target.get("activation_refs")) orelse return false;
    if (activation_refs.items.len != 1) return false;
    const activation_line = parseLineRef(stringValue(activation_refs.items[0]) orelse return false) orelse return false;

    const cut = requiredObject(root, "cut") catch return false;
    if (!hasExactKeys(cut, &.{ "kind", "confidence", "last_fixed_turn_index", "last_fixed_event_ref", "first_regenerated_event_ref", "rationale", "excluded_future_digest" }) or
        !equalsString(cut, "kind", "skill_activation") or
        !oneOf(stringValue(cut.get("confidence")) orelse return false, &.{ "exact", "derived", "manual", "ambiguous" }) or
        !nonblankString(cut.get("rationale")) or
        !canonical_json.isFingerprint(stringValue(cut.get("excluded_future_digest")) orelse return false)) return false;
    const last_fixed_line = parseLineRef(stringValue(cut.get("last_fixed_event_ref")) orelse return false) orelse return false;
    const first_regenerated_line = parseLineRef(stringValue(cut.get("first_regenerated_event_ref")) orelse return false) orelse return false;
    if (last_fixed_line >= first_regenerated_line or activation_line > last_fixed_line or
        intValue(source_range.get("last_fixed_line")) != last_fixed_line or intValue(cut.get("last_fixed_turn_index")) == null or
        source_turn_ids.items.len != intValue(cut.get("last_fixed_turn_index")).? + 1) return false;

    const stimulus_value = root.get("stimulus") orelse return false;
    if (!try validateStimulusValue(allocator, stimulus_value)) return false;
    const stimulus = try object(stimulus_value);
    const embedded_stimulus_fingerprint = stringValue(stimulus.get("stimulus_fingerprint")) orelse return false;
    if (!std.mem.eql(u8, embedded_stimulus_fingerprint, stringValue(root.get("stimulus_fingerprint")).?)) return false;
    const messages = try requiredArray(stimulus, "messages");
    for (messages.items) |message_value| {
        const message = try object(message_value);
        const line = intValue(message.get("source_line")) orelse return false;
        if (line > last_fixed_line or line == activation_line or
            (line > activation_line and !equalsString(message, "role", "user"))) return false;
    }
    const instructions = try requiredArray(stimulus, "instructions");
    var matched_slot = false;
    var replaceable_target_count: usize = 0;
    for (instructions.items) |instruction_value| {
        const instruction = try object(instruction_value);
        const line = intValue(instruction.get("source_line")) orelse return false;
        if (equalsString(instruction, "class", "replaceable_target")) {
            replaceable_target_count += 1;
            if (equalsString(instruction, "slot", expected_slot) and line == activation_line) matched_slot = true;
        } else if (line >= activation_line) return false;
    }
    if (!matched_slot or replaceable_target_count != 1) return false;

    const hidden = requiredObject(root, "hidden_reference") catch return false;
    if (!hasExactKeys(hidden, &.{ "historical_response_ref", "historical_response_fingerprint", "historical_trace_ref", "future_outcome_ref" }) or
        !safeCustodyRef(hidden.get("historical_response_ref")) or
        !optionalCustodyRef(hidden.get("historical_trace_ref")) or
        !optionalCustodyRef(hidden.get("future_outcome_ref")) or
        !canonical_json.isFingerprint(stringValue(hidden.get("historical_response_fingerprint")) orelse return false)) return false;
    if (!validOracleContractRefs(root.get("oracle_contract_refs"))) return false;
    const privacy = requiredObject(root, "privacy") catch return false;
    if (!hasExactKeys(privacy, &.{ "mode", "redaction_receipt_ref", "redaction_receipt_fingerprint" }) or
        !equalsString(privacy, "mode", "sanitized") or
        !safeCustodyRef(privacy.get("redaction_receipt_ref")) or
        !canonical_json.isFingerprint(stringValue(privacy.get("redaction_receipt_fingerprint")) orelse return false)) return false;
    const fidelity = requiredObject(root, "fidelity") catch return false;
    if (!validFidelity(fidelity)) return false;
    const claimed = stringValue(root.get("episode_fingerprint")).?;
    const computed = episodeFingerprintAlloc(allocator, value) catch return false;
    defer allocator.free(computed);
    return std.mem.eql(u8, claimed, computed) and episodeIdMatchesFingerprint(stringValue(root.get("episode_id")).?, claimed);
}

pub fn validateRunnerInputValue(allocator: std.mem.Allocator, value: std.json.Value) !bool {
    const root = object(value) catch return false;
    if (!hasExactKeys(root, &.{
        "schema",            "episode_id",               "episode_fingerprint",            "target",               "cut",                 "stimulus_ref",         "stimulus_fingerprint", "world_snapshot_ref",
        "world_fingerprint", "world_availability_ref",   "world_availability_fingerprint", "runtime_contract_ref", "runtime_fingerprint", "oracle_contract_refs", "fidelity",             "split",
        "effect_policy",     "runner_input_fingerprint",
    }) or
        !equalsString(root, "schema", "hylo-runner-input/v1") or containsForbiddenKey(value) or
        !nonblankString(root.get("episode_id")) or
        !canonical_json.isFingerprint(stringValue(root.get("episode_fingerprint")) orelse return false) or
        !equalsString(root, "stimulus_ref", "artifact:stimulus.json") or
        !equalsString(root, "world_snapshot_ref", "artifact:world.json") or
        !equalsString(root, "world_availability_ref", "artifact:world-availability.json") or
        !equalsString(root, "runtime_contract_ref", "artifact:runtime.json") or
        !equalsString(root, "effect_policy", "deny_external") or
        !oneOf(stringValue(root.get("split")) orelse return false, &.{ "practice", "holdout", "challenge" })) return false;
    if (!episodeIdMatchesFingerprint(stringValue(root.get("episode_id")).?, stringValue(root.get("episode_fingerprint")).?)) return false;
    for ([_][]const u8{ "stimulus_fingerprint", "world_fingerprint", "world_availability_fingerprint", "runtime_fingerprint", "runner_input_fingerprint" }) |name| {
        if (!canonical_json.isFingerprint(stringValue(root.get(name)) orelse return false)) return false;
    }
    const target = requiredObject(root, "target") catch return false;
    if (!hasExactKeys(target, &.{ "kind", "target_id", "replaceable_slot" }) or !equalsString(target, "kind", "skill") or
        !nonblankString(target.get("target_id"))) return false;
    const expected_slot = try std.fmt.allocPrint(allocator, "skill://{s}", .{stringValue(target.get("target_id")).?});
    defer allocator.free(expected_slot);
    if (!equalsString(target, "replaceable_slot", expected_slot)) return false;
    const cut = requiredObject(root, "cut") catch return false;
    if (!hasExactKeys(cut, &.{ "kind", "confidence", "last_fixed_turn_index", "last_fixed_event_ref", "first_regenerated_event_ref", "rationale" }) or
        !equalsString(cut, "kind", "skill_activation") or !oneOf(stringValue(cut.get("confidence")) orelse return false, &.{ "exact", "derived", "manual" }) or
        intValue(cut.get("last_fixed_turn_index")) == null or !nonblankString(cut.get("rationale"))) return false;
    const last_fixed = parseLineRef(stringValue(cut.get("last_fixed_event_ref")) orelse return false) orelse return false;
    const first_regenerated = parseLineRef(stringValue(cut.get("first_regenerated_event_ref")) orelse return false) orelse return false;
    if (last_fixed >= first_regenerated) return false;
    if (!validOracleContractRefs(root.get("oracle_contract_refs"))) return false;
    const fidelity = requiredObject(root, "fidelity") catch return false;
    if (!validFidelity(fidelity)) return false;
    return canonical_json.verifyFingerprintAlloc(allocator, value, "runner_input_fingerprint");
}

pub fn validateStimulusValue(allocator: std.mem.Allocator, value: std.json.Value) !bool {
    const root = object(value) catch return false;
    if (!hasExactKeys(root, &.{ "schema", "messages", "instructions", "attachments", "initial_goal_state", "context_policy", "stimulus_fingerprint" }) or
        !equalsString(root, "schema", "hylo-stimulus/v1") or
        !canonical_json.isFingerprint(stringValue(root.get("stimulus_fingerprint")) orelse return false)) return false;
    portable_credentials.validateJson(value) catch return false;
    const messages = requiredArray(root, "messages") catch return false;
    var previous_line: usize = 0;
    for (messages.items, 0..) |message_value, index| {
        const message = object(message_value) catch return false;
        if (!hasExactKeys(message, &.{ "message_id", "ordinal", "source_line", "role", "content", "timestamp_policy", "provenance_ref", "visibility" }) or
            !nonblankString(message.get("message_id")) or
            intValue(message.get("ordinal")) != index or
            !oneOf(stringValue(message.get("role")) orelse return false, &.{ "system", "developer", "user", "assistant_prefix", "tool_observation", "controller" }) or
            !oneOf(stringValue(message.get("timestamp_policy")) orelse return false, &.{ "source", "relative" }) or
            !equalsString(message, "visibility", "runner_visible") or
            !nonblankString(message.get("provenance_ref"))) return false;
        const line = intValue(message.get("source_line")) orelse return false;
        if (line == 0 or (index != 0 and line <= previous_line)) return false;
        const content = arrayValue(message.get("content")) orelse return false;
        if (content.items.len == 0) return false;
        const adjacent_text = try allocator.alloc([]const u8, content.items.len);
        defer allocator.free(adjacent_text);
        for (content.items, 0..) |item_value, item_index| {
            const item = object(item_value) catch return false;
            if (!hasExactKeys(item, &.{ "type", "text" }) or !equalsString(item, "type", "text") or stringValue(item.get("text")) == null) return false;
            adjacent_text[item_index] = stringValue(item.get("text")).?;
        }
        portable_credentials.validateAdjacentTextSlices(allocator, adjacent_text) catch return false;
        previous_line = line;
    }
    const instructions = requiredArray(root, "instructions") catch return false;
    var replaceable_target_count: usize = 0;
    for (instructions.items) |instruction_value| {
        const instruction = object(instruction_value) catch return false;
        if (!hasExactKeys(instruction, &.{ "instruction_id", "class", "slot", "content_ref", "source_line" }) or
            !nonblankString(instruction.get("instruction_id")) or
            !oneOf(stringValue(instruction.get("class")) orelse return false, &.{ "fixed", "replaceable_target", "runtime_owned", "unknown" }) or
            intValue(instruction.get("source_line")) == null or intValue(instruction.get("source_line")).? == 0) return false;
        const class = stringValue(instruction.get("class")).?;
        if (std.mem.eql(u8, class, "replaceable_target")) {
            if (!startsWithString(instruction.get("slot"), "skill://") or !isNull(instruction.get("content_ref"))) return false;
            replaceable_target_count += 1;
        } else if (!optionalString(instruction.get("slot")) or !safeRunnerContentRef(instruction.get("content_ref")) or
            !stimulusContentRefMatches(messages, instruction)) return false;
    }
    if (replaceable_target_count != 1) return false;
    const attachments = arrayValue(root.get("attachments")) orelse return false;
    if (attachments.items.len != 0 or !isNull(root.get("initial_goal_state"))) return false;
    const context_policy = requiredObject(root, "context_policy") catch return false;
    if (!hasExactKeys(context_policy, &.{ "requested", "applied" }) or
        !oneOf(stringValue(context_policy.get("requested")) orelse return false, &.{ "dependency-closed", "dependency_closed", "full-prefix", "full_prefix" }) or
        !oneOf(stringValue(context_policy.get("applied")) orelse return false, &.{ "full_prefix_fallback", "full_prefix" })) return false;
    const claimed = stringValue(root.get("stimulus_fingerprint")).?;
    const computed = stimulusFingerprintAlloc(allocator, value) catch return false;
    defer allocator.free(computed);
    return std.mem.eql(u8, claimed, computed);
}

pub fn validateCounterfactualCutReceipt(value: std.json.Value, allocator: std.mem.Allocator) !bool {
    const root = object(value) catch return false;
    if (!hasExactKeys(root, &.{ "schema", "kind", "confidence", "activation_ref", "last_fixed_turn_index", "last_fixed_event_ref", "first_regenerated_event_ref", "rationale", "excluded_future_digest", "historical_target_content_fingerprint", "cut_fingerprint" }) or
        !equalsString(root, "schema", "hylo-counterfactual-cut-receipt/v1") or
        !equalsString(root, "kind", "skill_activation") or
        !oneOf(stringValue(root.get("confidence")) orelse return false, &.{ "exact", "derived", "manual", "ambiguous" }) or
        intValue(root.get("last_fixed_turn_index")) == null or !nonblankString(root.get("rationale")) or
        !canonical_json.isFingerprint(stringValue(root.get("excluded_future_digest")) orelse return false) or
        !canonical_json.isFingerprint(stringValue(root.get("historical_target_content_fingerprint")) orelse return false)) return false;
    const activation = parseLineRef(stringValue(root.get("activation_ref")) orelse return false) orelse return false;
    const last_fixed = parseLineRef(stringValue(root.get("last_fixed_event_ref")) orelse return false) orelse return false;
    const first_regenerated = parseLineRef(stringValue(root.get("first_regenerated_event_ref")) orelse return false) orelse return false;
    if (activation > last_fixed or last_fixed >= first_regenerated) return false;
    return canonical_json.verifyFingerprintAlloc(allocator, value, "cut_fingerprint");
}

pub fn validateRedactionReceipt(value: std.json.Value, allocator: std.mem.Allocator) !bool {
    const root = object(value) catch return false;
    if (!hasExactKeys(root, &.{ "schema", "source_fingerprint", "output_fingerprint", "redaction_classes", "stable_substitutions", "semantic_impact", "local_unredacted_available", "redaction_fingerprint" }) or
        !equalsString(root, "schema", "hylo-redaction-receipt/v1") or
        !canonical_json.isFingerprint(stringValue(root.get("source_fingerprint")) orelse return false) or
        !canonical_json.isFingerprint(stringValue(root.get("output_fingerprint")) orelse return false) or
        !oneOf(stringValue(root.get("semantic_impact")) orelse return false, &.{ "path_identity_only", "credential_personal_and_path_identity_only" }) or
        boolValue(root.get("local_unredacted_available")) != true) return false;
    const classes = arrayValue(root.get("redaction_classes")) orelse return false;
    const expected_classes = [_][]const u8{ "credential", "email", "home_path" };
    if (classes.items.len != expected_classes.len) return false;
    for (classes.items, expected_classes) |class_value, expected| {
        if (!std.mem.eql(u8, stringValue(class_value) orelse return false, expected)) return false;
    }
    const semantic_impact = stringValue(root.get("semantic_impact")).?;
    const substitutions = arrayValue(root.get("stable_substitutions")) orelse return false;
    if (substitutions.items.len != classes.items.len) return false;
    const expected_placeholders = [_][]const u8{ "<CREDENTIAL>", "<EMAIL>", "<HOME>" };
    for (substitutions.items, expected_classes, expected_placeholders) |substitution_value, expected_class, expected_placeholder| {
        const substitution = object(substitution_value) catch return false;
        const count = intValue(substitution.get("count")) orelse return false;
        if (!hasExactKeys(substitution, &.{ "class", "placeholder", "count" }) or
            !equalsString(substitution, "class", expected_class) or !equalsString(substitution, "placeholder", expected_placeholder) or
            (std.mem.eql(u8, semantic_impact, "path_identity_only") and
                !std.mem.eql(u8, expected_class, "home_path") and count != 0)) return false;
    }
    return canonical_json.verifyFingerprintAlloc(allocator, value, "redaction_fingerprint");
}

pub fn validateCustodyManifest(value: std.json.Value, allocator: std.mem.Allocator) !bool {
    const root = object(value) catch return false;
    if (!hasExactKeys(root, &.{ "schema", "episode_id", "entries", "key_delivery", "manifest_fingerprint" }) or
        !equalsString(root, "schema", "hylo-custody-manifest/v1") or
        !nonblankString(root.get("episode_id")) or !equalsString(root, "key_delivery", "owner_fd_only")) return false;
    const entries = requiredArray(root, "entries") catch return false;
    if (entries.items.len != 1) return false;
    for (entries.items) |entry_value| {
        const entry = object(entry_value) catch return false;
        if (!hasExactKeys(entry, &.{ "kind", "ref", "fingerprint", "plaintext_persisted" }) or
            !equalsString(entry, "kind", "historical_response") or !equalsString(entry, "ref", "historical-response.sealed.json") or
            !canonical_json.isFingerprint(stringValue(entry.get("fingerprint")) orelse return false) or boolValue(entry.get("plaintext_persisted")) != false) return false;
    }
    return canonical_json.verifyFingerprintAlloc(allocator, value, "manifest_fingerprint");
}

pub fn validateSealedHistoricalResponse(value: std.json.Value, allocator: std.mem.Allocator) bool {
    const root = object(value) catch return false;
    if (!hasExactKeys(root, &.{ "schema", "episode_id", "historical_response_fingerprint", "algorithm", "aad", "nonce_base64", "ciphertext_base64", "tag_base64" }) or
        !equalsString(root, "schema", "hylo-sealed-historical-response/v1") or
        !nonblankString(root.get("episode_id")) or
        !canonical_json.isFingerprint(stringValue(root.get("historical_response_fingerprint")) orelse return false) or
        !equalsString(root, "algorithm", "xchacha20-poly1305") or
        !nonblankString(root.get("nonce_base64")) or
        !nonblankString(root.get("ciphertext_base64")) or
        !nonblankString(root.get("tag_base64"))) return false;
    if (!equalsString(root, "aad", stringValue(root.get("episode_id")) orelse return false)) return false;
    const nonce = decodeCanonicalBase64Alloc(allocator, stringValue(root.get("nonce_base64")) orelse return false) catch return false;
    defer allocator.free(nonce);
    const ciphertext = decodeCanonicalBase64Alloc(allocator, stringValue(root.get("ciphertext_base64")) orelse return false) catch return false;
    defer allocator.free(ciphertext);
    const tag = decodeCanonicalBase64Alloc(allocator, stringValue(root.get("tag_base64")) orelse return false) catch return false;
    defer allocator.free(tag);
    return nonce.len == std.crypto.aead.chacha_poly.XChaCha20Poly1305.nonce_length and
        ciphertext.len != 0 and tag.len == std.crypto.aead.chacha_poly.XChaCha20Poly1305.tag_length;
}

fn decodeCanonicalBase64Alloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return error.InvalidBase64;
    const canonical = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(decoded.len));
    defer allocator.free(canonical);
    _ = std.base64.standard.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, encoded, canonical)) return error.NonCanonicalBase64;
    return decoded;
}

pub fn containsForbiddenKey(value: std.json.Value) bool {
    return switch (value) {
        .object => |map| blk: {
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                if (oneOf(entry.key_ptr.*, &.{ "hidden_reference", "excluded_future_digest", "sealed_root", "ciphertext", "historical_response", "future_outcome_ref", "grader_reference" }) or containsForbiddenKey(entry.value_ptr.*)) break :blk true;
            }
            break :blk false;
        },
        .array => |array| blk: {
            for (array.items) |item| if (containsForbiddenKey(item)) break :blk true;
            break :blk false;
        },
        .string => |text| containsForbiddenRunnerLocator(text),
        else => false,
    };
}

fn containsForbiddenRunnerLocator(text: []const u8) bool {
    for ([_][]const u8{ "custody:", "sealed:", ".sealed.json" }) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) return true;
    }
    return false;
}

fn digestWriterValueAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) ![]u8 {
    const basis = try out.toOwnedSlice();
    defer allocator.free(basis);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, basis, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    return canonical_json.digestValueAlloc(allocator, parsed.value);
}

fn writeRequiredMember(allocator: std.mem.Allocator, writer: anytype, object_map: std.json.ObjectMap, name: []const u8) !void {
    try writer.writeByte(',');
    try writeNamedRequiredMember(allocator, writer, object_map, name, false);
}

fn writeNamedRequiredMember(allocator: std.mem.Allocator, writer: anytype, object_map: std.json.ObjectMap, name: []const u8, comma: bool) !void {
    if (comma) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    try writeCanonical(allocator, writer, object_map.get(name) orelse return error.MissingField);
}

fn writeCanonical(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value) !void {
    const encoded = try canonical_json.canonicalJsonAlloc(allocator, value);
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
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

fn requiredObject(parent: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return object(parent.get(name) orelse return error.MissingField);
}

fn requiredArray(parent: std.json.ObjectMap, name: []const u8) !std.json.Array {
    return arrayValue(parent.get(name)) orelse error.MissingField;
}

fn arrayValue(value: ?std.json.Value) ?std.json.Array {
    return if (value) |actual| switch (actual) {
        .array => |array| array,
        else => null,
    } else null;
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    return if (value) |actual| switch (actual) {
        .string => |text| text,
        else => null,
    } else null;
}

fn intValue(value: ?std.json.Value) ?usize {
    return if (value) |actual| switch (actual) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    } else null;
}

fn boolValue(value: ?std.json.Value) ?bool {
    return if (value) |actual| switch (actual) {
        .bool => |boolean| boolean,
        else => null,
    } else null;
}

fn nonblankString(value: ?std.json.Value) bool {
    const text = stringValue(value) orelse return false;
    return std.mem.trim(u8, text, " \t\r\n").len != 0;
}

fn startsWithString(value: ?std.json.Value, prefix: []const u8) bool {
    const text = stringValue(value) orelse return false;
    return std.mem.startsWith(u8, text, prefix);
}

fn equalsString(object_map: std.json.ObjectMap, name: []const u8, expected: []const u8) bool {
    const actual = stringValue(object_map.get(name)) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn oneOf(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn hasExactKeys(object_map: std.json.ObjectMap, expected: []const []const u8) bool {
    if (object_map.count() != expected.len) return false;
    for (expected) |key| if (!object_map.contains(key)) return false;
    return true;
}

fn parseLineRef(value: []const u8) ?usize {
    if (!std.mem.startsWith(u8, value, "line:")) return null;
    const line = std.fmt.parseInt(usize, value["line:".len..], 10) catch return null;
    return if (line == 0) null else line;
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isNull(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .null => true,
        else => false,
    } else false;
}

fn optionalString(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .null, .string => true,
        else => false,
    } else false;
}

fn safeRunnerContentRef(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .null => true,
        .string => |text| if (std.mem.startsWith(u8, text, "artifact:"))
            safeRelativePath(text["artifact:".len..])
        else
            validStimulusContentRef(text),
        else => false,
    } else false;
}

fn validStimulusContentRef(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "stimulus:msg-")) return false;
    const suffix = text["stimulus:msg-".len..];
    if (suffix.len == 0) return false;
    for (suffix) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

fn stimulusContentRefMatches(messages: std.json.Array, instruction: std.json.ObjectMap) bool {
    const content_ref = stringValue(instruction.get("content_ref")) orelse return true;
    if (!std.mem.startsWith(u8, content_ref, "stimulus:")) return true;
    const expected_message_id = content_ref["stimulus:".len..];
    const instruction_line = intValue(instruction.get("source_line")) orelse return false;
    for (messages.items) |message_value| {
        const message = object(message_value) catch return false;
        if (equalsString(message, "message_id", expected_message_id) and intValue(message.get("source_line")) == instruction_line) return true;
    }
    return false;
}

fn optionalCustodyRef(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .null => true,
        .string => safeCustodyRef(actual),
        else => false,
    } else false;
}

fn safeCustodyRef(value: ?std.json.Value) bool {
    const text = stringValue(value) orelse return false;
    return std.mem.startsWith(u8, text, "custody:") and safeRelativePath(text["custody:".len..]);
}

fn allNonblankStrings(array: std.json.Array) bool {
    for (array.items) |item| if (!nonblankString(item)) return false;
    return true;
}

fn validOracleContractRefs(value: ?std.json.Value) bool {
    const refs = arrayValue(value) orelse return false;
    for (refs.items) |ref_value| {
        const ref = stringValue(ref_value) orelse return false;
        if (!std.mem.startsWith(u8, ref, "artifact:oracle-") or std.mem.indexOf(u8, ref, "..") != null or
            std.mem.indexOf(u8, ref, "sealed") != null or std.mem.indexOf(u8, ref, "custody") != null) return false;
    }
    return true;
}

fn validFidelity(fidelity: std.json.ObjectMap) bool {
    if (!hasExactKeys(fidelity, &.{ "class", "limitations", "replay_eligible" }) or
        !oneOf(stringValue(fidelity.get("class")) orelse return false, &.{ "controlled_replay", "workspace_snapshot", "tool_tape_replay", "transcript_only", "diagnostic_only", "unusable" }) or
        boolValue(fidelity.get("replay_eligible")) == null) return false;
    const limitations = arrayValue(fidelity.get("limitations")) orelse return false;
    if (!allNonblankStrings(limitations)) return false;
    const class = stringValue(fidelity.get("class")).?;
    const replay_eligible = boolValue(fidelity.get("replay_eligible")).?;
    if (limitations.items.len == 0) return false;
    if (oneOf(class, &.{ "transcript_only", "diagnostic_only", "unusable" }) and replay_eligible) return false;
    if (std.mem.eql(u8, class, "controlled_replay") and !replay_eligible) return false;
    return true;
}

fn episodeIdMatchesFingerprint(episode_id: []const u8, fingerprint: []const u8) bool {
    return canonical_json.isFingerprint(fingerprint) and episode_id.len == "ep-".len + 16 and
        std.mem.startsWith(u8, episode_id, "ep-") and std.mem.eql(u8, episode_id["ep-".len..], fingerprint["sha256:".len .. "sha256:".len + 16]);
}

fn buildTestEpisodeAlloc(
    allocator: std.mem.Allocator,
    post_activation_role: []const u8,
    fixed_instruction_line: usize,
    rationale: []const u8,
) ![]u8 {
    const stimulus_base = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-stimulus/v1\",\"messages\":[{{\"message_id\":\"msg-1\",\"ordinal\":0,\"source_line\":1,\"role\":\"system\",\"content\":[{{\"type\":\"text\",\"text\":\"fixed context\"}}],\"timestamp_policy\":\"source\",\"provenance_ref\":\"rollout:line-1\",\"visibility\":\"runner_visible\"}},{{\"message_id\":\"msg-4\",\"ordinal\":1,\"source_line\":4,\"role\":{f},\"content\":[{{\"type\":\"text\",\"text\":\"follow-up\"}}],\"timestamp_policy\":\"source\",\"provenance_ref\":\"rollout:line-4\",\"visibility\":\"runner_visible\"}}],\"instructions\":[{{\"instruction_id\":\"inst-fixed\",\"class\":\"fixed\",\"slot\":null,\"content_ref\":\"artifact:fixed.txt\",\"source_line\":{d}}},{{\"instruction_id\":\"inst-target\",\"class\":\"replaceable_target\",\"slot\":\"skill://hylo\",\"content_ref\":null,\"source_line\":3}}],\"attachments\":[],\"initial_goal_state\":null,\"context_policy\":{{\"requested\":\"full-prefix\",\"applied\":\"full_prefix\"}},\"stimulus_fingerprint\":\"\"}}",
        .{ std.json.fmt(post_activation_role, .{}), fixed_instruction_line },
    );
    defer allocator.free(stimulus_base);
    const stimulus_json = try finalizeStimulusAlloc(allocator, stimulus_base);
    defer allocator.free(stimulus_json);
    var parsed_stimulus = try std.json.parseFromSlice(std.json.Value, allocator, stimulus_json, .{});
    defer parsed_stimulus.deinit();
    const stimulus_fingerprint = stringValue((try object(parsed_stimulus.value)).get("stimulus_fingerprint")).?;

    const episode_base = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-replay-episode/v1\",\"episode_id\":\"ep-0000000000000000\",\"episode_family_id\":\"family-test\",\"source\":{{\"session_id\":\"session-test\",\"rollout_ref\":\"local:test\",\"rollout_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"source_turn_ids\":[\"turn-1\"],\"source_event_range\":{{\"first_line\":1,\"last_fixed_line\":5}}}},\"target\":{{\"kind\":\"skill\",\"target_id\":\"hylo\",\"activation_refs\":[\"line:3\"],\"replaceable_slot\":\"skill://hylo\",\"source_bundle_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\"}},\"cut\":{{\"kind\":\"skill_activation\",\"confidence\":\"exact\",\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:5\",\"first_regenerated_event_ref\":\"line:6\",\"rationale\":{f},\"excluded_future_digest\":\"sha256:3333333333333333333333333333333333333333333333333333333333333333\"}},\"stimulus\":{s},\"stimulus_ref\":\"artifact:stimulus.json\",\"stimulus_fingerprint\":{f},\"world_snapshot_ref\":\"artifact:world.json\",\"world_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\",\"world_availability_ref\":\"artifact:world-availability.json\",\"world_availability_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\",\"runtime_contract_ref\":\"artifact:runtime.json\",\"runtime_fingerprint\":\"sha256:6666666666666666666666666666666666666666666666666666666666666666\",\"hidden_reference\":{{\"historical_response_ref\":\"custody:historical-response.sealed.json\",\"historical_response_fingerprint\":\"sha256:7777777777777777777777777777777777777777777777777777777777777777\",\"historical_trace_ref\":null,\"future_outcome_ref\":null}},\"oracle_contract_refs\":[],\"privacy\":{{\"mode\":\"sanitized\",\"redaction_receipt_ref\":\"custody:redaction.json\",\"redaction_receipt_fingerprint\":\"sha256:8888888888888888888888888888888888888888888888888888888888888888\"}},\"fidelity\":{{\"class\":\"controlled_replay\",\"limitations\":[\"frozen fixtures\"],\"replay_eligible\":true}},\"split\":\"practice\",\"episode_fingerprint\":\"\"}}",
        .{ std.json.fmt(rationale, .{}), stimulus_json, std.json.fmt(stimulus_fingerprint, .{}) },
    );
    defer allocator.free(episode_base);
    const finalized = try finalizeEpisodeAlloc(allocator, episode_base);
    defer allocator.free(finalized);
    var parsed_episode = try std.json.parseFromSlice(std.json.Value, allocator, finalized, .{ .allocate = .alloc_always });
    defer parsed_episode.deinit();
    const root = try objectPtr(&parsed_episode.value);
    const fingerprint = stringValue(root.get("episode_fingerprint")).?;
    const episode_id = try std.fmt.allocPrint(allocator, "ep-{s}", .{fingerprint["sha256:".len .. "sha256:".len + 16]});
    defer allocator.free(episode_id);
    root.getPtr("episode_id").?.* = .{ .string = episode_id };
    return canonical_json.canonicalJsonAlloc(allocator, parsed_episode.value);
}

fn refinalizeTestEpisodeAlloc(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const root = try objectPtr(&parsed.value);
    root.getPtr("episode_id").?.* = .{ .string = "ep-0000000000000000" };
    root.getPtr("episode_fingerprint").?.* = .{ .string = "" };
    const base = try canonical_json.canonicalJsonAlloc(allocator, parsed.value);
    defer allocator.free(base);
    const finalized = try finalizeEpisodeAlloc(allocator, base);
    defer allocator.free(finalized);
    var finalized_parsed = try std.json.parseFromSlice(std.json.Value, allocator, finalized, .{ .allocate = .alloc_always });
    defer finalized_parsed.deinit();
    const finalized_root = try objectPtr(&finalized_parsed.value);
    const fingerprint = stringValue(finalized_root.get("episode_fingerprint")).?;
    const episode_id = try std.fmt.allocPrint(allocator, "ep-{s}", .{fingerprint["sha256:".len .. "sha256:".len + 16]});
    defer allocator.free(episode_id);
    finalized_root.getPtr("episode_id").?.* = .{ .string = episode_id };
    return canonical_json.canonicalJsonAlloc(allocator, finalized_parsed.value);
}

test "episode semantic identity binds custody locators but excludes sealed content digests" {
    const left =
        "{\"episode_family_id\":\"family-a\",\"target\":{\"kind\":\"skill\",\"target_id\":\"hylo\",\"replaceable_slot\":\"skill://hylo\"},\"cut\":{\"kind\":\"skill_activation\",\"confidence\":\"exact\",\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:3\",\"first_regenerated_event_ref\":\"line:4\",\"rationale\":\"structured activation\",\"excluded_future_digest\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\"},\"stimulus_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"world_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"world_availability_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"runtime_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"oracle_contract_refs\":[],\"hidden_reference\":{\"historical_response_ref\":\"custody:history/response.sealed.json\",\"historical_response_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"historical_trace_ref\":null,\"future_outcome_ref\":null},\"privacy\":{\"redaction_receipt_ref\":\"custody:receipts/redaction.json\",\"redaction_receipt_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"},\"fidelity\":{\"class\":\"transcript_only\",\"limitations\":[\"unavailable\"],\"replay_eligible\":false},\"split\":\"practice\",\"source\":{\"rollout_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"}}";
    const right =
        "{\"episode_family_id\":\"family-a\",\"target\":{\"kind\":\"skill\",\"target_id\":\"hylo\",\"replaceable_slot\":\"skill://hylo\"},\"cut\":{\"kind\":\"skill_activation\",\"confidence\":\"exact\",\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:3\",\"first_regenerated_event_ref\":\"line:4\",\"rationale\":\"structured activation\",\"excluded_future_digest\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\"},\"stimulus_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"world_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"world_availability_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"runtime_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"oracle_contract_refs\":[],\"hidden_reference\":{\"historical_response_ref\":\"custody:history/response.sealed.json\",\"historical_response_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\",\"historical_trace_ref\":null,\"future_outcome_ref\":null},\"privacy\":{\"redaction_receipt_ref\":\"custody:receipts/redaction.json\",\"redaction_receipt_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"},\"fidelity\":{\"class\":\"transcript_only\",\"limitations\":[\"unavailable\"],\"replay_eligible\":false},\"split\":\"practice\",\"source\":{\"rollout_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"}}";
    var left_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, left, .{});
    defer left_parsed.deinit();
    var right_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, right, .{});
    defer right_parsed.deinit();
    const left_fingerprint = try episodeFingerprintAlloc(std.testing.allocator, left_parsed.value);
    defer std.testing.allocator.free(left_fingerprint);
    const right_fingerprint = try episodeFingerprintAlloc(std.testing.allocator, right_parsed.value);
    defer std.testing.allocator.free(right_fingerprint);
    try std.testing.expectEqualStrings(left_fingerprint, right_fingerprint);

    const locator_cases = [_]struct { needle: []const u8, replacement: []const u8 }{
        .{ .needle = "history/response.sealed.json", .replacement = "history/alternate.sealed.json" },
        .{ .needle = "\"historical_trace_ref\":null", .replacement = "\"historical_trace_ref\":\"custody:history/trace.sealed.json\"" },
        .{ .needle = "\"future_outcome_ref\":null", .replacement = "\"future_outcome_ref\":\"custody:history/future.sealed.json\"" },
        .{ .needle = "custody:receipts/redaction.json", .replacement = "custody:receipts/alternate-redaction.json" },
    };
    for (locator_cases) |case| {
        const changed_locator = try std.mem.replaceOwned(u8, std.testing.allocator, left, case.needle, case.replacement);
        defer std.testing.allocator.free(changed_locator);
        var locator_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, changed_locator, .{});
        defer locator_parsed.deinit();
        const locator_fingerprint = try episodeFingerprintAlloc(std.testing.allocator, locator_parsed.value);
        defer std.testing.allocator.free(locator_fingerprint);
        try std.testing.expect(!std.mem.eql(u8, left_fingerprint, locator_fingerprint));
    }

    const changed_family = try std.mem.replaceOwned(u8, std.testing.allocator, left, "family-a", "family-b");
    defer std.testing.allocator.free(changed_family);
    var family_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, changed_family, .{});
    defer family_parsed.deinit();
    const family_fingerprint = try episodeFingerprintAlloc(std.testing.allocator, family_parsed.value);
    defer std.testing.allocator.free(family_fingerprint);
    try std.testing.expect(!std.mem.eql(u8, left_fingerprint, family_fingerprint));

    const changed_limitation = try std.mem.replaceOwned(u8, std.testing.allocator, left, "unavailable", "different-limitation");
    defer std.testing.allocator.free(changed_limitation);
    var limitation_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, changed_limitation, .{});
    defer limitation_parsed.deinit();
    const limitation_fingerprint = try episodeFingerprintAlloc(std.testing.allocator, limitation_parsed.value);
    defer std.testing.allocator.free(limitation_fingerprint);
    try std.testing.expect(!std.mem.eql(u8, left_fingerprint, limitation_fingerprint));

    const changed_rationale = try std.mem.replaceOwned(u8, std.testing.allocator, left, "structured activation", "different rationale");
    defer std.testing.allocator.free(changed_rationale);
    var rationale_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, changed_rationale, .{});
    defer rationale_parsed.deinit();
    const rationale_fingerprint = try episodeFingerprintAlloc(std.testing.allocator, rationale_parsed.value);
    defer std.testing.allocator.free(rationale_fingerprint);
    try std.testing.expect(!std.mem.eql(u8, left_fingerprint, rationale_fingerprint));
}

test "transcript-only fidelity cannot claim replay eligibility" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"class\":\"transcript_only\",\"limitations\":[\"historical bytes unavailable\"],\"replay_eligible\":true}", .{});
    defer parsed.deinit();
    try std.testing.expect(!validFidelity(try object(parsed.value)));
}

test "v1 episodes and runner inputs reject exact reconstruction claims" {
    const valid_episode = try buildTestEpisodeAlloc(std.testing.allocator, "user", 1, "structured activation");
    defer std.testing.allocator.free(valid_episode);
    const exact_episode_base = try std.mem.replaceOwned(u8, std.testing.allocator, valid_episode, "controlled_replay", "exact_reconstruction");
    defer std.testing.allocator.free(exact_episode_base);
    const exact_episode = try refinalizeTestEpisodeAlloc(std.testing.allocator, exact_episode_base);
    defer std.testing.allocator.free(exact_episode);
    var exact_episode_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, exact_episode, .{});
    defer exact_episode_parsed.deinit();
    try std.testing.expect(!(try validateEpisodeValue(std.testing.allocator, exact_episode_parsed.value)));

    const valid_runner = try projectRunnerInputAlloc(std.testing.allocator, valid_episode);
    defer std.testing.allocator.free(valid_runner);
    const exact_runner_base = try std.mem.replaceOwned(u8, std.testing.allocator, valid_runner, "controlled_replay", "exact_reconstruction");
    defer std.testing.allocator.free(exact_runner_base);
    const exact_runner = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, exact_runner_base, "runner_input_fingerprint");
    defer std.testing.allocator.free(exact_runner);
    var exact_runner_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, exact_runner, .{});
    defer exact_runner_parsed.deinit();
    try std.testing.expect(!(try validateRunnerInputValue(std.testing.allocator, exact_runner_parsed.value)));
}

test "refingerprinted episodes reject unsafe custody locators" {
    const valid = try buildTestEpisodeAlloc(std.testing.allocator, "user", 1, "structured activation");
    defer std.testing.allocator.free(valid);
    const cases = [_]struct { valid: []const u8, invalid: []const u8 }{
        .{ .valid = "custody:historical-response.sealed.json", .invalid = "custody:" },
        .{ .valid = "custody:historical-response.sealed.json", .invalid = "custody:/absolute.json" },
        .{ .valid = "custody:historical-response.sealed.json", .invalid = "custody:../escape.json" },
        .{ .valid = "custody:historical-response.sealed.json", .invalid = "custody:a/./response.json" },
        .{ .valid = "custody:historical-response.sealed.json", .invalid = "custody:a//response.json" },
        .{ .valid = "custody:historical-response.sealed.json", .invalid = "custody:a\\\\response.json" },
        .{ .valid = "custody:redaction.json", .invalid = "custody:../redaction.json" },
        .{ .valid = "\"historical_trace_ref\":null", .invalid = "\"historical_trace_ref\":\"custody:../trace.json\"" },
        .{ .valid = "\"future_outcome_ref\":null", .invalid = "\"future_outcome_ref\":\"custody:\"" },
    };
    for (cases) |case| {
        const invalid_base = try std.mem.replaceOwned(u8, std.testing.allocator, valid, case.valid, case.invalid);
        defer std.testing.allocator.free(invalid_base);
        const invalid = try refinalizeTestEpisodeAlloc(std.testing.allocator, invalid_base);
        defer std.testing.allocator.free(invalid);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, invalid, .{});
        defer parsed.deinit();
        try std.testing.expect(!(try validateEpisodeValue(std.testing.allocator, parsed.value)));
    }
}

test "cut receipt rejects source line zero after refingerprinting" {
    const base =
        "{\"schema\":\"hylo-counterfactual-cut-receipt/v1\",\"kind\":\"skill_activation\",\"confidence\":\"exact\",\"activation_ref\":\"line:0\",\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:0\",\"first_regenerated_event_ref\":\"line:1\",\"rationale\":\"invalid zero boundary\",\"excluded_future_digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"historical_target_content_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"cut_fingerprint\":\"\"}";
    const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "cut_fingerprint");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validateCounterfactualCutReceipt(parsed.value, std.testing.allocator)));
}

test "runner validation rejects unknown future-bearing fields after refingerprinting" {
    const base =
        "{\"schema\":\"hylo-runner-input/v1\",\"episode_id\":\"ep-aaaaaaaaaaaaaaaa\",\"episode_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"target\":{\"kind\":\"skill\",\"target_id\":\"hylo\",\"replaceable_slot\":\"skill://hylo\"},\"cut\":{\"kind\":\"skill_activation\",\"confidence\":\"exact\",\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:3\",\"first_regenerated_event_ref\":\"line:4\",\"rationale\":\"exact\"},\"stimulus_ref\":\"artifact:stimulus.json\",\"stimulus_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"world_snapshot_ref\":\"artifact:world.json\",\"world_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"world_availability_ref\":\"artifact:world-availability.json\",\"world_availability_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"runtime_contract_ref\":\"artifact:runtime.json\",\"runtime_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"oracle_contract_refs\":[],\"fidelity\":{\"class\":\"transcript_only\",\"limitations\":[],\"replay_eligible\":false},\"split\":\"practice\",\"effect_policy\":\"deny_external\",\"historical_response\":\"future\",\"runner_input_fingerprint\":\"\"}";
    const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "runner_input_fingerprint");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validateRunnerInputValue(std.testing.allocator, parsed.value)));
}

test "runner validation rejects custody and sealed locators in nested string values" {
    const base =
        "{\"schema\":\"hylo-runner-input/v1\",\"episode_id\":\"ep-aaaaaaaaaaaaaaaa\",\"episode_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"target\":{\"kind\":\"skill\",\"target_id\":\"hylo\",\"replaceable_slot\":\"skill://hylo\"},\"cut\":{\"kind\":\"skill_activation\",\"confidence\":\"exact\",\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:3\",\"first_regenerated_event_ref\":\"line:4\",\"rationale\":\"structured activation\"},\"stimulus_ref\":\"artifact:stimulus.json\",\"stimulus_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"world_snapshot_ref\":\"artifact:world.json\",\"world_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"world_availability_ref\":\"artifact:world-availability.json\",\"world_availability_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"runtime_contract_ref\":\"artifact:runtime.json\",\"runtime_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"oracle_contract_refs\":[],\"fidelity\":{\"class\":\"transcript_only\",\"limitations\":[\"historical repository bytes unavailable\"],\"replay_eligible\":false},\"split\":\"practice\",\"effect_policy\":\"deny_external\",\"runner_input_fingerprint\":\"\"}";
    const valid_json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "runner_input_fingerprint");
    defer std.testing.allocator.free(valid_json);
    var valid_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid_json, .{});
    defer valid_parsed.deinit();
    try std.testing.expect(try validateRunnerInputValue(std.testing.allocator, valid_parsed.value));

    const cases = [_]struct {
        needle: []const u8,
        replacement: []const u8,
    }{
        .{ .needle = "structured activation", .replacement = "custody:redaction.json" },
        .{ .needle = "historical repository bytes unavailable", .replacement = "sealed:future-outcome" },
        .{ .needle = "structured activation", .replacement = "artifact:historical-response.sealed.json" },
    };
    for (cases) |case| {
        const invalid_base = try std.mem.replaceOwned(u8, std.testing.allocator, base, case.needle, case.replacement);
        defer std.testing.allocator.free(invalid_base);
        const invalid_json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, invalid_base, "runner_input_fingerprint");
        defer std.testing.allocator.free(invalid_json);
        var invalid_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, invalid_json, .{});
        defer invalid_parsed.deinit();
        try std.testing.expect(!(try validateRunnerInputValue(std.testing.allocator, invalid_parsed.value)));
    }
}

test "runner validation rejects untyped oracle payloads and target slot disagreement" {
    const cases = [_][]const u8{
        "{\"schema\":\"hylo-runner-input/v1\",\"episode_id\":\"ep-aaaaaaaaaaaaaaaa\",\"episode_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"target\":{\"kind\":\"skill\",\"target_id\":\"hylo\",\"replaceable_slot\":\"skill://hylo\"},\"cut\":{\"kind\":\"skill_activation\",\"confidence\":\"exact\",\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:3\",\"first_regenerated_event_ref\":\"line:4\",\"rationale\":\"exact\"},\"stimulus_ref\":\"artifact:stimulus.json\",\"stimulus_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"world_snapshot_ref\":\"artifact:world.json\",\"world_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"world_availability_ref\":\"artifact:world-availability.json\",\"world_availability_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"runtime_contract_ref\":\"artifact:runtime.json\",\"runtime_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"oracle_contract_refs\":[{\"answer\":\"future\"}],\"fidelity\":{\"class\":\"transcript_only\",\"limitations\":[],\"replay_eligible\":false},\"split\":\"practice\",\"effect_policy\":\"deny_external\",\"runner_input_fingerprint\":\"\"}",
        "{\"schema\":\"hylo-runner-input/v1\",\"episode_id\":\"ep-aaaaaaaaaaaaaaaa\",\"episode_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"target\":{\"kind\":\"skill\",\"target_id\":\"hylo\",\"replaceable_slot\":\"skill://other\"},\"cut\":{\"kind\":\"skill_activation\",\"confidence\":\"exact\",\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:3\",\"first_regenerated_event_ref\":\"line:4\",\"rationale\":\"exact\"},\"stimulus_ref\":\"artifact:stimulus.json\",\"stimulus_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"world_snapshot_ref\":\"artifact:world.json\",\"world_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"world_availability_ref\":\"artifact:world-availability.json\",\"world_availability_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"runtime_contract_ref\":\"artifact:runtime.json\",\"runtime_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"oracle_contract_refs\":[],\"fidelity\":{\"class\":\"transcript_only\",\"limitations\":[],\"replay_eligible\":false},\"split\":\"practice\",\"effect_policy\":\"deny_external\",\"runner_input_fingerprint\":\"\"}",
    };
    for (cases) |base| {
        const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "runner_input_fingerprint");
        defer std.testing.allocator.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(!(try validateRunnerInputValue(std.testing.allocator, parsed.value)));
    }
}

test "custody manifest requires the sealed historical response entry" {
    const base =
        "{\"schema\":\"hylo-custody-manifest/v1\",\"episode_id\":\"ep-aaaaaaaaaaaaaaaa\",\"entries\":[{\"kind\":\"arbitrary_future_outcome\",\"ref\":\"runner-visible.json\",\"fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"plaintext_persisted\":false}],\"key_delivery\":\"owner_fd_only\",\"manifest_fingerprint\":\"\"}";
    const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "manifest_fingerprint");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validateCustodyManifest(parsed.value, std.testing.allocator)));
}

test "path identity only redaction receipts require zero credential and email counts" {
    const cases = [_]struct {
        semantic_impact: []const u8,
        credential_count: usize,
        email_count: usize,
        expected: bool,
    }{
        .{ .semantic_impact = "path_identity_only", .credential_count = 0, .email_count = 0, .expected = true },
        .{ .semantic_impact = "path_identity_only", .credential_count = 1, .email_count = 0, .expected = false },
        .{ .semantic_impact = "path_identity_only", .credential_count = 0, .email_count = 1, .expected = false },
        .{ .semantic_impact = "credential_personal_and_path_identity_only", .credential_count = 0, .email_count = 0, .expected = true },
        .{ .semantic_impact = "credential_personal_and_path_identity_only", .credential_count = 1, .email_count = 1, .expected = true },
    };
    for (cases) |case| {
        const base = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema\":\"hylo-redaction-receipt/v1\",\"source_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"output_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"redaction_classes\":[\"credential\",\"email\",\"home_path\"],\"stable_substitutions\":[{{\"class\":\"credential\",\"placeholder\":\"<CREDENTIAL>\",\"count\":{d}}},{{\"class\":\"email\",\"placeholder\":\"<EMAIL>\",\"count\":{d}}},{{\"class\":\"home_path\",\"placeholder\":\"<HOME>\",\"count\":2}}],\"semantic_impact\":{f},\"local_unredacted_available\":true,\"redaction_fingerprint\":\"\"}}",
            .{ case.credential_count, case.email_count, std.json.fmt(case.semantic_impact, .{}) },
        );
        defer std.testing.allocator.free(base);
        const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "redaction_fingerprint");
        defer std.testing.allocator.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, try validateRedactionReceipt(parsed.value, std.testing.allocator));
    }
}

test "stimulus validation rejects untyped attachments" {
    const base =
        "{\"schema\":\"hylo-stimulus/v1\",\"messages\":[],\"instructions\":[{\"instruction_id\":\"inst-target\",\"class\":\"replaceable_target\",\"slot\":\"skill://hylo\",\"content_ref\":null,\"source_line\":1}],\"attachments\":[{\"historical_response\":\"future\"}],\"initial_goal_state\":null,\"context_policy\":{\"requested\":\"full-prefix\",\"applied\":\"full_prefix\"},\"stimulus_fingerprint\":\"\"}";
    const json = try finalizeStimulusAlloc(std.testing.allocator, base);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validateStimulusValue(std.testing.allocator, parsed.value)));
}

test "stimulus validation rejects custody instruction references" {
    const base =
        "{\"schema\":\"hylo-stimulus/v1\",\"messages\":[],\"instructions\":[{\"instruction_id\":\"inst-fixed\",\"class\":\"fixed\",\"slot\":null,\"content_ref\":\"custody:historical-response.sealed.json\",\"source_line\":1},{\"instruction_id\":\"inst-target\",\"class\":\"replaceable_target\",\"slot\":\"skill://hylo\",\"content_ref\":null,\"source_line\":2}],\"attachments\":[],\"initial_goal_state\":null,\"context_policy\":{\"requested\":\"full-prefix\",\"applied\":\"full_prefix\"},\"stimulus_fingerprint\":\"\"}";
    const json = try finalizeStimulusAlloc(std.testing.allocator, base);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validateStimulusValue(std.testing.allocator, parsed.value)));
}

test "stimulus validation enforces credential postconditions across adjacent text parts" {
    const base =
        "{\"schema\":\"hylo-stimulus/v1\",\"messages\":[{\"message_id\":\"msg-1\",\"ordinal\":0,\"source_line\":1,\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"client\"},{\"type\":\"text\",\"text\":\"Secret=synthetic-value\"}],\"timestamp_policy\":\"source\",\"provenance_ref\":\"rollout:line-1\",\"visibility\":\"runner_visible\"}],\"instructions\":[{\"instruction_id\":\"inst-target\",\"class\":\"replaceable_target\",\"slot\":\"skill://hylo\",\"content_ref\":null,\"source_line\":2}],\"attachments\":[],\"initial_goal_state\":null,\"context_policy\":{\"requested\":\"full-prefix\",\"applied\":\"full_prefix\"},\"stimulus_fingerprint\":\"\"}";
    const json = try finalizeStimulusAlloc(std.testing.allocator, base);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validateStimulusValue(std.testing.allocator, parsed.value)));
}

test "stimulus content references use safe schemes and exact message identity" {
    inline for (.{
        "artifact:",
        "artifact:/etc/passwd",
        "artifact:../future.json",
        "artifact:a/./future.json",
        "artifact:a//future.json",
        "artifact:a\\future.json",
        "stimulus:msg-2",
    }) |content_ref| {
        const base = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema\":\"hylo-stimulus/v1\",\"messages\":[{{\"message_id\":\"msg-1\",\"ordinal\":0,\"source_line\":1,\"role\":\"system\",\"content\":[{{\"type\":\"text\",\"text\":\"fixed context\"}}],\"timestamp_policy\":\"source\",\"provenance_ref\":\"rollout:line-1\",\"visibility\":\"runner_visible\"}}],\"instructions\":[{{\"instruction_id\":\"inst-fixed\",\"class\":\"fixed\",\"slot\":null,\"content_ref\":{f},\"source_line\":1}},{{\"instruction_id\":\"inst-target\",\"class\":\"replaceable_target\",\"slot\":\"skill://hylo\",\"content_ref\":null,\"source_line\":2}}],\"attachments\":[],\"initial_goal_state\":null,\"context_policy\":{{\"requested\":\"full-prefix\",\"applied\":\"full_prefix\"}},\"stimulus_fingerprint\":\"\"}}",
            .{std.json.fmt(content_ref, .{})},
        );
        defer std.testing.allocator.free(base);
        const json = try finalizeStimulusAlloc(std.testing.allocator, base);
        defer std.testing.allocator.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(!(try validateStimulusValue(std.testing.allocator, parsed.value)));
    }

    try std.testing.expect(!safeRunnerContentRef(.{ .string = "artifact:a\x00b" }));
    try std.testing.expect(safeRunnerContentRef(.{ .string = "artifact:fixed/context.txt" }));

    const exact_base =
        "{\"schema\":\"hylo-stimulus/v1\",\"messages\":[{\"message_id\":\"msg-1\",\"ordinal\":0,\"source_line\":1,\"role\":\"system\",\"content\":[{\"type\":\"text\",\"text\":\"fixed context\"}],\"timestamp_policy\":\"source\",\"provenance_ref\":\"rollout:line-1\",\"visibility\":\"runner_visible\"}],\"instructions\":[{\"instruction_id\":\"inst-fixed\",\"class\":\"fixed\",\"slot\":null,\"content_ref\":\"stimulus:msg-1\",\"source_line\":1},{\"instruction_id\":\"inst-target\",\"class\":\"replaceable_target\",\"slot\":\"skill://hylo\",\"content_ref\":null,\"source_line\":2}],\"attachments\":[],\"initial_goal_state\":null,\"context_policy\":{\"requested\":\"full-prefix\",\"applied\":\"full_prefix\"},\"stimulus_fingerprint\":\"\"}";
    const exact_json = try finalizeStimulusAlloc(std.testing.allocator, exact_base);
    defer std.testing.allocator.free(exact_json);
    var exact_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, exact_json, .{});
    defer exact_parsed.deinit();
    try std.testing.expect(try validateStimulusValue(std.testing.allocator, exact_parsed.value));
}

test "refingerprinted episodes enforce the post-activation causal frontier" {
    const valid = try buildTestEpisodeAlloc(std.testing.allocator, "user", 1, "structured activation");
    defer std.testing.allocator.free(valid);
    var valid_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid, .{});
    defer valid_parsed.deinit();
    try std.testing.expect(try validateEpisodeValue(std.testing.allocator, valid_parsed.value));

    const assistant_after_activation = try buildTestEpisodeAlloc(std.testing.allocator, "assistant_prefix", 1, "structured activation");
    defer std.testing.allocator.free(assistant_after_activation);
    var assistant_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, assistant_after_activation, .{});
    defer assistant_parsed.deinit();
    try std.testing.expect(!(try validateEpisodeValue(std.testing.allocator, assistant_parsed.value)));

    const fixed_after_activation = try buildTestEpisodeAlloc(std.testing.allocator, "user", 4, "structured activation");
    defer std.testing.allocator.free(fixed_after_activation);
    var fixed_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixed_after_activation, .{});
    defer fixed_parsed.deinit();
    try std.testing.expect(!(try validateEpisodeValue(std.testing.allocator, fixed_parsed.value)));
}

test "refingerprinted episodes enforce the portable credential postcondition" {
    const json = try buildTestEpisodeAlloc(std.testing.allocator, "user", 1, "clientSecret=synthetic-value");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validateEpisodeValue(std.testing.allocator, parsed.value)));
}

test "sealed historical response binds episode, response digest, and aad" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"schema\":\"hylo-sealed-historical-response/v1\",\"episode_id\":\"ep-aaaaaaaaaaaaaaaa\",\"historical_response_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"algorithm\":\"xchacha20-poly1305\",\"aad\":\"ep-aaaaaaaaaaaaaaaa\",\"nonce_base64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"ciphertext_base64\":\"Y2lwaGVydGV4dA==\",\"tag_base64\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(validateSealedHistoricalResponse(parsed.value, std.testing.allocator));
    const root = try objectPtr(&parsed.value);
    root.getPtr("aad").?.* = .{ .string = "ep-bbbbbbbbbbbbbbbb" };
    try std.testing.expect(!validateSealedHistoricalResponse(parsed.value, std.testing.allocator));
}

test "sealed historical response rejects malformed or wrong-sized cipher material" {
    const template =
        "{\"schema\":\"hylo-sealed-historical-response/v1\",\"episode_id\":\"ep-aaaaaaaaaaaaaaaa\",\"historical_response_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"algorithm\":\"xchacha20-poly1305\",\"aad\":\"ep-aaaaaaaaaaaaaaaa\",\"nonce_base64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"ciphertext_base64\":\"YQ==\",\"tag_base64\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}";
    const cases = [_]struct { field: []const u8, valid: []const u8, invalid: []const u8 }{
        .{ .field = "nonce_base64", .valid = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .invalid = "x" },
        .{ .field = "nonce_base64", .valid = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .invalid = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" },
        .{ .field = "tag_base64", .valid = "AAAAAAAAAAAAAAAAAAAAAA==", .invalid = "x" },
        .{ .field = "tag_base64", .valid = "AAAAAAAAAAAAAAAAAAAAAA==", .invalid = "AAAAAAAAAAAAAAAAAAAA" },
        .{ .field = "ciphertext_base64", .valid = "YQ==", .invalid = "x" },
    };
    for (cases) |case| {
        _ = case.field;
        const json = try std.mem.replaceOwned(u8, std.testing.allocator, template, case.valid, case.invalid);
        defer std.testing.allocator.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(!validateSealedHistoricalResponse(parsed.value, std.testing.allocator));
    }
}
