const std = @import("std");
const retrace_core = @import("retrace_core");
const compiler = @import("causal_frontier_compiler.zig");

const canonical_json = retrace_core.canonical_json;

const StoredArtifact = struct {
    id: []u8,
    json: []u8,

    fn deinit(self: *StoredArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.json);
    }
};

pub const State = struct {
    failure_signatures: std.ArrayList(StoredArtifact) = .empty,
    hypotheses: std.ArrayList(StoredArtifact) = .empty,
    hypothesis_history: std.ArrayList(StoredArtifact) = .empty,
    experiments: std.ArrayList(StoredArtifact) = .empty,
    experiment_history: std.ArrayList(StoredArtifact) = .empty,
    recorded_next_steps: std.ArrayList(StoredArtifact) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.failure_signatures.items) |*item| item.deinit(allocator);
        self.failure_signatures.deinit(allocator);
        for (self.hypotheses.items) |*item| item.deinit(allocator);
        self.hypotheses.deinit(allocator);
        for (self.hypothesis_history.items) |*item| item.deinit(allocator);
        self.hypothesis_history.deinit(allocator);
        for (self.experiments.items) |*item| item.deinit(allocator);
        self.experiments.deinit(allocator);
        for (self.experiment_history.items) |*item| item.deinit(allocator);
        self.experiment_history.deinit(allocator);
        for (self.recorded_next_steps.items) |*item| item.deinit(allocator);
        self.recorded_next_steps.deinit(allocator);
    }
};

pub const Context = struct {
    campaign_id: []const u8,
    current_bundle_fingerprint: []const u8,
    runtime_fingerprint: []const u8,
    admitted_bundle_fingerprints: []const []const u8,
    allowed_paths: []const []const u8,
    practice_evidence_refs: []const []const u8,
    holdout_evidence_refs: []const []const u8,
    admitted_scenario_ids: []const []const u8,
    replay_eligible_scenario_ids: []const []const u8,
    rubric_dimension_ids: []const []const u8,
    satisfied_applicability_conditions: []const []const u8,
    target_change_authorized: bool,
    holdout_exposed: bool,
    remaining_attempts: u64,
    holdout_attempt_capacity: u64,
    reconstruction_ready: bool,
    frontier_fingerprint_basis: []const u8,
};

const FailureSignatureInput = struct {
    schema: []const u8,
    failure_signature_id: []const u8,
    name: []const u8,
    observable_predicate: std.json.Value,
    episode_family_refs: []const []const u8,
    dimension_refs: []const []const u8,
    hard_gate_refs: []const []const u8,
    evidence_refs: []const []const u8,
};

const HypothesisContextInput = struct {
    target_bundle_fingerprint: []const u8,
    runtime_fingerprint: []const u8,
    applicability_conditions: []const []const u8,
};

const HypothesisMechanismInput = struct {
    claim: []const u8,
    failure_signature_ids: []const []const u8,
    evidence_refs: []const []const u8,
    causal_cut_points: []const []const u8,
};

const HypothesisScopeInput = struct {
    affected_episode_families: []const []const u8,
    affected_dimensions: []const []const u8,
    protected_dimensions: []const []const u8,
};

const HypothesisInterventionInput = struct {
    kind: []const u8,
    semantic_surface: []const u8,
    allowed_paths: []const []const u8,
    reversible: bool,
};

const HypothesisInput = struct {
    schema: []const u8,
    hypothesis_id: []const u8,
    campaign_id: []const u8,
    context: HypothesisContextInput,
    mechanism: HypothesisMechanismInput,
    predicted_scope: HypothesisScopeInput,
    candidate_intervention: HypothesisInterventionInput,
    falsifiers: []const std.json.Value,
    status: []const u8,
};

const SemanticChangeBudgetInput = struct {
    rules_added: u64,
    rules_removed: u64,
    sections_touched: u64,
};

const ExperimentInterventionInput = struct {
    description: []const u8,
    allowed_paths: []const []const u8,
    semantic_change_budget: SemanticChangeBudgetInput,
    reversible: bool,
    route_fingerprint: []const u8,
    applicability_fingerprint: []const u8,
    parent_bundle_fingerprint: ?[]const u8 = null,
    candidate_bundle_fingerprint: ?[]const u8 = null,
};

const PredictionInput = struct {
    scenario_id: []const u8,
    dimension_id: []const u8,
    direction: []const u8,
    critical: bool,
};

const ControlInput = struct {
    scenario_id: []const u8,
    dimension_id: []const u8,
    allowed_direction: []const u8,
};

const ExperimentBudgetInput = struct {
    practice_attempts: u64,
    holdout_attempts_reserved: u64,
};

const DecisionDimensionsInput = struct {
    evidence: []const u8,
    discriminability: []const u8,
    scope: []const u8,
    coverage: []const u8,
    reversibility: []const u8,
    risk: []const u8,
    cost: []const u8,
};

const ExperimentInput = struct {
    schema: []const u8,
    experiment_id: []const u8,
    campaign_id: []const u8,
    kind: []const u8,
    status: []const u8,
    hypothesis_ids: []const []const u8,
    evidence_refs: []const []const u8,
    intervention: ExperimentInterventionInput,
    predictions: []const PredictionInput,
    controls: []const ControlInput,
    falsifiers: []const std.json.Value,
    budget: ExperimentBudgetInput,
    decision_dimensions: DecisionDimensionsInput,
    discriminates_hypotheses: []const []const u8 = &.{},
    selection_basis_ref: ?[]const u8 = null,
};

fn parseValueAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !std.json.Parsed(T) {
    const json = try canonical_json.canonicalJsonAlloc(allocator, value);
    defer allocator.free(json);
    return std.json.parseFromSlice(T, allocator, json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

fn parseStoredAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    artifact: StoredArtifact,
) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, artifact.json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

fn nonblank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

fn contains(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn validateUniqueNonblank(values: []const []const u8, required: bool) !void {
    if (required and values.len == 0) return error.RequiredListEmpty;
    for (values, 0..) |value, index| {
        if (!nonblank(value)) return error.InvalidIdentifier;
        for (values[0..index]) |prior| if (std.mem.eql(u8, value, prior)) return error.DuplicateIdentifier;
    }
}

fn storedContains(items: []const StoredArtifact, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn storedIndex(items: []const StoredArtifact, id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.id, id)) return index;
    }
    return null;
}

fn ownedStored(
    allocator: std.mem.Allocator,
    id: []const u8,
    value: std.json.Value,
) !StoredArtifact {
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const json = try canonical_json.canonicalJsonAlloc(allocator, value);
    errdefer allocator.free(json);
    return .{ .id = owned_id, .json = json };
}

fn appendStored(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(StoredArtifact),
    id: []const u8,
    value: std.json.Value,
) !void {
    if (storedContains(items.items, id)) return error.DuplicateArtifact;
    var artifact = try ownedStored(allocator, id, value);
    errdefer artifact.deinit(allocator);
    try items.append(allocator, artifact);
}

fn canonicalWithoutStatusAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    const canonical = try canonical_json.canonicalJsonAlloc(allocator, value);
    defer allocator.free(canonical);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, canonical, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |*map| map,
        else => return error.ArtifactInvalid,
    };
    const status = object.getPtr("status") orelse return error.ArtifactInvalid;
    status.* = .{ .string = "" };
    return canonical_json.canonicalJsonAlloc(allocator, parsed.value);
}

fn legalStatusTransition(from: []const u8, to: []const u8) bool {
    if (std.mem.eql(u8, from, to)) return false;
    if (std.mem.eql(u8, from, "proposed")) {
        return contains(&.{ "eligible", "inconclusive", "refuted", "inapplicable", "superseded" }, to);
    }
    if (std.mem.eql(u8, from, "eligible")) {
        return contains(&.{ "supported", "refuted", "inconclusive", "inapplicable", "superseded" }, to);
    }
    if (std.mem.eql(u8, from, "inconclusive")) {
        return contains(&.{ "eligible", "refuted", "inapplicable", "superseded" }, to);
    }
    if (std.mem.eql(u8, from, "supported")) return std.mem.eql(u8, to, "superseded");
    return false;
}

