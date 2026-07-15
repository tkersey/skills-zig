const std = @import("std");
const dcp_schema = @import("dcp_schema.zig");
const attestation = @import("hctp_attestation.zig");

pub const source_governance_version = "SGG-v1";
pub const fir_version = "FIR-v1";
pub const replay_plan_version = "RIP-v1";
pub const episode_identity_version = "hylo-retrace-episode-identity/v1";
pub const source_episode_projection_version = "hylo-source-episode-projection/v1";
pub const target_text_witness_version = "hylo-source-target-text-witness/v1";

pub const SourceGovernanceState = enum {
    authoritative,
    declared_uncontrolled,
    incidental,
    ambiguous,
    absent,
};

pub const SourceGovernanceReport = struct {
    state: SourceGovernanceState,
    replay_allowed: bool,
    workflow_effect_allowed: bool,
};

pub const HistoricalProfileReport = struct {
    governance: SourceGovernanceReport,
    packet_id: []u8,
    anchor_digest: []u8,
    reconstructability: []u8,
    source_ref: []u8,
    source_episode_id: []u8,
    source_turn_digest: []u8,
    target_text_witness_fingerprint: []u8,

    pub fn deinit(self: *HistoricalProfileReport, allocator: std.mem.Allocator) void {
        allocator.free(self.packet_id);
        allocator.free(self.anchor_digest);
        allocator.free(self.reconstructability);
        allocator.free(self.source_ref);
        allocator.free(self.source_episode_id);
        allocator.free(self.source_turn_digest);
        allocator.free(self.target_text_witness_fingerprint);
    }
};

pub const FirReport = struct {
    lane_id: []u8,
    inquiry_id: []u8,
    lineage_mode: []u8,
    source_turn_digest: []u8,
    anchor_digest: []u8,
    source_episode_id: []u8,
    source_ref: ?[]u8 = null,
    episode_identity_fingerprint: ?[]u8 = null,

    pub fn deinit(self: *FirReport, allocator: std.mem.Allocator) void {
        allocator.free(self.lane_id);
        allocator.free(self.inquiry_id);
        allocator.free(self.lineage_mode);
        allocator.free(self.source_turn_digest);
        allocator.free(self.anchor_digest);
        allocator.free(self.source_episode_id);
        if (self.source_ref) |value| allocator.free(value);
        if (self.episode_identity_fingerprint) |value| allocator.free(value);
    }
};

pub const ReplayPlanOptions = struct {
    inquiry_id: []const u8,
    lane_id: []const u8,
    prompt_template: []const u8,
    model_policy: []const u8 = "registered",
    workspace_policy: []const u8,
    maximum_lane_duration_ms: u64,
    maximum_tokens_per_lane: u64,
};

pub fn validateSourceGovernance(value: std.json.Value) !SourceGovernanceReport {
    const root = try object(value);
    const gate = if (root.get("source_governance_gate")) |wrapped| try object(wrapped) else root;
    if (!std.mem.eql(u8, try requiredString(gate, "gate_version"), source_governance_version)) {
        return error.SourceGovernanceVersionInvalid;
    }
    const verdict = try requiredObject(gate, "verdict");
    const state = parseGovernanceState(try requiredString(verdict, "state")) orelse
        return error.SourceGovernanceStateInvalid;
    const replay_allowed = try requiredBool(verdict, "replay_allowed");
    const allowed_modes = try requiredArray(verdict, "allowed_modes");
    if (replay_allowed != listContains(allowed_modes, "replay")) {
        return error.SourceGovernanceModeInconsistent;
    }
    const workflow_effect_allowed = state == .authoritative and replay_allowed;
    if ((state == .incidental or state == .ambiguous or state == .absent) and replay_allowed) {
        return error.SourceGovernanceReplayForbidden;
    }
    return .{
        .state = state,
        .replay_allowed = replay_allowed,
        .workflow_effect_allowed = workflow_effect_allowed,
    };
}

