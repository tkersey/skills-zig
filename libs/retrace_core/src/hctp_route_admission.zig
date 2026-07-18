const std = @import("std");
const canonical_json = @import("canonical_json.zig");
const dcp_schema = @import("dcp_schema.zig");
const hctp_adapter = @import("hctp_adapter.zig");
const replay_episode = @import("replay_episode.zig");

pub const schema = "hylo-source-route-admission/v1";

pub const DeriveOptions = struct {
    campaign_id: []const u8,
    unit_id: []const u8,
    scenario_id: []const u8,
    source_episode_id: []const u8,
    split: []const u8,
    require_authoritative_historical: bool = false,
};

pub const ExpectedBinding = struct {
    campaign_id: []const u8,
    unit_id: []const u8,
    scenario_id: []const u8,
    source_profile_fingerprint: []const u8,
    source_episode_projection_fingerprint: []const u8,
};

/// Derives the public, source-owner-attested route projection from a validated
/// CRF episode and its governed source profile. The episode body is consumed
/// only as evidence and is never copied into the returned artifact.
pub fn deriveAlloc(
    allocator: std.mem.Allocator,
    episode_value: std.json.Value,
    source_profile_value: std.json.Value,
    options: DeriveOptions,
) ![]u8 {
    const episode = try episodeEvidence(allocator, episode_value, options);
    const profile = try object(source_profile_value);
    const source_kind = try requiredString(profile, "kind");
    const source_profile_fingerprint = try canonical_json.digestValueAlloc(
        allocator,
        source_profile_value,
    );
    defer allocator.free(source_profile_fingerprint);

    var route = try deriveRouteProjectionAlloc(
        allocator,
        source_profile_value,
        profile,
        source_kind,
        episode,
        options.require_authoritative_historical,
    );
    defer route.deinit(allocator);

    const derived = try writeAdmissionAlloc(
        allocator,
        options,
        episode,
        source_kind,
        source_profile_fingerprint,
        route,
    );
    defer allocator.free(derived);
    return canonicalizeAdmissionAlloc(
        allocator,
        derived,
        options,
        source_profile_fingerprint,
        route.source_episode_projection_fingerprint,
    );
}

const EpisodeEvidence = struct {
    episode_id: []const u8,
    episode_fingerprint: []const u8,
    fidelity_class: []const u8,
    replay_eligible: bool,
    limitations: std.json.Array,
};

fn episodeEvidence(
    allocator: std.mem.Allocator,
    episode_value: std.json.Value,
    options: DeriveOptions,
) !EpisodeEvidence {
    if (!(replay_episode.validateEpisodeValue(allocator, episode_value) catch false)) {
        return error.CrfReplayEpisodeInvalid;
    }
    const episode = try object(episode_value);
    const episode_id = try requiredString(episode, "episode_id");
    if (!std.mem.eql(u8, episode_id, options.source_episode_id)) {
        return error.SourceEpisodeIdentityMismatch;
    }
    if (!std.mem.eql(u8, try requiredString(episode, "split"), options.split)) {
        return error.CrfReplayEpisodeSplitMismatch;
    }
    const fidelity = try requiredObject(episode, "fidelity");
    return .{
        .episode_id = episode_id,
        .episode_fingerprint = try requiredString(episode, "episode_fingerprint"),
        .fidelity_class = try requiredString(fidelity, "class"),
        .replay_eligible = try requiredBool(fidelity, "replay_eligible"),
        .limitations = try requiredArray(fidelity, "limitations"),
    };
}

const RouteProjection = struct {
    execution_route: []const u8,
    comparison_eligible: bool,
    effective_reconstruction_class: []const u8,
    governance_state: ?[]const u8 = null,
    governance_workflow_effect_allowed: bool = false,
    required_lineage: ?[]const u8 = null,
    required_fir_version: ?[]const u8 = null,
    source_episode_projection_fingerprint: []u8,
    owned_reconstruction: ?[]u8 = null,
    profile_limitations: ?std.json.Array = null,

    fn deinit(self: *RouteProjection, allocator: std.mem.Allocator) void {
        allocator.free(self.source_episode_projection_fingerprint);
        if (self.owned_reconstruction) |value| allocator.free(value);
    }
};

fn deriveRouteProjectionAlloc(
    allocator: std.mem.Allocator,
    source_profile_value: std.json.Value,
    profile: std.json.ObjectMap,
    source_kind: []const u8,
    episode: EpisodeEvidence,
    require_authoritative_historical: bool,
) !RouteProjection {
    if (std.mem.eql(u8, source_kind, "direct")) {
        const projection_fingerprint = try hctp_adapter.directSourceEpisodeFingerprintAlloc(
            allocator,
            episode.episode_id,
        );
        return .{
            .execution_route = if (episode.replay_eligible) "direct" else "diagnostic_only",
            .comparison_eligible = episode.replay_eligible,
            .effective_reconstruction_class = episode.fidelity_class,
            .source_episode_projection_fingerprint = projection_fingerprint,
        };
    }
    if (!std.mem.eql(u8, source_kind, "historical_decision")) {
        return error.SourceProfileInvalid;
    }

    var report = try hctp_adapter.validateHistoricalProfile(
        allocator,
        source_profile_value,
        require_authoritative_historical,
    );
    defer report.deinit(allocator);
    const reconstruction = effectiveHistoricalReconstruction(
        episode.fidelity_class,
        episode.replay_eligible,
        report.reconstructability,
    );
    const required_lineage = try requiredString(profile, "required_lineage");
    const required_fir_version = try requiredString(profile, "required_fir_version");
    const profile_limitations = try requiredArray(profile, "limitations");
    const owned_reconstruction = try allocator.dupe(u8, reconstruction);
    errdefer allocator.free(owned_reconstruction);
    const projection_fingerprint = try hctp_adapter.historicalSourceEpisodeFingerprintAlloc(
        allocator,
        episode.episode_id,
        &report,
    );
    return .{
        .execution_route = "historical_replay",
        .comparison_eligible = !std.mem.eql(u8, reconstruction, "unavailable"),
        .effective_reconstruction_class = owned_reconstruction,
        .governance_state = @tagName(report.governance.state),
        .governance_workflow_effect_allowed = report.governance.workflow_effect_allowed,
        .required_lineage = required_lineage,
        .required_fir_version = required_fir_version,
        .source_episode_projection_fingerprint = projection_fingerprint,
        .owned_reconstruction = owned_reconstruction,
        .profile_limitations = profile_limitations,
    };
}

