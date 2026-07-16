const std = @import("std");
const durable_store = @import("durable_store");
const retrace_core = @import("retrace_core");

const adapter = retrace_core.hctp_adapter;
const attestation = retrace_core.hctp_attestation;
const portable_credentials = retrace_core.portable_credentials;
const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const MaxInputBytes = 64 * 1024 * 1024;

pub const source_request_schema = "hylo-source-selection-request/v1";
pub const source_receipt_schema = "hylo-source-selection-receipt/v1";
pub const sealed_case_schema = "hylo-sealed-case/v1";
pub const materialization_receipt_schema = "hylo-materialization-receipt/v1";

const Action = enum { compile, validate, govern, materialize };

const Options = struct {
    action: Action,
    manifest: ?[]const u8 = null,
    manifest_fd: ?std.posix.fd_t = null,
    output: ?[]const u8 = null,
    sealed_dir: ?[]const u8 = null,
    seal_key_fd: ?std.posix.fd_t = null,
    seal_key_output_fd: ?std.posix.fd_t = null,
    source_signing_seed_fd: ?std.posix.fd_t = null,
    evidence: ?[]const u8 = null,
    receipt: ?[]const u8 = null,
    sealed_case: ?[]const u8 = null,
    trial: ?[]const u8 = null,
    lane_id: ?[]const u8 = null,
    visible_output_fd: ?std.posix.fd_t = null,
    source_profile_output_fd: ?std.posix.fd_t = null,
    signing_seed_fd: ?std.posix.fd_t = null,
    source_owner_id: []const u8 = "seq-source-owner",
    source_owner_key_id: []const u8 = "source-owner-key",
    materializer_id: []const u8 = "seq-materializer",
    materializer_key_id: []const u8 = "materializer-key",
    controller_id: []const u8 = "hylo-controller",
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try stdout_writer.interface.writeAll(usage());
        return;
    }
    const options = try parseArgs(args);
    switch (options.action) {
        .compile => try cmdCompile(allocator, options),
        .validate => try cmdValidate(allocator, options),
        .govern => try cmdGovern(allocator, options),
        .materialize => try cmdMaterialize(allocator, options),
    }
}

pub fn usage() []const u8 {
    return
    \\usage: seq hctp-source compile (--manifest FILE | --manifest-fd N) --output FILE --source-signing-seed-fd N
    \\           [--sealed-dir DIR --seal-key-output-fd N]
    \\       seq hctp-source validate --receipt FILE --trial FILE
    \\       seq hctp-source govern --evidence FILE --output FILE
    \\       seq hctp-source materialize --sealed-case FILE --trial FILE --lane-id ID
    \\           --seal-key-fd N --visible-output-fd N [--source-profile-output-fd N]
    \\           --signing-seed-fd N --output FILE
    \\
    \\Compilation derives the complete denominator and independence clusters.
    \\Case-blind payloads are XChaCha20-Poly1305 sealed; plaintext is omitted
    \\from the receipt. Materialization writes visible input only to a protected
    \\FD and emits a role-attested, lane-scoped receipt.
    ;
}

fn parseArgs(args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingHctpSourceAction;
    var options = Options{ .action = if (std.mem.eql(u8, args[0], "compile"))
        .compile
    else if (std.mem.eql(u8, args[0], "validate"))
        .validate
    else if (std.mem.eql(u8, args[0], "govern"))
        .govern
    else if (std.mem.eql(u8, args[0], "materialize"))
        .materialize
    else
        return error.InvalidHctpSourceAction };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h")) return error.HctpSourceHelp;
        if (index + 1 >= args.len) return error.MissingArgValue;
        const value = args[index + 1];
        index += 1;
        if (std.mem.eql(u8, flag, "--manifest")) options.manifest = value else if (std.mem.eql(u8, flag, "--manifest-fd")) options.manifest_fd = try parseFd(value) else if (std.mem.eql(u8, flag, "--output")) options.output = value else if (std.mem.eql(u8, flag, "--sealed-dir")) options.sealed_dir = value else if (std.mem.eql(u8, flag, "--seal-key-fd")) options.seal_key_fd = try parseFd(value) else if (std.mem.eql(u8, flag, "--seal-key-output-fd")) options.seal_key_output_fd = try parseFd(value) else if (std.mem.eql(u8, flag, "--source-signing-seed-fd")) options.source_signing_seed_fd = try parseFd(value) else if (std.mem.eql(u8, flag, "--evidence")) options.evidence = value else if (std.mem.eql(u8, flag, "--receipt")) options.receipt = value else if (std.mem.eql(u8, flag, "--sealed-case")) options.sealed_case = value else if (std.mem.eql(u8, flag, "--trial")) options.trial = value else if (std.mem.eql(u8, flag, "--lane-id")) options.lane_id = value else if (std.mem.eql(u8, flag, "--visible-output-fd")) options.visible_output_fd = try parseFd(value) else if (std.mem.eql(u8, flag, "--source-profile-output-fd")) options.source_profile_output_fd = try parseFd(value) else if (std.mem.eql(u8, flag, "--signing-seed-fd")) options.signing_seed_fd = try parseFd(value) else if (std.mem.eql(u8, flag, "--source-owner-id")) options.source_owner_id = value else if (std.mem.eql(u8, flag, "--source-owner-key-id")) options.source_owner_key_id = value else if (std.mem.eql(u8, flag, "--materializer-id")) options.materializer_id = value else if (std.mem.eql(u8, flag, "--materializer-key-id")) options.materializer_key_id = value else if (std.mem.eql(u8, flag, "--controller-id")) options.controller_id = value else return error.UnknownArgument;
    }
    return options;
}

fn parseFd(raw: []const u8) !std.posix.fd_t {
    const value = try std.fmt.parseInt(i32, raw, 10);
    if (value < 3) return error.InvalidFd;
    return value;
}

const CaseInfo = struct {
    object: std.json.ObjectMap,
    unit_id: []const u8,
    scenario_id: []const u8,
    split: []const u8,
    visibility: []const u8,
    visible_fingerprint: []u8,
    hidden_fingerprint: []u8,
    source_episode_fingerprint: []u8,
    source_profile_fingerprint: []u8,
    target_text_witness: ?[]u8,
    source_profile_json: []u8,
    normalized_request: []u8,
    dependency_keys: [][]u8,
    cluster_root: usize,

    fn deinit(self: *CaseInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.visible_fingerprint);
        allocator.free(self.hidden_fingerprint);
        allocator.free(self.source_episode_fingerprint);
        allocator.free(self.source_profile_fingerprint);
        if (self.target_text_witness) |witness| allocator.free(witness);
        allocator.free(self.source_profile_json);
        allocator.free(self.normalized_request);
        for (self.dependency_keys) |key| allocator.free(key);
        allocator.free(self.dependency_keys);
    }
};

fn cmdCompile(allocator: std.mem.Allocator, options: Options) !void {
    if ((options.manifest == null) == (options.manifest_fd == null)) {
        return if (options.manifest == null) error.MissingManifest else error.ManifestSourceConflict;
    }
    const source_seed_fd = options.source_signing_seed_fd orelse return error.SourceSigningSeedRequired;
    var capability_fds: [3]std.posix.fd_t = undefined;
    var capability_count: usize = 0;
    capability_fds[capability_count] = source_seed_fd;
    capability_count += 1;
    if (options.manifest_fd) |fd| {
        try validateManifestInputEndpoint(fd);
        capability_fds[capability_count] = fd;
        capability_count += 1;
    }
    if (options.seal_key_output_fd) |fd| {
        capability_fds[capability_count] = fd;
        capability_count += 1;
    }
    try validateDistinctSensitiveEndpoints(capability_fds[0..capability_count]);
    const output_path = options.output orelse return error.MissingOutput;
    const raw = if (options.manifest_fd) |fd|
        try readFdAlloc(allocator, fd, MaxInputBytes)
    else
        try readFileAlloc(allocator, options.manifest.?);
    defer {
        std.crypto.secureZero(u8, raw);
        allocator.free(raw);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(root, "schema"), source_request_schema)) return error.SourceManifestSchemaInvalid;
    const campaign_id = try requiredString(root, "campaign_id");
    const cases = try requiredArray(root, "cases");
    if (cases.items.len == 0) return error.SourceManifestEmpty;
    const default_visibility = optionalString(root, "case_visibility") orelse "open";
    const needs_seal = anyCaseBlind(cases, default_visibility) catch return error.SourceManifestInvalid;
    if (options.seal_key_fd != null) return error.ControllerSuppliedSealKeyForbidden;
    if (needs_seal and options.seal_key_output_fd == null) return error.SealKeyOutputFdRequired;
    if (needs_seal and options.sealed_dir == null) return error.SealedDirectoryRequired;

    var infos = try allocator.alloc(CaseInfo, cases.items.len);
    var initialized: usize = 0;
    defer {
        for (infos[0..initialized]) |*info| info.deinit(allocator);
        allocator.free(infos);
    }
    var seen_units = std.StringHashMap(void).init(allocator);
    defer seen_units.deinit();
    var seen_scenarios = std.StringHashMap(void).init(allocator);
    defer seen_scenarios.deinit();
    for (cases.items, 0..) |case_value, index| {
        const case = try object(case_value);
        const unit_id = try requiredString(case, "unit_id");
        const scenario_id = try requiredString(case, "scenario_id");
        try validateId(unit_id);
        try validateId(scenario_id);
        if ((try seen_units.getOrPut(unit_id)).found_existing or
            (try seen_scenarios.getOrPut(scenario_id)).found_existing)
        {
            return error.DuplicateSourceCase;
        }
        const split = try requiredString(case, "split");
        if (!oneOf(split, &.{ "practice", "holdout", "challenge" })) return error.SourceSplitInvalid;
        const visibility = optionalString(case, "case_visibility") orelse default_visibility;
        if (!oneOf(visibility, &.{ "open", "result_blind", "case_blind" })) return error.CaseVisibilityInvalid;
        const visible = case.get("visible_input") orelse return error.VisibleInputMissing;
        const visible_json = try attestation.canonicalJsonAlloc(allocator, visible);
        defer allocator.free(visible_json);
        if (containsPersistedSecret(visible_json)) return error.FinalSanitizationFailed;
        const hidden = case.get("hidden_reference") orelse std.json.Value.null;
        const source_profile_input = case.get("source_profile") orelse return error.SourceProfileMissing;
        const source_profile_json = try prepareSourceProfileAlloc(allocator, source_profile_input, split);
        var profile_owned = true;
        defer if (profile_owned) allocator.free(source_profile_json);
        var source_profile_parsed = try std.json.parseFromSlice(std.json.Value, allocator, source_profile_json, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        });
        defer source_profile_parsed.deinit();
        const source_profile = source_profile_parsed.value;
        try validateSourceProfile(allocator, source_profile, split);
        const source_profile_object = try object(source_profile);
        const target_text_witness = try targetTextWitnessAlloc(allocator, source_profile_object);
        const normalized = try normalizeRequestAlloc(allocator, visible_json);
        const dependencies = try dependencyKeysAlloc(allocator, case);
        const source_episode_fingerprint = try sourceEpisodeFingerprintAlloc(
            allocator,
            case,
            source_profile,
            split,
        );
        infos[index] = .{
            .object = case,
            .unit_id = unit_id,
            .scenario_id = scenario_id,
            .split = split,
            .visibility = visibility,
            .visible_fingerprint = try attestation.digestValueAlloc(allocator, visible),
            .hidden_fingerprint = try attestation.digestValueAlloc(allocator, hidden),
            .source_episode_fingerprint = source_episode_fingerprint,
            .source_profile_fingerprint = try attestation.digestValueAlloc(allocator, source_profile),
            .target_text_witness = target_text_witness,
            .source_profile_json = source_profile_json,
            .normalized_request = normalized,
            .dependency_keys = dependencies,
            .cluster_root = index,
        };
        initialized += 1;
        profile_owned = false;
    }
    try connectDependencies(infos);
    try rejectCrossSplitDependencyClusters(infos);
    try rejectCrossSplitExactDuplicates(infos);
    try validateKeyInputEndpoint(source_seed_fd);
    if (options.seal_key_output_fd) |fd| try validatePrivateKeyCapability(fd);
    var source_seed = try readKey(source_seed_fd);
    defer std.crypto.secureZero(u8, &source_seed);
    const source_binary = try currentExecutableFingerprintAlloc(allocator);
    defer allocator.free(source_binary);
    var seal_key = [_]u8{0} ** 32;
    defer std.crypto.secureZero(u8, &seal_key);
    if (needs_seal) {
        try std.Io.randomSecure(defaultIo(), &seal_key);
        // The owner capability must exist before any ciphertext or receipt is
        // durable. A failed protected write therefore leaves nothing on disk
        // that can no longer be materialized.
        try writeFd(options.seal_key_output_fd.?, &seal_key);
    }

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try body.writer.writeByte('{');
    try writeStringMember(&body.writer, "schema", source_receipt_schema, true);
    try writeStringMember(&body.writer, "campaign_id", campaign_id, true);
    try body.writer.writeAll("\"denominator\":{");
    try body.writer.print("\"source_cases\":{d},\"independence_clusters\":{d},\"practice\":{d},\"holdout\":{d},\"challenge\":{d}}},", .{
        infos.len,
        countClusters(infos),
        countSplit(infos, "practice"),
        countSplit(infos, "holdout"),
        countSplit(infos, "challenge"),
    });
    try body.writer.writeAll("\"cases\":[");
    for (infos, 0..) |info, index| {
        if (index != 0) try body.writer.writeByte(',');
        const cluster_id = try clusterIdAlloc(allocator, infos, info.cluster_root);
        defer allocator.free(cluster_id);
        try body.writer.writeByte('{');
        try writeStringMember(&body.writer, "unit_id", info.unit_id, true);
        try writeStringMember(&body.writer, "scenario_id", info.scenario_id, true);
        try writeStringMember(&body.writer, "split", info.split, true);
        try writeStringMember(&body.writer, "independence_cluster_id", cluster_id, true);
        try writeStringMember(&body.writer, "case_visibility", info.visibility, true);
        try writeStringMember(&body.writer, "visible_input_fingerprint", info.visible_fingerprint, true);
        try writeStringMember(&body.writer, "hidden_reference_fingerprint", info.hidden_fingerprint, true);
        try writeStringMember(&body.writer, "source_episode_projection_version", adapter.source_episode_projection_version, true);
        try writeStringMember(&body.writer, "source_episode_fingerprint", info.source_episode_fingerprint, true);
        try writeStringMember(&body.writer, "source_profile_fingerprint", info.source_profile_fingerprint, true);
        try body.writer.writeAll("\"source_profile\":");
        const source_json = try sourceProfileProjectionAlloc(allocator, info);
        defer allocator.free(source_json);
        if (containsPersistedSecret(source_json)) return error.FinalSanitizationFailed;
        try body.writer.writeAll(source_json);
        if (std.mem.eql(u8, info.visibility, "case_blind")) {
            const sealed = try sealCaseAlloc(allocator, info, seal_key, options.sealed_dir.?);
            defer allocator.free(sealed.json);
            defer allocator.free(sealed.ref);
            defer allocator.free(sealed.fingerprint);
            try durable_store.writeTextAtomic(allocator, sealed.ref, sealed.json);
            try body.writer.writeAll(",\"sealed_case\":{");
            try writeStringMember(&body.writer, "schema", sealed_case_schema, true);
            try writeStringMember(&body.writer, "unit_id", info.unit_id, true);
            try writeStringMember(&body.writer, "visible_input_fingerprint", info.visible_fingerprint, true);
            try writeStringMember(&body.writer, "hidden_reference_fingerprint", info.hidden_fingerprint, true);
            try writeStringMember(&body.writer, "source_episode_projection_version", adapter.source_episode_projection_version, true);
            try writeStringMember(&body.writer, "source_episode_fingerprint", info.source_episode_fingerprint, true);
            try writeStringMember(&body.writer, "source_profile_fingerprint", info.source_profile_fingerprint, true);
            try writeStringMember(&body.writer, "ciphertext_or_capability_ref", sealed.ref, true);
            try writeStringMember(&body.writer, "ciphertext_fingerprint", sealed.fingerprint, false);
            try body.writer.writeByte('}');
        } else {
            try body.writer.writeAll(",\"visible_input\":");
            const visible_json = try attestation.canonicalJsonAlloc(allocator, info.object.get("visible_input").?);
            defer allocator.free(visible_json);
            try body.writer.writeAll(visible_json);
        }
        try body.writer.writeByte('}');
    }
    try body.writer.writeAll("],\"duplicate_analysis\":{");
    try body.writer.print("\"exact_duplicate_pairs\":{d},\"near_duplicate_pairs\":{d},\"cross_split_exact_duplicates\":0}},", .{
        countExactPairs(infos),
        countNearPairs(infos),
    });
    try body.writer.print("\"final_redaction\":{{\"schema\":\"hylo-final-sanitization-receipt/v1\",\"policy_id\":\"seq-final-redaction-v1\",\"status\":\"sanitized\",\"artifacts_checked\":{d},\"plaintext_sealed_cases_persisted\":false,\"secret_patterns_detected\":0}}}}", .{infos.len});
    const core_json = try body.toOwnedSlice();
    defer allocator.free(core_json);
    if (containsPersistedSecret(core_json)) return error.FinalSanitizationFailed;
    const source_owner_attestation = try sourceOwnerAttestationAlloc(
        allocator,
        core_json,
        campaign_id,
        options,
        source_binary,
        source_seed,
    );
    defer allocator.free(source_owner_attestation);
    const body_json = try appendJsonMemberAlloc(allocator, core_json, "source_owner_attestation", source_owner_attestation);
    defer allocator.free(body_json);
    var body_parsed = try std.json.parseFromSlice(std.json.Value, allocator, body_json, .{ .allocate = .alloc_always });
    defer body_parsed.deinit();
    const receipt_fingerprint = try attestation.digestValueAlloc(allocator, body_parsed.value);
    defer allocator.free(receipt_fingerprint);
    const final_json = try appendFingerprintAlloc(allocator, body_json, receipt_fingerprint);
    defer allocator.free(final_json);
    try durable_store.writeTextAtomic(allocator, output_path, final_json);
    const source_public_key = try attestation.publicKeyBase64Alloc(allocator, source_seed);
    defer allocator.free(source_public_key);
    try printReceipt(.{
        .schema = "hylo-source-compile-result/v1",
        .campaign_id = campaign_id,
        .receipt_ref = output_path,
        .receipt_fingerprint = receipt_fingerprint,
        .source_cases = infos.len,
        .independence_clusters = countClusters(infos),
        .source_owner_key_id = options.source_owner_key_id,
        .source_owner_public_key_base64 = source_public_key,
    });
}