pub fn validateHistoricalProfile(
    allocator: std.mem.Allocator,
    profile_value: std.json.Value,
    require_authoritative: bool,
) !HistoricalProfileReport {
    const profile = try object(profile_value);
    if (!std.mem.eql(u8, try requiredString(profile, "kind"), "historical_decision")) {
        return error.HistoricalDecisionProfileRequired;
    }
    const governance_value = profile.get("source_governance") orelse
        return error.SourceGovernanceMissing;
    const governance = try validateSourceGovernance(governance_value);
    const governance_root = try object(governance_value);
    const governance_gate = if (governance_root.get("source_governance_gate")) |wrapped|
        try object(wrapped)
    else
        governance_root;
    const source_ref = try requiredString(governance_gate, "source_ref");
    const source_episode_id = try requiredString(governance_gate, "source_episode_id");
    if (!std.mem.eql(u8, source_ref, source_episode_id)) return error.SourceEpisodeIdentityMismatch;
    if (!governance.replay_allowed) return error.SourceGovernanceReplayForbidden;
    if (require_authoritative and !governance.workflow_effect_allowed) {
        return error.SourceGovernanceNotAuthoritative;
    }
    if (!std.mem.eql(u8, try requiredString(profile, "temporal_horizon"), "pre_decision")) {
        return error.OutcomeAwareDecisionContext;
    }
    if (!std.mem.eql(u8, try requiredString(profile, "retrace_mode"), "replay")) {
        return error.RetraceReplayRequired;
    }
    if (!std.mem.eql(u8, try requiredString(profile, "required_fir_version"), fir_version)) {
        return error.FirVersionInvalid;
    }
    const required_lineage = try requiredString(profile, "required_lineage");
    if (!oneOf(required_lineage, &.{ "thread_fork", "rollout_transcript", "either" })) {
        return error.LineageModeInvalid;
    }
    const policy = try requiredString(profile, "source_target_text_policy");
    if (!oneOf(policy, &.{ "absent", "preserve", "strip_and_replace" })) {
        return error.SourceTargetTextPolicyInvalid;
    }
    const context_value = profile.get("decision_context") orelse return error.DecisionContextMissing;
    var dcp_report = try dcp_schema.validateValue(allocator, context_value);
    defer dcp_report.deinit(allocator);
    if (!dcp_report.valid or !containsString(dcp_report.anchors_available, "pre_decision")) {
        return error.DecisionContextInvalid;
    }
    var source_episode_resolution = try dcp_schema.resolveSourceEpisodeIdentity(allocator, context_value);
    defer source_episode_resolution.deinit(allocator);
    switch (source_episode_resolution.state) {
        .explicit_exact, .derived_session_turn => {},
        .mismatch => return error.SourceEpisodeIdentityMismatch,
        .unavailable => return error.SourceEpisodeIdentityUnavailable,
    }
    const resolved_source_episode_id = source_episode_resolution.source_episode_id.?;
    if (!std.mem.eql(u8, resolved_source_episode_id, source_episode_id)) {
        return error.SourceEpisodeIdentityMismatch;
    }
    const packet = dcpBody(try object(context_value));
    const anchors = try requiredObject(packet, "anchors");
    const pre = try requiredObject(anchors, "pre_decision");
    if (!try requiredBool(pre, "available")) return error.PreDecisionAnchorUnavailable;
    const packet_id = try requiredString(packet, "packet_id");
    const anchor_digest = try requiredString(pre, "anchor_digest");
    const source_turn_digest = try requiredString(try requiredObject(packet, "turns"), "source_turn_digest");
    try validateFingerprint(source_turn_digest);
    const reconstructability = try requiredString(try requiredObject(packet, "artifact_state"), "reconstructability");
    const declared_reconstructability = try requiredString(profile, "reconstructability");
    if (!std.mem.eql(u8, reconstructability, declared_reconstructability)) {
        return error.ReconstructabilityMismatch;
    }
    const target_text_witness = profile.get("source_target_text_witness") orelse
        return error.TargetTextWitnessMissing;
    const target_text_witness_fingerprint = try validateTargetTextWitness(
        allocator,
        target_text_witness,
        source_ref,
        source_episode_id,
        source_turn_digest,
        context_value,
        try requiredObject(packet, "contamination"),
        policy,
    );
    errdefer allocator.free(target_text_witness_fingerprint);
    return .{
        .governance = governance,
        .packet_id = try allocator.dupe(u8, packet_id),
        .anchor_digest = try allocator.dupe(u8, anchor_digest),
        .reconstructability = try allocator.dupe(u8, reconstructability),
        .source_ref = try allocator.dupe(u8, source_ref),
        .source_episode_id = try allocator.dupe(u8, source_episode_id),
        .source_turn_digest = try allocator.dupe(u8, source_turn_digest),
        .target_text_witness_fingerprint = target_text_witness_fingerprint,
    };
}

pub fn validateFirForLane(
    allocator: std.mem.Allocator,
    fir_value: std.json.Value,
    expected_lane_id: []const u8,
    expected_lineage: []const u8,
    expected_anchor_digest: []const u8,
) !FirReport {
    const root = try object(fir_value);
    try rejectPortfolio(root);
    const fir = if (root.get("fork_inquiry_receipt")) |wrapped| try object(wrapped) else root;
    try rejectPortfolio(fir);
    if (!std.mem.eql(u8, try requiredString(fir, "receipt_version"), fir_version)) {
        return error.FirVersionInvalid;
    }
    const lane_id = try requiredString(fir, "lane_id");
    if (!std.mem.eql(u8, lane_id, expected_lane_id)) return error.FirLaneMismatch;
    const inquiry_id = try requiredString(fir, "inquiry_id");
    const source = try requiredObject(fir, "source");
    const source_episode_id = try requiredString(source, "source_episode_id");
    const lineage_mode = try requiredString(source, "lineage_mode");
    if (!std.mem.eql(u8, expected_lineage, "either") and
        !std.mem.eql(u8, lineage_mode, expected_lineage))
    {
        return error.FirLineageMismatch;
    }
    if (!oneOf(lineage_mode, &.{ "thread_fork", "rollout_transcript" })) {
        return error.FirLineageMismatch;
    }
    const source_turn_digest = try requiredString(source, "source_turn_digest");
    const fork = try requiredObject(fir, "fork");
    const anchor = try requiredObject(fork, "anchor");
    if (!std.mem.eql(u8, try requiredString(anchor, "temporal_horizon"), "pre_decision") or
        !try requiredBool(anchor, "exact"))
    {
        return error.OutcomeAwareDecisionContext;
    }
    const anchor_expected = try requiredString(anchor, "anchor_digest_expected");
    const anchor_observed = try requiredString(anchor, "anchor_digest_observed");
    if (!std.mem.eql(u8, anchor_expected, anchor_observed) or
        !std.mem.eql(u8, anchor_observed, expected_anchor_digest))
    {
        return error.FirAnchorMismatch;
    }
    if (!std.mem.eql(u8, try requiredString(fork, "approval_policy"), "never")) {
        return error.FirPermissionInvalid;
    }
    const inquiry = try requiredObject(fir, "inquiry");
    if (!std.mem.eql(u8, try requiredString(inquiry, "mode"), "replay") or
        !std.mem.eql(u8, try requiredString(inquiry, "status"), "completed"))
    {
        return error.FirInquiryInvalid;
    }
    const answer = try requiredObject(fir, "answer");
    if (try requiredBool(answer, "hindsight_available")) return error.OutcomeAwareDecisionContext;
    const gate = try requiredObject(fir, "gate");
    inline for (.{ "lineage_valid", "anchor_valid", "permissions_valid", "hindsight_label_valid", "answer_complete", "receipt_valid" }) |key| {
        if (!try requiredBool(gate, key)) return error.FirGateInvalid;
    }
    if (try requiredBool(gate, "approval_or_tool_request_observed")) return error.FirGateInvalid;
    return .{
        .lane_id = try allocator.dupe(u8, lane_id),
        .inquiry_id = try allocator.dupe(u8, inquiry_id),
        .lineage_mode = try allocator.dupe(u8, lineage_mode),
        .source_turn_digest = try allocator.dupe(u8, source_turn_digest),
        .anchor_digest = try allocator.dupe(u8, anchor_observed),
        .source_episode_id = try allocator.dupe(u8, source_episode_id),
    };
}