fn writeAdmissionAlloc(
    allocator: std.mem.Allocator,
    options: DeriveOptions,
    episode: EpisodeEvidence,
    source_kind: []const u8,
    source_profile_fingerprint: []const u8,
    route: RouteProjection,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeAdmissionIdentity(&out.writer, options, episode, route);
    try writeAdmissionFidelity(&out.writer, episode, route);
    try writeAdmissionRoute(
        &out.writer,
        options,
        source_kind,
        source_profile_fingerprint,
        route,
    );
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeAdmissionIdentity(
    writer: *std.Io.Writer,
    options: DeriveOptions,
    episode: EpisodeEvidence,
    route: RouteProjection,
) !void {
    try writer.writeAll("{\"campaign_id\":");
    try writeString(writer, options.campaign_id);
    try writer.writeAll(",\"comparison_eligible\":");
    try writer.writeAll(if (route.comparison_eligible) "true" else "false");
    try writer.writeAll(",\"effective_reconstruction_class\":");
    try writeString(writer, route.effective_reconstruction_class);
    try writer.writeAll(",\"episode_fingerprint\":");
    try writeString(writer, episode.episode_fingerprint);
    try writer.writeAll(",\"episode_id\":");
    try writeString(writer, episode.episode_id);
    try writer.writeAll(",\"execution_route\":");
    try writeString(writer, route.execution_route);
}

fn writeAdmissionFidelity(
    writer: *std.Io.Writer,
    episode: EpisodeEvidence,
    route: RouteProjection,
) !void {
    try writer.writeAll(",\"fidelity\":{\"class\":");
    try writeString(writer, episode.fidelity_class);
    try writer.writeAll(",\"replay_eligible\":");
    try writer.writeAll(if (episode.replay_eligible) "true}" else "false}");
    try writer.writeAll(",\"limitations\":[");
    try writeMergedLimitations(writer, episode.limitations, route.profile_limitations);
}

fn writeAdmissionRoute(
    writer: *std.Io.Writer,
    options: DeriveOptions,
    source_kind: []const u8,
    source_profile_fingerprint: []const u8,
    route: RouteProjection,
) !void {
    try writer.writeAll("],\"required_fir_version\":");
    try writeOptionalString(writer, route.required_fir_version);
    try writer.writeAll(",\"required_lineage\":");
    try writeOptionalString(writer, route.required_lineage);
    try writer.writeAll(",\"scenario_id\":");
    try writeString(writer, options.scenario_id);
    try writer.writeAll(",\"schema\":\"");
    try writer.writeAll(schema);
    try writer.writeAll("\",\"source_governance_state\":");
    try writeOptionalString(writer, route.governance_state);
    try writer.writeAll(",\"source_governance_workflow_effect_allowed\":");
    try writer.writeAll(if (route.governance_workflow_effect_allowed) "true" else "false");
    try writer.writeAll(",\"source_episode_projection_fingerprint\":");
    try writeString(writer, route.source_episode_projection_fingerprint);
    try writer.writeAll(",\"source_episode_projection_version\":\"");
    try writer.writeAll(hctp_adapter.source_episode_projection_version);
    try writer.writeByte('"');
    try writer.writeAll(",\"source_profile_fingerprint\":");
    try writeString(writer, source_profile_fingerprint);
    try writer.writeAll(",\"source_profile_kind\":");
    try writeString(writer, source_kind);
    try writer.writeAll(",\"unit_id\":");
    try writeString(writer, options.unit_id);
}

fn canonicalizeAdmissionAlloc(
    allocator: std.mem.Allocator,
    derived: []const u8,
    options: DeriveOptions,
    source_profile_fingerprint: []const u8,
    source_episode_projection_fingerprint: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, derived, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    try validateValue(allocator, parsed.value, .{
        .campaign_id = options.campaign_id,
        .unit_id = options.unit_id,
        .scenario_id = options.scenario_id,
        .source_profile_fingerprint = source_profile_fingerprint,
        .source_episode_projection_fingerprint = source_episode_projection_fingerprint,
    });
    return canonical_json.canonicalJsonAlloc(allocator, parsed.value);
}

/// Validates the signed public projection without requiring the private CRF
/// episode or historical source-profile body to cross the boundary again.
pub fn validateValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    expected: ExpectedBinding,
) !void {
    _ = allocator;
    const root = try object(value);
    try validateAdmissionShape(root);
    try validateAdmissionBinding(root, expected);
    const fidelity = try validateAdmissionFidelity(root);
    try validateAdmissionLimitations(root);
    try validateAdmissionRoute(root, fidelity);
}

fn validateAdmissionShape(root: std.json.ObjectMap) !void {
    if (!hasExactKeys(root, &.{
        "campaign_id",
        "comparison_eligible",
        "effective_reconstruction_class",
        "episode_fingerprint",
        "episode_id",
        "execution_route",
        "fidelity",
        "limitations",
        "required_fir_version",
        "required_lineage",
        "scenario_id",
        "schema",
        "source_governance_state",
        "source_governance_workflow_effect_allowed",
        "source_episode_projection_fingerprint",
        "source_episode_projection_version",
        "source_profile_fingerprint",
        "source_profile_kind",
        "unit_id",
    })) return error.SourceRouteAdmissionInvalid;
}

fn validateAdmissionBinding(
    root: std.json.ObjectMap,
    expected: ExpectedBinding,
) !void {
    if (!std.mem.eql(u8, try requiredString(root, "schema"), schema) or
        !std.mem.eql(u8, try requiredString(root, "campaign_id"), expected.campaign_id) or
        !std.mem.eql(u8, try requiredString(root, "unit_id"), expected.unit_id) or
        !std.mem.eql(u8, try requiredString(root, "scenario_id"), expected.scenario_id))
    {
        return error.SourceRouteAdmissionBindingMismatch;
    }
    const episode_id = try requiredString(root, "episode_id");
    const episode_fingerprint = try requiredString(root, "episode_fingerprint");
    if (!episodeIdMatchesFingerprint(episode_id, episode_fingerprint) or
        !std.mem.eql(
            u8,
            try requiredString(root, "source_episode_projection_version"),
            hctp_adapter.source_episode_projection_version,
        ) or
        !canonical_json.isFingerprint(
            try requiredString(root, "source_episode_projection_fingerprint"),
        ) or
        !canonical_json.isFingerprint(
            try requiredString(root, "source_profile_fingerprint"),
        ))
    {
        return error.SourceRouteAdmissionInvalid;
    }
    if (!std.mem.eql(
        u8,
        expected.source_profile_fingerprint,
        try requiredString(root, "source_profile_fingerprint"),
    )) {
        return error.SourceRouteAdmissionBindingMismatch;
    }
    if (!std.mem.eql(
        u8,
        expected.source_episode_projection_fingerprint,
        try requiredString(root, "source_episode_projection_fingerprint"),
    )) {
        return error.SourceRouteAdmissionBindingMismatch;
    }
}

const ValidatedFidelity = struct {
    class: []const u8,
    replay_eligible: bool,
};

