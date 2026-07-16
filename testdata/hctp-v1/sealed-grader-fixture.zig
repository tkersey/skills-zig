const std = @import("std");
const durable_store = @import("durable_store");
const retrace_core = @import("retrace_core");

const attestation = retrace_core.hctp_attestation;
const MaxBytes = 64 * 1024 * 1024;
const BaselineOutput = "{\"answer\":\"required-behavior-missing\",\"correct\":false}\n";
const CandidateOutput = "{\"answer\":\"required-behavior-present\",\"correct\":true}\n";

const libc = struct {
    extern "c" fn getentropy(buffer: *anyopaque, length: usize) c_int;
};

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ObjectRequired,
    };
}

fn required(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.RequiredFieldMissing;
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try required(map, key)) {
        .string => |text| if (text.len == 0) error.EmptyField else text,
        else => error.StringRequired,
    };
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return switch (try required(map, key)) {
        .array => |items| items,
        else => error.ArrayRequired,
    };
}

fn requiredUsize(map: std.json.ObjectMap, key: []const u8) !usize {
    const value = switch (try required(map, key)) {
        .integer => |number| number,
        else => return error.IntegerRequired,
    };
    if (value < 0) return error.IntegerRequired;
    return std.math.cast(usize, value) orelse error.IntegerRequired;
}

fn requireExactKeys(map: std.json.ObjectMap, expected: []const []const u8) !void {
    if (map.count() != expected.len) return error.UnexpectedField;
    for (expected) |key| _ = map.get(key) orelse return error.RequiredFieldMissing;
}

fn requireOpaqueIdentifier(value: []const u8) !void {
    inline for (.{ "calibration", "sentinel", "null", "positive" }) |marker| {
        if (std.mem.indexOf(u8, value, marker) != null) return error.SentinelPurposeRecognized;
    }
    if (value.len != "opaque-".len + 64 or !std.mem.startsWith(u8, value, "opaque-")) {
        return error.RegisteredIdentifierExposed;
    }
    for (value["opaque-".len..]) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.RegisteredIdentifierExposed;
        }
    }
}

fn parseFd(raw: []const u8) !std.posix.fd_t {
    const fd = try std.fmt.parseInt(i32, raw, 10);
    if (fd < 3) return error.InvalidFd;
    return fd;
}

const EndpointAccess = enum {
    read_only,
    write_only,
};

fn sameFdEndpoint(expected: std.c.Stat, fd: std.posix.fd_t) bool {
    var actual: std.c.Stat = undefined;
    if (std.c.fstat(fd, &actual) != 0) return false;
    return expected.dev == actual.dev and expected.ino == actual.ino;
}

fn validateAnonymousEndpoint(
    fd: std.posix.fd_t,
    access: EndpointAccess,
    allow_standard_descriptor: bool,
) !std.c.Stat {
    if (fd < 0) return error.CapabilityEndpointInvalid;
    var endpoint: std.c.Stat = undefined;
    if (std.c.fstat(fd, &endpoint) != 0 or
        !std.c.S.ISFIFO(endpoint.mode) or
        endpoint.nlink != 0)
    {
        return error.CapabilityEndpointInvalid;
    }
    if (!allow_standard_descriptor and
        (sameFdEndpoint(endpoint, std.posix.STDIN_FILENO) or
            sameFdEndpoint(endpoint, std.posix.STDOUT_FILENO) or
            sameFdEndpoint(endpoint, std.posix.STDERR_FILENO)))
    {
        return error.CapabilityEndpointInvalid;
    }
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return error.CapabilityEndpointInvalid;
    const flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    switch (access) {
        .read_only => if (flags.ACCMODE != .RDONLY) return error.CapabilityEndpointInvalid,
        .write_only => if (flags.ACCMODE != .WRONLY) return error.CapabilityEndpointInvalid,
    }
    return endpoint;
}

fn validateTransportEndpoints(
    input_fd: std.posix.fd_t,
    output_fd: std.posix.fd_t,
    seed_fd: std.posix.fd_t,
) !void {
    const input = try validateAnonymousEndpoint(input_fd, .read_only, true);
    const output = try validateAnonymousEndpoint(output_fd, .write_only, true);
    const seed = try validateAnonymousEndpoint(seed_fd, .read_only, false);
    if ((input.dev == output.dev and input.ino == output.ino) or
        (input.dev == seed.dev and input.ino == seed.ino) or
        (output.dev == seed.dev and output.ino == seed.ino))
    {
        return error.CapabilityEndpointAlias;
    }
}