fn cmdValidate(allocator: std.mem.Allocator, options: Options) !void {
    const receipt_path = options.receipt orelse return error.MissingReceipt;
    const trial_path = options.trial orelse return error.MissingTrial;
    const raw = try readFileAlloc(allocator, receipt_path);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    const trial_raw = try readFileAlloc(allocator, trial_path);
    defer allocator.free(trial_raw);
    var trial_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial_raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer trial_parsed.deinit();
    try validateSourceReceiptValue(allocator, parsed.value, try object(trial_parsed.value));
    try printReceipt(.{ .schema = "hylo-source-validation/v1", .status = "valid", .receipt_fingerprint = try requiredString(try object(parsed.value), "receipt_fingerprint") });
}

fn validateSourceReceiptValue(allocator: std.mem.Allocator, value: std.json.Value, trial: std.json.ObjectMap) !void {
    const root = try object(value);
    if (!std.mem.eql(u8, try requiredString(root, "schema"), source_receipt_schema)) return error.SourceReceiptInvalid;
    const campaign_id = try requiredString(root, "campaign_id");
    try validateId(campaign_id);
    if (!std.mem.eql(u8, campaign_id, try requiredString(trial, "campaign_id"))) return error.SourceCampaignMismatch;
    const declared = try requiredString(root, "receipt_fingerprint");
    try validateFingerprint(declared);
    const actual = try fingerprintOmittingAlloc(allocator, root, "receipt_fingerprint");
    defer allocator.free(actual);
    if (!std.mem.eql(u8, declared, actual)) return error.SourceReceiptFingerprintMismatch;
    const cases = try requiredArray(root, "cases");
    if (cases.items.len == 0) return error.SourceManifestEmpty;
    var seen_units = std.StringHashMap(void).init(allocator);
    defer seen_units.deinit();
    var seen_scenarios = std.StringHashMap(void).init(allocator);
    defer seen_scenarios.deinit();
    var clusters = std.StringHashMap(void).init(allocator);
    defer clusters.deinit();
    var practice: u64 = 0;
    var holdout: u64 = 0;
    var challenge: u64 = 0;
    for (cases.items) |case_value| {
        const case = try object(case_value);
        const unit_id = try requiredString(case, "unit_id");
        const scenario_id = try requiredString(case, "scenario_id");
        try validateId(unit_id);
        try validateId(scenario_id);
        if ((try seen_units.getOrPut(unit_id)).found_existing or
            (try seen_scenarios.getOrPut(scenario_id)).found_existing) return error.DuplicateSourceCase;
        const split = try requiredString(case, "split");
        if (std.mem.eql(u8, split, "practice")) practice += 1 else if (std.mem.eql(u8, split, "holdout")) holdout += 1 else if (std.mem.eql(u8, split, "challenge")) challenge += 1 else return error.SourceSplitInvalid;
        const cluster_id = try requiredString(case, "independence_cluster_id");
        try validateId(cluster_id);
        _ = try clusters.getOrPut(cluster_id);
        const visible_fingerprint = try requiredString(case, "visible_input_fingerprint");
        const hidden_fingerprint = try requiredString(case, "hidden_reference_fingerprint");
        const source_episode_fingerprint = try requiredString(case, "source_episode_fingerprint");
        const source_profile_fingerprint = try requiredString(case, "source_profile_fingerprint");
        try validateFingerprint(visible_fingerprint);
        try validateFingerprint(hidden_fingerprint);
        try validateFingerprint(source_episode_fingerprint);
        if (!std.mem.eql(
            u8,
            try requiredString(case, "source_episode_projection_version"),
            adapter.source_episode_projection_version,
        )) return error.SourceEpisodeProjectionVersionMismatch;
        try validateFingerprint(source_profile_fingerprint);
        const visibility = try requiredString(case, "case_visibility");
        if (!oneOf(visibility, &.{ "open", "result_blind", "case_blind" })) return error.CaseVisibilityInvalid;
        const profile = try requiredObject(case, "source_profile");
        const profile_json = try attestation.canonicalJsonAlloc(allocator, .{ .object = profile });
        defer allocator.free(profile_json);
        if (containsPersistedSecret(profile_json)) return error.FinalSanitizationFailed;
        if (optionalString(profile, "source_profile_fingerprint")) |committed_profile| {
            if (!std.mem.eql(u8, committed_profile, source_profile_fingerprint)) {
                return error.SourceProfileFingerprintMismatch;
            }
            const profile_kind = try requiredString(profile, "kind");
            if (std.mem.eql(u8, profile_kind, "historical_decision")) {
                if (!std.mem.eql(u8, try requiredString(profile, "profile_body_delivery"), "source_profile_fd")) {
                    return error.SourceProfileFingerprintMismatch;
                }
            } else if (!std.mem.eql(u8, profile_kind, "direct") or profile.get("profile_body_delivery") != null) {
                return error.SourceProfileFingerprintMismatch;
            }
        } else if (!std.mem.eql(u8, visibility, "case_blind")) {
            const observed_profile = try attestation.digestValueAlloc(allocator, .{ .object = profile });
            defer allocator.free(observed_profile);
            if (!std.mem.eql(u8, observed_profile, source_profile_fingerprint)) {
                return error.SourceProfileFingerprintMismatch;
            }
        }
        if (std.mem.eql(u8, visibility, "case_blind")) {
            if (case.get("visible_input") != null or profile.get("source_governance") != null or profile.get("decision_context") != null or
                !try requiredBool(profile, "sealed_payload")) return error.CaseBlindProjectionInvalid;
            const profile_kind = try requiredString(profile, "kind");
            if (profile.get("source_target_text_witness") != null) return error.CaseBlindProjectionInvalid;
            if (std.mem.eql(u8, profile_kind, "historical_decision")) {
                try validateFingerprint(try requiredString(profile, "source_target_text_witness_fingerprint"));
            } else if (profile.get("source_target_text_witness_fingerprint") != null) {
                return error.CaseBlindProjectionInvalid;
            }
            const sealed = try requiredObject(case, "sealed_case");
            if (!std.mem.eql(u8, try requiredString(sealed, "unit_id"), unit_id) or
                !std.mem.eql(u8, try requiredString(sealed, "visible_input_fingerprint"), visible_fingerprint) or
                !std.mem.eql(u8, try requiredString(sealed, "hidden_reference_fingerprint"), hidden_fingerprint) or
                !std.mem.eql(u8, try requiredString(sealed, "source_episode_projection_version"), adapter.source_episode_projection_version) or
                !std.mem.eql(u8, try requiredString(sealed, "source_episode_fingerprint"), source_episode_fingerprint)) return error.SealedCaseCommitmentMismatch;
            if (!std.mem.eql(u8, try requiredString(sealed, "source_profile_fingerprint"), source_profile_fingerprint)) return error.SealedCaseCommitmentMismatch;
            inline for (.{ "source_governance_ref", "decision_context_ref" }) |ref_key| {
                if (optionalString(profile, ref_key)) |ref| try validateOpaqueContentAddressedRef(ref);
            }
            try validateFingerprint(try requiredString(sealed, "ciphertext_fingerprint"));
            _ = try requiredString(sealed, "ciphertext_or_capability_ref");
        } else {
            const visible = case.get("visible_input") orelse return error.VisibleInputMissing;
            const observed = try attestation.digestValueAlloc(allocator, visible);
            defer allocator.free(observed);
            if (!std.mem.eql(u8, observed, visible_fingerprint)) return error.SealedCaseFingerprintMismatch;
        }
    }
    const denominator = try requiredObject(root, "denominator");
    if (try requiredU64(denominator, "source_cases") != cases.items.len or
        try requiredU64(denominator, "independence_clusters") != clusters.count() or
        try requiredU64(denominator, "practice") != practice or
        try requiredU64(denominator, "holdout") != holdout or
        try requiredU64(denominator, "challenge") != challenge) return error.SourceDenominatorInvalid;
    const duplicate_analysis = try requiredObject(root, "duplicate_analysis");
    _ = try requiredU64(duplicate_analysis, "exact_duplicate_pairs");
    _ = try requiredU64(duplicate_analysis, "near_duplicate_pairs");
    if (try requiredU64(duplicate_analysis, "cross_split_exact_duplicates") != 0) return error.DuplicateSourceAcrossSplits;
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
    const redaction = try requiredObject(root, "final_redaction");
    if (!std.mem.eql(u8, try requiredString(redaction, "schema"), "hylo-final-sanitization-receipt/v1") or
        !std.mem.eql(u8, try requiredString(redaction, "policy_id"), "seq-final-redaction-v1") or
        !std.mem.eql(u8, try requiredString(redaction, "status"), "sanitized") or
        try requiredU64(redaction, "artifacts_checked") != cases.items.len or
        try requiredU64(redaction, "secret_patterns_detected") != 0 or
        try requiredBool(redaction, "plaintext_sealed_cases_persisted")) return error.FinalSanitizationFailed;
    try validateSourceOwnerAttestation(allocator, root, trial);
}

fn findSourceCase(receipt_value: std.json.Value, unit_id: []const u8, scenario_id: []const u8) !std.json.ObjectMap {
    const root = try object(receipt_value);
    var found: ?std.json.ObjectMap = null;
    for ((try requiredArray(root, "cases")).items) |case_value| {
        const case = try object(case_value);
        if (!std.mem.eql(u8, try requiredString(case, "unit_id"), unit_id)) continue;
        if (!std.mem.eql(u8, try requiredString(case, "scenario_id"), scenario_id) or found != null) return error.MaterializationScopeInvalid;
        found = case;
    }
    return found orelse error.MaterializationScopeInvalid;
}

fn cmdGovern(allocator: std.mem.Allocator, options: Options) !void {
    const evidence_path = options.evidence orelse return error.MissingGovernanceEvidence;
    const output_path = options.output orelse return error.MissingOutput;
    const raw = try readFileAlloc(allocator, evidence_path);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    const evidence = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(evidence, "schema"), "hylo-source-governance-evidence/v1")) return error.GovernanceEvidenceInvalid;
    const source_ref = try requiredString(evidence, "source_ref");
    const source_episode_id = try requiredString(evidence, "source_episode_id");
    if (!std.mem.eql(u8, source_ref, source_episode_id)) return error.SourceEpisodeIdentityMismatch;
    const workflow_invoked = try requiredBool(evidence, "workflow_invoked");
    const target_owned = try requiredBool(evidence, "target_owned");
    const decision_inside = try requiredBool(evidence, "decision_inside_workflow");
    const declared_uncontrolled = try requiredBool(evidence, "declared_uncontrolled");
    const incidental_mention = try requiredBool(evidence, "incidental_mention");
    const conflicting = try requiredBool(evidence, "conflicting_evidence");
    const state = if (conflicting)
        "ambiguous"
    else if (workflow_invoked and target_owned and decision_inside)
        "authoritative"
    else if (declared_uncontrolled)
        "declared_uncontrolled"
    else if (incidental_mention)
        "incidental"
    else
        "absent";
    const replay_allowed = std.mem.eql(u8, state, "authoritative") or std.mem.eql(u8, state, "declared_uncontrolled");
    const evidence_fingerprint = try attestation.digestValueAlloc(allocator, parsed.value);
    defer allocator.free(evidence_fingerprint);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"source_governance_gate\":{{\"gate_version\":\"SGG-v1\",\"source_ref\":{f},\"source_episode_id\":{f},\"evidence_fingerprint\":{f},\"verdict\":{{\"state\":{f},\"replay_allowed\":{s},\"allowed_modes\":{s}}},\"limitations\":[]}}}}",
        .{
            std.json.fmt(source_ref, .{}),
            std.json.fmt(source_episode_id, .{}),
            std.json.fmt(evidence_fingerprint, .{}),
            std.json.fmt(state, .{}),
            if (replay_allowed) "true" else "false",
            if (replay_allowed) "[\"replay\"]" else "[]",
        },
    );
    defer allocator.free(body);
    try durable_store.writeTextAtomic(allocator, output_path, body);
    try printReceipt(.{ .schema = "hylo-source-governance-result/v1", .state = state, .replay_allowed = replay_allowed, .output_ref = output_path });
}