fn appendOrTransitionStored(
    allocator: std.mem.Allocator,
    current: *std.ArrayList(StoredArtifact),
    history: *std.ArrayList(StoredArtifact),
    id: []const u8,
    prior_status: ?[]const u8,
    next_status: []const u8,
    value: std.json.Value,
) !void {
    const index = storedIndex(current.items, id) orelse {
        var artifact = try ownedStored(allocator, id, value);
        errdefer artifact.deinit(allocator);
        try current.append(allocator, artifact);
        return;
    };
    const previous_status = prior_status orelse return error.ArtifactStatusMissing;
    if (!legalStatusTransition(previous_status, next_status)) return error.IllegalStatusTransition;

    var prior_parsed = try std.json.parseFromSlice(std.json.Value, allocator, current.items[index].json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer prior_parsed.deinit();
    const prior_core = try canonicalWithoutStatusAlloc(allocator, prior_parsed.value);
    defer allocator.free(prior_core);
    const next_core = try canonicalWithoutStatusAlloc(allocator, value);
    defer allocator.free(next_core);
    if (!std.mem.eql(u8, prior_core, next_core)) return error.ArtifactIdentityMutation;

    var replacement = try ownedStored(allocator, id, value);
    errdefer replacement.deinit(allocator);
    try history.append(allocator, current.items[index]);
    current.items[index] = replacement;
}

pub fn inputFingerprintAlloc(allocator: std.mem.Allocator, state: *const State) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"failure_signatures\":[");
    for (state.failure_signatures.items, 0..) |artifact, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(artifact.json);
    }
    try writer.writeAll("],\"hypotheses\":[");
    for (state.hypotheses.items, 0..) |artifact, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(artifact.json);
    }
    try writer.writeAll("],\"hypothesis_history\":[");
    for (state.hypothesis_history.items, 0..) |artifact, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(artifact.json);
    }
    try writer.writeAll("],\"experiments\":[");
    for (state.experiments.items, 0..) |artifact, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(artifact.json);
    }
    try writer.writeAll("],\"experiment_history\":[");
    for (state.experiment_history.items, 0..) |artifact, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(artifact.json);
    }
    try writer.writeAll("]}");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const canonical = try canonical_json.canonicalJsonAlloc(allocator, parsed.value);
    defer allocator.free(canonical);
    return canonical_json.digestBytesAlloc(allocator, canonical);
}

pub fn applyFailureSignature(
    allocator: std.mem.Allocator,
    state: *State,
    value: std.json.Value,
) !void {
    var parsed = try parseValueAs(FailureSignatureInput, allocator, value);
    defer parsed.deinit();
    const input = parsed.value;
    if (!std.mem.eql(u8, input.schema, "hylo-failure-signature/v1") or
        !nonblank(input.failure_signature_id) or !nonblank(input.name) or
        input.observable_predicate != .object)
    {
        return error.FailureSignatureInvalid;
    }
    try validateUniqueNonblank(input.episode_family_refs, true);
    try validateUniqueNonblank(input.dimension_refs, false);
    try validateUniqueNonblank(input.hard_gate_refs, false);
    try validateUniqueNonblank(input.evidence_refs, true);
    try appendStored(allocator, &state.failure_signatures, input.failure_signature_id, value);
}

fn validHypothesisStatus(status: []const u8) bool {
    return contains(&.{ "proposed", "eligible", "supported", "refuted", "inconclusive", "superseded", "inapplicable" }, status);
}

fn validFalsifier(value: std.json.Value) bool {
    const object = switch (value) {
        .object => |map| map,
        else => return false,
    };
    if (object.count() == 0) return false;
    const kind = switch (object.get("kind") orelse return false) {
        .string => |text| text,
        else => return false,
    };
    return nonblank(kind);
}

pub fn applyHypothesis(
    allocator: std.mem.Allocator,
    state: *State,
    value: std.json.Value,
) !void {
    var parsed = try parseValueAs(HypothesisInput, allocator, value);
    defer parsed.deinit();
    const input = parsed.value;
    if (!std.mem.eql(u8, input.schema, "hylo-causal-hypothesis/v1") or
        !nonblank(input.hypothesis_id) or !nonblank(input.campaign_id) or
        !canonical_json.isFingerprint(input.context.target_bundle_fingerprint) or
        !canonical_json.isFingerprint(input.context.runtime_fingerprint) or
        !nonblank(input.mechanism.claim) or input.falsifiers.len == 0 or
        !validHypothesisStatus(input.status) or
        !nonblank(input.candidate_intervention.kind) or
        !nonblank(input.candidate_intervention.semantic_surface))
    {
        return error.HypothesisInvalid;
    }
    for (input.falsifiers) |falsifier| {
        if (!validFalsifier(falsifier)) return error.FalsifierInvalid;
    }
    try validateUniqueNonblank(input.mechanism.failure_signature_ids, true);
    for (input.mechanism.failure_signature_ids) |id| {
        if (!storedContains(state.failure_signatures.items, id)) return error.FailureSignatureMissing;
    }
    try validateUniqueNonblank(input.mechanism.evidence_refs, true);
    try validateUniqueNonblank(input.mechanism.causal_cut_points, true);
    try validateUniqueNonblank(input.predicted_scope.affected_episode_families, true);
    try validateUniqueNonblank(input.predicted_scope.affected_dimensions, true);
    try validateUniqueNonblank(input.predicted_scope.protected_dimensions, true);
    try validateUniqueNonblank(input.candidate_intervention.allowed_paths, input.candidate_intervention.kind.len != 0);
    if (storedIndex(state.hypotheses.items, input.hypothesis_id)) |index| {
        var previous = try parseStoredAs(HypothesisInput, allocator, state.hypotheses.items[index]);
        defer previous.deinit();
        try appendOrTransitionStored(
            allocator,
            &state.hypotheses,
            &state.hypothesis_history,
            input.hypothesis_id,
            previous.value.status,
            input.status,
            value,
        );
    } else {
        try appendOrTransitionStored(
            allocator,
            &state.hypotheses,
            &state.hypothesis_history,
            input.hypothesis_id,
            null,
            input.status,
            value,
        );
    }
}

fn validExperimentStatus(status: []const u8) bool {
    return contains(&.{ "proposed", "eligible", "supported", "refuted", "inconclusive", "superseded", "inapplicable" }, status);
}

fn validateDecisionDimensions(input: DecisionDimensionsInput) !void {
    _ = try evidenceRank(input.evidence);
    _ = try discriminabilityRank(input.discriminability);
    _ = try scopeRank(input.scope);
    _ = try coverageRank(input.coverage);
    _ = try reversibilityRank(input.reversibility);
    _ = try riskRank(input.risk);
    _ = try costRank(input.cost);
}