fn descriptorScanLimit() !usize {
    const limits = std.posix.getrlimit(.NOFILE) catch
        return error.GraderDescriptorLimitUnavailable;
    const max_fd_t: usize = @intCast(std.math.maxInt(std.posix.fd_t));
    const max_c_int: usize = @intCast(std.math.maxInt(c_int));
    const max_inspectable_fd: usize = @min(max_fd_t, max_c_int);
    const soft_limit = std.math.cast(usize, limits.cur) orelse
        return error.GraderDescriptorLimitInvalid;
    return @min(soft_limit, max_inspectable_fd + 1);
}

fn requireClosedDescriptorRange(first: usize, end_exclusive: usize) !void {
    const scan_limit = try descriptorScanLimit();
    if (first > end_exclusive or end_exclusive > scan_limit) {
        return error.GraderDescriptorRangeInvalid;
    }
    var raw_fd = first;
    while (raw_fd < end_exclusive) : (raw_fd += 1) {
        const fd = std.math.cast(std.posix.fd_t, raw_fd) orelse
            return error.GraderDescriptorRangeInvalid;
        while (true) {
            const result = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
            switch (std.posix.errno(result)) {
                .SUCCESS => return error.GraderInheritedFdLeak,
                .BADF => break,
                .INTR => continue,
                else => return error.GraderFdInspectionFailed,
            }
        }
    }
}

fn verifyExecutionBoundary(seed_fd: std.posix.fd_t) !void {
    if (seed_fd != 3) return error.GraderSeedFdInvalid;
    try validateTransportEndpoints(
        std.posix.STDIN_FILENO,
        std.posix.STDOUT_FILENO,
        seed_fd,
    );
    const expected_environment = [_]struct { name: [*:0]const u8, value: []const u8 }{
        .{ .name = "HOME", .value = "/nonexistent" },
        .{ .name = "LANG", .value = "C" },
        .{ .name = "LC_ALL", .value = "C" },
        .{ .name = "PATH", .value = "/usr/bin:/bin" },
        .{ .name = "TZ", .value = "UTC" },
    };
    for (expected_environment) |entry| {
        const actual = std.c.getenv(entry.name) orelse return error.GraderEnvironmentMissing;
        if (!std.mem.eql(u8, std.mem.span(actual), entry.value)) return error.GraderEnvironmentInvalid;
    }
    try requireClosedDescriptorRange(4, try descriptorScanLimit());
}

fn readKey(fd: std.posix.fd_t) ![32]u8 {
    _ = try validateAnonymousEndpoint(fd, .read_only, false);
    var raw: [33]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw);
    var used: usize = 0;
    read_loop: while (used < raw.len) {
        const count = std.c.read(fd, raw[used..].ptr, raw.len - used);
        switch (std.posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) break :read_loop;
                used += @intCast(count);
            },
            .INTR => continue,
            else => return error.KeyReadFailed,
        }
    }
    if (used != 32) return error.KeyInvalid;
    return raw[0..32].*;
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn digestJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return attestation.digestValueAlloc(allocator, value);
}

fn base64DecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
        return error.SemanticObservationEncodingInvalid;
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch
        return error.SemanticObservationEncodingInvalid;
    return decoded;
}

fn executableFingerprintAlloc(allocator: std.mem.Allocator) ![]u8 {
    const path = try std.process.executablePathAlloc(defaultIo(), allocator);
    defer allocator.free(path);
    const bytes = try durable_store.readFileAlloc(allocator, path, MaxBytes);
    defer allocator.free(bytes);
    return digestBytesAlloc(allocator, bytes);
}

pub fn scoreSemanticOutput(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_fingerprint: []const u8,
) !f64 {
    if (bytes.len == 0) return error.SemanticObservationMissing;
    const fingerprint = try digestBytesAlloc(allocator, bytes);
    defer allocator.free(fingerprint);
    if (!std.mem.eql(u8, fingerprint, expected_fingerprint)) {
        return error.SemanticObservationFingerprintMismatch;
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const root = try object(parsed.value);
    const correct = switch (try required(root, "correct")) {
        .bool => |value| value,
        else => return error.SemanticOutputInvalid,
    };
    return if (correct) 1.0 else 0.0;
}

const SemanticObservation = struct {
    fingerprint: []u8,
    scores: [2]f64 = .{ 0, 0 },
    output_fingerprints: [2]?[]const u8 = .{ null, null },
    output_count: usize = 0,

    fn deinit(self: SemanticObservation, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
    }
};

fn decodeCarrierAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    expected_slot: []const u8,
    expected_fingerprint: []const u8,
) ![]u8 {
    const carrier = try object(value);
    try requireExactKeys(carrier, &.{ "slot", "fingerprint", "size_bytes", "content_base64" });
    if (!std.mem.eql(u8, try requiredString(carrier, "slot"), expected_slot) or
        !std.mem.eql(u8, try requiredString(carrier, "fingerprint"), expected_fingerprint))
    {
        return error.SemanticObservationInvalid;
    }
    const decoded = try base64DecodeAlloc(allocator, try requiredString(carrier, "content_base64"));
    errdefer allocator.free(decoded);
    if (decoded.len == 0 or decoded.len != try requiredUsize(carrier, "size_bytes")) {
        return error.SemanticObservationInvalid;
    }
    const fingerprint = try digestBytesAlloc(allocator, decoded);
    defer allocator.free(fingerprint);
    if (!std.mem.eql(u8, fingerprint, expected_fingerprint)) {
        return error.SemanticObservationFingerprintMismatch;
    }
    return decoded;
}

