const std = @import("std");

pub const scanner_version = "resolve-intent-closed-scanner-v1";
pub const run_version = "RCRUN-v2";

pub const Protocol = enum {
    legacy_cleanroom,
    c3_mrpc,
    mbk_v1_legacy_open_horizon,
    intent_closed_cegis_v1,
    mixed,
    none,

    pub fn label(self: Protocol) []const u8 {
        return switch (self) {
            .legacy_cleanroom => "legacy-cleanroom",
            .c3_mrpc => "c3-mrpc",
            .mbk_v1_legacy_open_horizon => "mbk-v1-legacy-open-horizon",
            .intent_closed_cegis_v1 => "intent-closed-cegis-v1",
            .mixed => "mixed",
            .none => "none",
        };
    }
};

pub const ArtifactKind = enum {
    acceptance_contract,
    review_batch,
    review_aperture,
    counterexample,
    counterexample_basis,
    potential_cycle,
    mbkc,
    reduction_certificate,
    delivery,
    holdout,
    controller_event,
    unknown,
};

pub const EvidenceAuthority = enum {
    controller_artifact,
    controller_command_output,
    structured_skill_artifact,
    git_pr_state,
    assistant_prose,
    raw_mention,

    pub fn priority(self: EvidenceAuthority) u8 {
        return switch (self) {
            .controller_artifact => 0,
            .controller_command_output => 1,
            .structured_skill_artifact => 2,
            .git_pr_state => 3,
            .assistant_prose => 4,
            .raw_mention => 5,
        };
    }
};

pub const EvidenceRef = struct {
    authority: EvidenceAuthority,
    ref: []u8,

    pub fn deinit(self: *EvidenceRef, allocator: std.mem.Allocator) void {
        allocator.free(self.ref);
    }
};

pub const ArtifactRow = struct {
    kind: ArtifactKind,
    valid: bool,
    protocol: Protocol,
    id: ?[]u8 = null,
    campaign_id: ?[]u8 = null,
    batch_id: ?[]u8 = null,
    aperture_id: ?[]u8 = null,
    mode: ?[]u8 = null,
    state: ?[]u8 = null,
    fingerprint: ?[]u8 = null,
    acceptance_fingerprint: ?[]u8 = null,
    intent_relation: ?[]u8 = null,
    novelty: ?[]u8 = null,
    disposition: ?[]u8 = null,
    sealed: ?bool = null,
    mutation_authority: ?bool = null,
    source_refs: [][]u8 = &.{},
    evidence_refs: []EvidenceRef = &.{},
    issues: [][]u8 = &.{},

    pub fn deinit(self: *ArtifactRow, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.id);
        freeOpt(allocator, self.campaign_id);
        freeOpt(allocator, self.batch_id);
        freeOpt(allocator, self.aperture_id);
        freeOpt(allocator, self.mode);
        freeOpt(allocator, self.state);
        freeOpt(allocator, self.fingerprint);
        freeOpt(allocator, self.acceptance_fingerprint);
        freeOpt(allocator, self.intent_relation);
        freeOpt(allocator, self.novelty);
        freeOpt(allocator, self.disposition);
        freeStringList(allocator, self.source_refs);
        for (self.evidence_refs) |*ref| ref.deinit(allocator);
        allocator.free(self.evidence_refs);
        freeStringList(allocator, self.issues);
    }
};

pub const PotentialMetrics = struct {
    cycle_id: ?[]u8 = null,
    acceptance_fingerprint: ?[]u8 = null,
    primary: PrimaryTuple = .{},
    hard_surface: HardSurface = .{},
    proof_debt: ProofDebt = .{},
    evidence_refs: [][]u8 = &.{},

    pub fn deinit(self: *PotentialMetrics, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.cycle_id);
        freeOpt(allocator, self.acceptance_fingerprint);
        freeStringList(allocator, self.evidence_refs);
    }
};

pub const PrimaryTuple = struct {
    U: i64 = 0,
    L: i64 = 0,
    C: i64 = 0,
    O: i64 = 0,
};