pub fn applyExperiment(
    allocator: std.mem.Allocator,
    state: *State,
    value: std.json.Value,
) !void {
    var parsed = try parseValueAs(ExperimentInput, allocator, value);
    defer parsed.deinit();
    const input = parsed.value;
    if (!std.mem.eql(u8, input.schema, "hylo-experiment/v1") or
        !nonblank(input.experiment_id) or !nonblank(input.campaign_id) or
        !contains(&.{ "target_intervention", "read_only_probe" }, input.kind) or
        !validExperimentStatus(input.status) or
        !nonblank(input.intervention.description) or
        !canonical_json.isFingerprint(input.intervention.route_fingerprint) or
        !canonical_json.isFingerprint(input.intervention.applicability_fingerprint))
    {
        return error.ExperimentInvalid;
    }
    try validateUniqueNonblank(input.hypothesis_ids, true);
    for (input.hypothesis_ids) |id| {
        if (!storedContains(state.hypotheses.items, id)) return error.HypothesisMissing;
    }
    try validateUniqueNonblank(input.evidence_refs, true);
    try validateUniqueNonblank(input.intervention.allowed_paths, false);
    try validateUniqueNonblank(input.discriminates_hypotheses, false);
    try validateDecisionDimensions(input.decision_dimensions);
    for (input.falsifiers) |falsifier| {
        if (!validFalsifier(falsifier)) return error.FalsifierInvalid;
    }
    if (std.mem.eql(u8, input.kind, "target_intervention")) {
        if (input.intervention.parent_bundle_fingerprint == null or
            input.intervention.candidate_bundle_fingerprint == null or
            input.predictions.len == 0 or input.controls.len == 0 or input.falsifiers.len == 0)
        {
            return error.ExperimentInvalid;
        }
        if (!canonical_json.isFingerprint(input.intervention.parent_bundle_fingerprint.?) or
            !canonical_json.isFingerprint(input.intervention.candidate_bundle_fingerprint.?))
        {
            return error.ExperimentInvalid;
        }
    } else if (input.intervention.parent_bundle_fingerprint != null or
        input.intervention.candidate_bundle_fingerprint != null or
        input.intervention.allowed_paths.len != 0 or input.discriminates_hypotheses.len < 2)
    {
        return error.ProbeMutationForbidden;
    }
    if (std.mem.eql(u8, input.kind, "read_only_probe")) {
        for (input.discriminates_hypotheses) |id| {
            if (!storedContains(state.hypotheses.items, id) or !contains(input.hypothesis_ids, id)) {
                return error.ProbeHypothesisMissing;
            }
        }
    }
    var has_improvement_prediction = false;
    for (input.predictions) |prediction| {
        if (!nonblank(prediction.scenario_id) or !nonblank(prediction.dimension_id) or
            !contains(&.{ "improve", "no_regression" }, prediction.direction)) return error.PredictionInvalid;
        if (std.mem.eql(u8, prediction.direction, "improve")) has_improvement_prediction = true;
    }
    if (std.mem.eql(u8, input.kind, "target_intervention") and !has_improvement_prediction) {
        return error.PredictionImprovementMissing;
    }
    for (input.controls, 0..) |control, index| {
        if (!nonblank(control.scenario_id) or !nonblank(control.dimension_id) or
            !contains(&.{ "no_regression", "improve" }, control.allowed_direction)) return error.ControlInvalid;
        for (input.controls[0..index]) |prior| {
            if (std.mem.eql(u8, control.scenario_id, prior.scenario_id) and
                std.mem.eql(u8, control.dimension_id, prior.dimension_id)) return error.DuplicateControl;
        }
    }
    if (storedIndex(state.experiments.items, input.experiment_id)) |index| {
        var previous = try parseStoredAs(ExperimentInput, allocator, state.experiments.items[index]);
        defer previous.deinit();
        try appendOrTransitionStored(
            allocator,
            &state.experiments,
            &state.experiment_history,
            input.experiment_id,
            previous.value.status,
            input.status,
            value,
        );
    } else {
        try appendOrTransitionStored(
            allocator,
            &state.experiments,
            &state.experiment_history,
            input.experiment_id,
            null,
            input.status,
            value,
        );
    }
}

fn evidenceRank(value: []const u8) !u8 {
    if (std.mem.eql(u8, value, "direct")) return 0;
    if (std.mem.eql(u8, value, "triangulated")) return 1;
    if (std.mem.eql(u8, value, "speculative")) return 2;
    return error.DecisionDimensionInvalid;
}

fn discriminabilityRank(value: []const u8) !u8 {
    if (std.mem.eql(u8, value, "unique")) return 0;
    if (std.mem.eql(u8, value, "partial")) return 1;
    if (std.mem.eql(u8, value, "none")) return 2;
    return error.DecisionDimensionInvalid;
}

fn scopeRank(value: []const u8) !u8 {
    if (std.mem.eql(u8, value, "single_rule")) return 0;
    if (std.mem.eql(u8, value, "single_section")) return 1;
    if (std.mem.eql(u8, value, "multi_surface")) return 2;
    return error.DecisionDimensionInvalid;
}

fn coverageRank(value: []const u8) !u8 {
    if (std.mem.eql(u8, value, "multi_failure")) return 0;
    if (std.mem.eql(u8, value, "single_failure")) return 1;
    if (std.mem.eql(u8, value, "anecdotal")) return 2;
    return error.DecisionDimensionInvalid;
}

fn reversibilityRank(value: []const u8) !u8 {
    if (std.mem.eql(u8, value, "complete")) return 0;
    if (std.mem.eql(u8, value, "partial")) return 1;
    if (std.mem.eql(u8, value, "poor")) return 2;
    return error.DecisionDimensionInvalid;
}

fn riskRank(value: []const u8) !u8 {
    if (std.mem.eql(u8, value, "low")) return 0;
    if (std.mem.eql(u8, value, "bounded")) return 1;
    if (std.mem.eql(u8, value, "high")) return 2;
    return error.DecisionDimensionInvalid;
}

fn costRank(value: []const u8) !u8 {
    if (std.mem.eql(u8, value, "low")) return 0;
    if (std.mem.eql(u8, value, "medium")) return 1;
    if (std.mem.eql(u8, value, "high")) return 2;
    return error.DecisionDimensionInvalid;
}

fn vectorFor(input: DecisionDimensionsInput) !compiler.DecisionVector {
    return .{
        .evidence = try evidenceRank(input.evidence),
        .discriminability = try discriminabilityRank(input.discriminability),
        .scope = try scopeRank(input.scope),
        .coverage = try coverageRank(input.coverage),
        .reversibility = try reversibilityRank(input.reversibility),
        .risk = try riskRank(input.risk),
        .cost = try costRank(input.cost),
    };
}

fn vectorsEqual(left: compiler.DecisionVector, right: compiler.DecisionVector) bool {
    return std.meta.eql(left, right);
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn stringSliceLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn writeSortedStringArray(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    values: []const []const u8,
) !void {
    const sorted = try allocator.dupe([]const u8, values);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, stringSliceLessThan);
    try writer.writeByte('[');
    for (sorted, 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}

fn routeFingerprintAlloc(
    allocator: std.mem.Allocator,
    input: ExperimentInput,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"allowed_paths\":");
    try writeSortedStringArray(allocator, writer, input.intervention.allowed_paths);
    try writer.writeAll(",\"description\":");
    try writeJsonString(writer, input.intervention.description);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, input.kind);
    try writer.print(
        ",\"reversible\":{},\"semantic_change_budget\":{{\"rules_added\":{d},\"rules_removed\":{d},\"sections_touched\":{d}}}}}",
        .{
            input.intervention.reversible,
            input.intervention.semantic_change_budget.rules_added,
            input.intervention.semantic_change_budget.rules_removed,
            input.intervention.semantic_change_budget.sections_touched,
        },
    );
    return canonical_json.digestBytesAlloc(allocator, out.written());
}