fn observeSemanticBytesAlloc(
    allocator: std.mem.Allocator,
    kind: []const u8,
    presentation: std.json.ObjectMap,
    observation_value: std.json.Value,
) !SemanticObservation {
    const observation = try object(observation_value);
    try requireExactKeys(observation, &.{ "schema", "kind", "output_carriers", "trace_carriers" });
    if (!std.mem.eql(u8, try requiredString(observation, "schema"), "hylo-grade-semantic-observation/v1") or
        !std.mem.eql(u8, try requiredString(observation, "kind"), kind))
    {
        return error.SemanticObservationInvalid;
    }
    const outputs = try requiredArray(observation, "output_carriers");
    const traces = try requiredArray(observation, "trace_carriers");
    const absolute = std.mem.eql(u8, kind, "absolute");
    if (outputs.items.len != (if (absolute) @as(usize, 1) else 2) or
        traces.items.len != (if (absolute) @as(usize, 1) else 0))
    {
        return error.SemanticObservationInvalid;
    }
    var result = SemanticObservation{
        .fingerprint = try digestJsonAlloc(allocator, observation_value),
    };
    errdefer result.deinit(allocator);
    if (absolute) {
        const output_fingerprint = try requiredString(presentation, "output_fingerprint");
        const output = try decodeCarrierAlloc(
            allocator,
            outputs.items[0],
            "output",
            output_fingerprint,
        );
        defer allocator.free(output);
        result.scores[0] = try scoreSemanticOutput(allocator, output, output_fingerprint);
        result.output_fingerprints[0] = output_fingerprint;
        result.output_count = 1;
        const trace_fingerprint = try requiredString(presentation, "trace_fingerprint");
        const trace = try decodeCarrierAlloc(
            allocator,
            traces.items[0],
            "trace",
            trace_fingerprint,
        );
        allocator.free(trace);
    } else {
        inline for (.{
            .{ 0, "left_output", "left_output_fingerprint" },
            .{ 1, "right_output", "right_output_fingerprint" },
        }) |expected| {
            const output_fingerprint = try requiredString(presentation, expected[2]);
            const output = try decodeCarrierAlloc(
                allocator,
                outputs.items[expected[0]],
                expected[1],
                output_fingerprint,
            );
            defer allocator.free(output);
            result.scores[expected[0]] = try scoreSemanticOutput(allocator, output, output_fingerprint);
            result.output_fingerprints[expected[0]] = output_fingerprint;
        }
        result.output_count = 2;
    }
    return result;
}