pub fn validateFirForHistoricalLane(
    allocator: std.mem.Allocator,
    fir_value: std.json.Value,
    profile: *const HistoricalProfileReport,
    expected_trial_id: []const u8,
    expected_lane_id: []const u8,
    expected_lineage: []const u8,
) !FirReport {
    if (expected_trial_id.len == 0) return error.EmptyField;
    var report = try validateFirForLane(
        allocator,
        fir_value,
        expected_lane_id,
        expected_lineage,
        profile.anchor_digest,
    );
    errdefer report.deinit(allocator);
    if (!std.mem.eql(u8, report.inquiry_id, expected_trial_id)) return error.FirInquiryMismatch;
    if (!std.mem.eql(u8, report.source_turn_digest, profile.source_turn_digest)) {
        return error.FirSourceEpisodeMismatch;
    }
    if (!std.mem.eql(u8, report.source_episode_id, profile.source_episode_id)) {
        return error.FirSourceEpisodeMismatch;
    }
    report.source_ref = try allocator.dupe(u8, profile.source_ref);
    report.episode_identity_fingerprint = try episodeIdentityFingerprintAlloc(
        allocator,
        profile.source_episode_id,
        profile.source_turn_digest,
        report.source_turn_digest,
        expected_trial_id,
    );
    return report;
}

pub fn episodeIdentityFingerprintAlloc(
    allocator: std.mem.Allocator,
    source_episode_id: []const u8,
    dcp_source_turn_digest: []const u8,
    fir_source_turn_digest: []const u8,
    inquiry_id: []const u8,
) ![]u8 {
    if (source_episode_id.len == 0 or inquiry_id.len == 0) return error.EmptyField;
    try validateFingerprint(dcp_source_turn_digest);
    try validateFingerprint(fir_source_turn_digest);
    if (!std.mem.eql(u8, dcp_source_turn_digest, fir_source_turn_digest)) {
        return error.FirSourceEpisodeMismatch;
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", episode_identity_version);
    hashTagged(&hasher, "source-episode-id", source_episode_id);
    hashTagged(&hasher, "dcp-source-turn", dcp_source_turn_digest);
    hashTagged(&hasher, "fir-source-turn", fir_source_turn_digest);
    hashTagged(&hasher, "inquiry-trial", inquiry_id);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

/// Fingerprint the source owner's minimal direct-episode projection.  The
/// projection is field-tagged so callers cannot substitute an opaque digest
/// for the episode identity that Seq actually selected.
pub fn directSourceEpisodeFingerprintAlloc(
    allocator: std.mem.Allocator,
    source_episode_id: []const u8,
) ![]u8 {
    if (source_episode_id.len == 0) return error.EmptyField;
    const projection = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":{f},\"kind\":\"direct\",\"source_episode_id\":{f}}}",
        .{ std.json.fmt(source_episode_projection_version, .{}), std.json.fmt(source_episode_id, .{}) },
    );
    defer allocator.free(projection);
    return fingerprintSourceEpisodeProjectionAlloc(allocator, projection);
}

/// Fingerprint the canonical historical episode projection after SGG/DCP
/// validation.  The manifest episode id, SGG source ref/id, and DCP episode
/// identity must already denote the same episode before any digest is issued.
pub fn historicalSourceEpisodeFingerprintAlloc(
    allocator: std.mem.Allocator,
    manifest_source_episode_id: []const u8,
    report: *const HistoricalProfileReport,
) ![]u8 {
    if (manifest_source_episode_id.len == 0 or
        !std.mem.eql(u8, manifest_source_episode_id, report.source_episode_id) or
        !std.mem.eql(u8, report.source_ref, report.source_episode_id))
    {
        return error.SourceEpisodeIdentityMismatch;
    }
    try validateFingerprint(report.source_turn_digest);
    try validateFingerprint(report.anchor_digest);
    if (report.packet_id.len == 0) return error.EmptyField;
    const projection = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":{f},\"kind\":\"historical_decision\",\"source_episode_id\":{f},\"source_ref\":{f},\"dcp_source_turn_digest\":{f},\"dcp_packet_id\":{f},\"pre_decision_anchor_digest\":{f}}}",
        .{
            std.json.fmt(source_episode_projection_version, .{}),
            std.json.fmt(report.source_episode_id, .{}),
            std.json.fmt(report.source_ref, .{}),
            std.json.fmt(report.source_turn_digest, .{}),
            std.json.fmt(report.packet_id, .{}),
            std.json.fmt(report.anchor_digest, .{}),
        },
    );
    defer allocator.free(projection);
    return fingerprintSourceEpisodeProjectionAlloc(allocator, projection);
}

fn fingerprintSourceEpisodeProjectionAlloc(
    allocator: std.mem.Allocator,
    projection: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, projection, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    return attestation.digestValueAlloc(allocator, parsed.value);
}