fn failureApplicabilityCoreAlloc(
    allocator: std.mem.Allocator,
    input: FailureSignatureInput,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const predicate = try canonical_json.canonicalJsonAlloc(allocator, input.observable_predicate);
    defer allocator.free(predicate);
    const writer = &out.writer;
    try writer.writeAll("{\"dimension_refs\":");
    try writeSortedStringArray(allocator, writer, input.dimension_refs);
    try writer.writeAll(",\"episode_family_refs\":");
    try writeSortedStringArray(allocator, writer, input.episode_family_refs);
    try writer.writeAll(",\"hard_gate_refs\":");
    try writeSortedStringArray(allocator, writer, input.hard_gate_refs);
    try writer.writeAll(",\"observable_predicate\":");
    try writer.writeAll(predicate);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn hypothesisApplicabilityCoreAlloc(
    allocator: std.mem.Allocator,
    state: *const State,
    input: HypothesisInput,
) ![]u8 {
    var failure_cores: std.ArrayList([]u8) = .empty;
    defer {
        for (failure_cores.items) |core| allocator.free(core);
        failure_cores.deinit(allocator);
    }
    for (input.mechanism.failure_signature_ids) |failure_id| {
        var failure = (try failureById(allocator, state, failure_id)) orelse return error.FailureSignatureMissing;
        defer failure.deinit();
        try failure_cores.append(allocator, try failureApplicabilityCoreAlloc(allocator, failure.value));
    }
    std.mem.sort([]u8, failure_cores.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"affected_dimensions\":");
    try writeSortedStringArray(allocator, writer, input.predicted_scope.affected_dimensions);
    try writer.writeAll(",\"affected_episode_families\":");
    try writeSortedStringArray(allocator, writer, input.predicted_scope.affected_episode_families);
    try writer.writeAll(",\"applicability_conditions\":");
    try writeSortedStringArray(allocator, writer, input.context.applicability_conditions);
    try writer.writeAll(",\"failure_signatures\":[");
    for (failure_cores.items, 0..) |core, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(core);
    }
    try writer.writeAll("],\"protected_dimensions\":");
    try writeSortedStringArray(allocator, writer, input.predicted_scope.protected_dimensions);
    try writer.writeAll(",\"runtime_fingerprint\":");
    try writeJsonString(writer, input.context.runtime_fingerprint);
    try writer.writeAll(",\"target_bundle_fingerprint\":");
    try writeJsonString(writer, input.context.target_bundle_fingerprint);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn predictionCoreAlloc(allocator: std.mem.Allocator, input: PredictionInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"critical\":");
    try out.writer.print("{}", .{input.critical});
    try out.writer.writeAll(",\"dimension_id\":");
    try writeJsonString(&out.writer, input.dimension_id);
    try out.writer.writeAll(",\"direction\":");
    try writeJsonString(&out.writer, input.direction);
    try out.writer.writeAll(",\"scenario_id\":");
    try writeJsonString(&out.writer, input.scenario_id);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn controlCoreAlloc(allocator: std.mem.Allocator, input: ControlInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"allowed_direction\":");
    try writeJsonString(&out.writer, input.allowed_direction);
    try out.writer.writeAll(",\"dimension_id\":");
    try writeJsonString(&out.writer, input.dimension_id);
    try out.writer.writeAll(",\"scenario_id\":");
    try writeJsonString(&out.writer, input.scenario_id);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn applicabilityFingerprintAlloc(
    allocator: std.mem.Allocator,
    state: *const State,
    input: ExperimentInput,
) ![]u8 {
    var hypothesis_cores: std.ArrayList([]u8) = .empty;
    defer {
        for (hypothesis_cores.items) |core| allocator.free(core);
        hypothesis_cores.deinit(allocator);
    }
    for (input.hypothesis_ids) |hypothesis_id| {
        var hypothesis = (try hypothesisById(allocator, state, hypothesis_id)) orelse return error.HypothesisMissing;
        defer hypothesis.deinit();
        try hypothesis_cores.append(allocator, try hypothesisApplicabilityCoreAlloc(allocator, state, hypothesis.value));
    }
    std.mem.sort([]u8, hypothesis_cores.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var prediction_cores: std.ArrayList([]u8) = .empty;
    defer {
        for (prediction_cores.items) |core| allocator.free(core);
        prediction_cores.deinit(allocator);
    }
    for (input.predictions) |prediction| {
        try prediction_cores.append(allocator, try predictionCoreAlloc(allocator, prediction));
    }
    std.mem.sort([]u8, prediction_cores.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var control_cores: std.ArrayList([]u8) = .empty;
    defer {
        for (control_cores.items) |core| allocator.free(core);
        control_cores.deinit(allocator);
    }
    for (input.controls) |control| {
        try control_cores.append(allocator, try controlCoreAlloc(allocator, control));
    }
    std.mem.sort([]u8, control_cores.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"controls\":[");
    for (control_cores.items, 0..) |core, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(core);
    }
    try writer.writeAll("],\"hypotheses\":[");
    for (hypothesis_cores.items, 0..) |core, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(core);
    }
    try writer.writeAll("],\"predictions\":[");
    for (prediction_cores.items, 0..) |core, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(core);
    }
    try writer.writeAll("]}");
    return canonical_json.digestBytesAlloc(allocator, out.written());
}

fn hypothesisById(
    allocator: std.mem.Allocator,
    state: *const State,
    id: []const u8,
) !?std.json.Parsed(HypothesisInput) {
    for (state.hypotheses.items) |artifact| {
        if (std.mem.eql(u8, artifact.id, id)) return try parseStoredAs(HypothesisInput, allocator, artifact);
    }
    return null;
}

fn failureById(
    allocator: std.mem.Allocator,
    state: *const State,
    id: []const u8,
) !?std.json.Parsed(FailureSignatureInput) {
    for (state.failure_signatures.items) |artifact| {
        if (std.mem.eql(u8, artifact.id, id)) return try parseStoredAs(FailureSignatureInput, allocator, artifact);
    }
    return null;
}

fn refsContainAny(values: []const []const u8, candidates: []const []const u8) bool {
    for (values) |value| if (contains(candidates, value)) return true;
    return false;
}

fn refsArePractice(values: []const []const u8, context: Context) bool {
    if (values.len == 0) return false;
    for (values) |value| if (!contains(context.practice_evidence_refs, value)) return false;
    return true;
}

fn appendReason(reasons: *std.ArrayList([]const u8), allocator: std.mem.Allocator, code: []const u8) !void {
    if (!contains(reasons.items, code)) try reasons.append(allocator, code);
}

fn pathsAuthorized(paths: []const []const u8, allowed: []const []const u8) bool {
    if (paths.len == 0) return false;
    for (paths) |path| if (!contains(allowed, path)) return false;
    return true;
}

fn controlProtectsDimension(controls: []const ControlInput, dimension_id: []const u8) bool {
    for (controls) |control| {
        if (std.mem.eql(u8, control.dimension_id, dimension_id) and
            contains(&.{ "no_regression", "improve" }, control.allowed_direction)) return true;
    }
    return false;
}

fn derivedVectorFor(
    allocator: std.mem.Allocator,
    state: *const State,
    input: ExperimentInput,
) !compiler.DecisionVector {
    var failure_ids: std.ArrayList([]const u8) = .empty;
    defer failure_ids.deinit(allocator);
    var all_protected = true;
    for (input.hypothesis_ids) |hypothesis_id| {
        var hypothesis = (try hypothesisById(allocator, state, hypothesis_id)) orelse return error.HypothesisMissing;
        defer hypothesis.deinit();
        for (hypothesis.value.mechanism.failure_signature_ids) |failure_id| {
            if (!contains(failure_ids.items, failure_id)) try failure_ids.append(allocator, failure_id);
        }
        for (hypothesis.value.predicted_scope.protected_dimensions) |dimension_id| {
            if (!controlProtectsDimension(input.controls, dimension_id)) all_protected = false;
        }
    }

    const budget = input.intervention.semantic_change_budget;
    const changed_rules = std.math.add(u64, budget.rules_added, budget.rules_removed) catch std.math.maxInt(u64);
    const scope: u8 = if (changed_rules <= 1 and budget.sections_touched <= 1)
        0
    else if (budget.sections_touched <= 1)
        1
    else
        2;
    const coverage: u8 = if (failure_ids.items.len > 1)
        0
    else if (failure_ids.items.len == 1)
        1
    else
        2;
    const total_attempts = std.math.add(
        u64,
        input.budget.practice_attempts,
        input.budget.holdout_attempts_reserved,
    ) catch std.math.maxInt(u64);
    const risk: u8 = if (!input.intervention.reversible)
        2
    else if (scope == 0 and all_protected)
        0
    else
        1;
    const cost: u8 = if (total_attempts <= 4)
        0
    else if (total_attempts <= 16)
        1
    else
        2;
    return .{
        .evidence = if (input.evidence_refs.len != 0) 0 else 2,
        .discriminability = if (input.hypothesis_ids.len == 1) 0 else if (input.hypothesis_ids.len > 1) 1 else 2,
        .scope = scope,
        .coverage = coverage,
        .reversibility = if (input.intervention.reversible) 0 else 2,
        .risk = risk,
        .cost = cost,
    };
}