fn absoluteReceiptAlloc(
    allocator: std.mem.Allocator,
    presentation: std.json.ObjectMap,
    semantic_observation_value: std.json.Value,
    presentation_receipt_fingerprint: []const u8,
    identifier_alias_map_fingerprint: []const u8,
    binary_fingerprint: []const u8,
    seed: [32]u8,
) ![]u8 {
    try requireOpaqueIdentifier(try requiredString(presentation, "trial_id"));
    try requireOpaqueIdentifier(try requiredString(presentation, "lane_id"));
    try requireOpaqueIdentifier(try requiredString(presentation, "opaque_arm_id"));
    const semantic_observation = try observeSemanticBytesAlloc(
        allocator,
        "absolute",
        presentation,
        semantic_observation_value,
    );
    defer semantic_observation.deinit(allocator);
    const output_fingerprint = semantic_observation.output_fingerprints[0].?;
    const score = semantic_observation.scores[0];
    const unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-receipt/v1\",\"trial_id\":{f},\"lane_id\":{f},\"opaque_arm_id\":{f},\"run_receipt_fingerprint\":{f},\"grade_presentation_receipt_fingerprint\":{f},\"identifier_alias_map_fingerprint\":{f},\"semantic_observation_fingerprint\":{f},\"producer\":{{\"id\":\"deterministic-grader\",\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":\"absolute-grader-key\"}},\"blinding\":{{\"semantic_arm_identity_visible\":false,\"target_diff_visible\":false,\"sibling_output_visible\":false,\"prior_trial_results_visible\":false,\"hidden_reference_visible\":false,\"registered_identifiers_visible\":false}},\"status\":{f},\"rubric_fingerprint\":{f},\"judge\":{{\"kind\":\"deterministic\",\"id\":\"sealed-output-grader\",\"version\":\"v1\",\"config_fingerprint\":\"sha256:6666666666666666666666666666666666666666666666666666666666666666\"}},\"dimensions\":[{{\"id\":\"correctness\",\"score\":{d},\"weight\":1.0,\"grader_kind\":\"deterministic\",\"grader_ref\":\"hctp:sealed-output\",\"grader_fingerprint\":{f},\"evidence_refs\":[{f}]}}],\"oracle_results\":[{{\"id\":\"required-test\",\"status\":\"pass\",\"grader_kind\":\"deterministic\",\"grader_ref\":\"hctp:sealed-output-oracle\",\"grader_fingerprint\":{f},\"evidence_refs\":[{f}]}}],\"derived_critical_violations\":[],\"evidence_refs\":[{f}],\"attestation\":null}}",
        .{
            std.json.fmt(try requiredString(presentation, "trial_id"), .{}),
            std.json.fmt(try requiredString(presentation, "lane_id"), .{}),
            std.json.fmt(try requiredString(presentation, "opaque_arm_id"), .{}),
            std.json.fmt(try requiredString(presentation, "run_receipt_fingerprint"), .{}),
            std.json.fmt(presentation_receipt_fingerprint, .{}),
            std.json.fmt(identifier_alias_map_fingerprint, .{}),
            std.json.fmt(semantic_observation.fingerprint, .{}),
            std.json.fmt(binary_fingerprint, .{}),
            std.json.fmt(if (score == 1.0) "pass" else "fail", .{}),
            std.json.fmt(try requiredString(presentation, "rubric_fingerprint"), .{}),
            score,
            std.json.fmt(binary_fingerprint, .{}),
            std.json.fmt(output_fingerprint, .{}),
            std.json.fmt(binary_fingerprint, .{}),
            std.json.fmt(output_fingerprint, .{}),
            std.json.fmt(output_fingerprint, .{}),
        },
    );
    defer allocator.free(unsigned);
    return attestation.signReceiptAlloc(allocator, unsigned, .{
        .id = "deterministic-grader",
        .version = "v1",
        .binary_fingerprint = binary_fingerprint,
        .key_id = "absolute-grader-key",
    }, "absolute_grader", 100, seed);
}

fn preference(left: f64, right: f64) []const u8 {
    if (left > right) return "left";
    if (right > left) return "right";
    return "tie";
}

fn pairReceiptAlloc(
    allocator: std.mem.Allocator,
    presentation: std.json.ObjectMap,
    semantic_observation_value: std.json.Value,
    presentation_receipt_fingerprint: []const u8,
    identifier_alias_map_fingerprint: []const u8,
    binary_fingerprint: []const u8,
    seed: [32]u8,
) ![]u8 {
    try requireOpaqueIdentifier(try requiredString(presentation, "trial_id"));
    try requireOpaqueIdentifier(try requiredString(presentation, "pair_id"));
    try requireOpaqueIdentifier(try requiredString(presentation, "left_lane_id"));
    try requireOpaqueIdentifier(try requiredString(presentation, "right_lane_id"));
    const semantic_observation = try observeSemanticBytesAlloc(
        allocator,
        "pair",
        presentation,
        semantic_observation_value,
    );
    defer semantic_observation.deinit(allocator);
    const left_output = semantic_observation.output_fingerprints[0].?;
    const right_output = semantic_observation.output_fingerprints[1].?;
    const preferred = preference(
        semantic_observation.scores[0],
        semantic_observation.scores[1],
    );
    const unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-pair-grade-receipt/v1\",\"trial_id\":{f},\"pair_id\":{f},\"lane_ids\":[{f},{f}],\"grade_presentation_receipt_fingerprint\":{f},\"identifier_alias_map_fingerprint\":{f},\"semantic_observation_fingerprint\":{f},\"judge_contract_fingerprint\":\"sha256:9b296a9dec19da50db8597c607eef413f7d43fd173b9a8fd6d94075af9890432\",\"presentation\":{{\"left_lane_id\":{f},\"right_lane_id\":{f},\"left_output_fingerprint\":{f},\"right_output_fingerprint\":{f},\"position_map_commitment\":{f},\"sibling_outputs_only\":true}},\"producer\":{{\"id\":\"blind-pair-grader\",\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":\"pair-grader-key\"}},\"blinding\":{{\"semantic_arm_identity_visible\":false,\"opaque_arm_id_visible\":false,\"target_diff_visible\":false,\"lane_execution_order_visible\":false,\"absolute_grade_results_visible\":false,\"prior_pair_results_visible\":false,\"registered_identifiers_visible\":false}},\"verdict\":{{\"preferred\":{f},\"confidence\":1.0}},\"dimensions\":[{{\"id\":\"correctness\",\"preferred\":{f},\"rationale_ref\":\"hctp:sealed-output-pair\",\"evidence_refs\":[{f},{f}]}}],\"prohibited_critical_authority\":true,\"evidence_refs\":[{f},{f}],\"attestation\":null}}",
        .{
            std.json.fmt(try requiredString(presentation, "trial_id"), .{}),
            std.json.fmt(try requiredString(presentation, "pair_id"), .{}),
            std.json.fmt(try requiredString(presentation, "left_lane_id"), .{}),
            std.json.fmt(try requiredString(presentation, "right_lane_id"), .{}),
            std.json.fmt(presentation_receipt_fingerprint, .{}),
            std.json.fmt(identifier_alias_map_fingerprint, .{}),
            std.json.fmt(semantic_observation.fingerprint, .{}),
            std.json.fmt(try requiredString(presentation, "left_lane_id"), .{}),
            std.json.fmt(try requiredString(presentation, "right_lane_id"), .{}),
            std.json.fmt(left_output, .{}),
            std.json.fmt(right_output, .{}),
            std.json.fmt(try requiredString(presentation, "position_map_commitment"), .{}),
            std.json.fmt(binary_fingerprint, .{}),
            std.json.fmt(preferred, .{}),
            std.json.fmt(preferred, .{}),
            std.json.fmt(left_output, .{}),
            std.json.fmt(right_output, .{}),
            std.json.fmt(left_output, .{}),
            std.json.fmt(right_output, .{}),
        },
    );
    defer allocator.free(unsigned);
    return attestation.signReceiptAlloc(allocator, unsigned, .{
        .id = "blind-pair-grader",
        .version = "v1",
        .binary_fingerprint = binary_fingerprint,
        .key_id = "pair-grader-key",
    }, "pair_grader", 100, seed);
}