fn validateAdmissionFidelity(root: std.json.ObjectMap) !ValidatedFidelity {
    const fidelity = try requiredObject(root, "fidelity");
    if (!hasExactKeys(fidelity, &.{ "class", "replay_eligible" })) {
        return error.SourceRouteAdmissionInvalid;
    }
    const fidelity_class = try requiredString(fidelity, "class");
    const replay_eligible = try requiredBool(fidelity, "replay_eligible");
    if (!oneOf(fidelity_class, &.{
        "controlled_replay",
        "workspace_snapshot",
        "tool_tape_replay",
        "transcript_only",
        "diagnostic_only",
        "unusable",
    })) {
        return error.SourceRouteAdmissionInvalid;
    }
    if ((oneOf(
        fidelity_class,
        &.{ "transcript_only", "diagnostic_only", "unusable" },
    ) and replay_eligible) or
        (std.mem.eql(u8, fidelity_class, "controlled_replay") and !replay_eligible))
    {
        return error.SourceRouteAdmissionInvalid;
    }
    return .{ .class = fidelity_class, .replay_eligible = replay_eligible };
}

fn validateAdmissionLimitations(root: std.json.ObjectMap) !void {
    const limitations = try requiredArray(root, "limitations");
    if (limitations.items.len == 0) return error.SourceRouteAdmissionInvalid;
    for (limitations.items) |limitation| {
        if (limitation != .string or limitation.string.len == 0) {
            return error.SourceRouteAdmissionInvalid;
        }
    }
}

fn validateAdmissionRoute(
    root: std.json.ObjectMap,
    fidelity: ValidatedFidelity,
) !void {
    const source_kind = try requiredString(root, "source_profile_kind");
    const reconstruction = try requiredString(root, "effective_reconstruction_class");
    if (reconstruction.len == 0) return error.SourceRouteAdmissionInvalid;
    if (std.mem.eql(u8, source_kind, "direct")) {
        return validateDirectAdmission(root, fidelity, reconstruction);
    }
    try validateHistoricalAdmission(root, fidelity, reconstruction);
}

fn validateDirectAdmission(
    root: std.json.ObjectMap,
    fidelity: ValidatedFidelity,
    reconstruction: []const u8,
) !void {
    const route = try requiredString(root, "execution_route");
    const comparison_eligible = try requiredBool(root, "comparison_eligible");
    const workflow_effect_allowed = try requiredBool(
        root,
        "source_governance_workflow_effect_allowed",
    );
    if (!isNull(root.get("source_governance_state")) or workflow_effect_allowed or
        !isNull(root.get("required_lineage")) or
        !isNull(root.get("required_fir_version")) or
        !std.mem.eql(u8, reconstruction, fidelity.class))
    {
        return error.SourceRouteAdmissionInvalid;
    }
    if (fidelity.replay_eligible) {
        if (!std.mem.eql(u8, route, "direct") or !comparison_eligible) {
            return error.SourceRouteAdmissionInvalid;
        }
    } else if (!std.mem.eql(u8, route, "diagnostic_only") or comparison_eligible) {
        return error.SourceRouteAdmissionInvalid;
    }
}

fn validateHistoricalAdmission(
    root: std.json.ObjectMap,
    fidelity: ValidatedFidelity,
    reconstruction: []const u8,
) !void {
    const route = try requiredString(root, "execution_route");
    const comparison_eligible = try requiredBool(root, "comparison_eligible");
    const workflow_effect_allowed = try requiredBool(
        root,
        "source_governance_workflow_effect_allowed",
    );
    if (!std.mem.eql(u8, try requiredString(root, "source_profile_kind"), "historical_decision") or
        !std.mem.eql(u8, route, "historical_replay") or
        optionalString(root, "source_governance_state") == null or
        optionalString(root, "required_lineage") == null or
        !std.mem.eql(
            u8,
            try requiredString(root, "required_fir_version"),
            hctp_adapter.fir_version,
        ))
    {
        return error.SourceRouteAdmissionInvalid;
    }
    if (!oneOf(
        try requiredString(root, "required_lineage"),
        &.{ "thread_fork", "rollout_transcript", "either" },
    )) {
        return error.SourceRouteAdmissionInvalid;
    }
    if (!oneOf(
        reconstruction,
        &.{ "exact", "head_only", "transcript_only", "unavailable" },
    )) {
        return error.SourceRouteAdmissionInvalid;
    }
    if (comparison_eligible != !std.mem.eql(u8, reconstruction, "unavailable")) {
        return error.SourceRouteAdmissionInvalid;
    }
    if (!fidelity.replay_eligible) {
        const allowed = if (oneOf(fidelity.class, &.{ "diagnostic_only", "unusable" }))
            std.mem.eql(u8, reconstruction, "unavailable")
        else
            oneOf(reconstruction, &.{ "transcript_only", "unavailable" });
        if (!allowed) return error.SourceRouteAdmissionInvalid;
    }
    const governance_state = try requiredString(root, "source_governance_state");
    if (!oneOf(governance_state, &.{ "authoritative", "declared_uncontrolled" }) or
        workflow_effect_allowed != std.mem.eql(u8, governance_state, "authoritative"))
    {
        return error.SourceRouteAdmissionInvalid;
    }
}

fn effectiveHistoricalReconstruction(
    fidelity_class: []const u8,
    replay_eligible: bool,
    profile_reconstruction: []const u8,
) []const u8 {
    if (replay_eligible) return profile_reconstruction;
    if (std.mem.eql(u8, fidelity_class, "diagnostic_only") or
        std.mem.eql(u8, fidelity_class, "unusable") or
        std.mem.eql(u8, profile_reconstruction, "unavailable"))
    {
        return "unavailable";
    }
    return "transcript_only";
}

fn episodeIdMatchesFingerprint(episode_id: []const u8, fingerprint: []const u8) bool {
    return canonical_json.isFingerprint(fingerprint) and episode_id.len == "ep-".len + 16 and
        std.mem.startsWith(u8, episode_id, "ep-") and
        std.mem.eql(u8, episode_id["ep-".len..], fingerprint["sha256:".len .. "sha256:".len + 16]);
}

pub fn requireComparisonEligible(value: std.json.Value) !void {
    const root = try object(value);
    if (try requiredBool(root, "comparison_eligible")) return;
    const fidelity = try requiredObject(root, "fidelity");
    if (std.mem.eql(u8, try requiredString(root, "source_profile_kind"), "direct") and
        !(try requiredBool(fidelity, "replay_eligible")))
    {
        return error.CrfReplayIneligibleForDirectRoute;
    }
    return error.DiagnosticSourceNotComparisonEligible;
}