fn experimentHasRefutedEquivalent(
    allocator: std.mem.Allocator,
    state: *const State,
    current: ExperimentInput,
) !bool {
    const current_route = try routeFingerprintAlloc(allocator, current);
    defer allocator.free(current_route);
    const current_applicability = try applicabilityFingerprintAlloc(allocator, state, current);
    defer allocator.free(current_applicability);
    for (state.experiments.items) |artifact| {
        if (std.mem.eql(u8, artifact.id, current.experiment_id)) continue;
        var parsed = try parseStoredAs(ExperimentInput, allocator, artifact);
        defer parsed.deinit();
        const prior = parsed.value;
        if (!std.mem.eql(u8, prior.status, "refuted")) continue;
        const prior_route = try routeFingerprintAlloc(allocator, prior);
        defer allocator.free(prior_route);
        if (!std.mem.eql(u8, prior_route, current_route)) continue;
        const prior_applicability = try applicabilityFingerprintAlloc(allocator, state, prior);
        defer allocator.free(prior_applicability);
        if (std.mem.eql(u8, prior_applicability, current_applicability)) return true;
    }
    return false;
}

fn validateHypothesisEvidence(
    allocator: std.mem.Allocator,
    state: *const State,
    context: Context,
    hypothesis_ids: []const []const u8,
    reasons: *std.ArrayList([]const u8),
) !void {
    for (hypothesis_ids) |hypothesis_id| {
        var parsed = (try hypothesisById(allocator, state, hypothesis_id)) orelse {
            try appendReason(reasons, allocator, "hypothesis_missing");
            continue;
        };
        defer parsed.deinit();
        const hypothesis = parsed.value;
        if (!contains(&.{ "eligible", "supported" }, hypothesis.status)) {
            try appendReason(reasons, allocator, "hypothesis_ineligible");
        }
        if (!std.mem.eql(u8, hypothesis.context.target_bundle_fingerprint, context.current_bundle_fingerprint)) {
            try appendReason(reasons, allocator, "hypothesis_target_context_mismatch");
        }
        if (!std.mem.eql(u8, hypothesis.context.runtime_fingerprint, context.runtime_fingerprint)) {
            try appendReason(reasons, allocator, "hypothesis_runtime_context_mismatch");
        }
        for (hypothesis.context.applicability_conditions) |condition| {
            if (!contains(context.satisfied_applicability_conditions, condition)) {
                try appendReason(reasons, allocator, "hypothesis_applicability_unresolved");
            }
        }
        if (hypothesis.falsifiers.len == 0) try appendReason(reasons, allocator, "falsifier_missing");
        if (refsContainAny(hypothesis.mechanism.evidence_refs, context.holdout_evidence_refs)) {
            try appendReason(reasons, allocator, "holdout_motivated_intervention");
        } else if (!refsArePractice(hypothesis.mechanism.evidence_refs, context)) {
            try appendReason(reasons, allocator, "practice_evidence_missing");
        }
        for (hypothesis.predicted_scope.affected_dimensions) |dimension_id| {
            if (!contains(context.rubric_dimension_ids, dimension_id)) {
                try appendReason(reasons, allocator, "hypothesis_dimension_unknown");
            }
        }
        for (hypothesis.predicted_scope.protected_dimensions) |dimension_id| {
            if (!contains(context.rubric_dimension_ids, dimension_id)) {
                try appendReason(reasons, allocator, "hypothesis_dimension_unknown");
            }
        }
        for (hypothesis.mechanism.failure_signature_ids) |failure_id| {
            var failure = (try failureById(allocator, state, failure_id)) orelse {
                try appendReason(reasons, allocator, "failure_signature_missing");
                continue;
            };
            defer failure.deinit();
            if (refsContainAny(failure.value.evidence_refs, context.holdout_evidence_refs)) {
                try appendReason(reasons, allocator, "holdout_motivated_intervention");
            } else if (!refsArePractice(failure.value.evidence_refs, context)) {
                try appendReason(reasons, allocator, "reproducible_practice_failure_missing");
            }
            for (failure.value.dimension_refs) |dimension_id| {
                if (!contains(context.rubric_dimension_ids, dimension_id)) {
                    try appendReason(reasons, allocator, "failure_dimension_unknown");
                }
            }
        }
    }
}

fn dimensionInHypothesisScope(
    allocator: std.mem.Allocator,
    state: *const State,
    hypothesis_ids: []const []const u8,
    dimension_id: []const u8,
    protected: bool,
) !bool {
    for (hypothesis_ids) |hypothesis_id| {
        var hypothesis = (try hypothesisById(allocator, state, hypothesis_id)) orelse continue;
        defer hypothesis.deinit();
        const dimensions = if (protected)
            hypothesis.value.predicted_scope.protected_dimensions
        else
            hypothesis.value.predicted_scope.affected_dimensions;
        if (contains(dimensions, dimension_id)) return true;
    }
    return false;
}

fn allProtectedDimensionsCovered(
    allocator: std.mem.Allocator,
    state: *const State,
    input: ExperimentInput,
) !bool {
    for (input.hypothesis_ids) |hypothesis_id| {
        var hypothesis = (try hypothesisById(allocator, state, hypothesis_id)) orelse return false;
        defer hypothesis.deinit();
        for (hypothesis.value.predicted_scope.protected_dimensions) |dimension_id| {
            if (!controlProtectsDimension(input.controls, dimension_id)) return false;
        }
    }
    return true;
}

fn interventionWithinHypothesisScope(
    allocator: std.mem.Allocator,
    state: *const State,
    input: ExperimentInput,
) !bool {
    for (input.hypothesis_ids) |hypothesis_id| {
        var hypothesis = (try hypothesisById(allocator, state, hypothesis_id)) orelse return false;
        defer hypothesis.deinit();
        if (hypothesis.value.candidate_intervention.reversible != input.intervention.reversible) return false;
        if (!pathsAuthorized(
            input.intervention.allowed_paths,
            hypothesis.value.candidate_intervention.allowed_paths,
        )) return false;
    }
    return true;
}

