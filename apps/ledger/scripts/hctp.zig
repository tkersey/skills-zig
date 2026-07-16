const std = @import("std");
const fixtures = @import("hctp_fixtures");
const retrace_core = @import("retrace_core");

const ValidTrialFixture = fixtures.valid_trial;
const ValidNullTrialFixture = fixtures.valid_null_trial;
const ValidRunReceiptFixture = fixtures.valid_run_receipt;
const ValidGradeReceiptFixture = fixtures.valid_grade_receipt;
const ValidPairGradeReceiptFixture = fixtures.valid_pair_grade_receipt;
const ValidRevealFixture = fixtures.valid_reveal;

pub const TrialSchema = "hylo-trial/v1";
pub const TrialFoldVersion = "hylo-trial-fold/v1";
pub const BootstrapVersion = "hylo-bootstrap-xoshiro256pp-v1";
pub const PairGradeVersion = "hylo-pair-grade/v1";
pub const TargetCommonProjectionVersion = "hylo-target-common-projection/v1";
pub const GradeCommitmentDomain = "HCTP/hylo-grade-commitment/v1";
pub const CanonicalJsonProfile = retrace_core.canonical_json.Profile;
pub const CanonicalJsonSha256Algorithm = retrace_core.canonical_json.Sha256Algorithm;

pub const FeatureFlags = [_][]const u8{
    "hylo_trial_v1",
    "hylo_lane_leases_v1",
    "hylo_lane_finish_recovery_v1",
    "hylo_lane_materialization_v1",
    "hylo_pair_grade_v1",
    "hylo_trial_reveal_v1",
    "hylo_trial_result_v1",
    "hylo_signed_attestations_v1",
    "hylo_proof_bundle_v1",
    "hylo_promotion_sentinel_binding_v1",
    "hylo_external_proof_anchor_v1",
    "hylo_grade_commit_open_v1",
};

pub fn isTrialEventKind(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "trial_registered") or
        std.mem.eql(u8, raw, "lane_started") or
        std.mem.eql(u8, raw, "lane_finished") or
        std.mem.eql(u8, raw, "grade_committed") or
        std.mem.eql(u8, raw, "pair_grade_committed") or
        std.mem.eql(u8, raw, "pair_grade_recorded") or
        std.mem.eql(u8, raw, "trial_revealed") or
        std.mem.eql(u8, raw, "trial_closed");
}

pub const Validation = struct {
    trial_id: []u8,
    fingerprint: []u8,
    unit_count: usize,
    pair_count: usize,
    lane_count: usize,

    pub fn deinit(self: *Validation, allocator: std.mem.Allocator) void {
        allocator.free(self.trial_id);
        allocator.free(self.fingerprint);
    }
};

const Purpose = enum {
    practice_repair,
    promotion,
    mechanism_probe,
    environment_probe,
    calibration_null,
    calibration_positive,
    reliability_probe,

    fn parse(raw: []const u8) ?Purpose {
        inline for (@typeInfo(Purpose).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const FactorKind = enum {
    target_snapshot,
    instruction_bundle,
    evidence_set,
    environment_variant,
    model_configuration,
    tool_policy,
    null,

    fn parse(raw: []const u8) ?FactorKind {
        inline for (@typeInfo(FactorKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

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

fn requireExactKeys(map: std.json.ObjectMap, expected: []const []const u8, err: anyerror) !void {
    if (map.count() != expected.len) return err;
    for (expected) |key| _ = map.get(key) orelse return err;
}

fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.StringRequired,
    };
}

fn integer(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.IntegerRequired,
        else => error.IntegerRequired,
    };
}

fn boolean(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |flag| flag,
        else => error.BooleanRequired,
    };
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return string(try required(map, key));
}

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(try required(map, key));
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return array(try required(map, key));
}

fn numeric(value: std.json.Value) !f64 {
    const result = switch (value) {
        .integer => |item| @as(f64, @floatFromInt(item)),
        .float => |item| item,
        else => return error.NumberRequired,
    };
    if (!std.math.isFinite(result)) return error.NumberRequired;
    return result;
}

fn optionalStringValue(value: std.json.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |item| item,
        else => error.StringRequired,
    };
}

fn requireOneOf(value: []const u8, allowed: []const []const u8, err: anyerror) !void {
    for (allowed) |candidate| if (std.mem.eql(u8, value, candidate)) return;
    return err;
}

fn validateStringArray(items: std.json.Array, require_non_empty: bool) !void {
    if (require_non_empty and items.items.len == 0) return error.ArrayEmpty;
    for (items.items, 0..) |value, index| {
        const item = try string(value);
        if (item.len == 0) return error.StringRequired;
        for (items.items[0..index]) |prior| {
            if (std.mem.eql(u8, item, try string(prior))) return error.DuplicateValue;
        }
    }
}

fn validateLimitationsRecursive(value: std.json.Value) !void {
    switch (value) {
        .array => |items| for (items.items) |item| try validateLimitationsRecursive(item),
        .object => |map| {
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "limitations")) {
                    try validateStringArray(try array(entry.value_ptr.*), false);
                }
                try validateLimitationsRecursive(entry.value_ptr.*);
            }
        },
        else => {},
    }
}

fn stringSliceContains(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn validateFingerprintedRef(map: std.json.ObjectMap, ref_key: []const u8, fingerprint_key: []const u8) !void {
    const ref_value = try required(map, ref_key);
    const fingerprint_value = try required(map, fingerprint_key);
    const ref_text = try optionalStringValue(ref_value);
    const fingerprint_text = try optionalStringValue(fingerprint_value);
    if ((ref_text == null) != (fingerprint_text == null)) return error.IncompleteArtifactReference;
    if (ref_text) |value| if (value.len == 0) return error.IncompleteArtifactReference;
    if (fingerprint_text) |value| try validateFingerprint(value);
}

fn validateOptionalOpaqueContentRef(map: std.json.ObjectMap, key: []const u8) !void {
    const raw = map.get(key) orelse return;
    const value = try optionalStringValue(raw) orelse return;
    const fingerprint = if (std.mem.startsWith(u8, value, "artifact:sha256:"))
        value["artifact:".len..]
    else if (std.mem.startsWith(u8, value, "sha256:"))
        value
    else
        return error.SealedProfileReferenceInvalid;
    try validateFingerprint(fingerprint);
}

fn validateCaseMaterializerContract(
    allocator: std.mem.Allocator,
    sealing: std.json.ObjectMap,
    required_contract: bool,
) !void {
    const contract_value = sealing.get("case_materializer_contract") orelse {
        if (required_contract) return error.CaseMaterializerMissing;
        return;
    };
    if (contract_value == .null) {
        if (required_contract) return error.CaseMaterializerMissing;
        return;
    }
    const contract = try object(contract_value);
    if (!std.mem.eql(
        u8,
        try requiredString(contract, "schema"),
        "hylo-case-materializer-contract/v1",
    )) return error.CaseMaterializerInvalid;
    const controller_id = try requiredString(contract, "controller_id");
    const materializer_id = try requiredString(contract, "materializer_id");
    const runner_id = try requiredString(contract, "runner_id");
    try validateId(controller_id);
    try validateId(materializer_id);
    try validateId(runner_id);
    if ((try requiredString(contract, "materializer_version")).len == 0) {
        return error.CaseMaterializerInvalid;
    }
    try validateFingerprint(try requiredString(contract, "materializer_binary_fingerprint"));
    if (std.mem.eql(u8, controller_id, materializer_id) or
        std.mem.eql(u8, controller_id, runner_id) or
        std.mem.eql(u8, materializer_id, runner_id)) return error.SealedSamePrincipalForbidden;
    const materializer_key_id = try requiredString(contract, "materializer_key_id");
    const runner_key_id = try requiredString(contract, "runner_key_id");
    try validateId(materializer_key_id);
    try validateId(runner_key_id);
    if (std.mem.eql(u8, materializer_key_id, runner_key_id)) return error.SealedSamePrincipalForbidden;
    if (!std.mem.eql(u8, try requiredString(contract, "capability_delivery"), "anonymous_fd") or
        !std.mem.eql(u8, try requiredString(contract, "visible_input_delivery"), "anonymous_fd") or
        !std.mem.eql(u8, try requiredString(contract, "source_profile_delivery"), "anonymous_fd") or
        !std.mem.eql(u8, try requiredString(contract, "receiver_binding"), "runner_key") or
        !std.mem.eql(u8, try requiredString(contract, "receiver_role"), "runner") or
        !try boolean(try required(contract, "single_use")))
    {
        return error.CaseMaterializerInvalid;
    }
    const observed = try digestValueAlloc(allocator, contract_value);
    defer allocator.free(observed);
    const declared = try optionalStringValue(try required(sealing, "case_materializer_fingerprint")) orelse
        return error.IncompleteArtifactReference;
    if (!std.mem.eql(u8, observed, declared)) return error.CaseMaterializerInvalid;
}

pub fn validateId(value: []const u8) !void {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return error.InvalidId;
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':') {
            return error.InvalidId;
        }
    }
}

fn validateOpaqueGraderVisibleId(value: []const u8, err: anyerror) !void {
    try validateId(value);
    var tokens = std.mem.tokenizeAny(u8, value, "-_.:");
    while (tokens.next()) |token| {
        inline for (.{ "baseline", "candidate", "old", "new", "fixed" }) |hint| {
            if (std.ascii.eqlIgnoreCase(token, hint)) return err;
        }
        if ((token.len == 4 or token.len >= 8) and
            std.ascii.isDigit(token[0]) and
            std.ascii.isDigit(token[1]) and
            std.ascii.isDigit(token[2]) and
            std.ascii.isDigit(token[3]) and
            ((token[0] == '1' and token[1] == '9') or (token[0] == '2' and token[1] == '0')))
        {
            return err;
        }
    }
}

fn validateOpaqueArmId(value: []const u8) !void {
    return validateOpaqueGraderVisibleId(value, error.ArmCommitmentInvalid);
}

fn validateOpaqueLaneId(value: []const u8) !void {
    return validateOpaqueGraderVisibleId(value, error.GraderVisibleIdentifierInvalid);
}

fn isIdSeparator(byte: u8) bool {
    return byte == '-' or byte == '_' or byte == '.' or byte == ':';
}

fn containsIdTokenSequence(container: []const u8, token_sequence: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, container, offset, token_sequence)) |index| {
        const end = index + token_sequence.len;
        const left_boundary = index == 0 or isIdSeparator(container[index - 1]);
        const right_boundary = end == container.len or isIdSeparator(container[end]);
        if (left_boundary and right_boundary) return true;
        offset = index + 1;
    }
    return false;
}

fn validateLaneArmOpacity(lane_id: []const u8, arm0_id: []const u8, arm1_id: []const u8) !void {
    if (containsIdTokenSequence(lane_id, arm0_id) or containsIdTokenSequence(lane_id, arm1_id)) {
        return error.GraderVisibleIdentifierInvalid;
    }
}

pub fn validateFingerprint(value: []const u8) !void {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return error.InvalidFingerprint;
    for (value[7..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidFingerprint;
    }
}

pub fn validateCanonicalJsonProfile(map: std.json.ObjectMap) !void {
    const value = map.get("canonical_json_profile") orelse
        return error.CanonicalJsonProfileMissing;
    if (!std.mem.eql(u8, try string(value), CanonicalJsonProfile)) {
        return error.CanonicalJsonProfileMismatch;
    }
}

fn validateUnique(
    set: *std.StringHashMap(void),
    value: []const u8,
    duplicate_error: anyerror,
) !void {
    try validateId(value);
    const entry = try set.getOrPut(value);
    if (entry.found_existing) return duplicate_error;
}

pub fn canonicalJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return retrace_core.canonical_json.canonicalJsonAlloc(allocator, value);
}

fn writeCanonicalJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value) !void {
    return retrace_core.canonical_json.writeCanonicalJson(allocator, writer, value);
}

pub fn digestValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return retrace_core.canonical_json.digestValueAlloc(allocator, value);
}

test "float-bearing HCTP identities use one stable canonical profile" {
    const Case = struct {
        name: []const u8,
        left: []const u8,
        right: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{
            .name = "trial",
            .left = "{\"schema\":\"hylo-trial/v1\",\"minimum_effect\":0.000001}",
            .right = "{\"minimum_effect\":1e-6,\"schema\":\"hylo-trial/v1\"}",
            .expected = "{\"minimum_effect\":0.000001,\"schema\":\"hylo-trial/v1\"}",
        },
        .{
            .name = "run",
            .left = "{\"schema\":\"hylo-run-receipt/v1\",\"latency_ratio\":1e23}",
            .right = "{\"latency_ratio\":1e+23,\"schema\":\"hylo-run-receipt/v1\"}",
            .expected = "{\"latency_ratio\":1e+23,\"schema\":\"hylo-run-receipt/v1\"}",
        },
        .{
            .name = "absolute grade",
            .left = "{\"score\":0.3333333333333333,\"schema\":\"hylo-grade/v2\"}",
            .right = "{\"schema\":\"hylo-grade/v2\",\"score\":3.333333333333333e-1}",
            .expected = "{\"schema\":\"hylo-grade/v2\",\"score\":0.3333333333333333}",
        },
        .{
            .name = "pair grade",
            .left = "{\"schema\":\"hylo-pair-grade/v1\",\"delta\":-0.0000033333333333333333}",
            .right = "{\"delta\":-3.3333333333333333e-6,\"schema\":\"hylo-pair-grade/v1\"}",
            .expected = "{\"delta\":-0.0000033333333333333333,\"schema\":\"hylo-pair-grade/v1\"}",
        },
        .{
            .name = "opening",
            .left = "{\"schema\":\"hylo-grade-opening/v1\",\"nonce_weight\":-0.0}",
            .right = "{\"nonce_weight\":0.0,\"schema\":\"hylo-grade-opening/v1\"}",
            .expected = "{\"nonce_weight\":0,\"schema\":\"hylo-grade-opening/v1\"}",
        },
        .{
            .name = "reveal",
            .left = "{\"schema\":\"hylo-trial-reveal/v1\",\"confidence\":333333333.33333325}",
            .right = "{\"confidence\":333333333.33333325,\"schema\":\"hylo-trial-reveal/v1\"}",
            .expected = "{\"confidence\":333333333.33333325,\"schema\":\"hylo-trial-reveal/v1\"}",
        },
        .{
            .name = "result",
            .left = "{\"schema\":\"hylo-trial-result/v1\",\"effect\":9.999999999999997e-7}",
            .right = "{\"effect\":0.0000009999999999999997,\"schema\":\"hylo-trial-result/v1\"}",
            .expected = "{\"effect\":9.999999999999997e-7,\"schema\":\"hylo-trial-result/v1\"}",
        },
        .{
            .name = "event",
            .left = "{\"sequence\":9223372036854775807,\"schema\":\"hylo-event/v1\",\"body\":{\"effect\":0.000001}}",
            .right = "{\"body\":{\"effect\":1e-6},\"schema\":\"hylo-event/v1\",\"sequence\":9223372036854775807}",
            .expected = "{\"body\":{\"effect\":0.000001},\"schema\":\"hylo-event/v1\",\"sequence\":9223372036854775807}",
        },
    };

    for (cases) |case| {
        var left = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.left, .{});
        defer left.deinit();
        var right = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.right, .{});
        defer right.deinit();
        const left_bytes = try canonicalJsonAlloc(std.testing.allocator, left.value);
        defer std.testing.allocator.free(left_bytes);
        const right_bytes = try canonicalJsonAlloc(std.testing.allocator, right.value);
        defer std.testing.allocator.free(right_bytes);
        try std.testing.expectEqualStrings(case.expected, left_bytes);
        try std.testing.expectEqualStrings(left_bytes, right_bytes);
        const left_digest = try digestValueAlloc(std.testing.allocator, left.value);
        defer std.testing.allocator.free(left_digest);
        const right_digest = try digestValueAlloc(std.testing.allocator, right.value);
        defer std.testing.allocator.free(right_digest);
        try std.testing.expectEqualStrings(left_digest, right_digest);
        try std.testing.expect(case.name.len != 0);
    }
}

test "legacy HCTP corpus remains byte locked" {
    const Locked = struct {
        path: []const u8,
        size: usize,
        digest: []const u8,
    };
    const locked = [_]Locked{
        .{ .path = "corpus-v1.json", .size = 1349, .digest = "sha256:13ea32c3e80d5b1f83287d0542ca148eb7793ff6100aab92133e0ec18edf6de5" },
        .{ .path = "campaign-v1.json", .size = 2631, .digest = "sha256:f045ba5a8df3d1e4b9d59ed5c69ec52fe009e4e138030554dfe34e835eba7397" },
        .{ .path = "scenarios.jsonl", .size = 1780, .digest = "sha256:53c20a94dd86d06e22655189ad2f45fd63f658d37d3450c52c45d7f526e215b1" },
        .{ .path = "events-v1.jsonl", .size = 8258, .digest = "sha256:648c29643c60374152dae7437a5d7e9565fd5728a4cb956ce2a6ac6ac628d960" },
        .{ .path = "expected-progress-v1.json", .size = 1782, .digest = "sha256:42a9387c0d8fba8ec5053264d1021e3218fd41c6a18d2b1abaf9c3487e555648" },
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    for (locked) |entry| {
        const root_path = try std.fmt.allocPrint(
            std.testing.allocator,
            "testdata/hctp-v1/legacy/{s}",
            .{entry.path},
        );
        defer std.testing.allocator.free(root_path);
        const seq_cwd_path = try std.fmt.allocPrint(
            std.testing.allocator,
            "../../testdata/hctp-v1/legacy/{s}",
            .{entry.path},
        );
        defer std.testing.allocator.free(seq_cwd_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            root_path,
            std.testing.allocator,
            .limited(1024 * 1024),
        ) catch try std.Io.Dir.cwd().readFileAlloc(
            io,
            seq_cwd_path,
            std.testing.allocator,
            .limited(1024 * 1024),
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(entry.size, bytes.len);
        const digest = try retrace_core.canonical_json.digestBytesAlloc(std.testing.allocator, bytes);
        defer std.testing.allocator.free(digest);
        try std.testing.expectEqualStrings(entry.digest, digest);
    }
}

fn armsEqual(left: std.json.ObjectMap, right: std.json.ObjectMap) !bool {
    return std.mem.eql(
        u8,
        try requiredString(left, "value_fingerprint"),
        try requiredString(right, "value_fingerprint"),
    ) and std.mem.eql(
        u8,
        try requiredString(left, "materialization_fingerprint"),
        try requiredString(right, "materialization_fingerprint"),
    );
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or
        (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/');
}

fn isLowerHex(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn validateProjectionPath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, '\\') != null)
    {
        return error.TargetCommonProjectionInvalid;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.TargetCommonProjectionInvalid;
        }
    }
}

fn validateTargetCommonProjection(
    allocator: std.mem.Allocator,
    factor: std.json.ObjectMap,
    witness: std.json.ObjectMap,
) !void {
    const projection_value = factor.get("target_common_projection") orelse
        return error.TargetCommonProjectionMissing;
    const projection = try object(projection_value);
    if (projection.count() != 5 or
        !std.mem.eql(u8, try requiredString(projection, "schema"), TargetCommonProjectionVersion))
    {
        return error.TargetCommonProjectionInvalid;
    }
    const verifier = try requiredObject(projection, "verifier");
    if (verifier.count() != 2 or
        !std.mem.eql(u8, try requiredString(verifier, "id"), "git-target-common-projection") or
        !std.mem.eql(u8, try requiredString(verifier, "version"), "v1"))
    {
        return error.TargetCommonProjectionInvalid;
    }
    const baseline_revision = try requiredString(projection, "baseline_revision");
    if ((baseline_revision.len != 40 and baseline_revision.len != 64) or !isLowerHex(baseline_revision)) {
        return error.TargetCommonProjectionInvalid;
    }
    const declared_roots = try requiredArray(factor, "allowed_difference_roots");
    const excluded_roots = try requiredArray(projection, "excluded_roots");
    if (excluded_roots.items.len != declared_roots.items.len) return error.TargetCommonProjectionInvalid;
    for (excluded_roots.items, 0..) |root_value, index| {
        const root = try string(root_value);
        try validateProjectionPath(root);
        if (index != 0 and !std.mem.lessThan(u8, try string(excluded_roots.items[index - 1]), root)) {
            return error.TargetCommonProjectionInvalid;
        }
        var matched = false;
        for (declared_roots.items) |declared_value| {
            if (std.mem.eql(u8, root, try string(declared_value))) matched = true;
        }
        if (!matched) return error.TargetCommonProjectionInvalid;
    }
    const entries = try requiredArray(projection, "entries");
    for (entries.items, 0..) |entry_value, index| {
        const entry = try object(entry_value);
        if (entry.count() != 5) return error.TargetCommonProjectionInvalid;
        const path = try requiredString(entry, "path");
        try validateProjectionPath(path);
        if (index != 0 and !std.mem.lessThan(u8, try requiredString(try object(entries.items[index - 1]), "path"), path)) {
            return error.TargetCommonProjectionInvalid;
        }
        for (excluded_roots.items) |root_value| {
            if (pathWithin(path, try string(root_value))) return error.TargetCommonProjectionInvalid;
        }
        const mode = try requiredString(entry, "mode");
        if (!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) {
            return error.TargetCommonProjectionEntryUnsupported;
        }
        if (!std.mem.eql(u8, try requiredString(entry, "object_type"), "blob")) {
            return error.TargetCommonProjectionEntryUnsupported;
        }
        const object_id = try requiredString(entry, "object_id");
        if ((object_id.len != 40 and object_id.len != 64) or !isLowerHex(object_id)) {
            return error.TargetCommonProjectionInvalid;
        }
        try validateFingerprint(try requiredString(entry, "content_fingerprint"));
    }
    const projection_fingerprint = try digestValueAlloc(allocator, projection_value);
    defer allocator.free(projection_fingerprint);
    if (!std.mem.eql(u8, projection_fingerprint, try requiredString(factor, "common_projection_fingerprint")) or
        !std.mem.eql(
            u8,
            projection_fingerprint,
            try requiredString(try requiredObject(witness, "common_projection"), "fingerprint"),
        ))
    {
        return error.TargetCommonProjectionMismatch;
    }
}

fn expectedVerifier(kind: FactorKind) struct { id: []const u8, version: []const u8 } {
    return switch (kind) {
        .target_snapshot => .{ .id = "git-target-projection", .version = "v1" },
        .instruction_bundle, .evidence_set => .{ .id = "canonical-projection", .version = "v1" },
        .environment_variant => .{ .id = "environment-projection", .version = "v1" },
        .model_configuration => .{ .id = "model-projection", .version = "v1" },
        .tool_policy => .{ .id = "tool-policy-projection", .version = "v1" },
        .null => .{ .id = "identical-projection", .version = "v1" },
    };
}

fn validateInterventionWitness(
    allocator: std.mem.Allocator,
    trial_id: []const u8,
    factor_kind: FactorKind,
    factor: std.json.ObjectMap,
    arm0: std.json.ObjectMap,
    arm1: std.json.ObjectMap,
) !void {
    const verifier = try requiredObject(factor, "verifier");
    const expected = expectedVerifier(factor_kind);
    if (!std.mem.eql(u8, try requiredString(verifier, "id"), expected.id) or
        !std.mem.eql(u8, try requiredString(verifier, "version"), expected.version))
    {
        return error.FactorVerifierUnsupported;
    }
    try validateFingerprint(try requiredString(verifier, "fingerprint"));
    const witness_value = factor.get("intervention_witness") orelse return error.InterventionWitnessMissing;
    const witness = try object(witness_value);
    if (!std.mem.eql(u8, try requiredString(witness, "schema"), "hylo-intervention-witness/v1") or
        !std.mem.eql(u8, try requiredString(witness, "trial_id"), trial_id) or
        !std.mem.eql(u8, try requiredString(witness, "factor_kind"), @tagName(factor_kind)))
    {
        return error.InterventionWitnessInvalid;
    }
    const actual_fingerprint = try digestValueAlloc(allocator, witness_value);
    defer allocator.free(actual_fingerprint);
    if (!std.mem.eql(
        u8,
        actual_fingerprint,
        try requiredString(factor, "intervention_witness_fingerprint"),
    )) return error.InterventionWitnessInvalid;
    const witness_verifier = try requiredObject(witness, "verifier");
    if (!std.mem.eql(u8, try requiredString(witness_verifier, "id"), expected.id) or
        !std.mem.eql(u8, try requiredString(witness_verifier, "version"), expected.version) or
        !std.mem.eql(
            u8,
            try requiredString(witness_verifier, "binary_fingerprint"),
            try requiredString(verifier, "fingerprint"),
        ))
    {
        return error.InterventionWitnessInvalid;
    }
    const verdict = try requiredObject(witness, "verdict");
    if (!try boolean(try required(verdict, "one_factor_closed"))) return error.InterventionNotClosed;
    const common_projection = try requiredObject(witness, "common_projection");
    if (!std.mem.eql(
        u8,
        try requiredString(common_projection, "fingerprint"),
        try requiredString(factor, "common_projection_fingerprint"),
    )) return error.InterventionWitnessInvalid;
    if (factor_kind == .target_snapshot) {
        try validateTargetCommonProjection(allocator, factor, witness);
    } else if (factor.get("target_common_projection") != null) {
        return error.TargetCommonProjectionInvalid;
    }
    const arm_values = try requiredObject(witness, "arm_values");
    for ([_]std.json.ObjectMap{ arm0, arm1 }) |arm| {
        const arm_id = try requiredString(arm, "arm_id");
        const witnessed = try object(arm_values.get(arm_id) orelse return error.InterventionWitnessInvalid);
        if (!std.mem.eql(
            u8,
            try requiredString(witnessed, "fingerprint"),
            try requiredString(arm, "value_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(witnessed, "snapshot_fingerprint"),
            try requiredString(arm, "materialization_fingerprint"),
        )) return error.InterventionWitnessInvalid;
    }
    const differing = try requiredObject(witness, "differing_projection");
    const allowed_roots = try requiredArray(differing, "allowed_roots");
    const declared_roots = try requiredArray(factor, "allowed_difference_roots");
    if (allowed_roots.items.len != declared_roots.items.len) return error.UnexpectedFactorDifference;
    for (allowed_roots.items, 0..) |root_value, index| {
        if (!std.mem.eql(u8, try string(root_value), try string(declared_roots.items[index]))) {
            return error.UnexpectedFactorDifference;
        }
    }
    const observed_paths = try requiredArray(differing, "observed_paths");
    if (factor_kind != .null and observed_paths.items.len == 0) return error.InterventionDifferenceMissing;
    if (factor_kind == .null and observed_paths.items.len != 0) return error.NullSentinelArmsDiffer;
    for (observed_paths.items) |path_value| {
        const path = try string(path_value);
        var allowed = false;
        for (declared_roots.items) |root_value| {
            if (pathWithin(path, try string(root_value))) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return error.UnexpectedFactorDifference;
    }
}

fn validateSourceProfile(
    allocator: std.mem.Allocator,
    profile: std.json.ObjectMap,
    purpose: Purpose,
    factor_kind: FactorKind,
    case_visibility: []const u8,
) !void {
    const kind = try requiredString(profile, "kind");
    const sealed_payload = if (profile.get("sealed_payload")) |value|
        try boolean(value)
    else
        false;
    const profile_body_delivery = if (profile.get("profile_body_delivery")) |value|
        try optionalStringValue(value)
    else
        null;
    if (profile_body_delivery) |delivery| {
        if (!std.mem.eql(u8, delivery, "source_profile_fd")) return error.SourceProfileInvalid;
        if (sealed_payload != std.mem.eql(u8, case_visibility, "case_blind")) {
            return error.CaseBlindProjectionInvalid;
        }
        const source_profile_fingerprint = try requiredString(profile, "source_profile_fingerprint");
        try validateFingerprint(source_profile_fingerprint);
        if (profile.get("source_governance") != null or profile.get("decision_context") != null) {
            return error.CaseBlindProjectionInvalid;
        }
        if (!std.mem.eql(u8, kind, "historical_decision")) return error.SourceProfileInvalid;
        try validateFingerprint(try requiredString(profile, "source_governance_fingerprint"));
        try validateFingerprint(try requiredString(profile, "decision_context_fingerprint"));
        if (sealed_payload) {
            try validateOptionalOpaqueContentRef(profile, "source_governance_ref");
            try validateOptionalOpaqueContentRef(profile, "decision_context_ref");
        } else {
            try validateFingerprintedRef(profile, "source_governance_ref", "source_governance_fingerprint");
            try validateFingerprintedRef(profile, "decision_context_ref", "decision_context_fingerprint");
        }
        if (!std.mem.eql(u8, try requiredString(profile, "temporal_horizon"), "pre_decision")) {
            return error.OutcomeAwareDecisionContext;
        }
        const source_target_text_policy = try requiredString(profile, "source_target_text_policy");
        try requireOneOf(
            source_target_text_policy,
            &.{ "absent", "preserve", "strip_and_replace" },
            error.SourceTargetTextPolicyInvalid,
        );
        if (!sealed_payload and !std.mem.eql(u8, source_target_text_policy, "strip_and_replace")) {
            return error.SourceProfileInvalid;
        }
        if (factor_kind == .target_snapshot and std.mem.eql(u8, source_target_text_policy, "preserve")) {
            return error.SourceTargetTextContamination;
        }
        try validateHistoricalReplayMode(profile, purpose);
        try requireOneOf(
            try requiredString(profile, "required_lineage"),
            &.{ "thread_fork", "rollout_transcript", "either" },
            error.RetraceLineageInvalid,
        );
        if (!std.mem.eql(u8, try requiredString(profile, "required_fir_version"), "FIR-v1")) {
            return error.RetraceFirVersionInvalid;
        }
        try requireOneOf(
            try requiredString(profile, "reconstructability"),
            &.{ "exact", "head_only", "transcript_only" },
            error.ReconstructabilityInvalid,
        );
        try validateStringArray(try requiredArray(profile, "limitations"), false);
        if (sealed_payload) {
            if (profile.get("source_target_text_witness") != null) {
                return error.CaseBlindProjectionInvalid;
            }
            try validateFingerprint(try requiredString(profile, "source_target_text_witness_fingerprint"));
        } else {
            _ = try requiredObject(profile, "source_target_text_witness");
        }
        return;
    }
    if (sealed_payload) {
        if (!std.mem.eql(u8, case_visibility, "case_blind")) return error.CaseBlindProjectionInvalid;
        const source_profile_fingerprint = try requiredString(profile, "source_profile_fingerprint");
        try validateFingerprint(source_profile_fingerprint);
        if (profile.get("source_governance") != null or profile.get("decision_context") != null) {
            return error.CaseBlindProjectionInvalid;
        }
        if (std.mem.eql(u8, kind, "direct")) return;
        if (!std.mem.eql(u8, kind, "historical_decision")) return error.SourceProfileInvalid;
        try validateFingerprintedRef(profile, "source_governance_ref", "source_governance_fingerprint");
        try validateFingerprintedRef(profile, "decision_context_ref", "decision_context_fingerprint");
        if (!std.mem.eql(u8, try requiredString(profile, "temporal_horizon"), "pre_decision")) {
            return error.OutcomeAwareDecisionContext;
        }
        const source_target_text_policy = try requiredString(profile, "source_target_text_policy");
        try requireOneOf(
            source_target_text_policy,
            &.{ "absent", "preserve", "strip_and_replace" },
            error.SourceTargetTextPolicyInvalid,
        );
        if (factor_kind == .target_snapshot and std.mem.eql(u8, source_target_text_policy, "preserve")) {
            return error.SourceTargetTextContamination;
        }
        try validateHistoricalReplayMode(profile, purpose);
        try requireOneOf(
            try requiredString(profile, "required_lineage"),
            &.{ "thread_fork", "rollout_transcript", "either" },
            error.RetraceLineageInvalid,
        );
        if (!std.mem.eql(u8, try requiredString(profile, "required_fir_version"), "FIR-v1")) {
            return error.RetraceFirVersionInvalid;
        }
        try requireOneOf(
            try requiredString(profile, "reconstructability"),
            &.{ "exact", "head_only", "transcript_only" },
            error.ReconstructabilityInvalid,
        );
        try validateStringArray(try requiredArray(profile, "limitations"), false);
        if (profile.get("source_target_text_witness") != null) {
            return error.CaseBlindProjectionInvalid;
        }
        try validateFingerprint(try requiredString(profile, "source_target_text_witness_fingerprint"));
        return;
    }
    if (std.mem.eql(u8, kind, "direct")) return;
    if (!std.mem.eql(u8, kind, "historical_decision")) return error.SourceProfileInvalid;
    try validateFingerprintedRef(profile, "source_governance_ref", "source_governance_fingerprint");
    try validateFingerprintedRef(profile, "decision_context_ref", "decision_context_fingerprint");
    const governance_value = profile.get("source_governance") orelse return error.SourceGovernanceMissing;
    const governance_fingerprint = try digestValueAlloc(allocator, governance_value);
    defer allocator.free(governance_fingerprint);
    if (!std.mem.eql(
        u8,
        governance_fingerprint,
        try requiredString(profile, "source_governance_fingerprint"),
    )) return error.SourceGovernanceInvalid;
    const governance_root = try object(governance_value);
    const governance = if (governance_root.get("source_governance_gate")) |wrapped|
        try object(wrapped)
    else
        governance_root;
    if (!std.mem.eql(u8, try requiredString(governance, "gate_version"), "SGG-v1")) {
        return error.SourceGovernanceInvalid;
    }
    const verdict = try requiredObject(governance, "verdict");
    const governance_state = try requiredString(verdict, "state");
    if (!try boolean(try required(verdict, "replay_allowed")) or
        !try listContains(try requiredArray(verdict, "allowed_modes"), "replay"))
    {
        return error.SourceGovernanceReplayForbidden;
    }
    if ((purpose == .promotion or purpose == .practice_repair) and
        !std.mem.eql(u8, governance_state, "authoritative"))
    {
        return error.SourceGovernanceNotAuthoritative;
    }
    if (!std.mem.eql(u8, governance_state, "authoritative") and
        !std.mem.eql(u8, governance_state, "declared_uncontrolled"))
    {
        return error.SourceGovernanceReplayForbidden;
    }
    const decision_context_value = profile.get("decision_context") orelse
        return error.DecisionContextMissing;
    const decision_context_fingerprint = try digestValueAlloc(allocator, decision_context_value);
    defer allocator.free(decision_context_fingerprint);
    if (!std.mem.eql(
        u8,
        decision_context_fingerprint,
        try requiredString(profile, "decision_context_fingerprint"),
    )) return error.DecisionContextInvalid;
    var dcp_report = try retrace_core.dcp_schema.validateValue(allocator, decision_context_value);
    defer dcp_report.deinit(allocator);
    if (!dcp_report.valid or !stringSliceContains(dcp_report.anchors_available, "pre_decision")) {
        return error.DecisionContextInvalid;
    }
    if (!std.mem.eql(u8, try requiredString(profile, "temporal_horizon"), "pre_decision")) {
        return error.OutcomeAwareDecisionContext;
    }
    const source_target_text_policy = try requiredString(profile, "source_target_text_policy");
    try requireOneOf(
        source_target_text_policy,
        &.{ "absent", "preserve", "strip_and_replace" },
        error.SourceTargetTextPolicyInvalid,
    );
    if (factor_kind == .target_snapshot and std.mem.eql(u8, source_target_text_policy, "preserve")) {
        const outside_anchor = if (profile.get("source_target_text_outside_anchor")) |value|
            try boolean(value)
        else
            false;
        if (!outside_anchor) return error.SourceTargetTextContamination;
    }
    try validateHistoricalReplayMode(profile, purpose);
    try requireOneOf(
        try requiredString(profile, "required_lineage"),
        &.{ "thread_fork", "rollout_transcript", "either" },
        error.RetraceLineageInvalid,
    );
    if (!std.mem.eql(u8, try requiredString(profile, "required_fir_version"), "FIR-v1")) {
        return error.RetraceFirVersionInvalid;
    }
    try requireOneOf(
        try requiredString(profile, "reconstructability"),
        &.{ "exact", "head_only", "transcript_only" },
        error.ReconstructabilityInvalid,
    );
    try validateStringArray(try requiredArray(profile, "limitations"), false);
}

fn validateHistoricalReplayMode(profile: std.json.ObjectMap, purpose: Purpose) !void {
    const retrace_mode = try requiredString(profile, "retrace_mode");
    if (std.mem.eql(u8, retrace_mode, "compare")) return error.RetraceCompareForbidden;
    try requireOneOf(
        retrace_mode,
        &.{ "audit", "explain", "replay", "challenge", "evidence_ablation", "retrospective" },
        error.RetraceModeInvalid,
    );
    if (std.mem.eql(u8, retrace_mode, "replay")) return;
    if (purpose == .promotion) return error.RetracePromotionModeInvalid;
    return error.RetraceReplayRequired;
}

fn validateExecution(allocator: std.mem.Allocator, root: std.json.ObjectMap) !void {
    const execution = try requiredObject(root, "execution");
    const fingerprint_keys = [_][]const u8{
        "runner_contract_fingerprint",
        "model_policy_fingerprint",
        "environment_fingerprint",
        "replay_policy_fingerprint",
        "effect_policy_fingerprint",
    };
    for (fingerprint_keys) |key| try validateFingerprint(try requiredString(execution, key));
    if ((try requiredString(execution, "runner_contract_ref")).len == 0) return error.RunnerContractInvalid;
    if (execution.get("runner_contract")) |contract| {
        const observed = try digestValueAlloc(allocator, contract);
        defer allocator.free(observed);
        if (!std.mem.eql(
            u8,
            observed,
            try requiredString(execution, "runner_contract_fingerprint"),
        )) return error.RunnerContractInvalid;
    }
    const runner = try requiredObject(execution, "runner_authority");
    try validateId(try requiredString(runner, "producer_id"));
    if ((try requiredString(runner, "producer_version")).len == 0) return error.RunnerContractInvalid;
    try validateFingerprint(try requiredString(runner, "binary_fingerprint"));
    try validateId(try requiredString(runner, "key_id"));
    const reset = try requiredObject(execution, "reset_policy");
    if (!try boolean(try required(reset, "fresh_thread")) or
        !try boolean(try required(reset, "fresh_workspace")) or
        !try boolean(try required(reset, "clear_target_local_caches")) or
        !try boolean(try required(reset, "sibling_output_isolation")))
    {
        return error.ResetPolicyInvalid;
    }
    if (try integer(try required(execution, "maximum_lane_duration_ms")) == 0 or
        try integer(try required(execution, "maximum_tokens_per_lane")) == 0)
    {
        return error.ExecutionBudgetInvalid;
    }
}

fn validateGrading(allocator: std.mem.Allocator, root: std.json.ObjectMap) !void {
    const grading = try requiredObject(root, "grading");
    try validateFingerprint(try requiredString(grading, "rubric_fingerprint"));
    const mode = try requiredString(grading, "mode");
    try requireOneOf(
        mode,
        &.{ "independent_absolute", "paired_blind", "composite" },
        error.GradingModeInvalid,
    );
    const judges = try requiredArray(grading, "judge_contracts");
    const oracles = try requiredArray(grading, "oracle_contracts");
    const pair_mode = std.mem.eql(u8, mode, "paired_blind") or std.mem.eql(u8, mode, "composite");
    if ((pair_mode and judges.items.len != 1) or (!pair_mode and judges.items.len != 0)) {
        return error.JudgeContractInvalid;
    }
    for (judges.items) |judge_value| {
        const judge = try object(judge_value);
        if (!std.mem.eql(u8, try requiredString(judge, "schema"), "hylo-judge-contract/v1")) {
            return error.JudgeContractInvalid;
        }
        try validateId(try requiredString(judge, "contract_id"));
        if ((try requiredString(judge, "version")).len == 0 or
            (try requiredString(judge, "contract_ref")).len == 0)
        {
            return error.JudgeContractInvalid;
        }
        try requireOneOf(
            try requiredString(judge, "kind"),
            &.{ "deterministic", "model", "human" },
            error.JudgeContractInvalid,
        );
        const declared = try requiredString(judge, "contract_fingerprint");
        try validateFingerprint(declared);
        const observed = try digestValueAlloc(allocator, try required(judge, "contract"));
        defer allocator.free(observed);
        if (!std.mem.eql(u8, declared, observed)) return error.JudgeContractInvalid;
    }
    try validateStringArray(oracles, false);
    const authorities = try requiredArray(grading, "producer_authorities");
    const sealed = std.mem.eql(
        u8,
        try requiredString(try requiredObject(root, "assurance"), "required_level"),
        "sealed",
    );
    var has_absolute = false;
    var has_pair = false;
    for (authorities.items, 0..) |authority_value, index| {
        const authority = try object(authority_value);
        const role = try requiredString(authority, "role");
        if (std.mem.eql(u8, role, "absolute_grader")) has_absolute = true else if (std.mem.eql(u8, role, "pair_grader")) has_pair = true else return error.GraderAuthorityInvalid;
        try validateId(try requiredString(authority, "producer_id"));
        if ((try requiredString(authority, "producer_version")).len == 0) {
            return error.GraderAuthorityInvalid;
        }
        try validateFingerprint(try requiredString(authority, "binary_fingerprint"));
        try validateId(try requiredString(authority, "key_id"));
        for (authorities.items[0..index]) |prior_value| {
            const prior = try object(prior_value);
            if (std.mem.eql(u8, role, try requiredString(prior, "role")) and
                std.mem.eql(
                    u8,
                    try requiredString(authority, "producer_id"),
                    try requiredString(prior, "producer_id"),
                )) return error.GraderAuthorityInvalid;
        }
    }
    if (!has_absolute or
        ((std.mem.eql(u8, mode, "paired_blind") or std.mem.eql(u8, mode, "composite")) and !has_pair))
    {
        return error.GraderAuthorityInvalid;
    }
    if (sealed) {
        const presenter = try requiredObject(grading, "presentation_materializer");
        if (!std.mem.eql(
            u8,
            try requiredString(presenter, "schema"),
            "hylo-grade-presentation-materializer/v1",
        )) return error.GradePresentationInvalid;
        try validateId(try requiredString(presenter, "producer_id"));
        if ((try requiredString(presenter, "producer_version")).len == 0) {
            return error.GradePresentationInvalid;
        }
        try validateFingerprint(try requiredString(presenter, "binary_fingerprint"));
        try validateId(try requiredString(presenter, "key_id"));
        if (!std.mem.eql(u8, try requiredString(presenter, "role"), "materializer") or
            !try boolean(try required(presenter, "single_use_capabilities")))
        {
            return error.GradePresentationInvalid;
        }
    }
    const critical = try requiredObject(grading, "critical_policy");
    if (!try boolean(try required(critical, "derived_only"))) return error.FreeFormCriticalViolationForbidden;
    if (try boolean(try required(critical, "model_may_be_sole_critical_authority"))) {
        return error.ModelSoleCriticalAuthority;
    }
    if (!try boolean(try required(grading, "require_all_terminal_before_reveal")) or
        !try boolean(try required(grading, "require_all_grades_before_reveal")))
    {
        return error.RevealPolicyInvalid;
    }
}

fn frozenProducerAuthority(
    trial_root: std.json.ObjectMap,
    producer: std.json.ObjectMap,
    role: []const u8,
    err: anyerror,
) !std.json.ObjectMap {
    const authorities = try requiredArray(
        try requiredObject(trial_root, "grading"),
        "producer_authorities",
    );
    for (authorities.items) |authority_value| {
        const authority = try object(authority_value);
        if (!std.mem.eql(u8, try requiredString(authority, "role"), role)) continue;
        if (std.mem.eql(u8, try requiredString(authority, "producer_id"), try requiredString(producer, "id")) and
            std.mem.eql(u8, try requiredString(authority, "producer_version"), try requiredString(producer, "version")) and
            std.mem.eql(
                u8,
                try requiredString(authority, "binary_fingerprint"),
                try requiredString(producer, "binary_fingerprint"),
            ) and
            std.mem.eql(u8, try requiredString(authority, "key_id"), try requiredString(producer, "key_id")))
        {
            return authority;
        }
    }
    return err;
}

fn validateFrozenProducer(
    trial_root: std.json.ObjectMap,
    producer: std.json.ObjectMap,
    role: []const u8,
    err: anyerror,
) !void {
    _ = try frozenProducerAuthority(trial_root, producer, role, err);
}

fn validateMetricMap(map: std.json.ObjectMap, dimensions: std.json.Array, non_negative: bool) !void {
    if (map.count() == 0 or map.count() != dimensions.items.len) return error.MetricPolicyMissing;
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (dimensions.items) |dimension_value| {
            if (std.mem.eql(u8, entry.key_ptr.*, try string(dimension_value))) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownPrimaryDimension;
        const value = try numeric(entry.value_ptr.*);
        if (non_negative and value < 0) return error.MetricPolicyInvalid;
    }
}

fn validatePurposeFactor(purpose: Purpose, factor_kind: FactorKind) !void {
    const allowed = switch (purpose) {
        .practice_repair => factor_kind == .target_snapshot or factor_kind == .null,
        .promotion => factor_kind == .target_snapshot,
        .mechanism_probe => factor_kind == .instruction_bundle or factor_kind == .evidence_set,
        .environment_probe => factor_kind == .environment_variant or factor_kind == .tool_policy,
        .calibration_null, .reliability_probe => factor_kind == .null,
        .calibration_positive => factor_kind == .instruction_bundle or
            factor_kind == .evidence_set or
            factor_kind == .environment_variant or
            factor_kind == .model_configuration or
            factor_kind == .tool_policy,
    };
    if (!allowed) return switch (purpose) {
        .promotion => error.PromotionFactorInvalid,
        .calibration_null => error.NullSentinelFactorInvalid,
        else => error.TrialFactorInvalid,
    };
}

fn validateEstimand(root: std.json.ObjectMap) !void {
    const estimand = try requiredObject(root, "estimand");
    const dimensions = try requiredArray(estimand, "primary_dimensions");
    try validateStringArray(dimensions, true);
    for (dimensions.items) |dimension| try validateId(try string(dimension));
    if (!std.mem.eql(u8, try requiredString(estimand, "aggregation_unit"), "independence_cluster")) {
        return error.AggregationUnitInvalid;
    }
    if (!std.mem.eql(u8, try requiredString(estimand, "effect_direction"), "candidate_minus_baseline")) {
        return error.EffectDirectionInvalid;
    }
    try validateMetricMap(try requiredObject(estimand, "minimum_effects"), dimensions, true);
    try validateMetricMap(try requiredObject(estimand, "noninferiority_margins"), dimensions, true);
    _ = try boolean(try required(estimand, "zero_critical_regressions"));
    const absolute = try requiredObject(estimand, "absolute_candidate_policy");
    if (!try boolean(try required(absolute, "require_all_candidate_lanes_pass"))) {
        return error.AbsoluteCandidatePolicyInvalid;
    }
    const uncertainty = try requiredObject(estimand, "uncertainty");
    try requireOneOf(
        try requiredString(uncertainty, "method"),
        &.{ "cluster_bootstrap", "exact_sign", "none" },
        error.UncertaintyMethodInvalid,
    );
    const confidence = try numeric(try required(uncertainty, "confidence"));
    if (confidence <= 0 or confidence >= 1) return error.ConfidenceInvalid;
    if (try integer(try required(uncertainty, "minimum_independent_clusters")) == 0) {
        return error.IndependentClusterMinimumInvalid;
    }
}

fn validateCalibration(root: std.json.ObjectMap) !void {
    const calibration = try requiredObject(root, "calibration");
    const null_refs = try requiredArray(calibration, "required_null_sentinel_refs");
    const positive_refs = try requiredArray(calibration, "required_positive_sentinel_refs");
    try validateStringArray(null_refs, false);
    try validateStringArray(positive_refs, false);
    const null_tolerance = try numeric(try required(calibration, "null_bias_tolerance"));
    const sensitivity = try numeric(try required(calibration, "positive_sensitivity_floor"));
    if (null_tolerance < 0 or null_tolerance > 1 or sensitivity < 0 or sensitivity > 1) {
        return error.CalibrationPolicyInvalid;
    }
}

fn arrayContainsString(items: std.json.Array, wanted: []const u8) !bool {
    for (items.items) |value| {
        if (std.mem.eql(u8, try string(value), wanted)) return true;
    }
    return false;
}

fn validateCommitmentCoverage(
    commitments: std.json.Array,
    cases: std.json.Array,
    case_key: []const u8,
) !void {
    for (cases.items) |case_value| {
        const case = try object(case_value);
        const fingerprint = try requiredString(case, case_key);
        if (!try arrayContainsString(commitments, fingerprint)) {
            return error.SourceSelectionReceiptInvalid;
        }
    }
    for (commitments.items) |commitment_value| {
        const commitment = try string(commitment_value);
        var matched = false;
        for (cases.items) |case_value| {
            if (std.mem.eql(u8, commitment, try requiredString(try object(case_value), case_key))) {
                matched = true;
                break;
            }
        }
        if (!matched) return error.SourceSelectionReceiptInvalid;
    }
}

fn validateSourceSelectionReceipt(
    allocator: std.mem.Allocator,
    sealing: std.json.ObjectMap,
    units: std.json.Array,
    required_receipt: bool,
    campaign_id: []const u8,
    assurance: std.json.ObjectMap,
) !void {
    const receipt_value = sealing.get("source_selection_receipt") orelse {
        if (required_receipt) return error.SourceSelectionReceiptMissing;
        return;
    };
    if (receipt_value == .null) {
        if (required_receipt) return error.SourceSelectionReceiptMissing;
        return;
    }
    const receipt_ref = try optionalStringValue(
        sealing.get("source_selection_receipt_ref") orelse return error.SourceSelectionReceiptInvalid,
    ) orelse return error.SourceSelectionReceiptInvalid;
    if (receipt_ref.len == 0) return error.SourceSelectionReceiptInvalid;
    const declared = try optionalStringValue(
        sealing.get("source_selection_receipt_fingerprint") orelse
            return error.SourceSelectionReceiptInvalid,
    ) orelse return error.SourceSelectionReceiptInvalid;
    try validateFingerprint(declared);
    const receipt = try object(receipt_value);
    if (!std.mem.eql(
        u8,
        try requiredString(receipt, "schema"),
        "hylo-source-selection-receipt/v1",
    ) or !std.mem.eql(u8, try requiredString(receipt, "receipt_fingerprint"), declared) or
        !std.mem.eql(u8, try requiredString(receipt, "campaign_id"), campaign_id))
    {
        return error.SourceSelectionReceiptInvalid;
    }
    const observed = try digestObjectOmittingAlloc(allocator, receipt_value, "receipt_fingerprint");
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, declared)) return error.SourceSelectionReceiptInvalid;
    try validateSourceOwnerAttestation(allocator, receipt_value, assurance, campaign_id);
    const cases = try requiredArray(receipt, "cases");
    if (cases.items.len != units.items.len) return error.SourceSelectionReceiptInvalid;
    const case_visibility = try requiredString(sealing, "case_visibility");
    const visible_commitments = try requiredArray(sealing, "visible_input_commitments");
    const hidden_commitments = try requiredArray(sealing, "hidden_reference_commitments");
    var seen_scenarios = std.StringHashMap(void).init(allocator);
    defer seen_scenarios.deinit();
    for (units.items) |unit_value| {
        const unit = try object(unit_value);
        const scenario_id = try requiredString(unit, "scenario_id");
        var matched: ?std.json.ObjectMap = null;
        for (cases.items) |case_value| {
            const case = try object(case_value);
            if (std.mem.eql(u8, try requiredString(case, "scenario_id"), scenario_id)) {
                if (matched != null) return error.SourceSelectionReceiptInvalid;
                matched = case;
            }
        }
        const case = matched orelse return error.SourceSelectionReceiptInvalid;
        if ((try seen_scenarios.getOrPut(scenario_id)).found_existing or
            !std.mem.eql(u8, try requiredString(case, "unit_id"), try requiredString(unit, "unit_id")) or
            !std.mem.eql(u8, try requiredString(case, "split"), try requiredString(unit, "split")) or
            !std.mem.eql(u8, try requiredString(case, "case_visibility"), case_visibility) or
            !std.mem.eql(
                u8,
                try requiredString(case, "independence_cluster_id"),
                try requiredString(unit, "independence_cluster_id"),
            ))
        {
            return error.SourceSelectionReceiptInvalid;
        }
        const visible_fingerprint = try requiredString(case, "visible_input_fingerprint");
        const hidden_fingerprint = try requiredString(case, "hidden_reference_fingerprint");
        const source_episode_fingerprint = try requiredString(case, "source_episode_fingerprint");
        const source_profile_fingerprint = try requiredString(case, "source_profile_fingerprint");
        try validateFingerprint(visible_fingerprint);
        try validateFingerprint(hidden_fingerprint);
        try validateFingerprint(source_episode_fingerprint);
        try validateFingerprint(source_profile_fingerprint);
        if (!std.mem.eql(
            u8,
            try requiredString(case, "source_episode_projection_version"),
            retrace_core.hctp_adapter.source_episode_projection_version,
        )) return error.SourceSelectionReceiptInvalid;
        const unit_profile_value = try required(unit, "source_profile");
        const case_profile_value = try required(case, "source_profile");
        const unit_profile_json = try canonicalJsonAlloc(allocator, unit_profile_value);
        defer allocator.free(unit_profile_json);
        const case_profile_json = try canonicalJsonAlloc(allocator, case_profile_value);
        defer allocator.free(case_profile_json);
        if (!std.mem.eql(u8, unit_profile_json, case_profile_json)) {
            return error.SourceSelectionReceiptInvalid;
        }
        const unit_profile = try object(unit_profile_value);
        if (std.mem.eql(u8, case_visibility, "case_blind")) {
            if (!try boolean(try required(unit_profile, "sealed_payload")) or
                !std.mem.eql(
                    u8,
                    try requiredString(unit_profile, "source_profile_fingerprint"),
                    source_profile_fingerprint,
                )) return error.CaseBlindProjectionInvalid;
            const sealed = try requiredObject(case, "sealed_case");
            if (!std.mem.eql(u8, try requiredString(sealed, "schema"), "hylo-sealed-case/v1") or
                !std.mem.eql(u8, try requiredString(sealed, "unit_id"), try requiredString(unit, "unit_id")) or
                !std.mem.eql(u8, try requiredString(sealed, "visible_input_fingerprint"), visible_fingerprint) or
                !std.mem.eql(u8, try requiredString(sealed, "hidden_reference_fingerprint"), hidden_fingerprint) or
                !std.mem.eql(u8, try requiredString(sealed, "source_episode_projection_version"), retrace_core.hctp_adapter.source_episode_projection_version) or
                !std.mem.eql(u8, try requiredString(sealed, "source_episode_fingerprint"), source_episode_fingerprint) or
                !std.mem.eql(u8, try requiredString(sealed, "source_profile_fingerprint"), source_profile_fingerprint) or
                (try requiredString(sealed, "ciphertext_or_capability_ref")).len == 0)
            {
                return error.SealedCaseCommitmentMismatch;
            }
            try validateFingerprint(try requiredString(sealed, "ciphertext_fingerprint"));
        } else {
            if (unit_profile.get("source_profile_fingerprint")) |commitment_value| {
                if (!std.mem.eql(u8, try string(commitment_value), source_profile_fingerprint) or
                    !std.mem.eql(u8, try requiredString(unit_profile, "profile_body_delivery"), "source_profile_fd"))
                {
                    return error.SourceSelectionReceiptInvalid;
                }
            } else {
                const observed_profile_fingerprint = try digestValueAlloc(allocator, unit_profile_value);
                defer allocator.free(observed_profile_fingerprint);
                if (!std.mem.eql(u8, observed_profile_fingerprint, source_profile_fingerprint)) {
                    return error.SourceSelectionReceiptInvalid;
                }
            }
        }
    }
    try validateCommitmentCoverage(visible_commitments, cases, "visible_input_fingerprint");
    try validateCommitmentCoverage(hidden_commitments, cases, "hidden_reference_fingerprint");
    try validateSourceEpisodeClusterLaw(cases);
    if (try integer(try required(
        try requiredObject(receipt, "duplicate_analysis"),
        "cross_split_exact_duplicates",
    )) != 0) return error.DuplicateSourceAcrossSplits;
}

fn validateSourceEpisodeClusterLaw(cases: std.json.Array) !void {
    for (cases.items, 0..) |left_value, left_index| {
        const left = try object(left_value);
        for (cases.items[left_index + 1 ..]) |right_value| {
            const right = try object(right_value);
            const same_visible = std.mem.eql(
                u8,
                try requiredString(left, "visible_input_fingerprint"),
                try requiredString(right, "visible_input_fingerprint"),
            );
            const same_episode = std.mem.eql(
                u8,
                try requiredString(left, "source_episode_fingerprint"),
                try requiredString(right, "source_episode_fingerprint"),
            );
            if ((same_visible or same_episode) and
                !std.mem.eql(u8, try requiredString(left, "split"), try requiredString(right, "split")))
            {
                return error.DuplicateSourceAcrossSplits;
            }
            if (same_episode and !std.mem.eql(
                u8,
                try requiredString(left, "independence_cluster_id"),
                try requiredString(right, "independence_cluster_id"),
            )) return error.SourceEpisodeClusterMismatch;
            if (std.mem.eql(
                u8,
                try requiredString(left, "independence_cluster_id"),
                try requiredString(right, "independence_cluster_id"),
            ) and !std.mem.eql(
                u8,
                try requiredString(left, "split"),
                try requiredString(right, "split"),
            )) return error.DuplicateSourceAcrossSplits;
        }
    }
}

test "source episode fingerprint fixes cluster identity and split membership" {
    const accepted_json =
        "[{\"visible_input_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"source_episode_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"split\":\"practice\",\"independence_cluster_id\":\"cluster-one\"}," ++
        "{\"visible_input_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"source_episode_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"split\":\"practice\",\"independence_cluster_id\":\"cluster-one\"}]";
    var accepted = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, accepted_json, .{});
    defer accepted.deinit();
    try validateSourceEpisodeClusterLaw(try array(accepted.value));

    const cluster_mismatch_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        accepted_json,
        "\"cluster-one\"}]",
        "\"cluster-two\"}]",
    );
    defer std.testing.allocator.free(cluster_mismatch_json);
    var cluster_mismatch = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, cluster_mismatch_json, .{});
    defer cluster_mismatch.deinit();
    try std.testing.expectError(
        error.SourceEpisodeClusterMismatch,
        validateSourceEpisodeClusterLaw(try array(cluster_mismatch.value)),
    );

    const split_mismatch_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        accepted_json,
        "\"split\":\"practice\",\"independence_cluster_id\":\"cluster-one\"}]",
        "\"split\":\"holdout\",\"independence_cluster_id\":\"cluster-one\"}]",
    );
    defer std.testing.allocator.free(split_mismatch_json);
    var split_mismatch = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, split_mismatch_json, .{});
    defer split_mismatch.deinit();
    try std.testing.expectError(
        error.DuplicateSourceAcrossSplits,
        validateSourceEpisodeClusterLaw(try array(split_mismatch.value)),
    );

    const dependent_split_mismatch_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        split_mismatch_json,
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"split\":\"holdout",
        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"split\":\"holdout",
    );
    defer std.testing.allocator.free(dependent_split_mismatch_json);
    var dependent_split_mismatch = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        dependent_split_mismatch_json,
        .{},
    );
    defer dependent_split_mismatch.deinit();
    try std.testing.expectError(
        error.DuplicateSourceAcrossSplits,
        validateSourceEpisodeClusterLaw(try array(dependent_split_mismatch.value)),
    );
}

test "case-blind historical registration accepts only an opaque target-text witness commitment" {
    const committed_profile_json =
        "{\"kind\":\"historical_decision\"," ++
        "\"source_governance_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"decision_context_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"temporal_horizon\":\"pre_decision\",\"source_target_text_policy\":\"absent\"," ++
        "\"retrace_mode\":\"replay\",\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\"," ++
        "\"reconstructability\":\"transcript_only\",\"limitations\":[]," ++
        "\"source_profile_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"," ++
        "\"profile_body_delivery\":\"source_profile_fd\",\"sealed_payload\":true," ++
        "\"source_target_text_witness_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"}";
    var committed_profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        committed_profile_json,
        .{},
    );
    defer committed_profile.deinit();
    try validateSourceProfile(
        std.testing.allocator,
        try object(committed_profile.value),
        .promotion,
        .target_snapshot,
        "case_blind",
    );

    const leaked_profile_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        committed_profile_json,
        "\"source_target_text_witness_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"",
        "\"source_target_text_witness\":{\"source_episode_id\":\"episode-private\"},\"source_target_text_witness_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"",
    );
    defer std.testing.allocator.free(leaked_profile_json);
    var leaked_profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        leaked_profile_json,
        .{},
    );
    defer leaked_profile.deinit();
    try std.testing.expectError(
        error.CaseBlindProjectionInvalid,
        validateSourceProfile(
            std.testing.allocator,
            try object(leaked_profile.value),
            .promotion,
            .target_snapshot,
            "case_blind",
        ),
    );
}

const AllocationReceiptSchema = "hylo-allocation-receipt/v1";
pub const AllocationVersion = "sha256-balanced-block-order/v1";

fn validateAllocationSeed(seed: []const u8) !void {
    if (seed.len < 32) return error.AllocationReceiptInvalid;
    const suffix = seed[seed.len - 32 ..];
    for (suffix) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
            return error.AllocationReceiptInvalid;
        }
    }
}

pub fn allocationSeedCommitmentAlloc(
    allocator: std.mem.Allocator,
    seed: []const u8,
) ![]u8 {
    try validateAllocationSeed(seed);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-allocation-seed/v1\",\"seed\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, seed);
    try out.writer.writeByte('}');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn allocationHash(
    domain: []const u8,
    seed: []const u8,
    unit_id: []const u8,
    block_id: ?[]const u8,
    repeat_index: ?u64,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(domain);
    hasher.update(&.{0});
    hasher.update(seed);
    hasher.update(&.{0});
    hasher.update(unit_id);
    if (block_id) |value| {
        hasher.update(&.{0});
        hasher.update(value);
    }
    if (repeat_index) |value| {
        var buffer: [32]u8 = undefined;
        const encoded = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
        hasher.update(&.{0});
        hasher.update(encoded);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn validateRandomizedAllocationReceipt(
    allocator: std.mem.Allocator,
    allocation: std.json.ObjectMap,
    units: std.json.Array,
    arm0_id: []const u8,
    arm1_id: []const u8,
    pair_count: usize,
) !void {
    const seed_commitment = try optionalStringValue(try required(allocation, "seed_commitment")) orelse
        return error.AllocationReceiptMissing;
    try validateFingerprint(seed_commitment);
    const receipt_value = allocation.get("allocation_receipt") orelse
        return error.AllocationReceiptMissing;
    if (receipt_value == .null) return error.AllocationReceiptMissing;
    const receipt_fingerprint = try optionalStringValue(
        allocation.get("allocation_receipt_fingerprint") orelse
            return error.AllocationReceiptMissing,
    ) orelse return error.AllocationReceiptMissing;
    try validateFingerprint(receipt_fingerprint);
    const observed_fingerprint = try digestValueAlloc(allocator, receipt_value);
    defer allocator.free(observed_fingerprint);
    if (!std.mem.eql(u8, receipt_fingerprint, observed_fingerprint)) {
        return error.AllocationReceiptInvalid;
    }
    const receipt = try object(receipt_value);
    if (!std.mem.eql(u8, try requiredString(receipt, "schema"), AllocationReceiptSchema) or
        !std.mem.eql(u8, try requiredString(receipt, "algorithm"), AllocationVersion))
    {
        return error.AllocationReceiptInvalid;
    }
    const seed = try requiredString(receipt, "seed");
    const observed_seed_commitment = try allocationSeedCommitmentAlloc(allocator, seed);
    defer allocator.free(observed_seed_commitment);
    if (!std.mem.eql(u8, seed_commitment, observed_seed_commitment)) {
        return error.AllocationReceiptInvalid;
    }
    const assignments = try requiredArray(receipt, "assignments");
    if (assignments.items.len != pair_count) return error.AllocationReceiptInvalid;

    var assignment_index: usize = 0;
    for (units.items) |unit_value| {
        const unit = try object(unit_value);
        const unit_id = try requiredString(unit, "unit_id");
        const pairs = try requiredArray(unit, "pairs");
        const unit_start = allocationHash(
            "hylo-randomized-blocks/start/v1",
            seed,
            unit_id,
            null,
            null,
        );
        const arm0_starts = (unit_start[0] & 1) == 0;
        var previous_rank: ?[32]u8 = null;
        var previous_block_id: ?[]const u8 = null;
        for (pairs.items, 0..) |pair_value, pair_index| {
            const pair = try object(pair_value);
            const pair_id = try requiredString(pair, "pair_id");
            const block_id = try requiredString(pair, "block_id");
            const repeat_index = try integer(try required(pair, "repeat_index"));
            const rank = allocationHash(
                "hylo-randomized-blocks/block/v1",
                seed,
                unit_id,
                block_id,
                repeat_index,
            );
            if (previous_rank) |prior| {
                const order = std.mem.order(u8, &prior, &rank);
                if (order == .gt or (order == .eq and
                    std.mem.order(u8, previous_block_id.?, block_id) != .lt))
                {
                    return error.AllocationReceiptInvalid;
                }
            }
            previous_rank = rank;
            previous_block_id = block_id;

            const even_position = pair_index % 2 == 0;
            const first_arm = if (arm0_starts == even_position) arm0_id else arm1_id;
            const second_arm = if (std.mem.eql(u8, first_arm, arm0_id)) arm1_id else arm0_id;
            const manifest_order = try requiredArray(pair, "order");
            if (manifest_order.items.len != 2 or
                !std.mem.eql(u8, try string(manifest_order.items[0]), first_arm) or
                !std.mem.eql(u8, try string(manifest_order.items[1]), second_arm))
            {
                return error.AllocationReceiptInvalid;
            }
            const lanes = try requiredObject(pair, "lanes");
            const first_lane = try requiredString(
                try object(lanes.get(first_arm) orelse return error.AllocationReceiptInvalid),
                "lane_id",
            );
            const second_lane = try requiredString(
                try object(lanes.get(second_arm) orelse return error.AllocationReceiptInvalid),
                "lane_id",
            );

            const assignment = try object(assignments.items[assignment_index]);
            assignment_index += 1;
            if (!std.mem.eql(u8, try requiredString(assignment, "unit_id"), unit_id) or
                !std.mem.eql(u8, try requiredString(assignment, "pair_id"), pair_id) or
                !std.mem.eql(u8, try requiredString(assignment, "block_id"), block_id) or
                try integer(try required(assignment, "repeat_index")) != repeat_index)
            {
                return error.AllocationReceiptInvalid;
            }
            const receipt_order = try requiredArray(assignment, "order");
            const lane_order = try requiredArray(assignment, "lane_order");
            if (receipt_order.items.len != 2 or lane_order.items.len != 2 or
                !std.mem.eql(u8, try string(receipt_order.items[0]), first_arm) or
                !std.mem.eql(u8, try string(receipt_order.items[1]), second_arm) or
                !std.mem.eql(u8, try string(lane_order.items[0]), first_lane) or
                !std.mem.eql(u8, try string(lane_order.items[1]), second_lane))
            {
                return error.AllocationReceiptInvalid;
            }
        }
    }
    if (assignment_index != assignments.items.len) return error.AllocationReceiptInvalid;
}

pub fn validateTrialAlloc(allocator: std.mem.Allocator, bytes: []const u8) !Validation {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = 16 * 1024 * 1024,
    });
    defer parsed.deinit();
    const root = try object(parsed.value);
    try validateLimitationsRecursive(parsed.value);
    if (!std.mem.eql(u8, try requiredString(root, "schema"), TrialSchema)) return error.TrialSchemaInvalid;
    try validateCanonicalJsonProfile(root);
    const trial_id = try requiredString(root, "trial_id");
    try validateId(trial_id);
    const campaign_id = try requiredString(root, "campaign_id");
    try validateId(campaign_id);
    const purpose = Purpose.parse(try requiredString(root, "purpose")) orelse return error.TrialPurposeInvalid;
    const target_epoch = try requiredObject(root, "target_epoch");
    const change_id = try optionalStringValue(try required(target_epoch, "change_id"));
    if (purpose == .promotion) {
        if (change_id == null) return error.PromotionChangeMissing;
        try validateId(change_id.?);
    } else if (change_id) |value| try validateId(value);
    try validateFingerprint(try requiredString(target_epoch, "before_target_fingerprint"));
    try validateFingerprint(try requiredString(target_epoch, "after_target_fingerprint"));
    const hypothesis = try requiredObject(root, "hypothesis");
    try validateId(try requiredString(hypothesis, "hypothesis_id"));
    if ((try requiredString(hypothesis, "claim")).len == 0 or
        (try requiredString(hypothesis, "primary_failure_signature")).len == 0 or
        (try requiredString(hypothesis, "falsifier")).len == 0)
    {
        return error.HypothesisInvalid;
    }
    try requireOneOf(
        try requiredString(hypothesis, "predicted_direction"),
        &.{ "candidate_better", "baseline_better", "equivalent", "detect_known_difference" },
        error.HypothesisDirectionInvalid,
    );
    try validateStringArray(try requiredArray(hypothesis, "competing_explanations"), false);

    const arms = try requiredArray(root, "arms");
    if (arms.items.len != 2) return error.PairShapeInvalid;
    const arm0 = try object(arms.items[0]);
    const arm1 = try object(arms.items[1]);
    const arm0_id = try requiredString(arm0, "arm_id");
    const arm1_id = try requiredString(arm1, "arm_id");
    try validateOpaqueArmId(arm0_id);
    try validateOpaqueArmId(arm1_id);
    if (std.mem.eql(u8, arm0_id, arm1_id)) return error.DuplicateArm;
    for ([_]std.json.ObjectMap{ arm0, arm1 }) |arm| {
        try validateFingerprint(try requiredString(arm, "value_fingerprint"));
        try validateFingerprint(try requiredString(arm, "materialization_fingerprint"));
        _ = try requiredString(arm, "materialization_ref");
    }
    const factor = try requiredObject(root, "factor");
    const factor_kind = FactorKind.parse(try requiredString(factor, "kind")) orelse return error.TrialFactorInvalid;
    if (purpose == .practice_repair and change_id == null and factor_kind != .null) {
        return error.PromotionChangeMissing;
    }
    try validatePurposeFactor(purpose, factor_kind);
    const before_target = try requiredString(target_epoch, "before_target_fingerprint");
    const after_target = try requiredString(target_epoch, "after_target_fingerprint");
    const arm0_value = try requiredString(arm0, "value_fingerprint");
    const arm1_value = try requiredString(arm1, "value_fingerprint");
    if (factor_kind == .target_snapshot) {
        if (!((std.mem.eql(u8, arm0_value, before_target) and std.mem.eql(u8, arm1_value, after_target)) or
            (std.mem.eql(u8, arm1_value, before_target) and std.mem.eql(u8, arm0_value, after_target))))
        {
            return error.InterventionNotClosed;
        }
    } else if (!std.mem.eql(u8, before_target, after_target)) {
        return error.UnexpectedFactorDifference;
    }
    const equal_arms = try armsEqual(arm0, arm1);
    if (factor_kind == .null and !equal_arms) return error.NullSentinelArmsDiffer;
    if (factor_kind != .null and equal_arms) return error.InterventionDifferenceMissing;
    if (purpose == .calibration_positive) {
        const predicted_direction = try requiredString(hypothesis, "predicted_direction");
        if (!std.mem.eql(u8, predicted_direction, "candidate_better") and
            !std.mem.eql(u8, predicted_direction, "baseline_better"))
        {
            return error.PositiveSentinelDirectionMissing;
        }
    }
    try validateInterventionWitness(allocator, trial_id, factor_kind, factor, arm0, arm1);
    const witness = try requiredString(factor, "intervention_witness_fingerprint");
    try validateFingerprint(witness);
    _ = try requiredString(factor, "intervention_witness_ref");

    const allocation = try requiredObject(root, "allocation");
    const method = try requiredString(allocation, "method");
    if (!std.mem.eql(u8, method, "balanced_ab_ba") and
        !std.mem.eql(u8, method, "randomized_blocks") and
        !std.mem.eql(u8, method, "fixed"))
    {
        return error.AllocationMethodInvalid;
    }
    if (!try boolean(try required(allocation, "position_balance_required"))) return error.PositionBalanceRequired;
    const seed_commitment = try optionalStringValue(try required(allocation, "seed_commitment"));
    if (std.mem.eql(u8, method, "randomized_blocks")) {
        if (seed_commitment == null) return error.AllocationReceiptMissing;
        try validateFingerprint(seed_commitment.?);
    } else if (seed_commitment) |value| try validateFingerprint(value);
    const arm_commitment = try requiredObject(root, "arm_map_commitment");
    if (!std.mem.eql(u8, try requiredString(arm_commitment, "algorithm"), CanonicalJsonSha256Algorithm)) {
        return error.ArmCommitmentAlgorithmInvalid;
    }
    try validateFingerprint(try requiredString(arm_commitment, "fingerprint"));

    const stop_policy = try requiredObject(root, "stop_policy");
    if (!std.mem.eql(u8, try requiredString(stop_policy, "kind"), "fixed")) return error.StopPolicyInvalid;
    const required_pairs = try integer(try required(stop_policy, "required_pairs_per_unit"));
    if (required_pairs == 0) return error.PairCountInvalid;
    if (std.mem.eql(u8, method, "balanced_ab_ba") and required_pairs % 2 != 0) {
        return error.PairOrderInvalid;
    }
    if (purpose == .promotion and root.get("early_stopping") != null) return error.PromotionTrialEarlyStoppingForbidden;

    const sealing = try requiredObject(root, "sealing");
    const case_visibility = try requiredString(sealing, "case_visibility");
    if (!std.mem.eql(u8, case_visibility, "open") and
        !std.mem.eql(u8, case_visibility, "result_blind") and
        !std.mem.eql(u8, case_visibility, "case_blind"))
    {
        return error.CaseVisibilityInvalid;
    }

    var unit_ids = std.StringHashMap(void).init(allocator);
    defer unit_ids.deinit();
    var scenario_ids = std.StringHashMap(void).init(allocator);
    defer scenario_ids.deinit();
    var pair_ids = std.StringHashMap(void).init(allocator);
    defer pair_ids.deinit();
    var lane_ids = std.StringHashMap(void).init(allocator);
    defer lane_ids.deinit();
    const units = try requiredArray(root, "units");
    if (units.items.len == 0) return error.TrialManifestEmpty;
    var pair_count: usize = 0;
    var lane_count: usize = 0;
    for (units.items) |unit_value| {
        const unit = try object(unit_value);
        try validateUnique(&unit_ids, try requiredString(unit, "unit_id"), error.DuplicateUnit);
        try validateUnique(&scenario_ids, try requiredString(unit, "scenario_id"), error.DuplicateScenarioUnit);
        try validateId(try requiredString(unit, "independence_cluster_id"));
        const split = try requiredString(unit, "split");
        if (!std.mem.eql(u8, split, "practice") and
            !std.mem.eql(u8, split, "holdout") and
            !std.mem.eql(u8, split, "challenge"))
        {
            return error.ScenarioSplitMismatch;
        }
        if (purpose != .promotion and !std.mem.eql(u8, split, "practice")) {
            return error.PracticePurposeContainsProtectedSplit;
        }
        try validateSourceProfile(
            allocator,
            try requiredObject(unit, "source_profile"),
            purpose,
            factor_kind,
            case_visibility,
        );
        const pairs = try requiredArray(unit, "pairs");
        if (pairs.items.len != required_pairs) return error.PairCountInvalid;
        var repeat_indexes = std.AutoHashMap(u64, void).init(allocator);
        defer repeat_indexes.deinit();
        var arm0_first_count: usize = 0;
        var arm1_first_count: usize = 0;
        for (pairs.items) |pair_value| {
            const pair = try object(pair_value);
            try validateUnique(&pair_ids, try requiredString(pair, "pair_id"), error.DuplicatePair);
            try validateId(try requiredString(pair, "block_id"));
            const repeat_index = try integer(try required(pair, "repeat_index"));
            if (repeat_index == 0) return error.PairOrderInvalid;
            const repeat_entry = try repeat_indexes.getOrPut(repeat_index);
            if (repeat_entry.found_existing) return error.PairOrderInvalid;
            const order = try requiredArray(pair, "order");
            if (order.items.len != 2) return error.PairOrderInvalid;
            const left = try string(order.items[0]);
            const right = try string(order.items[1]);
            if (std.mem.eql(u8, left, right) or
                (!std.mem.eql(u8, left, arm0_id) and !std.mem.eql(u8, left, arm1_id)) or
                (!std.mem.eql(u8, right, arm0_id) and !std.mem.eql(u8, right, arm1_id)))
            {
                return error.PairOrderInvalid;
            }
            if (std.mem.eql(u8, method, "balanced_ab_ba")) {
                const expected_left = if (repeat_index % 2 == 1) arm0_id else arm1_id;
                const expected_right = if (repeat_index % 2 == 1) arm1_id else arm0_id;
                if (!std.mem.eql(u8, left, expected_left) or !std.mem.eql(u8, right, expected_right)) {
                    return error.PairOrderInvalid;
                }
            }
            if (std.mem.eql(u8, left, arm0_id)) arm0_first_count += 1 else arm1_first_count += 1;
            const lanes = try requiredObject(pair, "lanes");
            if (lanes.count() != 2) return error.PairShapeInvalid;
            const lane0 = try object(lanes.get(arm0_id) orelse return error.PairShapeInvalid);
            const lane1 = try object(lanes.get(arm1_id) orelse return error.PairShapeInvalid);
            const lane0_id = try requiredString(lane0, "lane_id");
            const lane1_id = try requiredString(lane1, "lane_id");
            try validateOpaqueLaneId(lane0_id);
            try validateOpaqueLaneId(lane1_id);
            try validateLaneArmOpacity(lane0_id, arm0_id, arm1_id);
            try validateLaneArmOpacity(lane1_id, arm0_id, arm1_id);
            try validateUnique(&lane_ids, lane0_id, error.DuplicateLane);
            try validateUnique(&lane_ids, lane1_id, error.DuplicateLane);
            pair_count += 1;
            lane_count += 2;
        }
        const position_difference = if (arm0_first_count > arm1_first_count)
            arm0_first_count - arm1_first_count
        else
            arm1_first_count - arm0_first_count;
        if (position_difference > 1) return error.PairOrderInvalid;
    }
    if (std.mem.eql(u8, method, "randomized_blocks")) {
        try validateRandomizedAllocationReceipt(
            allocator,
            allocation,
            units,
            arm0_id,
            arm1_id,
            pair_count,
        );
    }

    if (std.mem.eql(u8, case_visibility, "case_blind")) {
        try validateFingerprintedRef(sealing, "case_materializer_ref", "case_materializer_fingerprint");
        if (try optionalStringValue(try required(sealing, "case_materializer_ref")) == null) {
            return error.CaseMaterializerMissing;
        }
        try validateCaseMaterializerContract(allocator, sealing, true);
    } else {
        try validateFingerprintedRef(sealing, "case_materializer_ref", "case_materializer_fingerprint");
        try validateCaseMaterializerContract(allocator, sealing, false);
    }
    if (!std.mem.eql(u8, try requiredString(sealing, "arm_visibility"), "opaque_until_reveal") or
        !std.mem.eql(u8, try requiredString(sealing, "grade_visibility"), "opaque_until_reveal"))
    {
        return error.BlindingPolicyInvalid;
    }
    try requireOneOf(
        try requiredString(sealing, "reveal_scope"),
        // HCTP-v1 has one trial-level reveal event. Pair-scoped reveal has no
        // legal state transition or opening object and therefore fails closed.
        &.{ "trial", "campaign_holdout" },
        error.RevealScopeInvalid,
    );
    const visible_input_commitments = try requiredArray(sealing, "visible_input_commitments");
    const hidden_reference_commitments = try requiredArray(sealing, "hidden_reference_commitments");
    try validateStringArray(visible_input_commitments, false);
    try validateStringArray(hidden_reference_commitments, false);
    for (visible_input_commitments.items) |value| try validateFingerprint(try string(value));
    for (hidden_reference_commitments.items) |value| try validateFingerprint(try string(value));
    const assurance = try requiredObject(root, "assurance");
    try validateSourceSelectionReceipt(
        allocator,
        sealing,
        units,
        purpose == .promotion,
        campaign_id,
        assurance,
    );
    try validateExecution(allocator, root);
    try validateGrading(allocator, root);
    try validateEstimand(root);
    try validateCalibration(root);
    const level = try requiredString(assurance, "required_level");
    if (!std.mem.eql(u8, level, "precommitted") and
        !std.mem.eql(u8, level, "receipt_bound") and
        !std.mem.eql(u8, level, "role_separated") and
        !std.mem.eql(u8, level, "sealed"))
    {
        return error.AssuranceLevelInvalid;
    }
    try validateFingerprint(try requiredString(assurance, "trust_policy_fingerprint"));
    const optional_trust_value = assurance.get("trust_policy");
    if (!std.mem.eql(u8, level, "precommitted") or optional_trust_value != null) {
        const trust_value = optional_trust_value orelse return error.TrustPolicyMissing;
        const trust = try object(trust_value);
        if (!std.mem.eql(u8, try requiredString(trust, "schema"), "hylo-trust-policy/v1")) {
            return error.TrustPolicyInvalid;
        }
        try validateId(try requiredString(trust, "policy_id"));
        const trust_fingerprint = try digestValueAlloc(allocator, trust_value);
        defer allocator.free(trust_fingerprint);
        if (!std.mem.eql(
            u8,
            trust_fingerprint,
            try requiredString(assurance, "trust_policy_fingerprint"),
        )) return error.TrustPolicyInvalid;
        const keys = try requiredArray(trust, "keys");
        if (keys.items.len == 0) return error.TrustPolicyInvalid;
        for (keys.items, 0..) |key_value, index| {
            const key = try object(key_value);
            try validateId(try requiredString(key, "key_id"));
            const public_key = try base64DecodeAlloc(allocator, try requiredString(key, "public_key_base64"));
            defer allocator.free(public_key);
            if (public_key.len != std.crypto.sign.Ed25519.PublicKey.encoded_length) {
                return error.TrustPolicyInvalid;
            }
            const roles = try requiredArray(key, "allowed_roles");
            if (roles.items.len == 0) return error.TrustPolicyInvalid;
            for (roles.items) |role_value| {
                try requireOneOf(
                    try string(role_value),
                    &.{ "runner", "absolute_grader", "pair_grader", "oracle", "human_confirmer", "materializer", "source_owner" },
                    error.TrustPolicyInvalid,
                );
            }
            try validateStringArray(try requiredArray(key, "producer_ids"), true);
            if (try listContains(roles, "source_owner")) {
                if (roles.items.len != 1) return error.TrustPolicyInvalid;
                const binary_fingerprints = try requiredArray(key, "producer_binary_fingerprints");
                try validateStringArray(binary_fingerprints, true);
                for (binary_fingerprints.items) |fingerprint_value| {
                    try validateFingerprint(try string(fingerprint_value));
                }
            }
            for (keys.items[0..index]) |prior_value| {
                const prior = try object(prior_value);
                if (std.mem.eql(
                    u8,
                    try requiredString(prior, "key_id"),
                    try requiredString(key, "key_id"),
                )) return error.TrustPolicyInvalid;
            }
        }
        const separation = try requiredObject(trust, "separation");
        if (!try boolean(try required(separation, "runner_and_pair_grader_distinct")) or
            !try boolean(try required(separation, "materializer_and_pair_grader_distinct")))
        {
            return error.TrustPolicyInvalid;
        }
        if (!try boolean(try required(separation, "human_confirmation_required_for_human_grade"))) {
            return error.TrustPolicyInvalid;
        }
    }
    const required_roles = try requiredArray(assurance, "required_distinct_roles");
    try validateStringArray(required_roles, false);
    for (required_roles.items) |role_value| {
        const role = try string(role_value);
        try requireOneOf(
            role,
            &.{ "runner", "absolute_grader", "pair_grader", "oracle", "human_confirmer", "materializer", "source_owner" },
            error.TrustPolicyInvalid,
        );
        // Oracle results do not carry an independently signed producer receipt
        // in HCTP-v1, so claiming oracle-key separation would overstate the
        // implemented assurance boundary.
        if (std.mem.eql(u8, role, "oracle")) return error.RoleSeparationInvalid;
        if (std.mem.eql(u8, role, "pair_grader")) {
            const grading_mode = try requiredString(try requiredObject(root, "grading"), "mode");
            if (std.mem.eql(u8, grading_mode, "independent_absolute")) {
                return error.RoleSeparationInvalid;
            }
        }
        if (std.mem.eql(u8, role, "materializer") and
            !std.mem.eql(u8, case_visibility, "case_blind"))
        {
            return error.RoleSeparationInvalid;
        }
        if (std.mem.eql(u8, role, "source_owner")) {
            const source_receipt = sealing.get("source_selection_receipt") orelse
                return error.RoleSeparationInvalid;
            if (source_receipt == .null) return error.RoleSeparationInvalid;
        }
    }
    if (optional_trust_value) |trust_value| {
        try validateRequiredRoleKeyMaterial(
            allocator,
            try object(trust_value),
            required_roles,
        );
    }
    if ((std.mem.eql(u8, level, "role_separated") or std.mem.eql(u8, level, "sealed")) and
        required_roles.items.len < 2)
    {
        return error.RoleSeparationInvalid;
    }
    if (std.mem.eql(u8, level, "sealed") and !std.mem.eql(u8, case_visibility, "case_blind")) {
        return error.SealedCaseVisibilityInvalid;
    }
    if (std.mem.eql(u8, level, "sealed")) {
        const contract = try requiredObject(sealing, "case_materializer_contract");
        const materializer_key_id = try requiredString(contract, "materializer_key_id");
        const runner_key_id = try requiredString(contract, "runner_key_id");
        const runner_authority = try requiredObject(try requiredObject(root, "execution"), "runner_authority");
        const presentation_materializer = try requiredObject(try requiredObject(root, "grading"), "presentation_materializer");
        if (!std.mem.eql(u8, try requiredString(runner_authority, "key_id"), runner_key_id)) {
            return error.RunnerContractInvalid;
        }
        if (!std.mem.eql(u8, try requiredString(presentation_materializer, "key_id"), materializer_key_id)) {
            return error.GradePresentationInvalid;
        }
        const trust = try object(optional_trust_value orelse return error.TrustPolicyMissing);
        const materializer_key = try keyById(trust, materializer_key_id);
        const runner_key = try keyById(trust, runner_key_id);
        if (!try listContains(try requiredArray(materializer_key, "allowed_roles"), "materializer") or
            !try listContains(try requiredArray(runner_key, "allowed_roles"), "runner") or
            try keyIdsSharePublicMaterial(allocator, trust, materializer_key_id, runner_key_id))
        {
            return error.RoleSeparationInvalid;
        }
    }
    const maximum_invalid = try integer(try required(stop_policy, "maximum_invalid_lanes"));
    if (purpose == .promotion and maximum_invalid != 0) return error.PromotionInvalidLaneToleranceForbidden;

    const fingerprint = try digestValueAlloc(allocator, parsed.value);
    errdefer allocator.free(fingerprint);
    return .{
        .trial_id = try allocator.dupe(u8, trial_id),
        .fingerprint = fingerprint,
        .unit_count = units.items.len,
        .pair_count = pair_count,
        .lane_count = lane_count,
    };
}

pub fn nullBias(left_wins: u64, right_wins: u64, arm0_wins: u64, arm1_wins: u64, eligible: u64) !f64 {
    if (eligible == 0) return error.EmptyCalibration;
    const n: f64 = @floatFromInt(eligible);
    const position = @abs(@as(f64, @floatFromInt(left_wins)) - @as(f64, @floatFromInt(right_wins))) / n;
    const arm = @abs(@as(f64, @floatFromInt(arm0_wins)) - @as(f64, @floatFromInt(arm1_wins))) / n;
    return @max(position, arm);
}

pub fn positiveSensitivity(correct_directional_preferences: u64, eligible: u64) !f64 {
    if (eligible == 0 or correct_directional_preferences > eligible) return error.EmptyCalibration;
    return @as(f64, @floatFromInt(correct_directional_preferences)) / @as(f64, @floatFromInt(eligible));
}

pub const LaneTerminal = enum {
    registered,
    started,
    completed,
    failed,
    blocked,
    aborted,
    invalid,

    fn parse(raw: []const u8) ?LaneTerminal {
        inline for (@typeInfo(LaneTerminal).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn isTerminal(self: LaneTerminal) bool {
        return self != .registered and self != .started;
    }
};

pub const LaneState = struct {
    id: []u8,
    unit_id: []u8,
    scenario_id: []u8,
    pair_id: []u8,
    arm_id: []u8,
    status: LaneTerminal = .registered,
    started_sequence: ?u64 = null,
    started_event_digest: ?[]u8 = null,
    terminal_sequence: ?u64 = null,
    lease_digest: ?[]u8 = null,
    runner_id: ?[]u8 = null,
    runner_version: ?[]u8 = null,
    runner_binary_fingerprint: ?[]u8 = null,
    runner_producer_key_id: ?[]u8 = null,
    presented_input_fingerprint: ?[]u8 = null,
    run_receipt_fingerprint: ?[]u8 = null,
    run_receipt_json: ?[]u8 = null,
    output_fingerprint: ?[]u8 = null,
    trace_fingerprint: ?[]u8 = null,
    model_id: ?[]u8 = null,
    model_provider: ?[]u8 = null,
    runtime_version: ?[]u8 = null,
    seed_json: ?[]u8 = null,
    absolute_graded: bool = false,
    grade_commitment_fingerprint: ?[]u8 = null,
    grade_commitment_json: ?[]u8 = null,
    grade_commitment_key_id: ?[]u8 = null,
    grade_commitment_grade_id: ?[]u8 = null,
    grade_id: ?[]u8 = null,
    grade_status: ?[]u8 = null,
    aggregate: ?f64 = null,
    critical_failure_count: ?usize = null,
    grade_receipt_json: ?[]u8 = null,
    runner_key_id: ?[]u8 = null,
    grade_key_id: ?[]u8 = null,
    grade_presenter_key_id: ?[]u8 = null,
    grade_presentation_capability_digest: ?[]u8 = null,
    grade_presentation_receipt_json: ?[]u8 = null,
    human_confirmation_key_id: ?[]u8 = null,

    fn deinit(self: *LaneState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.unit_id);
        allocator.free(self.scenario_id);
        allocator.free(self.pair_id);
        allocator.free(self.arm_id);
        if (self.lease_digest) |value| allocator.free(value);
        if (self.runner_id) |value| allocator.free(value);
        if (self.runner_version) |value| allocator.free(value);
        if (self.runner_binary_fingerprint) |value| allocator.free(value);
        if (self.runner_producer_key_id) |value| allocator.free(value);
        if (self.started_event_digest) |value| allocator.free(value);
        if (self.presented_input_fingerprint) |value| allocator.free(value);
        if (self.run_receipt_fingerprint) |value| allocator.free(value);
        if (self.run_receipt_json) |value| allocator.free(value);
        if (self.output_fingerprint) |value| allocator.free(value);
        if (self.trace_fingerprint) |value| allocator.free(value);
        if (self.model_id) |value| allocator.free(value);
        if (self.model_provider) |value| allocator.free(value);
        if (self.runtime_version) |value| allocator.free(value);
        if (self.seed_json) |value| allocator.free(value);
        if (self.grade_commitment_fingerprint) |value| allocator.free(value);
        if (self.grade_commitment_json) |value| allocator.free(value);
        if (self.grade_commitment_key_id) |value| allocator.free(value);
        if (self.grade_commitment_grade_id) |value| allocator.free(value);
        if (self.grade_status) |value| allocator.free(value);
        if (self.grade_id) |value| allocator.free(value);
        if (self.grade_receipt_json) |value| allocator.free(value);
        if (self.runner_key_id) |value| allocator.free(value);
        if (self.grade_key_id) |value| allocator.free(value);
        if (self.grade_presenter_key_id) |value| allocator.free(value);
        if (self.grade_presentation_capability_digest) |value| allocator.free(value);
        if (self.grade_presentation_receipt_json) |value| allocator.free(value);
        if (self.human_confirmation_key_id) |value| allocator.free(value);
    }
};

pub const PairState = struct {
    id: []u8,
    unit_id: []u8,
    split: []u8,
    independence_cluster_id: []u8,
    repeat_index: u64,
    pair_graded: bool = false,
    grade_commitment_fingerprint: ?[]u8 = null,
    grade_commitment_json: ?[]u8 = null,
    grade_commitment_key_id: ?[]u8 = null,
    grader_key_id: ?[]u8 = null,
    grade_presenter_key_id: ?[]u8 = null,
    grade_presentation_capability_digest: ?[]u8 = null,
    grade_presentation_receipt_json: ?[]u8 = null,
    pair_grade_receipt_json: ?[]u8 = null,

    fn deinit(self: *PairState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.unit_id);
        allocator.free(self.split);
        allocator.free(self.independence_cluster_id);
        if (self.grade_commitment_fingerprint) |value| allocator.free(value);
        if (self.grade_commitment_json) |value| allocator.free(value);
        if (self.grade_commitment_key_id) |value| allocator.free(value);
        if (self.grader_key_id) |value| allocator.free(value);
        if (self.grade_presenter_key_id) |value| allocator.free(value);
        if (self.grade_presentation_capability_digest) |value| allocator.free(value);
        if (self.grade_presentation_receipt_json) |value| allocator.free(value);
        if (self.pair_grade_receipt_json) |value| allocator.free(value);
    }
};

pub const TrialState = struct {
    id: []u8,
    fingerprint: []u8,
    purpose: []u8,
    arm0_id: []u8,
    arm1_id: []u8,
    arm_map_commitment: []u8,
    trial_json: []u8,
    lanes: std.ArrayList(LaneState) = .empty,
    pairs: std.ArrayList(PairState) = .empty,
    requires_pair_grade: bool,
    requires_grade_commitments: bool = false,
    registration_sequence: u64,
    registration_event_digest: []u8,
    calibration_sentinel_bindings_json: ?[]u8 = null,
    reveal_json: ?[]u8 = null,
    revealed: bool = false,
    reveal_sequence: ?u64 = null,
    closed: bool = false,
    close_sequence: ?u64 = null,
    close_status: ?[]u8 = null,
    close_result_fingerprint: ?[]u8 = null,
    close_result_chain_head: ?[]u8 = null,
    baseline_arm: ?[]u8 = null,
    candidate_arm: ?[]u8 = null,

    fn deinit(self: *TrialState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.fingerprint);
        allocator.free(self.purpose);
        allocator.free(self.arm0_id);
        allocator.free(self.arm1_id);
        allocator.free(self.arm_map_commitment);
        allocator.free(self.trial_json);
        allocator.free(self.registration_event_digest);
        if (self.calibration_sentinel_bindings_json) |value| allocator.free(value);
        if (self.reveal_json) |value| allocator.free(value);
        for (self.lanes.items) |*lane| lane.deinit(allocator);
        self.lanes.deinit(allocator);
        for (self.pairs.items) |*pair| pair.deinit(allocator);
        self.pairs.deinit(allocator);
        if (self.close_status) |value| allocator.free(value);
        if (self.close_result_fingerprint) |value| allocator.free(value);
        if (self.close_result_chain_head) |value| allocator.free(value);
        if (self.baseline_arm) |value| allocator.free(value);
        if (self.candidate_arm) |value| allocator.free(value);
    }

    pub fn findLane(self: *TrialState, lane_id: []const u8) ?*LaneState {
        for (self.lanes.items) |*lane| {
            if (std.mem.eql(u8, lane.id, lane_id)) return lane;
        }
        return null;
    }

    pub fn findLaneConst(self: *const TrialState, lane_id: []const u8) ?*const LaneState {
        for (self.lanes.items) |*lane| {
            if (std.mem.eql(u8, lane.id, lane_id)) return lane;
        }
        return null;
    }

    pub fn findPair(self: *TrialState, pair_id: []const u8) ?*PairState {
        for (self.pairs.items) |*pair| {
            if (std.mem.eql(u8, pair.id, pair_id)) return pair;
        }
        return null;
    }

    pub fn findPairConst(self: *const TrialState, pair_id: []const u8) ?*const PairState {
        for (self.pairs.items) |*pair| {
            if (std.mem.eql(u8, pair.id, pair_id)) return pair;
        }
        return null;
    }

    pub fn allLanesTerminal(self: *const TrialState) bool {
        for (self.lanes.items) |lane| if (!lane.status.isTerminal()) return false;
        return true;
    }

    pub fn allRequiredGradesPresent(self: *const TrialState) bool {
        for (self.lanes.items) |lane| {
            if (lane.status == .completed and !lane.absolute_graded) return false;
        }
        if (self.requires_pair_grade) {
            for (self.pairs.items) |pair| if (!pair.pair_graded) return false;
        }
        return true;
    }

    pub fn allRequiredGradeCommitmentsPresent(self: *const TrialState) bool {
        if (!self.requires_grade_commitments) return true;
        for (self.lanes.items) |lane| {
            if (lane.status == .completed and lane.grade_commitment_fingerprint == null) return false;
        }
        if (self.requires_pair_grade) {
            for (self.pairs.items) |pair| if (pair.grade_commitment_fingerprint == null) return false;
        }
        return true;
    }
};

pub const CampaignTrials = struct {
    trials: std.ArrayList(TrialState) = .empty,

    pub fn deinit(self: *CampaignTrials, allocator: std.mem.Allocator) void {
        for (self.trials.items) |*trial| trial.deinit(allocator);
        self.trials.deinit(allocator);
    }

    pub fn findTrial(self: *CampaignTrials, trial_id: []const u8) ?*TrialState {
        for (self.trials.items) |*trial| {
            if (std.mem.eql(u8, trial.id, trial_id)) return trial;
        }
        return null;
    }

    pub fn findTrialConst(self: *const CampaignTrials, trial_id: []const u8) ?*const TrialState {
        for (self.trials.items) |*trial| {
            if (std.mem.eql(u8, trial.id, trial_id)) return trial;
        }
        return null;
    }
};

fn dupeRequiredString(allocator: std.mem.Allocator, map: std.json.ObjectMap, key: []const u8) ![]u8 {
    return allocator.dupe(u8, try requiredString(map, key));
}

fn appendManifest(
    allocator: std.mem.Allocator,
    trial: *TrialState,
    trial_object: std.json.ObjectMap,
) !void {
    const units = try requiredArray(trial_object, "units");
    for (units.items) |unit_value| {
        const unit = try object(unit_value);
        const unit_id = try requiredString(unit, "unit_id");
        const scenario_id = try requiredString(unit, "scenario_id");
        const split = try requiredString(unit, "split");
        const independence_cluster_id = try requiredString(unit, "independence_cluster_id");
        const pairs = try requiredArray(unit, "pairs");
        for (pairs.items) |pair_value| {
            const pair = try object(pair_value);
            const pair_id = try requiredString(pair, "pair_id");
            try trial.pairs.append(allocator, .{
                .id = try allocator.dupe(u8, pair_id),
                .unit_id = try allocator.dupe(u8, unit_id),
                .split = try allocator.dupe(u8, split),
                .independence_cluster_id = try allocator.dupe(u8, independence_cluster_id),
                .repeat_index = try integer(try required(pair, "repeat_index")),
            });
            const lanes = try requiredObject(pair, "lanes");
            inline for (.{ trial.arm0_id, trial.arm1_id }) |arm_id| {
                const lane_object = try object(lanes.get(arm_id) orelse return error.PairShapeInvalid);
                try trial.lanes.append(allocator, .{
                    .id = try dupeRequiredString(allocator, lane_object, "lane_id"),
                    .unit_id = try allocator.dupe(u8, unit_id),
                    .scenario_id = try allocator.dupe(u8, scenario_id),
                    .pair_id = try allocator.dupe(u8, pair_id),
                    .arm_id = try allocator.dupe(u8, arm_id),
                });
            }
        }
    }
}

fn trialStateAlloc(
    allocator: std.mem.Allocator,
    trial_value: std.json.Value,
    fingerprint: []const u8,
    registration_sequence: u64,
    registration_event_digest: []const u8,
) !TrialState {
    const trial_object = try object(trial_value);
    const arms = try requiredArray(trial_object, "arms");
    const arm0 = try object(arms.items[0]);
    const arm1 = try object(arms.items[1]);
    const grading = try requiredObject(trial_object, "grading");
    const mode = try requiredString(grading, "mode");
    var trial = TrialState{
        .id = try dupeRequiredString(allocator, trial_object, "trial_id"),
        .fingerprint = try allocator.dupe(u8, fingerprint),
        .purpose = try dupeRequiredString(allocator, trial_object, "purpose"),
        .arm0_id = try dupeRequiredString(allocator, arm0, "arm_id"),
        .arm1_id = try dupeRequiredString(allocator, arm1, "arm_id"),
        .arm_map_commitment = try dupeRequiredString(
            allocator,
            try requiredObject(trial_object, "arm_map_commitment"),
            "fingerprint",
        ),
        .trial_json = try canonicalJsonAlloc(allocator, trial_value),
        .requires_pair_grade = std.mem.eql(u8, mode, "paired_blind") or std.mem.eql(u8, mode, "composite"),
        .requires_grade_commitments = std.mem.eql(
            u8,
            try requiredString(try requiredObject(trial_object, "assurance"), "required_level"),
            "sealed",
        ),
        .registration_sequence = registration_sequence,
        .registration_event_digest = try allocator.dupe(u8, registration_event_digest),
    };
    errdefer trial.deinit(allocator);
    try appendManifest(allocator, &trial, trial_object);
    return trial;
}

fn optionalString(map: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = map.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.StringRequired,
    };
}

fn requiredBodyPayload(body_value: std.json.Value) !struct {
    body: std.json.ObjectMap,
    payload: std.json.ObjectMap,
} {
    const body = try object(body_value);
    const payload = try object(try required(body, "payload"));
    return .{ .body = body, .payload = payload };
}

fn bindCalibrationSentinelEvidence(
    allocator: std.mem.Allocator,
    trial: *TrialState,
    payload: std.json.ObjectMap,
) !void {
    const bindings_value = payload.get("calibration_sentinel_bindings");
    if (std.mem.eql(u8, trial.purpose, "promotion")) {
        const bindings = bindings_value orelse return error.CalibrationSentinelBindingsMissing;
        _ = try array(bindings);
        trial.calibration_sentinel_bindings_json = try canonicalJsonAlloc(allocator, bindings);
    } else if (bindings_value != null) {
        return error.CalibrationSentinelBindingsInvalid;
    }
}

fn writeCanonicalObjectOmitting(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    map: std.json.ObjectMap,
    omitted_key: []const u8,
) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, omitted_key)) try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    try writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try writer.writeByte(',');
        try retrace_core.canonical_json.writeCanonicalString(writer, key);
        try writer.writeByte(':');
        try writeCanonicalJson(allocator, writer, map.get(key).?);
    }
    try writer.writeByte('}');
}

pub fn digestObjectOmittingAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    omitted_key: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeCanonicalObjectOmitting(allocator, &out.writer, try object(value), omitted_key);
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn writeCanonicalObjectOmittingKeys(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    map: std.json.ObjectMap,
    omitted_keys: []const []const u8,
) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        var omitted = false;
        for (omitted_keys) |omitted_key| {
            if (std.mem.eql(u8, entry.key_ptr.*, omitted_key)) {
                omitted = true;
                break;
            }
        }
        if (!omitted) try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    try writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try writer.writeByte(',');
        try retrace_core.canonical_json.writeCanonicalString(writer, key);
        try writer.writeByte(':');
        try writeCanonicalJson(allocator, writer, map.get(key).?);
    }
    try writer.writeByte('}');
}

fn digestObjectOmittingKeysAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    omitted_keys: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeCanonicalObjectOmittingKeys(allocator, &out.writer, try object(value), omitted_keys);
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn subjectFingerprintAlloc(
    allocator: std.mem.Allocator,
    subject: std.json.Value,
) ![]u8 {
    const subject_object = try object(subject);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeCanonicalObjectOmitting(allocator, &out.writer, subject_object, "attestation");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn attestationPreimageAlloc(
    allocator: std.mem.Allocator,
    attestation: std.json.ObjectMap,
) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = attestation.iterator();
    while (iterator.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try out.writer.writeByte(',');
        try retrace_core.canonical_json.writeCanonicalString(&out.writer, key);
        try out.writer.writeByte(':');
        if (std.mem.eql(u8, key, "signature")) {
            try writeCanonicalObjectOmitting(
                allocator,
                &out.writer,
                try object(attestation.get(key).?),
                "value_base64",
            );
        } else {
            try writeCanonicalJson(allocator, &out.writer, attestation.get(key).?);
        }
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn listContains(array_value: std.json.Array, wanted: []const u8) !bool {
    for (array_value.items) |value| {
        if (std.mem.eql(u8, try string(value), wanted)) return true;
    }
    return false;
}

fn base64DecodeAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(raw) catch return error.AttestationEncodingInvalid;
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    std.base64.standard.Decoder.decode(out, raw) catch return error.AttestationEncodingInvalid;
    return out;
}

fn roleSetsRequireDistinctPrincipal(
    left_roles: std.json.Array,
    right_roles: std.json.Array,
    required_roles: std.json.Array,
) !bool {
    for (required_roles.items) |left_required_value| {
        const left_required = try string(left_required_value);
        if (!try listContains(left_roles, left_required)) continue;
        for (required_roles.items) |right_required_value| {
            const right_required = try string(right_required_value);
            if (std.mem.eql(u8, left_required, right_required) or
                !try listContains(right_roles, right_required)) continue;
            return true;
        }
    }
    return false;
}

fn validateRequiredRoleKeyMaterial(
    allocator: std.mem.Allocator,
    trust: std.json.ObjectMap,
    required_roles: std.json.Array,
) !void {
    const keys = try requiredArray(trust, "keys");
    for (keys.items, 0..) |key_value, index| {
        const key = try object(key_value);
        const roles = try requiredArray(key, "allowed_roles");
        if (try roleSetsRequireDistinctPrincipal(roles, roles, required_roles)) {
            return error.RoleSeparationInvalid;
        }
        const public_key = try base64DecodeAlloc(
            allocator,
            try requiredString(key, "public_key_base64"),
        );
        defer allocator.free(public_key);
        if (public_key.len != std.crypto.sign.Ed25519.PublicKey.encoded_length) {
            return error.TrustPolicyInvalid;
        }
        for (keys.items[0..index]) |prior_value| {
            const prior = try object(prior_value);
            const prior_public_key = try base64DecodeAlloc(
                allocator,
                try requiredString(prior, "public_key_base64"),
            );
            defer allocator.free(prior_public_key);
            if (!std.mem.eql(u8, public_key, prior_public_key)) continue;
            const prior_roles = try requiredArray(prior, "allowed_roles");
            if (try listContains(roles, "source_owner") or
                try listContains(prior_roles, "source_owner"))
            {
                return error.TrustPolicyInvalid;
            }
            if (try roleSetsRequireDistinctPrincipal(roles, prior_roles, required_roles) or
                try roleSetsRequireDistinctPrincipal(prior_roles, roles, required_roles))
            {
                return error.RoleSeparationInvalid;
            }
        }
    }
}

fn keyById(trust: std.json.ObjectMap, key_id: []const u8) !std.json.ObjectMap {
    for ((try requiredArray(trust, "keys")).items) |key_value| {
        const key = try object(key_value);
        if (std.mem.eql(u8, try requiredString(key, "key_id"), key_id)) return key;
    }
    return error.AttestationKeyUnauthorized;
}

fn keyIdsSharePublicMaterial(
    allocator: std.mem.Allocator,
    trust: std.json.ObjectMap,
    left_key_id: []const u8,
    right_key_id: []const u8,
) !bool {
    const left = try keyById(trust, left_key_id);
    const right = try keyById(trust, right_key_id);
    const left_bytes = try base64DecodeAlloc(
        allocator,
        try requiredString(left, "public_key_base64"),
    );
    defer allocator.free(left_bytes);
    const right_bytes = try base64DecodeAlloc(
        allocator,
        try requiredString(right, "public_key_base64"),
    );
    defer allocator.free(right_bytes);
    if (left_bytes.len != std.crypto.sign.Ed25519.PublicKey.encoded_length or
        right_bytes.len != std.crypto.sign.Ed25519.PublicKey.encoded_length)
    {
        return error.TrustPolicyInvalid;
    }
    return std.mem.eql(u8, left_bytes, right_bytes);
}

fn assuranceForTrial(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
) !struct {
    parsed: std.json.Parsed(std.json.Value),
    assurance: std.json.ObjectMap,
    level: []const u8,
} {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial.trial_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    const assurance = try requiredObject(try object(parsed.value), "assurance");
    return .{
        .parsed = parsed,
        .assurance = assurance,
        .level = try requiredString(assurance, "required_level"),
    };
}

fn verifyReceiptAttestationAgainstTrust(
    allocator: std.mem.Allocator,
    trust: std.json.ObjectMap,
    receipt_value: std.json.Value,
    expected_role: []const u8,
) ![]u8 {
    const receipt = try object(receipt_value);
    const attestation = try object(receipt.get("attestation") orelse return error.AttestationMissing);
    if (!std.mem.eql(u8, try requiredString(attestation, "schema"), "hylo-attestation/v1") or
        !std.mem.eql(u8, try requiredString(attestation, "role"), expected_role))
    {
        return error.AttestationInvalid;
    }
    const producer = try requiredObject(receipt, "producer");
    if (!std.mem.eql(u8, try requiredString(attestation, "producer_id"), try requiredString(producer, "id")) or
        !std.mem.eql(u8, try requiredString(attestation, "producer_version"), try requiredString(producer, "version")) or
        !std.mem.eql(u8, try requiredString(attestation, "binary_fingerprint"), try requiredString(producer, "binary_fingerprint")))
    {
        return error.AttestationInvalid;
    }
    if (!std.mem.eql(u8, try requiredString(attestation, "subject_schema"), try requiredString(receipt, "schema"))) {
        return error.AttestationInvalid;
    }
    const subject_fingerprint = try subjectFingerprintAlloc(allocator, receipt_value);
    defer allocator.free(subject_fingerprint);
    if (!std.mem.eql(u8, subject_fingerprint, try requiredString(attestation, "subject_fingerprint"))) {
        return error.AttestationSubjectMismatch;
    }
    const key_id = try requiredString(attestation, "key_id");
    if (!std.mem.eql(u8, key_id, try requiredString(producer, "key_id"))) {
        return error.AttestationKeyUnauthorized;
    }
    _ = try integer(try required(attestation, "issued_at_unix"));
    const keys = try requiredArray(trust, "keys");
    var selected: ?std.json.ObjectMap = null;
    for (keys.items) |key_value| {
        const key = try object(key_value);
        if (std.mem.eql(u8, key_id, try requiredString(key, "key_id"))) {
            selected = key;
            break;
        }
    }
    const key = selected orelse return error.AttestationKeyUnauthorized;
    if (!try listContains(try requiredArray(key, "allowed_roles"), expected_role)) {
        return error.AttestationRoleUnauthorized;
    }
    if (!try listContains(try requiredArray(key, "producer_ids"), try requiredString(producer, "id"))) {
        return error.AttestationKeyUnauthorized;
    }
    if (std.mem.eql(u8, expected_role, "source_owner")) {
        if (!try listContains(
            try requiredArray(key, "producer_binary_fingerprints"),
            try requiredString(producer, "binary_fingerprint"),
        )) return error.AttestationKeyUnauthorized;
        if (!std.mem.eql(
            u8,
            try requiredString(producer, "public_key_base64"),
            try requiredString(key, "public_key_base64"),
        )) return error.AttestationKeyUnauthorized;
    }
    const signature_object = try requiredObject(attestation, "signature");
    if (!std.mem.eql(u8, try requiredString(signature_object, "algorithm"), "ed25519")) {
        return error.AttestationAlgorithmInvalid;
    }
    const public_key_bytes = try base64DecodeAlloc(allocator, try requiredString(key, "public_key_base64"));
    defer allocator.free(public_key_bytes);
    const signature_bytes = try base64DecodeAlloc(
        allocator,
        try requiredString(signature_object, "value_base64"),
    );
    defer allocator.free(signature_bytes);
    if (public_key_bytes.len != std.crypto.sign.Ed25519.PublicKey.encoded_length or
        signature_bytes.len != std.crypto.sign.Ed25519.Signature.encoded_length)
    {
        return error.AttestationEncodingInvalid;
    }
    const public_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(
        public_key_bytes[0..std.crypto.sign.Ed25519.PublicKey.encoded_length].*,
    ) catch return error.AttestationInvalid;
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(
        signature_bytes[0..std.crypto.sign.Ed25519.Signature.encoded_length].*,
    );
    const preimage = try attestationPreimageAlloc(allocator, attestation);
    defer allocator.free(preimage);
    signature.verifyStrict(preimage, public_key) catch return error.AttestationSignatureInvalid;
    return allocator.dupe(u8, key_id);
}

fn validateSourceOwnerAttestation(
    allocator: std.mem.Allocator,
    receipt_value: std.json.Value,
    assurance: std.json.ObjectMap,
    campaign_id: []const u8,
) !void {
    const receipt = try object(receipt_value);
    const subject_value = receipt.get("source_owner_attestation") orelse
        return error.SourceOwnerAttestationMissing;
    const subject = try object(subject_value);
    if (!std.mem.eql(
        u8,
        try requiredString(subject, "schema"),
        "hylo-source-selection-attestation-subject/v1",
    ) or !std.mem.eql(u8, try requiredString(subject, "campaign_id"), campaign_id)) {
        return error.SourceOwnerAttestationInvalid;
    }
    const selection_fingerprint = try digestObjectOmittingKeysAlloc(
        allocator,
        receipt_value,
        &.{ "receipt_fingerprint", "source_owner_attestation" },
    );
    defer allocator.free(selection_fingerprint);
    if (!std.mem.eql(
        u8,
        selection_fingerprint,
        try requiredString(subject, "selection_fingerprint"),
    )) return error.SourceOwnerAttestationInvalid;
    const trust = try object(assurance.get("trust_policy") orelse return error.SourceOwnerTrustMissing);
    if (!std.mem.eql(u8, try requiredString(trust, "schema"), "hylo-trust-policy/v1")) {
        return error.SourceOwnerTrustMissing;
    }
    const key_id = verifyReceiptAttestationAgainstTrust(
        allocator,
        trust,
        subject_value,
        "source_owner",
    ) catch return error.SourceOwnerAttestationInvalid;
    defer allocator.free(key_id);
}

fn verifyReceiptAttestation(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    receipt_value: std.json.Value,
    expected_role: []const u8,
) !?[]u8 {
    var assurance_view = try assuranceForTrial(allocator, trial);
    defer assurance_view.parsed.deinit();
    if (std.mem.eql(u8, assurance_view.level, "precommitted") and
        !std.mem.eql(u8, expected_role, "human_confirmer")) return null;
    const trust = try object(assurance_view.assurance.get("trust_policy") orelse return error.TrustPolicyMissing);
    return @as(?[]u8, try verifyReceiptAttestationAgainstTrust(
        allocator,
        trust,
        receipt_value,
        expected_role,
    ));
}

pub fn applyRegistered(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
    sequence: u64,
    event_digest: []const u8,
) !void {
    const parts = try requiredBodyPayload(body_value);
    if (try optionalString(parts.body, "scenario_id") != null or
        try optionalString(parts.body, "attempt_id") != null or
        try optionalString(parts.body, "grade_id") != null)
    {
        return error.TrialRegistrationIdsForbidden;
    }
    const trial_value = try required(parts.payload, "trial");
    const declared_fingerprint = try requiredString(parts.payload, "trial_fingerprint");
    try validateFingerprint(declared_fingerprint);
    const canonical = try canonicalJsonAlloc(allocator, trial_value);
    defer allocator.free(canonical);
    var validation = try validateTrialAlloc(allocator, canonical);
    defer validation.deinit(allocator);
    if (!std.mem.eql(u8, declared_fingerprint, validation.fingerprint)) return error.TrialFingerprintMismatch;
    const trial_root = try object(trial_value);
    const factor = try requiredObject(trial_root, "factor");
    const factor_kind = try requiredString(factor, "kind");
    if (std.mem.eql(u8, factor_kind, "target_snapshot")) {
        const factor_projection = factor.get("target_common_projection") orelse
            return error.TargetCommonProjectionMissing;
        const payload_projection = parts.payload.get("target_common_projection") orelse
            return error.TargetCommonProjectionMissing;
        const factor_projection_canonical = try canonicalJsonAlloc(allocator, factor_projection);
        defer allocator.free(factor_projection_canonical);
        const payload_projection_canonical = try canonicalJsonAlloc(allocator, payload_projection);
        defer allocator.free(payload_projection_canonical);
        if (!std.mem.eql(u8, factor_projection_canonical, payload_projection_canonical)) {
            return error.TargetCommonProjectionMismatch;
        }
    } else if (parts.payload.get("target_common_projection") != null) {
        return error.TargetCommonProjectionInvalid;
    }
    if (state.findTrial(validation.trial_id) != null) return error.TrialIdDuplicate;
    var trial = try trialStateAlloc(
        allocator,
        trial_value,
        declared_fingerprint,
        sequence,
        event_digest,
    );
    errdefer trial.deinit(allocator);
    try bindCalibrationSentinelEvidence(allocator, &trial, parts.payload);
    for (state.trials.items) |existing_trial| {
        for (existing_trial.lanes.items) |existing_lane| {
            for (trial.lanes.items) |lane| {
                if (std.mem.eql(u8, existing_lane.id, lane.id)) return error.DuplicateLane;
            }
        }
    }
    try state.trials.append(allocator, trial);
}

/// Reconstruct one registration from a source-owner-attested proof projection.
/// The caller must first verify the projection schema, its exact artifact-set
/// attestation, and the original event/checkpoint binding.  The only omitted
/// source value is the case-blind sealed locator; all state-driving trial
/// fields remain present and are joined against the campaign by the caller.
pub fn applyProofProjectedRegistered(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
    sequence: u64,
    event_digest: []const u8,
    projected_body_fingerprint: []const u8,
) !void {
    try validateFingerprint(projected_body_fingerprint);
    const parts = try requiredBodyPayload(body_value);
    if (try optionalString(parts.body, "scenario_id") != null or
        try optionalString(parts.body, "attempt_id") != null or
        try optionalString(parts.body, "grade_id") != null)
    {
        return error.TrialRegistrationIdsForbidden;
    }
    const trial_value = try required(parts.payload, "trial");
    const trial_root = try object(trial_value);
    if (!std.mem.eql(u8, try requiredString(trial_root, "schema"), TrialSchema)) {
        return error.TrialSchemaInvalid;
    }
    try validateCanonicalJsonProfile(trial_root);
    const declared_fingerprint = try requiredString(parts.payload, "trial_fingerprint");
    try validateFingerprint(declared_fingerprint);
    const factor = try requiredObject(trial_root, "factor");
    const factor_kind = try requiredString(factor, "kind");
    if (std.mem.eql(u8, factor_kind, "target_snapshot")) {
        const factor_projection = factor.get("target_common_projection") orelse
            return error.TargetCommonProjectionMissing;
        const payload_projection = parts.payload.get("target_common_projection") orelse
            return error.TargetCommonProjectionMissing;
        const factor_projection_canonical = try canonicalJsonAlloc(allocator, factor_projection);
        defer allocator.free(factor_projection_canonical);
        const payload_projection_canonical = try canonicalJsonAlloc(allocator, payload_projection);
        defer allocator.free(payload_projection_canonical);
        if (!std.mem.eql(u8, factor_projection_canonical, payload_projection_canonical)) {
            return error.TargetCommonProjectionMismatch;
        }
    } else if (parts.payload.get("target_common_projection") != null) {
        return error.TargetCommonProjectionInvalid;
    }
    if (state.findTrial(try requiredString(trial_root, "trial_id")) != null) {
        return error.TrialIdDuplicate;
    }
    var trial = try trialStateAlloc(
        allocator,
        trial_value,
        declared_fingerprint,
        sequence,
        event_digest,
    );
    errdefer trial.deinit(allocator);
    try bindCalibrationSentinelEvidence(allocator, &trial, parts.payload);
    for (state.trials.items) |existing_trial| {
        for (existing_trial.lanes.items) |existing_lane| {
            for (trial.lanes.items) |lane| {
                if (std.mem.eql(u8, existing_lane.id, lane.id)) return error.DuplicateLane;
            }
        }
    }
    try state.trials.append(allocator, trial);
}

pub fn registrationPayloadAlloc(
    allocator: std.mem.Allocator,
    trial_json: []const u8,
    declared_fingerprint: []const u8,
) ![]u8 {
    try validateFingerprint(declared_fingerprint);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const trial = try object(parsed.value);
    const factor = try requiredObject(trial, "factor");
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"trial_fingerprint\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, declared_fingerprint);
    try out.writer.writeAll(",\"trial\":");
    try writeCanonicalJson(allocator, &out.writer, parsed.value);
    if (std.mem.eql(u8, try requiredString(factor, "kind"), "target_snapshot")) {
        try out.writer.writeAll(",\"target_common_projection\":");
        try writeCanonicalJson(
            allocator,
            &out.writer,
            factor.get("target_common_projection") orelse return error.TargetCommonProjectionMissing,
        );
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn laneManifestFingerprintAlloc(
    allocator: std.mem.Allocator,
    lane: *const LaneState,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"arm_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&writer.writer, lane.arm_id);
    try writer.writer.writeAll(",\"lane_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&writer.writer, lane.id);
    try writer.writer.writeAll(",\"pair_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&writer.writer, lane.pair_id);
    try writer.writer.writeAll(",\"scenario_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&writer.writer, lane.scenario_id);
    try writer.writer.writeAll(",\"unit_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&writer.writer, lane.unit_id);
    try writer.writer.writeByte('}');
    const bytes = try writer.toOwnedSlice();
    defer allocator.free(bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

pub fn applyLaneStarted(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
    sequence: u64,
    event_digest: []const u8,
) !void {
    const parts = try requiredBodyPayload(body_value);
    const scenario_id = try optionalString(parts.body, "scenario_id") orelse return error.ScenarioMissing;
    const lane_id = try optionalString(parts.body, "attempt_id") orelse return error.LaneNotRegistered;
    if (try optionalString(parts.body, "grade_id") != null) return error.GradeIdForbidden;
    const trial = state.findTrial(try requiredString(parts.payload, "trial_id")) orelse return error.TrialMissing;
    if (trial.revealed) return error.LaneStartAfterReveal;
    if (trial.closed) return error.LaneStartAfterClose;
    const lane = trial.findLane(lane_id) orelse return error.LaneNotRegistered;
    if (lane.status != .registered) return error.LaneAlreadyStarted;
    if (!std.mem.eql(u8, lane.scenario_id, scenario_id) or
        !std.mem.eql(u8, lane.unit_id, try requiredString(parts.payload, "unit_id")) or
        !std.mem.eql(u8, lane.pair_id, try requiredString(parts.payload, "pair_id")) or
        !std.mem.eql(u8, lane.arm_id, try requiredString(parts.payload, "opaque_arm_id")))
    {
        return error.LaneManifestMismatch;
    }
    var trial_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial.trial_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial_parsed.deinit();
    const trial_root = try object(trial_parsed.value);
    try validateLaneStartOrder(trial, trial_root, lane);
    const execution = try requiredObject(trial_root, "execution");
    const arm = try armObject(trial_root, lane.arm_id);
    if (!std.mem.eql(
        u8,
        try requiredString(parts.payload, "runner_contract_fingerprint"),
        try requiredString(execution, "runner_contract_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(parts.payload, "target_snapshot_fingerprint"),
        try requiredString(arm, "materialization_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(parts.payload, "environment_fingerprint"),
        try requiredString(execution, "environment_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(parts.payload, "replay_policy_fingerprint"),
        try requiredString(execution, "replay_policy_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(parts.payload, "model_configuration_fingerprint"),
        try requiredString(execution, "model_policy_fingerprint"),
    )) return error.LaneManifestMismatch;
    const presented_input_fingerprint = try requiredString(parts.payload, "presented_input_fingerprint");
    try validateFingerprint(presented_input_fingerprint);
    const runner_id = try requiredString(parts.payload, "runner_id");
    try validateId(runner_id);
    const runner_authority = try requiredObject(execution, "runner_authority");
    if (!std.mem.eql(u8, runner_id, try requiredString(runner_authority, "producer_id"))) {
        return error.RunnerRoleUnauthorized;
    }
    if (try sourceCaseForLane(trial_root, lane)) |source_case| {
        if (!std.mem.eql(
            u8,
            presented_input_fingerprint,
            try requiredString(source_case, "visible_input_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(parts.payload, "source_episode_fingerprint"),
            try requiredString(source_case, "source_episode_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(parts.payload, "source_profile_fingerprint"),
            try requiredString(source_case, "source_profile_fingerprint"),
        )) return error.LaneManifestMismatch;
    }
    const sealing = try requiredObject(trial_root, "sealing");
    if (std.mem.eql(u8, try requiredString(sealing, "case_visibility"), "case_blind")) {
        const contract = try requiredObject(sealing, "case_materializer_contract");
        if (!std.mem.eql(u8, runner_id, try requiredString(contract, "runner_id"))) {
            return error.LaneManifestMismatch;
        }
    }
    const manifest_fingerprint = try laneManifestFingerprintAlloc(allocator, lane);
    defer allocator.free(manifest_fingerprint);
    if (!std.mem.eql(
        u8,
        try requiredString(parts.payload, "lane_manifest_fingerprint"),
        manifest_fingerprint,
    )) return error.LaneManifestMismatch;
    const lease = try requiredString(parts.payload, "start_lease_digest");
    try validateFingerprint(lease);
    for (state.trials.items) |*registered_trial| {
        for (registered_trial.lanes.items) |*registered_lane| {
            if (registered_lane.lease_digest) |prior| {
                if (std.mem.eql(u8, prior, lease)) return error.LaneLeaseReused;
            }
        }
    }
    lane.lease_digest = try allocator.dupe(u8, lease);
    lane.runner_id = try allocator.dupe(u8, runner_id);
    lane.presented_input_fingerprint = try allocator.dupe(u8, presented_input_fingerprint);
    lane.started_event_digest = try allocator.dupe(u8, event_digest);
    lane.status = .started;
    lane.started_sequence = sequence;
}

fn expectTrue(map: std.json.ObjectMap, key: []const u8, err: anyerror) !void {
    if (!try boolean(try required(map, key))) return err;
}

fn armObject(trial: std.json.ObjectMap, arm_id: []const u8) !std.json.ObjectMap {
    const arms = try requiredArray(trial, "arms");
    for (arms.items) |arm_value| {
        const arm = try object(arm_value);
        if (std.mem.eql(u8, try requiredString(arm, "arm_id"), arm_id)) return arm;
    }
    return error.PairShapeInvalid;
}

fn pairObject(trial: std.json.ObjectMap, pair_id: []const u8) !std.json.ObjectMap {
    for ((try requiredArray(trial, "units")).items) |unit_value| {
        for ((try requiredArray(try object(unit_value), "pairs")).items) |pair_value| {
            const pair = try object(pair_value);
            if (std.mem.eql(u8, try requiredString(pair, "pair_id"), pair_id)) return pair;
        }
    }
    return error.PairMissing;
}

fn validateLaneStartOrder(
    trial: *const TrialState,
    trial_root: std.json.ObjectMap,
    lane: *const LaneState,
) !void {
    const pair = try pairObject(trial_root, lane.pair_id);
    const order = try requiredArray(pair, "order");
    if (order.items.len != 2) return error.PairOrderInvalid;
    const first_arm = try string(order.items[0]);
    if (std.mem.eql(u8, lane.arm_id, first_arm)) return;
    if (!std.mem.eql(u8, lane.arm_id, try string(order.items[1]))) {
        return error.PairOrderInvalid;
    }
    const lanes = try requiredObject(pair, "lanes");
    const first_lane_id = try requiredString(
        try object(lanes.get(first_arm) orelse return error.PairOrderInvalid),
        "lane_id",
    );
    const first_lane = trial.findLaneConst(first_lane_id) orelse return error.PairOrderInvalid;
    if (!first_lane.status.isTerminal()) return error.PairOrderInvalid;
}

fn unitSourceProfile(trial: std.json.ObjectMap, unit_id: []const u8) !std.json.ObjectMap {
    for ((try requiredArray(trial, "units")).items) |unit_value| {
        const unit = try object(unit_value);
        if (std.mem.eql(u8, try requiredString(unit, "unit_id"), unit_id)) {
            return requiredObject(unit, "source_profile");
        }
    }
    return error.SourceProfileInvalid;
}

fn sourceCaseForLane(trial: std.json.ObjectMap, lane: *const LaneState) !?std.json.ObjectMap {
    const sealing = try requiredObject(trial, "sealing");
    const receipt_value = sealing.get("source_selection_receipt") orelse return null;
    if (receipt_value == .null) return null;
    const cases = try requiredArray(try object(receipt_value), "cases");
    var matched: ?std.json.ObjectMap = null;
    for (cases.items) |case_value| {
        const case = try object(case_value);
        if (!std.mem.eql(u8, try requiredString(case, "unit_id"), lane.unit_id) or
            !std.mem.eql(u8, try requiredString(case, "scenario_id"), lane.scenario_id)) continue;
        if (matched != null) return error.SourceSelectionReceiptInvalid;
        matched = case;
    }
    return matched orelse error.SourceSelectionReceiptInvalid;
}

fn validateEmbeddedNativeFingerprint(
    allocator: std.mem.Allocator,
    native_receipt: std.json.ObjectMap,
) !std.json.Value {
    const receipt_value = try required(native_receipt, "receipt");
    const actual = try digestValueAlloc(allocator, receipt_value);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, try requiredString(native_receipt, "fingerprint"))) {
        return error.NativeReceiptFingerprintMismatch;
    }
    return receipt_value;
}

fn validateCasNativeReceipt(
    allocator: std.mem.Allocator,
    trial: std.json.ObjectMap,
    lane: *const LaneState,
    terminal_status: LaneTerminal,
    native_receipt: std.json.ObjectMap,
) !void {
    const receipt = try object(try validateEmbeddedNativeFingerprint(allocator, native_receipt));
    if (!std.mem.eql(u8, try requiredString(receipt, "schema"), "cas-trial-receipt/v1") or
        !std.mem.eql(u8, try requiredString(receipt, "trial_id"), try requiredString(trial, "trial_id")) or
        !std.mem.eql(u8, try requiredString(receipt, "lane_id"), lane.id) or
        !std.mem.eql(u8, try requiredString(receipt, "terminal_status"), @tagName(terminal_status)))
    {
        return error.NativeReceiptInvalid;
    }
    const claim = try requiredObject(receipt, "claim");
    if (!try boolean(try required(claim, "atomic")) or
        !try boolean(try required(claim, "claimed_before_execution")) or
        try integer(try required(claim, "claim_count")) != 1 or
        lane.lease_digest == null or !std.mem.eql(
        u8,
        try requiredString(claim, "lane_lease_digest"),
        lane.lease_digest.?,
    )) {
        return error.NativeReceiptInvalid;
    }
    const execution = try requiredObject(receipt, "execution");
    if (try integer(try required(execution, "handle_count")) != 1 or
        try integer(try required(execution, "retry_count")) != 0 or
        try integer(try required(execution, "hidden_fork_count")) != 0 or
        !try boolean(try required(execution, "terminal_receipt_once")))
    {
        return error.HiddenRetryOrFork;
    }
    if (!std.mem.eql(
        u8,
        try requiredString(receipt, "runner_contract_fingerprint"),
        try requiredString(try requiredObject(trial, "execution"), "runner_contract_fingerprint"),
    )) return error.NativeReceiptInvalid;
}

fn validateHistoricalTerminalFailureNativeReceipt(
    allocator: std.mem.Allocator,
    trial: std.json.ObjectMap,
    lane: *const LaneState,
    terminal_status: LaneTerminal,
    failure_class: []const u8,
    native_receipt: std.json.ObjectMap,
) !void {
    if (terminal_status == .completed or !terminal_status.isTerminal()) {
        return error.RetraceFirInvalid;
    }
    const source_profile = try unitSourceProfile(trial, lane.unit_id);
    if (!std.mem.eql(u8, try requiredString(source_profile, "kind"), "historical_decision")) {
        return error.RetraceSourceProfileRequired;
    }
    try rejectForkPortfolio(native_receipt);
    const receipt_value = try validateEmbeddedNativeFingerprint(allocator, native_receipt);
    const receipt = try object(receipt_value);
    try rejectForkPortfolio(receipt);
    if (!std.mem.eql(
        u8,
        try requiredString(receipt, "schema"),
        "cas-historical-terminal-receipt/v1",
    ) or !std.mem.eql(u8, try requiredString(receipt, "trial_id"), try requiredString(trial, "trial_id")) or
        !std.mem.eql(u8, try requiredString(receipt, "lane_id"), lane.id) or
        !std.mem.eql(u8, try requiredString(receipt, "terminal_status"), @tagName(terminal_status)) or
        !std.mem.eql(
            u8,
            try requiredString(receipt, "runner_contract_fingerprint"),
            try requiredString(try requiredObject(trial, "execution"), "runner_contract_fingerprint"),
        ))
    {
        return error.NativeReceiptInvalid;
    }
    const claim = try requiredObject(receipt, "claim");
    if (!std.mem.eql(u8, try requiredString(claim, "claim_id"), lane.id) or
        !try boolean(try required(claim, "atomic")) or
        !try boolean(try required(claim, "claimed_before_execution")) or
        try integer(try required(claim, "claim_count")) != 1 or
        lane.lease_digest == null or !std.mem.eql(
        u8,
        try requiredString(claim, "lane_lease_digest"),
        lane.lease_digest.?,
    )) return error.NativeReceiptInvalid;

    const source = try requiredObject(receipt, "source");
    if (!std.mem.eql(
        u8,
        try requiredString(source, "source_governance_fingerprint"),
        try requiredString(source_profile, "source_governance_fingerprint"),
    ) or (try requiredString(source, "decision_context_ref")).len == 0 or !std.mem.eql(
        u8,
        try requiredString(source, "decision_context_fingerprint"),
        try requiredString(source_profile, "decision_context_fingerprint"),
    ) or !std.mem.eql(u8, try requiredString(source, "temporal_horizon"), "pre_decision") or
        !std.mem.eql(
            u8,
            try requiredString(source, "source_target_text_policy"),
            try requiredString(source_profile, "source_target_text_policy"),
        ) or !std.mem.eql(
        u8,
        try requiredString(source, "required_lineage"),
        try requiredString(source_profile, "required_lineage"),
    ) or !std.mem.eql(u8, try requiredString(source, "required_fir_version"), "FIR-v1")) {
        return error.RetraceSourceLineageInvalid;
    }
    if (source_profile.get("source_target_text_witness_fingerprint")) |expected_value| {
        if (!std.mem.eql(
            u8,
            try string(expected_value),
            try requiredString(source, "source_target_text_witness_fingerprint"),
        )) return error.RetraceSourceLineageInvalid;
    }
    if (try sourceCaseForLane(trial, lane)) |source_case| {
        if (!std.mem.eql(
            u8,
            try requiredString(source, "source_profile_fingerprint"),
            try requiredString(source_case, "source_profile_fingerprint"),
        )) return error.RetraceSourceLineageInvalid;
    }

    const execution = try requiredObject(receipt, "execution");
    if ((try requiredString(execution, "executor")).len == 0 or
        (try requiredString(execution, "execution_audit_ref")).len == 0 or
        try integer(try required(execution, "handle_count")) != 1 or
        try integer(try required(execution, "retry_count")) != 0 or
        try integer(try required(execution, "hidden_fork_count")) != 0 or
        try boolean(try required(execution, "internal_execution_verified")))
    {
        return error.HiddenRetryOrFork;
    }
    try validateFingerprint(try requiredString(execution, "executor_binary_fingerprint"));
    try validateFingerprint(try requiredString(execution, "execution_audit_fingerprint"));

    const fir = try requiredObject(receipt, "fir");
    if (!std.mem.eql(u8, try requiredString(fir, "status"), "unavailable") or
        (try required(fir, "receipt_ref")) != .null or
        (try required(fir, "receipt_fingerprint")) != .null or
        !std.mem.eql(u8, try requiredString(fir, "reason"), failure_class))
    {
        return error.RetraceFirInvalid;
    }
}

fn rejectForkPortfolio(map: std.json.ObjectMap) !void {
    if (map.get("forks") != null or map.get("portfolio") != null) {
        return error.HiddenRetryOrFork;
    }
}

fn validateFirNativeReceipt(
    allocator: std.mem.Allocator,
    trial: std.json.ObjectMap,
    lane: *const LaneState,
    native_receipt: std.json.ObjectMap,
) !void {
    const source_profile = try unitSourceProfile(trial, lane.unit_id);
    if (!std.mem.eql(u8, try requiredString(source_profile, "kind"), "historical_decision")) {
        return error.RetraceSourceProfileRequired;
    }
    if (!std.mem.eql(
        u8,
        try requiredString(native_receipt, "source_governance_fingerprint"),
        try requiredString(source_profile, "source_governance_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(native_receipt, "decision_context_fingerprint"),
        try requiredString(source_profile, "decision_context_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(native_receipt, "source_target_text_policy"),
        try requiredString(source_profile, "source_target_text_policy"),
    ) or try integer(try required(native_receipt, "target_instruction_count")) != 1) {
        return error.RetraceSourceLineageInvalid;
    }
    try rejectForkPortfolio(native_receipt);
    const receipt_value = try validateEmbeddedNativeFingerprint(allocator, native_receipt);
    const receipt_root = try object(receipt_value);
    try rejectForkPortfolio(receipt_root);
    const receipt = if (receipt_root.get("fork_inquiry_receipt")) |wrapped| try object(wrapped) else receipt_root;
    try rejectForkPortfolio(receipt);
    if (!std.mem.eql(u8, try requiredString(receipt, "receipt_version"), "FIR-v1") or
        !std.mem.eql(u8, try requiredString(receipt, "lane_id"), lane.id))
    {
        return error.RetraceFirInvalid;
    }
    const source = try requiredObject(receipt, "source");
    const required_lineage = try requiredString(source_profile, "required_lineage");
    if (!std.mem.eql(u8, required_lineage, "either") and
        !std.mem.eql(u8, required_lineage, try requiredString(source, "lineage_mode")))
    {
        return error.RetraceSourceLineageInvalid;
    }
    const fork = try requiredObject(receipt, "fork");
    const anchor = try requiredObject(fork, "anchor");
    if (!std.mem.eql(u8, try requiredString(anchor, "temporal_horizon"), "pre_decision") or
        !try boolean(try required(anchor, "exact")) or
        !std.mem.eql(
            u8,
            try requiredString(anchor, "anchor_digest_expected"),
            try requiredString(anchor, "anchor_digest_observed"),
        ) or !std.mem.eql(u8, try requiredString(fork, "approval_policy"), "never"))
    {
        return error.OutcomeAwareDecisionContext;
    }
    const inquiry = try requiredObject(receipt, "inquiry");
    if (!std.mem.eql(u8, try requiredString(inquiry, "mode"), "replay") or
        !std.mem.eql(u8, try requiredString(inquiry, "status"), "completed"))
    {
        return error.RetracePromotionModeInvalid;
    }
    const answer = try requiredObject(receipt, "answer");
    if (try boolean(try required(answer, "hindsight_available"))) return error.OutcomeAwareDecisionContext;
    const gate = try requiredObject(receipt, "gate");
    if (!try boolean(try required(gate, "lineage_valid")) or
        !try boolean(try required(gate, "anchor_valid")) or
        !try boolean(try required(gate, "permissions_valid")) or
        try boolean(try required(gate, "approval_or_tool_request_observed")) or
        !try boolean(try required(gate, "hindsight_label_valid")) or
        !try boolean(try required(gate, "answer_complete")) or
        !try boolean(try required(gate, "receipt_valid")))
    {
        return error.RetraceFirInvalid;
    }
    const sealed_payload = if (source_profile.get("sealed_payload")) |value|
        try boolean(value)
    else
        false;
    if (sealed_payload) {
        const witness_fingerprint = try requiredString(
            source_profile,
            "source_target_text_witness_fingerprint",
        );
        try validateFingerprint(witness_fingerprint);
        if (!std.mem.eql(
            u8,
            witness_fingerprint,
            try requiredString(native_receipt, "source_target_text_witness_fingerprint"),
        )) return error.RetraceSourceLineageInvalid;
        // The controller-facing profile is deliberately commitment-only. CAS
        // validates the full signed profile delivered over the runner-only FD;
        // reveal then joins its fingerprint through the materializer receipt.
        // Requiring the plaintext SGG/DCP again here would break case blindness.
        return;
    }
    const purpose = try requiredString(trial, "purpose");
    var historical_profile = retrace_core.hctp_adapter.validateHistoricalProfile(
        allocator,
        .{ .object = source_profile },
        std.mem.eql(u8, purpose, "promotion") or std.mem.eql(u8, purpose, "practice_repair"),
    ) catch return error.RetraceSourceLineageInvalid;
    defer historical_profile.deinit(allocator);
    var strict_fir = retrace_core.hctp_adapter.validateFirForHistoricalLane(
        allocator,
        receipt_value,
        &historical_profile,
        try requiredString(trial, "trial_id"),
        lane.id,
        try requiredString(source_profile, "required_lineage"),
    ) catch |err| switch (err) {
        error.HiddenForkPortfolio => return error.HiddenRetryOrFork,
        else => return error.RetraceFirInvalid,
    };
    defer strict_fir.deinit(allocator);
}

fn validateGenericNativeReceipt(
    allocator: std.mem.Allocator,
    trial: std.json.ObjectMap,
    lane: *const LaneState,
    terminal_status: LaneTerminal,
    native_receipt: std.json.ObjectMap,
    expected_schema: []const u8,
) !void {
    const receipt = try object(try validateEmbeddedNativeFingerprint(allocator, native_receipt));
    if (!std.mem.eql(u8, try requiredString(receipt, "schema"), expected_schema) or
        !std.mem.eql(u8, try requiredString(receipt, "trial_id"), try requiredString(trial, "trial_id")) or
        !std.mem.eql(u8, try requiredString(receipt, "lane_id"), lane.id) or
        !std.mem.eql(u8, try requiredString(receipt, "terminal_status"), @tagName(terminal_status)) or
        try integer(try required(receipt, "execution_count")) != 1 or
        try integer(try required(receipt, "retry_count")) != 0 or
        try integer(try required(receipt, "hidden_fork_count")) != 0)
    {
        return error.NativeReceiptInvalid;
    }
}

fn validateRunReceipt(
    allocator: std.mem.Allocator,
    trial_state: *const TrialState,
    lane: *const LaneState,
    receipt_value: std.json.Value,
) !void {
    try validateLimitationsRecursive(receipt_value);
    const receipt = try object(receipt_value);
    if (!std.mem.eql(u8, try requiredString(receipt, "schema"), "hylo-run-receipt/v1") or
        !std.mem.eql(u8, try requiredString(receipt, "trial_id"), trial_state.id) or
        !std.mem.eql(u8, try requiredString(receipt, "unit_id"), lane.unit_id) or
        !std.mem.eql(u8, try requiredString(receipt, "scenario_id"), lane.scenario_id) or
        !std.mem.eql(u8, try requiredString(receipt, "pair_id"), lane.pair_id) or
        !std.mem.eql(u8, try requiredString(receipt, "lane_id"), lane.id) or
        !std.mem.eql(u8, try requiredString(receipt, "opaque_arm_id"), lane.arm_id))
    {
        return error.RunReceiptInvalid;
    }
    const terminal = try requiredObject(receipt, "terminal");
    const status = LaneTerminal.parse(try requiredString(terminal, "status")) orelse return error.RunReceiptInvalid;
    if (!status.isTerminal()) return error.RunReceiptInvalid;
    const lineage = try requiredObject(receipt, "lineage");
    if (lane.lease_digest == null or !std.mem.eql(
        u8,
        try requiredString(lineage, "lane_lease_digest"),
        lane.lease_digest.?,
    )) return error.LaneLeaseInvalid;
    if (!std.mem.eql(
        u8,
        try requiredString(lineage, "registration_event_digest"),
        trial_state.registration_event_digest,
    ) or lane.started_event_digest == null or !std.mem.eql(
        u8,
        try requiredString(lineage, "lane_started_event_digest"),
        lane.started_event_digest.?,
    )) return error.RunReceiptLineageInvalid;

    const producer = try requiredObject(receipt, "producer");
    try validateId(try requiredString(producer, "id"));
    if ((try requiredString(producer, "version")).len == 0) return error.RunReceiptInvalid;
    try validateFingerprint(try requiredString(producer, "binary_fingerprint"));
    try validateId(try requiredString(producer, "key_id"));
    if (lane.runner_id == null or
        !std.mem.eql(u8, lane.runner_id.?, try requiredString(producer, "id")))
    {
        return error.RunnerRoleUnauthorized;
    }

    var trial_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial_state.trial_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial_parsed.deinit();
    const trial = try object(trial_parsed.value);
    const execution = try requiredObject(trial, "execution");
    const runner_authority = try requiredObject(execution, "runner_authority");
    if (!std.mem.eql(u8, try requiredString(producer, "id"), try requiredString(runner_authority, "producer_id")) or
        !std.mem.eql(u8, try requiredString(producer, "version"), try requiredString(runner_authority, "producer_version")) or
        !std.mem.eql(u8, try requiredString(producer, "binary_fingerprint"), try requiredString(runner_authority, "binary_fingerprint")) or
        !std.mem.eql(u8, try requiredString(producer, "key_id"), try requiredString(runner_authority, "key_id")))
    {
        return error.RunnerRoleUnauthorized;
    }
    const arm = try armObject(trial, lane.arm_id);
    const materialization = try requiredObject(receipt, "materialization");
    if (!std.mem.eql(
        u8,
        try requiredString(materialization, "arm_value_fingerprint"),
        try requiredString(arm, "value_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(materialization, "target_snapshot_fingerprint"),
        try requiredString(arm, "materialization_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(materialization, "target_snapshot_ref"),
        try requiredString(arm, "materialization_ref"),
    )) return error.RunReceiptInvalid;
    if ((try requiredString(materialization, "presented_input_ref")).len == 0 or
        lane.presented_input_fingerprint == null or !std.mem.eql(
        u8,
        try requiredString(materialization, "presented_input_fingerprint"),
        lane.presented_input_fingerprint.?,
    )) return error.RunReceiptInvalid;
    if (try sourceCaseForLane(trial, lane)) |source_case| {
        if (!std.mem.eql(
            u8,
            try requiredString(materialization, "source_episode_fingerprint"),
            try requiredString(source_case, "source_episode_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(materialization, "source_profile_fingerprint"),
            try requiredString(source_case, "source_profile_fingerprint"),
        )) return error.RunReceiptInvalid;
    }
    const hidden_reference_presented = try boolean(try required(materialization, "hidden_reference_presented"));
    const sibling_output_presented = try boolean(try required(materialization, "sibling_output_presented"));
    if (hidden_reference_presented and status == .completed) return error.HiddenReferenceLeak;
    if (sibling_output_presented and status == .completed) return error.SiblingOutputLeak;

    const runtime = try requiredObject(receipt, "runtime");
    if (!std.mem.eql(
        u8,
        try requiredString(runtime, "environment_fingerprint"),
        try requiredString(execution, "environment_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(runtime, "replay_policy_fingerprint"),
        try requiredString(execution, "replay_policy_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(runtime, "effect_policy_fingerprint"),
        try requiredString(execution, "effect_policy_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(runtime, "model_configuration_fingerprint"),
        try requiredString(execution, "model_policy_fingerprint"),
    )) return error.RuntimeDrift;
    const started_at = try integer(try required(runtime, "started_at_unix"));
    const ended_at = try integer(try required(runtime, "ended_at_unix"));
    if (ended_at < started_at) return error.RunReceiptInvalid;
    const duration_ms = std.math.mul(u64, ended_at - started_at, std.time.ms_per_s) catch
        return error.RunReceiptInvalid;
    if (duration_ms > try integer(try required(execution, "maximum_lane_duration_ms"))) {
        return error.RunReceiptInvalid;
    }
    if (try integer(try required(runtime, "tokens_used")) >
        try integer(try required(execution, "maximum_tokens_per_lane")))
    {
        return error.ExecutionBudgetExceeded;
    }
    if ((try requiredString(runtime, "model_id")).len == 0 or
        (try requiredString(runtime, "model_provider")).len == 0 or
        (try requiredString(runtime, "runtime_version")).len == 0)
    {
        return error.RunReceiptInvalid;
    }
    const seed_value = try required(runtime, "seed");
    const pair = try pairObject(trial, lane.pair_id);
    if (pair.get("shared_seed")) |shared_seed| {
        if (shared_seed != .null) {
            const expected_seed = try canonicalJsonAlloc(allocator, shared_seed);
            defer allocator.free(expected_seed);
            const actual_seed = try canonicalJsonAlloc(allocator, seed_value);
            defer allocator.free(actual_seed);
            if (!std.mem.eql(u8, expected_seed, actual_seed)) return error.RuntimeDrift;
        }
    }

    const isolation = try requiredObject(receipt, "isolation");
    const isolation_valid = try boolean(try required(isolation, "fresh_thread")) and
        try boolean(try required(isolation, "fresh_workspace")) and
        try boolean(try required(isolation, "target_cache_cleared")) and
        !try boolean(try required(isolation, "shared_mutable_state_detected"));
    if (!isolation_valid and status == .completed) return error.IsolationInvalid;
    if ((try requiredString(isolation, "reset_receipt_ref")).len == 0) return error.IsolationInvalid;
    try validateFingerprint(try requiredString(isolation, "reset_receipt_fingerprint"));
    try validateStringArray(try requiredArray(isolation, "limitations"), false);

    const effects = try requiredObject(receipt, "effects");
    const policy_violations = try requiredArray(effects, "policy_violations");
    try validateStringArray(policy_violations, false);
    if (policy_violations.items.len != 0 and status == .completed) return error.EffectPolicyViolation;
    if ((try requiredString(effects, "filesystem_receipt_ref")).len == 0 or
        (try requiredString(effects, "network_receipt_ref")).len == 0 or
        (try requiredString(effects, "external_effect_receipt_ref")).len == 0)
    {
        return error.RunReceiptInvalid;
    }
    try validateFingerprint(try requiredString(effects, "filesystem_receipt_fingerprint"));
    try validateFingerprint(try requiredString(effects, "network_receipt_fingerprint"));
    try validateFingerprint(try requiredString(effects, "external_effect_receipt_fingerprint"));

    const evidence = try requiredObject(receipt, "evidence");
    var failure_class: ?[]const u8 = null;
    if (status == .completed) {
        if (try optionalStringValue(try required(terminal, "failure_class")) != null or
            try optionalStringValue(try required(terminal, "failure_detail_ref")) != null)
        {
            return error.RunReceiptInvalid;
        }
        if ((try requiredString(evidence, "output_ref")).len == 0) return error.RunReceiptInvalid;
        try validateFingerprint(try requiredString(evidence, "output_fingerprint"));
        if ((try requiredString(evidence, "trace_ref")).len == 0) return error.RunReceiptInvalid;
        try validateFingerprint(try requiredString(evidence, "trace_fingerprint"));
    } else {
        failure_class = try optionalStringValue(try required(terminal, "failure_class"));
        if (failure_class == null or failure_class.?.len == 0) return error.RunReceiptInvalid;
        if (evidence.get("output_ref")) |value| if (try optionalStringValue(value) != null) {
            return error.RunReceiptInvalid;
        };
    }
    try validateFingerprintedRef(evidence, "world_state_ref", "world_state_fingerprint");
    try validateFingerprintedRef(evidence, "metrics_ref", "metrics_fingerprint");
    const native_receipt = try requiredObject(receipt, "native_receipt");
    const native_kind = try requiredString(native_receipt, "kind");
    const source_profile = try unitSourceProfile(trial, lane.unit_id);
    const historical = std.mem.eql(
        u8,
        try requiredString(source_profile, "kind"),
        "historical_decision",
    );
    if (historical) {
        if (status == .completed) {
            if (!std.mem.eql(u8, native_kind, "FIR-v1")) return error.RetraceFirInvalid;
        } else if (!std.mem.eql(u8, native_kind, "cas-historical-terminal-receipt")) {
            return error.RetraceFirInvalid;
        }
    }
    if (!std.mem.eql(u8, native_kind, "FIR-v1") and
        !std.mem.eql(u8, native_kind, "cas-historical-terminal-receipt") and
        !std.mem.eql(u8, native_kind, "cas-trial-receipt") and
        !std.mem.eql(u8, native_kind, "emulator-receipt") and
        !std.mem.eql(u8, native_kind, "container-receipt") and
        !std.mem.eql(u8, native_kind, "custom"))
    {
        return error.RunReceiptInvalid;
    }
    if ((try requiredString(native_receipt, "ref")).len == 0) return error.NativeReceiptInvalid;
    try validateFingerprint(try requiredString(native_receipt, "fingerprint"));
    if (std.mem.eql(u8, native_kind, "FIR-v1")) {
        try validateFirNativeReceipt(allocator, trial, lane, native_receipt);
    } else if (std.mem.eql(u8, native_kind, "cas-historical-terminal-receipt")) {
        const failure_detail_ref = try optionalStringValue(try required(terminal, "failure_detail_ref"));
        if (!historical or failure_class == null or failure_detail_ref == null or
            failure_detail_ref.?.len == 0 or
            (try required(evidence, "output_ref")) != .null or
            (try required(evidence, "output_fingerprint")) != .null or
            (try required(evidence, "trace_ref")) != .null or
            (try required(evidence, "trace_fingerprint")) != .null)
        {
            return error.RetraceFirInvalid;
        }
        try validateHistoricalTerminalFailureNativeReceipt(
            allocator,
            trial,
            lane,
            status,
            failure_class.?,
            native_receipt,
        );
    } else if (std.mem.eql(u8, native_kind, "cas-trial-receipt")) {
        try validateCasNativeReceipt(allocator, trial, lane, status, native_receipt);
    } else if (std.mem.eql(u8, native_kind, "emulator-receipt")) {
        try validateGenericNativeReceipt(
            allocator,
            trial,
            lane,
            status,
            native_receipt,
            "emulator-receipt/v1",
        );
    } else if (std.mem.eql(u8, native_kind, "container-receipt")) {
        try validateGenericNativeReceipt(
            allocator,
            trial,
            lane,
            status,
            native_receipt,
            "container-receipt/v1",
        );
    } else return error.NativeReceiptAdapterUnsupported;
}

pub fn applyLaneFinished(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
    sequence: u64,
) !void {
    const parts = try requiredBodyPayload(body_value);
    const scenario_id = try optionalString(parts.body, "scenario_id") orelse return error.ScenarioMissing;
    const lane_id = try optionalString(parts.body, "attempt_id") orelse return error.LaneNotRegistered;
    if (try optionalString(parts.body, "grade_id") != null) return error.GradeIdForbidden;
    const trial = state.findTrial(try requiredString(parts.payload, "trial_id")) orelse return error.TrialMissing;
    if (trial.revealed) return error.LaneFinishAfterReveal;
    if (trial.closed) return error.LaneFinishAfterClose;
    const lane = trial.findLane(lane_id) orelse return error.LaneNotRegistered;
    if (lane.status == .registered) return error.LaneFinishWithoutStart;
    if (lane.status != .started) return error.LaneAlreadyTerminal;
    if (!std.mem.eql(u8, lane.scenario_id, scenario_id)) return error.LaneManifestMismatch;
    const receipt_fingerprint = try requiredString(parts.payload, "run_receipt_fingerprint");
    try validateFingerprint(receipt_fingerprint);
    const receipt = try requiredObject(parts.payload, "run_receipt");
    try validateRunReceipt(allocator, trial, lane, try required(parts.payload, "run_receipt"));
    const actual_receipt_fingerprint = try digestValueAlloc(allocator, try required(parts.payload, "run_receipt"));
    defer allocator.free(actual_receipt_fingerprint);
    if (!std.mem.eql(u8, receipt_fingerprint, actual_receipt_fingerprint)) return error.RunReceiptInvalid;
    lane.runner_key_id = try verifyReceiptAttestation(
        allocator,
        trial,
        try required(parts.payload, "run_receipt"),
        "runner",
    );
    const terminal = try requiredObject(receipt, "terminal");
    const status = LaneTerminal.parse(try requiredString(terminal, "status")) orelse return error.RunReceiptInvalid;
    if (!status.isTerminal()) return error.RunReceiptInvalid;
    const runtime = try requiredObject(receipt, "runtime");
    const model_id = try requiredString(runtime, "model_id");
    const model_provider = try requiredString(runtime, "model_provider");
    const runtime_version = try requiredString(runtime, "runtime_version");
    const seed_json = try canonicalJsonAlloc(allocator, try required(runtime, "seed"));
    defer allocator.free(seed_json);
    const producer = try requiredObject(receipt, "producer");
    const producer_version = try requiredString(producer, "version");
    const producer_binary_fingerprint = try requiredString(producer, "binary_fingerprint");
    const producer_key_id = try requiredString(producer, "key_id");
    for (trial.lanes.items) |sibling| {
        if (std.mem.eql(u8, sibling.id, lane.id) or !std.mem.eql(u8, sibling.pair_id, lane.pair_id) or
            !sibling.status.isTerminal()) continue;
        if (sibling.model_id == null or sibling.model_provider == null or
            sibling.runtime_version == null or sibling.seed_json == null or
            sibling.runner_id == null or sibling.runner_version == null or
            sibling.runner_binary_fingerprint == null or sibling.runner_producer_key_id == null or
            !std.mem.eql(u8, sibling.model_id.?, model_id) or
            !std.mem.eql(u8, sibling.model_provider.?, model_provider) or
            !std.mem.eql(u8, sibling.runtime_version.?, runtime_version) or
            !std.mem.eql(u8, sibling.seed_json.?, seed_json) or
            !std.mem.eql(u8, sibling.runner_id.?, try requiredString(producer, "id")) or
            !std.mem.eql(u8, sibling.runner_version.?, producer_version) or
            !std.mem.eql(u8, sibling.runner_binary_fingerprint.?, producer_binary_fingerprint) or
            !std.mem.eql(u8, sibling.runner_producer_key_id.?, producer_key_id))
        {
            return error.RuntimeDrift;
        }
    }
    lane.status = status;
    lane.terminal_sequence = sequence;
    lane.run_receipt_fingerprint = try allocator.dupe(u8, receipt_fingerprint);
    lane.run_receipt_json = try canonicalJsonAlloc(allocator, try required(parts.payload, "run_receipt"));
    if (status == .completed) {
        const evidence = try requiredObject(receipt, "evidence");
        lane.output_fingerprint = try dupeRequiredString(
            allocator,
            evidence,
            "output_fingerprint",
        );
        lane.trace_fingerprint = try dupeRequiredString(allocator, evidence, "trace_fingerprint");
    }
    lane.model_id = try allocator.dupe(u8, model_id);
    lane.model_provider = try allocator.dupe(u8, model_provider);
    lane.runtime_version = try allocator.dupe(u8, runtime_version);
    lane.seed_json = try allocator.dupe(u8, seed_json);
    lane.runner_version = try allocator.dupe(u8, producer_version);
    lane.runner_binary_fingerprint = try allocator.dupe(u8, producer_binary_fingerprint);
    lane.runner_producer_key_id = try allocator.dupe(u8, producer_key_id);
}

fn validateHumanConfirmation(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    lane: *const LaneState,
    grade_receipt: std.json.ObjectMap,
) !?[]u8 {
    const confirmation_value = grade_receipt.get("human_confirmation_receipt") orelse
        return error.HumanConfirmationMissing;
    const confirmation = try object(confirmation_value);
    if (!std.mem.eql(
        u8,
        try requiredString(confirmation, "schema"),
        "hylo-human-confirmation-receipt/v1",
    ) or !std.mem.eql(u8, try requiredString(confirmation, "trial_id"), trial.id) or
        !std.mem.eql(u8, try requiredString(confirmation, "lane_id"), lane.id) or
        !try boolean(try required(confirmation, "confirmed")))
    {
        return error.HumanConfirmationInvalid;
    }
    return verifyReceiptAttestation(
        allocator,
        trial,
        confirmation_value,
        "human_confirmer",
    );
}

fn requireExactStrings(items: std.json.Array, expected: []const []const u8, err: anyerror) !void {
    if (items.items.len != expected.len) return err;
    for (expected, 0..) |value, index| {
        if (!std.mem.eql(u8, try string(items.items[index]), value)) return err;
    }
}

const GradeIdentifierAliasEvidence = struct {
    trial_id: []const u8,
    unit_id: []const u8,
    pair_ids: std.json.Array,
    lane_ids: std.json.Array,
    arm_id: ?[]const u8,
    map_fingerprint: []const u8,
    grader_presentation_fingerprint: []const u8,
};

fn validateOpaqueGradeIdentifier(value: []const u8) !void {
    if (value.len != "opaque-".len + 64 or !std.mem.startsWith(u8, value, "opaque-")) {
        return error.GradePresentationInvalid;
    }
    for (value["opaque-".len..]) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.GradePresentationInvalid;
        }
    }
}

fn requireDistinctOpaqueGradeIdentifiers(values: []const []const u8) !void {
    for (values, 0..) |value, index| {
        try validateOpaqueGradeIdentifier(value);
        for (values[0..index]) |prior| {
            if (std.mem.eql(u8, value, prior)) return error.GradePresentationInvalid;
        }
    }
}

fn absoluteGradeAliasMapFingerprintAlloc(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    lane: *const LaneState,
    aliases: GradeIdentifierAliasEvidence,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-identifier-alias-map/v1\",\"kind\":\"absolute\",\"registered\":{{\"trial_id\":{f},\"unit_id\":{f},\"pair_ids\":[],\"lane_ids\":[{f}],\"opaque_arm_id\":{f}}},\"aliases\":{{\"trial_id\":{f},\"unit_id\":{f},\"pair_ids\":[],\"lane_ids\":[{f}],\"opaque_arm_id\":{f}}}}}",
        .{
            std.json.fmt(trial.id, .{}),
            std.json.fmt(lane.unit_id, .{}),
            std.json.fmt(lane.id, .{}),
            std.json.fmt(lane.arm_id, .{}),
            std.json.fmt(aliases.trial_id, .{}),
            std.json.fmt(aliases.unit_id, .{}),
            std.json.fmt(try string(aliases.lane_ids.items[0]), .{}),
            std.json.fmt(aliases.arm_id.?, .{}),
        },
    );
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn pairGradeAliasMapFingerprintAlloc(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    pair: *const PairState,
    left_lane: *const LaneState,
    right_lane: *const LaneState,
    aliases: GradeIdentifierAliasEvidence,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-identifier-alias-map/v1\",\"kind\":\"pair\",\"registered\":{{\"trial_id\":{f},\"unit_id\":{f},\"pair_ids\":[{f}],\"lane_ids\":[{f},{f}],\"opaque_arm_id\":null}},\"aliases\":{{\"trial_id\":{f},\"unit_id\":{f},\"pair_ids\":[{f}],\"lane_ids\":[{f},{f}],\"opaque_arm_id\":null}}}}",
        .{
            std.json.fmt(trial.id, .{}),
            std.json.fmt(pair.unit_id, .{}),
            std.json.fmt(pair.id, .{}),
            std.json.fmt(left_lane.id, .{}),
            std.json.fmt(right_lane.id, .{}),
            std.json.fmt(aliases.trial_id, .{}),
            std.json.fmt(aliases.unit_id, .{}),
            std.json.fmt(try string(aliases.pair_ids.items[0]), .{}),
            std.json.fmt(try string(aliases.lane_ids.items[0]), .{}),
            std.json.fmt(try string(aliases.lane_ids.items[1]), .{}),
        },
    );
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn pairGradePositionMapCommitmentAlloc(
    allocator: std.mem.Allocator,
    left_lane_alias: []const u8,
    right_lane_alias: []const u8,
    nonce: []const u8,
) ![]u8 {
    if (nonce.len != 64) return error.GradePresentationInvalid;
    for (nonce) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.GradePresentationInvalid;
        }
    }
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-pair-grade-position-map/v1\",\"left_lane_id\":{f},\"right_lane_id\":{f},\"nonce\":{f}}}",
        .{
            std.json.fmt(left_lane_alias, .{}),
            std.json.fmt(right_lane_alias, .{}),
            std.json.fmt(nonce, .{}),
        },
    );
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn absoluteAliasPresentationFingerprintAlloc(
    allocator: std.mem.Allocator,
    lane: *const LaneState,
    aliases: GradeIdentifierAliasEvidence,
    rubric_fingerprint: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-blind-absolute-presentation/v1\",\"trial_id\":{f},\"lane_id\":{f},\"opaque_arm_id\":{f},\"run_receipt_fingerprint\":{f},\"output_fingerprint\":{f},\"trace_fingerprint\":{f},\"rubric_fingerprint\":{f}}}",
        .{
            std.json.fmt(aliases.trial_id, .{}),
            std.json.fmt(try string(aliases.lane_ids.items[0]), .{}),
            std.json.fmt(aliases.arm_id.?, .{}),
            std.json.fmt(lane.run_receipt_fingerprint.?, .{}),
            std.json.fmt(lane.output_fingerprint.?, .{}),
            std.json.fmt(lane.trace_fingerprint.?, .{}),
            std.json.fmt(rubric_fingerprint, .{}),
        },
    );
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn pairAliasPresentationFingerprintAlloc(
    allocator: std.mem.Allocator,
    left_lane: *const LaneState,
    right_lane: *const LaneState,
    aliases: GradeIdentifierAliasEvidence,
    position_map_commitment: []const u8,
    rubric_fingerprint: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-blind-pair-presentation/v1\",\"trial_id\":{f},\"pair_id\":{f},\"left_lane_id\":{f},\"left_output_fingerprint\":{f},\"right_lane_id\":{f},\"right_output_fingerprint\":{f},\"position_map_commitment\":{f},\"rubric_fingerprint\":{f}}}",
        .{
            std.json.fmt(aliases.trial_id, .{}),
            std.json.fmt(try string(aliases.pair_ids.items[0]), .{}),
            std.json.fmt(try string(aliases.lane_ids.items[0]), .{}),
            std.json.fmt(left_lane.output_fingerprint.?, .{}),
            std.json.fmt(try string(aliases.lane_ids.items[1]), .{}),
            std.json.fmt(right_lane.output_fingerprint.?, .{}),
            std.json.fmt(position_map_commitment, .{}),
            std.json.fmt(rubric_fingerprint, .{}),
        },
    );
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn gradeIdentifierAliasEvidence(presentation: std.json.ObjectMap, absolute: bool) !GradeIdentifierAliasEvidence {
    const aliases = try requiredObject(presentation, "identifier_aliases");
    if (aliases.count() != 5) return error.GradePresentationInvalid;
    const trial_id = try requiredString(aliases, "trial_id");
    const unit_id = try requiredString(aliases, "unit_id");
    const pair_ids = try requiredArray(aliases, "pair_ids");
    const lane_ids = try requiredArray(aliases, "lane_ids");
    const arm_value = try required(aliases, "opaque_arm_id");
    const arm_id = switch (arm_value) {
        .null => null,
        .string => |text| text,
        else => return error.GradePresentationInvalid,
    };
    if (pair_ids.items.len != (if (absolute) @as(usize, 0) else 1) or
        lane_ids.items.len != (if (absolute) @as(usize, 1) else 2) or
        (absolute and arm_id == null) or (!absolute and arm_id != null))
    {
        return error.GradePresentationInvalid;
    }
    var opaque_values: [5][]const u8 = undefined;
    var count: usize = 0;
    opaque_values[count] = trial_id;
    count += 1;
    opaque_values[count] = unit_id;
    count += 1;
    for (pair_ids.items) |value| {
        opaque_values[count] = try string(value);
        count += 1;
    }
    for (lane_ids.items) |value| {
        opaque_values[count] = try string(value);
        count += 1;
    }
    if (arm_id) |value| {
        opaque_values[count] = value;
        count += 1;
    }
    try requireDistinctOpaqueGradeIdentifiers(opaque_values[0..count]);
    const map_fingerprint = try requiredString(presentation, "identifier_alias_map_fingerprint");
    const grader_presentation_fingerprint = try requiredString(presentation, "grader_presentation_fingerprint");
    try validateFingerprint(map_fingerprint);
    try validateFingerprint(grader_presentation_fingerprint);
    return .{
        .trial_id = trial_id,
        .unit_id = unit_id,
        .pair_ids = pair_ids,
        .lane_ids = lane_ids,
        .arm_id = arm_id,
        .map_fingerprint = map_fingerprint,
        .grader_presentation_fingerprint = grader_presentation_fingerprint,
    };
}

fn jsonValuesEqual(allocator: std.mem.Allocator, left: std.json.Value, right: std.json.Value) !bool {
    const left_digest = try digestValueAlloc(allocator, left);
    defer allocator.free(left_digest);
    const right_digest = try digestValueAlloc(allocator, right);
    defer allocator.free(right_digest);
    return std.mem.eql(u8, left_digest, right_digest);
}

fn ignoredBlindEvaluationKey(key: []const u8, absolute: bool) bool {
    if (std.mem.eql(u8, key, "attestation") or
        std.mem.eql(u8, key, "blind_evaluation") or
        std.mem.eql(u8, key, "blind_evaluation_fingerprint") or
        std.mem.eql(u8, key, "trial_id")) return true;
    if (absolute) {
        return std.mem.eql(u8, key, "lane_id") or std.mem.eql(u8, key, "opaque_arm_id");
    }
    return std.mem.eql(u8, key, "pair_id") or std.mem.eql(u8, key, "lane_ids") or
        std.mem.eql(u8, key, "presentation");
}

fn requireBlindEvaluationSemanticParity(
    allocator: std.mem.Allocator,
    native: std.json.ObjectMap,
    blind: std.json.ObjectMap,
    absolute: bool,
) !void {
    var native_count: usize = 0;
    var native_iterator = native.iterator();
    while (native_iterator.next()) |entry| {
        if (!ignoredBlindEvaluationKey(entry.key_ptr.*, absolute)) native_count += 1;
    }
    var blind_count: usize = 0;
    var blind_iterator = blind.iterator();
    while (blind_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (ignoredBlindEvaluationKey(key, absolute)) continue;
        blind_count += 1;
        const native_value = native.get(key) orelse return error.GradePresentationInvalid;
        if (!try jsonValuesEqual(allocator, native_value, entry.value_ptr.*)) {
            return error.GradePresentationInvalid;
        }
    }
    if (native_count != blind_count) return error.GradePresentationInvalid;
}

fn validateBlindEvaluation(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    native: std.json.ObjectMap,
    aliases: GradeIdentifierAliasEvidence,
    presentation_receipt_fingerprint: []const u8,
    absolute: bool,
) !void {
    const blind_value = native.get("blind_evaluation");
    const blind_fingerprint_value = native.get("blind_evaluation_fingerprint");
    if ((blind_value == null) != (blind_fingerprint_value == null)) {
        return error.GradePresentationInvalid;
    }
    if (blind_value == null) {
        if (!std.mem.eql(u8, try requiredString(native, "trial_id"), aliases.trial_id) or
            !std.mem.eql(u8, try requiredString(native, "identifier_alias_map_fingerprint"), aliases.map_fingerprint) or
            !std.mem.eql(
                u8,
                try requiredString(native, "grade_presentation_receipt_fingerprint"),
                presentation_receipt_fingerprint,
            ))
        {
            return error.GradePresentationInvalid;
        }
        if (absolute) {
            if (!std.mem.eql(u8, try requiredString(native, "lane_id"), try string(aliases.lane_ids.items[0])) or
                !std.mem.eql(u8, try requiredString(native, "opaque_arm_id"), aliases.arm_id.?))
            {
                return error.GradePresentationInvalid;
            }
        } else {
            if (!std.mem.eql(u8, try requiredString(native, "pair_id"), try string(aliases.pair_ids.items[0]))) {
                return error.GradePresentationInvalid;
            }
            try requireExactStrings(try requiredArray(native, "lane_ids"), &.{
                try string(aliases.lane_ids.items[0]),
                try string(aliases.lane_ids.items[1]),
            }, error.GradePresentationInvalid);
            const native_presentation = try requiredObject(native, "presentation");
            if (!std.mem.eql(
                u8,
                try requiredString(native_presentation, "left_lane_id"),
                try string(aliases.lane_ids.items[0]),
            ) or !std.mem.eql(
                u8,
                try requiredString(native_presentation, "right_lane_id"),
                try string(aliases.lane_ids.items[1]),
            )) return error.GradePresentationInvalid;
        }
        return;
    }
    const blind_fingerprint = try string(blind_fingerprint_value.?);
    try validateFingerprint(blind_fingerprint);
    const observed_fingerprint = try digestValueAlloc(allocator, blind_value.?);
    defer allocator.free(observed_fingerprint);
    if (!std.mem.eql(u8, blind_fingerprint, observed_fingerprint)) return error.GradePresentationInvalid;
    const blind = try object(blind_value.?);
    if (blind.get("blind_evaluation") != null or blind.get("blind_evaluation_fingerprint") != null or
        !std.mem.eql(u8, try requiredString(blind, "trial_id"), aliases.trial_id) or
        !std.mem.eql(u8, try requiredString(blind, "identifier_alias_map_fingerprint"), aliases.map_fingerprint) or
        !std.mem.eql(u8, try requiredString(blind, "grade_presentation_receipt_fingerprint"), presentation_receipt_fingerprint))
    {
        return error.GradePresentationInvalid;
    }
    if (absolute) {
        if (!std.mem.eql(u8, try requiredString(blind, "lane_id"), try string(aliases.lane_ids.items[0])) or
            !std.mem.eql(u8, try requiredString(blind, "opaque_arm_id"), aliases.arm_id.?))
        {
            return error.GradePresentationInvalid;
        }
    } else {
        if (!std.mem.eql(u8, try requiredString(blind, "pair_id"), try string(aliases.pair_ids.items[0]))) {
            return error.GradePresentationInvalid;
        }
        try requireExactStrings(try requiredArray(blind, "lane_ids"), &.{
            try string(aliases.lane_ids.items[0]),
            try string(aliases.lane_ids.items[1]),
        }, error.GradePresentationInvalid);
        const native_presentation = try requiredObject(native, "presentation");
        const blind_presentation = try requiredObject(blind, "presentation");
        if (!std.mem.eql(u8, try requiredString(blind_presentation, "left_lane_id"), try string(aliases.lane_ids.items[0])) or
            !std.mem.eql(u8, try requiredString(blind_presentation, "right_lane_id"), try string(aliases.lane_ids.items[1])))
        {
            return error.GradePresentationInvalid;
        }
        inline for (.{ "left_output_fingerprint", "right_output_fingerprint", "position_map_commitment", "sibling_outputs_only" }) |key| {
            if (!try jsonValuesEqual(allocator, try required(native_presentation, key), try required(blind_presentation, key))) {
                return error.GradePresentationInvalid;
            }
        }
    }
    try requireBlindEvaluationSemanticParity(allocator, native, blind, absolute);
    const key_id = (try verifyReceiptAttestation(
        allocator,
        trial,
        blind_value.?,
        if (absolute) "absolute_grader" else "pair_grader",
    )) orelse return error.GradePresentationInvalid;
    allocator.free(key_id);
}

fn absoluteGradePresentationFingerprintAlloc(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    lane: *const LaneState,
    rubric_fingerprint: []const u8,
) ![]u8 {
    const run_fingerprint = lane.run_receipt_fingerprint orelse return error.GradePresentationInvalid;
    const output_fingerprint = lane.output_fingerprint orelse return error.GradePresentationInvalid;
    const trace_fingerprint = lane.trace_fingerprint orelse return error.GradePresentationInvalid;
    const presentation = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-blind-absolute-presentation/v1\",\"trial_id\":{f},\"lane_id\":{f},\"opaque_arm_id\":{f},\"run_receipt_fingerprint\":{f},\"output_fingerprint\":{f},\"trace_fingerprint\":{f},\"rubric_fingerprint\":{f}}}",
        .{
            std.json.fmt(trial.id, .{}),
            std.json.fmt(lane.id, .{}),
            std.json.fmt(lane.arm_id, .{}),
            std.json.fmt(run_fingerprint, .{}),
            std.json.fmt(output_fingerprint, .{}),
            std.json.fmt(trace_fingerprint, .{}),
            std.json.fmt(rubric_fingerprint, .{}),
        },
    );
    defer allocator.free(presentation);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, presentation, .{});
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn pairGradePresentationFingerprintAlloc(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    pair: *const PairState,
    left_lane: *const LaneState,
    right_lane: *const LaneState,
    position_map_commitment: []const u8,
    rubric_fingerprint: []const u8,
) ![]u8 {
    const left_output = left_lane.output_fingerprint orelse return error.GradePresentationInvalid;
    const right_output = right_lane.output_fingerprint orelse return error.GradePresentationInvalid;
    const presentation = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-blind-pair-presentation/v1\",\"trial_id\":{f},\"pair_id\":{f},\"left_lane_id\":{f},\"left_output_fingerprint\":{f},\"right_lane_id\":{f},\"right_output_fingerprint\":{f},\"position_map_commitment\":{f},\"rubric_fingerprint\":{f}}}",
        .{
            std.json.fmt(trial.id, .{}),
            std.json.fmt(pair.id, .{}),
            std.json.fmt(left_lane.id, .{}),
            std.json.fmt(left_output, .{}),
            std.json.fmt(right_lane.id, .{}),
            std.json.fmt(right_output, .{}),
            std.json.fmt(position_map_commitment, .{}),
            std.json.fmt(rubric_fingerprint, .{}),
        },
    );
    defer allocator.free(presentation);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, presentation, .{});
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn gradePresentationCapabilityUsed(state: *const CampaignTrials, digest: []const u8) bool {
    for (state.trials.items) |trial| {
        for (trial.lanes.items) |lane| {
            if (lane.grade_presentation_capability_digest) |prior| {
                if (std.mem.eql(u8, prior, digest)) return true;
            }
        }
        for (trial.pairs.items) |pair| {
            if (pair.grade_presentation_capability_digest) |prior| {
                if (std.mem.eql(u8, prior, digest)) return true;
            }
        }
    }
    return false;
}

fn validateGradePresentationEnvelope(
    allocator: std.mem.Allocator,
    state: *const CampaignTrials,
    trial: *const TrialState,
    trial_root: std.json.ObjectMap,
    payload: std.json.ObjectMap,
    grade_producer: std.json.ObjectMap,
    expected_kind: []const u8,
) !?struct { key_id: []u8, capability_digest: []u8, fingerprint: []const u8, receipt: std.json.ObjectMap } {
    const sealed = std.mem.eql(
        u8,
        try requiredString(try requiredObject(trial_root, "assurance"), "required_level"),
        "sealed",
    );
    const receipt_value = payload.get("grade_presentation_receipt") orelse {
        if (sealed) return error.SealedGradePresentationMissing;
        return null;
    };
    const receipt_ref = try optionalStringValue(
        payload.get("grade_presentation_receipt_ref") orelse return error.GradePresentationInvalid,
    ) orelse return error.GradePresentationInvalid;
    if (receipt_ref.len == 0) return error.GradePresentationInvalid;
    const declared_fingerprint = try optionalStringValue(
        payload.get("grade_presentation_receipt_fingerprint") orelse
            return error.GradePresentationInvalid,
    ) orelse return error.GradePresentationInvalid;
    try validateFingerprint(declared_fingerprint);
    const actual_fingerprint = try digestValueAlloc(allocator, receipt_value);
    defer allocator.free(actual_fingerprint);
    if (!std.mem.eql(u8, actual_fingerprint, declared_fingerprint)) {
        return error.GradePresentationInvalid;
    }
    const receipt = try object(receipt_value);
    if (!std.mem.eql(u8, try requiredString(receipt, "schema"), "hylo-grade-presentation-receipt/v1") or
        !std.mem.eql(u8, try requiredString(receipt, "trial_id"), trial.id) or
        !std.mem.eql(u8, try requiredString(receipt, "kind"), expected_kind))
    {
        return error.GradePresentationInvalid;
    }
    const grader = try requiredObject(receipt, "grader");
    inline for (.{ "id", "version", "binary_fingerprint", "key_id" }) |key| {
        if (!std.mem.eql(u8, try requiredString(grader, key), try requiredString(grade_producer, key))) {
            return error.GradePresentationInvalid;
        }
    }
    const expected_grader_role = if (std.mem.eql(u8, expected_kind, "absolute"))
        "absolute_grader"
    else
        "pair_grader";
    if (!std.mem.eql(u8, try requiredString(grader, "role"), expected_grader_role)) {
        return error.GradePresentationInvalid;
    }
    const authority = try frozenProducerAuthority(
        trial_root,
        grade_producer,
        expected_grader_role,
        error.GradePresentationInvalid,
    );
    const delivery = try requiredObject(receipt, "delivery");
    if (!std.mem.eql(u8, try requiredString(delivery, "method"), "anonymous_fd") or
        !std.mem.eql(u8, try requiredString(delivery, "receiver_binding"), "grader_key") or
        !std.mem.eql(u8, try requiredString(delivery, "receiver_role"), expected_grader_role) or
        !std.mem.eql(
            u8,
            try requiredString(delivery, "receiver_key_id"),
            try requiredString(authority, "key_id"),
        ) or
        !try boolean(try required(delivery, "single_use")))
    {
        return error.GradePresentationInvalid;
    }
    const disclosure = try requiredObject(receipt, "disclosure");
    inline for (.{ "semantic_arm_identity", "target_diff", "lane_execution_order", "prior_grades", "hidden_reference" }) |key| {
        if (try boolean(try required(disclosure, key))) return error.GradePresentationInvalid;
    }
    if (sealed and try boolean(try required(disclosure, "registered_identifiers"))) {
        return error.GradePresentationInvalid;
    }
    const producer = try requiredObject(receipt, "producer");
    const presentation_materializer = try requiredObject(
        try requiredObject(trial_root, "grading"),
        "presentation_materializer",
    );
    if (!std.mem.eql(u8, try requiredString(producer, "id"), try requiredString(presentation_materializer, "producer_id")) or
        !std.mem.eql(u8, try requiredString(producer, "version"), try requiredString(presentation_materializer, "producer_version")) or
        !std.mem.eql(u8, try requiredString(producer, "binary_fingerprint"), try requiredString(presentation_materializer, "binary_fingerprint")) or
        !std.mem.eql(u8, try requiredString(producer, "key_id"), try requiredString(presentation_materializer, "key_id")))
    {
        return error.GradePresentationInvalid;
    }
    if (receipt.get("execution")) |execution_value| {
        const execution = try object(execution_value);
        if (!try boolean(try required(execution, "separate_process")) or
            try boolean(try required(execution, "os_confinement")))
        {
            return error.GradePresentationInvalid;
        }
        const inherited = try requiredArray(execution, "inherited_capability_fds");
        if (inherited.items.len != 4) return error.GradePresentationInvalid;
        for (inherited.items, 0..) |fd_value, expected_fd| {
            if (try integer(fd_value) != expected_fd) return error.GradePresentationInvalid;
        }
    } else if (sealed) {
        return error.GradePresentationInvalid;
    }
    const key_id = (try verifyReceiptAttestation(allocator, trial, receipt_value, "materializer")) orelse
        return error.GradePresentationInvalid;
    errdefer allocator.free(key_id);
    if (std.mem.eql(u8, key_id, try requiredString(grade_producer, "key_id"))) {
        return error.RoleSeparationInvalid;
    }
    const capability = try requiredObject(receipt, "capability_scope");
    const capability_digest = try requiredString(capability, "capability_digest");
    try validateFingerprint(capability_digest);
    if (!std.mem.eql(u8, try requiredString(capability, "trial_id"), trial.id) or
        !try boolean(try required(capability, "single_use")) or
        gradePresentationCapabilityUsed(state, capability_digest))
    {
        return error.GradePresentationInvalid;
    }
    return .{
        .key_id = key_id,
        .capability_digest = try allocator.dupe(u8, capability_digest),
        .fingerprint = declared_fingerprint,
        .receipt = receipt,
    };
}

const GradePresentationEvidence = struct {
    key_id: []u8,
    capability_digest: []u8,
    receipt_json: []u8,
};

fn validateGradeSemanticObservation(
    presentation_receipt: std.json.ObjectMap,
    grade_receipt: std.json.ObjectMap,
    expected_output_fingerprints: []const []const u8,
    expected_trace_fingerprints: []const []const u8,
) !void {
    const observation = try requiredObject(presentation_receipt, "semantic_observation");
    if (!std.mem.eql(
        u8,
        try requiredString(observation, "schema"),
        "hylo-grade-semantic-observation-receipt/v1",
    ) or !std.mem.eql(u8, try requiredString(observation, "carrier_encoding"), "base64") or
        !try boolean(try required(observation, "semantic_bytes_presented")))
    {
        return error.GradePresentationInvalid;
    }
    const observation_fingerprint = try requiredString(observation, "observation_fingerprint");
    try validateFingerprint(observation_fingerprint);
    if (!std.mem.eql(
        u8,
        observation_fingerprint,
        try requiredString(grade_receipt, "semantic_observation_fingerprint"),
    )) return error.GradePresentationInvalid;
    try requireExactStrings(
        try requiredArray(observation, "output_fingerprints"),
        expected_output_fingerprints,
        error.GradePresentationInvalid,
    );
    try requireExactStrings(
        try requiredArray(observation, "trace_fingerprints"),
        expected_trace_fingerprints,
        error.GradePresentationInvalid,
    );
    const output_byte_counts = try requiredArray(observation, "output_byte_counts");
    const trace_byte_counts = try requiredArray(observation, "trace_byte_counts");
    if (output_byte_counts.items.len != expected_output_fingerprints.len or
        trace_byte_counts.items.len != expected_trace_fingerprints.len)
    {
        return error.GradePresentationInvalid;
    }
    for (output_byte_counts.items) |value| {
        const count = integer(value) catch return error.GradePresentationInvalid;
        if (count == 0) return error.GradePresentationInvalid;
    }
    for (trace_byte_counts.items) |value| {
        const count = integer(value) catch return error.GradePresentationInvalid;
        if (count == 0) return error.GradePresentationInvalid;
    }
}

fn validateAbsoluteGradePresentation(
    allocator: std.mem.Allocator,
    state: *const CampaignTrials,
    trial: *const TrialState,
    trial_root: std.json.ObjectMap,
    payload: std.json.ObjectMap,
    grade_receipt: std.json.ObjectMap,
    grade_producer: std.json.ObjectMap,
    lane: *const LaneState,
) !?GradePresentationEvidence {
    const envelope = try validateGradePresentationEnvelope(
        allocator,
        state,
        trial,
        trial_root,
        payload,
        grade_producer,
        "absolute",
    ) orelse return null;
    errdefer allocator.free(envelope.key_id);
    errdefer allocator.free(envelope.capability_digest);
    const receipt_json = try canonicalJsonAlloc(
        allocator,
        payload.get("grade_presentation_receipt").?,
    );
    errdefer allocator.free(receipt_json);
    if (!std.mem.eql(
        u8,
        try requiredString(grade_receipt, "grade_presentation_receipt_fingerprint"),
        envelope.fingerprint,
    )) return error.GradePresentationInvalid;
    const scope = try requiredObject(envelope.receipt, "scope");
    try requireExactStrings(try requiredArray(scope, "lane_ids"), &.{lane.id}, error.GradePresentationInvalid);
    try requireExactStrings(try requiredArray(scope, "pair_ids"), &.{}, error.GradePresentationInvalid);
    try requireExactStrings(try requiredArray(scope, "unit_ids"), &.{lane.unit_id}, error.GradePresentationInvalid);
    if (try integer(try required(scope, "unit_count")) != 1 or
        try integer(try required(scope, "lane_count")) != 1 or
        try integer(try required(scope, "pair_count")) != 0)
    {
        return error.GradePresentationInvalid;
    }
    const capability = try requiredObject(envelope.receipt, "capability_scope");
    try requireExactStrings(try requiredArray(capability, "lane_ids"), &.{lane.id}, error.GradePresentationInvalid);
    try requireExactStrings(try requiredArray(capability, "pair_ids"), &.{}, error.GradePresentationInvalid);
    try requireExactStrings(
        try requiredArray(capability, "allowed_inputs"),
        &.{ "output", "trace", "rubric" },
        error.GradePresentationInvalid,
    );
    const presentation = try requiredObject(envelope.receipt, "presentation");
    if (!std.mem.eql(u8, try requiredString(presentation, "schema"), "hylo-blind-absolute-presentation/v1")) {
        return error.GradePresentationInvalid;
    }
    const run_fingerprint = lane.run_receipt_fingerprint orelse return error.GradePresentationInvalid;
    const output_fingerprint = lane.output_fingerprint orelse return error.GradePresentationInvalid;
    const trace_fingerprint = lane.trace_fingerprint orelse return error.GradePresentationInvalid;
    try requireExactStrings(
        try requiredArray(presentation, "run_receipt_fingerprints"),
        &.{run_fingerprint},
        error.GradePresentationInvalid,
    );
    try requireExactStrings(
        try requiredArray(presentation, "output_fingerprints"),
        &.{output_fingerprint},
        error.GradePresentationInvalid,
    );
    try requireExactStrings(
        try requiredArray(presentation, "trace_fingerprints"),
        &.{trace_fingerprint},
        error.GradePresentationInvalid,
    );
    try validateGradeSemanticObservation(
        envelope.receipt,
        grade_receipt,
        &.{output_fingerprint},
        &.{trace_fingerprint},
    );
    const rubric_fingerprint = try requiredString(try requiredObject(trial_root, "grading"), "rubric_fingerprint");
    if (!std.mem.eql(u8, try requiredString(presentation, "rubric_fingerprint"), rubric_fingerprint) or
        (try required(presentation, "position_map_commitment")) != .null or
        try boolean(try required(try requiredObject(envelope.receipt, "disclosure"), "sibling_outputs")))
    {
        return error.GradePresentationInvalid;
    }
    const expected_presentation_fingerprint = try absoluteGradePresentationFingerprintAlloc(
        allocator,
        trial,
        lane,
        rubric_fingerprint,
    );
    defer allocator.free(expected_presentation_fingerprint);
    if (!std.mem.eql(
        u8,
        try requiredString(presentation, "presentation_fingerprint"),
        expected_presentation_fingerprint,
    )) return error.GradePresentationInvalid;
    const aliases = try gradeIdentifierAliasEvidence(presentation, true);
    if (std.mem.eql(u8, aliases.trial_id, trial.id) or
        std.mem.eql(u8, aliases.unit_id, lane.unit_id) or
        std.mem.eql(u8, try string(aliases.lane_ids.items[0]), lane.id) or
        std.mem.eql(u8, aliases.arm_id.?, lane.arm_id))
    {
        return error.GradePresentationInvalid;
    }
    const expected_alias_map_fingerprint = try absoluteGradeAliasMapFingerprintAlloc(
        allocator,
        trial,
        lane,
        aliases,
    );
    defer allocator.free(expected_alias_map_fingerprint);
    const expected_grader_presentation_fingerprint = try absoluteAliasPresentationFingerprintAlloc(
        allocator,
        lane,
        aliases,
        rubric_fingerprint,
    );
    defer allocator.free(expected_grader_presentation_fingerprint);
    if (!std.mem.eql(u8, aliases.map_fingerprint, expected_alias_map_fingerprint) or
        !std.mem.eql(u8, aliases.grader_presentation_fingerprint, expected_grader_presentation_fingerprint) or
        !std.mem.eql(u8, try requiredString(grade_receipt, "identifier_alias_map_fingerprint"), aliases.map_fingerprint) or
        try boolean(try required(try requiredObject(grade_receipt, "blinding"), "registered_identifiers_visible")))
    {
        return error.GradePresentationInvalid;
    }
    try validateBlindEvaluation(
        allocator,
        trial,
        grade_receipt,
        aliases,
        envelope.fingerprint,
        true,
    );
    return .{
        .key_id = envelope.key_id,
        .capability_digest = envelope.capability_digest,
        .receipt_json = receipt_json,
    };
}

fn validatePairGradePresentation(
    allocator: std.mem.Allocator,
    state: *const CampaignTrials,
    trial: *const TrialState,
    trial_root: std.json.ObjectMap,
    payload: std.json.ObjectMap,
    pair_grade_receipt: std.json.ObjectMap,
    grade_producer: std.json.ObjectMap,
    pair: *const PairState,
    left_lane: *const LaneState,
    right_lane: *const LaneState,
    position_map_commitment: []const u8,
) !?GradePresentationEvidence {
    const envelope = try validateGradePresentationEnvelope(
        allocator,
        state,
        trial,
        trial_root,
        payload,
        grade_producer,
        "pair",
    ) orelse return null;
    errdefer allocator.free(envelope.key_id);
    errdefer allocator.free(envelope.capability_digest);
    const receipt_json = try canonicalJsonAlloc(
        allocator,
        payload.get("grade_presentation_receipt").?,
    );
    errdefer allocator.free(receipt_json);
    if (!std.mem.eql(
        u8,
        try requiredString(pair_grade_receipt, "grade_presentation_receipt_fingerprint"),
        envelope.fingerprint,
    )) return error.GradePresentationInvalid;
    const scope = try requiredObject(envelope.receipt, "scope");
    try requireExactStrings(
        try requiredArray(scope, "lane_ids"),
        &.{ left_lane.id, right_lane.id },
        error.GradePresentationInvalid,
    );
    try requireExactStrings(try requiredArray(scope, "pair_ids"), &.{pair.id}, error.GradePresentationInvalid);
    try requireExactStrings(try requiredArray(scope, "unit_ids"), &.{pair.unit_id}, error.GradePresentationInvalid);
    if (try integer(try required(scope, "unit_count")) != 1 or
        try integer(try required(scope, "lane_count")) != 2 or
        try integer(try required(scope, "pair_count")) != 1)
    {
        return error.GradePresentationInvalid;
    }
    const capability = try requiredObject(envelope.receipt, "capability_scope");
    try requireExactStrings(
        try requiredArray(capability, "lane_ids"),
        &.{ left_lane.id, right_lane.id },
        error.GradePresentationInvalid,
    );
    try requireExactStrings(try requiredArray(capability, "pair_ids"), &.{pair.id}, error.GradePresentationInvalid);
    try requireExactStrings(
        try requiredArray(capability, "allowed_inputs"),
        &.{ "sibling_outputs", "rubric", "position_map_commitment" },
        error.GradePresentationInvalid,
    );
    const presentation = try requiredObject(envelope.receipt, "presentation");
    if (!std.mem.eql(u8, try requiredString(presentation, "schema"), "hylo-blind-pair-presentation/v1")) {
        return error.GradePresentationInvalid;
    }
    const left_run = left_lane.run_receipt_fingerprint orelse return error.GradePresentationInvalid;
    const right_run = right_lane.run_receipt_fingerprint orelse return error.GradePresentationInvalid;
    const left_output = left_lane.output_fingerprint orelse return error.GradePresentationInvalid;
    const right_output = right_lane.output_fingerprint orelse return error.GradePresentationInvalid;
    try requireExactStrings(
        try requiredArray(presentation, "run_receipt_fingerprints"),
        &.{ left_run, right_run },
        error.GradePresentationInvalid,
    );
    try requireExactStrings(
        try requiredArray(presentation, "output_fingerprints"),
        &.{ left_output, right_output },
        error.GradePresentationInvalid,
    );
    try requireExactStrings(try requiredArray(presentation, "trace_fingerprints"), &.{}, error.GradePresentationInvalid);
    try validateGradeSemanticObservation(
        envelope.receipt,
        pair_grade_receipt,
        &.{ left_output, right_output },
        &.{},
    );
    const rubric_fingerprint = try requiredString(try requiredObject(trial_root, "grading"), "rubric_fingerprint");
    if (!std.mem.eql(u8, try requiredString(presentation, "rubric_fingerprint"), rubric_fingerprint) or
        !std.mem.eql(u8, try requiredString(presentation, "position_map_commitment"), position_map_commitment) or
        !try boolean(try required(try requiredObject(envelope.receipt, "disclosure"), "sibling_outputs")))
    {
        return error.GradePresentationInvalid;
    }
    const expected_presentation_fingerprint = try pairGradePresentationFingerprintAlloc(
        allocator,
        trial,
        pair,
        left_lane,
        right_lane,
        position_map_commitment,
        rubric_fingerprint,
    );
    defer allocator.free(expected_presentation_fingerprint);
    if (!std.mem.eql(
        u8,
        try requiredString(presentation, "presentation_fingerprint"),
        expected_presentation_fingerprint,
    )) return error.GradePresentationInvalid;
    const aliases = try gradeIdentifierAliasEvidence(presentation, false);
    if (std.mem.eql(u8, aliases.trial_id, trial.id) or
        std.mem.eql(u8, aliases.unit_id, pair.unit_id) or
        std.mem.eql(u8, try string(aliases.pair_ids.items[0]), pair.id) or
        std.mem.eql(u8, try string(aliases.lane_ids.items[0]), left_lane.id) or
        std.mem.eql(u8, try string(aliases.lane_ids.items[1]), right_lane.id))
    {
        return error.GradePresentationInvalid;
    }
    if (pair_grade_receipt.get("position_map_nonce") != null or
        !std.mem.eql(
            u8,
            try requiredString(presentation, "position_map_commitment"),
            position_map_commitment,
        ))
    {
        return error.GradePresentationInvalid;
    }
    const expected_position_map_commitment = try pairGradePositionMapCommitmentAlloc(
        allocator,
        try string(aliases.lane_ids.items[0]),
        try string(aliases.lane_ids.items[1]),
        try requiredString(presentation, "position_map_nonce"),
    );
    defer allocator.free(expected_position_map_commitment);
    if (!std.mem.eql(u8, expected_position_map_commitment, position_map_commitment)) {
        return error.GradePresentationInvalid;
    }
    const expected_alias_map_fingerprint = try pairGradeAliasMapFingerprintAlloc(
        allocator,
        trial,
        pair,
        left_lane,
        right_lane,
        aliases,
    );
    defer allocator.free(expected_alias_map_fingerprint);
    const expected_grader_presentation_fingerprint = try pairAliasPresentationFingerprintAlloc(
        allocator,
        left_lane,
        right_lane,
        aliases,
        position_map_commitment,
        rubric_fingerprint,
    );
    defer allocator.free(expected_grader_presentation_fingerprint);
    if (!std.mem.eql(u8, aliases.map_fingerprint, expected_alias_map_fingerprint) or
        !std.mem.eql(u8, aliases.grader_presentation_fingerprint, expected_grader_presentation_fingerprint) or
        !std.mem.eql(u8, try requiredString(pair_grade_receipt, "identifier_alias_map_fingerprint"), aliases.map_fingerprint) or
        try boolean(try required(try requiredObject(pair_grade_receipt, "blinding"), "registered_identifiers_visible")))
    {
        return error.GradePresentationInvalid;
    }
    try validateBlindEvaluation(
        allocator,
        trial,
        pair_grade_receipt,
        aliases,
        envelope.fingerprint,
        false,
    );
    return .{
        .key_id = envelope.key_id,
        .capability_digest = envelope.capability_digest,
        .receipt_json = receipt_json,
    };
}

fn validateCommitmentScope(scope: std.json.ObjectMap, kind: []const u8) !void {
    try requireExactKeys(scope, &.{ "trial_id", "lane_ids", "pair_id" }, error.GradeCommitmentInvalid);
    try validateOpaqueGradeIdentifier(try requiredString(scope, "trial_id"));
    const lane_ids = try requiredArray(scope, "lane_ids");
    const absolute = std.mem.eql(u8, kind, "absolute");
    if ((!absolute and !std.mem.eql(u8, kind, "pair")) or lane_ids.items.len != (if (absolute) @as(usize, 1) else 2)) {
        return error.GradeCommitmentInvalid;
    }
    var prior: ?[]const u8 = null;
    for (lane_ids.items) |lane_value| {
        const lane_id = try string(lane_value);
        try validateOpaqueGradeIdentifier(lane_id);
        if (prior != null and std.mem.eql(u8, prior.?, lane_id)) return error.GradeCommitmentInvalid;
        prior = lane_id;
    }
    const pair_id = try optionalStringValue(try required(scope, "pair_id"));
    if (absolute) {
        if (pair_id != null) return error.GradeCommitmentInvalid;
    } else {
        try validateOpaqueGradeIdentifier(pair_id orelse return error.GradeCommitmentInvalid);
    }
}

fn commitmentFingerprintAlreadyPresent(state: *const CampaignTrials, fingerprint: []const u8) bool {
    for (state.trials.items) |trial| {
        for (trial.lanes.items) |lane| {
            if (lane.grade_commitment_fingerprint != null and
                std.mem.eql(u8, lane.grade_commitment_fingerprint.?, fingerprint)) return true;
        }
        for (trial.pairs.items) |pair| {
            if (pair.grade_commitment_fingerprint != null and
                std.mem.eql(u8, pair.grade_commitment_fingerprint.?, fingerprint)) return true;
        }
    }
    return false;
}

fn validateGradeCommitment(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    commitment_value: std.json.Value,
    declared_fingerprint: []const u8,
    expected_kind: []const u8,
) ![]u8 {
    try validateFingerprint(declared_fingerprint);
    const actual_fingerprint = try digestValueAlloc(allocator, commitment_value);
    defer allocator.free(actual_fingerprint);
    if (!std.mem.eql(u8, actual_fingerprint, declared_fingerprint)) return error.GradeCommitmentInvalid;
    const commitment = try object(commitment_value);
    try requireExactKeys(commitment, &.{
        "schema",
        "kind",
        "grader_scope",
        "grade_presentation_receipt_fingerprint",
        "identifier_alias_map_fingerprint",
        "producer",
        "opening_nonce_contract",
        "commitment",
        "attestation",
    }, error.GradeCommitmentInvalid);
    if (!std.mem.eql(u8, try requiredString(commitment, "schema"), "hylo-grade-commitment/v1") or
        !std.mem.eql(u8, try requiredString(commitment, "kind"), expected_kind))
    {
        return error.GradeCommitmentInvalid;
    }
    try validateCommitmentScope(try requiredObject(commitment, "grader_scope"), expected_kind);
    try validateFingerprint(try requiredString(commitment, "grade_presentation_receipt_fingerprint"));
    try validateFingerprint(try requiredString(commitment, "identifier_alias_map_fingerprint"));
    const nonce_contract = try requiredObject(commitment, "opening_nonce_contract");
    try requireExactKeys(nonce_contract, &.{ "source", "encoding", "bytes", "single_use" }, error.GradeCommitmentInvalid);
    if (!std.mem.eql(u8, try requiredString(nonce_contract, "source"), "getentropy") or
        !std.mem.eql(u8, try requiredString(nonce_contract, "encoding"), "lower_hex") or
        try integer(try required(nonce_contract, "bytes")) != 32 or
        !try boolean(try required(nonce_contract, "single_use")))
    {
        return error.GradeCommitmentInvalid;
    }
    const digest = try requiredObject(commitment, "commitment");
    try requireExactKeys(digest, &.{ "algorithm", "domain", "fingerprint" }, error.GradeCommitmentInvalid);
    if (!std.mem.eql(u8, try requiredString(digest, "algorithm"), CanonicalJsonSha256Algorithm) or
        !std.mem.eql(u8, try requiredString(digest, "domain"), GradeCommitmentDomain))
    {
        return error.GradeCommitmentInvalid;
    }
    try validateFingerprint(try requiredString(digest, "fingerprint"));
    const producer = try requiredObject(commitment, "producer");
    var trial_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial.trial_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial_parsed.deinit();
    try validateFrozenProducer(
        try object(trial_parsed.value),
        producer,
        if (std.mem.eql(u8, expected_kind, "absolute")) "absolute_grader" else "pair_grader",
        error.GradeCommitmentInvalid,
    );
    return (try verifyReceiptAttestation(
        allocator,
        trial,
        commitment_value,
        if (std.mem.eql(u8, expected_kind, "absolute")) "absolute_grader" else "pair_grader",
    )) orelse error.GradeCommitmentInvalid;
}

pub fn applyAbsoluteGradeCommitment(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
) !void {
    const parts = try requiredBodyPayload(body_value);
    try requireExactKeys(parts.payload, &.{
        "trial_id",
        "pair_id",
        "opaque_arm_id",
        "grade_commitment_fingerprint",
        "grade_commitment",
    }, error.GradeCommitmentInvalid);
    const trial = state.findTrial(try requiredString(parts.payload, "trial_id")) orelse return error.TrialMissing;
    if (!trial.requires_grade_commitments) return error.GradeCommitmentInvalid;
    if (trial.revealed) return error.GradeCommitmentAfterReveal;
    if (trial.closed) return error.GradeAfterClose;
    const lane_id = try optionalString(parts.body, "attempt_id") orelse return error.LaneNotRegistered;
    const scenario_id = try optionalString(parts.body, "scenario_id") orelse return error.ScenarioMissing;
    const grade_id = try optionalString(parts.body, "grade_id") orelse return error.GradeMissing;
    const lane = trial.findLane(lane_id) orelse return error.LaneNotRegistered;
    if (lane.status != .completed) return error.GradeCommitmentBeforeTerminal;
    if (lane.grade_commitment_fingerprint != null or lane.absolute_graded) return error.GradeCommitmentDuplicate;
    if (!std.mem.eql(u8, lane.scenario_id, scenario_id) or
        !std.mem.eql(u8, lane.pair_id, try requiredString(parts.payload, "pair_id")) or
        !std.mem.eql(u8, lane.arm_id, try requiredString(parts.payload, "opaque_arm_id")))
    {
        return error.LaneManifestMismatch;
    }
    try validateId(grade_id);
    const fingerprint = try requiredString(parts.payload, "grade_commitment_fingerprint");
    if (commitmentFingerprintAlreadyPresent(state, fingerprint)) return error.GradeCommitmentDuplicate;
    var key_id = try validateGradeCommitment(
        allocator,
        trial,
        try required(parts.payload, "grade_commitment"),
        fingerprint,
        "absolute",
    );
    errdefer allocator.free(key_id);
    lane.grade_commitment_fingerprint = try allocator.dupe(u8, fingerprint);
    errdefer {
        allocator.free(lane.grade_commitment_fingerprint.?);
        lane.grade_commitment_fingerprint = null;
    }
    lane.grade_commitment_json = try canonicalJsonAlloc(allocator, try required(parts.payload, "grade_commitment"));
    errdefer {
        allocator.free(lane.grade_commitment_json.?);
        lane.grade_commitment_json = null;
    }
    lane.grade_commitment_grade_id = try allocator.dupe(u8, grade_id);
    lane.grade_commitment_key_id = key_id;
    key_id = undefined;
}

pub fn applyPairGradeCommitment(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
) !void {
    const parts = try requiredBodyPayload(body_value);
    try requireExactKeys(parts.payload, &.{
        "trial_id",
        "pair_id",
        "grade_commitment_fingerprint",
        "grade_commitment",
    }, error.GradeCommitmentInvalid);
    if (try optionalString(parts.body, "scenario_id") != null or
        try optionalString(parts.body, "attempt_id") != null or
        try optionalString(parts.body, "grade_id") != null)
    {
        return error.GradeCommitmentInvalid;
    }
    const trial = state.findTrial(try requiredString(parts.payload, "trial_id")) orelse return error.TrialMissing;
    if (!trial.requires_grade_commitments) return error.GradeCommitmentInvalid;
    if (!trial.requires_pair_grade) return error.PairGradeCommitmentNotRequired;
    if (trial.revealed) return error.GradeCommitmentAfterReveal;
    if (trial.closed) return error.GradeAfterClose;
    const pair = trial.findPair(try requiredString(parts.payload, "pair_id")) orelse return error.PairMissing;
    if (pair.grade_commitment_fingerprint != null or pair.pair_graded) return error.GradeCommitmentDuplicate;
    for (trial.lanes.items) |lane| {
        if (std.mem.eql(u8, lane.pair_id, pair.id) and lane.status != .completed) {
            return error.GradeCommitmentBeforeTerminal;
        }
    }
    const fingerprint = try requiredString(parts.payload, "grade_commitment_fingerprint");
    if (commitmentFingerprintAlreadyPresent(state, fingerprint)) return error.GradeCommitmentDuplicate;
    var key_id = try validateGradeCommitment(
        allocator,
        trial,
        try required(parts.payload, "grade_commitment"),
        fingerprint,
        "pair",
    );
    errdefer allocator.free(key_id);
    pair.grade_commitment_fingerprint = try allocator.dupe(u8, fingerprint);
    errdefer {
        allocator.free(pair.grade_commitment_fingerprint.?);
        pair.grade_commitment_fingerprint = null;
    }
    pair.grade_commitment_json = try canonicalJsonAlloc(allocator, try required(parts.payload, "grade_commitment"));
    pair.grade_commitment_key_id = key_id;
    key_id = undefined;
}

pub const GradeOpeningKind = enum {
    absolute,
    pair,
};

pub const GradeOpeningBody = struct {
    kind: GradeOpeningKind,
    body_json: []u8,

    pub fn deinit(self: *GradeOpeningBody, allocator: std.mem.Allocator) void {
        allocator.free(self.body_json);
    }
};

fn validateOpeningNonce(nonce: []const u8) !void {
    // The signed contract attests `getentropy` provenance and single use. The
    // verifier proves canonical nonce format and commitment binding; it cannot
    // independently prove runtime entropy provenance or global nonce non-reuse.
    if (nonce.len != 64) return error.GradeOpeningInvalid;
    for (nonce) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.GradeOpeningInvalid;
    }
}

fn gradeCommitmentDigestAlloc(
    allocator: std.mem.Allocator,
    commitment: std.json.ObjectMap,
    grade_receipt_fingerprint: []const u8,
    nonce: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"domain\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, GradeCommitmentDomain);
    try out.writer.writeAll(",\"grade_presentation_receipt_fingerprint\":");
    try writeCanonicalJson(allocator, &out.writer, try required(commitment, "grade_presentation_receipt_fingerprint"));
    try out.writer.writeAll(",\"grade_receipt_fingerprint\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, grade_receipt_fingerprint);
    try out.writer.writeAll(",\"grader_scope\":");
    try writeCanonicalJson(allocator, &out.writer, try required(commitment, "grader_scope"));
    try out.writer.writeAll(",\"identifier_alias_map_fingerprint\":");
    try writeCanonicalJson(allocator, &out.writer, try required(commitment, "identifier_alias_map_fingerprint"));
    try out.writer.writeAll(",\"kind\":");
    try writeCanonicalJson(allocator, &out.writer, try required(commitment, "kind"));
    try out.writer.writeAll(",\"opening_nonce_hex\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, nonce);
    try out.writer.writeAll(",\"producer\":");
    try writeCanonicalJson(allocator, &out.writer, try required(commitment, "producer"));
    try out.writer.writeByte('}');
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(out.written());
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

const ValidatedGradeOpening = struct {
    receipt: std.json.Value,
    receipt_fingerprint: []const u8,
    presentation_fingerprint: []const u8,
};

fn validateGradeOpening(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    commitment_json: []const u8,
    commitment_fingerprint: []const u8,
    commitment_key_id: []const u8,
    opening_value: std.json.Value,
    expected_kind: []const u8,
) !ValidatedGradeOpening {
    var commitment_parsed = try std.json.parseFromSlice(std.json.Value, allocator, commitment_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer commitment_parsed.deinit();
    const commitment = try object(commitment_parsed.value);
    const opening = try object(opening_value);
    try requireExactKeys(opening, &.{
        "schema",
        "kind",
        "grade_commitment_fingerprint",
        "grader_scope",
        "opening_nonce_hex",
        "grade_receipt_fingerprint",
        "grade_receipt",
        "producer",
        "attestation",
    }, error.GradeOpeningInvalid);
    if (!std.mem.eql(u8, try requiredString(opening, "schema"), "hylo-grade-opening/v1") or
        !std.mem.eql(u8, try requiredString(opening, "kind"), expected_kind) or
        !std.mem.eql(u8, try requiredString(opening, "grade_commitment_fingerprint"), commitment_fingerprint) or
        !try jsonValuesEqual(allocator, try required(opening, "grader_scope"), try required(commitment, "grader_scope")) or
        !try jsonValuesEqual(allocator, try required(opening, "producer"), try required(commitment, "producer")))
    {
        return error.GradeOpeningCommitmentMismatch;
    }
    const nonce = try requiredString(opening, "opening_nonce_hex");
    try validateOpeningNonce(nonce);
    const receipt_fingerprint = try requiredString(opening, "grade_receipt_fingerprint");
    try validateFingerprint(receipt_fingerprint);
    const actual_receipt_fingerprint = try digestValueAlloc(allocator, try required(opening, "grade_receipt"));
    defer allocator.free(actual_receipt_fingerprint);
    if (!std.mem.eql(u8, actual_receipt_fingerprint, receipt_fingerprint)) {
        return error.GradeOpeningCommitmentMismatch;
    }
    const receipt = try requiredObject(opening, "grade_receipt");
    if (!std.mem.eql(
        u8,
        try requiredString(receipt, "schema"),
        if (std.mem.eql(u8, expected_kind, "absolute")) "hylo-grade-receipt/v1" else "hylo-pair-grade-receipt/v1",
    ) or !std.mem.eql(
        u8,
        try requiredString(receipt, "grade_presentation_receipt_fingerprint"),
        try requiredString(commitment, "grade_presentation_receipt_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(receipt, "identifier_alias_map_fingerprint"),
        try requiredString(commitment, "identifier_alias_map_fingerprint"),
    )) return error.GradeOpeningPresentationMismatch;
    const expected_role = if (std.mem.eql(u8, expected_kind, "absolute")) "absolute_grader" else "pair_grader";
    const opening_key_id = (try verifyReceiptAttestation(allocator, trial, opening_value, expected_role)) orelse
        return error.GradeOpeningAuthorityMismatch;
    defer allocator.free(opening_key_id);
    const receipt_key_id = (try verifyReceiptAttestation(
        allocator,
        trial,
        try required(opening, "grade_receipt"),
        expected_role,
    )) orelse return error.GradeOpeningAuthorityMismatch;
    defer allocator.free(receipt_key_id);
    if (!std.mem.eql(u8, opening_key_id, commitment_key_id) or
        !std.mem.eql(u8, receipt_key_id, commitment_key_id))
    {
        return error.GradeOpeningAuthorityMismatch;
    }
    const expected_digest = try gradeCommitmentDigestAlloc(
        allocator,
        commitment,
        receipt_fingerprint,
        nonce,
    );
    defer allocator.free(expected_digest);
    if (!std.mem.eql(
        u8,
        expected_digest,
        try requiredString(try requiredObject(commitment, "commitment"), "fingerprint"),
    )) return error.GradeOpeningCommitmentMismatch;
    return .{
        .receipt = try required(opening, "grade_receipt"),
        .receipt_fingerprint = receipt_fingerprint,
        .presentation_fingerprint = try requiredString(receipt, "grade_presentation_receipt_fingerprint"),
    };
}

fn presentationEvidenceForOpening(
    allocator: std.mem.Allocator,
    evidence_items: std.json.Array,
    presentation_fingerprint: []const u8,
    used: *std.StringHashMap(void),
) !std.json.ObjectMap {
    var selected: ?std.json.ObjectMap = null;
    for (evidence_items.items) |evidence_value| {
        const evidence = try object(evidence_value);
        try requireExactKeys(evidence, &.{
            "grade_presentation_receipt_ref",
            "grade_presentation_receipt_fingerprint",
            "grade_presentation_receipt",
        }, error.GradeOpeningPresentationMismatch);
        const declared = try requiredString(evidence, "grade_presentation_receipt_fingerprint");
        try validateFingerprint(declared);
        if (!std.mem.eql(u8, declared, presentation_fingerprint)) continue;
        if (selected != null) return error.GradeOpeningCoverageMismatch;
        const actual = try digestValueAlloc(allocator, try required(evidence, "grade_presentation_receipt"));
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, declared) or
            (try requiredString(evidence, "grade_presentation_receipt_ref")).len == 0)
        {
            return error.GradeOpeningPresentationMismatch;
        }
        selected = evidence;
    }
    const result = selected orelse return error.GradeOpeningPresentationMismatch;
    const entry = try used.getOrPut(presentation_fingerprint);
    if (entry.found_existing) return error.GradeOpeningCoverageMismatch;
    return result;
}

fn absoluteOpeningBodyAlloc(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    lane: *const LaneState,
    opening: ValidatedGradeOpening,
    evidence: std.json.ObjectMap,
) ![]u8 {
    const receipt_json = try canonicalJsonAlloc(allocator, opening.receipt);
    defer allocator.free(receipt_json);
    const presentation_json = try canonicalJsonAlloc(allocator, try required(evidence, "grade_presentation_receipt"));
    defer allocator.free(presentation_json);
    const receipt_ref = try std.fmt.allocPrint(allocator, "artifact:{s}", .{opening.receipt_fingerprint});
    defer allocator.free(receipt_ref);
    return std.fmt.allocPrint(
        allocator,
        "{{\"scenario_id\":{f},\"attempt_id\":{f},\"grade_id\":{f},\"payload\":{{\"trial_id\":{f},\"pair_id\":{f},\"opaque_arm_id\":{f},\"grade_receipt_ref\":{f},\"grade_receipt_fingerprint\":{f},\"grade_receipt\":{s},\"grade_presentation_receipt_ref\":{f},\"grade_presentation_receipt_fingerprint\":{f},\"grade_presentation_receipt\":{s}}}}}",
        .{
            std.json.fmt(lane.scenario_id, .{}),
            std.json.fmt(lane.id, .{}),
            std.json.fmt(lane.grade_commitment_grade_id orelse return error.GradeOpeningCoverageMismatch, .{}),
            std.json.fmt(trial.id, .{}),
            std.json.fmt(lane.pair_id, .{}),
            std.json.fmt(lane.arm_id, .{}),
            std.json.fmt(receipt_ref, .{}),
            std.json.fmt(opening.receipt_fingerprint, .{}),
            receipt_json,
            std.json.fmt(try requiredString(evidence, "grade_presentation_receipt_ref"), .{}),
            std.json.fmt(opening.presentation_fingerprint, .{}),
            presentation_json,
        },
    );
}

fn pairOpeningBodyAlloc(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    pair: *const PairState,
    opening: ValidatedGradeOpening,
    evidence: std.json.ObjectMap,
) ![]u8 {
    const receipt_json = try canonicalJsonAlloc(allocator, opening.receipt);
    defer allocator.free(receipt_json);
    const presentation_json = try canonicalJsonAlloc(allocator, try required(evidence, "grade_presentation_receipt"));
    defer allocator.free(presentation_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"scenario_id\":null,\"attempt_id\":null,\"grade_id\":null,\"payload\":{{\"trial_id\":{f},\"pair_id\":{f},\"pair_grade_receipt_fingerprint\":{f},\"pair_grade_receipt\":{s},\"grade_presentation_receipt_ref\":{f},\"grade_presentation_receipt_fingerprint\":{f},\"grade_presentation_receipt\":{s}}}}}",
        .{
            std.json.fmt(trial.id, .{}),
            std.json.fmt(pair.id, .{}),
            std.json.fmt(opening.receipt_fingerprint, .{}),
            receipt_json,
            std.json.fmt(try requiredString(evidence, "grade_presentation_receipt_ref"), .{}),
            std.json.fmt(opening.presentation_fingerprint, .{}),
            presentation_json,
        },
    );
}

pub fn gradeOpeningBodiesAlloc(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    reveal: std.json.ObjectMap,
) ![]GradeOpeningBody {
    if (!trial.requires_grade_commitments) return allocator.alloc(GradeOpeningBody, 0);
    if (!trial.allRequiredGradeCommitmentsPresent()) return error.RevealBeforeGradeCommitments;
    const openings = try requiredArray(reveal, "grade_openings");
    const presentation_evidence = try requiredArray(reveal, "grade_presentation_evidence");
    var expected_count: usize = 0;
    for (trial.lanes.items) |lane| if (lane.status == .completed) {
        expected_count += 1;
    };
    if (trial.requires_pair_grade) expected_count += trial.pairs.items.len;
    if (openings.items.len != expected_count or presentation_evidence.items.len != expected_count) {
        return error.GradeOpeningCoverageMismatch;
    }
    const result = try allocator.alloc(GradeOpeningBody, expected_count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*entry| entry.deinit(allocator);
        allocator.free(result);
    }
    var opened = std.StringHashMap(void).init(allocator);
    defer opened.deinit();
    var used_presentations = std.StringHashMap(void).init(allocator);
    defer used_presentations.deinit();
    for (openings.items) |opening_value| {
        const opening_object = try object(opening_value);
        const declared_commitment = try requiredString(opening_object, "grade_commitment_fingerprint");
        const opened_entry = try opened.getOrPut(declared_commitment);
        if (opened_entry.found_existing) return error.GradeOpeningCoverageMismatch;
        var matched = false;
        for (trial.lanes.items) |*lane| {
            if (lane.grade_commitment_fingerprint == null or
                !std.mem.eql(u8, lane.grade_commitment_fingerprint.?, declared_commitment)) continue;
            if (matched) return error.GradeOpeningCoverageMismatch;
            matched = true;
            const validated = try validateGradeOpening(
                allocator,
                trial,
                lane.grade_commitment_json orelse return error.GradeOpeningCoverageMismatch,
                declared_commitment,
                lane.grade_commitment_key_id orelse return error.GradeOpeningAuthorityMismatch,
                opening_value,
                "absolute",
            );
            const evidence = try presentationEvidenceForOpening(
                allocator,
                presentation_evidence,
                validated.presentation_fingerprint,
                &used_presentations,
            );
            result[initialized] = .{
                .kind = .absolute,
                .body_json = try absoluteOpeningBodyAlloc(allocator, trial, lane, validated, evidence),
            };
            initialized += 1;
        }
        for (trial.pairs.items) |*pair| {
            if (pair.grade_commitment_fingerprint == null or
                !std.mem.eql(u8, pair.grade_commitment_fingerprint.?, declared_commitment)) continue;
            if (matched) return error.GradeOpeningCoverageMismatch;
            matched = true;
            const validated = try validateGradeOpening(
                allocator,
                trial,
                pair.grade_commitment_json orelse return error.GradeOpeningCoverageMismatch,
                declared_commitment,
                pair.grade_commitment_key_id orelse return error.GradeOpeningAuthorityMismatch,
                opening_value,
                "pair",
            );
            const evidence = try presentationEvidenceForOpening(
                allocator,
                presentation_evidence,
                validated.presentation_fingerprint,
                &used_presentations,
            );
            result[initialized] = .{
                .kind = .pair,
                .body_json = try pairOpeningBodyAlloc(allocator, trial, pair, validated, evidence),
            };
            initialized += 1;
        }
        if (!matched) return error.GradeOpeningCoverageMismatch;
    }
    if (initialized != expected_count or opened.count() != expected_count or used_presentations.count() != expected_count) {
        return error.GradeOpeningCoverageMismatch;
    }
    return result;
}

pub fn clearOpenedGrades(allocator: std.mem.Allocator, trial: *TrialState) void {
    for (trial.lanes.items) |*lane| {
        lane.absolute_graded = false;
        if (lane.grade_id) |value| allocator.free(value);
        lane.grade_id = null;
        if (lane.grade_status) |value| allocator.free(value);
        lane.grade_status = null;
        lane.aggregate = null;
        lane.critical_failure_count = null;
        if (lane.grade_receipt_json) |value| allocator.free(value);
        lane.grade_receipt_json = null;
        if (lane.grade_key_id) |value| allocator.free(value);
        lane.grade_key_id = null;
        if (lane.grade_presenter_key_id) |value| allocator.free(value);
        lane.grade_presenter_key_id = null;
        if (lane.grade_presentation_capability_digest) |value| allocator.free(value);
        lane.grade_presentation_capability_digest = null;
        if (lane.grade_presentation_receipt_json) |value| allocator.free(value);
        lane.grade_presentation_receipt_json = null;
        if (lane.human_confirmation_key_id) |value| allocator.free(value);
        lane.human_confirmation_key_id = null;
    }
    for (trial.pairs.items) |*pair| {
        pair.pair_graded = false;
        if (pair.grader_key_id) |value| allocator.free(value);
        pair.grader_key_id = null;
        if (pair.grade_presenter_key_id) |value| allocator.free(value);
        pair.grade_presenter_key_id = null;
        if (pair.grade_presentation_capability_digest) |value| allocator.free(value);
        pair.grade_presentation_capability_digest = null;
        if (pair.grade_presentation_receipt_json) |value| allocator.free(value);
        pair.grade_presentation_receipt_json = null;
        if (pair.pair_grade_receipt_json) |value| allocator.free(value);
        pair.pair_grade_receipt_json = null;
    }
}

pub fn applyAbsoluteGrade(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
    minimum_aggregate: f64,
    zero_critical_violations: bool,
    authoritative_critical_failure_count: usize,
) !bool {
    const parts = try requiredBodyPayload(body_value);
    const trial_id = try optionalString(parts.payload, "trial_id") orelse return false;
    const trial = state.findTrial(trial_id) orelse return error.TrialMissing;
    if (trial.revealed) return error.GradeAfterReveal;
    if (trial.closed) return error.GradeAfterClose;
    const lane_id = try optionalString(parts.body, "attempt_id") orelse return error.LaneNotRegistered;
    const scenario_id = try optionalString(parts.body, "scenario_id") orelse return error.ScenarioMissing;
    const grade_id = try optionalString(parts.body, "grade_id") orelse return error.GradeMissing;
    const lane = trial.findLane(lane_id) orelse return error.LaneNotRegistered;
    if (lane.status != .completed) return error.GradeBeforeTerminal;
    if (lane.absolute_graded) return error.DuplicateComparableGrade;
    if (!std.mem.eql(u8, lane.arm_id, try requiredString(parts.payload, "opaque_arm_id"))) {
        return error.LaneManifestMismatch;
    }
    if (!std.mem.eql(u8, lane.scenario_id, scenario_id) or
        !std.mem.eql(u8, lane.pair_id, try requiredString(parts.payload, "pair_id")))
    {
        return error.LaneManifestMismatch;
    }
    try validateId(grade_id);
    const receipt = try requiredObject(parts.payload, "grade_receipt");
    try validateLimitationsRecursive(try required(parts.payload, "grade_receipt"));
    const declared_receipt_fingerprint = try requiredString(parts.payload, "grade_receipt_fingerprint");
    try validateFingerprint(declared_receipt_fingerprint);
    const actual_receipt_fingerprint = try digestValueAlloc(
        allocator,
        try required(parts.payload, "grade_receipt"),
    );
    defer allocator.free(actual_receipt_fingerprint);
    if (!std.mem.eql(u8, declared_receipt_fingerprint, actual_receipt_fingerprint)) {
        return error.GradeReceiptInvalid;
    }
    if ((try requiredString(parts.payload, "grade_receipt_ref")).len == 0) return error.GradeReceiptInvalid;
    if (!std.mem.eql(u8, try requiredString(receipt, "schema"), "hylo-grade-receipt/v1")) {
        return error.GradeReceiptInvalid;
    }
    const producer = try requiredObject(receipt, "producer");
    try validateId(try requiredString(producer, "id"));
    if ((try requiredString(producer, "version")).len == 0) return error.GradeReceiptInvalid;
    try validateFingerprint(try requiredString(producer, "binary_fingerprint"));
    try validateId(try requiredString(producer, "key_id"));
    const judge = try requiredObject(receipt, "judge");
    const judge_kind = try requiredString(judge, "kind");
    if (judge_kind.len == 0 or (try requiredString(judge, "id")).len == 0 or
        (try requiredString(judge, "version")).len == 0)
    {
        return error.GradeReceiptInvalid;
    }
    try validateFingerprint(try requiredString(judge, "config_fingerprint"));
    const has_grade_presentation = parts.payload.get("grade_presentation_receipt") != null;
    if ((!has_grade_presentation and
        (!std.mem.eql(u8, try requiredString(receipt, "trial_id"), trial.id) or
            !std.mem.eql(u8, try requiredString(receipt, "lane_id"), lane.id) or
            !std.mem.eql(u8, try requiredString(receipt, "opaque_arm_id"), lane.arm_id))) or
        lane.run_receipt_fingerprint == null or
        !std.mem.eql(
            u8,
            try requiredString(receipt, "run_receipt_fingerprint"),
            lane.run_receipt_fingerprint.?,
        ))
    {
        return error.GradeReceiptInvalid;
    }
    var trial_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial.trial_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial_parsed.deinit();
    const trial_root = try object(trial_parsed.value);
    var presentation_evidence = try validateAbsoluteGradePresentation(
        allocator,
        state,
        trial,
        trial_root,
        parts.payload,
        receipt,
        producer,
        lane,
    );
    errdefer if (presentation_evidence) |evidence| {
        allocator.free(evidence.key_id);
        allocator.free(evidence.capability_digest);
        allocator.free(evidence.receipt_json);
    };
    const blinding = try requiredObject(receipt, "blinding");
    if (try boolean(try required(blinding, "semantic_arm_identity_visible")) or
        try boolean(try required(blinding, "target_diff_visible")) or
        try boolean(try required(blinding, "sibling_output_visible")) or
        try boolean(try required(blinding, "prior_trial_results_visible")))
    {
        return error.GradeNotBlind;
    }
    var grade_key_id = try verifyReceiptAttestation(
        allocator,
        trial,
        try required(parts.payload, "grade_receipt"),
        "absolute_grader",
    );
    errdefer if (grade_key_id) |value| allocator.free(value);
    if (std.mem.eql(u8, judge_kind, "human") or receipt.get("human_confirmation_receipt") != null) {
        lane.human_confirmation_key_id = try validateHumanConfirmation(
            allocator,
            trial,
            lane,
            receipt,
        );
    }
    try validateFrozenProducer(trial_root, producer, "absolute_grader", error.GradeReceiptInvalid);
    if (!std.mem.eql(
        u8,
        try requiredString(receipt, "rubric_fingerprint"),
        try requiredString(try requiredObject(trial_root, "grading"), "rubric_fingerprint"),
    )) return error.RubricMismatch;
    const dimensions = try requiredArray(receipt, "dimensions");
    if (dimensions.items.len == 0) return error.GradeReceiptInvalid;
    var total_weight: f64 = 0;
    var weighted_score: f64 = 0;
    var dimension_ids = std.StringHashMap(void).init(allocator);
    defer dimension_ids.deinit();
    for (dimensions.items) |dimension_value| {
        const dimension = try object(dimension_value);
        const id = try requiredString(dimension, "id");
        try validateId(id);
        const entry = try dimension_ids.getOrPut(id);
        if (entry.found_existing) return error.DuplicateDimension;
        const score = switch (try required(dimension, "score")) {
            .float => |number| number,
            .integer => |number| @as(f64, @floatFromInt(number)),
            else => return error.GradeReceiptInvalid,
        };
        const weight = switch (try required(dimension, "weight")) {
            .float => |number| number,
            .integer => |number| @as(f64, @floatFromInt(number)),
            else => return error.GradeReceiptInvalid,
        };
        if (!std.math.isFinite(score) or score < 0 or score > 1 or
            !std.math.isFinite(weight) or weight < 0)
        {
            return error.GradeReceiptInvalid;
        }
        _ = try requiredString(dimension, "grader_kind");
        _ = try requiredString(dimension, "grader_ref");
        try validateFingerprint(try requiredString(dimension, "grader_fingerprint"));
        total_weight += weight;
        weighted_score += score * weight;
    }
    if (total_weight <= 0) return error.GradeReceiptInvalid;
    const computed_aggregate = weighted_score / total_weight;
    if (receipt.get("aggregate")) |claimed| {
        const claimed_value = switch (claimed) {
            .float => |number| number,
            .integer => |number| @as(f64, @floatFromInt(number)),
            else => return error.GradeReceiptInvalid,
        };
        if (@abs(claimed_value - computed_aggregate) > 1e-12) return error.GradeAggregateMismatch;
    }
    var derived_critical_count: usize = 0;
    const criticals = try requiredArray(receipt, "derived_critical_violations");
    for (criticals.items) |critical_value| {
        const critical = try object(critical_value);
        try validateId(try requiredString(critical, "violation_id"));
        const authority_kind = try requiredString(critical, "authority_kind");
        if (!std.mem.eql(u8, authority_kind, "rubric_dimension") and
            !std.mem.eql(u8, authority_kind, "scenario_oracle") and
            !std.mem.eql(u8, authority_kind, "trace_invariant"))
        {
            return error.FreeFormCriticalViolationForbidden;
        }
        try validateId(try requiredString(critical, "authority_id"));
        if ((try requiredArray(critical, "evidence_refs")).items.len == 0) {
            return error.FreeFormCriticalViolationForbidden;
        }
        derived_critical_count += 1;
    }
    const oracle_results = try requiredArray(receipt, "oracle_results");
    for (oracle_results.items) |oracle_value| {
        const oracle = try object(oracle_value);
        const oracle_status = try requiredString(oracle, "status");
        if (!std.mem.eql(u8, oracle_status, "pass") and
            !std.mem.eql(u8, oracle_status, "fail") and
            !std.mem.eql(u8, oracle_status, "unavailable"))
        {
            return error.GradeReceiptInvalid;
        }
    }
    if (authoritative_critical_failure_count < derived_critical_count) {
        return error.GradeReceiptInvalid;
    }
    const expected_pass = computed_aggregate >= minimum_aggregate and
        (!zero_critical_violations or authoritative_critical_failure_count == 0);
    const status = try requiredString(receipt, "status");
    if (std.mem.eql(u8, status, "pass")) {
        if (!expected_pass) return error.PassPolicyMismatch;
    } else if (std.mem.eql(u8, status, "fail")) {
        if (expected_pass) return error.FailSatisfiesPassPolicy;
    } else if (!std.mem.eql(u8, status, "invalid") and !std.mem.eql(u8, status, "incomparable")) {
        return error.GradeReceiptInvalid;
    }
    lane.absolute_graded = true;
    lane.grade_id = try allocator.dupe(u8, grade_id);
    lane.grade_status = try dupeRequiredString(allocator, receipt, "status");
    lane.grade_receipt_json = try canonicalJsonAlloc(allocator, try required(parts.payload, "grade_receipt"));
    lane.aggregate = computed_aggregate;
    lane.critical_failure_count = authoritative_critical_failure_count;
    lane.grade_key_id = grade_key_id;
    grade_key_id = null;
    if (presentation_evidence) |evidence| {
        lane.grade_presenter_key_id = evidence.key_id;
        lane.grade_presentation_capability_digest = evidence.capability_digest;
        lane.grade_presentation_receipt_json = evidence.receipt_json;
        presentation_evidence = null;
    }
    return true;
}

pub fn pairPresentationCommitmentAlloc(
    allocator: std.mem.Allocator,
    trial_id: []const u8,
    pair_id: []const u8,
    left_lane_id: []const u8,
    left_output_fingerprint: []const u8,
    right_lane_id: []const u8,
    right_output_fingerprint: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"left_lane_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, left_lane_id);
    try out.writer.writeAll(",\"left_output_fingerprint\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, left_output_fingerprint);
    try out.writer.writeAll(",\"pair_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, pair_id);
    try out.writer.writeAll(",\"right_lane_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, right_lane_id);
    try out.writer.writeAll(",\"right_output_fingerprint\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, right_output_fingerprint);
    try out.writer.writeAll(",\"schema\":\"hylo-pair-grade-presentation/v1\",\"trial_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, trial_id);
    try out.writer.writeByte('}');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

pub fn applyPairGrade(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
) !void {
    const parts = try requiredBodyPayload(body_value);
    const trial = state.findTrial(try requiredString(parts.payload, "trial_id")) orelse return error.TrialMissing;
    if (trial.revealed) return error.GradeAfterReveal;
    if (trial.closed) return error.GradeAfterClose;
    const pair = trial.findPair(try requiredString(parts.payload, "pair_id")) orelse return error.PairMissing;
    if (pair.pair_graded) return error.PairGradeDuplicate;
    for (trial.lanes.items) |lane| {
        if (std.mem.eql(u8, lane.pair_id, pair.id) and lane.status != .completed) {
            return error.PairGradeBeforeSiblingsTerminal;
        }
    }
    const receipt = try requiredObject(parts.payload, "pair_grade_receipt");
    try validateLimitationsRecursive(try required(parts.payload, "pair_grade_receipt"));
    const declared_receipt_fingerprint = try requiredString(parts.payload, "pair_grade_receipt_fingerprint");
    try validateFingerprint(declared_receipt_fingerprint);
    const actual_receipt_fingerprint = try digestValueAlloc(
        allocator,
        try required(parts.payload, "pair_grade_receipt"),
    );
    defer allocator.free(actual_receipt_fingerprint);
    if (!std.mem.eql(u8, declared_receipt_fingerprint, actual_receipt_fingerprint)) {
        return error.PairGradeReceiptInvalid;
    }
    if (!std.mem.eql(u8, try requiredString(receipt, "schema"), "hylo-pair-grade-receipt/v1")) {
        return error.PairGradeReceiptInvalid;
    }
    const producer = try requiredObject(receipt, "producer");
    try validateId(try requiredString(producer, "id"));
    if ((try requiredString(producer, "version")).len == 0) return error.PairGradeReceiptInvalid;
    try validateFingerprint(try requiredString(producer, "binary_fingerprint"));
    try validateId(try requiredString(producer, "key_id"));
    const has_grade_presentation = parts.payload.get("grade_presentation_receipt") != null;
    if (!has_grade_presentation and
        (!std.mem.eql(u8, try requiredString(receipt, "trial_id"), trial.id) or
            !std.mem.eql(u8, try requiredString(receipt, "pair_id"), pair.id)))
        return error.PairGradeReceiptInvalid;
    const lane_ids = try requiredArray(receipt, "lane_ids");
    if (lane_ids.items.len != 2) return error.PairGradeReceiptInvalid;
    if (std.mem.eql(u8, try string(lane_ids.items[0]), try string(lane_ids.items[1]))) {
        return error.PairGradeReceiptInvalid;
    }
    const presentation = try requiredObject(receipt, "presentation");
    try expectTrue(presentation, "sibling_outputs_only", error.PairGradeReceiptInvalid);
    const receipt_left_lane_id = try requiredString(presentation, "left_lane_id");
    const receipt_right_lane_id = try requiredString(presentation, "right_lane_id");
    if (std.mem.eql(u8, receipt_left_lane_id, receipt_right_lane_id)) return error.PairGradeReceiptInvalid;
    const SelectedPairGradeLanes = struct { left: *LaneState, right: *LaneState };
    const selected_lanes: SelectedPairGradeLanes = if (has_grade_presentation) blk: {
        const presentation_receipt = try requiredObject(parts.payload, "grade_presentation_receipt");
        const scope_lanes = try requiredArray(try requiredObject(presentation_receipt, "scope"), "lane_ids");
        if (scope_lanes.items.len != 2) return error.GradePresentationInvalid;
        const left_lane_id = try string(scope_lanes.items[0]);
        const right_lane_id = try string(scope_lanes.items[1]);
        if (std.mem.eql(u8, left_lane_id, right_lane_id)) return error.GradePresentationInvalid;
        break :blk .{
            .left = trial.findLane(left_lane_id) orelse return error.GradePresentationInvalid,
            .right = trial.findLane(right_lane_id) orelse return error.GradePresentationInvalid,
        };
    } else blk: {
        for (lane_ids.items) |lane_value| {
            const lane = trial.findLane(try string(lane_value)) orelse return error.PairGradeReceiptInvalid;
            if (!std.mem.eql(u8, lane.pair_id, pair.id)) return error.PairGradeReceiptInvalid;
        }
        break :blk .{
            .left = trial.findLane(receipt_left_lane_id) orelse return error.PairGradeReceiptInvalid,
            .right = trial.findLane(receipt_right_lane_id) orelse return error.PairGradeReceiptInvalid,
        };
    };
    const left_lane = selected_lanes.left;
    const right_lane = selected_lanes.right;
    if (!std.mem.eql(u8, left_lane.pair_id, pair.id) or !std.mem.eql(u8, right_lane.pair_id, pair.id)) {
        return error.PairGradeReceiptInvalid;
    }
    const left_output_fingerprint = left_lane.output_fingerprint orelse return error.PairGradeReceiptInvalid;
    const right_output_fingerprint = right_lane.output_fingerprint orelse return error.PairGradeReceiptInvalid;
    if (!std.mem.eql(
        u8,
        try requiredString(presentation, "left_output_fingerprint"),
        left_output_fingerprint,
    ) or !std.mem.eql(
        u8,
        try requiredString(presentation, "right_output_fingerprint"),
        right_output_fingerprint,
    )) return error.PairGradeReceiptInvalid;
    var trial_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial.trial_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial_parsed.deinit();
    const trial_root = try object(trial_parsed.value);
    const position_map_commitment = try requiredString(presentation, "position_map_commitment");
    try validateFingerprint(position_map_commitment);
    const sealed = std.mem.eql(
        u8,
        try requiredString(try requiredObject(trial_root, "assurance"), "required_level"),
        "sealed",
    );
    if (!sealed) {
        const expected_presentation_commitment = try pairPresentationCommitmentAlloc(
            allocator,
            trial.id,
            pair.id,
            receipt_left_lane_id,
            left_output_fingerprint,
            receipt_right_lane_id,
            right_output_fingerprint,
        );
        defer allocator.free(expected_presentation_commitment);
        if (!std.mem.eql(u8, position_map_commitment, expected_presentation_commitment)) {
            return error.PairGradeReceiptInvalid;
        }
    }
    const judge_contracts = try requiredArray(try requiredObject(trial_root, "grading"), "judge_contracts");
    if (judge_contracts.items.len != 1 or !std.mem.eql(
        u8,
        try requiredString(try object(judge_contracts.items[0]), "contract_fingerprint"),
        try requiredString(receipt, "judge_contract_fingerprint"),
    )) return error.JudgeContractMismatch;
    var presentation_evidence = try validatePairGradePresentation(
        allocator,
        state,
        trial,
        trial_root,
        parts.payload,
        receipt,
        producer,
        pair,
        left_lane,
        right_lane,
        position_map_commitment,
    );
    errdefer if (presentation_evidence) |evidence| {
        allocator.free(evidence.key_id);
        allocator.free(evidence.capability_digest);
        allocator.free(evidence.receipt_json);
    };
    const blinding = try requiredObject(receipt, "blinding");
    if (try boolean(try required(blinding, "semantic_arm_identity_visible")) or
        try boolean(try required(blinding, "opaque_arm_id_visible")) or
        try boolean(try required(blinding, "target_diff_visible")) or
        try boolean(try required(blinding, "lane_execution_order_visible")) or
        try boolean(try required(blinding, "absolute_grade_results_visible")) or
        try boolean(try required(blinding, "prior_pair_results_visible")))
    {
        return error.PairGradeNotBlind;
    }
    var grader_key_id = try verifyReceiptAttestation(
        allocator,
        trial,
        try required(parts.payload, "pair_grade_receipt"),
        "pair_grader",
    );
    errdefer if (grader_key_id) |value| allocator.free(value);
    const verdict = try requiredObject(receipt, "verdict");
    const preferred = try requiredString(verdict, "preferred");
    if (!std.mem.eql(u8, preferred, "left") and !std.mem.eql(u8, preferred, "right") and
        !std.mem.eql(u8, preferred, "tie") and !std.mem.eql(u8, preferred, "incomparable"))
    {
        return error.PairGradeReceiptInvalid;
    }
    const confidence = switch (try required(verdict, "confidence")) {
        .float => |number| number,
        .integer => |number| @as(f64, @floatFromInt(number)),
        else => return error.PairGradeReceiptInvalid,
    };
    if (!std.math.isFinite(confidence) or confidence < 0 or confidence > 1) {
        return error.PairGradeReceiptInvalid;
    }
    try expectTrue(receipt, "prohibited_critical_authority", error.PairGradeCriticalAuthorityForbidden);
    try validateFrozenProducer(
        trial_root,
        producer,
        "pair_grader",
        error.PairGradeReceiptInvalid,
    );
    const primary_dimensions = try requiredArray(
        try requiredObject(try object(trial_parsed.value), "estimand"),
        "primary_dimensions",
    );
    const dimensions = try requiredArray(receipt, "dimensions");
    if (dimensions.items.len != primary_dimensions.items.len) return error.PairGradeReceiptInvalid;
    for (dimensions.items, 0..) |dimension_value, index| {
        const dimension = try object(dimension_value);
        const id = try requiredString(dimension, "id");
        if (!std.mem.eql(u8, id, try string(primary_dimensions.items[index]))) {
            return error.PairGradeReceiptInvalid;
        }
        const dimension_preference = try requiredString(dimension, "preferred");
        if (!std.mem.eql(u8, dimension_preference, "left") and
            !std.mem.eql(u8, dimension_preference, "right") and
            !std.mem.eql(u8, dimension_preference, "tie") and
            !std.mem.eql(u8, dimension_preference, "incomparable"))
        {
            return error.PairGradeReceiptInvalid;
        }
        if ((try requiredString(dimension, "rationale_ref")).len == 0 or
            (try requiredArray(dimension, "evidence_refs")).items.len == 0)
        {
            return error.PairGradeReceiptInvalid;
        }
    }
    if ((try requiredArray(receipt, "evidence_refs")).items.len == 0) return error.PairGradeReceiptInvalid;
    pair.pair_grade_receipt_json = try canonicalJsonAlloc(
        allocator,
        try required(parts.payload, "pair_grade_receipt"),
    );
    pair.grader_key_id = grader_key_id;
    grader_key_id = null;
    if (presentation_evidence) |evidence| {
        pair.grade_presenter_key_id = evidence.key_id;
        pair.grade_presentation_capability_digest = evidence.capability_digest;
        pair.grade_presentation_receipt_json = evidence.receipt_json;
        presentation_evidence = null;
    }
    pair.pair_graded = true;
}

fn revealCommitmentAlloc(
    allocator: std.mem.Allocator,
    trial_id: []const u8,
    mapping: std.json.Value,
    nonce: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"mapping\":");
    try writeCanonicalJson(allocator, &out.writer, mapping);
    try out.writer.writeAll(",\"nonce\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, nonce);
    try out.writer.writeAll(",\"schema\":\"hylo-arm-map/v1\",\"trial_id\":");
    try retrace_core.canonical_json.writeCanonicalString(&out.writer, trial_id);
    try out.writer.writeByte('}');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn validateRevealNonce(nonce: []const u8) !void {
    // Existing HCTP producers use either a bare 128-bit lowercase hex nonce or
    // a descriptive prefix followed by that canonical suffix. Preserve both
    // encodings while rejecting commitments whose hiding value is enumerable.
    if (nonce.len < 32) return error.RevealNonceEntropyInvalid;
    const suffix = nonce[nonce.len - 32 ..];
    for (suffix) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
            return error.RevealNonceEntropyInvalid;
        }
    }
}

fn validateRoleSeparation(
    allocator: std.mem.Allocator,
    trial: *const TrialState,
    reveal: std.json.ObjectMap,
) !void {
    var assurance_view = try assuranceForTrial(allocator, trial);
    defer assurance_view.parsed.deinit();
    const role_separated = std.mem.eql(u8, assurance_view.level, "role_separated") or
        std.mem.eql(u8, assurance_view.level, "sealed");
    if (!role_separated) return;
    const required_roles = try requiredArray(assurance_view.assurance, "required_distinct_roles");
    const require_pair_grader = try listContains(required_roles, "pair_grader");
    const require_human_confirmer = try listContains(required_roles, "human_confirmer");
    const require_materializer = try listContains(required_roles, "materializer");
    if (require_pair_grader and !trial.requires_pair_grade) return error.RoleSeparationInvalid;
    if (std.mem.eql(u8, assurance_view.level, "sealed")) {
        const receipts = try requiredArray(reveal, "materialization_receipts");
        if (receipts.items.len != trial.lanes.items.len) return error.SealedMaterializationMissing;
    }
    const trust = try object(
        assurance_view.assurance.get("trust_policy") orelse return error.TrustPolicyMissing,
    );
    for (trial.lanes.items) |lane| {
        if (lane.runner_key_id == null or lane.grade_key_id == null) return error.RoleSeparationInvalid;
        if (try keyIdsSharePublicMaterial(
            allocator,
            trust,
            lane.runner_key_id.?,
            lane.grade_key_id.?,
        )) return error.RoleSeparationInvalid;
        const pair = trial.findPairConst(lane.pair_id) orelse return error.PairMissing;
        if (trial.requires_pair_grade) {
            if (pair.grader_key_id == null or
                try keyIdsSharePublicMaterial(
                    allocator,
                    trust,
                    pair.grader_key_id.?,
                    lane.runner_key_id.?,
                ) or
                try keyIdsSharePublicMaterial(
                    allocator,
                    trust,
                    pair.grader_key_id.?,
                    lane.grade_key_id.?,
                ))
            {
                return error.RoleSeparationInvalid;
            }
        }
        if (std.mem.eql(u8, assurance_view.level, "sealed")) {
            if (lane.grade_presenter_key_id == null or
                try keyIdsSharePublicMaterial(
                    allocator,
                    trust,
                    lane.grade_presenter_key_id.?,
                    lane.runner_key_id.?,
                ) or
                try keyIdsSharePublicMaterial(
                    allocator,
                    trust,
                    lane.grade_presenter_key_id.?,
                    lane.grade_key_id.?,
                ) or
                (pair.grader_key_id != null and
                    try keyIdsSharePublicMaterial(
                        allocator,
                        trust,
                        lane.grade_presenter_key_id.?,
                        pair.grader_key_id.?,
                    )) or
                (trial.requires_pair_grade and pair.grade_presenter_key_id == null) or
                (pair.grade_presenter_key_id != null and pair.grader_key_id != null and
                    try keyIdsSharePublicMaterial(
                        allocator,
                        trust,
                        pair.grade_presenter_key_id.?,
                        pair.grader_key_id.?,
                    )))
            {
                return error.RoleSeparationInvalid;
            }
        }
        if (require_human_confirmer) {
            if (lane.human_confirmation_key_id == null or
                try keyIdsSharePublicMaterial(
                    allocator,
                    trust,
                    lane.human_confirmation_key_id.?,
                    lane.runner_key_id.?,
                ) or
                try keyIdsSharePublicMaterial(
                    allocator,
                    trust,
                    lane.human_confirmation_key_id.?,
                    lane.grade_key_id.?,
                ) or
                (pair.grader_key_id != null and
                    try keyIdsSharePublicMaterial(
                        allocator,
                        trust,
                        lane.human_confirmation_key_id.?,
                        pair.grader_key_id.?,
                    )))
            {
                return error.RoleSeparationInvalid;
            }
        }
    }
    if (!std.mem.eql(u8, assurance_view.level, "sealed") and !require_materializer) return;
    const receipts = try requiredArray(reveal, "materialization_receipts");
    if (receipts.items.len != trial.lanes.items.len) return error.SealedMaterializationMissing;
    const trial_root = try object(assurance_view.parsed.value);
    const materializer_contract = try requiredObject(
        try requiredObject(trial_root, "sealing"),
        "case_materializer_contract",
    );
    const sealing = try requiredObject(trial_root, "sealing");
    const expected_controller_id = try requiredString(materializer_contract, "controller_id");
    const expected_materializer_id = try requiredString(materializer_contract, "materializer_id");
    const expected_materializer_version = try requiredString(materializer_contract, "materializer_version");
    const expected_materializer_binary = try requiredString(materializer_contract, "materializer_binary_fingerprint");
    const expected_runner_id = try requiredString(materializer_contract, "runner_id");
    const expected_materializer_key_id = try requiredString(materializer_contract, "materializer_key_id");
    const expected_runner_key_id = try requiredString(materializer_contract, "runner_key_id");
    var materialized_lanes = std.StringHashMap(void).init(allocator);
    defer materialized_lanes.deinit();
    for (receipts.items) |receipt_value| {
        const receipt = try object(receipt_value);
        if (!std.mem.eql(u8, try requiredString(receipt, "schema"), "hylo-materialization-receipt/v1")) {
            return error.SealedMaterializationInvalid;
        }
        if (!std.mem.eql(u8, try requiredString(receipt, "trial_id"), trial.id)) {
            return error.SealedMaterializationInvalid;
        }
        const lane_id = try requiredString(receipt, "lane_id");
        const lane = trial.findLaneConst(lane_id) orelse return error.SealedMaterializationInvalid;
        const source_case = (try sourceCaseForLane(trial_root, lane)) orelse
            return error.SealedMaterializationInvalid;
        const sealed_case = try requiredObject(source_case, "sealed_case");
        const materialized_entry = try materialized_lanes.getOrPut(lane_id);
        if (materialized_entry.found_existing or
            !std.mem.eql(u8, try requiredString(receipt, "unit_id"), lane.unit_id) or
            !std.mem.eql(u8, try requiredString(receipt, "source_episode_projection_version"), retrace_core.hctp_adapter.source_episode_projection_version) or
            !std.mem.eql(u8, try requiredString(receipt, "opaque_arm_id"), lane.arm_id) or
            lane.presented_input_fingerprint == null or !std.mem.eql(
            u8,
            try requiredString(receipt, "visible_input_fingerprint"),
            lane.presented_input_fingerprint.?,
        ) or !std.mem.eql(
            u8,
            try requiredString(receipt, "visible_input_fingerprint"),
            try requiredString(source_case, "visible_input_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(receipt, "hidden_reference_fingerprint"),
            try requiredString(source_case, "hidden_reference_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(receipt, "source_episode_fingerprint"),
            try requiredString(source_case, "source_episode_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(receipt, "source_profile_fingerprint"),
            try requiredString(source_case, "source_profile_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(receipt, "ciphertext_fingerprint"),
            try requiredString(sealed_case, "ciphertext_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(receipt, "source_selection_receipt_fingerprint"),
            try requiredString(sealing, "source_selection_receipt_fingerprint"),
        ) or try boolean(try required(receipt, "hidden_reference_disclosed")) or
            try boolean(try required(receipt, "semantic_arm_identity_disclosed")))
        {
            return error.SealedMaterializationInvalid;
        }
        const capability_scope = try requiredObject(receipt, "capability_scope");
        const capability_digest = try requiredString(capability_scope, "capability_digest");
        try validateFingerprint(capability_digest);
        if (!std.mem.eql(u8, try requiredString(capability_scope, "trial_id"), trial.id) or
            !std.mem.eql(u8, try requiredString(capability_scope, "lane_id"), lane.id) or
            try integer(try required(capability_scope, "unit_count")) != 1 or
            try integer(try required(capability_scope, "lane_count")) != 1 or
            !try boolean(try required(capability_scope, "single_use")))
        {
            return error.SealedMaterializationInvalid;
        }
        const key_id = try verifyReceiptAttestation(allocator, trial, receipt_value, "materializer") orelse
            return error.SealedMaterializationInvalid;
        defer allocator.free(key_id);
        try requireAttestationKey(key_id, expected_materializer_key_id, error.SealedMaterializationInvalid);
        const capability_domain = try requiredObject(receipt, "capability_domain");
        const controller_identity = try requiredString(capability_domain, "controller_identity");
        const materializer_identity = try requiredString(capability_domain, "materializer_identity");
        const runner_identity = try requiredString(capability_domain, "runner_identity");
        if (std.mem.eql(u8, controller_identity, materializer_identity) or
            std.mem.eql(u8, controller_identity, runner_identity) or
            std.mem.eql(u8, materializer_identity, runner_identity)) return error.SealedSamePrincipalForbidden;
        if (!std.mem.eql(u8, controller_identity, expected_controller_id) or
            !std.mem.eql(u8, materializer_identity, expected_materializer_id) or
            !std.mem.eql(u8, runner_identity, expected_runner_id) or
            !std.mem.eql(u8, try requiredString(capability_domain, "materializer_key_id"), expected_materializer_key_id) or
            !std.mem.eql(u8, try requiredString(capability_domain, "runner_key_id"), expected_runner_key_id) or
            !std.mem.eql(u8, try requiredString(capability_domain, "delivery"), "anonymous_fd") or
            !std.mem.eql(u8, try requiredString(capability_domain, "receiver_binding"), "runner_key") or
            !try boolean(try required(capability_domain, "single_use")) or
            !std.mem.eql(u8, try requiredString(materializer_contract, "capability_delivery"), "anonymous_fd") or
            !std.mem.eql(u8, try requiredString(materializer_contract, "visible_input_delivery"), "anonymous_fd") or
            !std.mem.eql(u8, try requiredString(materializer_contract, "source_profile_delivery"), "anonymous_fd") or
            !std.mem.eql(u8, try requiredString(materializer_contract, "receiver_binding"), "runner_key"))
        {
            return error.SealedMaterializationInvalid;
        }
        const producer = try requiredObject(receipt, "producer");
        if (!std.mem.eql(u8, try requiredString(producer, "id"), expected_materializer_id) or
            !std.mem.eql(u8, try requiredString(producer, "version"), expected_materializer_version) or
            !std.mem.eql(u8, try requiredString(producer, "binary_fingerprint"), expected_materializer_binary) or
            !std.mem.eql(u8, try requiredString(producer, "key_id"), expected_materializer_key_id))
        {
            return error.SealedMaterializationInvalid;
        }
        for (trial.lanes.items) |lane_state| {
            if ((lane_state.runner_key_id != null and try keyIdsSharePublicMaterial(
                allocator,
                trust,
                key_id,
                lane_state.runner_key_id.?,
            )) or
                (lane_state.grade_key_id != null and try keyIdsSharePublicMaterial(
                    allocator,
                    trust,
                    key_id,
                    lane_state.grade_key_id.?,
                )) or
                (lane_state.human_confirmation_key_id != null and
                    try keyIdsSharePublicMaterial(
                        allocator,
                        trust,
                        key_id,
                        lane_state.human_confirmation_key_id.?,
                    )))
            {
                return error.RoleSeparationInvalid;
            }
        }
        for (trial.pairs.items) |pair| {
            if (pair.grader_key_id != null and try keyIdsSharePublicMaterial(
                allocator,
                trust,
                key_id,
                pair.grader_key_id.?,
            )) {
                return error.RoleSeparationInvalid;
            }
        }
    }
}

fn requireAttestationKey(actual: []const u8, expected: []const u8, err: anyerror) !void {
    if (!std.mem.eql(u8, actual, expected)) return err;
}

fn promotionRevealEligible(allocator: std.mem.Allocator, trial: *const TrialState) !bool {
    if (!std.mem.eql(u8, trial.purpose, "promotion")) return true;
    for (trial.lanes.items) |lane| {
        if (lane.status != .completed or !lane.absolute_graded or lane.grade_status == null or
            (!std.mem.eql(u8, lane.grade_status.?, "pass") and
                !std.mem.eql(u8, lane.grade_status.?, "fail")))
        {
            return false;
        }
    }
    if (trial.requires_pair_grade) {
        for (trial.pairs.items) |pair| {
            const receipt_json = pair.pair_grade_receipt_json orelse return false;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt_json, .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            });
            defer parsed.deinit();
            const verdict = try requiredObject(try object(parsed.value), "verdict");
            if (std.mem.eql(u8, try requiredString(verdict, "preferred"), "incomparable")) {
                return false;
            }
        }
    }
    return true;
}

pub fn applyReveal(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
    sequence: u64,
) !void {
    const parts = try requiredBodyPayload(body_value);
    if (try optionalString(parts.body, "scenario_id") != null or
        try optionalString(parts.body, "attempt_id") != null or
        try optionalString(parts.body, "grade_id") != null)
    {
        return error.TrialRevealIdsForbidden;
    }
    const reveal_value = try required(parts.payload, "reveal");
    try validateLimitationsRecursive(reveal_value);
    const reveal = try object(reveal_value);
    if (!std.mem.eql(u8, try requiredString(reveal, "schema"), "hylo-trial-reveal/v1")) {
        return error.RevealInvalid;
    }
    const trial = state.findTrial(try requiredString(reveal, "trial_id")) orelse return error.TrialMissing;
    const reveal_fingerprint = try requiredString(parts.payload, "reveal_fingerprint");
    try validateFingerprint(reveal_fingerprint);
    const actual_reveal_fingerprint = try digestValueAlloc(allocator, reveal_value);
    defer allocator.free(actual_reveal_fingerprint);
    if (!std.mem.eql(u8, reveal_fingerprint, actual_reveal_fingerprint)) return error.RevealFingerprintMismatch;
    if (trial.closed) return error.RevealAfterClose;
    if (trial.revealed) return error.RevealAlreadyRecorded;
    if (!trial.allLanesTerminal()) return error.RevealBeforeTerminal;
    if (!trial.allRequiredGradeCommitmentsPresent()) return error.RevealBeforeGradeCommitments;
    if (!trial.allRequiredGradesPresent()) return error.RevealBeforeGrades;
    if (!try promotionRevealEligible(allocator, trial)) return error.TrialInvalid;
    try validateRoleSeparation(allocator, trial, reveal);
    const mapping_value = try required(reveal, "mapping");
    const mapping = try object(mapping_value);
    const arm0_semantic = try requiredString(mapping, trial.arm0_id);
    const arm1_semantic = try requiredString(mapping, trial.arm1_id);
    if (std.mem.eql(u8, arm0_semantic, arm1_semantic) or
        (!std.mem.eql(u8, arm0_semantic, "baseline") and !std.mem.eql(u8, arm0_semantic, "candidate")) or
        (!std.mem.eql(u8, arm1_semantic, "baseline") and !std.mem.eql(u8, arm1_semantic, "candidate")))
    {
        return error.RevealCommitmentMismatch;
    }
    const nonce = try requiredString(reveal, "nonce");
    try validateRevealNonce(nonce);
    const commitment = try revealCommitmentAlloc(
        allocator,
        trial.id,
        mapping_value,
        nonce,
    );
    defer allocator.free(commitment);
    if (!std.mem.eql(u8, commitment, trial.arm_map_commitment)) return error.RevealCommitmentMismatch;
    const baseline_arm = if (std.mem.eql(u8, arm0_semantic, "baseline")) trial.arm0_id else trial.arm1_id;
    const candidate_arm = if (std.mem.eql(u8, arm0_semantic, "candidate")) trial.arm0_id else trial.arm1_id;
    var trial_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial.trial_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial_parsed.deinit();
    const trial_object = try object(trial_parsed.value);
    if (!std.mem.eql(
        u8,
        try requiredString(reveal, "baseline_target_fingerprint"),
        try requiredString(try armObject(trial_object, baseline_arm), "value_fingerprint"),
    ) or !std.mem.eql(
        u8,
        try requiredString(reveal, "candidate_target_fingerprint"),
        try requiredString(try armObject(trial_object, candidate_arm), "value_fingerprint"),
    )) return error.RevealTargetMismatch;
    const epoch = try requiredObject(trial_object, "target_epoch");
    const factor = try requiredObject(trial_object, "factor");
    if (std.mem.eql(u8, try requiredString(factor, "kind"), "target_snapshot") and
        (!std.mem.eql(
            u8,
            try requiredString(reveal, "baseline_target_fingerprint"),
            try requiredString(epoch, "before_target_fingerprint"),
        ) or !std.mem.eql(
            u8,
            try requiredString(reveal, "candidate_target_fingerprint"),
            try requiredString(epoch, "after_target_fingerprint"),
        )))
    {
        return error.RevealTargetMismatch;
    }
    const expected_change_id = try optionalStringValue(try required(epoch, "change_id"));
    const actual_change_id = try optionalStringValue(try required(reveal, "candidate_change_id"));
    if ((expected_change_id == null) != (actual_change_id == null) or
        (expected_change_id != null and !std.mem.eql(u8, expected_change_id.?, actual_change_id.?)))
    {
        return error.RevealTargetMismatch;
    }
    const sealing = try requiredObject(trial_object, "sealing");
    const reveal_scope = try requiredString(reveal, "revealed_at_scope");
    if (!std.mem.eql(u8, reveal_scope, "trial") and !std.mem.eql(u8, reveal_scope, "campaign_holdout")) {
        return error.RevealScopeInvalid;
    }
    if (!std.mem.eql(u8, reveal_scope, try requiredString(sealing, "reveal_scope"))) {
        return error.RevealScopeInvalid;
    }
    trial.baseline_arm = try allocator.dupe(u8, baseline_arm);
    trial.candidate_arm = try allocator.dupe(u8, candidate_arm);
    trial.reveal_json = try canonicalJsonAlloc(allocator, reveal_value);
    trial.revealed = true;
    trial.reveal_sequence = sequence;
}

/// Closes only the trial lifecycle. Campaign owners must preserve any
/// protected-evidence exposure already caused by accepted trial grades or a
/// reveal; terminal status does not make that evidence unobserved.
pub fn applyClosed(
    allocator: std.mem.Allocator,
    state: *CampaignTrials,
    body_value: std.json.Value,
    sequence: u64,
    result_chain_head: []const u8,
) !void {
    const parts = try requiredBodyPayload(body_value);
    if (try optionalString(parts.body, "scenario_id") != null or
        try optionalString(parts.body, "attempt_id") != null or
        try optionalString(parts.body, "grade_id") != null)
    {
        return error.TrialCloseIdsForbidden;
    }
    const trial = state.findTrial(try requiredString(parts.payload, "trial_id")) orelse return error.TrialMissing;
    if (trial.closed) return error.TrialAlreadyClosed;
    const status = try requiredString(parts.payload, "status");
    if (std.mem.eql(u8, status, "completed")) {
        if (!trial.revealed) return error.TrialIncomplete;
    } else if (!std.mem.eql(u8, status, "invalid") and
        !std.mem.eql(u8, status, "abandoned") and
        !std.mem.eql(u8, status, "superseded"))
    {
        return error.TrialCloseStatusInvalid;
    }
    trial.close_status = try allocator.dupe(u8, status);
    const result_fingerprint = try requiredString(parts.payload, "result_fingerprint");
    try validateFingerprint(result_fingerprint);
    trial.close_result_fingerprint = try allocator.dupe(u8, result_fingerprint);
    trial.close_result_chain_head = try allocator.dupe(u8, result_chain_head);
    trial.closed = true;
    trial.close_sequence = sequence;
}

const GradeOpeningTestNonce = "0000000000000000000000000000000000000000000000000000000000000000";
const GradeOpeningTestProducer =
    "{\"id\":\"grade-opening-test\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"key_id\":\"absolute-grader-key\"}";

const GradeOpeningTestOptions = struct {
    opening_role: []const u8 = "absolute_grader",
    opening_seed_byte: u8 = 0x51,
    opening_nonce: []const u8 = GradeOpeningTestNonce,
    committed_receipt_fingerprint: ?[]const u8 = null,
    receipt_presentation_fingerprint: ?[]const u8 = null,
    opening_commitment_fingerprint: ?[]const u8 = null,
};

const GradeOpeningTestFixture = struct {
    trial_json: []u8,
    commitment_json: []u8,
    commitment_fingerprint: []u8,
    opening_json: []u8,
    presentation_fingerprint: []u8,

    fn deinit(self: *GradeOpeningTestFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.trial_json);
        allocator.free(self.commitment_json);
        allocator.free(self.commitment_fingerprint);
        allocator.free(self.opening_json);
        allocator.free(self.presentation_fingerprint);
    }
};

fn gradeOpeningTestFixtureAlloc(
    allocator: std.mem.Allocator,
    options: GradeOpeningTestOptions,
) !GradeOpeningTestFixture {
    const commitment_seed = [_]u8{0x51} ** 32;
    var opening_seed: [32]u8 = undefined;
    @memset(opening_seed[0..], options.opening_seed_byte);
    const public_key = try retrace_core.hctp_attestation.publicKeyBase64Alloc(allocator, commitment_seed);
    defer allocator.free(public_key);
    const trial_json = try std.fmt.allocPrint(
        allocator,
        "{{\"assurance\":{{\"required_level\":\"sealed\",\"trust_policy\":{{\"keys\":[{{\"key_id\":\"absolute-grader-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"absolute_grader\"],\"producer_ids\":[\"grade-opening-test\"]}}]}}}},\"grading\":{{\"producer_authorities\":[{{\"role\":\"absolute_grader\",\"producer_id\":\"grade-opening-test\",\"producer_version\":\"v1\",\"binary_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"key_id\":\"absolute-grader-key\"}}]}}}}",
        .{std.json.fmt(public_key, .{})},
    );
    errdefer allocator.free(trial_json);

    var presentation = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer presentation.deinit();
    const presentation_fingerprint = try digestValueAlloc(allocator, presentation.value);
    errdefer allocator.free(presentation_fingerprint);
    const receipt_presentation_fingerprint = options.receipt_presentation_fingerprint orelse
        presentation_fingerprint;
    const unsigned_receipt = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-receipt/v1\",\"grade_presentation_receipt_fingerprint\":{f},\"identifier_alias_map_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\",\"producer\":{s},\"value\":\"bound\",\"attestation\":null}}",
        .{ std.json.fmt(receipt_presentation_fingerprint, .{}), GradeOpeningTestProducer },
    );
    defer allocator.free(unsigned_receipt);
    const signed_receipt = try retrace_core.hctp_attestation.signReceiptAlloc(
        allocator,
        unsigned_receipt,
        .{
            .id = "grade-opening-test",
            .version = "v1",
            .binary_fingerprint = "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            .key_id = "absolute-grader-key",
        },
        options.opening_role,
        100,
        opening_seed,
    );
    defer allocator.free(signed_receipt);
    var receipt = try std.json.parseFromSlice(std.json.Value, allocator, signed_receipt, .{});
    defer receipt.deinit();
    const receipt_fingerprint = try digestValueAlloc(allocator, receipt.value);
    defer allocator.free(receipt_fingerprint);
    const committed_receipt_fingerprint = options.committed_receipt_fingerprint orelse receipt_fingerprint;

    const placeholder_commitment = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-commitment/v1\",\"kind\":\"absolute\",\"grader_scope\":{{\"trial_id\":\"opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"lane_ids\":[\"opaque-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"],\"pair_id\":null}},\"grade_presentation_receipt_fingerprint\":{f},\"identifier_alias_map_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\",\"producer\":{s},\"opening_nonce_contract\":{{\"source\":\"getentropy\",\"encoding\":\"lower_hex\",\"bytes\":32,\"single_use\":true}},\"commitment\":{{\"algorithm\":{f},\"domain\":\"HCTP/hylo-grade-commitment/v1\",\"fingerprint\":\"sha256:0000000000000000000000000000000000000000000000000000000000000000\"}},\"attestation\":null}}",
        .{
            std.json.fmt(presentation_fingerprint, .{}),
            GradeOpeningTestProducer,
            std.json.fmt(CanonicalJsonSha256Algorithm, .{}),
        },
    );
    defer allocator.free(placeholder_commitment);
    var placeholder = try std.json.parseFromSlice(std.json.Value, allocator, placeholder_commitment, .{});
    defer placeholder.deinit();
    const commitment_digest = try gradeCommitmentDigestAlloc(
        allocator,
        try object(placeholder.value),
        committed_receipt_fingerprint,
        GradeOpeningTestNonce,
    );
    defer allocator.free(commitment_digest);
    const unsigned_commitment = try std.mem.replaceOwned(
        u8,
        allocator,
        placeholder_commitment,
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        commitment_digest,
    );
    defer allocator.free(unsigned_commitment);
    const commitment_json = try retrace_core.hctp_attestation.signReceiptAlloc(
        allocator,
        unsigned_commitment,
        .{
            .id = "grade-opening-test",
            .version = "v1",
            .binary_fingerprint = "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            .key_id = "absolute-grader-key",
        },
        "absolute_grader",
        100,
        commitment_seed,
    );
    errdefer allocator.free(commitment_json);
    var commitment = try std.json.parseFromSlice(std.json.Value, allocator, commitment_json, .{});
    defer commitment.deinit();
    const commitment_fingerprint = try digestValueAlloc(allocator, commitment.value);
    errdefer allocator.free(commitment_fingerprint);
    const declared_commitment_fingerprint = options.opening_commitment_fingerprint orelse
        commitment_fingerprint;
    const unsigned_opening = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-opening/v1\",\"kind\":\"absolute\",\"grade_commitment_fingerprint\":{f},\"grader_scope\":{{\"trial_id\":\"opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"lane_ids\":[\"opaque-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"],\"pair_id\":null}},\"opening_nonce_hex\":{f},\"grade_receipt_fingerprint\":{f},\"grade_receipt\":{s},\"producer\":{s},\"attestation\":null}}",
        .{
            std.json.fmt(declared_commitment_fingerprint, .{}),
            std.json.fmt(options.opening_nonce, .{}),
            std.json.fmt(receipt_fingerprint, .{}),
            signed_receipt,
            GradeOpeningTestProducer,
        },
    );
    defer allocator.free(unsigned_opening);
    const opening_json = try retrace_core.hctp_attestation.signReceiptAlloc(
        allocator,
        unsigned_opening,
        .{
            .id = "grade-opening-test",
            .version = "v1",
            .binary_fingerprint = "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            .key_id = "absolute-grader-key",
        },
        options.opening_role,
        100,
        opening_seed,
    );
    errdefer allocator.free(opening_json);
    return .{
        .trial_json = trial_json,
        .commitment_json = commitment_json,
        .commitment_fingerprint = commitment_fingerprint,
        .opening_json = opening_json,
        .presentation_fingerprint = presentation_fingerprint,
    };
}

fn gradeOpeningTestTrial(trial_json: []u8) TrialState {
    return .{
        .id = @constCast("trial-grade-opening"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("practice_repair"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = trial_json,
        .requires_pair_grade = false,
        .requires_grade_commitments = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    };
}

test "valid twin trial validates and counts the frozen manifest" {
    var result = try validateTrialAlloc(std.testing.allocator, ValidTrialFixture);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("trial-valid-001", result.trial_id);
    try std.testing.expectEqual(@as(usize, 1), result.unit_count);
    try std.testing.expectEqual(@as(usize, 2), result.pair_count);
    try std.testing.expectEqual(@as(usize, 4), result.lane_count);
    try validateFingerprint(result.fingerprint);
}

test "trial identity requires the selected canonical JSON profile" {
    const missing = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "  \"canonical_json_profile\": \"hylo-canonical-json/v1\",\n",
        "",
    );
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(
        error.CanonicalJsonProfileMissing,
        validateTrialAlloc(std.testing.allocator, missing),
    );

    const mismatched = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        CanonicalJsonProfile,
        "other-canonical-json/v1",
    );
    defer std.testing.allocator.free(mismatched);
    try std.testing.expectError(
        error.CanonicalJsonProfileMismatch,
        validateTrialAlloc(std.testing.allocator, mismatched),
    );

    const legacy_algorithm = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        CanonicalJsonSha256Algorithm,
        "sha256-canonical-json",
    );
    defer std.testing.allocator.free(legacy_algorithm);
    try std.testing.expectError(
        error.ArmCommitmentAlgorithmInvalid,
        validateTrialAlloc(std.testing.allocator, legacy_algorithm),
    );
}

test "sealed grade openings reject authority and commitment binding mutations" {
    var valid = try gradeOpeningTestFixtureAlloc(std.testing.allocator, .{});
    defer valid.deinit(std.testing.allocator);
    const valid_trial = gradeOpeningTestTrial(valid.trial_json);
    var valid_opening = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid.opening_json, .{});
    defer valid_opening.deinit();
    const validated = try validateGradeOpening(
        std.testing.allocator,
        &valid_trial,
        valid.commitment_json,
        valid.commitment_fingerprint,
        "absolute-grader-key",
        valid_opening.value,
        "absolute",
    );
    try std.testing.expectEqualStrings(valid.presentation_fingerprint, validated.presentation_fingerprint);

    const cases = [_]struct {
        options: GradeOpeningTestOptions = .{},
        commitment_key_id: []const u8 = "absolute-grader-key",
        expected_error: anyerror,
    }{
        .{
            .options = .{ .opening_role = "pair_grader" },
            .expected_error = error.AttestationInvalid,
        },
        .{
            .options = .{ .opening_seed_byte = 0x52 },
            .expected_error = error.AttestationSignatureInvalid,
        },
        .{
            .commitment_key_id = "other-grader-key",
            .expected_error = error.GradeOpeningAuthorityMismatch,
        },
        .{
            .options = .{ .opening_nonce = "1111111111111111111111111111111111111111111111111111111111111111" },
            .expected_error = error.GradeOpeningCommitmentMismatch,
        },
        .{
            .options = .{ .committed_receipt_fingerprint = "sha256:3333333333333333333333333333333333333333333333333333333333333333" },
            .expected_error = error.GradeOpeningCommitmentMismatch,
        },
        .{
            .options = .{ .receipt_presentation_fingerprint = "sha256:4444444444444444444444444444444444444444444444444444444444444444" },
            .expected_error = error.GradeOpeningPresentationMismatch,
        },
        .{
            .options = .{ .opening_commitment_fingerprint = "sha256:5555555555555555555555555555555555555555555555555555555555555555" },
            .expected_error = error.GradeOpeningCommitmentMismatch,
        },
    };
    for (cases) |case| {
        var fixture = try gradeOpeningTestFixtureAlloc(std.testing.allocator, case.options);
        defer fixture.deinit(std.testing.allocator);
        const trial = gradeOpeningTestTrial(fixture.trial_json);
        var opening = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture.opening_json, .{});
        defer opening.deinit();
        if (validateGradeOpening(
            std.testing.allocator,
            &trial,
            fixture.commitment_json,
            fixture.commitment_fingerprint,
            case.commitment_key_id,
            opening.value,
            "absolute",
        )) |_| {
            return error.TestExpectedGradeOpeningRejection;
        } else |actual_error| {
            try std.testing.expectEqual(case.expected_error, actual_error);
        }
    }
}

test "sealed grade opening coverage rejects duplicate and extra openings" {
    var fixture = try gradeOpeningTestFixtureAlloc(std.testing.allocator, .{});
    defer fixture.deinit(std.testing.allocator);
    var state = CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try state.trials.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "trial-grade-opening"),
        .fingerprint = try std.testing.allocator.dupe(u8, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = try std.testing.allocator.dupe(u8, "practice_repair"),
        .arm0_id = try std.testing.allocator.dupe(u8, "arm-0"),
        .arm1_id = try std.testing.allocator.dupe(u8, "arm-1"),
        .arm_map_commitment = try std.testing.allocator.dupe(u8, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = try std.testing.allocator.dupe(u8, fixture.trial_json),
        .requires_pair_grade = false,
        .requires_grade_commitments = true,
        .registration_sequence = 1,
        .registration_event_digest = try std.testing.allocator.dupe(u8, "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    });
    const trial = &state.trials.items[0];
    try trial.lanes.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "lane-opening-a"),
        .unit_id = try std.testing.allocator.dupe(u8, "unit-opening"),
        .scenario_id = try std.testing.allocator.dupe(u8, "scenario-opening-a"),
        .pair_id = try std.testing.allocator.dupe(u8, "pair-opening"),
        .arm_id = try std.testing.allocator.dupe(u8, "arm-0"),
        .status = .completed,
        .grade_commitment_fingerprint = try std.testing.allocator.dupe(u8, fixture.commitment_fingerprint),
        .grade_commitment_json = try std.testing.allocator.dupe(u8, fixture.commitment_json),
        .grade_commitment_key_id = try std.testing.allocator.dupe(u8, "absolute-grader-key"),
        .grade_commitment_grade_id = try std.testing.allocator.dupe(u8, "grade-opening-a"),
    });
    try trial.lanes.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "lane-opening-b"),
        .unit_id = try std.testing.allocator.dupe(u8, "unit-opening"),
        .scenario_id = try std.testing.allocator.dupe(u8, "scenario-opening-b"),
        .pair_id = try std.testing.allocator.dupe(u8, "pair-opening"),
        .arm_id = try std.testing.allocator.dupe(u8, "arm-1"),
        .status = .completed,
        .grade_commitment_fingerprint = try std.testing.allocator.dupe(u8, "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
        .grade_commitment_json = try std.testing.allocator.dupe(u8, fixture.commitment_json),
        .grade_commitment_key_id = try std.testing.allocator.dupe(u8, "absolute-grader-key"),
        .grade_commitment_grade_id = try std.testing.allocator.dupe(u8, "grade-opening-b"),
    });
    const duplicate_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"grade_openings\":[{s},{s}],\"grade_presentation_evidence\":[{{\"grade_presentation_receipt_ref\":\"artifact:valid\",\"grade_presentation_receipt_fingerprint\":{f},\"grade_presentation_receipt\":{{}}}},{{\"grade_presentation_receipt_ref\":\"artifact:unused\",\"grade_presentation_receipt_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"grade_presentation_receipt\":{{\"unused\":true}}}}]}}",
        .{ fixture.opening_json, fixture.opening_json, std.json.fmt(fixture.presentation_fingerprint, .{}) },
    );
    defer std.testing.allocator.free(duplicate_json);
    var duplicate = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, duplicate_json, .{});
    defer duplicate.deinit();
    try std.testing.expectError(
        error.GradeOpeningCoverageMismatch,
        gradeOpeningBodiesAlloc(std.testing.allocator, trial, try object(duplicate.value)),
    );

    const extra_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"grade_openings\":[{s},{s},{s}],\"grade_presentation_evidence\":[{{}},{{}}]}}",
        .{ fixture.opening_json, fixture.opening_json, fixture.opening_json },
    );
    defer std.testing.allocator.free(extra_json);
    var extra = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, extra_json, .{});
    defer extra.deinit();
    try std.testing.expectError(
        error.GradeOpeningCoverageMismatch,
        gradeOpeningBodiesAlloc(std.testing.allocator, trial, try object(extra.value)),
    );
}

test "grade opening rollback clears an earlier opened grade and preserves its commitment" {
    var state = CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try state.trials.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "trial-opening-rollback"),
        .fingerprint = try std.testing.allocator.dupe(u8, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = try std.testing.allocator.dupe(u8, "practice_repair"),
        .arm0_id = try std.testing.allocator.dupe(u8, "arm-0"),
        .arm1_id = try std.testing.allocator.dupe(u8, "arm-1"),
        .arm_map_commitment = try std.testing.allocator.dupe(u8, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = try std.testing.allocator.dupe(u8, "{}"),
        .requires_pair_grade = false,
        .requires_grade_commitments = true,
        .registration_sequence = 1,
        .registration_event_digest = try std.testing.allocator.dupe(u8, "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    });
    const trial = &state.trials.items[0];
    try trial.lanes.append(std.testing.allocator, .{
        .id = try std.testing.allocator.dupe(u8, "lane-opening-rollback"),
        .unit_id = try std.testing.allocator.dupe(u8, "unit-opening-rollback"),
        .scenario_id = try std.testing.allocator.dupe(u8, "scenario-opening-rollback"),
        .pair_id = try std.testing.allocator.dupe(u8, "pair-opening-rollback"),
        .arm_id = try std.testing.allocator.dupe(u8, "arm-0"),
        .status = .completed,
        .grade_commitment_fingerprint = try std.testing.allocator.dupe(u8, "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
        .grade_commitment_json = try std.testing.allocator.dupe(u8, "{\"schema\":\"hylo-grade-commitment/v1\"}"),
        .grade_commitment_key_id = try std.testing.allocator.dupe(u8, "absolute-grader-key"),
        .grade_commitment_grade_id = try std.testing.allocator.dupe(u8, "grade-opening-rollback"),
    });
    const RejectLaterOpening = struct {
        fn apply(allocator: std.mem.Allocator, target: *TrialState) !void {
            errdefer clearOpenedGrades(allocator, target);
            const lane = &target.lanes.items[0];
            lane.absolute_graded = true;
            lane.grade_id = try allocator.dupe(u8, "grade-opened-first");
            lane.grade_status = try allocator.dupe(u8, "pass");
            lane.aggregate = 1;
            lane.critical_failure_count = 0;
            lane.grade_receipt_json = try allocator.dupe(u8, "{\"schema\":\"hylo-grade-receipt/v1\"}");
            lane.grade_key_id = try allocator.dupe(u8, "absolute-grader-key");
            lane.grade_presenter_key_id = try allocator.dupe(u8, "materializer-key");
            lane.grade_presentation_capability_digest = try allocator.dupe(u8, "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
            lane.grade_presentation_receipt_json = try allocator.dupe(u8, "{\"schema\":\"hylo-grade-presentation-receipt/v1\"}");
            return error.GradeOpeningInvalid;
        }
    };
    try std.testing.expectError(
        error.GradeOpeningInvalid,
        RejectLaterOpening.apply(std.testing.allocator, trial),
    );
    const lane = &trial.lanes.items[0];
    try std.testing.expect(!lane.absolute_graded);
    try std.testing.expect(lane.grade_id == null);
    try std.testing.expect(lane.grade_status == null);
    try std.testing.expect(lane.aggregate == null);
    try std.testing.expect(lane.critical_failure_count == null);
    try std.testing.expect(lane.grade_receipt_json == null);
    try std.testing.expect(lane.grade_key_id == null);
    try std.testing.expect(lane.grade_presenter_key_id == null);
    try std.testing.expect(lane.grade_presentation_capability_digest == null);
    try std.testing.expect(lane.grade_presentation_receipt_json == null);
    try std.testing.expectEqualStrings(
        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        lane.grade_commitment_fingerprint.?,
    );
    try std.testing.expectEqualStrings("absolute-grader-key", lane.grade_commitment_key_id.?);
    try std.testing.expectEqualStrings("grade-opening-rollback", lane.grade_commitment_grade_id.?);
}

test "opaque arm identifiers reject semantic and date hints" {
    const semantic = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "arm-0",
        "candidate",
    );
    defer std.testing.allocator.free(semantic);
    try std.testing.expectError(
        error.ArmCommitmentInvalid,
        validateTrialAlloc(std.testing.allocator, semantic),
    );

    const dated = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "arm-0",
        "arm-20260712",
    );
    defer std.testing.allocator.free(dated);
    try std.testing.expectError(
        error.ArmCommitmentInvalid,
        validateTrialAlloc(std.testing.allocator, dated),
    );
}

test "grader-visible lane identifiers reject semantic arm hints" {
    inline for (.{ "lane-baseline", "lane-candidate", "lane-old", "lane-new", "lane-fixed", "lane-20260712", "lane-arm-0" }) |semantic_lane| {
        const trial = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            ValidTrialFixture,
            "lane-001-r1-a0",
            semantic_lane,
        );
        defer std.testing.allocator.free(trial);
        try std.testing.expectError(
            error.GraderVisibleIdentifierInvalid,
            validateTrialAlloc(std.testing.allocator, trial),
        );
    }

    const pid_like = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "lane-001-r1-a0",
        "lane-x-202607-good",
    );
    defer std.testing.allocator.free(pid_like);
    var pid_like_result = try validateTrialAlloc(std.testing.allocator, pid_like);
    defer pid_like_result.deinit(std.testing.allocator);
}

test "judge contracts bind the exact registered contract bytes" {
    const mutable_contract = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidNullTrialFixture,
        "\"prompt_template\": \"blind-pair-v1\"",
        "\"prompt_template\": \"changed-after-calibration\"",
    );
    defer std.testing.allocator.free(mutable_contract);
    try std.testing.expectError(
        error.JudgeContractInvalid,
        validateTrialAlloc(std.testing.allocator, mutable_contract),
    );
}

test "purpose-factor matrix rejects target snapshots in mechanism probes" {
    const trial = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "\"purpose\": \"practice_repair\"",
        "\"purpose\": \"mechanism_probe\"",
    );
    defer std.testing.allocator.free(trial);
    try std.testing.expectError(
        error.TrialFactorInvalid,
        validateTrialAlloc(std.testing.allocator, trial),
    );
}

test "trial validation requires exact metric and lane manifests" {
    const missing_metric = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "\"primary_dimensions\": [\"correctness\"]",
        "\"primary_dimensions\": [\"correctness\", \"route_quality\"]",
    );
    defer std.testing.allocator.free(missing_metric);
    try std.testing.expectError(
        error.MetricPolicyMissing,
        validateTrialAlloc(std.testing.allocator, missing_metric),
    );

    const extra_lane = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "\"arm-1\": {\"lane_id\": \"lane-001-r1-a1\"}",
        "\"arm-1\": {\"lane_id\": \"lane-001-r1-a1\"}, \"shadow\": {\"lane_id\": \"lane-shadow\"}",
    );
    defer std.testing.allocator.free(extra_lane);
    try std.testing.expectError(
        error.PairShapeInvalid,
        validateTrialAlloc(std.testing.allocator, extra_lane),
    );
}

test "fixed allocation still enforces registered position balance" {
    const fixed = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "\"method\": \"balanced_ab_ba\"",
        "\"method\": \"fixed\"",
    );
    defer std.testing.allocator.free(fixed);
    const unbalanced = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixed,
        "\"order\": [\"arm-1\", \"arm-0\"]",
        "\"order\": [\"arm-0\", \"arm-1\"]",
    );
    defer std.testing.allocator.free(unbalanced);
    try std.testing.expectError(
        error.PairOrderInvalid,
        validateTrialAlloc(std.testing.allocator, unbalanced),
    );
}

test "reveal nonces carry a canonical 128-bit hiding suffix" {
    try validateRevealNonce("nonce-prefix-00112233445566778899aabbccddeeff");
    try std.testing.expectError(error.RevealNonceEntropyInvalid, validateRevealNonce("short-nonce"));
    try std.testing.expectError(
        error.RevealNonceEntropyInvalid,
        validateRevealNonce("nonce-prefix-00112233445566778899aabbccddeggh"),
    );
}

test "sealed materialization attestations use the contract-committed key" {
    try requireAttestationKey("materializer-key", "materializer-key", error.SealedMaterializationInvalid);
    try std.testing.expectError(
        error.SealedMaterializationInvalid,
        requireAttestationKey("alternate-key", "materializer-key", error.SealedMaterializationInvalid),
    );
}

test "unsupported distinct-role claims fail closed at registration" {
    const trial = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "\"required_distinct_roles\": []",
        "\"required_distinct_roles\": [\"runner\", \"oracle\"]",
    );
    defer std.testing.allocator.free(trial);
    try std.testing.expectError(
        error.RoleSeparationInvalid,
        validateTrialAlloc(std.testing.allocator, trial),
    );
}

test "required distinct roles compare decoded Ed25519 public-key material" {
    const shared_seed = [_]u8{0x31} ** 32;
    const distinct_seed = [_]u8{0x32} ** 32;
    const shared_public = try retrace_core.hctp_attestation.publicKeyBase64Alloc(
        std.testing.allocator,
        shared_seed,
    );
    defer std.testing.allocator.free(shared_public);
    const distinct_public = try retrace_core.hctp_attestation.publicKeyBase64Alloc(
        std.testing.allocator,
        distinct_seed,
    );
    defer std.testing.allocator.free(distinct_public);
    var required_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[\"runner\",\"absolute_grader\"]",
        .{},
    );
    defer required_value.deinit();
    const required_roles = try array(required_value.value);

    const aliased_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"keys\":[{{\"key_id\":\"runner-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"]}},{{\"key_id\":\"grader-alias\",\"public_key_base64\":{f},\"allowed_roles\":[\"absolute_grader\"]}}]}}",
        .{ std.json.fmt(shared_public, .{}), std.json.fmt(shared_public, .{}) },
    );
    defer std.testing.allocator.free(aliased_text);
    var aliased = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aliased_text, .{});
    defer aliased.deinit();
    try std.testing.expectError(
        error.RoleSeparationInvalid,
        validateRequiredRoleKeyMaterial(
            std.testing.allocator,
            try object(aliased.value),
            required_roles,
        ),
    );

    const distinct_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"keys\":[{{\"key_id\":\"runner-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"]}},{{\"key_id\":\"grader-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"absolute_grader\"]}}]}}",
        .{ std.json.fmt(shared_public, .{}), std.json.fmt(distinct_public, .{}) },
    );
    defer std.testing.allocator.free(distinct_text);
    var distinct = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, distinct_text, .{});
    defer distinct.deinit();
    try validateRequiredRoleKeyMaterial(
        std.testing.allocator,
        try object(distinct.value),
        required_roles,
    );

    const source_owner_alias_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"keys\":[{{\"key_id\":\"source-owner\",\"public_key_base64\":{f},\"allowed_roles\":[\"source_owner\"]}},{{\"key_id\":\"runner-alias\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"]}}]}}",
        .{ std.json.fmt(shared_public, .{}), std.json.fmt(shared_public, .{}) },
    );
    defer std.testing.allocator.free(source_owner_alias_text);
    var source_owner_alias = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        source_owner_alias_text,
        .{},
    );
    defer source_owner_alias.deinit();
    try std.testing.expectError(
        error.TrustPolicyInvalid,
        validateRequiredRoleKeyMaterial(
            std.testing.allocator,
            try object(source_owner_alias.value),
            required_roles,
        ),
    );
}

test "signed blind grade identities bind to presentation aliases" {
    const fp_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const fp_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const trial = TrialState{
        .id = @constCast("trial-registered"),
        .fingerprint = @constCast(fp_a),
        .purpose = @constCast("practice_repair"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast(fp_b),
        .trial_json = @constCast("{}"),
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast(fp_a),
    };
    var absolute_presentation = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"identifier_aliases\":{\"trial_id\":\"opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"unit_id\":\"opaque-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"pair_ids\":[],\"lane_ids\":[\"opaque-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"],\"opaque_arm_id\":\"opaque-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"identifier_alias_map_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grader_presentation_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}",
        .{},
    );
    defer absolute_presentation.deinit();
    const absolute_aliases = try gradeIdentifierAliasEvidence(try object(absolute_presentation.value), true);
    var absolute_receipt = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"trial_id\":\"opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"lane_id\":\"opaque-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"opaque_arm_id\":\"opaque-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"identifier_alias_map_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grade_presentation_receipt_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}",
        .{},
    );
    defer absolute_receipt.deinit();
    try validateBlindEvaluation(
        std.testing.allocator,
        &trial,
        try object(absolute_receipt.value),
        absolute_aliases,
        fp_b,
        true,
    );
    var registered_identity = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"trial_id\":\"opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"lane_id\":\"lane-registered\",\"opaque_arm_id\":\"opaque-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"identifier_alias_map_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grade_presentation_receipt_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}",
        .{},
    );
    defer registered_identity.deinit();
    try std.testing.expectError(
        error.GradePresentationInvalid,
        validateBlindEvaluation(
            std.testing.allocator,
            &trial,
            try object(registered_identity.value),
            absolute_aliases,
            fp_b,
            true,
        ),
    );

    var pair_presentation = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"identifier_aliases\":{\"trial_id\":\"opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"unit_id\":\"opaque-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"pair_ids\":[\"opaque-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"],\"lane_ids\":[\"opaque-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"opaque-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"],\"opaque_arm_id\":null},\"identifier_alias_map_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grader_presentation_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}",
        .{},
    );
    defer pair_presentation.deinit();
    const pair_aliases = try gradeIdentifierAliasEvidence(try object(pair_presentation.value), false);
    var pair_receipt = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"trial_id\":\"opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"pair_id\":\"opaque-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"lane_ids\":[\"opaque-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"opaque-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"],\"presentation\":{\"left_lane_id\":\"opaque-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"right_lane_id\":\"opaque-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"},\"identifier_alias_map_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grade_presentation_receipt_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}",
        .{},
    );
    defer pair_receipt.deinit();
    try validateBlindEvaluation(
        std.testing.allocator,
        &trial,
        try object(pair_receipt.value),
        pair_aliases,
        fp_b,
        false,
    );
}

test "sealed grade semantic observations bind the exact registered carriers" {
    var presentation_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"semantic_observation\":{\"schema\":\"hylo-grade-semantic-observation-receipt/v1\",\"observation_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"output_fingerprints\":[\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"],\"output_byte_counts\":[42],\"trace_fingerprints\":[\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"],\"trace_byte_counts\":[17],\"carrier_encoding\":\"base64\",\"semantic_bytes_presented\":true}}",
        .{},
    );
    defer presentation_value.deinit();
    var grade_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"semantic_observation_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
        .{},
    );
    defer grade_value.deinit();
    try validateGradeSemanticObservation(
        try object(presentation_value.value),
        try object(grade_value.value),
        &.{"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
        &.{"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
    );
    var grade = try object(grade_value.value);
    try grade.put(
        grade_value.arena.allocator(),
        "semantic_observation_fingerprint",
        .{ .string = @constCast("sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd") },
    );
    try std.testing.expectError(
        error.GradePresentationInvalid,
        validateGradeSemanticObservation(
            try object(presentation_value.value),
            grade,
            &.{"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
            &.{"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
        ),
    );

    var zero_count_presentation = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"semantic_observation\":{\"schema\":\"hylo-grade-semantic-observation-receipt/v1\",\"observation_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"output_fingerprints\":[\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"],\"output_byte_counts\":[0],\"trace_fingerprints\":[\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"],\"trace_byte_counts\":[17],\"carrier_encoding\":\"base64\",\"semantic_bytes_presented\":true}}",
        .{},
    );
    defer zero_count_presentation.deinit();
    try grade.put(
        grade_value.arena.allocator(),
        "semantic_observation_fingerprint",
        .{ .string = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") },
    );
    try std.testing.expectError(
        error.GradePresentationInvalid,
        validateGradeSemanticObservation(
            try object(zero_count_presentation.value),
            grade,
            &.{"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
            &.{"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
        ),
    );
    const zero_count_observation = try testObjectPtr(
        (try testObjectPtr(&zero_count_presentation.value)).getPtr("semantic_observation") orelse
            return error.TestFixtureInvalid,
    );
    const zero_output_counts = zero_count_observation.getPtr("output_byte_counts") orelse
        return error.TestFixtureInvalid;
    if (zero_output_counts.* != .array) return error.TestFixtureInvalid;
    zero_output_counts.array.items[0] = .{ .integer = -1 };
    try std.testing.expectError(
        error.GradePresentationInvalid,
        validateGradeSemanticObservation(
            try object(zero_count_presentation.value),
            grade,
            &.{"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
            &.{"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
        ),
    );
}

test "sealed pair position commitments hide the registered execution order" {
    const nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const forward = try pairGradePositionMapCommitmentAlloc(
        std.testing.allocator,
        "opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "opaque-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        nonce,
    );
    defer std.testing.allocator.free(forward);
    const repeated = try pairGradePositionMapCommitmentAlloc(
        std.testing.allocator,
        "opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "opaque-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        nonce,
    );
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(forward, repeated);
    const reversed = try pairGradePositionMapCommitmentAlloc(
        std.testing.allocator,
        "opaque-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        nonce,
    );
    defer std.testing.allocator.free(reversed);
    try std.testing.expect(!std.mem.eql(u8, forward, reversed));
    try std.testing.expectError(
        error.GradePresentationInvalid,
        pairGradePositionMapCommitmentAlloc(
            std.testing.allocator,
            "opaque-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "opaque-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "short",
        ),
    );
}

test "human confirmations cannot be self-asserted at precommitted assurance" {
    const lane = LaneState{
        .id = @constCast("lane-human"),
        .unit_id = @constCast("unit-human"),
        .scenario_id = @constCast("scenario-human"),
        .pair_id = @constCast("pair-human"),
        .arm_id = @constCast("arm-0"),
    };
    const trial = TrialState{
        .id = @constCast("trial-human"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("practice_repair"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = @constCast("{\"assurance\":{\"required_level\":\"precommitted\"}}"),
        .requires_pair_grade = false,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    };
    var valid = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"human_confirmation_receipt\":{\"schema\":\"hylo-human-confirmation-receipt/v1\",\"trial_id\":\"trial-human\",\"lane_id\":\"lane-human\",\"confirmed\":true}}",
        .{},
    );
    defer valid.deinit();
    try std.testing.expectError(
        error.TrustPolicyMissing,
        validateHumanConfirmation(
            std.testing.allocator,
            &trial,
            &lane,
            try object(valid.value),
        ),
    );
    var empty_confirmation_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{}",
        .{},
    );
    defer empty_confirmation_value.deinit();
    try std.testing.expectError(
        error.HumanConfirmationMissing,
        validateHumanConfirmation(
            std.testing.allocator,
            &trial,
            &lane,
            try object(empty_confirmation_value.value),
        ),
    );
}

test "human confirmations accept only a trusted human confirmer signature" {
    const seed = [_]u8{0x41} ** 32;
    const public_key = try retrace_core.hctp_attestation.publicKeyBase64Alloc(std.testing.allocator, seed);
    defer std.testing.allocator.free(public_key);
    const unsigned =
        "{\"schema\":\"hylo-human-confirmation-receipt/v1\",\"trial_id\":\"trial-human-signed\",\"lane_id\":\"lane-human-signed\",\"confirmed\":true,\"producer\":{\"id\":\"human-reviewer\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"key_id\":\"human-key\"},\"attestation\":null}";
    const signed = try retrace_core.hctp_attestation.signReceiptAlloc(
        std.testing.allocator,
        unsigned,
        .{
            .id = "human-reviewer",
            .version = "v1",
            .binary_fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .key_id = "human-key",
        },
        "human_confirmer",
        1,
        seed,
    );
    defer std.testing.allocator.free(signed);
    const trial_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"assurance\":{{\"required_level\":\"precommitted\",\"trust_policy\":{{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"human-policy\",\"keys\":[{{\"key_id\":\"human-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"human_confirmer\"],\"producer_ids\":[\"human-reviewer\"]}}],\"separation\":{{\"runner_and_pair_grader_distinct\":true,\"materializer_and_pair_grader_distinct\":true,\"human_confirmation_required_for_human_grade\":true}}}}}}}}",
        .{std.json.fmt(public_key, .{})},
    );
    defer std.testing.allocator.free(trial_json);
    const lane = LaneState{
        .id = @constCast("lane-human-signed"),
        .unit_id = @constCast("unit-human"),
        .scenario_id = @constCast("scenario-human"),
        .pair_id = @constCast("pair-human"),
        .arm_id = @constCast("arm-x"),
    };
    const trial = TrialState{
        .id = @constCast("trial-human-signed"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("practice_repair"),
        .arm0_id = @constCast("arm-x"),
        .arm1_id = @constCast("arm-y"),
        .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = trial_json,
        .requires_pair_grade = false,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    };
    const grade_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"human_confirmation_receipt\":{s}}}",
        .{signed},
    );
    defer std.testing.allocator.free(grade_text);
    var grade = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, grade_text, .{});
    defer grade.deinit();
    const key_id = (try validateHumanConfirmation(
        std.testing.allocator,
        &trial,
        &lane,
        try object(grade.value),
    )).?;
    defer std.testing.allocator.free(key_id);
    try std.testing.expectEqualStrings("human-key", key_id);
}

test "nested FIR portfolio markers are rejected at the Ledger boundary" {
    var wrapped = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"fork_inquiry_receipt\":{\"portfolio\":[]}}",
        .{},
    );
    defer wrapped.deinit();
    const root = try object(wrapped.value);
    const fir = try requiredObject(root, "fork_inquiry_receipt");
    try std.testing.expectError(error.HiddenRetryOrFork, rejectForkPortfolio(fir));
}

test "historical-decision lanes reject a signed non-FIR native receipt before adapter dispatch" {
    const seed = [_]u8{0x52} ** 32;
    const public_key = try retrace_core.hctp_attestation.publicKeyBase64Alloc(
        std.testing.allocator,
        seed,
    );
    defer std.testing.allocator.free(public_key);
    const historical_trial = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidNullTrialFixture,
        "\"source_profile\": {\"kind\": \"direct\"}",
        "\"source_profile\": {\"kind\": \"historical_decision\"}",
    );
    defer std.testing.allocator.free(historical_trial);
    const assurance = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"required_level\": \"receipt_bound\"," ++
            "\n    \"trust_policy_ref\": \"artifact:trust-policy\"," ++
            "\n    \"trust_policy_fingerprint\": \"sha256:7777777777777777777777777777777777777777777777777777777777777777\"," ++
            "\n    \"trust_policy\": {{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"historical-runner-policy\",\"keys\":[{{\"key_id\":\"runner-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"cas-trial\"]}}],\"separation\":{{\"runner_and_pair_grader_distinct\":true,\"materializer_and_pair_grader_distinct\":true,\"human_confirmation_required_for_human_grade\":true}}}},",
        .{std.json.fmt(public_key, .{})},
    );
    defer std.testing.allocator.free(assurance);
    const bound_trial = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        historical_trial,
        "\"required_level\": \"precommitted\",\n    \"trust_policy_ref\": \"artifact:trust-policy\",\n    \"trust_policy_fingerprint\": \"sha256:7777777777777777777777777777777777777777777777777777777777777777\",",
        assurance,
    );
    defer std.testing.allocator.free(bound_trial);

    const lane = LaneState{
        .id = @constCast("lane-null-a0"),
        .unit_id = @constCast("unit-null-001"),
        .scenario_id = @constCast("scenario-holdout"),
        .pair_id = @constCast("pair-null-001"),
        .arm_id = @constCast("arm-0"),
        .status = .started,
        .lease_digest = @constCast("sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
        .runner_id = @constCast("cas-trial"),
        .presented_input_fingerprint = @constCast("sha256:3dbc2a117751f42078d15a82dab707eef4ac2c2b19a8addd9286a873fa6ffb65"),
        .started_event_digest = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
    };
    const trial = TrialState{
        .id = @constCast("trial-null-001"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("calibration_null"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:12a363c4474b3da444d517dceed738aefc7c0dfd552d76209a3c3e65d1da0c4d"),
        .trial_json = bound_trial,
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    };
    const signed = try retrace_core.hctp_attestation.signReceiptAlloc(
        std.testing.allocator,
        ValidRunReceiptFixture,
        .{
            .id = "cas-trial",
            .version = "0.2.76",
            .binary_fingerprint = "sha256:3333333333333333333333333333333333333333333333333333333333333333",
            .key_id = "runner-key",
        },
        "runner",
        1,
        seed,
    );
    defer std.testing.allocator.free(signed);
    var receipt = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        signed,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer receipt.deinit();
    const verified_key = (try verifyReceiptAttestation(
        std.testing.allocator,
        &trial,
        receipt.value,
        "runner",
    )).?;
    defer std.testing.allocator.free(verified_key);
    try std.testing.expectEqualStrings("runner-key", verified_key);
    try std.testing.expectError(
        error.RetraceFirInvalid,
        validateRunReceipt(std.testing.allocator, &trial, &lane, receipt.value),
    );
}

test "historical-decision terminal failures preserve lineage without claiming FIR completion" {
    const historical_profile =
        "\"source_profile\": {\"kind\":\"historical_decision\",\"source_governance_ref\":\"artifact:sgg\",\"source_governance_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"decision_context_ref\":\"artifact:dcp\",\"decision_context_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\",\"temporal_horizon\":\"pre_decision\",\"source_target_text_policy\":\"strip_and_replace\",\"retrace_mode\":\"replay\",\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\",\"reconstructability\":\"transcript_only\",\"limitations\":[]}";
    const historical_trial = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidNullTrialFixture,
        "\"source_profile\": {\"kind\": \"direct\"}",
        historical_profile,
    );
    defer std.testing.allocator.free(historical_trial);
    const lane = LaneState{
        .id = @constCast("lane-null-a0"),
        .unit_id = @constCast("unit-null-001"),
        .scenario_id = @constCast("scenario-holdout"),
        .pair_id = @constCast("pair-null-001"),
        .arm_id = @constCast("arm-0"),
        .status = .started,
        .lease_digest = @constCast("sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
        .runner_id = @constCast("cas-trial"),
        .presented_input_fingerprint = @constCast("sha256:3dbc2a117751f42078d15a82dab707eef4ac2c2b19a8addd9286a873fa6ffb65"),
        .started_event_digest = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
    };
    const trial = TrialState{
        .id = @constCast("trial-null-001"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("calibration_null"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:12a363c4474b3da444d517dceed738aefc7c0dfd552d76209a3c3e65d1da0c4d"),
        .trial_json = historical_trial,
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    };

    inline for (.{ "failed", "blocked", "aborted", "invalid" }) |status| {
        var run = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            ValidRunReceiptFixture,
            .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
        );
        defer run.deinit();
        const run_allocator = run.arena.allocator();
        const run_root = try testObjectPtr(&run.value);
        const terminal = try testObjectPtr(run_root.getPtr("terminal") orelse return error.TestFixtureInvalid);
        try terminal.put(run_allocator, "status", .{ .string = @constCast(status) });
        try terminal.put(run_allocator, "failure_class", .{ .string = @constCast("executor_failure") });
        try terminal.put(run_allocator, "failure_detail_ref", .{ .string = @constCast("artifact:execution-audit") });
        const evidence = try testObjectPtr(run_root.getPtr("evidence") orelse return error.TestFixtureInvalid);
        inline for (.{ "output_ref", "output_fingerprint", "trace_ref", "trace_fingerprint" }) |key| {
            try evidence.put(run_allocator, key, .null);
        }
        const native_text = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema\":\"cas-historical-terminal-receipt/v1\",\"trial_id\":\"trial-null-001\",\"lane_id\":\"lane-null-a0\",\"terminal_status\":{f},\"claim\":{{\"claim_id\":\"lane-null-a0\",\"atomic\":true,\"claimed_before_execution\":true,\"claim_count\":1,\"lane_lease_digest\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"}},\"source\":{{\"source_governance_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"decision_context_ref\":\"artifact:dcp\",\"decision_context_fingerprint\":\"sha256:2222222222222222222222222222222222222222222222222222222222222222\",\"temporal_horizon\":\"pre_decision\",\"source_target_text_policy\":\"strip_and_replace\",\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\"}},\"execution\":{{\"executor\":\"cas-executor\",\"executor_binary_fingerprint\":\"sha256:3333333333333333333333333333333333333333333333333333333333333333\",\"execution_audit_ref\":\"artifact:execution-audit\",\"execution_audit_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\",\"handle_count\":1,\"retry_count\":0,\"hidden_fork_count\":0,\"internal_execution_verified\":false}},\"fir\":{{\"status\":\"unavailable\",\"receipt_ref\":null,\"receipt_fingerprint\":null,\"reason\":\"executor_failure\"}},\"runner_contract_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\"}}",
            .{std.json.fmt(status, .{})},
        );
        defer std.testing.allocator.free(native_text);
        var native_value = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            native_text,
            .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
        );
        defer native_value.deinit();
        const native = try testObjectPtr(run_root.getPtr("native_receipt") orelse return error.TestFixtureInvalid);
        try native.put(run_allocator, "kind", .{ .string = @constCast("cas-historical-terminal-receipt") });
        try native.put(run_allocator, "ref", .{ .string = @constCast("artifact:historical-terminal") });
        try native.put(run_allocator, "receipt", native_value.value);
        const native_fingerprint = try digestValueAlloc(std.testing.allocator, native_value.value);
        defer std.testing.allocator.free(native_fingerprint);
        try native.put(run_allocator, "fingerprint", .{ .string = native_fingerprint });
        try validateRunReceipt(std.testing.allocator, &trial, &lane, run.value);
    }
}

test "promotion reveal eligibility rejects non-completed or invalid grades" {
    var lanes = [_]LaneState{.{
        .id = @constCast("lane-one"),
        .unit_id = @constCast("unit-one"),
        .scenario_id = @constCast("scenario-one"),
        .pair_id = @constCast("pair-one"),
        .arm_id = @constCast("arm-0"),
        .status = .failed,
    }};
    const trial = TrialState{
        .id = @constCast("trial-one"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("promotion"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = @constCast("{}"),
        .lanes = .{ .items = &lanes, .capacity = lanes.len },
        .requires_pair_grade = false,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    };
    try std.testing.expect(!try promotionRevealEligible(std.testing.allocator, &trial));
    lanes[0].status = .completed;
    lanes[0].absolute_graded = true;
    lanes[0].grade_status = @constCast("invalid");
    try std.testing.expect(!try promotionRevealEligible(std.testing.allocator, &trial));
}

test "first repair may bootstrap only from a null-factor practice diagnostic" {
    const diagnostic = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidNullTrialFixture,
        "\"purpose\": \"calibration_null\"",
        "\"purpose\": \"practice_repair\"",
    );
    defer std.testing.allocator.free(diagnostic);
    var validation = try validateTrialAlloc(std.testing.allocator, diagnostic);
    defer validation.deinit(std.testing.allocator);

    const non_null = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        diagnostic,
        "\"kind\": \"null\"",
        "\"kind\": \"instruction_bundle\"",
    );
    defer std.testing.allocator.free(non_null);
    try std.testing.expectError(
        error.PromotionChangeMissing,
        validateTrialAlloc(std.testing.allocator, non_null),
    );
}

test "null and positive calibration formulas are frozen" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), try nullBias(6, 4, 5, 5, 10), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), try positiveSensitivity(8, 10), 0.000001);
}

test "non-null trials reject identical arms" {
    const same_value = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidTrialFixture,
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    defer std.testing.allocator.free(same_value);
    const same_materialization = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        same_value,
        "sha256:3222222222222222222222222222222222222222222222222222222222222222",
        "sha256:2111111111111111111111111111111111111111111111111111111111111111",
    );
    defer std.testing.allocator.free(same_materialization);
    try std.testing.expectError(
        error.InterventionDifferenceMissing,
        validateTrialAlloc(std.testing.allocator, same_materialization),
    );
}

fn testBodyAlloc(
    allocator: std.mem.Allocator,
    scenario_id: ?[]const u8,
    attempt_id: ?[]const u8,
    grade_id: ?[]const u8,
    payload_json: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"scenario_id\":");
    if (scenario_id) |value| try retrace_core.canonical_json.writeCanonicalString(&out.writer, value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"attempt_id\":");
    if (attempt_id) |value| try retrace_core.canonical_json.writeCanonicalString(&out.writer, value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"grade_id\":");
    if (grade_id) |value| try retrace_core.canonical_json.writeCanonicalString(&out.writer, value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"payload\":");
    try out.writer.writeAll(payload_json);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn testObjectPtr(value: *std.json.Value) !*std.json.ObjectMap {
    if (value.* != .object) return error.ObjectRequired;
    return &value.object;
}

test "proof-projected registration preserves canonical profile binding" {
    const mismatched = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        ValidNullTrialFixture,
        CanonicalJsonProfile,
        "other-canonical-json/v1",
    );
    defer std.testing.allocator.free(mismatched);
    var trial = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mismatched, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial.deinit();
    const fingerprint = try digestValueAlloc(std.testing.allocator, trial.value);
    defer std.testing.allocator.free(fingerprint);
    const payload = try registrationPayloadAlloc(std.testing.allocator, mismatched, fingerprint);
    defer std.testing.allocator.free(payload);
    const body = try testBodyAlloc(std.testing.allocator, null, null, null, payload);
    defer std.testing.allocator.free(body);
    var parsed_body = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed_body.deinit();
    var state = CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.CanonicalJsonProfileMismatch,
        applyProofProjectedRegistered(
            std.testing.allocator,
            &state,
            parsed_body.value,
            1,
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), state.trials.items.len);
}

test "trial state rejects undeclared and duplicate lane starts" {
    var trial_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ValidNullTrialFixture, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial_value.deinit();
    const fingerprint = try digestValueAlloc(std.testing.allocator, trial_value.value);
    defer std.testing.allocator.free(fingerprint);
    const canonical_trial = try canonicalJsonAlloc(std.testing.allocator, trial_value.value);
    defer std.testing.allocator.free(canonical_trial);
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"trial_fingerprint\":\"{s}\",\"trial\":{s}}}",
        .{ fingerprint, canonical_trial },
    );
    defer std.testing.allocator.free(payload);
    const registration_body = try testBodyAlloc(std.testing.allocator, null, null, null, payload);
    defer std.testing.allocator.free(registration_body);
    var registration = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, registration_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer registration.deinit();
    var state = CampaignTrials{};
    defer state.deinit(std.testing.allocator);
    try applyRegistered(
        std.testing.allocator,
        &state,
        registration.value,
        1,
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    try std.testing.expectError(
        error.TrialIdDuplicate,
        applyRegistered(
            std.testing.allocator,
            &state,
            registration.value,
            2,
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
    );
    const null_trial = state.findTrial("trial-null-001") orelse return error.TestExpectedTrial;
    const lane_a0 = null_trial.findLane("lane-null-a0") orelse return error.TestExpectedLane;
    const manifest_a0 = try laneManifestFingerprintAlloc(std.testing.allocator, lane_a0);
    defer std.testing.allocator.free(manifest_a0);
    const start_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"trial_id\":\"trial-null-001\",\"unit_id\":\"unit-null-001\",\"pair_id\":\"pair-null-001\",\"opaque_arm_id\":\"arm-0\",\"lane_manifest_fingerprint\":\"{s}\",\"start_lease_digest\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"runner_id\":\"cas-trial\",\"runner_contract_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\",\"target_snapshot_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"presented_input_fingerprint\":\"sha256:3dbc2a117751f42078d15a82dab707eef4ac2c2b19a8addd9286a873fa6ffb65\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"model_configuration_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\"}}",
        .{manifest_a0},
    );
    defer std.testing.allocator.free(start_payload);
    const start_body = try testBodyAlloc(
        std.testing.allocator,
        "scenario-holdout",
        "lane-null-a0",
        null,
        start_payload,
    );
    defer std.testing.allocator.free(start_body);
    var start = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, start_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer start.deinit();
    try applyLaneStarted(
        std.testing.allocator,
        &state,
        start.value,
        2,
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
    try std.testing.expectError(
        error.LaneAlreadyStarted,
        applyLaneStarted(
            std.testing.allocator,
            &state,
            start.value,
            3,
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ),
    );
    const unknown_body = try testBodyAlloc(
        std.testing.allocator,
        "scenario-holdout",
        "lane-not-registered",
        null,
        start_payload,
    );
    defer std.testing.allocator.free(unknown_body);
    var unknown = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unknown_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer unknown.deinit();
    try std.testing.expectError(
        error.LaneNotRegistered,
        applyLaneStarted(
            std.testing.allocator,
            &state,
            unknown.value,
            3,
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ),
    );

    const run_a0_bytes = ValidRunReceiptFixture;
    var run_a0 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, run_a0_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer run_a0.deinit();
    const retry_unbound = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        run_a0_bytes,
        "\"retry_count\": 0",
        "\"retry_count\": 1",
    );
    defer std.testing.allocator.free(retry_unbound);
    var retry_unbound_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        retry_unbound,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer retry_unbound_value.deinit();
    const retry_native = try requiredObject(try object(retry_unbound_value.value), "native_receipt");
    const retry_native_fingerprint = try digestValueAlloc(
        std.testing.allocator,
        try required(retry_native, "receipt"),
    );
    defer std.testing.allocator.free(retry_native_fingerprint);
    const retry_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        retry_unbound,
        "sha256:e2c43329003422f082580d9fff1019cf00733c0d279bc5ff948788f7088845fb",
        retry_native_fingerprint,
    );
    defer std.testing.allocator.free(retry_bytes);
    var retry_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        retry_bytes,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer retry_value.deinit();
    try std.testing.expectError(
        error.HiddenRetryOrFork,
        validateRunReceipt(std.testing.allocator, null_trial, lane_a0, retry_value.value),
    );

    var generic_hidden = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        run_a0_bytes,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer generic_hidden.deinit();
    var generic_receipt = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"schema\":\"emulator-receipt/v1\",\"trial_id\":\"trial-null-001\",\"lane_id\":\"lane-null-a0\",\"terminal_status\":\"completed\",\"execution_count\":1,\"retry_count\":0,\"hidden_fork_count\":1}",
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer generic_receipt.deinit();
    const generic_allocator = generic_hidden.arena.allocator();
    const generic_root = try testObjectPtr(&generic_hidden.value);
    const generic_native = try testObjectPtr(generic_root.getPtr("native_receipt") orelse return error.TestFixtureInvalid);
    try generic_native.put(generic_allocator, "kind", .{ .string = @constCast("emulator-receipt") });
    try generic_native.put(generic_allocator, "receipt", generic_receipt.value);
    const generic_fingerprint = try digestValueAlloc(std.testing.allocator, generic_receipt.value);
    defer std.testing.allocator.free(generic_fingerprint);
    try generic_native.put(generic_allocator, "fingerprint", .{ .string = generic_fingerprint });
    try std.testing.expectError(
        error.NativeReceiptInvalid,
        validateRunReceipt(std.testing.allocator, null_trial, lane_a0, generic_hidden.value),
    );

    var custom_portfolio = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        run_a0_bytes,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer custom_portfolio.deinit();
    const custom_allocator = custom_portfolio.arena.allocator();
    const custom_root = try testObjectPtr(&custom_portfolio.value);
    const custom_native = try testObjectPtr(custom_root.getPtr("native_receipt") orelse return error.TestFixtureInvalid);
    try custom_native.put(custom_allocator, "kind", .{ .string = @constCast("custom") });
    const custom_receipt = try testObjectPtr(custom_native.getPtr("receipt") orelse return error.TestFixtureInvalid);
    var portfolio: std.json.Array = .init(custom_allocator);
    try portfolio.append(.{ .string = @constCast("hidden-fork") });
    try custom_receipt.put(custom_allocator, "portfolio", .{ .array = portfolio });
    const custom_fingerprint = try digestValueAlloc(
        std.testing.allocator,
        custom_native.get("receipt") orelse return error.TestFixtureInvalid,
    );
    defer std.testing.allocator.free(custom_fingerprint);
    try custom_native.put(custom_allocator, "fingerprint", .{ .string = custom_fingerprint });
    const mechanism_trial_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        null_trial.trial_json,
        "\"purpose\":\"calibration_null\"",
        "\"purpose\":\"mechanism_probe\"",
    );
    defer std.testing.allocator.free(mechanism_trial_json);
    var mechanism_trial = null_trial.*;
    mechanism_trial.trial_json = mechanism_trial_json;
    try std.testing.expectError(
        error.NativeReceiptAdapterUnsupported,
        validateRunReceipt(std.testing.allocator, &mechanism_trial, lane_a0, custom_portfolio.value),
    );

    var invalid_terminal = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        run_a0_bytes,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer invalid_terminal.deinit();
    const invalid_allocator = invalid_terminal.arena.allocator();
    const invalid_root = try testObjectPtr(&invalid_terminal.value);
    const invalid_materialization = try testObjectPtr(invalid_root.getPtr("materialization") orelse return error.TestFixtureInvalid);
    try invalid_materialization.put(invalid_allocator, "hidden_reference_presented", .{ .bool = true });
    const invalid_isolation = try testObjectPtr(invalid_root.getPtr("isolation") orelse return error.TestFixtureInvalid);
    try invalid_isolation.put(invalid_allocator, "fresh_workspace", .{ .bool = false });
    try invalid_isolation.put(invalid_allocator, "shared_mutable_state_detected", .{ .bool = true });
    const invalid_effects = try testObjectPtr(invalid_root.getPtr("effects") orelse return error.TestFixtureInvalid);
    var violations: std.json.Array = .init(invalid_allocator);
    try violations.append(.{ .string = @constCast("effect-observation-unavailable") });
    try invalid_effects.put(invalid_allocator, "policy_violations", .{ .array = violations });
    const invalid_status = try testObjectPtr(invalid_root.getPtr("terminal") orelse return error.TestFixtureInvalid);
    try invalid_status.put(invalid_allocator, "status", .{ .string = @constCast("invalid") });
    try invalid_status.put(invalid_allocator, "failure_class", .{ .string = @constCast("runner_normalization_failure") });
    try invalid_status.put(invalid_allocator, "failure_detail_ref", .{ .string = @constCast("artifact:failure-detail") });
    const invalid_evidence = try testObjectPtr(invalid_root.getPtr("evidence") orelse return error.TestFixtureInvalid);
    inline for (.{ "output_ref", "output_fingerprint", "trace_ref", "trace_fingerprint" }) |key| {
        try invalid_evidence.put(invalid_allocator, key, .null);
    }
    const invalid_native = try testObjectPtr(invalid_root.getPtr("native_receipt") orelse return error.TestFixtureInvalid);
    const invalid_native_receipt = try testObjectPtr(invalid_native.getPtr("receipt") orelse return error.TestFixtureInvalid);
    try invalid_native_receipt.put(invalid_allocator, "terminal_status", .{ .string = @constCast("invalid") });
    const invalid_native_fingerprint = try digestValueAlloc(
        std.testing.allocator,
        invalid_native.get("receipt") orelse return error.TestFixtureInvalid,
    );
    defer std.testing.allocator.free(invalid_native_fingerprint);
    try invalid_native.put(invalid_allocator, "fingerprint", .{ .string = invalid_native_fingerprint });
    try validateRunReceipt(std.testing.allocator, null_trial, lane_a0, invalid_terminal.value);

    const run_a0_fingerprint = try digestValueAlloc(std.testing.allocator, run_a0.value);
    defer std.testing.allocator.free(run_a0_fingerprint);
    const run_a0_canonical = try canonicalJsonAlloc(std.testing.allocator, run_a0.value);
    defer std.testing.allocator.free(run_a0_canonical);
    const finish_a0_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"trial_id\":\"trial-null-001\",\"run_receipt_fingerprint\":\"{s}\",\"run_receipt\":{s}}}",
        .{ run_a0_fingerprint, run_a0_canonical },
    );
    defer std.testing.allocator.free(finish_a0_payload);
    const finish_a0_body = try testBodyAlloc(
        std.testing.allocator,
        "scenario-holdout",
        "lane-null-a0",
        null,
        finish_a0_payload,
    );
    defer std.testing.allocator.free(finish_a0_body);
    var finish_a0 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, finish_a0_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer finish_a0.deinit();
    try applyLaneFinished(std.testing.allocator, &state, finish_a0.value, 3);

    var grade_a0_receipt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ValidGradeReceiptFixture, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer grade_a0_receipt.deinit();
    const grade_a0_root = try testObjectPtr(&grade_a0_receipt.value);
    try grade_a0_root.put(
        grade_a0_receipt.arena.allocator(),
        "run_receipt_fingerprint",
        .{ .string = run_a0_fingerprint },
    );
    const grade_a0_bytes = try canonicalJsonAlloc(std.testing.allocator, grade_a0_receipt.value);
    defer std.testing.allocator.free(grade_a0_bytes);
    const grade_a0_fingerprint = try digestValueAlloc(std.testing.allocator, grade_a0_receipt.value);
    defer std.testing.allocator.free(grade_a0_fingerprint);
    const grade_a0_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"trial_id\":\"trial-null-001\",\"pair_id\":\"pair-null-001\",\"opaque_arm_id\":\"arm-0\",\"grade_receipt_ref\":\"fixture:grade-a0\",\"grade_receipt_fingerprint\":\"{s}\",\"grade_receipt\":{s}}}",
        .{ grade_a0_fingerprint, grade_a0_bytes },
    );
    defer std.testing.allocator.free(grade_a0_payload);
    const grade_a0_body = try testBodyAlloc(
        std.testing.allocator,
        "scenario-holdout",
        "lane-null-a0",
        "grade-lane-null-a0",
        grade_a0_payload,
    );
    defer std.testing.allocator.free(grade_a0_body);
    var grade_a0 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, grade_a0_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer grade_a0.deinit();
    try std.testing.expect(try applyAbsoluteGrade(
        std.testing.allocator,
        &state,
        grade_a0.value,
        1.0,
        true,
        0,
    ));

    const lane_a1 = null_trial.findLane("lane-null-a1") orelse return error.TestExpectedLane;
    const manifest_a1 = try laneManifestFingerprintAlloc(std.testing.allocator, lane_a1);
    defer std.testing.allocator.free(manifest_a1);
    const start_a1_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"trial_id\":\"trial-null-001\",\"unit_id\":\"unit-null-001\",\"pair_id\":\"pair-null-001\",\"opaque_arm_id\":\"arm-1\",\"lane_manifest_fingerprint\":\"{s}\",\"start_lease_digest\":\"sha256:1212121212121212121212121212121212121212121212121212121212121212\",\"runner_id\":\"cas-trial\",\"runner_contract_fingerprint\":\"sha256:4444444444444444444444444444444444444444444444444444444444444444\",\"target_snapshot_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"presented_input_fingerprint\":\"sha256:3dbc2a117751f42078d15a82dab707eef4ac2c2b19a8addd9286a873fa6ffb65\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"model_configuration_fingerprint\":\"sha256:5555555555555555555555555555555555555555555555555555555555555555\"}}",
        .{manifest_a1},
    );
    defer std.testing.allocator.free(start_a1_payload);
    const start_a1_body = try testBodyAlloc(
        std.testing.allocator,
        "scenario-holdout",
        "lane-null-a1",
        null,
        start_a1_payload,
    );
    defer std.testing.allocator.free(start_a1_body);
    var start_a1 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, start_a1_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer start_a1.deinit();
    try applyLaneStarted(
        std.testing.allocator,
        &state,
        start_a1.value,
        4,
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
    try std.testing.expect(!state.trials.items[0].allLanesTerminal());

    const run_a1_lane = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        run_a0_bytes,
        "lane-null-a0",
        "lane-null-a1",
    );
    defer std.testing.allocator.free(run_a1_lane);
    const run_a1_arm = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        run_a1_lane,
        "\"arm-0\"",
        "\"arm-1\"",
    );
    defer std.testing.allocator.free(run_a1_arm);
    const run_a1_start = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        run_a1_arm,
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
    defer std.testing.allocator.free(run_a1_start);
    const run_a1_lease = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        run_a1_start,
        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "sha256:1212121212121212121212121212121212121212121212121212121212121212",
    );
    defer std.testing.allocator.free(run_a1_lease);
    const run_a1_unbound = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        run_a1_lease,
        "-a0",
        "-a1",
    );
    defer std.testing.allocator.free(run_a1_unbound);
    var run_a1_unbound_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        run_a1_unbound,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer run_a1_unbound_value.deinit();
    const run_a1_native = try requiredObject(
        try object(run_a1_unbound_value.value),
        "native_receipt",
    );
    const run_a1_native_fingerprint = try digestValueAlloc(
        std.testing.allocator,
        try required(run_a1_native, "receipt"),
    );
    defer std.testing.allocator.free(run_a1_native_fingerprint);
    const run_a1_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        run_a1_unbound,
        "sha256:e2c43329003422f082580d9fff1019cf00733c0d279bc5ff948788f7088845fb",
        run_a1_native_fingerprint,
    );
    defer std.testing.allocator.free(run_a1_bytes);
    var run_a1 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, run_a1_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer run_a1.deinit();
    const run_a1_fingerprint = try digestValueAlloc(std.testing.allocator, run_a1.value);
    defer std.testing.allocator.free(run_a1_fingerprint);
    const run_a1_canonical = try canonicalJsonAlloc(std.testing.allocator, run_a1.value);
    defer std.testing.allocator.free(run_a1_canonical);
    const finish_a1_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"trial_id\":\"trial-null-001\",\"run_receipt_fingerprint\":\"{s}\",\"run_receipt\":{s}}}",
        .{ run_a1_fingerprint, run_a1_canonical },
    );
    defer std.testing.allocator.free(finish_a1_payload);
    const finish_a1_body = try testBodyAlloc(
        std.testing.allocator,
        "scenario-holdout",
        "lane-null-a1",
        null,
        finish_a1_payload,
    );
    defer std.testing.allocator.free(finish_a1_body);
    var finish_a1 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, finish_a1_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer finish_a1.deinit();
    try applyLaneFinished(std.testing.allocator, &state, finish_a1.value, 5);

    const grade_a1_lane = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        grade_a0_bytes,
        "lane-null-a0",
        "lane-null-a1",
    );
    defer std.testing.allocator.free(grade_a1_lane);
    const grade_a1_arm = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        grade_a1_lane,
        "\"arm-0\"",
        "\"arm-1\"",
    );
    defer std.testing.allocator.free(grade_a1_arm);
    const grade_a1_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        grade_a1_arm,
        run_a0_fingerprint,
        run_a1_fingerprint,
    );
    defer std.testing.allocator.free(grade_a1_bytes);
    var grade_a1_receipt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, grade_a1_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer grade_a1_receipt.deinit();
    const grade_a1_fingerprint = try digestValueAlloc(std.testing.allocator, grade_a1_receipt.value);
    defer std.testing.allocator.free(grade_a1_fingerprint);
    const grade_a1_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"trial_id\":\"trial-null-001\",\"pair_id\":\"pair-null-001\",\"opaque_arm_id\":\"arm-1\",\"grade_receipt_ref\":\"fixture:grade-a1\",\"grade_receipt_fingerprint\":\"{s}\",\"grade_receipt\":{s}}}",
        .{ grade_a1_fingerprint, grade_a1_bytes },
    );
    defer std.testing.allocator.free(grade_a1_payload);
    const grade_a1_body = try testBodyAlloc(
        std.testing.allocator,
        "scenario-holdout",
        "lane-null-a1",
        "grade-lane-null-a1",
        grade_a1_payload,
    );
    defer std.testing.allocator.free(grade_a1_body);
    var grade_a1 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, grade_a1_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer grade_a1.deinit();
    try std.testing.expect(try applyAbsoluteGrade(
        std.testing.allocator,
        &state,
        grade_a1.value,
        1.0,
        true,
        0,
    ));

    const pair_grade_bytes = ValidPairGradeReceiptFixture;
    var pair_grade_receipt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pair_grade_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer pair_grade_receipt.deinit();
    const pair_grade_fingerprint = try digestValueAlloc(std.testing.allocator, pair_grade_receipt.value);
    defer std.testing.allocator.free(pair_grade_fingerprint);
    const pair_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"trial_id\":\"trial-null-001\",\"pair_id\":\"pair-null-001\",\"pair_grade_receipt_fingerprint\":\"{s}\",\"pair_grade_receipt\":{s}}}",
        .{ pair_grade_fingerprint, pair_grade_bytes },
    );
    defer std.testing.allocator.free(pair_payload);
    const pair_body = try testBodyAlloc(std.testing.allocator, null, null, null, pair_payload);
    defer std.testing.allocator.free(pair_body);
    var pair_grade = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pair_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer pair_grade.deinit();
    try applyPairGrade(std.testing.allocator, &state, pair_grade.value);
    try std.testing.expect(state.trials.items[0].allLanesTerminal());
    try std.testing.expect(state.trials.items[0].allRequiredGradesPresent());

    const reveal_bytes = ValidRevealFixture;
    var reveal_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reveal_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer reveal_value.deinit();
    const reveal_fingerprint = try digestValueAlloc(std.testing.allocator, reveal_value.value);
    defer std.testing.allocator.free(reveal_fingerprint);
    const reveal_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"reveal_fingerprint\":\"{s}\",\"reveal\":{s}}}",
        .{ reveal_fingerprint, reveal_bytes },
    );
    defer std.testing.allocator.free(reveal_payload);
    const reveal_body = try testBodyAlloc(std.testing.allocator, null, null, null, reveal_payload);
    defer std.testing.allocator.free(reveal_body);
    var reveal = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reveal_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer reveal.deinit();
    try applyReveal(std.testing.allocator, &state, reveal.value, 7);
    try std.testing.expect(state.trials.items[0].revealed);

    const close_payload =
        "{\"trial_id\":\"trial-null-001\",\"status\":\"completed\",\"reason\":\"fixed cohort complete\",\"result_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"}";
    const close_body = try testBodyAlloc(std.testing.allocator, null, null, null, close_payload);
    defer std.testing.allocator.free(close_body);
    var close = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, close_body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer close.deinit();
    try applyClosed(
        std.testing.allocator,
        &state,
        close.value,
        8,
        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    );
    try std.testing.expect(state.trials.items[0].closed);
}

test "receipt attestations bind producer identity and subject bytes" {
    const seed = [_]u8{0x42} ** 32;
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const public_key_bytes = key_pair.public_key.toBytes();
    var public_key_base64_buffer: [std.base64.standard.Encoder.calcSize(public_key_bytes.len)]u8 = undefined;
    const public_key_base64 = std.base64.standard.Encoder.encode(
        &public_key_base64_buffer,
        &public_key_bytes,
    );
    const trial_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"assurance\":{{\"required_level\":\"receipt_bound\",\"trust_policy\":{{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"trust-test\",\"keys\":[{{\"key_id\":\"runner-key\",\"public_key_base64\":\"{s}\",\"allowed_roles\":[\"runner\"],\"producer_ids\":[\"runner-test\"]}}],\"separation\":{{\"runner_and_pair_grader_distinct\":true,\"materializer_and_pair_grader_distinct\":true,\"human_confirmation_required_for_human_grade\":true}}}}}}}}",
        .{public_key_base64},
    );
    defer std.testing.allocator.free(trial_json);
    const trial = TrialState{
        .id = @constCast("trial-attestation"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("reliability_probe"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = trial_json,
        .requires_pair_grade = false,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    };
    const unsigned_receipt =
        "{\"schema\":\"test-receipt/v1\",\"producer\":{\"id\":\"runner-test\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"key_id\":\"runner-key\"},\"value\":\"ok\",\"attestation\":null}";
    var unsigned_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        unsigned_receipt,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer unsigned_value.deinit();
    const subject_fingerprint = try subjectFingerprintAlloc(std.testing.allocator, unsigned_value.value);
    defer std.testing.allocator.free(subject_fingerprint);
    const unsigned_attestation = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema\":\"hylo-attestation/v1\",\"subject_schema\":\"test-receipt/v1\",\"subject_fingerprint\":\"{s}\",\"producer_id\":\"runner-test\",\"producer_version\":\"v1\",\"binary_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"key_id\":\"runner-key\",\"role\":\"runner\",\"issued_at_unix\":1,\"signature\":{{\"algorithm\":\"ed25519\",\"value_base64\":\"\"}}}}",
        .{subject_fingerprint},
    );
    defer std.testing.allocator.free(unsigned_attestation);
    var attestation_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        unsigned_attestation,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer attestation_value.deinit();
    const preimage = try attestationPreimageAlloc(
        std.testing.allocator,
        try object(attestation_value.value),
    );
    defer std.testing.allocator.free(preimage);
    const signature = try key_pair.sign(preimage, null);
    const signature_bytes = signature.toBytes();
    var signature_base64_buffer: [std.base64.standard.Encoder.calcSize(signature_bytes.len)]u8 = undefined;
    const signature_base64 = std.base64.standard.Encoder.encode(
        &signature_base64_buffer,
        &signature_bytes,
    );
    const receipt = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema\":\"test-receipt/v1\",\"producer\":{{\"id\":\"runner-test\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"key_id\":\"runner-key\"}},\"value\":\"ok\",\"attestation\":{{\"schema\":\"hylo-attestation/v1\",\"subject_schema\":\"test-receipt/v1\",\"subject_fingerprint\":\"{s}\",\"producer_id\":\"runner-test\",\"producer_version\":\"v1\",\"binary_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"key_id\":\"runner-key\",\"role\":\"runner\",\"issued_at_unix\":1,\"signature\":{{\"algorithm\":\"ed25519\",\"value_base64\":\"{s}\"}}}}}}",
        .{ subject_fingerprint, signature_base64 },
    );
    defer std.testing.allocator.free(receipt);
    var receipt_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        receipt,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer receipt_value.deinit();
    const key_id = try verifyReceiptAttestation(
        std.testing.allocator,
        &trial,
        receipt_value.value,
        "runner",
    ) orelse return error.TestExpectedAttestationKey;
    defer std.testing.allocator.free(key_id);
    try std.testing.expectEqualStrings("runner-key", key_id);

    const tampered_receipt = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        receipt,
        "\"value\":\"ok\"",
        "\"value\":\"no\"",
    );
    defer std.testing.allocator.free(tampered_receipt);
    var tampered_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tampered_receipt,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer tampered_value.deinit();
    try std.testing.expectError(
        error.AttestationSubjectMismatch,
        verifyReceiptAttestation(std.testing.allocator, &trial, tampered_value.value, "runner"),
    );

    const signature_marker = "\"value_base64\":\"";
    const signature_start = std.mem.indexOf(u8, receipt, signature_marker) orelse
        return error.TestExpectedAttestationSignature;
    const tampered_signature_receipt = try std.testing.allocator.dupe(u8, receipt);
    defer std.testing.allocator.free(tampered_signature_receipt);
    const signature_index = signature_start + signature_marker.len;
    tampered_signature_receipt[signature_index] = if (tampered_signature_receipt[signature_index] == 'A') 'B' else 'A';
    var tampered_signature_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tampered_signature_receipt,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer tampered_signature_value.deinit();
    try std.testing.expectError(
        error.AttestationSignatureInvalid,
        verifyReceiptAttestation(std.testing.allocator, &trial, tampered_signature_value.value, "runner"),
    );
}