pub const HardSurface = struct {
    truth_owners: i64 = 0,
    public_symbols: i64 = 0,
    state_variants: i64 = 0,
    protocol_cases: i64 = 0,
    fallback_compatibility_paths: i64 = 0,
    control_flow_branches: i64 = 0,
    helpers_wrappers: i64 = 0,
    test_families: i64 = 0,
};

pub const ProofDebt = struct {
    missing_law_proofs: i64 = 0,
    unmapped_proof_actions: i64 = 0,
    wound_specific_tests: i64 = 0,
};

pub const PotentialComparison = struct {
    valid: bool,
    strict_progress: bool,
    primary_decreased: bool,
    hard_surface_componentwise_nonincrease: bool,
    proof_debt_nonincrease: bool,
    comparison_across_rebase: bool,
    issues: [][]u8,

    pub fn deinit(self: *PotentialComparison, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.issues);
    }
};

pub fn parseArtifact(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
        return invalidRow(allocator, .unknown, source_ref, authority, "json_parse_error");
    };
    defer parsed.deinit();

    const root = object(parsed.value) orelse return invalidRow(allocator, .unknown, source_ref, authority, "root_not_object");
    const value = if (root.get("intent_closed_example")) |wrapped| blk: {
        const wrapped_obj = object(wrapped) orelse return invalidRow(allocator, .unknown, source_ref, authority, "example_wrapper_not_object");
        break :blk wrapped_obj.get("value") orelse return invalidRow(allocator, .unknown, source_ref, authority, "example_value_missing");
    } else parsed.value;

    const obj = object(value) orelse return invalidRow(allocator, .unknown, source_ref, authority, "artifact_not_object");
    if (obj.get("acceptance_version")) |version| return parseAcceptance(allocator, obj, version, source_ref, authority);
    if (obj.get("batch_version")) |version| return parseReviewBatch(allocator, obj, version, source_ref, authority);
    if (obj.get("aperture_version")) |version| return parseReviewAperture(allocator, obj, version, source_ref, authority);
    if (obj.get("cex_version")) |version| return parseCounterexample(allocator, obj, version, source_ref, authority);
    if (obj.get("basis_version")) |version| return parseBasis(allocator, obj, version, source_ref, authority);
    if (obj.get("potential_version")) |version| return parsePotentialArtifact(allocator, obj, version, source_ref, authority);
    if (obj.get("minimum_behavioral_kernel_certificate")) |mbkc| return parseMbkc(allocator, mbkc, source_ref, authority);
    if (obj.get("reduction_certificate_version")) |_| return parseSimpleVersioned(allocator, .reduction_certificate, .intent_closed_cegis_v1, obj, "certificate_id", source_ref, authority);
    return invalidRow(allocator, .unknown, source_ref, authority, "unsupported_artifact");
}

pub fn parsePotentialMetrics(allocator: std.mem.Allocator, json_text: []const u8) !PotentialMetrics {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    const root = object(parsed.value) orelse return error.InvalidPotential;
    const value = if (root.get("intent_closed_example")) |wrapped| blk: {
        const wrapped_obj = object(wrapped) orelse return error.InvalidPotential;
        break :blk wrapped_obj.get("value") orelse return error.InvalidPotential;
    } else parsed.value;
    const obj = object(value) orelse return error.InvalidPotential;
    if (!stringFieldEquals(obj.get("potential_version"), "PHI-v1")) return error.InvalidPotential;
    return parsePotentialMetricsObject(allocator, obj);
}