fn writeMergedLimitations(
    writer: *std.Io.Writer,
    episode: std.json.Array,
    profile: ?std.json.Array,
) !void {
    var first = true;
    for (episode.items) |value| {
        const text = try string(value);
        if (!first) try writer.writeByte(',');
        first = false;
        try writeString(writer, text);
    }
    if (profile) |profile_items| {
        for (profile_items.items, 0..) |value, index| {
            const text = try string(value);
            if (containsStringBefore(episode, text, episode.items.len) or
                containsStringBefore(profile_items, text, index)) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writeString(writer, text);
        }
    }
}

fn containsStringBefore(values: std.json.Array, needle: []const u8, end: usize) bool {
    for (values.items[0..end]) |value| {
        if (value == .string and std.mem.eql(u8, value.string, needle)) return true;
    }
    return false;
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| return writeString(writer, text);
    try writer.writeAll("null");
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ExpectedObject,
    };
}

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(map.get(key) orelse return error.MissingField);
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return switch (map.get(key) orelse return error.MissingField) {
        .array => |array| array,
        else => error.ExpectedArray,
    };
}

fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return string(map.get(key) orelse return error.MissingField);
}

fn optionalString(map: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return if (map.get(key)) |value| switch (value) {
        .string => |text| text,
        else => null,
    } else null;
}

fn requiredBool(map: std.json.ObjectMap, key: []const u8) !bool {
    return switch (map.get(key) orelse return error.MissingField) {
        .bool => |flag| flag,
        else => error.ExpectedBool,
    };
}

fn isNull(value: ?std.json.Value) bool {
    return if (value) |actual| actual == .null else false;
}

fn hasExactKeys(map: std.json.ObjectMap, expected: []const []const u8) bool {
    if (map.count() != expected.len) return false;
    for (expected) |key| if (!map.contains(key)) return false;
    return true;
}

fn oneOf(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

const test_hash_1 =
    "sha256:1111111111111111111111111111111111111111111111111111111111111111";
const test_hash_2 =
    "sha256:2222222222222222222222222222222222222222222222222222222222222222";
const test_hash_3 =
    "sha256:3333333333333333333333333333333333333333333333333333333333333333";
const test_hash_4 =
    "sha256:4444444444444444444444444444444444444444444444444444444444444444";
const test_hash_5 =
    "sha256:5555555555555555555555555555555555555555555555555555555555555555";
const test_hash_6 =
    "sha256:6666666666666666666666666666666666666666666666666666666666666666";
const test_hash_7 =
    "sha256:7777777777777777777777777777777777777777777777777777777777777777";
const test_hash_8 =
    "sha256:8888888888888888888888888888888888888888888888888888888888888888";

fn buildTestEpisodeAlloc(
    allocator: std.mem.Allocator,
    fidelity_class: []const u8,
    replay_eligible: bool,
) ![]u8 {
    const stimulus_json = try buildTestStimulusAlloc(allocator);
    defer allocator.free(stimulus_json);
    var stimulus_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        stimulus_json,
        .{},
    );
    defer stimulus_parsed.deinit();
    const stimulus_fingerprint = try requiredString(
        try object(stimulus_parsed.value),
        "stimulus_fingerprint",
    );

    const episode_base = try buildTestEpisodeBaseAlloc(
        allocator,
        stimulus_json,
        stimulus_fingerprint,
        fidelity_class,
        replay_eligible,
    );
    defer allocator.free(episode_base);
    const provisional = try replay_episode.finalizeEpisodeAlloc(allocator, episode_base);
    defer allocator.free(provisional);
    var provisional_parsed = try std.json.parseFromSlice(std.json.Value, allocator, provisional, .{
        .allocate = .alloc_always,
    });
    defer provisional_parsed.deinit();
    const provisional_root = try object(provisional_parsed.value);
    const fingerprint = try requiredString(provisional_root, "episode_fingerprint");
    const episode_id = try std.fmt.allocPrint(
        allocator,
        "ep-{s}",
        .{fingerprint["sha256:".len .. "sha256:".len + 16]},
    );
    defer allocator.free(episode_id);
    const with_identity = try std.mem.replaceOwned(
        u8,
        allocator,
        provisional,
        "ep-0000000000000000",
        episode_id,
    );
    defer allocator.free(with_identity);
    return replay_episode.finalizeEpisodeAlloc(allocator, with_identity);
}

fn buildTestStimulusAlloc(allocator: std.mem.Allocator) ![]u8 {
    const stimulus_base =
        "{\"schema\":\"hylo-stimulus/v1\",\"messages\":[{" ++
        "\"message_id\":\"msg-1\",\"ordinal\":0,\"source_line\":1," ++
        "\"role\":\"system\",\"content\":[{\"type\":\"text\"," ++
        "\"text\":\"fixed context\"}],\"timestamp_policy\":\"source\"," ++
        "\"provenance_ref\":\"rollout:line-1\",\"visibility\":\"runner_visible\"},{" ++
        "\"message_id\":\"msg-4\",\"ordinal\":1,\"source_line\":4," ++
        "\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"follow-up\"}]," ++
        "\"timestamp_policy\":\"source\",\"provenance_ref\":\"rollout:line-4\"," ++
        "\"visibility\":\"runner_visible\"}],\"instructions\":[{" ++
        "\"instruction_id\":\"inst-fixed\",\"class\":\"fixed\",\"slot\":null," ++
        "\"content_ref\":\"artifact:fixed.txt\",\"source_line\":1},{" ++
        "\"instruction_id\":\"inst-target\",\"class\":\"replaceable_target\"," ++
        "\"slot\":\"skill://hylo\",\"content_ref\":null,\"source_line\":3}]," ++
        "\"attachments\":[],\"initial_goal_state\":null,\"context_policy\":{" ++
        "\"requested\":\"full-prefix\",\"applied\":\"full_prefix\"}," ++
        "\"stimulus_fingerprint\":\"\"}";
    return replay_episode.finalizeStimulusAlloc(allocator, stimulus_base);
}

fn buildTestEpisodeBaseAlloc(
    allocator: std.mem.Allocator,
    stimulus_json: []const u8,
    stimulus_fingerprint: []const u8,
    fidelity_class: []const u8,
    replay_eligible: bool,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeTestEpisodePrefix(&out.writer);
    try out.writer.writeAll(",\"stimulus\":");
    try out.writer.writeAll(stimulus_json);
    try writeTestEpisodeArtifacts(&out.writer, stimulus_fingerprint);
    try writeTestEpisodeSuffix(&out.writer, fidelity_class, replay_eligible);
    return out.toOwnedSlice();
}