pub fn compileReplayPlanAlloc(
    allocator: std.mem.Allocator,
    decision_context: std.json.Value,
    options: ReplayPlanOptions,
) ![]u8 {
    if (options.maximum_lane_duration_ms == 0 or options.maximum_tokens_per_lane == 0) {
        return error.ReplayBudgetInvalid;
    }
    const packet = dcpBody(try object(decision_context));
    const packet_id = try requiredString(packet, "packet_id");
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"retrace_inquiry_plan\":{");
    try field(&writer.writer, "plan_version", replay_plan_version, true);
    try field(&writer.writer, "inquiry_id", options.inquiry_id, true);
    try field(&writer.writer, "source_capsule", packet_id, true);
    try field(&writer.writer, "objective", "HCTP opaque-arm replay", true);
    try field(&writer.writer, "model_policy", options.model_policy, true);
    try field(&writer.writer, "workspace_policy", options.workspace_policy, true);
    try writer.writer.writeAll("\"permission_policy\":{\"read_only\":true,\"network\":false},");
    try writer.writer.writeAll("\"budgets\":{");
    try writer.writer.print("\"max_forks\":1,\"max_turns_per_fork\":1,\"max_total_tokens\":{d},\"timeout_ms\":{d}", .{
        options.maximum_tokens_per_lane,
        options.maximum_lane_duration_ms,
    });
    try writer.writer.writeAll("},\"lanes\":[{");
    try field(&writer.writer, "lane_id", options.lane_id, true);
    try field(&writer.writer, "temporal_horizon", "pre_decision", true);
    try field(&writer.writer, "inquiry_mode", "replay", true);
    try writer.writer.writeAll("\"fork_count\":1,");
    try field(&writer.writer, "prompt_template", options.prompt_template, true);
    try writer.writer.writeAll("\"evidence_allowed\":[],\"evidence_withheld\":[]}]}}\n");
    return writer.toOwnedSlice();
}

pub fn sanitizeDecisionContextAlloc(
    allocator: std.mem.Allocator,
    decision_context: std.json.Value,
) ![]u8 {
    const canonical = try dcp_schema.canonicalJsonAlloc(allocator, decision_context, false);
    defer allocator.free(canonical);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, canonical, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = try objectPtr(&parsed.value);
    const packet_value = root.getPtr("decision_context_packet") orelse &parsed.value;
    const packet = try objectPtr(packet_value);
    const episode_value = packet.getPtr("episode") orelse return error.DecisionContextMissing;
    const episode = try objectPtr(episode_value);
    inline for (.{
        "rejected_routes",
        "explicit_rationale",
        "explicit_assumptions",
        "evidence_refs",
        "tools_and_artifacts",
        "skills_and_instructions",
        "outcome_refs",
    }) |key| {
        if (episode.getPtr(key)) |field_value| field_value.* = .{ .array = .init(allocator) } else return error.DecisionContextInvalid;
    }
    const contamination_value = packet.getPtr("contamination") orelse return error.DecisionContextInvalid;
    const contamination = try objectPtr(contamination_value);
    inline for (.{ "injected_skill_blocks", "generated_reports", "current_audit_prompt", "quoted_material" }) |key| {
        if (contamination.getPtr(key)) |field_value| field_value.* = .{ .bool = false } else return error.DecisionContextInvalid;
    }
    const packet_id = try dcp_schema.packetIdForValueExcludingPacketId(allocator, parsed.value);
    defer allocator.free(packet_id);
    try packet.put(allocator, "packet_id", .{ .string = packet_id });
    var report = try dcp_schema.validateValue(allocator, parsed.value);
    defer report.deinit(allocator);
    if (!report.valid) return error.DecisionContextInvalid;
    return dcp_schema.canonicalJsonAlloc(allocator, parsed.value, false);
}

fn validateTargetTextWitness(
    allocator: std.mem.Allocator,
    witness_value: std.json.Value,
    expected_source_ref: []const u8,
    expected_source_episode_id: []const u8,
    expected_source_turn_digest: []const u8,
    decision_context: std.json.Value,
    dcp_contamination: std.json.ObjectMap,
    policy: []const u8,
) ![]u8 {
    const witness = try object(witness_value);
    if (!std.mem.eql(u8, try requiredString(witness, "schema"), target_text_witness_version)) {
        return error.TargetTextWitnessSchemaInvalid;
    }
    if (!std.mem.eql(u8, try requiredString(witness, "source_ref"), expected_source_ref) or
        !std.mem.eql(u8, try requiredString(witness, "source_episode_id"), expected_source_episode_id) or
        !std.mem.eql(u8, try requiredString(witness, "source_turn_digest"), expected_source_turn_digest))
    {
        return error.TargetTextWitnessLineageMismatch;
    }
    const dcp_contamination_value = std.json.Value{ .object = dcp_contamination };
    const contamination_canonical = try dcp_schema.canonicalJsonAlloc(
        allocator,
        dcp_contamination_value,
        false,
    );
    defer allocator.free(contamination_canonical);
    const contamination_fingerprint = try digestBytesAlloc(allocator, contamination_canonical);
    defer allocator.free(contamination_fingerprint);
    const declared_contamination_fingerprint = try requiredString(witness, "dcp_contamination_fingerprint");
    try validateFingerprint(declared_contamination_fingerprint);
    _ = try requiredString(witness, "evidence_ref");

    const contamination = try requiredObject(witness, "contamination");
    const source_target_text_present = try requiredBool(contamination, "source_target_text_present");
    const within_anchor = try requiredBool(contamination, "within_pre_decision_anchor");
    if (within_anchor and !source_target_text_present) return error.TargetTextWitnessInvalid;
    const sanitization = try requiredObject(witness, "sanitization");
    const sanitization_applied = try requiredBool(sanitization, "applied");
    const sanitized_context = sanitization.get("sanitized_context_fingerprint") orelse
        return error.MissingField;
    const target_instruction_count = try requiredUnsigned(sanitization, "target_instruction_count");
    if (target_instruction_count != 1) return error.SourceTargetTextSanitizationInvalid;

    if (std.mem.eql(u8, policy, "absent")) {
        if (!std.mem.eql(u8, declared_contamination_fingerprint, contamination_fingerprint)) {
            return error.DerivedContaminationWitnessMismatch;
        }
        if (source_target_text_present or within_anchor or sanitization_applied or sanitized_context != .null) {
            return error.SourceTargetTextSanitizationInvalid;
        }
    } else if (std.mem.eql(u8, policy, "preserve")) {
        if (!std.mem.eql(u8, declared_contamination_fingerprint, contamination_fingerprint)) {
            return error.DerivedContaminationWitnessMismatch;
        }
        if (!source_target_text_present or within_anchor or sanitization_applied or sanitized_context != .null) {
            return error.SourceTargetTextSanitizationInvalid;
        }
    } else if (std.mem.eql(u8, policy, "strip_and_replace")) {
        if (!source_target_text_present or !sanitization_applied) {
            return error.SourceTargetTextSanitizationInvalid;
        }
        const fingerprint = switch (sanitized_context) {
            .string => |text| text,
            else => return error.SourceTargetTextSanitizationInvalid,
        };
        try validateFingerprint(fingerprint);
        const sanitized_json = try dcp_schema.canonicalJsonAlloc(allocator, decision_context, false);
        defer allocator.free(sanitized_json);
        const observed_fingerprint = try digestBytesAlloc(allocator, sanitized_json);
        defer allocator.free(observed_fingerprint);
        if (!std.mem.eql(u8, fingerprint, observed_fingerprint)) {
            return error.SourceTargetTextSanitizationInvalid;
        }
        inline for (.{ "injected_skill_blocks", "generated_reports", "current_audit_prompt", "quoted_material" }) |key| {
            if (try requiredBool(dcp_contamination, key)) return error.SourceTargetTextSanitizationInvalid;
        }
    } else unreachable;

    const witness_canonical = try dcp_schema.canonicalJsonAlloc(allocator, witness_value, false);
    defer allocator.free(witness_canonical);
    return digestBytesAlloc(allocator, witness_canonical);
}