pub fn comparePotential(
    allocator: std.mem.Allocator,
    before_json: []const u8,
    after_json: []const u8,
) !PotentialComparison {
    var before = try parsePotentialMetrics(allocator, before_json);
    defer before.deinit(allocator);
    var after = try parsePotentialMetrics(allocator, after_json);
    defer after.deinit(allocator);

    var issues: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, issues.items);

    const same_ac = optionalEqual(before.acceptance_fingerprint, after.acceptance_fingerprint);
    if (!same_ac) try addIssue(allocator, &issues, "comparison_across_ac_rebase");
    const primary_decreased = primaryStrictlyDecreased(before.primary, after.primary);
    if (!primary_decreased) try addIssue(allocator, &issues, "primary_not_decreased");
    const hard_ok = hardSurfaceNonincrease(before.hard_surface, after.hard_surface);
    if (!hard_ok) try addIssue(allocator, &issues, "hard_surface_regression");
    const proof_ok = proofDebtNonincrease(before.proof_debt, after.proof_debt);
    if (!proof_ok) try addIssue(allocator, &issues, "proof_debt_regression");

    const valid = same_ac;
    const strict = valid and primary_decreased and hard_ok and proof_ok;
    return .{
        .valid = valid,
        .strict_progress = strict,
        .primary_decreased = primary_decreased,
        .hard_surface_componentwise_nonincrease = hard_ok,
        .proof_debt_nonincrease = proof_ok,
        .comparison_across_rebase = !same_ac,
        .issues = try issues.toOwnedSlice(allocator),
    };
}

fn parseAcceptance(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    version: std.json.Value,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    var row = try baseRow(allocator, .acceptance_contract, protocolForVersion(version), source_ref, authority);
    errdefer row.deinit(allocator);
    row.id = try dupAnyStringField(allocator, obj, "contract_id");
    row.campaign_id = try dupAnyStringField(allocator, obj, "campaign_id");
    row.fingerprint = try dupAnyStringField(allocator, obj, "fingerprint");
    row.sealed = boolField(obj, "sealed") orelse boolField(objectField(obj, "authority"), "sealed");
    if (jsonStringEquals(version, "AC-v2") and row.fingerprint == null) try appendIssue(allocator, &row, "missing_fingerprint");
    if (emptyArrayField(obj, "required") and emptyArrayField(obj, "criteria")) try appendIssue(allocator, &row, "empty_acceptance");
    if (emptyObjectOrArrayField(obj, "observation_language")) try appendIssue(allocator, &row, "empty_observation_language");
    row.valid = row.issues.len == 0;
    return row;
}

fn parseReviewBatch(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    version: std.json.Value,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    var row = try baseRow(allocator, .review_batch, protocolForVersion(version), source_ref, authority);
    errdefer row.deinit(allocator);
    row.id = try dupAnyStringField(allocator, obj, "batch_id");
    row.campaign_id = try dupAnyStringField(allocator, obj, "campaign_id");
    row.mode = try dupAnyStringField(allocator, obj, "mode");
    row.state = try dupAnyStringField(allocator, obj, "status");
    row.acceptance_fingerprint = try dupAnyStringField(allocator, obj, "acceptance_fingerprint");
    if (row.id == null) try appendIssue(allocator, &row, "missing_batch_id");
    if (row.mode == null) try appendIssue(allocator, &row, "missing_mode");
    if (isOpen(row.state) and arrayLen(obj, "mutation_events") > 0) try appendIssue(allocator, &row, "mutation_while_open");
    row.valid = row.issues.len == 0;
    return row;
}

fn parseReviewAperture(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    version: std.json.Value,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    var row = try baseRow(allocator, .review_aperture, protocolForVersion(version), source_ref, authority);
    errdefer row.deinit(allocator);
    row.id = try dupAnyStringField(allocator, obj, "aperture_id");
    row.batch_id = try dupAnyStringField(allocator, obj, "batch_id");
    row.mode = try dupAnyStringField(allocator, obj, "mode");
    if (row.id == null) try appendIssue(allocator, &row, "missing_aperture_id");
    if (isConformance(row.mode) and boolField(obj, "whole_diff_allowed") == true) try appendIssue(allocator, &row, "whole_diff_conformance");
    if (isConformance(row.mode) and emptyArrayField(obj, "targets")) try appendIssue(allocator, &row, "incomplete_aperture_targets");
    row.valid = row.issues.len == 0;
    return row;
}