pub fn compileAlloc(
    allocator: std.mem.Allocator,
    state: *const State,
    context: Context,
) ![]u8 {
    if (!nonblank(context.campaign_id) or
        !canonical_json.isFingerprint(context.current_bundle_fingerprint) or
        !canonical_json.isFingerprint(context.runtime_fingerprint) or
        !canonical_json.isFingerprint(context.frontier_fingerprint_basis)) return error.ContextInvalid;
    try validateUniqueNonblank(context.admitted_bundle_fingerprints, false);
    try validateUniqueNonblank(context.allowed_paths, false);
    try validateUniqueNonblank(context.practice_evidence_refs, false);
    try validateUniqueNonblank(context.holdout_evidence_refs, false);
    try validateUniqueNonblank(context.admitted_scenario_ids, false);
    try validateUniqueNonblank(context.replay_eligible_scenario_ids, false);
    try validateUniqueNonblank(context.rubric_dimension_ids, false);
    try validateUniqueNonblank(context.satisfied_applicability_conditions, false);
    for (context.admitted_bundle_fingerprints) |fingerprint| {
        if (!canonical_json.isFingerprint(fingerprint)) return error.ContextInvalid;
    }
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var candidates: std.ArrayList(compiler.Candidate) = .empty;
    var probes: std.ArrayList(compiler.Probe) = .empty;
    var ineligible: std.ArrayList(compiler.Ineligible) = .empty;

    for (state.experiments.items) |artifact| {
        const parsed = try parseStoredAs(ExperimentInput, arena, artifact);
        const input = parsed.value;
        var reasons: std.ArrayList([]const u8) = .empty;
        if (!std.mem.eql(u8, input.campaign_id, context.campaign_id)) try appendReason(&reasons, arena, "campaign_mismatch");
        if (!contains(&.{ "proposed", "eligible" }, input.status)) try appendReason(&reasons, arena, "experiment_ineligible_status");
        if (refsContainAny(input.evidence_refs, context.holdout_evidence_refs)) {
            try appendReason(&reasons, arena, "holdout_motivated_intervention");
        } else if (!refsArePractice(input.evidence_refs, context)) {
            try appendReason(&reasons, arena, "practice_evidence_missing");
        }
        try validateHypothesisEvidence(arena, state, context, input.hypothesis_ids, &reasons);
        const derived_vector = try derivedVectorFor(arena, state, input);
        if (!vectorsEqual(try vectorFor(input.decision_dimensions), derived_vector)) {
            try appendReason(&reasons, arena, "decision_vector_mismatch");
        }
        if (!context.reconstruction_ready) try appendReason(&reasons, arena, "reconstruction_ineligible");
        const required_attempts = std.math.add(
            u64,
            input.budget.practice_attempts,
            input.budget.holdout_attempts_reserved,
        ) catch std.math.maxInt(u64);
        if (required_attempts > context.remaining_attempts or
            input.budget.holdout_attempts_reserved > context.holdout_attempt_capacity)
        {
            try appendReason(&reasons, arena, "promotion_budget_infeasible");
        }
        if (std.mem.eql(u8, input.kind, "target_intervention")) {
            if (!context.target_change_authorized or !pathsAuthorized(input.intervention.allowed_paths, context.allowed_paths)) {
                try appendReason(&reasons, arena, "intervention_outside_authority");
            }
            if (!(try interventionWithinHypothesisScope(arena, state, input))) {
                try appendReason(&reasons, arena, "intervention_outside_hypothesis_scope");
            }
            if (context.holdout_exposed) try appendReason(&reasons, arena, "holdout_exposure_locks_target");
            if (!std.mem.eql(u8, input.intervention.parent_bundle_fingerprint.?, context.current_bundle_fingerprint) or
                std.mem.eql(u8, input.intervention.parent_bundle_fingerprint.?, input.intervention.candidate_bundle_fingerprint.?) or
                !contains(context.admitted_bundle_fingerprints, input.intervention.candidate_bundle_fingerprint.?))
            {
                try appendReason(&reasons, arena, "target_bundle_change_invalid");
            }
            if (input.predictions.len == 0) try appendReason(&reasons, arena, "measurable_prediction_missing");
            for (input.predictions) |prediction| {
                if (!contains(context.admitted_scenario_ids, prediction.scenario_id)) {
                    try appendReason(&reasons, arena, "prediction_scenario_unadmitted");
                }
                if (!contains(context.replay_eligible_scenario_ids, prediction.scenario_id)) {
                    try appendReason(&reasons, arena, "prediction_scenario_replay_ineligible");
                }
                if (!contains(context.rubric_dimension_ids, prediction.dimension_id)) {
                    try appendReason(&reasons, arena, "prediction_dimension_unknown");
                } else if (!(try dimensionInHypothesisScope(
                    arena,
                    state,
                    input.hypothesis_ids,
                    prediction.dimension_id,
                    false,
                ))) {
                    try appendReason(&reasons, arena, "prediction_outside_hypothesis_scope");
                }
            }
            for (input.controls) |control| {
                if (!contains(context.admitted_scenario_ids, control.scenario_id)) {
                    try appendReason(&reasons, arena, "control_scenario_unadmitted");
                }
                if (!contains(context.replay_eligible_scenario_ids, control.scenario_id)) {
                    try appendReason(&reasons, arena, "control_scenario_replay_ineligible");
                }
                if (!contains(context.rubric_dimension_ids, control.dimension_id)) {
                    try appendReason(&reasons, arena, "control_dimension_unknown");
                } else if (!(try dimensionInHypothesisScope(
                    arena,
                    state,
                    input.hypothesis_ids,
                    control.dimension_id,
                    true,
                ))) {
                    try appendReason(&reasons, arena, "control_not_protective");
                }
            }
            if (input.controls.len == 0) try appendReason(&reasons, arena, "protected_control_missing");
            if (!(try allProtectedDimensionsCovered(arena, state, input))) {
                try appendReason(&reasons, arena, "protected_control_missing");
            }
            if (input.falsifiers.len == 0) try appendReason(&reasons, arena, "falsifier_missing");
            if (try experimentHasRefutedEquivalent(arena, state, input)) {
                try appendReason(&reasons, arena, "route_refuted_equivalent");
            }
            if (reasons.items.len == 0) try candidates.append(arena, .{
                .experiment_id = input.experiment_id,
                .hypothesis_ids = input.hypothesis_ids,
                .vector = derived_vector,
            });
        } else {
            if (input.intervention.parent_bundle_fingerprint != null or
                input.intervention.candidate_bundle_fingerprint != null or
                input.intervention.allowed_paths.len != 0)
            {
                try appendReason(&reasons, arena, "probe_mutation_forbidden");
            }
            if (input.discriminates_hypotheses.len < 2) try appendReason(&reasons, arena, "probe_not_discriminating");
            for (input.discriminates_hypotheses) |hypothesis_id| {
                if (!storedContains(state.hypotheses.items, hypothesis_id) or
                    !contains(input.hypothesis_ids, hypothesis_id))
                {
                    try appendReason(&reasons, arena, "probe_hypothesis_missing");
                }
            }
            if (reasons.items.len == 0) try probes.append(arena, .{
                .experiment_id = input.experiment_id,
                .discriminates_hypotheses = input.discriminates_hypotheses,
                .cost_rank = derived_vector.cost,
            });
        }
        if (reasons.items.len != 0) try ineligible.append(arena, .{
            .experiment_id = input.experiment_id,
            .reason_codes = reasons.items,
        });
    }
    return compiler.compileAlloc(
        allocator,
        .{
            .campaign_id = context.campaign_id,
            .current_bundle_fingerprint = context.current_bundle_fingerprint,
            .runtime_fingerprint = context.runtime_fingerprint,
            .frontier_fingerprint_basis = context.frontier_fingerprint_basis,
        },
        candidates.items,
        probes.items,
        ineligible.items,
    );
}

pub fn validateAndRecordDecision(
    allocator: std.mem.Allocator,
    state: *State,
    value: std.json.Value,
    context: Context,
) !void {
    const expected = try compileAlloc(allocator, state, context);
    defer allocator.free(expected);
    return recordExpectedDecision(allocator, state, value, expected);
}