const MaterializerBoundary = struct {
    controller_id: []const u8,
    materializer_id: []const u8,
    runner_id: []const u8,
    materializer_key_id: []const u8,
    runner_key_id: []const u8,
};

fn validateMaterializerBoundary(
    contract: std.json.ObjectMap,
    materializer_id: []const u8,
    materializer_key_id: []const u8,
) !MaterializerBoundary {
    if (!std.mem.eql(
        u8,
        try requiredString(contract, "schema"),
        "hylo-case-materializer-contract/v1",
    )) return error.CaseMaterializerInvalid;
    const controller_id = try requiredString(contract, "controller_id");
    const registered_materializer_id = try requiredString(contract, "materializer_id");
    const runner_id = try requiredString(contract, "runner_id");
    const registered_materializer_key_id = try requiredString(contract, "materializer_key_id");
    const runner_key_id = try requiredString(contract, "runner_key_id");
    if (controller_id.len == 0 or registered_materializer_id.len == 0 or runner_id.len == 0 or
        registered_materializer_key_id.len == 0 or runner_key_id.len == 0)
    {
        return error.CaseMaterializerInvalid;
    }
    if (std.mem.eql(u8, controller_id, registered_materializer_id) or
        std.mem.eql(u8, controller_id, runner_id) or
        std.mem.eql(u8, registered_materializer_id, runner_id) or
        std.mem.eql(u8, registered_materializer_key_id, runner_key_id))
    {
        return error.SealedSamePrincipalForbidden;
    }
    if (!std.mem.eql(u8, registered_materializer_id, materializer_id) or
        !std.mem.eql(u8, registered_materializer_key_id, materializer_key_id) or
        !std.mem.eql(u8, try requiredString(contract, "capability_delivery"), "anonymous_fd") or
        !std.mem.eql(u8, try requiredString(contract, "visible_input_delivery"), "anonymous_fd") or
        !std.mem.eql(u8, try requiredString(contract, "source_profile_delivery"), "anonymous_fd") or
        !std.mem.eql(u8, try requiredString(contract, "receiver_binding"), "runner_key") or
        !std.mem.eql(u8, try requiredString(contract, "receiver_role"), "runner") or
        !try requiredBool(contract, "single_use"))
    {
        return error.CaseMaterializerInvalid;
    }
    return .{
        .controller_id = controller_id,
        .materializer_id = registered_materializer_id,
        .runner_id = runner_id,
        .materializer_key_id = registered_materializer_key_id,
        .runner_key_id = runner_key_id,
    };
}

fn validateRunnerOutputEndpoint(fd: std.posix.fd_t) !void {
    if (!isAnonymousSensitiveEndpoint(fd, .output)) return error.MaterializationEndpointUnbound;
}

fn cmdMaterialize(allocator: std.mem.Allocator, options: Options) !void {
    const sealed_path = options.sealed_case orelse return error.MissingSealedCase;
    const trial_path = options.trial orelse return error.MissingTrial;
    const lane_id = options.lane_id orelse return error.MissingLaneId;
    const output_path = options.output orelse return error.MissingOutput;
    const seal_key_fd = options.seal_key_fd orelse return error.SealKeyRequired;
    const signing_seed_fd = options.signing_seed_fd orelse return error.SigningSeedRequired;
    const visible_output_fd = options.visible_output_fd orelse return error.VisibleOutputFdRequired;
    try validateKeyInputEndpoint(seal_key_fd);
    try validateKeyInputEndpoint(signing_seed_fd);
    try validateRunnerOutputEndpoint(visible_output_fd);
    var capability_fds: [4]std.posix.fd_t = undefined;
    var capability_count: usize = 0;
    for ([_]std.posix.fd_t{ seal_key_fd, signing_seed_fd, visible_output_fd }) |fd| {
        capability_fds[capability_count] = fd;
        capability_count += 1;
    }
    if (options.source_profile_output_fd) |fd| {
        try validateRunnerOutputEndpoint(fd);
        capability_fds[capability_count] = fd;
        capability_count += 1;
    }
    try validateDistinctSensitiveEndpoints(capability_fds[0..capability_count]);
    var key = try readKey(seal_key_fd);
    defer std.crypto.secureZero(u8, &key);
    var seed = try readKey(signing_seed_fd);
    defer std.crypto.secureZero(u8, &seed);
    const sealed_raw = try readFileAlloc(allocator, sealed_path);
    defer allocator.free(sealed_raw);
    var sealed_parsed = try std.json.parseFromSlice(std.json.Value, allocator, sealed_raw, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    defer sealed_parsed.deinit();
    const envelope = try object(sealed_parsed.value);
    if (!std.mem.eql(u8, try requiredString(envelope, "schema"), "hylo-sealed-case-ciphertext/v1")) return error.SealedCaseInvalid;
    const trial_raw = try readFileAlloc(allocator, trial_path);
    defer allocator.free(trial_raw);
    var trial_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trial_raw, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    defer trial_parsed.deinit();
    const trial = try object(trial_parsed.value);
    if (std.mem.eql(u8, options.controller_id, options.materializer_id)) return error.SealedSamePrincipalForbidden;
    const assurance = try requiredObject(trial, "assurance");
    if (!std.mem.eql(u8, try requiredString(assurance, "required_level"), "sealed")) return error.SealedAssuranceRequired;
    const sealing = try requiredObject(trial, "sealing");
    if (!std.mem.eql(u8, try requiredString(sealing, "case_visibility"), "case_blind")) return error.CaseBlindRequired;
    const materializer_contract_value = sealing.get("case_materializer_contract") orelse
        return error.CaseMaterializerMissing;
    const materializer_contract = try object(materializer_contract_value);
    const materializer_boundary = try validateMaterializerBoundary(
        materializer_contract,
        options.materializer_id,
        options.materializer_key_id,
    );
    const materializer_contract_fingerprint = try attestation.digestValueAlloc(
        allocator,
        materializer_contract_value,
    );
    defer allocator.free(materializer_contract_fingerprint);
    if (!std.mem.eql(
        u8,
        materializer_contract_fingerprint,
        try requiredString(sealing, "case_materializer_fingerprint"),
    )) return error.CaseMaterializerInvalid;
    const lane = try findTrialLane(trial, lane_id);
    if (!std.mem.eql(u8, lane.unit_id, try requiredString(envelope, "unit_id"))) return error.MaterializationScopeInvalid;
    const source_receipt_value = sealing.get("source_selection_receipt") orelse return error.SourceReceiptInvalid;
    try validateSourceReceiptValue(allocator, source_receipt_value, trial);
    const source_case = try findSourceCase(source_receipt_value, lane.unit_id, lane.scenario_id);
    const registered_sealed = try requiredObject(source_case, "sealed_case");
    if (!std.mem.eql(u8, sealed_path, try requiredString(registered_sealed, "ciphertext_or_capability_ref"))) {
        return error.MaterializationScopeInvalid;
    }
    const sealed_fingerprint = try digestJsonTextAlloc(allocator, sealed_raw);
    defer allocator.free(sealed_fingerprint);
    if (!std.mem.eql(u8, sealed_fingerprint, try requiredString(registered_sealed, "ciphertext_fingerprint"))) {
        return error.SealedCaseFingerprintMismatch;
    }
    if (!std.mem.eql(u8, try requiredString(source_case, "source_episode_projection_version"), adapter.source_episode_projection_version) or
        !std.mem.eql(u8, try requiredString(registered_sealed, "source_episode_projection_version"), adapter.source_episode_projection_version) or
        !std.mem.eql(u8, try requiredString(envelope, "source_episode_projection_version"), adapter.source_episode_projection_version))
    {
        return error.SourceEpisodeProjectionVersionMismatch;
    }
    inline for (.{ "visible_input_fingerprint", "hidden_reference_fingerprint", "source_episode_fingerprint", "source_profile_fingerprint" }) |key_name| {
        if (!std.mem.eql(u8, try requiredString(envelope, key_name), try requiredString(registered_sealed, key_name)) or
            !std.mem.eql(u8, try requiredString(envelope, key_name), try requiredString(source_case, key_name)))
        {
            return error.SealedCaseCommitmentMismatch;
        }
    }
    const projected_profile = try requiredObject(source_case, "source_profile");
    const historical = std.mem.eql(u8, try requiredString(projected_profile, "kind"), "historical_decision");
    const source_profile_output_fd = if (historical)
        options.source_profile_output_fd orelse return error.SourceProfileOutputFdRequired
    else
        null;
    if (source_profile_output_fd) |fd| try validateRunnerOutputEndpoint(fd);
    const producer_binary = try currentExecutableFingerprintAlloc(allocator);
    defer allocator.free(producer_binary);
    try validateMaterializerAuthority(allocator, trial, options.materializer_id, options.materializer_key_id, seed);
    const payload = try decryptCaseAlloc(allocator, envelope, key);
    defer allocator.free(payload);
    var payload_parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    defer payload_parsed.deinit();
    const payload_root = try object(payload_parsed.value);
    if (!std.mem.eql(u8, try requiredString(payload_root, "unit_id"), lane.unit_id) or
        !std.mem.eql(u8, try requiredString(payload_root, "scenario_id"), lane.scenario_id) or
        !std.mem.eql(
            u8,
            try requiredString(payload_root, "source_episode_fingerprint"),
            try requiredString(source_case, "source_episode_fingerprint"),
        ))
    {
        return error.MaterializationScopeInvalid;
    }
    const visible = payload_root.get("visible_input") orelse return error.VisibleInputMissing;
    const hidden = payload_root.get("hidden_reference") orelse return error.HiddenReferenceMissing;
    const source_profile = payload_root.get("source_profile") orelse return error.SourceProfileMissing;
    const visible_json = try attestation.canonicalJsonAlloc(allocator, visible);
    defer allocator.free(visible_json);
    const visible_fingerprint = try attestation.digestValueAlloc(allocator, visible);
    defer allocator.free(visible_fingerprint);
    if (!std.mem.eql(u8, visible_fingerprint, try requiredString(envelope, "visible_input_fingerprint"))) return error.SealedCaseFingerprintMismatch;
    if (!arrayContains(try requiredArray(sealing, "visible_input_commitments"), visible_fingerprint)) return error.SealedCaseCommitmentMismatch;
    const hidden_fingerprint = try attestation.digestValueAlloc(allocator, hidden);
    defer allocator.free(hidden_fingerprint);
    if (!std.mem.eql(u8, hidden_fingerprint, try requiredString(envelope, "hidden_reference_fingerprint")) or
        !arrayContains(try requiredArray(sealing, "hidden_reference_commitments"), hidden_fingerprint))
    {
        return error.SealedCaseCommitmentMismatch;
    }
    const source_profile_fingerprint = try attestation.digestValueAlloc(allocator, source_profile);
    defer allocator.free(source_profile_fingerprint);
    if (!std.mem.eql(u8, source_profile_fingerprint, try requiredString(envelope, "source_profile_fingerprint"))) {
        return error.SealedCaseCommitmentMismatch;
    }
    if (historical) {
        var historical_profile = try adapter.validateHistoricalProfile(
            allocator,
            source_profile,
            std.mem.eql(u8, try requiredString(source_case, "split"), "holdout"),
        );
        defer historical_profile.deinit(allocator);
        try validateMaterializedTargetTextWitnessCommitment(
            projected_profile,
            historical_profile.target_text_witness_fingerprint,
        );
    }
    if (!std.mem.eql(u8, try requiredString(payload_root, "source_episode_projection_version"), adapter.source_episode_projection_version)) {
        return error.SourceEpisodeProjectionVersionMismatch;
    }
    const derived_source_episode_fingerprint = try derivedSourceEpisodeFingerprintAlloc(
        allocator,
        try requiredString(payload_root, "source_episode_id"),
        source_profile,
        try requiredString(source_case, "split"),
    );
    defer allocator.free(derived_source_episode_fingerprint);
    if (!std.mem.eql(u8, derived_source_episode_fingerprint, try requiredString(source_case, "source_episode_fingerprint"))) {
        return error.SourceEpisodeIdentityMismatch;
    }
    const source_profile_json = try attestation.canonicalJsonAlloc(allocator, source_profile);
    defer allocator.free(source_profile_json);
    try writeFd(visible_output_fd, visible_json);
    if (source_profile_output_fd) |fd| try writeFd(fd, source_profile_json);
    const capability_digest = try materializationCapabilityDigestAlloc(
        allocator,
        try requiredString(trial, "trial_id"),
        lane_id,
        lane.unit_id,
        materializer_boundary.materializer_key_id,
        materializer_boundary.runner_key_id,
    );
    defer allocator.free(capability_digest);
    const unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-materialization-receipt/v1\",\"trial_id\":{f},\"unit_id\":{f},\"lane_id\":{f},\"opaque_arm_id\":{f},\"visible_input_fingerprint\":{f},\"hidden_reference_fingerprint\":{f},\"source_episode_projection_version\":{f},\"source_episode_fingerprint\":{f},\"source_profile_fingerprint\":{f},\"ciphertext_fingerprint\":{f},\"source_selection_receipt_fingerprint\":{f},\"hidden_reference_disclosed\":false,\"semantic_arm_identity_disclosed\":false,\"capability_scope\":{{\"capability_digest\":{f},\"trial_id\":{f},\"lane_id\":{f},\"unit_count\":1,\"lane_count\":1,\"single_use\":true}},\"capability_domain\":{{\"controller_identity\":{f},\"materializer_identity\":{f},\"runner_identity\":{f},\"materializer_key_id\":{f},\"runner_key_id\":{f},\"delivery\":\"anonymous_fd\",\"receiver_binding\":\"runner_key\",\"single_use\":true}},\"producer\":{{\"id\":{f},\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":{f}}},\"attestation\":null}}",
        .{
            std.json.fmt(try requiredString(trial, "trial_id"), .{}),
            std.json.fmt(lane.unit_id, .{}),
            std.json.fmt(lane_id, .{}),
            std.json.fmt(lane.arm_id, .{}),
            std.json.fmt(visible_fingerprint, .{}),
            std.json.fmt(hidden_fingerprint, .{}),
            std.json.fmt(adapter.source_episode_projection_version, .{}),
            std.json.fmt(try requiredString(source_case, "source_episode_fingerprint"), .{}),
            std.json.fmt(source_profile_fingerprint, .{}),
            std.json.fmt(sealed_fingerprint, .{}),
            std.json.fmt(try requiredString(try object(source_receipt_value), "receipt_fingerprint"), .{}),
            std.json.fmt(capability_digest, .{}),
            std.json.fmt(try requiredString(trial, "trial_id"), .{}),
            std.json.fmt(lane_id, .{}),
            std.json.fmt(materializer_boundary.controller_id, .{}),
            std.json.fmt(materializer_boundary.materializer_id, .{}),
            std.json.fmt(materializer_boundary.runner_id, .{}),
            std.json.fmt(materializer_boundary.materializer_key_id, .{}),
            std.json.fmt(materializer_boundary.runner_key_id, .{}),
            std.json.fmt(options.materializer_id, .{}),
            std.json.fmt(producer_binary, .{}),
            std.json.fmt(options.materializer_key_id, .{}),
        },
    );
    defer allocator.free(unsigned);
    const signed = try attestation.signReceiptAlloc(allocator, unsigned, .{
        .id = options.materializer_id,
        .version = "v1",
        .binary_fingerprint = producer_binary,
        .key_id = options.materializer_key_id,
    }, "materializer", unixSeconds(), seed);
    defer allocator.free(signed);
    try durable_store.writeTextAtomic(allocator, output_path, signed);
    const fingerprint = try digestJsonTextAlloc(allocator, signed);
    defer allocator.free(fingerprint);
    try printReceipt(.{ .schema = "hylo-case-materialization-result/v1", .trial_id = try requiredString(trial, "trial_id"), .lane_id = lane_id, .receipt_ref = output_path, .receipt_fingerprint = fingerprint });
}