fn parseCounterexample(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    version: std.json.Value,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    var row = try baseRow(allocator, .counterexample, protocolForVersion(version), source_ref, authority);
    errdefer row.deinit(allocator);
    row.id = try dupAnyStringField(allocator, obj, "cex_id");
    row.campaign_id = try dupAnyStringField(allocator, obj, "campaign_id");
    row.batch_id = try dupAnyStringField(allocator, obj, "batch_id");
    row.aperture_id = try dupAnyStringField(allocator, obj, "aperture_id");
    row.intent_relation = try dupAnyStringField(allocator, obj, "intent_relation");
    row.novelty = try dupAnyStringField(allocator, obj, "novelty");
    row.disposition = try dupAnyStringField(allocator, obj, "disposition");
    row.mutation_authority = boolField(obj, "mutation_authority");
    if (row.id == null) try appendIssue(allocator, &row, "missing_cex_id");
    if (emptyArrayField(obj, "minimal_trace")) try appendIssue(allocator, &row, "missing_trace");
    if (isAccepted(row.disposition) and emptyArrayField(obj, "acceptance_refs")) try appendIssue(allocator, &row, "unanchored_accepted_cex");
    if (row.mutation_authority == true) try appendIssue(allocator, &row, "caller_sets_mutation_authority");
    row.valid = row.issues.len == 0;
    return row;
}

fn parseBasis(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    version: std.json.Value,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    var row = try baseRow(allocator, .counterexample_basis, protocolForVersion(version), source_ref, authority);
    errdefer row.deinit(allocator);
    row.id = try dupAnyStringField(allocator, obj, "basis_id");
    row.campaign_id = try dupAnyStringField(allocator, obj, "campaign_id");
    row.acceptance_fingerprint = try dupAnyStringField(allocator, obj, "acceptance_fingerprint");
    row.sealed = boolField(objectField(obj, "gate"), "sealed") orelse boolField(obj, "sealed");
    if (row.id == null) try appendIssue(allocator, &row, "missing_basis_id");
    if (row.sealed != true) try appendIssue(allocator, &row, "basis_not_sealed");
    row.valid = row.issues.len == 0;
    return row;
}

fn parsePotentialArtifact(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    version: std.json.Value,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    var row = try baseRow(allocator, .potential_cycle, protocolForVersion(version), source_ref, authority);
    errdefer row.deinit(allocator);
    row.id = try dupAnyStringField(allocator, obj, "cycle_id");
    row.campaign_id = try dupAnyStringField(allocator, obj, "campaign_id");
    row.acceptance_fingerprint = try dupAnyStringField(allocator, obj, "acceptance_fingerprint");
    for (row.evidence_refs) |*ref| ref.deinit(allocator);
    allocator.free(row.evidence_refs);
    row.evidence_refs = try evidenceRefsFromField(allocator, obj, "evidence_refs", authority);
    if (row.id == null) try appendIssue(allocator, &row, "missing_cycle_id");
    if (row.acceptance_fingerprint == null) try appendIssue(allocator, &row, "missing_acceptance_fingerprint");
    if (arrayLen(obj, "evidence_refs") == 0) try appendIssue(allocator, &row, "missing_evidence_refs");
    row.valid = row.issues.len == 0;
    return row;
}

fn parseMbkc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    const obj = object(value) orelse return invalidRow(allocator, .mbkc, source_ref, authority, "mbkc_not_object");
    var row = try baseRow(allocator, .mbkc, .intent_closed_cegis_v1, source_ref, authority);
    errdefer row.deinit(allocator);
    row.id = try dupAnyStringField(allocator, obj, "certificate_id");
    row.state = try dupAnyStringField(allocator, obj, "stage");
    if (!stringFieldEquals(obj.get("certificate_version"), "MBKC-v1")) try appendIssue(allocator, &row, "invalid_mbkc_version");
    row.valid = row.issues.len == 0;
    return row;
}

fn parseSimpleVersioned(
    allocator: std.mem.Allocator,
    kind: ArtifactKind,
    protocol: Protocol,
    obj: std.json.ObjectMap,
    id_key: []const u8,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    var row = try baseRow(allocator, kind, protocol, source_ref, authority);
    errdefer row.deinit(allocator);
    row.id = try dupAnyStringField(allocator, obj, id_key);
    if (row.id == null) try appendIssue(allocator, &row, "missing_id");
    row.valid = row.issues.len == 0;
    return row;
}