const GradeIdentity = struct {
    kind: []const u8,
    receipt_schema: []const u8,
    producer_id: []const u8,
    producer_key_id: []const u8,
    role: []const u8,
};

fn gradeIdentity(kind: []const u8) !GradeIdentity {
    if (std.mem.eql(u8, kind, "absolute")) return .{
        .kind = "absolute",
        .receipt_schema = "hylo-grade-receipt/v1",
        .producer_id = "deterministic-grader",
        .producer_key_id = "absolute-grader-key",
        .role = "absolute_grader",
    };
    if (std.mem.eql(u8, kind, "pair")) return .{
        .kind = "pair",
        .receipt_schema = "hylo-pair-grade-receipt/v1",
        .producer_id = "blind-pair-grader",
        .producer_key_id = "pair-grader-key",
        .role = "pair_grader",
    };
    return error.InvalidArguments;
}

fn digestJsonTextAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    return digestJsonAlloc(allocator, parsed.value);
}

fn graderScopeAlloc(
    allocator: std.mem.Allocator,
    identity: GradeIdentity,
    presentation: std.json.ObjectMap,
) ![]u8 {
    if (std.mem.eql(u8, identity.kind, "absolute")) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"trial_id\":{f},\"lane_ids\":[{f}],\"pair_id\":null}}",
            .{
                std.json.fmt(try requiredString(presentation, "trial_id"), .{}),
                std.json.fmt(try requiredString(presentation, "lane_id"), .{}),
            },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"trial_id\":{f},\"lane_ids\":[{f},{f}],\"pair_id\":{f}}}",
        .{
            std.json.fmt(try requiredString(presentation, "trial_id"), .{}),
            std.json.fmt(try requiredString(presentation, "left_lane_id"), .{}),
            std.json.fmt(try requiredString(presentation, "right_lane_id"), .{}),
            std.json.fmt(try requiredString(presentation, "pair_id"), .{}),
        },
    );
}

fn producerAlloc(
    allocator: std.mem.Allocator,
    identity: GradeIdentity,
    binary_fingerprint: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"id\":{f},\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":{f}}}",
        .{
            std.json.fmt(identity.producer_id, .{}),
            std.json.fmt(binary_fingerprint, .{}),
            std.json.fmt(identity.producer_key_id, .{}),
        },
    );
}

fn validateOpeningNonce(nonce_hex: []const u8) !void {
    if (nonce_hex.len != 64) return error.GraderOpeningNonceInvalid;
    for (nonce_hex) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.GraderOpeningNonceInvalid;
        }
    }
}