fn rejectPortfolio(value: std.json.ObjectMap) !void {
    if (value.get("forks") != null or value.get("portfolio") != null) {
        return error.HiddenForkPortfolio;
    }
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn hashTagged(hasher: *std.crypto.hash.sha2.Sha256, tag: []const u8, value: []const u8) void {
    hasher.update(tag);
    hasher.update(&.{0});
    hasher.update(value);
    hasher.update(&.{0xff});
}

fn validateFingerprint(value: []const u8) !void {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) {
        return error.InvalidFingerprint;
    }
    for (value[7..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
            return error.InvalidFingerprint;
        }
    }
}

fn field(writer: anytype, name: []const u8, value: []const u8, comma: bool) !void {
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
    if (comma) try writer.writeByte(',');
}

fn parseGovernanceState(raw: []const u8) ?SourceGovernanceState {
    inline for (std.meta.fields(SourceGovernanceState)) |entry| {
        if (std.mem.eql(u8, raw, entry.name)) return @enumFromInt(entry.value);
    }
    return null;
}

fn dcpBody(root: std.json.ObjectMap) std.json.ObjectMap {
    if (root.get("decision_context_packet")) |wrapped| return object(wrapped) catch root;
    return root;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |value_object| value_object,
        else => error.ExpectedObject,
    };
}

fn objectPtr(value: *std.json.Value) !*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*value_object| value_object,
        else => error.ExpectedObject,
    };
}

fn requiredObject(parent: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(parent.get(key) orelse return error.MissingField);
}

fn requiredArray(parent: std.json.ObjectMap, key: []const u8) !std.json.Array {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .array => |array| array,
        else => error.ExpectedArray,
    };
}

fn requiredString(parent: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .string => |text| if (text.len == 0) error.EmptyField else text,
        else => error.ExpectedString,
    };
}

fn requiredBool(parent: std.json.ObjectMap, key: []const u8) !bool {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.ExpectedBool,
    };
}

fn requiredUnsigned(parent: std.json.ObjectMap, key: []const u8) !u64 {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.ExpectedUnsigned,
        else => error.ExpectedUnsigned,
    };
}

fn listContains(array: std.json.Array, wanted: []const u8) bool {
    for (array.items) |value| switch (value) {
        .string => |text| if (std.mem.eql(u8, text, wanted)) return true,
        else => {},
    };
    return false;
}