fn validateSourceProfile(allocator: std.mem.Allocator, value: std.json.Value, split: []const u8) !void {
    const profile = try object(value);
    const kind = try requiredString(profile, "kind");
    if (std.mem.eql(u8, kind, "direct")) return;
    if (!std.mem.eql(u8, kind, "historical_decision")) return error.SourceProfileInvalid;
    try validateEmbeddedFingerprint(allocator, profile, "source_governance", "source_governance_fingerprint");
    try validateEmbeddedFingerprint(allocator, profile, "decision_context", "decision_context_fingerprint");
    var report = try adapter.validateHistoricalProfile(allocator, value, std.mem.eql(u8, split, "holdout"));
    report.deinit(allocator);
}

fn prepareSourceProfileAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    split: []const u8,
) ![]u8 {
    const profile = try object(value);
    const kind = try requiredString(profile, "kind");
    if (std.mem.eql(u8, kind, "direct")) return attestation.canonicalJsonAlloc(allocator, value);
    if (!std.mem.eql(u8, kind, "historical_decision")) return error.SourceProfileInvalid;
    try validateEmbeddedFingerprint(allocator, profile, "source_governance", "source_governance_fingerprint");
    try validateEmbeddedFingerprint(allocator, profile, "decision_context", "decision_context_fingerprint");
    if (!std.mem.eql(u8, try requiredString(profile, "source_target_text_policy"), "strip_and_replace")) {
        var source_report = try adapter.validateHistoricalProfile(allocator, value, std.mem.eql(u8, split, "holdout"));
        source_report.deinit(allocator);
        return attestation.canonicalJsonAlloc(allocator, value);
    }

    const original_context = profile.get("decision_context") orelse return error.DecisionContextMissing;
    const original_root = try object(original_context);
    const original_packet = if (original_root.get("decision_context_packet")) |wrapped| try object(wrapped) else original_root;
    const original_contamination_value = original_packet.get("contamination") orelse return error.DecisionContextInvalid;
    const original_contamination = try object(original_contamination_value);
    var contamination_detected = false;
    inline for (.{ "injected_skill_blocks", "generated_reports", "current_audit_prompt", "quoted_material" }) |key| {
        contamination_detected = contamination_detected or try requiredBool(original_contamination, key);
    }
    if (!contamination_detected) return error.SourceTargetTextSanitizationInvalid;
    const original_contamination_json = try retrace_core.dcp_schema.canonicalJsonAlloc(
        allocator,
        original_contamination_value,
        false,
    );
    defer allocator.free(original_contamination_json);
    const original_contamination_fingerprint = try attestation.digestBytesAlloc(allocator, original_contamination_json);
    defer allocator.free(original_contamination_fingerprint);
    const source_witness = try object(profile.get("source_target_text_witness") orelse return error.TargetTextWitnessMissing);
    const source_witness_contamination = try requiredObject(source_witness, "contamination");
    const source_witness_sanitization = try requiredObject(source_witness, "sanitization");
    if (!try requiredBool(source_witness_contamination, "source_target_text_present") or
        !try requiredBool(source_witness_contamination, "within_pre_decision_anchor") or
        !try requiredBool(source_witness_sanitization, "applied") or
        try requiredU64(source_witness_sanitization, "target_instruction_count") != 1 or
        !std.mem.eql(u8, try requiredString(source_witness, "dcp_contamination_fingerprint"), original_contamination_fingerprint))
    {
        return error.SourceTargetTextSanitizationInvalid;
    }

    const sanitized_context = try adapter.sanitizeDecisionContextAlloc(
        allocator,
        original_context,
    );
    defer allocator.free(sanitized_context);
    var sanitized_parsed = try std.json.parseFromSlice(std.json.Value, allocator, sanitized_context, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer sanitized_parsed.deinit();
    const sanitized_fingerprint = try attestation.digestValueAlloc(allocator, sanitized_parsed.value);
    defer allocator.free(sanitized_fingerprint);

    const original = try attestation.canonicalJsonAlloc(allocator, value);
    defer allocator.free(original);
    var prepared_parsed = try std.json.parseFromSlice(std.json.Value, allocator, original, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer prepared_parsed.deinit();
    const prepared = try objectPtr(&prepared_parsed.value);
    try prepared.put(allocator, "decision_context", sanitized_parsed.value);
    try prepared.put(allocator, "decision_context_fingerprint", .{ .string = sanitized_fingerprint });
    const witness_value = prepared.getPtr("source_target_text_witness") orelse return error.TargetTextWitnessMissing;
    const witness = try objectPtr(witness_value);
    const sanitization_value = witness.getPtr("sanitization") orelse return error.TargetTextWitnessMissing;
    const sanitization = try objectPtr(sanitization_value);
    try sanitization.put(allocator, "applied", .{ .bool = true });
    try sanitization.put(allocator, "sanitized_context_fingerprint", .{ .string = sanitized_fingerprint });
    const prepared_json = try attestation.canonicalJsonAlloc(allocator, prepared_parsed.value);
    var verify_parsed = try std.json.parseFromSlice(std.json.Value, allocator, prepared_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer verify_parsed.deinit();
    var report = try adapter.validateHistoricalProfile(
        allocator,
        verify_parsed.value,
        std.mem.eql(u8, split, "holdout"),
    );
    report.deinit(allocator);
    return prepared_json;
}

fn targetTextWitnessAlloc(allocator: std.mem.Allocator, profile: std.json.ObjectMap) !?[]u8 {
    if (std.mem.eql(u8, try requiredString(profile, "kind"), "direct")) return null;
    const witness_value = profile.get("source_target_text_witness") orelse return error.TargetTextWitnessMissing;
    return @as(?[]u8, try attestation.canonicalJsonAlloc(allocator, witness_value));
}

fn validateMaterializedTargetTextWitnessCommitment(
    projected_profile: std.json.ObjectMap,
    observed_fingerprint: []const u8,
) !void {
    if (projected_profile.get("source_target_text_witness") != null) {
        return error.CaseBlindProjectionInvalid;
    }
    const committed = try requiredString(projected_profile, "source_target_text_witness_fingerprint");
    try validateFingerprint(committed);
    if (!std.mem.eql(u8, committed, observed_fingerprint)) {
        return error.TargetTextWitnessCommitmentMismatch;
    }
}

fn sourceProfileProjectionAlloc(allocator: std.mem.Allocator, info: CaseInfo) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, info.source_profile_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const value = parsed.value;
    const profile = try object(value);
    const kind = try requiredString(profile, "kind");
    const case_blind = std.mem.eql(u8, info.visibility, "case_blind");
    if (!case_blind and (std.mem.eql(u8, kind, "direct") or
        !std.mem.eql(u8, try requiredString(profile, "source_target_text_policy"), "strip_and_replace")))
    {
        return allocator.dupe(u8, info.source_profile_json);
    }
    if (std.mem.eql(u8, kind, "direct")) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"kind\":\"direct\",\"source_profile_fingerprint\":{f},\"sealed_payload\":true}}",
            .{std.json.fmt(info.source_profile_fingerprint, .{})},
        );
    }
    const limitations_json = try attestation.canonicalJsonAlloc(
        allocator,
        profile.get("limitations") orelse return error.SourceProfileMissing,
    );
    defer allocator.free(limitations_json);
    if (case_blind) {
        // The controller receives only content commitments.  Full SGG/DCP
        // bodies and their potentially case-identifying locators remain in the
        // encrypted payload delivered directly to the runner.
        const target_text_witness_fingerprint = try attestation.digestBytesAlloc(
            allocator,
            info.target_text_witness.?,
        );
        defer allocator.free(target_text_witness_fingerprint);
        return std.fmt.allocPrint(
            allocator,
            "{{\"kind\":\"historical_decision\",\"source_governance_fingerprint\":{f},\"decision_context_fingerprint\":{f},\"temporal_horizon\":{f},\"source_target_text_policy\":{f},\"retrace_mode\":{f},\"required_lineage\":{f},\"required_fir_version\":{f},\"reconstructability\":{f},\"limitations\":{s},\"source_profile_fingerprint\":{f},\"profile_body_delivery\":\"source_profile_fd\",\"sealed_payload\":true,\"source_target_text_witness_fingerprint\":{f}}}",
            .{
                std.json.fmt(try requiredString(profile, "source_governance_fingerprint"), .{}),
                std.json.fmt(try requiredString(profile, "decision_context_fingerprint"), .{}),
                std.json.fmt(try requiredString(profile, "temporal_horizon"), .{}),
                std.json.fmt(try requiredString(profile, "source_target_text_policy"), .{}),
                std.json.fmt(try requiredString(profile, "retrace_mode"), .{}),
                std.json.fmt(try requiredString(profile, "required_lineage"), .{}),
                std.json.fmt(try requiredString(profile, "required_fir_version"), .{}),
                std.json.fmt(try requiredString(profile, "reconstructability"), .{}),
                limitations_json,
                std.json.fmt(info.source_profile_fingerprint, .{}),
                std.json.fmt(target_text_witness_fingerprint, .{}),
            },
        );
    }
    // strip_and_replace is runner-materialized at every visibility level.  A
    // signed, non-self-referential projection commits to the separately
    // supplied sanitized profile body; CAS verifies the body digest before it
    // can execute the lane.
    return std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"historical_decision\",\"source_governance_ref\":{f},\"source_governance_fingerprint\":{f},\"decision_context_ref\":{f},\"decision_context_fingerprint\":{f},\"temporal_horizon\":{f},\"source_target_text_policy\":{f},\"retrace_mode\":{f},\"required_lineage\":{f},\"required_fir_version\":{f},\"reconstructability\":{f},\"limitations\":{s},\"source_profile_fingerprint\":{f},\"profile_body_delivery\":\"source_profile_fd\",\"source_target_text_witness\":{s}}}",
        .{
            std.json.fmt(try requiredString(profile, "source_governance_ref"), .{}),
            std.json.fmt(try requiredString(profile, "source_governance_fingerprint"), .{}),
            std.json.fmt(try requiredString(profile, "decision_context_ref"), .{}),
            std.json.fmt(try requiredString(profile, "decision_context_fingerprint"), .{}),
            std.json.fmt(try requiredString(profile, "temporal_horizon"), .{}),
            std.json.fmt(try requiredString(profile, "source_target_text_policy"), .{}),
            std.json.fmt(try requiredString(profile, "retrace_mode"), .{}),
            std.json.fmt(try requiredString(profile, "required_lineage"), .{}),
            std.json.fmt(try requiredString(profile, "required_fir_version"), .{}),
            std.json.fmt(try requiredString(profile, "reconstructability"), .{}),
            limitations_json,
            std.json.fmt(info.source_profile_fingerprint, .{}),
            info.target_text_witness.?,
        },
    );
}

fn sourceEpisodeFingerprintAlloc(
    allocator: std.mem.Allocator,
    case: std.json.ObjectMap,
    source_profile: std.json.Value,
    split: []const u8,
) ![]u8 {
    if (case.get("source_episode_fingerprint") != null) {
        return error.CallerSuppliedSourceEpisodeFingerprintForbidden;
    }
    const source_episode_id = try requiredString(case, "source_episode_id");
    return derivedSourceEpisodeFingerprintAlloc(
        allocator,
        source_episode_id,
        source_profile,
        split,
    );
}

fn derivedSourceEpisodeFingerprintAlloc(
    allocator: std.mem.Allocator,
    source_episode_id: []const u8,
    source_profile: std.json.Value,
    split: []const u8,
) ![]u8 {
    const profile = try object(source_profile);
    const kind = try requiredString(profile, "kind");
    if (std.mem.eql(u8, kind, "direct")) {
        return adapter.directSourceEpisodeFingerprintAlloc(allocator, source_episode_id);
    }
    if (!std.mem.eql(u8, kind, "historical_decision")) return error.SourceProfileInvalid;
    var report = try adapter.validateHistoricalProfile(
        allocator,
        source_profile,
        std.mem.eql(u8, split, "holdout"),
    );
    defer report.deinit(allocator);
    return adapter.historicalSourceEpisodeFingerprintAlloc(allocator, source_episode_id, &report);
}

fn anyCaseBlind(cases: std.json.Array, default_visibility: []const u8) !bool {
    for (cases.items) |case_value| {
        const case = try object(case_value);
        if (std.mem.eql(u8, optionalString(case, "case_visibility") orelse default_visibility, "case_blind")) return true;
    }
    return false;
}

fn dependencyKeysAlloc(allocator: std.mem.Allocator, case: std.json.ObjectMap) ![][]u8 {
    var keys: std.ArrayList([]u8) = .empty;
    errdefer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    inline for (.{ "source_episode_id", "mutation_parent_id", "user_task_id", "hidden_oracle_instance_id" }) |key| {
        if (optionalString(case, key)) |value| {
            try keys.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}", .{ key, value }));
        }
    }
    return keys.toOwnedSlice(allocator);
}

fn sharesDependency(left: CaseInfo, right: CaseInfo) bool {
    for (left.dependency_keys) |left_key| for (right.dependency_keys) |right_key| {
        if (std.mem.eql(u8, left_key, right_key)) return true;
    };
    return false;
}

fn connectDependencies(infos: []CaseInfo) !void {
    for (infos, 0..) |_, left| {
        var right = left + 1;
        while (right < infos.len) : (right += 1) {
            if (std.mem.eql(u8, infos[left].source_episode_fingerprint, infos[right].source_episode_fingerprint) or
                sharesDependency(infos[left], infos[right]) or
                jaccardSimilarity(infos[left].normalized_request, infos[right].normalized_request) >= 0.85)
            {
                unionCases(infos, left, right);
            }
        }
    }
    for (infos, 0..) |*info, index| info.cluster_root = find(infos, index);
}