fn sealedGradeResultWithNonceAlloc(
    allocator: std.mem.Allocator,
    kind: []const u8,
    presentation: std.json.ObjectMap,
    presentation_receipt_fingerprint: []const u8,
    identifier_alias_map_fingerprint: []const u8,
    binary_fingerprint: []const u8,
    receipt: []const u8,
    nonce_hex: []const u8,
    seed: [32]u8,
) ![]u8 {
    try validateOpeningNonce(nonce_hex);
    const identity = try gradeIdentity(kind);
    const grader_scope = try graderScopeAlloc(allocator, identity, presentation);
    defer allocator.free(grader_scope);
    const producer = try producerAlloc(allocator, identity, binary_fingerprint);
    defer allocator.free(producer);
    const grade_receipt_fingerprint = try digestJsonTextAlloc(allocator, receipt);
    defer allocator.free(grade_receipt_fingerprint);

    const commitment_preimage = try std.fmt.allocPrint(
        allocator,
        "{{\"domain\":\"HCTP/hylo-grade-commitment/v1\",\"kind\":{f},\"grader_scope\":{s},\"grade_presentation_receipt_fingerprint\":{f},\"identifier_alias_map_fingerprint\":{f},\"producer\":{s},\"grade_receipt_fingerprint\":{f},\"opening_nonce_hex\":{f}}}",
        .{
            std.json.fmt(identity.kind, .{}),
            grader_scope,
            std.json.fmt(presentation_receipt_fingerprint, .{}),
            std.json.fmt(identifier_alias_map_fingerprint, .{}),
            producer,
            std.json.fmt(grade_receipt_fingerprint, .{}),
            std.json.fmt(nonce_hex, .{}),
        },
    );
    defer allocator.free(commitment_preimage);
    const commitment_digest = try digestJsonTextAlloc(allocator, commitment_preimage);
    defer allocator.free(commitment_digest);

    const unsigned_commitment = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-commitment/v1\",\"kind\":{f},\"grader_scope\":{s},\"grade_presentation_receipt_fingerprint\":{f},\"identifier_alias_map_fingerprint\":{f},\"producer\":{s},\"opening_nonce_contract\":{{\"source\":\"getentropy\",\"encoding\":\"lower_hex\",\"bytes\":32,\"single_use\":true}},\"commitment\":{{\"algorithm\":{f},\"domain\":\"HCTP/hylo-grade-commitment/v1\",\"fingerprint\":{f}}},\"attestation\":null}}",
        .{
            std.json.fmt(identity.kind, .{}),
            grader_scope,
            std.json.fmt(presentation_receipt_fingerprint, .{}),
            std.json.fmt(identifier_alias_map_fingerprint, .{}),
            producer,
            std.json.fmt(retrace_core.canonical_json.Sha256Algorithm, .{}),
            std.json.fmt(commitment_digest, .{}),
        },
    );
    defer allocator.free(unsigned_commitment);
    const signed_commitment = try attestation.signReceiptAlloc(allocator, unsigned_commitment, .{
        .id = identity.producer_id,
        .version = "v1",
        .binary_fingerprint = binary_fingerprint,
        .key_id = identity.producer_key_id,
    }, identity.role, 100, seed);
    defer allocator.free(signed_commitment);
    const grade_commitment_fingerprint = try digestJsonTextAlloc(allocator, signed_commitment);
    defer allocator.free(grade_commitment_fingerprint);

    const unsigned_opening = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-opening/v1\",\"kind\":{f},\"grade_commitment_fingerprint\":{f},\"grader_scope\":{s},\"opening_nonce_hex\":{f},\"grade_receipt_fingerprint\":{f},\"grade_receipt\":{s},\"producer\":{s},\"attestation\":null}}",
        .{
            std.json.fmt(identity.kind, .{}),
            std.json.fmt(grade_commitment_fingerprint, .{}),
            grader_scope,
            std.json.fmt(nonce_hex, .{}),
            std.json.fmt(grade_receipt_fingerprint, .{}),
            receipt,
            producer,
        },
    );
    defer allocator.free(unsigned_opening);
    const signed_opening = try attestation.signReceiptAlloc(allocator, unsigned_opening, .{
        .id = identity.producer_id,
        .version = "v1",
        .binary_fingerprint = binary_fingerprint,
        .key_id = identity.producer_key_id,
    }, identity.role, 100, seed);
    defer allocator.free(signed_opening);

    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-sealed-result/v1\",\"grade_commitment_fingerprint\":{f},\"grade_commitment\":{s},\"grade_opening\":{s}}}",
        .{
            std.json.fmt(grade_commitment_fingerprint, .{}),
            signed_commitment,
            signed_opening,
        },
    );
}