fn containsString(values: []const []u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

test "source governance rejects replay authority contradictions" {
    const raw =
        \\{"source_governance_gate":{"gate_version":"SGG-v1","verdict":{"state":"incidental","replay_allowed":true,"allowed_modes":["replay"]}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.SourceGovernanceReplayForbidden, validateSourceGovernance(parsed.value));
}

test "replay plan contains one lane and one fork" {
    const raw =
        \\{"decision_context_packet":{"packet_version":"DCP-v2","packet_id":"DCP-one"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const plan = try compileReplayPlanAlloc(std.testing.allocator, parsed.value, .{
        .inquiry_id = "inquiry-one",
        .lane_id = "lane-one",
        .prompt_template = "replay the registered decision",
        .workspace_policy = "transcript_only",
        .maximum_lane_duration_ms = 1000,
        .maximum_tokens_per_lane = 100,
    });
    defer std.testing.allocator.free(plan);
    try std.testing.expect(std.mem.indexOf(u8, plan, "\"fork_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "\"inquiry_mode\":\"replay\"") != null);
}

test "FIR validation admits exactly one blind pre-decision replay" {
    const raw =
        \\{"fork_inquiry_receipt":{"receipt_version":"FIR-v1","receipt_id":"FIR-lane-one-1","inquiry_id":"trial-one","lane_id":"lane-one","source":{"source_episode_id":"session:one#turn:one","source_turn_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","lineage_mode":"rollout_transcript"},"fork":{"approval_policy":"never","anchor":{"temporal_horizon":"pre_decision","exact":true,"anchor_digest_expected":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","anchor_digest_observed":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},"inquiry":{"mode":"replay","status":"completed"},"answer":{"hindsight_available":false},"gate":{"lineage_valid":true,"anchor_valid":true,"permissions_valid":true,"approval_or_tool_request_observed":false,"hindsight_label_valid":true,"answer_complete":true,"receipt_valid":true}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    var report = try validateFirForLane(
        std.testing.allocator,
        parsed.value,
        "lane-one",
        "either",
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("lane-one", report.lane_id);

    const portfolio = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        raw,
        "{\"fork_inquiry_receipt\"",
        "{\"portfolio\":[],\"fork_inquiry_receipt\"",
    );
    defer std.testing.allocator.free(portfolio);
    var portfolio_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, portfolio, .{});
    defer portfolio_parsed.deinit();
    try std.testing.expectError(
        error.HiddenForkPortfolio,
        validateFirForLane(
            std.testing.allocator,
            portfolio_parsed.value,
            "lane-one",
            "either",
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ),
    );
}

const TestDcpTemplate =
    \\{"decision_context_packet":{
    \\"packet_version":"DCP-v2","packet_id":"DCP-placeholder",
    \\"source":{"session_id":"one","decision_id":"decision-one","source_episode_id":"session:one#turn:one"},
    \\"artifact_state":{"reconstructability":"transcript_only"},
    \\"episode":{"question":"Which route should be selected?","selected_route":"route-a","rejected_routes":[],"explicit_rationale":[],"explicit_assumptions":[],"evidence_refs":[],"tools_and_artifacts":[],"skills_and_instructions":[],"outcome_refs":[]},
    \\"turns":{"total_turns":3,"decision_turn_index":2,"decision_turn_id":"one","first_outcome_turn_index":3,"source_turn_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    \\"anchors":{"pre_decision":{"available":true,"keep_through_turn_index":1,"drop_last_n_turns":2,"anchor_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"post_decision_pre_outcome":{"available":true,"keep_through_turn_index":2,"drop_last_n_turns":1,"anchor_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"outcome_aware":{"available":true,"keep_through_turn_index":3,"drop_last_n_turns":0,"anchor_digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}},
    \\"contamination":{"injected_skill_blocks":false,"generated_reports":false,"current_audit_prompt":false,"quoted_material":false},
    \\"limitations":[]}}
;

const TestFir =
    \\{"fork_inquiry_receipt":{"receipt_version":"FIR-v1","receipt_id":"FIR-lane-one-1","inquiry_id":"trial-one","lane_id":"lane-one","source":{"source_episode_id":"session:one#turn:one","source_turn_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","lineage_mode":"rollout_transcript"},"fork":{"approval_policy":"never","anchor":{"temporal_horizon":"pre_decision","exact":true,"anchor_digest_expected":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","anchor_digest_observed":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},"inquiry":{"mode":"replay","status":"completed"},"answer":{"hindsight_available":false},"gate":{"lineage_valid":true,"anchor_valid":true,"permissions_valid":true,"approval_or_tool_request_observed":false,"hindsight_label_valid":true,"answer_complete":true,"receipt_valid":true}}}
;

const TestAnchorDigest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn replaceOneAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (std.mem.count(u8, bytes, needle) != 1) return error.TestFixtureShapeChanged;
    return std.mem.replaceOwned(u8, allocator, bytes, needle, replacement);
}

fn historicalProfileForDcpTemplateAlloc(allocator: std.mem.Allocator, dcp_template: []const u8) ![]u8 {
    const packet_id = try dcp_schema.packetIdForTextExcludingPacketId(allocator, dcp_template);
    defer allocator.free(packet_id);
    const dcp = try replaceOneAlloc(allocator, dcp_template, "DCP-placeholder", packet_id);
    defer allocator.free(dcp);
    var dcp_parsed = try std.json.parseFromSlice(std.json.Value, allocator, dcp, .{});
    defer dcp_parsed.deinit();
    const packet = dcpBody(try object(dcp_parsed.value));
    const contamination = try requiredObject(packet, "contamination");
    const contamination_json = try dcp_schema.canonicalJsonAlloc(
        allocator,
        .{ .object = contamination },
        false,
    );
    defer allocator.free(contamination_json);
    const contamination_fingerprint = try digestBytesAlloc(allocator, contamination_json);
    defer allocator.free(contamination_fingerprint);
    const governance =
        \\{"source_governance_gate":{"gate_version":"SGG-v1","source_ref":"session:one#turn:one","source_episode_id":"session:one#turn:one","evidence_fingerprint":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","verdict":{"state":"authoritative","replay_allowed":true,"allowed_modes":["replay"]},"limitations":[]}}
    ;
    return std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"historical_decision\",\"source_governance\":{s},\"decision_context\":{s},\"temporal_horizon\":\"pre_decision\",\"source_target_text_policy\":\"absent\",\"source_target_text_witness\":{{\"schema\":\"{s}\",\"source_ref\":\"session:one#turn:one\",\"source_episode_id\":\"session:one#turn:one\",\"source_turn_digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"dcp_contamination_fingerprint\":\"{s}\",\"evidence_ref\":\"seq:target-text-derivation\",\"contamination\":{{\"source_target_text_present\":false,\"within_pre_decision_anchor\":false}},\"sanitization\":{{\"applied\":false,\"sanitized_context_fingerprint\":null,\"target_instruction_count\":1}}}},\"retrace_mode\":\"replay\",\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\",\"reconstructability\":\"transcript_only\"}}",
        .{ governance, dcp, target_text_witness_version, contamination_fingerprint },
    );
}

fn validHistoricalProfileAlloc(allocator: std.mem.Allocator) ![]u8 {
    return historicalProfileForDcpTemplateAlloc(allocator, TestDcpTemplate);
}

test "historical lane binds SGG DCP FIR and trial into one canonical episode identity" {
    const profile_bytes = try validHistoricalProfileAlloc(std.testing.allocator);
    defer std.testing.allocator.free(profile_bytes);
    var profile_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, profile_bytes, .{});
    defer profile_parsed.deinit();
    var profile = try validateHistoricalProfile(std.testing.allocator, profile_parsed.value, true);
    defer profile.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("session:one#turn:one", profile.source_ref);
    try std.testing.expectEqualStrings(
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        profile.source_turn_digest,
    );
    try validateFingerprint(profile.target_text_witness_fingerprint);
    const source_episode_fingerprint = try historicalSourceEpisodeFingerprintAlloc(
        std.testing.allocator,
        "session:one#turn:one",
        &profile,
    );
    defer std.testing.allocator.free(source_episode_fingerprint);
    try validateFingerprint(source_episode_fingerprint);
    try std.testing.expectError(
        error.SourceEpisodeIdentityMismatch,
        historicalSourceEpisodeFingerprintAlloc(
            std.testing.allocator,
            "session:manifest#turn:different",
            &profile,
        ),
    );

    var fir_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, TestFir, .{});
    defer fir_parsed.deinit();
    var fir = try validateFirForHistoricalLane(
        std.testing.allocator,
        fir_parsed.value,
        &profile,
        "trial-one",
        "lane-one",
        "either",
    );
    defer fir.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("trial-one", fir.inquiry_id);
    try std.testing.expectEqualStrings(profile.source_ref, fir.source_ref.?);
    try validateFingerprint(fir.episode_identity_fingerprint.?);
    const repeated = try episodeIdentityFingerprintAlloc(
        std.testing.allocator,
        profile.source_ref,
        profile.source_turn_digest,
        fir.source_turn_digest,
        fir.inquiry_id,
    );
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(fir.episode_identity_fingerprint.?, repeated);

    try std.testing.expectError(
        error.FirInquiryMismatch,
        validateFirForHistoricalLane(
            std.testing.allocator,
            fir_parsed.value,
            &profile,
            "trial-other",
            "lane-one",
            "either",
        ),
    );
    const different_source = try replaceOneAlloc(
        std.testing.allocator,
        TestFir,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
    defer std.testing.allocator.free(different_source);
    var different_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, different_source, .{});
    defer different_parsed.deinit();
    try std.testing.expectError(
        error.FirSourceEpisodeMismatch,
        validateFirForHistoricalLane(
            std.testing.allocator,
            different_parsed.value,
            &profile,
            "trial-one",
            "lane-one",
            "either",
        ),
    );
}

test "historical profile rejects SGG and DCP episode disagreement" {
    const profile_bytes = try validHistoricalProfileAlloc(std.testing.allocator);
    defer std.testing.allocator.free(profile_bytes);
    const governance_identity = "\"source_ref\":\"session:one#turn:one\",\"source_episode_id\":\"session:one#turn:one\"";
    if (std.mem.count(u8, profile_bytes, governance_identity) != 2) return error.TestFixtureShapeChanged;
    const mismatched = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        profile_bytes,
        governance_identity,
        "\"source_ref\":\"session:sgg#turn:different\",\"source_episode_id\":\"session:sgg#turn:different\"",
    );
    defer std.testing.allocator.free(mismatched);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mismatched, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.SourceEpisodeIdentityMismatch,
        validateHistoricalProfile(std.testing.allocator, parsed.value, true),
    );
}

test "historical profile admits derived DCP-v2 identity and rejects mismatch or unavailable identity" {
    const derived_template = try replaceOneAlloc(
        std.testing.allocator,
        TestDcpTemplate,
        ",\"source_episode_id\":\"session:one#turn:one\"",
        "",
    );
    defer std.testing.allocator.free(derived_template);
    const derived_profile_bytes = try historicalProfileForDcpTemplateAlloc(std.testing.allocator, derived_template);
    defer std.testing.allocator.free(derived_profile_bytes);
    var derived_profile_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, derived_profile_bytes, .{});
    defer derived_profile_parsed.deinit();
    var derived_profile = try validateHistoricalProfile(std.testing.allocator, derived_profile_parsed.value, true);
    defer derived_profile.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("session:one#turn:one", derived_profile.source_episode_id);

    const mismatch_template = try replaceOneAlloc(
        std.testing.allocator,
        TestDcpTemplate,
        "\"source_episode_id\":\"session:one#turn:one\"",
        "\"source_episode_id\":\"session:different#turn:one\"",
    );
    defer std.testing.allocator.free(mismatch_template);
    const mismatch_profile_bytes = try historicalProfileForDcpTemplateAlloc(std.testing.allocator, mismatch_template);
    defer std.testing.allocator.free(mismatch_profile_bytes);
    var mismatch_profile_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mismatch_profile_bytes, .{});
    defer mismatch_profile_parsed.deinit();
    try std.testing.expectError(
        error.SourceEpisodeIdentityMismatch,
        validateHistoricalProfile(std.testing.allocator, mismatch_profile_parsed.value, true),
    );

    const unavailable_source = try replaceOneAlloc(
        std.testing.allocator,
        derived_template,
        "\"session_id\":\"one\"",
        "\"rollout_path\":\"/tmp/source.jsonl\"",
    );
    defer std.testing.allocator.free(unavailable_source);
    const unavailable_template = try replaceOneAlloc(
        std.testing.allocator,
        unavailable_source,
        ",\"decision_turn_id\":\"one\"",
        "",
    );
    defer std.testing.allocator.free(unavailable_template);
    const unavailable_profile_bytes = try historicalProfileForDcpTemplateAlloc(std.testing.allocator, unavailable_template);
    defer std.testing.allocator.free(unavailable_profile_bytes);
    var unavailable_profile_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unavailable_profile_bytes, .{});
    defer unavailable_profile_parsed.deinit();
    try std.testing.expectError(
        error.SourceEpisodeIdentityUnavailable,
        validateHistoricalProfile(std.testing.allocator, unavailable_profile_parsed.value, true),
    );
}

test "FIR rejects portfolio fields on both wrapper and normalized receipt" {
    inline for (.{ "portfolio", "forks" }) |field_name| {
        const wrapper_prefix = try std.fmt.allocPrint(std.testing.allocator, "{{\"{s}\":[],\"fork_inquiry_receipt\"", .{field_name});
        defer std.testing.allocator.free(wrapper_prefix);
        const wrapper = try replaceOneAlloc(
            std.testing.allocator,
            TestFir,
            "{\"fork_inquiry_receipt\"",
            wrapper_prefix,
        );
        defer std.testing.allocator.free(wrapper);
        var wrapper_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, wrapper, .{});
        defer wrapper_parsed.deinit();
        try std.testing.expectError(
            error.HiddenForkPortfolio,
            validateFirForLane(std.testing.allocator, wrapper_parsed.value, "lane-one", "either", TestAnchorDigest),
        );

        const normalized_prefix = try std.fmt.allocPrint(std.testing.allocator, "{{\"{s}\":[],\"receipt_version\"", .{field_name});
        defer std.testing.allocator.free(normalized_prefix);
        const normalized = try replaceOneAlloc(
            std.testing.allocator,
            TestFir,
            "{\"receipt_version\"",
            normalized_prefix,
        );
        defer std.testing.allocator.free(normalized);
        var normalized_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, normalized, .{});
        defer normalized_parsed.deinit();
        try std.testing.expectError(
            error.HiddenForkPortfolio,
            validateFirForLane(std.testing.allocator, normalized_parsed.value, "lane-one", "either", TestAnchorDigest),
        );
    }
}

test "historical profile requires derived target text contamination and sanitization witness" {
    const profile_bytes = try validHistoricalProfileAlloc(std.testing.allocator);
    defer std.testing.allocator.free(profile_bytes);

    var missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, profile_bytes, .{});
    defer missing.deinit();
    _ = missing.value.object.orderedRemove("source_target_text_witness");
    try std.testing.expectError(
        error.TargetTextWitnessMissing,
        validateHistoricalProfile(std.testing.allocator, missing.value, true),
    );

    const wrong_derived = try replaceOneAlloc(
        std.testing.allocator,
        profile_bytes,
        "\"dcp_contamination_fingerprint\":\"sha256:",
        "\"dcp_contamination_fingerprint\":\"sha256:0",
    );
    defer std.testing.allocator.free(wrong_derived);
    var wrong_derived_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, wrong_derived, .{});
    defer wrong_derived_parsed.deinit();
    try std.testing.expectError(
        error.InvalidFingerprint,
        validateHistoricalProfile(std.testing.allocator, wrong_derived_parsed.value, true),
    );

    var mismatched_source = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, profile_bytes, .{});
    defer mismatched_source.deinit();
    const mismatched_profile = try objectPtr(&mismatched_source.value);
    const governance_value = mismatched_profile.getPtr("source_governance") orelse return error.MissingField;
    const governance_root = try objectPtr(governance_value);
    const gate_value = governance_root.getPtr("source_governance_gate") orelse return error.MissingField;
    const gate = try objectPtr(gate_value);
    (gate.getPtr("source_ref") orelse return error.MissingField).* = .{ .string = "session:different" };
    try std.testing.expectError(
        error.SourceEpisodeIdentityMismatch,
        validateHistoricalProfile(std.testing.allocator, mismatched_source.value, true),
    );

    var invalid_sanitization = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, profile_bytes, .{});
    defer invalid_sanitization.deinit();
    const profile_root = try objectPtr(&invalid_sanitization.value);
    const witness_value = profile_root.getPtr("source_target_text_witness") orelse return error.MissingField;
    const witness = try objectPtr(witness_value);
    const sanitization_value = witness.getPtr("sanitization") orelse return error.MissingField;
    const sanitization = try objectPtr(sanitization_value);
    (sanitization.getPtr("applied") orelse return error.MissingField).* = .{ .bool = true };
    try std.testing.expectError(
        error.SourceTargetTextSanitizationInvalid,
        validateHistoricalProfile(std.testing.allocator, invalid_sanitization.value, true),
    );
}