fn find(infos: []CaseInfo, index: usize) usize {
    var current = index;
    while (infos[current].cluster_root != current) current = infos[current].cluster_root;
    return current;
}

fn unionCases(infos: []CaseInfo, left: usize, right: usize) void {
    const left_root = find(infos, left);
    const right_root = find(infos, right);
    if (left_root == right_root) return;
    const root = @min(left_root, right_root);
    infos[left_root].cluster_root = root;
    infos[right_root].cluster_root = root;
}

fn rejectCrossSplitExactDuplicates(infos: []const CaseInfo) !void {
    for (infos, 0..) |left, left_index| {
        for (infos[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.visible_fingerprint, right.visible_fingerprint) and
                !std.mem.eql(u8, left.split, right.split))
            {
                return error.DuplicateSourceAcrossSplits;
            }
            if (std.mem.eql(u8, left.source_episode_fingerprint, right.source_episode_fingerprint) and
                !std.mem.eql(u8, left.split, right.split))
            {
                return error.DuplicateSourceAcrossSplits;
            }
            const left_episode = optionalString(left.object, "source_episode_id");
            const right_episode = optionalString(right.object, "source_episode_id");
            if (left_episode != null and right_episode != null and
                std.mem.eql(u8, left_episode.?, right_episode.?) and
                !std.mem.eql(u8, left.split, right.split))
            {
                return error.DuplicateSourceAcrossSplits;
            }
        }
    }
}

fn rejectCrossSplitDependencyClusters(infos: []const CaseInfo) !void {
    for (infos, 0..) |left, left_index| {
        for (infos[left_index + 1 ..]) |right| {
            if (left.cluster_root == right.cluster_root and
                !std.mem.eql(u8, left.split, right.split))
            {
                return error.DuplicateSourceAcrossSplits;
            }
        }
    }
}

fn validateEmbeddedFingerprint(
    allocator: std.mem.Allocator,
    parent: std.json.ObjectMap,
    value_key: []const u8,
    fingerprint_key: []const u8,
) !void {
    const value = parent.get(value_key) orelse return error.SourceProfileMissing;
    const observed = try attestation.digestValueAlloc(allocator, value);
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, try requiredString(parent, fingerprint_key))) return error.SourceProfileFingerprintMismatch;
}

fn normalizeRequestAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (pending_space and out.items.len != 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, std.ascii.toLower(byte));
        } else pending_space = true;
    }
    return out.toOwnedSlice(allocator);
}

fn jaccardSimilarity(left: []const u8, right: []const u8) f64 {
    var left_tokens = std.mem.tokenizeScalar(u8, left, ' ');
    var intersection: usize = 0;
    var left_count: usize = 0;
    while (left_tokens.next()) |token| {
        if (!isFirstTokenOccurrence(left, token)) continue;
        left_count += 1;
        if (tokenSetContains(right, token)) intersection += 1;
    }
    var right_tokens = std.mem.tokenizeScalar(u8, right, ' ');
    var right_count: usize = 0;
    while (right_tokens.next()) |token| if (isFirstTokenOccurrence(right, token)) {
        right_count += 1;
    };
    const union_count = left_count + right_count - intersection;
    return if (union_count == 0) 1.0 else @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(union_count));
}

fn isFirstTokenOccurrence(text: []const u8, token: []const u8) bool {
    const offset = @intFromPtr(token.ptr) - @intFromPtr(text.ptr);
    var prior = std.mem.tokenizeScalar(u8, text[0..offset], ' ');
    while (prior.next()) |candidate| if (std.mem.eql(u8, token, candidate)) return false;
    return true;
}

fn tokenSetContains(text: []const u8, token: []const u8) bool {
    var tokens = std.mem.tokenizeScalar(u8, text, ' ');
    while (tokens.next()) |candidate| if (std.mem.eql(u8, token, candidate)) return true;
    return false;
}

fn countClusters(infos: []const CaseInfo) usize {
    var count: usize = 0;
    for (infos, 0..) |info, index| if (info.cluster_root == index) {
        count += 1;
    };
    return count;
}

fn countSplit(infos: []const CaseInfo, split: []const u8) usize {
    var count: usize = 0;
    for (infos) |info| if (std.mem.eql(u8, info.split, split)) {
        count += 1;
    };
    return count;
}

fn countExactPairs(infos: []const CaseInfo) usize {
    var count: usize = 0;
    for (infos, 0..) |left, index| for (infos[index + 1 ..]) |right| if (std.mem.eql(u8, left.visible_fingerprint, right.visible_fingerprint)) {
        count += 1;
    };
    return count;
}

fn countNearPairs(infos: []const CaseInfo) usize {
    var count: usize = 0;
    for (infos, 0..) |left, index| for (infos[index + 1 ..]) |right| {
        const similarity = jaccardSimilarity(left.normalized_request, right.normalized_request);
        if (similarity >= 0.85 and !std.mem.eql(u8, left.visible_fingerprint, right.visible_fingerprint)) count += 1;
    };
    return count;
}

fn clusterIdAlloc(allocator: std.mem.Allocator, infos: []const CaseInfo, root: usize) ![]u8 {
    var minimum = infos[root].visible_fingerprint;
    for (infos) |info| if (info.cluster_root == root and std.mem.lessThan(u8, info.visible_fingerprint, minimum)) {
        minimum = info.visible_fingerprint;
    };
    return std.fmt.allocPrint(allocator, "cluster-{s}", .{minimum[7..23]});
}

const SealedArtifact = struct { ref: []u8, json: []u8, fingerprint: []u8 };

fn sealCaseAlloc(allocator: std.mem.Allocator, info: CaseInfo, key: [32]u8, sealed_dir: []const u8) !SealedArtifact {
    try std.Io.Dir.cwd().createDirPath(defaultIo(), sealed_dir);
    const visible = try attestation.canonicalJsonAlloc(allocator, info.object.get("visible_input").?);
    defer allocator.free(visible);
    const hidden = try attestation.canonicalJsonAlloc(allocator, info.object.get("hidden_reference") orelse std.json.Value.null);
    defer allocator.free(hidden);
    const source_profile = info.source_profile_json;
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-sealed-case-payload/v1\",\"unit_id\":{f},\"scenario_id\":{f},\"source_episode_id\":{f},\"source_episode_projection_version\":{f},\"source_episode_fingerprint\":{f},\"visible_input\":{s},\"hidden_reference\":{s},\"source_profile\":{s}}}",
        .{ std.json.fmt(info.unit_id, .{}), std.json.fmt(info.scenario_id, .{}), std.json.fmt(try requiredString(info.object, "source_episode_id"), .{}), std.json.fmt(adapter.source_episode_projection_version, .{}), std.json.fmt(info.source_episode_fingerprint, .{}), visible, hidden, source_profile },
    );
    defer allocator.free(payload);
    var nonce: [Cipher.nonce_length]u8 = undefined;
    try std.Io.randomSecure(defaultIo(), &nonce);
    const ciphertext = try allocator.alloc(u8, payload.len);
    defer allocator.free(ciphertext);
    var tag: [Cipher.tag_length]u8 = undefined;
    Cipher.encrypt(ciphertext, &tag, payload, info.unit_id, nonce, key);
    const nonce64 = try base64EncodeAlloc(allocator, &nonce);
    defer allocator.free(nonce64);
    const ciphertext64 = try base64EncodeAlloc(allocator, ciphertext);
    defer allocator.free(ciphertext64);
    const tag64 = try base64EncodeAlloc(allocator, &tag);
    defer allocator.free(tag64);
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-sealed-case-ciphertext/v1\",\"unit_id\":{f},\"scenario_id\":{f},\"visible_input_fingerprint\":{f},\"hidden_reference_fingerprint\":{f},\"source_episode_projection_version\":{f},\"source_episode_fingerprint\":{f},\"source_profile_fingerprint\":{f},\"algorithm\":\"xchacha20-poly1305\",\"nonce_base64\":{f},\"ciphertext_base64\":{f},\"tag_base64\":{f}}}",
        .{ std.json.fmt(info.unit_id, .{}), std.json.fmt(info.scenario_id, .{}), std.json.fmt(info.visible_fingerprint, .{}), std.json.fmt(info.hidden_fingerprint, .{}), std.json.fmt(adapter.source_episode_projection_version, .{}), std.json.fmt(info.source_episode_fingerprint, .{}), std.json.fmt(info.source_profile_fingerprint, .{}), std.json.fmt(nonce64, .{}), std.json.fmt(ciphertext64, .{}), std.json.fmt(tag64, .{}) },
    );
    const ref = try std.fmt.allocPrint(allocator, "{s}/{s}.sealed.json", .{ sealed_dir, info.unit_id });
    return .{ .ref = ref, .fingerprint = try digestJsonTextAlloc(allocator, json), .json = json };
}

fn decryptCaseAlloc(allocator: std.mem.Allocator, envelope: std.json.ObjectMap, key: [32]u8) ![]u8 {
    const nonce_bytes = try base64DecodeAlloc(allocator, try requiredString(envelope, "nonce_base64"));
    defer allocator.free(nonce_bytes);
    const ciphertext = try base64DecodeAlloc(allocator, try requiredString(envelope, "ciphertext_base64"));
    defer allocator.free(ciphertext);
    const tag_bytes = try base64DecodeAlloc(allocator, try requiredString(envelope, "tag_base64"));
    defer allocator.free(tag_bytes);
    if (nonce_bytes.len != Cipher.nonce_length or tag_bytes.len != Cipher.tag_length) return error.SealedCaseInvalid;
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    const nonce: [Cipher.nonce_length]u8 = nonce_bytes[0..Cipher.nonce_length].*;
    const tag: [Cipher.tag_length]u8 = tag_bytes[0..Cipher.tag_length].*;
    Cipher.decrypt(plaintext, ciphertext, tag, try requiredString(envelope, "unit_id"), nonce, key) catch return error.SealedCaseAuthenticationFailed;
    return plaintext;
}

const TrialLane = struct { unit_id: []const u8, scenario_id: []const u8, arm_id: []const u8 };

fn findTrialLane(trial: std.json.ObjectMap, lane_id: []const u8) !TrialLane {
    const units = try requiredArray(trial, "units");
    var found: ?TrialLane = null;
    for (units.items) |unit_value| {
        const unit = try object(unit_value);
        for ((try requiredArray(unit, "pairs")).items) |pair_value| {
            const lanes = try requiredObject(try object(pair_value), "lanes");
            var iterator = lanes.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, try requiredString(try object(entry.value_ptr.*), "lane_id"), lane_id)) {
                    if (found != null) return error.DuplicateLane;
                    found = .{ .unit_id = try requiredString(unit, "unit_id"), .scenario_id = try requiredString(unit, "scenario_id"), .arm_id = entry.key_ptr.* };
                }
            }
        }
    }
    return found orelse error.LaneNotRegistered;
}

fn validateMaterializerAuthority(allocator: std.mem.Allocator, trial: std.json.ObjectMap, producer_id: []const u8, key_id: []const u8, seed: [32]u8) !void {
    const trust = try requiredObject(try requiredObject(trial, "assurance"), "trust_policy");
    const public_key = try attestation.publicKeyBase64Alloc(allocator, seed);
    defer allocator.free(public_key);
    for ((try requiredArray(trust, "keys")).items) |key_value| {
        const entry = try object(key_value);
        if (!std.mem.eql(u8, try requiredString(entry, "key_id"), key_id)) continue;
        if (!std.mem.eql(u8, try requiredString(entry, "public_key_base64"), public_key) or
            !arrayContains(try requiredArray(entry, "allowed_roles"), "materializer") or
            !arrayContains(try requiredArray(entry, "producer_ids"), producer_id))
        {
            return error.MaterializerKeyUnauthorized;
        }
        return;
    }
    return error.MaterializerKeyUnauthorized;
}

fn sourceOwnerAttestationAlloc(
    allocator: std.mem.Allocator,
    selection_core: []const u8,
    campaign_id: []const u8,
    options: Options,
    binary_fingerprint: []const u8,
    seed: [32]u8,
) ![]u8 {
    var core_parsed = try std.json.parseFromSlice(std.json.Value, allocator, selection_core, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer core_parsed.deinit();
    const selection_fingerprint = try attestation.digestValueAlloc(allocator, core_parsed.value);
    defer allocator.free(selection_fingerprint);
    const public_key = try attestation.publicKeyBase64Alloc(allocator, seed);
    defer allocator.free(public_key);
    const unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-source-selection-attestation-subject/v1\",\"campaign_id\":{f},\"selection_fingerprint\":{f},\"producer\":{{\"id\":{f},\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":{f},\"public_key_base64\":{f}}},\"attestation\":null}}",
        .{
            std.json.fmt(campaign_id, .{}),
            std.json.fmt(selection_fingerprint, .{}),
            std.json.fmt(options.source_owner_id, .{}),
            std.json.fmt(binary_fingerprint, .{}),
            std.json.fmt(options.source_owner_key_id, .{}),
            std.json.fmt(public_key, .{}),
        },
    );
    defer allocator.free(unsigned);
    return attestation.signReceiptAlloc(allocator, unsigned, .{
        .id = options.source_owner_id,
        .version = "v1",
        .binary_fingerprint = binary_fingerprint,
        .key_id = options.source_owner_key_id,
    }, "source_owner", unixSeconds(), seed);
}