fn writeTestEpisodePrefix(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"schema\":\"hylo-replay-episode/v1\",");
    try writer.writeAll("\"episode_id\":\"ep-0000000000000000\",");
    try writer.writeAll("\"episode_family_id\":\"family-route-admission\",\"source\":{");
    try writer.writeAll("\"session_id\":\"session-route\",\"rollout_ref\":\"local:route\",");
    try writer.writeAll("\"rollout_fingerprint\":");
    try writeString(writer, test_hash_1);
    try writer.writeAll(",\"source_turn_ids\":[\"turn-1\"],\"source_event_range\":{");
    try writer.writeAll("\"first_line\":1,\"last_fixed_line\":5}},\"target\":{");
    try writer.writeAll("\"kind\":\"skill\",\"target_id\":\"hylo\",");
    try writer.writeAll("\"activation_refs\":[\"line:3\"],\"replaceable_slot\":\"skill://hylo\",");
    try writer.writeAll("\"source_bundle_fingerprint\":");
    try writeString(writer, test_hash_2);
    try writer.writeAll("},\"cut\":{\"kind\":\"skill_activation\",\"confidence\":\"exact\",");
    try writer.writeAll("\"last_fixed_turn_index\":0,\"last_fixed_event_ref\":\"line:5\",");
    try writer.writeAll("\"first_regenerated_event_ref\":\"line:6\",");
    try writer.writeAll("\"rationale\":\"structured activation\",\"excluded_future_digest\":");
    try writeString(writer, test_hash_3);
    try writer.writeByte('}');
}

fn writeTestEpisodeArtifacts(
    writer: *std.Io.Writer,
    stimulus_fingerprint: []const u8,
) !void {
    try writer.writeAll(",\"stimulus_ref\":\"artifact:stimulus.json\",");
    try writer.writeAll("\"stimulus_fingerprint\":");
    try writeString(writer, stimulus_fingerprint);
    try writer.writeAll(",\"world_snapshot_ref\":\"artifact:world.json\",\"world_fingerprint\":");
    try writeString(writer, test_hash_4);
    try writer.writeAll(",\"world_availability_ref\":\"artifact:world-availability.json\",");
    try writer.writeAll("\"world_availability_fingerprint\":");
    try writeString(writer, test_hash_5);
    try writer.writeAll(",\"runtime_contract_ref\":\"artifact:runtime.json\",");
    try writer.writeAll("\"runtime_fingerprint\":");
    try writeString(writer, test_hash_6);
    try writer.writeAll(",\"hidden_reference\":{");
    try writer.writeAll("\"historical_response_ref\":\"custody:historical-response.sealed.json\",");
    try writer.writeAll("\"historical_response_fingerprint\":");
    try writeString(writer, test_hash_7);
    try writer.writeAll(",\"historical_trace_ref\":null,\"future_outcome_ref\":null},");
    try writer.writeAll("\"oracle_contract_refs\":[],\"privacy\":{\"mode\":\"sanitized\",");
    try writer.writeAll("\"redaction_receipt_ref\":\"custody:redaction.json\",");
    try writer.writeAll("\"redaction_receipt_fingerprint\":");
    try writeString(writer, test_hash_8);
    try writer.writeByte('}');
}

fn writeTestEpisodeSuffix(
    writer: *std.Io.Writer,
    fidelity_class: []const u8,
    replay_eligible: bool,
) !void {
    try writer.writeAll(",\"fidelity\":{\"class\":");
    try writeString(writer, fidelity_class);
    try writer.writeAll(",\"limitations\":[\"fixture limitation\"],\"replay_eligible\":");
    try writer.writeAll(if (replay_eligible) "true}" else "false}");
    try writer.writeAll(",\"split\":\"practice\",\"episode_fingerprint\":\"\"}");
}

fn buildHistoricalProfileAlloc(
    allocator: std.mem.Allocator,
    source_episode_id: []const u8,
    reconstructability: []const u8,
) ![]u8 {
    const template = try buildDecisionContextTemplateAlloc(allocator);
    defer allocator.free(template);
    const dcp = try bindDecisionContextAlloc(
        allocator,
        template,
        source_episode_id,
        reconstructability,
    );
    defer allocator.free(dcp);
    var dcp_parsed = try std.json.parseFromSlice(std.json.Value, allocator, dcp, .{});
    defer dcp_parsed.deinit();
    const packet = try requiredObject(try object(dcp_parsed.value), "decision_context_packet");
    const contamination = packet.get("contamination") orelse return error.MissingField;
    const contamination_json = try dcp_schema.canonicalJsonAlloc(allocator, contamination, false);
    defer allocator.free(contamination_json);
    const contamination_fingerprint = try canonical_json.digestBytesAlloc(
        allocator,
        contamination_json,
    );
    defer allocator.free(contamination_fingerprint);
    const dcp_fingerprint = try canonical_json.digestValueAlloc(allocator, dcp_parsed.value);
    defer allocator.free(dcp_fingerprint);
    const governance = try buildGovernanceAlloc(allocator, source_episode_id);
    defer allocator.free(governance);
    var governance_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        governance,
        .{},
    );
    defer governance_parsed.deinit();
    const governance_fingerprint = try canonical_json.digestValueAlloc(
        allocator,
        governance_parsed.value,
    );
    defer allocator.free(governance_fingerprint);
    return buildHistoricalProfileJsonAlloc(
        allocator,
        source_episode_id,
        reconstructability,
        governance,
        governance_fingerprint,
        dcp,
        dcp_fingerprint,
        contamination_fingerprint,
    );
}

fn bindDecisionContextAlloc(
    allocator: std.mem.Allocator,
    template: []const u8,
    source_episode_id: []const u8,
    reconstructability: []const u8,
) ![]u8 {
    const reconstruction_bound = try std.mem.replaceOwned(
        u8,
        allocator,
        template,
        "RECONSTRUCTION",
        reconstructability,
    );
    defer allocator.free(reconstruction_bound);
    const identity_bound = try std.mem.replaceOwned(
        u8,
        allocator,
        reconstruction_bound,
        "SOURCE-EPISODE",
        source_episode_id,
    );
    defer allocator.free(identity_bound);
    const packet_id = try dcp_schema.packetIdForTextExcludingPacketId(allocator, identity_bound);
    defer allocator.free(packet_id);
    const dcp = try std.mem.replaceOwned(
        u8,
        allocator,
        identity_bound,
        "DCP-placeholder",
        packet_id,
    );
    return dcp;
}

fn buildDecisionContextTemplateAlloc(allocator: std.mem.Allocator) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"decision_context_packet\":{");
    try out.writer.writeAll("\"packet_version\":\"DCP-v2\",\"packet_id\":\"DCP-placeholder\",");
    try out.writer.writeAll("\"source\":{\"session_id\":\"one\",\"decision_id\":\"decision-one\",");
    try out.writer.writeAll("\"source_episode_id\":\"SOURCE-EPISODE\"},");
    try out.writer.writeAll("\"artifact_state\":{\"reconstructability\":\"RECONSTRUCTION\"},");
    try out.writer.writeAll("\"episode\":{\"question\":\"Which route should be selected?\",");
    try out.writer.writeAll("\"selected_route\":\"route-a\",\"rejected_routes\":[],");
    try out.writer.writeAll("\"explicit_rationale\":[],\"explicit_assumptions\":[],");
    try out.writer.writeAll("\"evidence_refs\":[],\"tools_and_artifacts\":[],");
    try out.writer.writeAll("\"skills_and_instructions\":[],\"outcome_refs\":[]},");
    try writeDecisionContextTurns(&out.writer);
    try writeDecisionContextAnchors(&out.writer);
    try out.writer.writeAll(",\"contamination\":{\"injected_skill_blocks\":false,");
    try out.writer.writeAll("\"generated_reports\":false,\"current_audit_prompt\":false,");
    try out.writer.writeAll("\"quoted_material\":false},\"limitations\":[]}}");
    return out.toOwnedSlice();
}