fn sealedGradeResultAlloc(
    allocator: std.mem.Allocator,
    kind: []const u8,
    presentation: std.json.ObjectMap,
    presentation_receipt_fingerprint: []const u8,
    identifier_alias_map_fingerprint: []const u8,
    binary_fingerprint: []const u8,
    receipt: []const u8,
    seed: [32]u8,
) ![]u8 {
    var nonce_bytes: [32]u8 = undefined;
    if (libc.getentropy(&nonce_bytes, nonce_bytes.len) != 0) {
        return error.GraderEntropyUnavailable;
    }
    const nonce_hex = std.fmt.bytesToHex(nonce_bytes, .lower);
    return sealedGradeResultWithNonceAlloc(
        allocator,
        kind,
        presentation,
        presentation_receipt_fingerprint,
        identifier_alias_map_fingerprint,
        binary_fingerprint,
        receipt,
        &nonce_hex,
        seed,
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 or !std.mem.eql(u8, args[2], "--seed-fd")) return error.InvalidArguments;
    const seed_fd = try parseFd(args[3]);
    try verifyExecutionBoundary(seed_fd);
    var seed = try readKey(seed_fd);
    defer std.crypto.secureZero(u8, &seed);
    var stdin_reader = std.Io.File.stdin().reader(defaultIo(), &.{});
    const input = try stdin_reader.interface.allocRemaining(allocator, .limited(MaxBytes));
    defer allocator.free(input);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const binary_fingerprint = try executableFingerprintAlloc(allocator);
    defer allocator.free(binary_fingerprint);
    const envelope = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(envelope, "schema"), "hylo-grade-presentation-envelope/v1")) {
        return error.InvalidArguments;
    }
    const presentation = try object(envelope.get("presentation") orelse return error.RequiredFieldMissing);
    const semantic_observation = envelope.get("semantic_observation") orelse
        return error.SemanticObservationMissing;
    const presentation_receipt_fingerprint = try requiredString(envelope, "grade_presentation_receipt_fingerprint");
    const identifier_alias_map_fingerprint = try requiredString(envelope, "identifier_alias_map_fingerprint");
    const receipt = if (std.mem.eql(u8, args[1], "absolute"))
        try absoluteReceiptAlloc(allocator, presentation, semantic_observation, presentation_receipt_fingerprint, identifier_alias_map_fingerprint, binary_fingerprint, seed)
    else if (std.mem.eql(u8, args[1], "pair"))
        try pairReceiptAlloc(allocator, presentation, semantic_observation, presentation_receipt_fingerprint, identifier_alias_map_fingerprint, binary_fingerprint, seed)
    else
        return error.InvalidArguments;
    defer allocator.free(receipt);
    const sealed_result = try sealedGradeResultAlloc(
        allocator,
        args[1],
        presentation,
        presentation_receipt_fingerprint,
        identifier_alias_map_fingerprint,
        binary_fingerprint,
        receipt,
        seed,
    );
    defer allocator.free(sealed_result);
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(sealed_result);
    try stdout_writer.interface.writeByte('\n');
}

test "sealed grade commitment" {
    const allocator = std.testing.allocator;
    const binary_fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const seed = [_]u8{0x42} ** 32;
    const unsigned_receipt =
        \\{"schema":"hylo-grade-receipt/v1","producer":{"id":"deterministic-grader","version":"v1","binary_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","key_id":"absolute-grader-key"},"attestation":null}
    ;
    const receipt = try attestation.signReceiptAlloc(allocator, unsigned_receipt, .{
        .id = "deterministic-grader",
        .version = "v1",
        .binary_fingerprint = binary_fingerprint,
        .key_id = "absolute-grader-key",
    }, "absolute_grader", 100, seed);
    defer allocator.free(receipt);
    var presentation = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"trial_id\":\"opaque-trial\",\"lane_id\":\"opaque-lane\"}",
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
    defer presentation.deinit();
    const result = try sealedGradeResultWithNonceAlloc(
        allocator,
        "absolute",
        try object(presentation.value),
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        binary_fingerprint,
        receipt,
        "0000000000000000000000000000000000000000000000000000000000000000",
        seed,
    );
    defer allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const envelope = try object(parsed.value);
    try requireExactKeys(envelope, &.{ "schema", "grade_commitment_fingerprint", "grade_commitment", "grade_opening" });
    try std.testing.expectEqualStrings("hylo-grade-sealed-result/v1", try requiredString(envelope, "schema"));
    const commitment = try object(try required(envelope, "grade_commitment"));
    try requireExactKeys(commitment, &.{ "schema", "kind", "grader_scope", "grade_presentation_receipt_fingerprint", "identifier_alias_map_fingerprint", "producer", "opening_nonce_contract", "commitment", "attestation" });
    try std.testing.expect(commitment.get("grade_receipt") == null);
    const commitment_fingerprint = try digestJsonAlloc(allocator, try required(envelope, "grade_commitment"));
    defer allocator.free(commitment_fingerprint);
    try std.testing.expectEqualStrings(
        commitment_fingerprint,
        try requiredString(envelope, "grade_commitment_fingerprint"),
    );
    const opening = try object(try required(envelope, "grade_opening"));
    try requireExactKeys(opening, &.{ "schema", "kind", "grade_commitment_fingerprint", "grader_scope", "opening_nonce_hex", "grade_receipt_fingerprint", "grade_receipt", "producer", "attestation" });
    try std.testing.expectEqualStrings(
        commitment_fingerprint,
        try requiredString(opening, "grade_commitment_fingerprint"),
    );
    _ = try object(try required(opening, "grade_receipt"));
}