pub fn recordExpectedDecision(
    allocator: std.mem.Allocator,
    state: *State,
    value: std.json.Value,
    expected: []const u8,
) !void {
    var expected_parsed = try std.json.parseFromSlice(std.json.Value, allocator, expected, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer expected_parsed.deinit();
    const expected_root = switch (expected_parsed.value) {
        .object => |map| map,
        else => return error.NextStepDecisionInvalid,
    };
    const expected_next_step = expected_root.get("next_step") orelse return error.NextStepDecisionInvalid;
    const expected_decision = try canonical_json.canonicalJsonAlloc(allocator, expected_next_step);
    defer allocator.free(expected_decision);
    const supplied = try canonical_json.canonicalJsonAlloc(allocator, value);
    defer allocator.free(supplied);
    if (!std.mem.eql(u8, supplied, expected_decision)) return error.NextStepDecisionMismatch;
    const object = switch (value) {
        .object => |map| map,
        else => return error.NextStepDecisionInvalid,
    };
    const fingerprint = switch (object.get("decision_fingerprint") orelse return error.NextStepDecisionInvalid) {
        .string => |text| text,
        else => return error.NextStepDecisionInvalid,
    };
    if (!canonical_json.isFingerprint(fingerprint) or
        !(try canonical_json.verifyFingerprintAlloc(allocator, value, "decision_fingerprint")))
    {
        return error.NextStepDecisionInvalid;
    }
    try appendStored(allocator, &state.recorded_next_steps, fingerprint, value);
}

pub fn recordedDecisionProjectionAlloc(
    allocator: std.mem.Allocator,
    state: *const State,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"count\":{d},\"latest\":", .{state.recorded_next_steps.items.len});
    if (state.recorded_next_steps.getLastOrNull()) |latest| {
        try out.writer.writeAll(latest.json);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

const test_failure_json =
    "{\"schema\":\"hylo-failure-signature/v1\",\"failure_signature_id\":\"fs-1\",\"name\":\"constraint loss\",\"observable_predicate\":{},\"episode_family_refs\":[\"family-1\"],\"dimension_refs\":[\"correctness\"],\"hard_gate_refs\":[],\"evidence_refs\":[\"grade:g1\"]}";

const test_hypothesis_json =
    "{\"schema\":\"hylo-causal-hypothesis/v1\",\"hypothesis_id\":\"H-1\",\"campaign_id\":\"cmp\",\"context\":{\"target_bundle_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"runtime_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"applicability_conditions\":[]},\"mechanism\":{\"claim\":\"constraint is dropped\",\"failure_signature_ids\":[\"fs-1\"],\"evidence_refs\":[\"grade:g1\"],\"causal_cut_points\":[\"post-tool\"]},\"predicted_scope\":{\"affected_episode_families\":[\"family-1\"],\"affected_dimensions\":[\"correctness\"],\"protected_dimensions\":[\"tool-correctness\"]},\"candidate_intervention\":{\"kind\":\"skill_rule_change\",\"semantic_surface\":\"post-tool invariant\",\"allowed_paths\":[\"skills/hylo/SKILL.md\"],\"reversible\":true},\"falsifiers\":[{\"kind\":\"failure_persists\"}],\"status\":\"eligible\"}";

fn testApplyFailure(allocator: std.mem.Allocator, state: *State) !void {
    var failure = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        test_failure_json,
        .{},
    );
    defer failure.deinit();
    try applyFailureSignature(allocator, state, failure.value);
}

fn testApplyFoundation(allocator: std.mem.Allocator, state: *State) !void {
    try testApplyFailure(allocator, state);
    var hypothesis = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        test_hypothesis_json,
        .{},
    );
    defer hypothesis.deinit();
    try applyHypothesis(allocator, state, hypothesis.value);
}

fn testExperimentAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    status: []const u8,
    evidence_ref: []const u8,
    route_fingerprint: []const u8,
    applicability_fingerprint: []const u8,
    practice_attempts: u64,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-experiment/v1\",\"experiment_id\":{f},\"campaign_id\":\"cmp\",\"kind\":\"target_intervention\",\"status\":{f},\"hypothesis_ids\":[\"H-1\"],\"evidence_refs\":[{f}],\"intervention\":{{\"description\":\"add one invariant\",\"allowed_paths\":[\"skills/hylo/SKILL.md\"],\"semantic_change_budget\":{{\"rules_added\":1,\"rules_removed\":0,\"sections_touched\":1}},\"reversible\":true,\"route_fingerprint\":{f},\"applicability_fingerprint\":{f},\"parent_bundle_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"candidate_bundle_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}},\"predictions\":[{{\"scenario_id\":\"scenario-1\",\"dimension_id\":\"correctness\",\"direction\":\"improve\",\"critical\":true}}],\"controls\":[{{\"scenario_id\":\"scenario-1\",\"dimension_id\":\"tool-correctness\",\"allowed_direction\":\"no_regression\"}}],\"falsifiers\":[{{\"kind\":\"prediction_not_observed\"}}],\"budget\":{{\"practice_attempts\":{d},\"holdout_attempts_reserved\":1}},\"decision_dimensions\":{{\"evidence\":\"direct\",\"discriminability\":\"unique\",\"scope\":\"single_rule\",\"coverage\":\"single_failure\",\"reversibility\":\"complete\",\"risk\":\"low\",\"cost\":\"low\"}},\"discriminates_hypotheses\":[]}}",
        .{
            std.json.fmt(id, .{}),
            std.json.fmt(status, .{}),
            std.json.fmt(evidence_ref, .{}),
            std.json.fmt(route_fingerprint, .{}),
            std.json.fmt(applicability_fingerprint, .{}),
            practice_attempts,
        },
    );
}

fn testContext(state: *const State) !struct { context: Context, basis: []u8 } {
    const basis = try inputFingerprintAlloc(std.testing.allocator, state);
    return .{
        .context = .{
            .campaign_id = "cmp",
            .current_bundle_fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .runtime_fingerprint = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            .admitted_bundle_fingerprints = &.{
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            },
            .allowed_paths = &.{"skills/hylo/SKILL.md"},
            .practice_evidence_refs = &.{"grade:g1"},
            .holdout_evidence_refs = &.{"grade:h1"},
            .admitted_scenario_ids = &.{"scenario-1"},
            .replay_eligible_scenario_ids = &.{"scenario-1"},
            .rubric_dimension_ids = &.{ "correctness", "tool-correctness" },
            .satisfied_applicability_conditions = &.{},
            .target_change_authorized = true,
            .holdout_exposed = false,
            .remaining_attempts = 4,
            .holdout_attempt_capacity = 2,
            .reconstruction_ready = true,
            .frontier_fingerprint_basis = basis,
        },
        .basis = basis,
    };
}

test "causal frontier derives RUN and rejects forged recorded decisions" {
    var state = State{};
    defer state.deinit(std.testing.allocator);
    try testApplyFoundation(std.testing.allocator, &state);
    const experiment_json = try testExperimentAlloc(
        std.testing.allocator,
        "E-1",
        "proposed",
        "grade:g1",
        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        2,
    );
    defer std.testing.allocator.free(experiment_json);
    var experiment = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, experiment_json, .{});
    defer experiment.deinit();
    try applyExperiment(std.testing.allocator, &state, experiment.value);
    const owned_context = try testContext(&state);
    defer std.testing.allocator.free(owned_context.basis);
    const frontier = try compileAlloc(std.testing.allocator, &state, owned_context.context);
    defer std.testing.allocator.free(frontier);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "\"decision\":\"run\"") != null);
    var forged = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer forged.deinit();
    try std.testing.expectError(
        error.NextStepDecisionMismatch,
        recordExpectedDecision(std.testing.allocator, &state, forged.value, frontier),
    );
    var valid_frontier = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, frontier, .{});
    defer valid_frontier.deinit();
    const valid = valid_frontier.value.object.get("next_step") orelse return error.TestExpectedEqual;
    try recordExpectedDecision(std.testing.allocator, &state, valid, frontier);
    try std.testing.expectEqual(@as(usize, 1), state.recorded_next_steps.items.len);
}

test "causal frontier rejects refuted-equivalent holdout-motivated infeasible route" {
    var state = State{};
    defer state.deinit(std.testing.allocator);
    try testApplyFoundation(std.testing.allocator, &state);
    const route = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const applicability = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const old_json = try testExperimentAlloc(std.testing.allocator, "E-old", "proposed", "grade:g1", route, applicability, 1);
    defer std.testing.allocator.free(old_json);
    var old = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, old_json, .{});
    defer old.deinit();
    try applyExperiment(std.testing.allocator, &state, old.value);
    const refuted_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        old_json,
        "\"status\":\"proposed\"",
        "\"status\":\"refuted\"",
    );
    defer std.testing.allocator.free(refuted_json);
    var refuted = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, refuted_json, .{});
    defer refuted.deinit();
    try applyExperiment(std.testing.allocator, &state, refuted.value);
    const retry_json = try testExperimentAlloc(
        std.testing.allocator,
        "E-retry",
        "proposed",
        "grade:h1",
        "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "sha256:9999999999999999999999999999999999999999999999999999999999999999",
        9,
    );
    defer std.testing.allocator.free(retry_json);
    var retry = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, retry_json, .{});
    defer retry.deinit();
    try applyExperiment(std.testing.allocator, &state, retry.value);
    const owned_context = try testContext(&state);
    defer std.testing.allocator.free(owned_context.basis);
    const frontier = try compileAlloc(std.testing.allocator, &state, owned_context.context);
    defer std.testing.allocator.free(frontier);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "route_refuted_equivalent") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "holdout_motivated_intervention") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "promotion_budget_infeasible") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "\"decision\":\"stop\"") != null);
}