fn writeDecisionContextTurns(writer: *std.Io.Writer) !void {
    try writer.writeAll("\"turns\":{\"total_turns\":3,\"decision_turn_index\":2,");
    try writer.writeAll("\"decision_turn_id\":\"one\",\"first_outcome_turn_index\":3,");
    try writer.writeAll("\"source_turn_digest\":");
    try writeString(writer, test_hash_a);
    try writer.writeAll("},");
}

fn writeDecisionContextAnchors(writer: *std.Io.Writer) !void {
    try writer.writeAll("\"anchors\":{\"pre_decision\":{\"available\":true,");
    try writer.writeAll("\"keep_through_turn_index\":1,\"drop_last_n_turns\":2,\"anchor_digest\":");
    try writeString(writer, test_hash_b);
    try writer.writeAll("},\"post_decision_pre_outcome\":{\"available\":true,");
    try writer.writeAll("\"keep_through_turn_index\":2,\"drop_last_n_turns\":1,\"anchor_digest\":");
    try writeString(writer, test_hash_c);
    try writer.writeAll("},\"outcome_aware\":{\"available\":true,");
    try writer.writeAll("\"keep_through_turn_index\":3,\"drop_last_n_turns\":0,\"anchor_digest\":");
    try writeString(writer, test_hash_d);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

const test_hash_a =
    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const test_hash_b =
    "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const test_hash_c =
    "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const test_hash_d =
    "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const test_hash_e =
    "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

fn buildGovernanceAlloc(
    allocator: std.mem.Allocator,
    source_episode_id: []const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"source_governance_gate\":{\"gate_version\":\"SGG-v1\",");
    try out.writer.writeAll("\"source_ref\":");
    try writeString(&out.writer, source_episode_id);
    try out.writer.writeAll(",\"source_episode_id\":");
    try writeString(&out.writer, source_episode_id);
    try out.writer.writeAll(",\"evidence_fingerprint\":");
    try writeString(&out.writer, test_hash_e);
    try out.writer.writeAll(",\"verdict\":{\"state\":\"authoritative\",");
    try out.writer.writeAll("\"replay_allowed\":true,\"allowed_modes\":[\"replay\"]},");
    try out.writer.writeAll("\"limitations\":[]}}");
    return out.toOwnedSlice();
}

fn buildHistoricalProfileJsonAlloc(
    allocator: std.mem.Allocator,
    source_episode_id: []const u8,
    reconstructability: []const u8,
    governance: []const u8,
    governance_fingerprint: []const u8,
    dcp: []const u8,
    dcp_fingerprint: []const u8,
    contamination_fingerprint: []const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeHistoricalProfileHeader(
        &out.writer,
        governance,
        governance_fingerprint,
        dcp,
        dcp_fingerprint,
    );
    try writeTargetTextWitness(&out.writer, source_episode_id, contamination_fingerprint);
    try out.writer.writeAll(",\"retrace_mode\":\"replay\",\"required_lineage\":\"either\",");
    try out.writer.writeAll("\"required_fir_version\":\"FIR-v1\",\"reconstructability\":");
    try writeString(&out.writer, reconstructability);
    try out.writer.writeAll(",\"limitations\":[\"profile transcript reconstruction\"]}");
    return out.toOwnedSlice();
}

fn writeHistoricalProfileHeader(
    writer: *std.Io.Writer,
    governance: []const u8,
    governance_fingerprint: []const u8,
    dcp: []const u8,
    dcp_fingerprint: []const u8,
) !void {
    try writer.writeAll("{\"kind\":\"historical_decision\",");
    try writer.writeAll("\"source_governance_ref\":\"artifact:sgg\",");
    try writer.writeAll("\"source_governance_fingerprint\":");
    try writeString(writer, governance_fingerprint);
    try writer.writeAll(",\"source_governance\":");
    try writer.writeAll(governance);
    try writer.writeAll(",\"decision_context_ref\":\"artifact:dcp\",");
    try writer.writeAll("\"decision_context_fingerprint\":");
    try writeString(writer, dcp_fingerprint);
    try writer.writeAll(",\"decision_context\":");
    try writer.writeAll(dcp);
    try writer.writeAll(",\"temporal_horizon\":\"pre_decision\",");
    try writer.writeAll("\"source_target_text_policy\":\"absent\",");
}

fn writeTargetTextWitness(
    writer: *std.Io.Writer,
    source_episode_id: []const u8,
    contamination_fingerprint: []const u8,
) !void {
    try writer.writeAll("\"source_target_text_witness\":{");
    try writer.writeAll("\"schema\":\"hylo-source-target-text-witness/v1\",\"source_ref\":");
    try writeString(writer, source_episode_id);
    try writer.writeAll(",\"source_episode_id\":");
    try writeString(writer, source_episode_id);
    try writer.writeAll(",\"source_turn_digest\":");
    try writeString(writer, test_hash_a);
    try writer.writeAll(",\"dcp_contamination_fingerprint\":");
    try writeString(writer, contamination_fingerprint);
    try writer.writeAll(",\"evidence_ref\":\"seq:target-text-derivation\",\"contamination\":{");
    try writer.writeAll("\"source_target_text_present\":false,");
    try writer.writeAll("\"within_pre_decision_anchor\":false},\"sanitization\":{");
    try writer.writeAll("\"applied\":false,\"sanitized_context_fingerprint\":null,");
    try writer.writeAll("\"target_instruction_count\":1}}");
}

test "route admission accepts eligible direct evidence without publishing the episode body" {
    const episode_json = try buildTestEpisodeAlloc(
        std.testing.allocator,
        "controlled_replay",
        true,
    );
    defer std.testing.allocator.free(episode_json);
    var episode = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        episode_json,
        .{ .allocate = .alloc_always },
    );
    defer episode.deinit();
    var profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"direct\"}",
        .{},
    );
    defer profile.deinit();
    const episode_id = try requiredString(try object(episode.value), "episode_id");
    const admission_json = try deriveAlloc(std.testing.allocator, episode.value, profile.value, .{
        .campaign_id = "campaign-one",
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .source_episode_id = episode_id,
        .split = "practice",
    });
    defer std.testing.allocator.free(admission_json);
    try std.testing.expect(
        std.mem.indexOf(u8, admission_json, "\"execution_route\":\"direct\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, admission_json, "\"comparison_eligible\":true") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, admission_json, "\"stimulus\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, admission_json, "historical_response") == null);
    var admission = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        admission_json,
        .{ .allocate = .alloc_always },
    );
    defer admission.deinit();
    try requireComparisonEligible(admission.value);
}