fn parsePotentialMetricsObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !PotentialMetrics {
    return .{
        .cycle_id = try dupAnyStringField(allocator, obj, "cycle_id"),
        .acceptance_fingerprint = try dupAnyStringField(allocator, obj, "acceptance_fingerprint"),
        .primary = parsePrimary(objectField(obj, "primary")),
        .hard_surface = parseHardSurface(objectField(obj, "hard_surface")),
        .proof_debt = parseProofDebt(objectField(obj, "proof_debt")),
        .evidence_refs = try stringArrayField(allocator, obj, "evidence_refs"),
    };
}

fn baseRow(
    allocator: std.mem.Allocator,
    kind: ArtifactKind,
    protocol: Protocol,
    source_ref: []const u8,
    authority: EvidenceAuthority,
) !ArtifactRow {
    return .{
        .kind = kind,
        .valid = true,
        .protocol = protocol,
        .source_refs = try singletonStringList(allocator, source_ref),
        .evidence_refs = try singletonEvidenceRef(allocator, source_ref, authority),
    };
}

fn invalidRow(
    allocator: std.mem.Allocator,
    kind: ArtifactKind,
    source_ref: []const u8,
    authority: EvidenceAuthority,
    issue: []const u8,
) !ArtifactRow {
    return .{
        .kind = kind,
        .valid = false,
        .protocol = .none,
        .source_refs = try singletonStringList(allocator, source_ref),
        .evidence_refs = try singletonEvidenceRef(allocator, source_ref, authority),
        .issues = try singletonStringList(allocator, issue),
    };
}

fn protocolForVersion(value: std.json.Value) Protocol {
    if (jsonStringEquals(value, "AC-v2")) return .intent_closed_cegis_v1;
    if (jsonStringEquals(value, "RB-v1")) return .intent_closed_cegis_v1;
    if (jsonStringEquals(value, "RAP-v1")) return .intent_closed_cegis_v1;
    if (jsonStringEquals(value, "CEX-v1")) return .intent_closed_cegis_v1;
    if (jsonStringEquals(value, "CEB-v2")) return .intent_closed_cegis_v1;
    if (jsonStringEquals(value, "PHI-v1")) return .intent_closed_cegis_v1;
    if (jsonStringEquals(value, "RCA-v1")) return .mbk_v1_legacy_open_horizon;
    return .none;
}

fn parsePrimary(obj_opt: ?std.json.ObjectMap) PrimaryTuple {
    const obj = obj_opt orelse return .{};
    return .{
        .U = intField(obj, "U"),
        .L = intField(obj, "L"),
        .C = intField(obj, "C"),
        .O = intField(obj, "O"),
    };
}

fn parseHardSurface(obj_opt: ?std.json.ObjectMap) HardSurface {
    const obj = obj_opt orelse return .{};
    return .{
        .truth_owners = intField(obj, "truth_owners"),
        .public_symbols = intField(obj, "public_symbols"),
        .state_variants = intField(obj, "state_variants"),
        .protocol_cases = intField(obj, "protocol_cases"),
        .fallback_compatibility_paths = intField(obj, "fallback_compatibility_paths"),
        .control_flow_branches = intField(obj, "control_flow_branches"),
        .helpers_wrappers = intField(obj, "helpers_wrappers"),
        .test_families = intField(obj, "test_families"),
    };
}

fn parseProofDebt(obj_opt: ?std.json.ObjectMap) ProofDebt {
    const obj = obj_opt orelse return .{};
    return .{
        .missing_law_proofs = intField(obj, "missing_law_proofs"),
        .unmapped_proof_actions = intField(obj, "unmapped_proof_actions"),
        .wound_specific_tests = intField(obj, "wound_specific_tests"),
    };
}

fn primaryStrictlyDecreased(before: PrimaryTuple, after: PrimaryTuple) bool {
    if (after.U != before.U) return after.U < before.U;
    if (after.L != before.L) return after.L < before.L;
    if (after.C != before.C) return after.C < before.C;
    return after.O < before.O;
}