fn validateSourceOwnerAttestation(
    allocator: std.mem.Allocator,
    receipt: std.json.ObjectMap,
    trial: std.json.ObjectMap,
) !void {
    const subject_value = receipt.get("source_owner_attestation") orelse return error.SourceOwnerAttestationMissing;
    const subject = try object(subject_value);
    if (!std.mem.eql(u8, try requiredString(subject, "schema"), "hylo-source-selection-attestation-subject/v1") or
        !std.mem.eql(u8, try requiredString(subject, "campaign_id"), try requiredString(receipt, "campaign_id")) or
        !std.mem.eql(u8, try requiredString(subject, "campaign_id"), try requiredString(trial, "campaign_id")))
    {
        return error.SourceOwnerAttestationInvalid;
    }
    const core_json = try canonicalObjectOmittingKeysAlloc(allocator, receipt, &.{ "receipt_fingerprint", "source_owner_attestation" });
    defer allocator.free(core_json);
    const core_fingerprint = try attestation.digestBytesAlloc(allocator, core_json);
    defer allocator.free(core_fingerprint);
    if (!std.mem.eql(u8, core_fingerprint, try requiredString(subject, "selection_fingerprint"))) {
        return error.SourceOwnerAttestationInvalid;
    }
    const producer = try requiredObject(subject, "producer");
    const attestation_object = try requiredObject(subject, "attestation");
    if (!std.mem.eql(u8, try requiredString(attestation_object, "schema"), "hylo-attestation/v1") or
        !std.mem.eql(u8, try requiredString(attestation_object, "subject_schema"), "hylo-source-selection-attestation-subject/v1") or
        !std.mem.eql(u8, try requiredString(attestation_object, "producer_id"), try requiredString(producer, "id")) or
        !std.mem.eql(u8, try requiredString(attestation_object, "producer_version"), try requiredString(producer, "version")) or
        !std.mem.eql(u8, try requiredString(attestation_object, "binary_fingerprint"), try requiredString(producer, "binary_fingerprint")) or
        !std.mem.eql(u8, try requiredString(attestation_object, "key_id"), try requiredString(producer, "key_id")) or
        !std.mem.eql(u8, try requiredString(attestation_object, "role"), "source_owner"))
    {
        return error.SourceOwnerAttestationInvalid;
    }
    const subject_fingerprint = try attestation.subjectFingerprintAlloc(allocator, subject_value);
    defer allocator.free(subject_fingerprint);
    if (!std.mem.eql(u8, subject_fingerprint, try requiredString(attestation_object, "subject_fingerprint"))) {
        return error.SourceOwnerAttestationInvalid;
    }
    const assurance = try requiredObject(trial, "assurance");
    const trust_policy = try requiredObject(assurance, "trust_policy");
    var trusted_key: ?std.json.ObjectMap = null;
    for ((try requiredArray(trust_policy, "keys")).items) |key_value| {
        const key = try object(key_value);
        if (!std.mem.eql(u8, try requiredString(key, "key_id"), try requiredString(producer, "key_id"))) continue;
        if (trusted_key != null) return error.SourceOwnerAuthorityInvalid;
        trusted_key = key;
    }
    const key = trusted_key orelse return error.SourceOwnerAuthorityInvalid;
    if (!arrayContains(try requiredArray(key, "allowed_roles"), "source_owner") or
        !arrayContains(try requiredArray(key, "producer_ids"), try requiredString(producer, "id")) or
        !arrayContains(try requiredArray(key, "producer_binary_fingerprints"), try requiredString(producer, "binary_fingerprint")) or
        !std.mem.eql(u8, try requiredString(key, "public_key_base64"), try requiredString(producer, "public_key_base64")))
    {
        return error.SourceOwnerAuthorityInvalid;
    }
    const public_key_bytes = try base64DecodeAlloc(allocator, try requiredString(key, "public_key_base64"));
    defer allocator.free(public_key_bytes);
    const signature_object = try requiredObject(attestation_object, "signature");
    if (!std.mem.eql(u8, try requiredString(signature_object, "algorithm"), "ed25519")) return error.SourceOwnerAttestationInvalid;
    const signature_bytes = try base64DecodeAlloc(allocator, try requiredString(signature_object, "value_base64"));
    defer allocator.free(signature_bytes);
    if (public_key_bytes.len != std.crypto.sign.Ed25519.PublicKey.encoded_length or
        signature_bytes.len != std.crypto.sign.Ed25519.Signature.encoded_length) return error.SourceOwnerAttestationInvalid;
    const public_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key_bytes[0..std.crypto.sign.Ed25519.PublicKey.encoded_length].*) catch return error.SourceOwnerAttestationInvalid;
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(signature_bytes[0..std.crypto.sign.Ed25519.Signature.encoded_length].*);
    const preimage = try attestationPreimageAllocLocal(allocator, attestation_object);
    defer allocator.free(preimage);
    signature.verifyStrict(preimage, public_key) catch return error.SourceOwnerAttestationInvalid;
}

fn attestationPreimageAllocLocal(allocator: std.mem.Allocator, value: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = value.iterator();
    while (iterator.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    sortKeys(keys.items);
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, &out.writer);
        try out.writer.writeByte(':');
        if (std.mem.eql(u8, key, "signature")) {
            const signature = try object(value.get(key).?);
            const signature_json = try canonicalObjectOmittingKeysAlloc(allocator, signature, &.{"value_base64"});
            defer allocator.free(signature_json);
            try out.writer.writeAll(signature_json);
        } else {
            const json = try attestation.canonicalJsonAlloc(allocator, value.get(key).?);
            defer allocator.free(json);
            try out.writer.writeAll(json);
        }
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn canonicalObjectOmittingKeysAlloc(
    allocator: std.mem.Allocator,
    value: std.json.ObjectMap,
    omitted: []const []const u8,
) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = value.iterator();
    while (iterator.next()) |entry| {
        var skip = false;
        for (omitted) |omitted_key| if (std.mem.eql(u8, entry.key_ptr.*, omitted_key)) {
            skip = true;
            break;
        };
        if (!skip) try keys.append(allocator, entry.key_ptr.*);
    }
    sortKeys(keys.items);
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, &out.writer);
        try out.writer.writeByte(':');
        const json = try attestation.canonicalJsonAlloc(allocator, value.get(key).?);
        defer allocator.free(json);
        try out.writer.writeAll(json);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn sortKeys(keys: [][]const u8) void {
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

fn appendJsonMemberAlloc(
    allocator: std.mem.Allocator,
    body: []const u8,
    key: []const u8,
    value_json: []const u8,
) ![]u8 {
    if (body.len == 0 or body[body.len - 1] != '}') return error.SourceReceiptInvalid;
    return std.fmt.allocPrint(
        allocator,
        "{s},{f}:{s}}}",
        .{ body[0 .. body.len - 1], std.json.fmt(key, .{}), value_json },
    );
}

fn statFd(fd: std.posix.fd_t) !std.c.Stat {
    if (fd < 3) return error.InvalidFd;
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0) return error.FdStatFailed;
    return stat;
}

const SensitiveEndpointAccess = enum { input, output };

fn sameFdEndpoint(expected: std.c.Stat, fd: std.posix.fd_t) bool {
    var actual: std.c.Stat = undefined;
    if (std.c.fstat(fd, &actual) != 0) return false;
    return expected.dev == actual.dev and expected.ino == actual.ino;
}

fn isAnonymousSensitiveEndpoint(fd: std.posix.fd_t, expected_access: SensitiveEndpointAccess) bool {
    const endpoint = statFd(fd) catch return false;
    if (sameFdEndpoint(endpoint, std.posix.STDIN_FILENO) or
        sameFdEndpoint(endpoint, std.posix.STDOUT_FILENO) or
        sameFdEndpoint(endpoint, std.posix.STDERR_FILENO))
    {
        return false;
    }
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return false;
    const flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    const access_valid = switch (expected_access) {
        .input => flags.ACCMODE == .RDONLY,
        .output => flags.ACCMODE == .WRONLY,
    };
    return std.c.S.ISFIFO(endpoint.mode) and endpoint.nlink == 0 and access_valid;
}

fn validateManifestInputEndpoint(fd: std.posix.fd_t) !void {
    if (!isAnonymousSensitiveEndpoint(fd, .input)) return error.ManifestEndpointUnbound;
}

fn validateKeyInputEndpoint(fd: std.posix.fd_t) !void {
    if (!isAnonymousSensitiveEndpoint(fd, .input)) return error.KeyEndpointUnbound;
}

fn validatePrivateKeyCapability(fd: std.posix.fd_t) !void {
    if (!isAnonymousSensitiveEndpoint(fd, .output)) return error.PrivateKeySinkInvalid;
}

fn validateDistinctSensitiveEndpoints(fds: []const std.posix.fd_t) !void {
    for (fds, 0..) |left_fd, left_index| {
        const left = try statFd(left_fd);
        for (fds[left_index + 1 ..]) |right_fd| {
            if (sameFdEndpoint(left, right_fd)) return error.SensitiveEndpointAlias;
        }
    }
}

fn appendFingerprintAlloc(allocator: std.mem.Allocator, body: []const u8, fingerprint: []const u8) ![]u8 {
    if (body.len == 0 or body[body.len - 1] != '}') return error.SourceReceiptInvalid;
    return std.fmt.allocPrint(allocator, "{s},\"receipt_fingerprint\":{f}}}\n", .{ body[0 .. body.len - 1], std.json.fmt(fingerprint, .{}) });
}

fn fingerprintOmittingAlloc(allocator: std.mem.Allocator, root: std.json.ObjectMap, omitted: []const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = root.iterator();
    while (iterator.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, omitted)) try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    try writer.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try writer.writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, &writer.writer);
        try writer.writer.writeByte(':');
        const value_json = try attestation.canonicalJsonAlloc(allocator, root.get(key).?);
        defer allocator.free(value_json);
        try writer.writer.writeAll(value_json);
    }
    try writer.writer.writeByte('}');
    const canonical = try writer.toOwnedSlice();
    defer allocator.free(canonical);
    return attestation.digestBytesAlloc(allocator, canonical);
}

fn containsPersistedSecret(text: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, text, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return portable_credentials.contains(text);
    defer parsed.deinit();
    return jsonContainsPersistedSecret(parsed.value);
}

fn jsonContainsPersistedSecret(value: std.json.Value) bool {
    return switch (value) {
        .string => |text| portable_credentials.contains(text),
        .array => |items| result: {
            for (items.items) |item| {
                if (jsonContainsPersistedSecret(item)) break :result true;
            }
            break :result false;
        },
        .object => |map| result: {
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                const public_protocol_reference = std.mem.eql(u8, key, "ciphertext_or_capability_ref");
                if ((!public_protocol_reference and portable_credentials.isSensitiveJsonKey(key)) or
                    jsonContainsPersistedSecret(entry.value_ptr.*))
                {
                    break :result true;
                }
            }
            break :result false;
        },
        else => false,
    };
}

fn readKey(fd: std.posix.fd_t) ![32]u8 {
    try validateKeyInputEndpoint(fd);
    var raw: [33]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw);
    var used: usize = 0;
    while (used < raw.len) {
        const count = try std.posix.read(fd, raw[used..]);
        if (count == 0) break;
        used += count;
    }
    if (used != 32) return error.KeyInvalid;
    return raw[0..32].*;
}

fn readFdAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, limit: usize) ![]u8 {
    try validateManifestInputEndpoint(fd);
    var raw: std.ArrayList(u8) = .empty;
    errdefer {
        std.crypto.secureZero(u8, raw.items);
        raw.deinit(allocator);
    }
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    while (true) {
        const remaining = limit - raw.items.len;
        const read_limit = @min(buffer.len, remaining +| 1);
        const count = try std.posix.read(fd, buffer[0..read_limit]);
        if (count == 0) break;
        if (count > remaining) return error.FdInputTooLarge;
        try raw.appendSlice(allocator, buffer[0..count]);
    }
    if (raw.items.len == 0) return error.EmptyFd;
    return raw.toOwnedSlice(allocator);
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    if (!isAnonymousSensitiveEndpoint(fd, .output)) return error.SensitiveOutputEndpointUnbound;
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    try file.writeStreamingAll(defaultIo(), bytes);
}

fn base64EncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(result, bytes);
    return result;
}

fn base64DecodeAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(raw) catch return error.Base64Invalid;
    const result = try allocator.alloc(u8, size);
    errdefer allocator.free(result);
    std.base64.standard.Decoder.decode(result, raw) catch return error.Base64Invalid;
    return result;
}

fn digestJsonTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return attestation.digestValueAlloc(allocator, parsed.value);
}

fn materializationCapabilityDigestAlloc(
    allocator: std.mem.Allocator,
    trial_id: []const u8,
    lane_id: []const u8,
    unit_id: []const u8,
    materializer_key_id: []const u8,
    runner_key_id: []const u8,
) ![]u8 {
    const preimage = try std.fmt.allocPrint(
        allocator,
        "hctp-case-capability/v1\x00{s}\x00{s}\x00{s}\x00{s}\x00{s}",
        .{ trial_id, lane_id, unit_id, materializer_key_id, runner_key_id },
    );
    defer allocator.free(preimage);
    return attestation.digestBytesAlloc(allocator, preimage);
}

fn currentExecutableFingerprintAlloc(allocator: std.mem.Allocator) ![]u8 {
    const path = try std.process.executablePathAlloc(defaultIo(), allocator);
    defer allocator.free(path);
    const raw = try readFileAlloc(allocator, path);
    defer allocator.free(raw);
    return attestation.digestBytesAlloc(allocator, raw);
}

fn unixSeconds() i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(defaultIo()).nanoseconds, std.time.ns_per_s));
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(defaultIo(), path, .{})
    else
        try std.Io.Dir.cwd().openFile(defaultIo(), path, .{});
    defer file.close(defaultIo());
    var reader = file.reader(defaultIo(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
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

fn optionalString(parent: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = parent.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn requiredString(parent: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return optionalString(parent, key) orelse error.MissingField;
}

fn requiredBool(parent: std.json.ObjectMap, key: []const u8) !bool {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.ExpectedBool,
    };
}

fn requiredU64(parent: std.json.ObjectMap, key: []const u8) !u64 {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.ExpectedUnsigned,
        else => error.ExpectedUnsigned,
    };
}

fn validateId(value: []const u8) !void {
    if (value.len == 0) return error.InvalidId;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return error.InvalidId;
}

fn validateFingerprint(value: []const u8) !void {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return error.FingerprintInvalid;
    for (value[7..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.FingerprintInvalid;
}

fn validateOpaqueContentAddressedRef(value: []const u8) !void {
    const fingerprint = if (std.mem.startsWith(u8, value, "artifact:sha256:"))
        value["artifact:".len..]
    else if (std.mem.startsWith(u8, value, "sha256:"))
        value
    else
        return error.SealedProfileReferenceInvalid;
    try validateFingerprint(fingerprint);
}

fn oneOf(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn arrayContains(array: std.json.Array, wanted: []const u8) bool {
    for (array.items) |value| switch (value) {
        .string => |text| if (std.mem.eql(u8, text, wanted)) return true,
        else => {},
    };
    return false;
}

fn writeStringMember(writer: anytype, key: []const u8, value: []const u8, comma: bool) !void {
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
    if (comma) try writer.writeByte(',');
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn printReceipt(value: anytype) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &stdout_writer.interface);
    try stdout_writer.interface.writeByte('\n');
}

test "final sanitization recognizes bounded known-secret forms" {
    for ([_][]const u8{
        "ghp_0123456789abcdef",
        "AKIAIOSFODNN7EXAMPLE",
        "Authorization: Bearer TOPSECRET123",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature_bytes",
        "postgresql://app:supersecret@example.invalid/database",
        "https://deploy-token@example.invalid/repository",
        "{\"ciphertext_or_capability_ref\":\"https://deploy-token@example.invalid/repository\"}",
        "{\"password\":\"synthetic\"}",
    }) |secret| {
        try std.testing.expect(containsPersistedSecret(secret));
    }

    for ([_][]const u8{
        "bearer token authentication",
        "https://example.invalid/path",
        "token_count max_tokens",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "AKIAX is not an AWS access key",
        "ghp_x is not a complete GitHub token",
        "{\"ciphertext_or_capability_ref\":\"sealed/case-one.json\"}",
    }) |benign| {
        try std.testing.expect(!containsPersistedSecret(benign));
    }
}

test "HCTP source compilation rejects a portable known secret" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const manifest =
        "{\"schema\":\"hylo-source-selection-request/v1\",\"campaign_id\":\"campaign-secret\",\"cases\":[" ++
        "{\"unit_id\":\"unit-secret\",\"scenario_id\":\"scenario-secret\",\"split\":\"practice\"," ++
        "\"source_episode_id\":\"episode-secret\",\"visible_input\":{\"request\":\"ghp_0123456789abcdef\"}," ++
        "\"hidden_reference\":null,\"source_profile\":{\"kind\":\"direct\"}}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest.json", .data = manifest });
    const manifest_path = try tmp.dir.realPathFileAlloc(std.testing.io, "manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(manifest_path);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root, "selection.json" });
    defer std.testing.allocator.free(output_path);

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    const seed = [_]u8{0x51} ** 32;
    try std.testing.expectEqual(@as(isize, seed.len), std.c.write(fds[1], &seed, seed.len));
    _ = std.c.close(fds[1]);

    try std.testing.expectError(error.FinalSanitizationFailed, cmdCompile(std.testing.allocator, .{
        .action = .compile,
        .manifest = manifest_path,
        .output = output_path,
        .source_signing_seed_fd = fds[0],
    }));
}

test "HCTP source compilation requires exactly one manifest carrier" {
    try std.testing.expectError(error.MissingManifest, cmdCompile(std.testing.allocator, .{
        .action = .compile,
        .output = "unused.json",
    }));
    try std.testing.expectError(error.ManifestSourceConflict, cmdCompile(std.testing.allocator, .{
        .action = .compile,
        .manifest = "unused.json",
        .manifest_fd = 3,
        .output = "unused.json",
    }));
}

test "failed seal key delivery publishes no sealed source artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const manifest =
        "{\"schema\":\"hylo-source-selection-request/v1\",\"campaign_id\":\"campaign-key-failure\"," ++
        "\"case_visibility\":\"case_blind\",\"cases\":[{" ++
        "\"unit_id\":\"unit-key-failure\",\"scenario_id\":\"scenario-key-failure\",\"split\":\"holdout\"," ++
        "\"source_episode_id\":\"episode-key-failure\",\"visible_input\":{\"request\":\"evaluate the candidate\"}," ++
        "\"hidden_reference\":{\"answer\":\"sealed\"},\"source_profile\":{\"kind\":\"direct\"}}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest.json", .data = manifest });
    const manifest_path = try tmp.dir.realPathFileAlloc(std.testing.io, "manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(manifest_path);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root, "selection.json" });
    defer std.testing.allocator.free(output_path);
    const sealed_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "sealed" });
    defer std.testing.allocator.free(sealed_dir);

    var seed_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&seed_fds));
    defer _ = std.c.close(seed_fds[0]);
    const seed = [_]u8{0x51} ** 32;
    try std.testing.expectEqual(@as(isize, seed.len), std.c.write(seed_fds[1], &seed, seed.len));
    _ = std.c.close(seed_fds[1]);

    var key_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&key_fds));
    defer _ = std.c.close(key_fds[1]);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(key_fds[1], std.c.F.SETNOSIGPIPE, @as(c_int, 1)));
    _ = std.c.close(key_fds[0]);

    try std.testing.expectError(error.BrokenPipe, cmdCompile(std.testing.allocator, .{
        .action = .compile,
        .manifest = manifest_path,
        .output = output_path,
        .sealed_dir = sealed_dir,
        .seal_key_output_fd = key_fds[1],
        .source_signing_seed_fd = seed_fds[0],
    }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "selection.json", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "sealed", .{}));
}