test "replay-ineligible direct evidence is diagnostic and cannot become comparison eligible" {
    const episode_json = try buildTestEpisodeAlloc(std.testing.allocator, "transcript_only", false);
    defer std.testing.allocator.free(episode_json);
    var episode = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        episode_json,
        .{ .allocate = .alloc_always },
    );
    defer episode.deinit();
    var profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"direct\"}",
        .{},
    );
    defer profile.deinit();
    const episode_id = try requiredString(try object(episode.value), "episode_id");
    const admission_json = try deriveAlloc(std.testing.allocator, episode.value, profile.value, .{
        .campaign_id = "campaign-one",
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .source_episode_id = episode_id,
        .split = "practice",
    });
    defer std.testing.allocator.free(admission_json);
    var admission = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        admission_json,
        .{ .allocate = .alloc_always },
    );
    defer admission.deinit();
    try std.testing.expectEqualStrings(
        "diagnostic_only",
        try requiredString(try object(admission.value), "execution_route"),
    );
    try std.testing.expectError(
        error.CrfReplayIneligibleForDirectRoute,
        requireComparisonEligible(admission.value),
    );

    const root = try objectPtr(&admission.value);
    const actual_profile_fingerprint = try requiredString(root.*, "source_profile_fingerprint");
    const actual_projection_fingerprint = try requiredString(
        root.*,
        "source_episode_projection_fingerprint",
    );
    (root.getPtr("execution_route") orelse return error.MissingField).* = .{ .string = "direct" };
    (root.getPtr("comparison_eligible") orelse return error.MissingField).* = .{ .bool = true };
    try std.testing.expectError(
        error.SourceRouteAdmissionInvalid,
        validateValue(std.testing.allocator, admission.value, .{
            .campaign_id = "campaign-one",
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .source_profile_fingerprint = actual_profile_fingerprint,
            .source_episode_projection_fingerprint = actual_projection_fingerprint,
        }),
    );
}

test "governed historical evidence retains transcript limitations and authority obligations" {
    const episode_json = try buildTestEpisodeAlloc(std.testing.allocator, "transcript_only", false);
    defer std.testing.allocator.free(episode_json);
    var episode = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        episode_json,
        .{ .allocate = .alloc_always },
    );
    defer episode.deinit();
    const episode_id = try requiredString(try object(episode.value), "episode_id");
    const profile_json = try buildHistoricalProfileAlloc(
        std.testing.allocator,
        episode_id,
        "transcript_only",
    );
    defer std.testing.allocator.free(profile_json);
    var profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        profile_json,
        .{ .allocate = .alloc_always },
    );
    defer profile.deinit();
    const admission_json = try deriveAlloc(std.testing.allocator, episode.value, profile.value, .{
        .campaign_id = "campaign-one",
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .source_episode_id = episode_id,
        .split = "practice",
        .require_authoritative_historical = true,
    });
    defer std.testing.allocator.free(admission_json);
    try std.testing.expect(std.mem.indexOf(
        u8,
        admission_json,
        "\"execution_route\":\"historical_replay\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        admission_json,
        "\"source_governance_state\":\"authoritative\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        admission_json,
        "\"required_fir_version\":\"FIR-v1\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, admission_json, "fixture limitation") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, admission_json, "profile transcript reconstruction") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, admission_json, "\"stimulus\"") == null);
    var admission = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        admission_json,
        .{ .allocate = .alloc_always },
    );
    defer admission.deinit();
    try requireComparisonEligible(admission.value);
    try expectHistoricalTamperRejected(&admission.value);
    try expectHistoricalReconstructionCapped(episode.value, episode_id);
}

fn expectHistoricalTamperRejected(admission: *std.json.Value) !void {
    const root = try objectPtr(admission);
    try std.testing.expect(try requiredBool(root.*, "comparison_eligible"));
    const profile_fingerprint = try requiredString(root.*, "source_profile_fingerprint");
    const projection_fingerprint = try requiredString(
        root.*,
        "source_episode_projection_fingerprint",
    );
    (root.getPtr("comparison_eligible") orelse return error.MissingField).* = .{ .bool = false };
    try expectAdmissionInvalid(admission.*, profile_fingerprint, projection_fingerprint);
    (root.getPtr("comparison_eligible") orelse return error.MissingField).* = .{ .bool = true };
    (root.getPtr("effective_reconstruction_class") orelse return error.MissingField).* =
        .{ .string = "exact" };
    try expectAdmissionInvalid(admission.*, profile_fingerprint, projection_fingerprint);
}

fn expectAdmissionInvalid(
    admission: std.json.Value,
    profile_fingerprint: []const u8,
    projection_fingerprint: []const u8,
) !void {
    try std.testing.expectError(
        error.SourceRouteAdmissionInvalid,
        validateValue(std.testing.allocator, admission, .{
            .campaign_id = "campaign-one",
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .source_profile_fingerprint = profile_fingerprint,
            .source_episode_projection_fingerprint = projection_fingerprint,
        }),
    );
}

fn expectHistoricalReconstructionCapped(
    episode: std.json.Value,
    episode_id: []const u8,
) !void {
    const exact_profile_json = try buildHistoricalProfileAlloc(
        std.testing.allocator,
        episode_id,
        "exact",
    );
    defer std.testing.allocator.free(exact_profile_json);
    var exact_profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        exact_profile_json,
        .{ .allocate = .alloc_always },
    );
    defer exact_profile.deinit();
    const capped_json = try deriveAlloc(std.testing.allocator, episode, exact_profile.value, .{
        .campaign_id = "campaign-one",
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .source_episode_id = episode_id,
        .split = "practice",
        .require_authoritative_historical = true,
    });
    defer std.testing.allocator.free(capped_json);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capped_json,
        "\"effective_reconstruction_class\":\"transcript_only\"",
    ) != null);
}

test "authoritative exact historical evidence cannot upgrade unusable CRF fidelity" {
    inline for (.{ "diagnostic_only", "unusable" }) |fidelity_class| {
        try expectUnusableHistoricalFidelity(fidelity_class);
    }
}