fn createTestPipe() ![2]std.posix.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    while (true) switch (std.posix.errno(std.c.pipe(&fds))) {
        .SUCCESS => return .{ fds[0], fds[1] },
        .INTR => continue,
        else => return error.TestPipeCreationFailed,
    };
}

fn closeTestFd(fd: *std.posix.fd_t) void {
    if (fd.* >= 0) _ = std.c.close(fd.*);
    fd.* = -1;
}

fn writeTestBytes(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const count = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (std.posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) return error.TestPipeWriteFailed;
                written += @intCast(count);
            },
            .INTR => continue,
            else => return error.TestPipeWriteFailed,
        }
    }
}

fn openTestNamedFifo() !struct {
    tmp: std.testing.TmpDir,
    file: std.Io.File,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "named-fifo" });
    defer allocator.free(path);
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "mkfifo", "-m", "600", path },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return error.TestFifoCreationFailed;
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{ .mode = .read_write });
    return .{ .tmp = tmp, .file = file };
}

test "sealed grader rejects non-anonymous and wrong-direction capability endpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var regular = try tmp.dir.createFile(std.testing.io, "regular", .{ .read = true });
    defer regular.close(std.testing.io);
    try std.testing.expectError(
        error.CapabilityEndpointInvalid,
        validateAnonymousEndpoint(regular.handle, .read_only, false),
    );

    var fifo = try openTestNamedFifo();
    defer {
        fifo.file.close(std.testing.io);
        fifo.tmp.cleanup();
    }
    try std.testing.expectError(
        error.CapabilityEndpointInvalid,
        validateAnonymousEndpoint(fifo.file.handle, .read_only, false),
    );

    var pipe = try createTestPipe();
    defer {
        closeTestFd(&pipe[0]);
        closeTestFd(&pipe[1]);
    }
    try std.testing.expectError(
        error.CapabilityEndpointInvalid,
        validateAnonymousEndpoint(pipe[1], .read_only, false),
    );
}

test "sealed grader rejects aliased capability endpoints" {
    var input = try createTestPipe();
    defer {
        closeTestFd(&input[0]);
        closeTestFd(&input[1]);
    }
    var output = try createTestPipe();
    defer {
        closeTestFd(&output[0]);
        closeTestFd(&output[1]);
    }
    try std.testing.expectError(
        error.CapabilityEndpointAlias,
        validateTransportEndpoints(input[0], output[1], input[0]),
    );
}

test "sealed grader detects an inherited descriptor above 64" {
    var pipe = try createTestPipe();
    defer {
        closeTestFd(&pipe[0]);
        closeTestFd(&pipe[1]);
    }
    const duplicate_result = std.posix.system.fcntl(
        pipe[0],
        std.posix.F.DUPFD_CLOEXEC,
        @as(usize, 65),
    );
    var leaked_fd: std.posix.fd_t = switch (std.posix.errno(duplicate_result)) {
        .SUCCESS => @intCast(duplicate_result),
        else => return error.TestFdDuplicationFailed,
    };
    defer closeTestFd(&leaked_fd);
    const raw_leaked_fd: usize = @intCast(leaked_fd);
    try std.testing.expect(raw_leaked_fd > 64);
    try std.testing.expect(raw_leaked_fd < try descriptorScanLimit());
    try std.testing.expectError(
        error.GraderInheritedFdLeak,
        requireClosedDescriptorRange(raw_leaked_fd, raw_leaked_fd + 1),
    );
}

test "sealed grader accepts exactly one raw key and rejects trailing bytes" {
    const key = [_]u8{0x5a} ** 32;
    var exact = try createTestPipe();
    defer {
        closeTestFd(&exact[0]);
        closeTestFd(&exact[1]);
    }
    try writeTestBytes(exact[1], &key);
    closeTestFd(&exact[1]);
    var observed = try readKey(exact[0]);
    defer std.crypto.secureZero(u8, &observed);
    try std.testing.expectEqualSlices(u8, &key, &observed);

    var trailing = try createTestPipe();
    defer {
        closeTestFd(&trailing[0]);
        closeTestFd(&trailing[1]);
    }
    var oversized: [33]u8 = [_]u8{0x5a} ** 33;
    defer std.crypto.secureZero(u8, &oversized);
    try writeTestBytes(trailing[1], &oversized);
    closeTestFd(&trailing[1]);
    try std.testing.expectError(error.KeyInvalid, readKey(trailing[0]));
}