test "Jaccard similarity is symmetric unique-token set similarity" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), jaccardSimilarity("alpha alpha", "alpha beta"), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), jaccardSimilarity("alpha beta", "alpha alpha"), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), jaccardSimilarity("alpha alpha", "alpha"), 0.000001);
}

test "repeated tokens do not create a false dependency cluster" {
    var infos = [_]CaseInfo{
        .{ .object = undefined, .unit_id = "u1", .scenario_id = "s1", .split = "practice", .visibility = "open", .visible_fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), .hidden_fingerprint = @constCast("sha256:1111111111111111111111111111111111111111111111111111111111111111"), .source_episode_fingerprint = @constCast("sha256:1313131313131313131313131313131313131313131313131313131313131313"), .source_profile_fingerprint = @constCast("sha256:3333333333333333333333333333333333333333333333333333333333333333"), .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = @constCast("alpha alpha"), .dependency_keys = &.{}, .cluster_root = 0 },
        .{ .object = undefined, .unit_id = "u2", .scenario_id = "s2", .split = "practice", .visibility = "open", .visible_fingerprint = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), .hidden_fingerprint = @constCast("sha256:2222222222222222222222222222222222222222222222222222222222222222"), .source_episode_fingerprint = @constCast("sha256:1414141414141414141414141414141414141414141414141414141414141414"), .source_profile_fingerprint = @constCast("sha256:4444444444444444444444444444444444444444444444444444444444444444"), .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = @constCast("alpha beta"), .dependency_keys = &.{}, .cluster_root = 1 },
    };
    try connectDependencies(&infos);
    try std.testing.expectEqual(@as(usize, 2), countClusters(&infos));
}

test "dependency closure clusters near duplicates but keeps the denominator" {
    var dependencies_one = [_][]u8{@constCast("incident:a")};
    var dependencies_two = [_][]u8{@constCast("incident:b")};
    var infos = [_]CaseInfo{
        .{ .object = undefined, .unit_id = "u1", .scenario_id = "s1", .split = "practice", .visibility = "open", .visible_fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), .hidden_fingerprint = @constCast("sha256:1111111111111111111111111111111111111111111111111111111111111111"), .source_episode_fingerprint = @constCast("sha256:1313131313131313131313131313131313131313131313131313131313131313"), .source_profile_fingerprint = @constCast("sha256:3333333333333333333333333333333333333333333333333333333333333333"), .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = @constCast("choose the safe deployment route right now"), .dependency_keys = &dependencies_one, .cluster_root = 0 },
        .{ .object = undefined, .unit_id = "u2", .scenario_id = "s2", .split = "practice", .visibility = "open", .visible_fingerprint = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), .hidden_fingerprint = @constCast("sha256:2222222222222222222222222222222222222222222222222222222222222222"), .source_episode_fingerprint = @constCast("sha256:1414141414141414141414141414141414141414141414141414141414141414"), .source_profile_fingerprint = @constCast("sha256:4444444444444444444444444444444444444444444444444444444444444444"), .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = @constCast("choose the safe deployment route right now please"), .dependency_keys = &dependencies_two, .cluster_root = 1 },
    };
    try connectDependencies(&infos);
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expectEqual(@as(usize, 1), countClusters(&infos));
}

test "one source episode fingerprint denotes one cluster and cannot cross splits" {
    const shared_episode = @constCast("sha256:1515151515151515151515151515151515151515151515151515151515151515");
    var infos = [_]CaseInfo{
        .{ .object = undefined, .unit_id = "u1", .scenario_id = "s1", .split = "practice", .visibility = "open", .visible_fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), .hidden_fingerprint = @constCast("sha256:1111111111111111111111111111111111111111111111111111111111111111"), .source_episode_fingerprint = shared_episode, .source_profile_fingerprint = @constCast("sha256:3333333333333333333333333333333333333333333333333333333333333333"), .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = @constCast("unrelated alpha request"), .dependency_keys = &.{}, .cluster_root = 0 },
        .{ .object = undefined, .unit_id = "u2", .scenario_id = "s2", .split = "practice", .visibility = "result_blind", .visible_fingerprint = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), .hidden_fingerprint = @constCast("sha256:2222222222222222222222222222222222222222222222222222222222222222"), .source_episode_fingerprint = shared_episode, .source_profile_fingerprint = @constCast("sha256:4444444444444444444444444444444444444444444444444444444444444444"), .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = @constCast("orthogonal omega request"), .dependency_keys = &.{}, .cluster_root = 1 },
    };
    try connectDependencies(&infos);
    try std.testing.expectEqual(@as(usize, 1), countClusters(&infos));
    try rejectCrossSplitExactDuplicates(&infos);

    infos[1].split = "holdout";
    try std.testing.expectError(
        error.DuplicateSourceAcrossSplits,
        rejectCrossSplitExactDuplicates(&infos),
    );
}

test "dependency closure unions every declared dependency dimension" {
    const left_raw = "{\"source_episode_id\":\"episode-a\",\"user_task_id\":\"task-shared\"}";
    const right_raw = "{\"source_episode_id\":\"episode-b\",\"user_task_id\":\"task-shared\"}";
    var left = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, left_raw, .{});
    defer left.deinit();
    var right = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, right_raw, .{});
    defer right.deinit();
    const left_keys = try dependencyKeysAlloc(std.testing.allocator, try object(left.value));
    defer {
        for (left_keys) |key| std.testing.allocator.free(key);
        std.testing.allocator.free(left_keys);
    }
    const right_keys = try dependencyKeysAlloc(std.testing.allocator, try object(right.value));
    defer {
        for (right_keys) |key| std.testing.allocator.free(key);
        std.testing.allocator.free(right_keys);
    }
    try std.testing.expect(sharesDependency(
        .{ .object = undefined, .unit_id = "u1", .scenario_id = "s1", .split = "practice", .visibility = "open", .visible_fingerprint = undefined, .hidden_fingerprint = undefined, .source_episode_fingerprint = undefined, .source_profile_fingerprint = undefined, .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = undefined, .dependency_keys = left_keys, .cluster_root = 0 },
        .{ .object = undefined, .unit_id = "u2", .scenario_id = "s2", .split = "practice", .visibility = "open", .visible_fingerprint = undefined, .hidden_fingerprint = undefined, .source_episode_fingerprint = undefined, .source_profile_fingerprint = undefined, .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = undefined, .dependency_keys = right_keys, .cluster_root = 1 },
    ));
}

test "dependency clusters cannot cross practice holdout or challenge" {
    var shared_dependencies_one = [_][]u8{@constCast("user_task_id:task-shared")};
    var shared_dependencies_two = [_][]u8{@constCast("user_task_id:task-shared")};
    var infos = [_]CaseInfo{
        .{ .object = undefined, .unit_id = "u1", .scenario_id = "s1", .split = "practice", .visibility = "open", .visible_fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), .hidden_fingerprint = @constCast("sha256:1111111111111111111111111111111111111111111111111111111111111111"), .source_episode_fingerprint = @constCast("sha256:1313131313131313131313131313131313131313131313131313131313131313"), .source_profile_fingerprint = @constCast("sha256:3333333333333333333333333333333333333333333333333333333333333333"), .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = @constCast("alpha request"), .dependency_keys = &shared_dependencies_one, .cluster_root = 0 },
        .{ .object = undefined, .unit_id = "u2", .scenario_id = "s2", .split = "holdout", .visibility = "case_blind", .visible_fingerprint = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), .hidden_fingerprint = @constCast("sha256:2222222222222222222222222222222222222222222222222222222222222222"), .source_episode_fingerprint = @constCast("sha256:1414141414141414141414141414141414141414141414141414141414141414"), .source_profile_fingerprint = @constCast("sha256:4444444444444444444444444444444444444444444444444444444444444444"), .target_text_witness = null, .source_profile_json = @constCast("{}"), .normalized_request = @constCast("omega request"), .dependency_keys = &shared_dependencies_two, .cluster_root = 1 },
    };
    try connectDependencies(&infos);
    try std.testing.expectEqual(@as(usize, 1), countClusters(&infos));
    try std.testing.expectError(
        error.DuplicateSourceAcrossSplits,
        rejectCrossSplitDependencyClusters(&infos),
    );
}

test "source-owner attestation binds the selection core" {
    const core = "{\"schema\":\"hylo-source-selection-receipt/v1\",\"campaign_id\":\"campaign-one\"}";
    const seed = [_]u8{0x51} ** 32;
    const signed = try sourceOwnerAttestationAlloc(
        std.testing.allocator,
        core,
        "campaign-one",
        .{ .action = .compile },
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        seed,
    );
    defer std.testing.allocator.free(signed);
    const body = try appendJsonMemberAlloc(std.testing.allocator, core, "source_owner_attestation", signed);
    defer std.testing.allocator.free(body);
    const public_key = try attestation.publicKeyBase64Alloc(std.testing.allocator, seed);
    defer std.testing.allocator.free(public_key);
    const trial_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"campaign_id\":\"campaign-one\",\"assurance\":{{\"trust_policy\":{{\"keys\":[{{\"key_id\":\"source-owner-key\",\"public_key_base64\":{f},\"allowed_roles\":[\"source_owner\"],\"producer_ids\":[\"seq-source-owner\"],\"producer_binary_fingerprints\":[\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"]}}]}}}}}}",
        .{std.json.fmt(public_key, .{})},
    );
    defer std.testing.allocator.free(trial_json);
    var trial_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, trial_json, .{ .allocate = .alloc_always });
    defer trial_parsed.deinit();
    const trial = try object(trial_parsed.value);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try validateSourceOwnerAttestation(std.testing.allocator, try object(parsed.value), trial);
    const tampered = try std.mem.replaceOwned(u8, std.testing.allocator, body, "campaign-one", "campaign-two");
    defer std.testing.allocator.free(tampered);
    var tampered_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tampered, .{ .allocate = .alloc_always });
    defer tampered_parsed.deinit();
    try std.testing.expectError(
        error.SourceOwnerAttestationInvalid,
        validateSourceOwnerAttestation(std.testing.allocator, try object(tampered_parsed.value), trial),
    );

    const untrusted_trial_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        trial_json,
        public_key,
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    );
    defer std.testing.allocator.free(untrusted_trial_json);
    var untrusted_trial = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, untrusted_trial_json, .{ .allocate = .alloc_always });
    defer untrusted_trial.deinit();
    try std.testing.expectError(
        error.SourceOwnerAuthorityInvalid,
        validateSourceOwnerAttestation(
            std.testing.allocator,
            try object(parsed.value),
            try object(untrusted_trial.value),
        ),
    );
}