fn hardSurfaceNonincrease(before: HardSurface, after: HardSurface) bool {
    return after.truth_owners <= before.truth_owners and
        after.public_symbols <= before.public_symbols and
        after.state_variants <= before.state_variants and
        after.protocol_cases <= before.protocol_cases and
        after.fallback_compatibility_paths <= before.fallback_compatibility_paths and
        after.control_flow_branches <= before.control_flow_branches and
        after.helpers_wrappers <= before.helpers_wrappers and
        after.test_families <= before.test_families;
}

fn proofDebtNonincrease(before: ProofDebt, after: ProofDebt) bool {
    return after.missing_law_proofs <= before.missing_law_proofs and
        after.unmapped_proof_actions <= before.unmapped_proof_actions and
        after.wound_specific_tests <= before.wound_specific_tests;
}

fn appendIssue(allocator: std.mem.Allocator, row: *ArtifactRow, issue: []const u8) !void {
    row.issues = try appendOwnedString(allocator, row.issues, issue);
}

fn addIssue(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), issue: []const u8) !void {
    try list.append(allocator, try allocator.dupe(u8, issue));
}

fn appendOwnedString(allocator: std.mem.Allocator, existing: [][]u8, value: []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, existing.len + 1);
    @memcpy(out[0..existing.len], existing);
    out[existing.len] = try allocator.dupe(u8, value);
    allocator.free(existing);
    return out;
}

fn singletonStringList(allocator: std.mem.Allocator, value: []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, 1);
    out[0] = try allocator.dupe(u8, value);
    return out;
}

fn singletonEvidenceRef(allocator: std.mem.Allocator, value: []const u8, authority: EvidenceAuthority) ![]EvidenceRef {
    const out = try allocator.alloc(EvidenceRef, 1);
    out[0] = .{ .authority = authority, .ref = try allocator.dupe(u8, value) };
    return out;
}