fn expectUnusableHistoricalFidelity(fidelity_class: []const u8) !void {
    const episode_json = try buildTestEpisodeAlloc(
        std.testing.allocator,
        fidelity_class,
        false,
    );
    defer std.testing.allocator.free(episode_json);
    var episode = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        episode_json,
        .{ .allocate = .alloc_always },
    );
    defer episode.deinit();
    const episode_id = try requiredString(try object(episode.value), "episode_id");
    const profile_json = try buildHistoricalProfileAlloc(
        std.testing.allocator,
        episode_id,
        "exact",
    );
    defer std.testing.allocator.free(profile_json);
    var profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        profile_json,
        .{ .allocate = .alloc_always },
    );
    defer profile.deinit();
    const admission_json = try deriveAlloc(std.testing.allocator, episode.value, profile.value, .{
        .campaign_id = "campaign-one",
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .source_episode_id = episode_id,
        .split = "practice",
        .require_authoritative_historical = true,
    });
    defer std.testing.allocator.free(admission_json);
    var admission = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        admission_json,
        .{ .allocate = .alloc_always },
    );
    defer admission.deinit();
    try expectUnusableAdmission(&admission.value);
}

fn expectUnusableAdmission(admission: *std.json.Value) !void {
    const root = try objectPtr(admission);
    try std.testing.expectEqualStrings(
        "unavailable",
        try requiredString(root.*, "effective_reconstruction_class"),
    );
    try std.testing.expect(!(try requiredBool(root.*, "comparison_eligible")));
    try std.testing.expectEqualStrings(
        "authoritative",
        try requiredString(root.*, "source_governance_state"),
    );
    try std.testing.expect(try requiredBool(
        root.*,
        "source_governance_workflow_effect_allowed",
    ));
    try std.testing.expectError(
        error.DiagnosticSourceNotComparisonEligible,
        requireComparisonEligible(admission.*),
    );
    const profile_fingerprint = try requiredString(root.*, "source_profile_fingerprint");
    const projection_fingerprint = try requiredString(
        root.*,
        "source_episode_projection_fingerprint",
    );
    (root.getPtr("comparison_eligible") orelse return error.MissingField).* = .{ .bool = true };
    try expectAdmissionInvalid(admission.*, profile_fingerprint, projection_fingerprint);
}

test "route admission rejects episode identity split and profile fingerprint drift" {
    const episode_json = try buildTestEpisodeAlloc(
        std.testing.allocator,
        "controlled_replay",
        true,
    );
    defer std.testing.allocator.free(episode_json);
    var episode = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        episode_json,
        .{ .allocate = .alloc_always },
    );
    defer episode.deinit();
    var profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"direct\"}",
        .{},
    );
    defer profile.deinit();
    const episode_id = try requiredString(try object(episode.value), "episode_id");
    try expectEpisodeBindingErrors(episode.value, profile.value, episode_id);
    const admission_json = try deriveAlloc(std.testing.allocator, episode.value, profile.value, .{
        .campaign_id = "campaign-one",
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .source_episode_id = episode_id,
        .split = "practice",
    });
    defer std.testing.allocator.free(admission_json);
    var admission = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        admission_json,
        .{},
    );
    defer admission.deinit();
    const root = try object(admission.value);
    const profile_fingerprint = try requiredString(root, "source_profile_fingerprint");
    const projection_fingerprint = try requiredString(
        root,
        "source_episode_projection_fingerprint",
    );
    try expectFingerprintBindingErrors(
        admission.value,
        profile_fingerprint,
        projection_fingerprint,
    );
    try expectAdmissionBodyTamperErrors(
        admission_json,
        profile_fingerprint,
        projection_fingerprint,
    );
}

fn expectEpisodeBindingErrors(
    episode: std.json.Value,
    profile: std.json.Value,
    episode_id: []const u8,
) !void {
    try std.testing.expectError(
        error.SourceEpisodeIdentityMismatch,
        deriveAlloc(std.testing.allocator, episode, profile, .{
            .campaign_id = "campaign-one",
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .source_episode_id = "ep-mismatched00000",
            .split = "practice",
        }),
    );
    try std.testing.expectError(
        error.CrfReplayEpisodeSplitMismatch,
        deriveAlloc(std.testing.allocator, episode, profile, .{
            .campaign_id = "campaign-one",
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .source_episode_id = episode_id,
            .split = "holdout",
        }),
    );
}

const test_hash_9 =
    "sha256:9999999999999999999999999999999999999999999999999999999999999999";

fn expectFingerprintBindingErrors(
    admission: std.json.Value,
    profile_fingerprint: []const u8,
    projection_fingerprint: []const u8,
) !void {
    try std.testing.expectError(
        error.SourceRouteAdmissionBindingMismatch,
        validateValue(std.testing.allocator, admission, .{
            .campaign_id = "campaign-one",
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .source_profile_fingerprint = test_hash_9,
            .source_episode_projection_fingerprint = projection_fingerprint,
        }),
    );
    try std.testing.expectError(
        error.SourceRouteAdmissionBindingMismatch,
        validateValue(std.testing.allocator, admission, .{
            .campaign_id = "campaign-one",
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .source_profile_fingerprint = profile_fingerprint,
            .source_episode_projection_fingerprint = test_hash_9,
        }),
    );
}

fn expectAdmissionBodyTamperErrors(
    admission_json: []const u8,
    profile_fingerprint: []const u8,
    projection_fingerprint: []const u8,
) !void {
    var identity_tampered = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        admission_json,
        .{ .allocate = .alloc_always },
    );
    defer identity_tampered.deinit();
    const identity_root = try objectPtr(&identity_tampered.value);
    (identity_root.getPtr("episode_id") orelse return error.MissingField).* =
        .{ .string = "ep-0000000000000000" };
    try std.testing.expectError(
        error.SourceRouteAdmissionInvalid,
        validateValue(std.testing.allocator, identity_tampered.value, .{
            .campaign_id = "campaign-one",
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .source_profile_fingerprint = profile_fingerprint,
            .source_episode_projection_fingerprint = projection_fingerprint,
        }),
    );

    var fidelity_tampered = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        admission_json,
        .{ .allocate = .alloc_always },
    );
    defer fidelity_tampered.deinit();
    const fidelity_root = try objectPtr(&fidelity_tampered.value);
    const fidelity_value = fidelity_root.getPtr("fidelity") orelse return error.MissingField;
    const fidelity = try objectPtr(fidelity_value);
    (fidelity.getPtr("class") orelse return error.MissingField).* =
        .{ .string = "transcript_only" };
    try std.testing.expectError(
        error.SourceRouteAdmissionInvalid,
        validateValue(std.testing.allocator, fidelity_tampered.value, .{
            .campaign_id = "campaign-one",
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .source_profile_fingerprint = profile_fingerprint,
            .source_episode_projection_fingerprint = projection_fingerprint,
        }),
    );
}

fn objectPtr(value: *std.json.Value) !*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*map| map,
        else => error.ExpectedObject,
    };
}