test "case-blind historical projection omits embedded decision evidence" {
    const profile_raw =
        "{\"kind\":\"historical_decision\",\"source_governance_ref\":\"artifact:sgg\"," ++
        "\"source_governance_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"source_governance\":{\"secret-question\":\"controller-must-not-see\"},\"decision_context_ref\":\"artifact:dcp\"," ++
        "\"decision_context_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"decision_context\":{\"secret-question\":\"controller-must-not-see\"},\"temporal_horizon\":\"pre_decision\"," ++
        "\"source_target_text_policy\":\"absent\",\"retrace_mode\":\"replay\",\"required_lineage\":\"either\"," ++
        "\"required_fir_version\":\"FIR-v1\",\"reconstructability\":\"transcript_only\",\"limitations\":[]}";
    const raw = "{\"source_profile\":" ++ profile_raw ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const projected = try sourceProfileProjectionAlloc(std.testing.allocator, .{
        .object = try object(parsed.value),
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .split = "holdout",
        .visibility = "case_blind",
        .visible_fingerprint = undefined,
        .hidden_fingerprint = undefined,
        .source_episode_fingerprint = @constCast("sha256:1515151515151515151515151515151515151515151515151515151515151515"),
        .source_profile_fingerprint = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        .target_text_witness = @constCast("{\"schema\":\"hylo-source-target-text-witness/v1\",\"source_ref\":\"session:private#turn:decision\",\"source_episode_id\":\"episode-private\",\"source_turn_digest\":\"sha256:edededededededededededededededededededededededededededededededed\"}"),
        .source_profile_json = @constCast(profile_raw),
        .normalized_request = undefined,
        .dependency_keys = &.{},
        .cluster_root = 0,
    });
    defer std.testing.allocator.free(projected);
    try std.testing.expect(std.mem.indexOf(u8, projected, "secret-question") == null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "decision_context\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "artifact:sgg") == null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "artifact:dcp") == null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "\"source_target_text_witness\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "source_target_text_witness_fingerprint") != null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "session:private") == null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "episode-private") == null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "source_turn_digest") == null);
}

test "case-blind direct projection needs no private profile body delivery" {
    const profile_raw = "{\"kind\":\"direct\"}";
    const raw = "{\"source_profile\":" ++ profile_raw ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const projected = try sourceProfileProjectionAlloc(std.testing.allocator, .{
        .object = try object(parsed.value),
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .split = "practice",
        .visibility = "case_blind",
        .visible_fingerprint = undefined,
        .hidden_fingerprint = undefined,
        .source_episode_fingerprint = @constCast("sha256:1515151515151515151515151515151515151515151515151515151515151515"),
        .source_profile_fingerprint = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        .target_text_witness = null,
        .source_profile_json = @constCast(profile_raw),
        .normalized_request = undefined,
        .dependency_keys = &.{},
        .cluster_root = 0,
    });
    defer std.testing.allocator.free(projected);
    try std.testing.expect(std.mem.indexOf(u8, projected, "\"kind\":\"direct\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "\"source_profile_fingerprint\":\"sha256:cccc") != null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "\"sealed_payload\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, projected, "profile_body_delivery") == null);
}

test "sealed materialization validates the full target-text witness against its opaque commitment" {
    const fingerprint = "sha256:1515151515151515151515151515151515151515151515151515151515151515";
    var projected = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"historical_decision\",\"source_target_text_witness_fingerprint\":\"sha256:1515151515151515151515151515151515151515151515151515151515151515\"}",
        .{},
    );
    defer projected.deinit();
    try validateMaterializedTargetTextWitnessCommitment(try object(projected.value), fingerprint);
    try std.testing.expectError(
        error.TargetTextWitnessCommitmentMismatch,
        validateMaterializedTargetTextWitnessCommitment(
            try object(projected.value),
            "sha256:2525252525252525252525252525252525252525252525252525252525252525",
        ),
    );

    var leaked = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"source_target_text_witness\":{\"source_episode_id\":\"episode-private\"},\"source_target_text_witness_fingerprint\":\"sha256:1515151515151515151515151515151515151515151515151515151515151515\"}",
        .{},
    );
    defer leaked.deinit();
    try std.testing.expectError(
        error.CaseBlindProjectionInvalid,
        validateMaterializedTargetTextWitnessCommitment(try object(leaked.value), fingerprint),
    );
}

test "open and result-blind strip profiles publish a non-self-referential body commitment" {
    const profile_raw =
        "{\"kind\":\"historical_decision\",\"source_governance_ref\":\"artifact:sgg\"," ++
        "\"source_governance_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"source_governance\":{\"secret-question\":\"runner-only\"},\"decision_context_ref\":\"artifact:dcp\"," ++
        "\"decision_context_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"decision_context\":{\"secret-question\":\"runner-only\"},\"temporal_horizon\":\"pre_decision\"," ++
        "\"source_target_text_policy\":\"strip_and_replace\",\"retrace_mode\":\"replay\",\"required_lineage\":\"either\"," ++
        "\"required_fir_version\":\"FIR-v1\",\"reconstructability\":\"transcript_only\",\"limitations\":[]}";
    const raw = "{\"source_profile\":" ++ profile_raw ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    inline for (.{ "open", "result_blind" }) |visibility| {
        const projected = try sourceProfileProjectionAlloc(std.testing.allocator, .{
            .object = try object(parsed.value),
            .unit_id = "unit-one",
            .scenario_id = "scenario-one",
            .split = "practice",
            .visibility = visibility,
            .visible_fingerprint = undefined,
            .hidden_fingerprint = undefined,
            .source_episode_fingerprint = @constCast("sha256:1515151515151515151515151515151515151515151515151515151515151515"),
            .source_profile_fingerprint = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
            .target_text_witness = @constCast("{\"schema\":\"hylo-source-target-text-witness/v1\"}"),
            .source_profile_json = @constCast(profile_raw),
            .normalized_request = undefined,
            .dependency_keys = &.{},
            .cluster_root = 0,
        });
        defer std.testing.allocator.free(projected);
        try std.testing.expect(std.mem.indexOf(u8, projected, "\"profile_body_delivery\":\"source_profile_fd\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, projected, "\"source_profile_fingerprint\":\"sha256:cccc") != null);
        try std.testing.expect(std.mem.indexOf(u8, projected, "runner-only") == null);
        try std.testing.expect(std.mem.indexOf(u8, projected, "\"decision_context\"") == null);
    }
}

test "source episode commitment is source-derived and caller fingerprints are forbidden" {
    var direct_profile = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"direct\"}",
        .{},
    );
    defer direct_profile.deinit();
    var derived_case = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"source_episode_id\":\"session:one#turn:two\"}",
        .{},
    );
    defer derived_case.deinit();
    const derived = try sourceEpisodeFingerprintAlloc(
        std.testing.allocator,
        try object(derived_case.value),
        direct_profile.value,
        "practice",
    );
    defer std.testing.allocator.free(derived);
    try validateFingerprint(derived);
    const expected = try adapter.directSourceEpisodeFingerprintAlloc(
        std.testing.allocator,
        "session:one#turn:two",
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, derived);

    var explicit_case = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"source_episode_id\":\"session:one#turn:two\",\"source_episode_fingerprint\":\"sha256:1515151515151515151515151515151515151515151515151515151515151515\"}",
        .{},
    );
    defer explicit_case.deinit();
    try std.testing.expectError(
        error.CallerSuppliedSourceEpisodeFingerprintForbidden,
        sourceEpisodeFingerprintAlloc(
            std.testing.allocator,
            try object(explicit_case.value),
            direct_profile.value,
            "practice",
        ),
    );
}

test "source case lookup binds unit and scenario together" {
    const raw =
        "{\"cases\":[{\"unit_id\":\"unit-one\",\"scenario_id\":\"scenario-one\"}," ++
        "{\"unit_id\":\"unit-two\",\"scenario_id\":\"scenario-two\"}]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    _ = try findSourceCase(parsed.value, "unit-one", "scenario-one");
    try std.testing.expectError(
        error.MaterializationScopeInvalid,
        findSourceCase(parsed.value, "unit-one", "scenario-two"),
    );
}

test "binary keys preserve leading and trailing whitespace bytes" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    var key = [_]u8{0x42} ** 32;
    key[0] = ' ';
    key[31] = '\n';
    try std.testing.expectEqual(@as(isize, 32), std.c.write(fds[1], &key, key.len));
    _ = std.c.close(fds[1]);
    const observed = try readKey(fds[0]);
    try std.testing.expectEqualSlices(u8, &key, &observed);
}

test "raw keys require exactly 32 bytes through EOF" {
    var trailing_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&trailing_fds));
    defer _ = std.c.close(trailing_fds[0]);
    var trailing = [_]u8{0x42} ** 33;
    try std.testing.expectEqual(@as(isize, trailing.len), std.c.write(trailing_fds[1], &trailing, trailing.len));
    _ = std.c.close(trailing_fds[1]);
    try std.testing.expectError(error.KeyInvalid, readKey(trailing_fds[0]));

    var encoded_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&encoded_fds));
    defer _ = std.c.close(encoded_fds[0]);
    const encoded = "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI=";
    try std.testing.expectEqual(@as(isize, encoded.len), std.c.write(encoded_fds[1], encoded.ptr, encoded.len));
    _ = std.c.close(encoded_fds[1]);
    try std.testing.expectError(error.KeyInvalid, readKey(encoded_fds[0]));
}

test "manifest descriptor reads are bounded through EOF" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    const input = "{}x";
    try std.testing.expectEqual(@as(isize, input.len), std.c.write(fds[1], input.ptr, input.len));
    _ = std.c.close(fds[1]);
    try std.testing.expectError(error.FdInputTooLarge, readFdAlloc(std.testing.allocator, fds[0], 2));
}

test "sensitive endpoints require anonymous directional distinct pipes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "visible.json", .{});
    defer file.close(std.testing.io);
    try std.testing.expectError(
        error.MaterializationEndpointUnbound,
        validateRunnerOutputEndpoint(file.handle),
    );
    try std.testing.expectError(error.ManifestEndpointUnbound, validateManifestInputEndpoint(file.handle));
    try std.testing.expectError(error.KeyEndpointUnbound, validateKeyInputEndpoint(file.handle));

    var first: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&first));
    defer _ = std.c.close(first[0]);
    defer _ = std.c.close(first[1]);
    try validateManifestInputEndpoint(first[0]);
    try validateKeyInputEndpoint(first[0]);
    try validatePrivateKeyCapability(first[1]);
    try validateRunnerOutputEndpoint(first[1]);
    try std.testing.expectError(error.MaterializationEndpointUnbound, validateRunnerOutputEndpoint(first[0]));
    try std.testing.expectError(error.KeyEndpointUnbound, validateKeyInputEndpoint(first[1]));
    try std.testing.expectError(error.KeyEndpointUnbound, validateKeyInputEndpoint(std.posix.STDIN_FILENO));
    const aliased_fd = std.c.dup(first[0]);
    try std.testing.expect(aliased_fd >= 0);
    defer _ = std.c.close(aliased_fd);
    try std.testing.expectError(error.SensitiveEndpointAlias, validateDistinctSensitiveEndpoints(&.{ first[0], aliased_fd }));

    var second: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&second));
    defer _ = std.c.close(second[0]);
    defer _ = std.c.close(second[1]);
    try validateDistinctSensitiveEndpoints(&.{ first[0], second[0] });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const fifo_path = try std.fs.path.join(std.testing.allocator, &.{ root, "named.fifo" });
    defer std.testing.allocator.free(fifo_path);
    const fifo_path_z = try std.testing.allocator.dupeZ(u8, fifo_path);
    defer std.testing.allocator.free(fifo_path_z);
    const libc = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };
    try std.testing.expectEqual(@as(c_int, 0), libc.mkfifo(fifo_path_z, 0o600));
    const named_fd = try std.posix.openat(std.posix.AT.FDCWD, fifo_path, .{ .ACCMODE = .RDWR }, 0);
    defer _ = std.c.close(named_fd);
    var named_stat: std.c.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.fstat(named_fd, &named_stat));
    try std.testing.expect(std.c.S.ISFIFO(named_stat.mode));
    try std.testing.expect(named_stat.nlink != 0);
    try std.testing.expectError(error.PrivateKeySinkInvalid, validatePrivateKeyCapability(named_fd));
}

test "sealed case encryption authenticates unit scope" {
    const key = [_]u8{0x33} ** 32;
    const raw = "{\"source_episode_id\":\"session:one#turn:one\",\"visible_input\":{\"request\":\"controller-must-not-see-this-case\"},\"hidden_reference\":{\"answer\":\"controller-must-not-see-this-oracle\"},\"source_profile\":{\"kind\":\"direct\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const info = CaseInfo{
        .object = try object(parsed.value),
        .unit_id = "unit-one",
        .scenario_id = "scenario-one",
        .split = "holdout",
        .visibility = "case_blind",
        .visible_fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .hidden_fingerprint = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .source_episode_fingerprint = @constCast("sha256:1515151515151515151515151515151515151515151515151515151515151515"),
        .source_profile_fingerprint = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        .target_text_witness = null,
        .source_profile_json = @constCast("{\"kind\":\"direct\"}"),
        .normalized_request = @constCast("controller-must-not-see-this-case"),
        .dependency_keys = &.{},
        .cluster_root = 0,
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const sealed = try sealCaseAlloc(std.testing.allocator, info, key, root);
    defer std.testing.allocator.free(sealed.ref);
    defer std.testing.allocator.free(sealed.json);
    defer std.testing.allocator.free(sealed.fingerprint);
    try std.testing.expect(std.mem.indexOf(u8, sealed.json, "controller-must-not-see-this-case") == null);
    try std.testing.expect(std.mem.indexOf(u8, sealed.json, "controller-must-not-see-this-oracle") == null);
    var envelope_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sealed.json, .{});
    defer envelope_parsed.deinit();
    const wrong_key = [_]u8{0x44} ** 32;
    try std.testing.expectError(
        error.SealedCaseAuthenticationFailed,
        decryptCaseAlloc(std.testing.allocator, try object(envelope_parsed.value), wrong_key),
    );
    const plaintext = try decryptCaseAlloc(std.testing.allocator, try object(envelope_parsed.value), key);
    defer std.testing.allocator.free(plaintext);
    try std.testing.expect(std.mem.indexOf(u8, plaintext, "hidden_reference") != null);
}

test "sealed materializer requires distinct registered role keys" {
    const contract_json =
        "{\"schema\":\"hylo-case-materializer-contract/v1\",\"controller_id\":\"hylo-controller\"," ++
        "\"materializer_id\":\"seq-materializer\",\"runner_id\":\"cas-runner\"," ++
        "\"materializer_key_id\":\"materializer-key\",\"runner_key_id\":\"runner-key\"," ++
        "\"capability_delivery\":\"anonymous_fd\",\"visible_input_delivery\":\"anonymous_fd\"," ++
        "\"source_profile_delivery\":\"anonymous_fd\",\"receiver_binding\":\"runner_key\"," ++
        "\"receiver_role\":\"runner\",\"single_use\":true}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, contract_json, .{});
    defer parsed.deinit();
    const contract = try object(parsed.value);
    const valid = try validateMaterializerBoundary(
        contract,
        "seq-materializer",
        "materializer-key",
    );
    try std.testing.expectEqualStrings("hylo-controller", valid.controller_id);
    try std.testing.expectEqualStrings("runner-key", valid.runner_key_id);
    try std.testing.expectError(
        error.CaseMaterializerInvalid,
        validateMaterializerBoundary(contract, "seq-materializer", "other-key"),
    );

    const shared_key_json =
        "{\"schema\":\"hylo-case-materializer-contract/v1\",\"controller_id\":\"hylo-controller\"," ++
        "\"materializer_id\":\"seq-materializer\",\"runner_id\":\"cas-runner\"," ++
        "\"materializer_key_id\":\"shared-key\",\"runner_key_id\":\"shared-key\"," ++
        "\"capability_delivery\":\"anonymous_fd\",\"visible_input_delivery\":\"anonymous_fd\"," ++
        "\"source_profile_delivery\":\"anonymous_fd\",\"receiver_binding\":\"runner_key\"," ++
        "\"receiver_role\":\"runner\",\"single_use\":true}";
    var shared_key = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        shared_key_json,
        .{},
    );
    defer shared_key.deinit();
    try std.testing.expectError(
        error.SealedSamePrincipalForbidden,
        validateMaterializerBoundary(
            try object(shared_key.value),
            "seq-materializer",
            "shared-key",
        ),
    );
}