test "strip and replace materializes a target-free fingerprintable DCP" {
    const with_target = try replaceOneAlloc(
        std.testing.allocator,
        TestDcpTemplate,
        "\"skills_and_instructions\":[]",
        "\"skills_and_instructions\":[\"TARGET-ONLY-INSTRUCTION-MUST-NOT-SURVIVE\"]",
    );
    defer std.testing.allocator.free(with_target);
    const contaminated = try replaceOneAlloc(
        std.testing.allocator,
        with_target,
        "\"injected_skill_blocks\":false",
        "\"injected_skill_blocks\":true",
    );
    defer std.testing.allocator.free(contaminated);
    const packet_id = try dcp_schema.packetIdForTextExcludingPacketId(std.testing.allocator, contaminated);
    defer std.testing.allocator.free(packet_id);
    const valid = try replaceOneAlloc(std.testing.allocator, contaminated, "DCP-placeholder", packet_id);
    defer std.testing.allocator.free(valid);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const sanitized = try sanitizeDecisionContextAlloc(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(sanitized);
    try std.testing.expect(std.mem.indexOf(u8, sanitized, "TARGET-ONLY-INSTRUCTION-MUST-NOT-SURVIVE") == null);
    var report = try dcp_schema.validateText(std.testing.allocator, sanitized);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.valid);
    var sanitized_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sanitized, .{});
    defer sanitized_parsed.deinit();
    const packet = dcpBody(try object(sanitized_parsed.value));
    const contamination = try requiredObject(packet, "contamination");
    inline for (.{ "injected_skill_blocks", "generated_reports", "current_audit_prompt", "quoted_material" }) |key| {
        try std.testing.expect(!(try requiredBool(contamination, key)));
    }
}