test "causal artifacts reject empty falsifiers degrading predictions and unprotective controls" {
    var state = State{};
    defer state.deinit(std.testing.allocator);
    try testApplyFoundation(std.testing.allocator, &state);
    const valid = try testExperimentAlloc(
        std.testing.allocator,
        "E-invalid",
        "proposed",
        "grade:g1",
        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        2,
    );
    defer std.testing.allocator.free(valid);
    const cases = [_]struct {
        needle: []const u8,
        replacement: []const u8,
        expected: anyerror,
    }{
        .{ .needle = "{\"kind\":\"prediction_not_observed\"}", .replacement = "{}", .expected = error.FalsifierInvalid },
        .{ .needle = "{\"kind\":\"prediction_not_observed\"}", .replacement = "null", .expected = error.FalsifierInvalid },
        .{ .needle = "\"direction\":\"improve\"", .replacement = "\"direction\":\"degrade\"", .expected = error.PredictionInvalid },
        .{ .needle = "\"direction\":\"improve\"", .replacement = "\"direction\":\"no_regression\"", .expected = error.PredictionImprovementMissing },
        .{ .needle = "\"allowed_direction\":\"no_regression\"", .replacement = "\"allowed_direction\":\"any\"", .expected = error.ControlInvalid },
        .{ .needle = "\"description\":\"add one invariant\"", .replacement = "\"description\":\"\"", .expected = error.ExperimentInvalid },
    };
    for (cases) |case| {
        const changed = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            valid,
            case.needle,
            case.replacement,
        );
        defer std.testing.allocator.free(changed);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, changed, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.expected, applyExperiment(std.testing.allocator, &state, parsed.value));
    }

    const bad_hypothesis = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        test_hypothesis_json,
        "{\"kind\":\"failure_persists\"}",
        "null",
    );
    defer std.testing.allocator.free(bad_hypothesis);
    var fresh = State{};
    defer fresh.deinit(std.testing.allocator);
    try testApplyFailure(std.testing.allocator, &fresh);
    var parsed_hypothesis = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bad_hypothesis, .{});
    defer parsed_hypothesis.deinit();
    try std.testing.expectError(
        error.FalsifierInvalid,
        applyHypothesis(std.testing.allocator, &fresh, parsed_hypothesis.value),
    );
}

test "causal frontier derives vector and validates frozen rubric replay and applicability context" {
    var state = State{};
    defer state.deinit(std.testing.allocator);
    try testApplyFoundation(std.testing.allocator, &state);
    const valid = try testExperimentAlloc(
        std.testing.allocator,
        "E-context",
        "proposed",
        "grade:g1",
        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        2,
    );
    defer std.testing.allocator.free(valid);
    const mislabeled = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid,
        "\"scope\":\"single_rule\"",
        "\"scope\":\"multi_surface\"",
    );
    defer std.testing.allocator.free(mislabeled);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mislabeled, .{});
    defer parsed.deinit();
    try applyExperiment(std.testing.allocator, &state, parsed.value);
    const owned_context = try testContext(&state);
    defer std.testing.allocator.free(owned_context.basis);
    var context = owned_context.context;
    context.runtime_fingerprint = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    context.replay_eligible_scenario_ids = &.{};
    context.rubric_dimension_ids = &.{"tool-correctness"};
    const frontier = try compileAlloc(std.testing.allocator, &state, context);
    defer std.testing.allocator.free(frontier);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "decision_vector_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "hypothesis_runtime_context_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "prediction_scenario_replay_ineligible") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "hypothesis_dimension_unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "prediction_dimension_unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "\"decision\":\"stop\"") != null);
}

test "causal artifact status transitions retain latest state and immutable provenance" {
    var state = State{};
    defer state.deinit(std.testing.allocator);
    try testApplyFailure(std.testing.allocator, &state);

    const proposed_hypothesis = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        test_hypothesis_json,
        "\"status\":\"eligible\"",
        "\"status\":\"proposed\"",
    );
    defer std.testing.allocator.free(proposed_hypothesis);
    var proposed_hypothesis_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        proposed_hypothesis,
        .{},
    );
    defer proposed_hypothesis_value.deinit();
    try applyHypothesis(std.testing.allocator, &state, proposed_hypothesis_value.value);
    var eligible_hypothesis = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        test_hypothesis_json,
        .{},
    );
    defer eligible_hypothesis.deinit();
    try applyHypothesis(std.testing.allocator, &state, eligible_hypothesis.value);
    try std.testing.expectEqual(@as(usize, 1), state.hypotheses.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.hypothesis_history.items.len);

    const proposed_experiment = try testExperimentAlloc(
        std.testing.allocator,
        "E-lifecycle",
        "proposed",
        "grade:g1",
        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        2,
    );
    defer std.testing.allocator.free(proposed_experiment);
    var proposed_experiment_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        proposed_experiment,
        .{},
    );
    defer proposed_experiment_value.deinit();
    try applyExperiment(std.testing.allocator, &state, proposed_experiment_value.value);
    const eligible_experiment = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        proposed_experiment,
        "\"status\":\"proposed\"",
        "\"status\":\"eligible\"",
    );
    defer std.testing.allocator.free(eligible_experiment);
    var eligible_experiment_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        eligible_experiment,
        .{},
    );
    defer eligible_experiment_value.deinit();
    try applyExperiment(std.testing.allocator, &state, eligible_experiment_value.value);
    try std.testing.expectEqual(@as(usize, 1), state.experiments.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.experiment_history.items.len);

    try std.testing.expectError(
        error.IllegalStatusTransition,
        applyExperiment(std.testing.allocator, &state, proposed_experiment_value.value),
    );
    const supported = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        eligible_experiment,
        "\"status\":\"eligible\"",
        "\"status\":\"supported\"",
    );
    defer std.testing.allocator.free(supported);
    const mutated = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        supported,
        "add one invariant",
        "add a different invariant",
    );
    defer std.testing.allocator.free(mutated);
    var mutated_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mutated, .{});
    defer mutated_value.deinit();
    try std.testing.expectError(
        error.ArtifactIdentityMutation,
        applyExperiment(std.testing.allocator, &state, mutated_value.value),
    );

    const fingerprint = try inputFingerprintAlloc(std.testing.allocator, &state);
    defer std.testing.allocator.free(fingerprint);
    try std.testing.expect(canonical_json.isFingerprint(fingerprint));
}

test "proposed hypothesis cannot authorize RUN" {
    var state = State{};
    defer state.deinit(std.testing.allocator);
    try testApplyFailure(std.testing.allocator, &state);
    const proposed_hypothesis = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        test_hypothesis_json,
        "\"status\":\"eligible\"",
        "\"status\":\"proposed\"",
    );
    defer std.testing.allocator.free(proposed_hypothesis);
    var hypothesis = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, proposed_hypothesis, .{});
    defer hypothesis.deinit();
    try applyHypothesis(std.testing.allocator, &state, hypothesis.value);
    const experiment_json = try testExperimentAlloc(
        std.testing.allocator,
        "E-proposed-hypothesis",
        "proposed",
        "grade:g1",
        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        2,
    );
    defer std.testing.allocator.free(experiment_json);
    var experiment = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, experiment_json, .{});
    defer experiment.deinit();
    try applyExperiment(std.testing.allocator, &state, experiment.value);
    const owned_context = try testContext(&state);
    defer std.testing.allocator.free(owned_context.basis);
    const frontier = try compileAlloc(std.testing.allocator, &state, owned_context.context);
    defer std.testing.allocator.free(frontier);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "hypothesis_ineligible") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontier, "\"decision\":\"stop\"") != null);
}