fn evidenceRefsFromField(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    authority: EvidenceAuthority,
) ![]EvidenceRef {
    const value = obj.get(key) orelse return &.{};
    const arr = switch (value) {
        .array => |items| items,
        else => return &.{},
    };
    var out: std.ArrayList(EvidenceRef) = .empty;
    errdefer {
        for (out.items) |*ref| ref.deinit(allocator);
        out.deinit(allocator);
    }
    for (arr.items) |item| {
        if (item == .string) {
            try out.append(allocator, .{ .authority = authority, .ref = try allocator.dupe(u8, item.string) });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn stringArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![][]u8 {
    const value = obj.get(key) orelse return &.{};
    const arr = switch (value) {
        .array => |items| items,
        else => return &.{},
    };
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    for (arr.items) |item| {
        if (item == .string) try out.append(allocator, try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice(allocator);
}

fn dupAnyStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        .integer => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .bool => |flag| try allocator.dupe(u8, if (flag) "true" else "false"),
        else => null,
    };
}

fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return object(value);
}

fn intField(obj: std.json.ObjectMap, key: []const u8) i64 {
    const value = obj.get(key) orelse return 0;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        else => 0,
    };
}

fn boolField(obj_opt: ?std.json.ObjectMap, key: []const u8) ?bool {
    const obj = obj_opt orelse return null;
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn arrayLen(obj: std.json.ObjectMap, key: []const u8) usize {
    const value = obj.get(key) orelse return 0;
    return switch (value) {
        .array => |arr| arr.items.len,
        else => 0,
    };
}

fn emptyArrayField(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return true;
    return switch (value) {
        .array => |arr| arr.items.len == 0,
        else => true,
    };
}

fn emptyObjectOrArrayField(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return true;
    return switch (value) {
        .array => |arr| arr.items.len == 0,
        .object => |map| map.count() == 0,
        else => true,
    };
}

fn stringFieldEquals(value_opt: ?std.json.Value, expected: []const u8) bool {
    const value = value_opt orelse return false;
    return jsonStringEquals(value, expected);
}

fn jsonStringEquals(value: std.json.Value, expected: []const u8) bool {
    return switch (value) {
        .string => |text| std.mem.eql(u8, text, expected),
        else => false,
    };
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn isOpen(state: ?[]const u8) bool {
    return state != null and std.ascii.eqlIgnoreCase(state.?, "open");
}

fn isConformance(mode: ?[]const u8) bool {
    return mode != null and std.ascii.eqlIgnoreCase(mode.?, "conformance");
}

fn isAccepted(disposition: ?[]const u8) bool {
    return disposition != null and std.ascii.eqlIgnoreCase(disposition.?, "accepted");
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |text| allocator.free(text);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "counterexample parser owns strings and detects unanchored accepted mutation authority" {
    const json = try std.testing.allocator.dupe(u8,
        \\{"cex_version":"CEX-v1","cex_id":"cex.1","batch_id":"batch.1","aperture_id":"rap.1","intent_relation":"in_horizon","novelty":"new_equivalence_class","disposition":"accepted","acceptance_refs":[],"minimal_trace":["step"],"mutation_authority":true}
    );
    var row = try parseArtifact(std.testing.allocator, json, "artifact:cex.1", .controller_artifact);
    std.testing.allocator.free(json);
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(ArtifactKind.counterexample, row.kind);
    try std.testing.expectEqual(Protocol.intent_closed_cegis_v1, row.protocol);
    try std.testing.expect(row.id != null and std.mem.eql(u8, row.id.?, "cex.1"));
    try std.testing.expectEqual(@as(usize, 2), row.issues.len);
    try std.testing.expect(!row.valid);
}

test "review batch parser detects mutation while open" {
    var row = try parseArtifact(std.testing.allocator,
        \\{"batch_version":"RB-v1","batch_id":"batch.1","mode":"discovery","campaign_id":"camp","acceptance_fingerprint":"sha256:ac","status":"open","mutation_events":["write"]}
    , "artifact:batch.1", .controller_artifact);
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(ArtifactKind.review_batch, row.kind);
    try std.testing.expect(!row.valid);
    try std.testing.expectEqualStrings("mutation_while_open", row.issues[0]);
}

test "potential comparison recomputes strict progress and rejects rebase" {
    const before =
        \\{"potential_version":"PHI-v1","cycle_id":"before","acceptance_fingerprint":"sha256:ac","primary":{"U":2,"L":1,"C":1,"O":1},"hard_surface":{"truth_owners":1,"public_symbols":1,"state_variants":1,"protocol_cases":1,"fallback_compatibility_paths":1,"control_flow_branches":1,"helpers_wrappers":1,"test_families":1},"proof_debt":{"missing_law_proofs":1,"unmapped_proof_actions":1,"wound_specific_tests":1},"evidence_refs":["before"]}
    ;
    const after =
        \\{"potential_version":"PHI-v1","cycle_id":"after","acceptance_fingerprint":"sha256:ac","primary":{"U":1,"L":1,"C":1,"O":1},"hard_surface":{"truth_owners":1,"public_symbols":1,"state_variants":1,"protocol_cases":1,"fallback_compatibility_paths":1,"control_flow_branches":1,"helpers_wrappers":1,"test_families":1},"proof_debt":{"missing_law_proofs":1,"unmapped_proof_actions":1,"wound_specific_tests":1},"evidence_refs":["after"]}
    ;
    var pass = try comparePotential(std.testing.allocator, before, after);
    defer pass.deinit(std.testing.allocator);
    try std.testing.expect(pass.valid);
    try std.testing.expect(pass.strict_progress);

    const rebased =
        \\{"potential_version":"PHI-v1","cycle_id":"after","acceptance_fingerprint":"sha256:new","primary":{"U":1,"L":1,"C":1,"O":1},"hard_surface":{"truth_owners":1,"public_symbols":1,"state_variants":1,"protocol_cases":1,"fallback_compatibility_paths":1,"control_flow_branches":1,"helpers_wrappers":1,"test_families":1},"proof_debt":{"missing_law_proofs":1,"unmapped_proof_actions":1,"wound_specific_tests":1},"evidence_refs":["after"]}
    ;
    var invalid = try comparePotential(std.testing.allocator, before, rebased);
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expect(!invalid.valid);
    try std.testing.expect(invalid.comparison_across_rebase);
}
