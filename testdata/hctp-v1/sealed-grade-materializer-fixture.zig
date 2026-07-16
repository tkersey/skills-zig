const std = @import("std");
const durable_store = @import("durable_store");
const retrace_core = @import("retrace_core");

const attestation = retrace_core.hctp_attestation;
const MaxBytes = 64 * 1024 * 1024;

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

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(try required(map, key));
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
        return error.MaterializerDescriptorLimitUnavailable;
    const max_fd_t: usize = @intCast(std.math.maxInt(std.posix.fd_t));
    const max_c_int: usize = @intCast(std.math.maxInt(c_int));
    const max_inspectable_fd: usize = @min(max_fd_t, max_c_int);
    const soft_limit = std.math.cast(usize, limits.cur) orelse
        return error.MaterializerDescriptorLimitInvalid;
    return @min(soft_limit, max_inspectable_fd + 1);
}

fn requireClosedDescriptorRange(first: usize, end_exclusive: usize) !void {
    const scan_limit = try descriptorScanLimit();
    if (first > end_exclusive or end_exclusive > scan_limit) {
        return error.MaterializerDescriptorRangeInvalid;
    }
    var raw_fd = first;
    while (raw_fd < end_exclusive) : (raw_fd += 1) {
        const fd = std.math.cast(std.posix.fd_t, raw_fd) orelse
            return error.MaterializerDescriptorRangeInvalid;
        while (true) {
            const result = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
            switch (std.posix.errno(result)) {
                .SUCCESS => return error.MaterializerInheritedFdLeak,
                .BADF => break,
                .INTR => continue,
                else => return error.MaterializerFdInspectionFailed,
            }
        }
    }
}

fn verifyExecutionBoundary(seed_fd: std.posix.fd_t) !void {
    if (seed_fd != 3) return error.MaterializerSeedFdInvalid;
    try validateTransportEndpoints(
        std.posix.STDIN_FILENO,
        std.posix.STDOUT_FILENO,
        seed_fd,
    );
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

fn digestJsonTextAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    return digestJsonAlloc(allocator, parsed.value);
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

pub fn executableFingerprintAlloc(allocator: std.mem.Allocator) ![]u8 {
    const path = try std.process.executablePathAlloc(defaultIo(), allocator);
    defer allocator.free(path);
    const bytes = try durable_store.readFileAlloc(allocator, path, MaxBytes);
    defer allocator.free(bytes);
    return digestBytesAlloc(allocator, bytes);
}

fn validateAbsolutePresentation(presentation: std.json.ObjectMap) !void {
    try requireExactKeys(presentation, &.{
        "schema",
        "trial_id",
        "lane_id",
        "opaque_arm_id",
        "run_receipt_fingerprint",
        "output_fingerprint",
        "trace_fingerprint",
        "rubric_fingerprint",
    });
    if (!std.mem.eql(u8, try requiredString(presentation, "schema"), "hylo-blind-absolute-presentation/v1")) {
        return error.PresentationInvalid;
    }
}

fn validatePairPresentation(presentation: std.json.ObjectMap) !void {
    try requireExactKeys(presentation, &.{
        "schema",
        "trial_id",
        "pair_id",
        "left_lane_id",
        "left_output_fingerprint",
        "right_lane_id",
        "right_output_fingerprint",
        "position_map_commitment",
        "rubric_fingerprint",
    });
    if (!std.mem.eql(u8, try requiredString(presentation, "schema"), "hylo-blind-pair-presentation/v1")) {
        return error.PresentationInvalid;
    }
}

fn requireOpaqueAlias(value: []const u8) !void {
    if (value.len != "opaque-".len + 64 or !std.mem.startsWith(u8, value, "opaque-")) {
        return error.IdentifierAliasInvalid;
    }
    for (value["opaque-".len..]) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.IdentifierAliasInvalid;
        }
    }
}

fn stringAt(items: std.json.Array, index: usize) ![]const u8 {
    if (index >= items.items.len) return error.IdentifierAliasInvalid;
    return switch (items.items[index]) {
        .string => |text| text,
        else => error.IdentifierAliasInvalid,
    };
}

fn expectEqualField(left: std.json.ObjectMap, right: std.json.ObjectMap, key: []const u8) !void {
    if (!std.mem.eql(u8, try requiredString(left, key), try requiredString(right, key))) {
        return error.IdentifierAliasInvalid;
    }
}

fn validateIdentifierAliases(
    allocator: std.mem.Allocator,
    kind: []const u8,
    unit_id: []const u8,
    native: std.json.ObjectMap,
    grader: std.json.ObjectMap,
    map_value: std.json.Value,
) !struct { fingerprint: []u8, aliases_json: []u8 } {
    const alias_map = try object(map_value);
    try requireExactKeys(alias_map, &.{ "schema", "kind", "registered", "aliases" });
    if (!std.mem.eql(u8, try requiredString(alias_map, "schema"), "hylo-grade-identifier-alias-map/v1") or
        !std.mem.eql(u8, try requiredString(alias_map, "kind"), kind))
    {
        return error.IdentifierAliasInvalid;
    }
    const registered = try requiredObject(alias_map, "registered");
    const aliases = try requiredObject(alias_map, "aliases");
    inline for (.{ registered, aliases }) |side| try requireExactKeys(side, &.{
        "trial_id",
        "unit_id",
        "pair_ids",
        "lane_ids",
        "opaque_arm_id",
    });
    if (!std.mem.eql(u8, try requiredString(registered, "trial_id"), try requiredString(native, "trial_id")) or
        !std.mem.eql(u8, try requiredString(registered, "unit_id"), unit_id) or
        !std.mem.eql(u8, try requiredString(aliases, "trial_id"), try requiredString(grader, "trial_id")))
    {
        return error.IdentifierAliasInvalid;
    }
    const registered_lanes = try requiredArray(registered, "lane_ids");
    const alias_lanes = try requiredArray(aliases, "lane_ids");
    const registered_pairs = try requiredArray(registered, "pair_ids");
    const alias_pairs = try requiredArray(aliases, "pair_ids");
    const absolute = std.mem.eql(u8, kind, "absolute");
    const expected_lane_count: usize = if (absolute) 1 else 2;
    const expected_pair_count: usize = if (absolute) 0 else 1;
    if (registered_lanes.items.len != expected_lane_count or
        alias_lanes.items.len != registered_lanes.items.len or
        registered_pairs.items.len != expected_pair_count or
        alias_pairs.items.len != registered_pairs.items.len)
    {
        return error.IdentifierAliasInvalid;
    }
    if (absolute) {
        if (!std.mem.eql(u8, try stringAt(registered_lanes, 0), try requiredString(native, "lane_id")) or
            !std.mem.eql(u8, try stringAt(alias_lanes, 0), try requiredString(grader, "lane_id")) or
            !std.mem.eql(u8, try requiredString(registered, "opaque_arm_id"), try requiredString(native, "opaque_arm_id")) or
            !std.mem.eql(u8, try requiredString(aliases, "opaque_arm_id"), try requiredString(grader, "opaque_arm_id")))
        {
            return error.IdentifierAliasInvalid;
        }
        inline for (.{ "run_receipt_fingerprint", "output_fingerprint", "trace_fingerprint", "rubric_fingerprint" }) |key| {
            try expectEqualField(native, grader, key);
        }
    } else {
        if ((try required(registered, "opaque_arm_id")) != .null or
            (try required(aliases, "opaque_arm_id")) != .null or
            !std.mem.eql(u8, try stringAt(registered_pairs, 0), try requiredString(native, "pair_id")) or
            !std.mem.eql(u8, try stringAt(alias_pairs, 0), try requiredString(grader, "pair_id")) or
            !std.mem.eql(u8, try stringAt(registered_lanes, 0), try requiredString(native, "left_lane_id")) or
            !std.mem.eql(u8, try stringAt(registered_lanes, 1), try requiredString(native, "right_lane_id")) or
            !std.mem.eql(u8, try stringAt(alias_lanes, 0), try requiredString(grader, "left_lane_id")) or
            !std.mem.eql(u8, try stringAt(alias_lanes, 1), try requiredString(grader, "right_lane_id")))
        {
            return error.IdentifierAliasInvalid;
        }
        inline for (.{
            "left_output_fingerprint",
            "right_output_fingerprint",
            "rubric_fingerprint",
        }) |key| try expectEqualField(native, grader, key);
        if ((try required(native, "position_map_commitment")) != .null or
            (try required(grader, "position_map_commitment")) != .null)
        {
            return error.IdentifierAliasInvalid;
        }
    }

    var opaque_values: [5][]const u8 = undefined;
    var opaque_count: usize = 0;
    inline for (.{ "trial_id", "unit_id" }) |key| {
        opaque_values[opaque_count] = try requiredString(aliases, key);
        opaque_count += 1;
    }
    for (alias_pairs.items) |value| {
        opaque_values[opaque_count] = switch (value) {
            .string => |text| text,
            else => return error.IdentifierAliasInvalid,
        };
        opaque_count += 1;
    }
    for (alias_lanes.items) |value| {
        opaque_values[opaque_count] = switch (value) {
            .string => |text| text,
            else => return error.IdentifierAliasInvalid,
        };
        opaque_count += 1;
    }
    if (absolute) {
        opaque_values[opaque_count] = try requiredString(aliases, "opaque_arm_id");
        opaque_count += 1;
    }
    for (opaque_values[0..opaque_count], 0..) |value, index| {
        try requireOpaqueAlias(value);
        for (opaque_values[0..index]) |prior| {
            if (std.mem.eql(u8, value, prior)) return error.IdentifierAliasInvalid;
        }
    }

    return .{
        .fingerprint = try digestJsonAlloc(allocator, map_value),
        .aliases_json = try attestation.canonicalJsonAlloc(allocator, try required(alias_map, "aliases")),
    };
}

const SemanticObservationEvidence = struct {
    fingerprint: []u8,
    canonical: []u8,
    output_fingerprints: [2]?[]const u8 = .{ null, null },
    output_byte_counts: [2]usize = .{ 0, 0 },
    output_count: usize = 0,
    trace_fingerprints: [1]?[]const u8 = .{null},
    trace_byte_counts: [1]usize = .{0},
    trace_count: usize = 0,

    fn deinit(self: SemanticObservationEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
        allocator.free(self.canonical);
    }
};

fn validateSemanticCarrierAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    expected_slot: []const u8,
    expected_fingerprint: []const u8,
) !usize {
    const carrier = try object(value);
    try requireExactKeys(carrier, &.{ "slot", "fingerprint", "size_bytes", "content_base64" });
    if (!std.mem.eql(u8, try requiredString(carrier, "slot"), expected_slot) or
        !std.mem.eql(u8, try requiredString(carrier, "fingerprint"), expected_fingerprint))
    {
        return error.SemanticObservationInvalid;
    }
    const decoded = try base64DecodeAlloc(allocator, try requiredString(carrier, "content_base64"));
    defer allocator.free(decoded);
    if (decoded.len == 0 or decoded.len != try requiredUsize(carrier, "size_bytes")) {
        return error.SemanticObservationInvalid;
    }
    const fingerprint = try digestBytesAlloc(allocator, decoded);
    defer allocator.free(fingerprint);
    if (!std.mem.eql(u8, fingerprint, expected_fingerprint)) {
        return error.SemanticObservationFingerprintMismatch;
    }
    return decoded.len;
}

fn validateSemanticObservationAlloc(
    allocator: std.mem.Allocator,
    kind: []const u8,
    native: std.json.ObjectMap,
    observation_value: std.json.Value,
) !SemanticObservationEvidence {
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
    var evidence = SemanticObservationEvidence{
        .fingerprint = try digestJsonAlloc(allocator, observation_value),
        .canonical = try attestation.canonicalJsonAlloc(allocator, observation_value),
    };
    errdefer evidence.deinit(allocator);
    if (absolute) {
        const output_fingerprint = try requiredString(native, "output_fingerprint");
        const trace_fingerprint = try requiredString(native, "trace_fingerprint");
        evidence.output_fingerprints[0] = output_fingerprint;
        evidence.output_byte_counts[0] = try validateSemanticCarrierAlloc(
            allocator,
            outputs.items[0],
            "output",
            output_fingerprint,
        );
        evidence.output_count = 1;
        evidence.trace_fingerprints[0] = trace_fingerprint;
        evidence.trace_byte_counts[0] = try validateSemanticCarrierAlloc(
            allocator,
            traces.items[0],
            "trace",
            trace_fingerprint,
        );
        evidence.trace_count = 1;
    } else {
        inline for (.{
            .{ 0, "left_output", "left_output_fingerprint" },
            .{ 1, "right_output", "right_output_fingerprint" },
        }) |expected| {
            const fingerprint = try requiredString(native, expected[2]);
            evidence.output_fingerprints[expected[0]] = fingerprint;
            evidence.output_byte_counts[expected[0]] = try validateSemanticCarrierAlloc(
                allocator,
                outputs.items[expected[0]],
                expected[1],
                fingerprint,
            );
        }
        evidence.output_count = 2;
    }
    return evidence;
}

fn pairPresentationAlloc(
    allocator: std.mem.Allocator,
    presentation: std.json.ObjectMap,
    position_map_commitment: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-blind-pair-presentation/v1\",\"trial_id\":{f},\"pair_id\":{f},\"left_lane_id\":{f},\"left_output_fingerprint\":{f},\"right_lane_id\":{f},\"right_output_fingerprint\":{f},\"position_map_commitment\":{f},\"rubric_fingerprint\":{f}}}",
        .{
            std.json.fmt(try requiredString(presentation, "trial_id"), .{}),
            std.json.fmt(try requiredString(presentation, "pair_id"), .{}),
            std.json.fmt(try requiredString(presentation, "left_lane_id"), .{}),
            std.json.fmt(try requiredString(presentation, "left_output_fingerprint"), .{}),
            std.json.fmt(try requiredString(presentation, "right_lane_id"), .{}),
            std.json.fmt(try requiredString(presentation, "right_output_fingerprint"), .{}),
            std.json.fmt(position_map_commitment, .{}),
            std.json.fmt(try requiredString(presentation, "rubric_fingerprint"), .{}),
        },
    );
}

pub fn positionMapCommitmentAlloc(
    allocator: std.mem.Allocator,
    left_alias: []const u8,
    right_alias: []const u8,
    nonce: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-pair-grade-position-map/v1\",\"left_lane_id\":{f},\"right_lane_id\":{f},\"nonce\":{f}}}",
        .{ std.json.fmt(left_alias, .{}), std.json.fmt(right_alias, .{}), std.json.fmt(nonce, .{}) },
    );
    defer allocator.free(body);
    return digestJsonTextAlloc(allocator, body);
}

pub fn carrierAlloc(
    allocator: std.mem.Allocator,
    request: std.json.ObjectMap,
    seed: [32]u8,
) ![]u8 {
    try requireExactKeys(request, &.{
        "schema",
        "kind",
        "unit_id",
        "grader_binary_fingerprint",
        "materializer_binary_fingerprint",
        "run_receipt_fingerprints",
        "identifier_alias_map",
        "grader_presentation",
        "presentation",
        "semantic_observation",
    });
    if (!std.mem.eql(u8, try requiredString(request, "schema"), "hylo-grade-presentation-materialization-request/v1")) {
        return error.InvalidRequest;
    }
    const kind = try requiredString(request, "kind");
    const absolute = std.mem.eql(u8, kind, "absolute");
    if (!absolute and !std.mem.eql(u8, kind, "pair")) return error.InvalidRequest;
    const presentation_value = try required(request, "presentation");
    const presentation = try object(presentation_value);
    const grader_presentation_value = try required(request, "grader_presentation");
    const grader_presentation = try object(grader_presentation_value);
    const run_receipt_fingerprints = switch (try required(request, "run_receipt_fingerprints")) {
        .array => |items| items,
        else => return error.ArrayRequired,
    };
    if (absolute) {
        try validateAbsolutePresentation(presentation);
        try validateAbsolutePresentation(grader_presentation);
    } else {
        try validatePairPresentation(presentation);
        try validatePairPresentation(grader_presentation);
    }
    const expected_run_receipts: usize = if (absolute) 1 else 2;
    if (run_receipt_fingerprints.items.len != expected_run_receipts) return error.PresentationInvalid;
    for (run_receipt_fingerprints.items) |value| if (value != .string) return error.PresentationInvalid;
    const trial_id = try requiredString(presentation, "trial_id");
    const unit_id = try requiredString(request, "unit_id");
    const alias_evidence = try validateIdentifierAliases(
        allocator,
        kind,
        unit_id,
        presentation,
        grader_presentation,
        try required(request, "identifier_alias_map"),
    );
    defer allocator.free(alias_evidence.fingerprint);
    defer allocator.free(alias_evidence.aliases_json);
    const materializer_fingerprint = try requiredString(request, "materializer_binary_fingerprint");
    const observed_fingerprint = try executableFingerprintAlloc(allocator);
    defer allocator.free(observed_fingerprint);
    if (!std.mem.eql(u8, materializer_fingerprint, observed_fingerprint)) return error.MaterializerBinaryMismatch;
    const semantic_observation = try validateSemanticObservationAlloc(
        allocator,
        kind,
        presentation,
        try required(request, "semantic_observation"),
    );
    defer semantic_observation.deinit(allocator);

    var position_nonce_bytes: [32]u8 = undefined;
    var position_nonce_hex: [64]u8 = undefined;
    var position_map_commitment: ?[]u8 = null;
    defer if (position_map_commitment) |value| allocator.free(value);
    if (!absolute) {
        if (libc.getentropy(&position_nonce_bytes, position_nonce_bytes.len) != 0) {
            return error.MaterializerEntropyUnavailable;
        }
        position_nonce_hex = std.fmt.bytesToHex(position_nonce_bytes, .lower);
        position_map_commitment = try positionMapCommitmentAlloc(
            allocator,
            try requiredString(grader_presentation, "left_lane_id"),
            try requiredString(grader_presentation, "right_lane_id"),
            &position_nonce_hex,
        );
    }
    const finalized_presentation = if (absolute)
        try attestation.canonicalJsonAlloc(allocator, presentation_value)
    else
        try pairPresentationAlloc(allocator, presentation, position_map_commitment.?);
    defer allocator.free(finalized_presentation);
    const finalized_grader_presentation = if (absolute)
        try attestation.canonicalJsonAlloc(allocator, grader_presentation_value)
    else
        try pairPresentationAlloc(allocator, grader_presentation, position_map_commitment.?);
    defer allocator.free(finalized_grader_presentation);
    const presentation_fingerprint = try digestJsonTextAlloc(allocator, finalized_presentation);
    defer allocator.free(presentation_fingerprint);
    const grader_presentation_fingerprint = try digestJsonTextAlloc(allocator, finalized_grader_presentation);
    defer allocator.free(grader_presentation_fingerprint);
    const capability_preimage = try std.fmt.allocPrint(
        allocator,
        "hctp-grade-capability/v1\x00{s}\x00{s}\x00{s}\x00{s}",
        .{
            presentation_fingerprint,
            grader_presentation_fingerprint,
            alias_evidence.fingerprint,
            semantic_observation.fingerprint,
        },
    );
    defer allocator.free(capability_preimage);
    const capability_digest = try digestBytesAlloc(allocator, capability_preimage);
    defer allocator.free(capability_digest);
    const grader_binary_fingerprint = try requiredString(request, "grader_binary_fingerprint");
    const grader_id = if (absolute) "deterministic-grader" else "blind-pair-grader";
    const grader_role = if (absolute) "absolute_grader" else "pair_grader";
    const grader_key = if (absolute) "absolute-grader-key" else "pair-grader-key";
    const allowed_inputs = if (absolute)
        "[\"output\",\"trace\",\"rubric\"]"
    else
        "[\"sibling_outputs\",\"rubric\",\"position_map_commitment\"]";
    const sibling_outputs = !absolute;
    const semantic_observation_receipt = if (absolute)
        try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hylo-grade-semantic-observation-receipt/v1\",\"observation_fingerprint\":{f},\"output_fingerprints\":[{f}],\"output_byte_counts\":[{d}],\"trace_fingerprints\":[{f}],\"trace_byte_counts\":[{d}],\"carrier_encoding\":\"base64\",\"semantic_bytes_presented\":true}}",
            .{
                std.json.fmt(semantic_observation.fingerprint, .{}),
                std.json.fmt(semantic_observation.output_fingerprints[0].?, .{}),
                semantic_observation.output_byte_counts[0],
                std.json.fmt(semantic_observation.trace_fingerprints[0].?, .{}),
                semantic_observation.trace_byte_counts[0],
            },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hylo-grade-semantic-observation-receipt/v1\",\"observation_fingerprint\":{f},\"output_fingerprints\":[{f},{f}],\"output_byte_counts\":[{d},{d}],\"trace_fingerprints\":[],\"trace_byte_counts\":[],\"carrier_encoding\":\"base64\",\"semantic_bytes_presented\":true}}",
            .{
                std.json.fmt(semantic_observation.fingerprint, .{}),
                std.json.fmt(semantic_observation.output_fingerprints[0].?, .{}),
                std.json.fmt(semantic_observation.output_fingerprints[1].?, .{}),
                semantic_observation.output_byte_counts[0],
                semantic_observation.output_byte_counts[1],
            },
        );
    defer allocator.free(semantic_observation_receipt);

    const unsigned = if (absolute)
        try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hylo-grade-presentation-receipt/v1\",\"trial_id\":{f},\"kind\":\"absolute\",\"scope\":{{\"lane_ids\":[{f}],\"pair_ids\":[],\"unit_ids\":[{f}],\"unit_count\":1,\"lane_count\":1,\"pair_count\":0}},\"grader\":{{\"role\":{f},\"id\":{f},\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":{f}}},\"capability_scope\":{{\"capability_digest\":{f},\"trial_id\":{f},\"lane_ids\":[{f}],\"pair_ids\":[],\"allowed_inputs\":{s},\"single_use\":true}},\"presentation\":{{\"schema\":\"hylo-blind-absolute-presentation/v1\",\"presentation_fingerprint\":{f},\"grader_presentation_fingerprint\":{f},\"identifier_alias_map_fingerprint\":{f},\"identifier_aliases\":{s},\"run_receipt_fingerprints\":[{f}],\"output_fingerprints\":[{f}],\"trace_fingerprints\":[{f}],\"rubric_fingerprint\":{f},\"position_map_commitment\":null,\"position_map_nonce\":null}},\"semantic_observation\":{s},\"delivery\":{{\"method\":\"anonymous_fd\",\"receiver_binding\":\"grader_key\",\"receiver_role\":{f},\"receiver_key_id\":{f},\"single_use\":true}},\"disclosure\":{{\"semantic_arm_identity\":false,\"target_diff\":false,\"lane_execution_order\":false,\"prior_grades\":false,\"hidden_reference\":false,\"sibling_outputs\":{},\"registered_identifiers\":false}},\"execution\":{{\"separate_process\":true,\"os_confinement\":false,\"inherited_capability_fds\":[0,1,2,3]}},\"producer\":{{\"id\":\"hctp-grade-broker\",\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":\"materializer-key\"}},\"attestation\":null}}",
            .{
                std.json.fmt(trial_id, .{}),
                std.json.fmt(try requiredString(presentation, "lane_id"), .{}),
                std.json.fmt(unit_id, .{}),
                std.json.fmt(grader_role, .{}),
                std.json.fmt(grader_id, .{}),
                std.json.fmt(grader_binary_fingerprint, .{}),
                std.json.fmt(grader_key, .{}),
                std.json.fmt(capability_digest, .{}),
                std.json.fmt(trial_id, .{}),
                std.json.fmt(try requiredString(presentation, "lane_id"), .{}),
                allowed_inputs,
                std.json.fmt(presentation_fingerprint, .{}),
                std.json.fmt(grader_presentation_fingerprint, .{}),
                std.json.fmt(alias_evidence.fingerprint, .{}),
                alias_evidence.aliases_json,
                std.json.fmt(run_receipt_fingerprints.items[0].string, .{}),
                std.json.fmt(try requiredString(presentation, "output_fingerprint"), .{}),
                std.json.fmt(try requiredString(presentation, "trace_fingerprint"), .{}),
                std.json.fmt(try requiredString(presentation, "rubric_fingerprint"), .{}),
                semantic_observation_receipt,
                std.json.fmt(grader_role, .{}),
                std.json.fmt(grader_key, .{}),
                sibling_outputs,
                std.json.fmt(materializer_fingerprint, .{}),
            },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"hylo-grade-presentation-receipt/v1\",\"trial_id\":{f},\"kind\":\"pair\",\"scope\":{{\"lane_ids\":[{f},{f}],\"pair_ids\":[{f}],\"unit_ids\":[{f}],\"unit_count\":1,\"lane_count\":2,\"pair_count\":1}},\"grader\":{{\"role\":{f},\"id\":{f},\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":{f}}},\"capability_scope\":{{\"capability_digest\":{f},\"trial_id\":{f},\"lane_ids\":[{f},{f}],\"pair_ids\":[{f}],\"allowed_inputs\":{s},\"single_use\":true}},\"presentation\":{{\"schema\":\"hylo-blind-pair-presentation/v1\",\"presentation_fingerprint\":{f},\"grader_presentation_fingerprint\":{f},\"identifier_alias_map_fingerprint\":{f},\"identifier_aliases\":{s},\"run_receipt_fingerprints\":[{f},{f}],\"output_fingerprints\":[{f},{f}],\"trace_fingerprints\":[],\"rubric_fingerprint\":{f},\"position_map_commitment\":{f},\"position_map_nonce\":{f}}},\"semantic_observation\":{s},\"delivery\":{{\"method\":\"anonymous_fd\",\"receiver_binding\":\"grader_key\",\"receiver_role\":{f},\"receiver_key_id\":{f},\"single_use\":true}},\"disclosure\":{{\"semantic_arm_identity\":false,\"target_diff\":false,\"lane_execution_order\":false,\"prior_grades\":false,\"hidden_reference\":false,\"sibling_outputs\":{},\"registered_identifiers\":false}},\"execution\":{{\"separate_process\":true,\"os_confinement\":false,\"inherited_capability_fds\":[0,1,2,3]}},\"producer\":{{\"id\":\"hctp-grade-broker\",\"version\":\"v1\",\"binary_fingerprint\":{f},\"key_id\":\"materializer-key\"}},\"attestation\":null}}",
            .{
                std.json.fmt(trial_id, .{}),
                std.json.fmt(try requiredString(presentation, "left_lane_id"), .{}),
                std.json.fmt(try requiredString(presentation, "right_lane_id"), .{}),
                std.json.fmt(try requiredString(presentation, "pair_id"), .{}),
                std.json.fmt(unit_id, .{}),
                std.json.fmt(grader_role, .{}),
                std.json.fmt(grader_id, .{}),
                std.json.fmt(grader_binary_fingerprint, .{}),
                std.json.fmt(grader_key, .{}),
                std.json.fmt(capability_digest, .{}),
                std.json.fmt(trial_id, .{}),
                std.json.fmt(try requiredString(presentation, "left_lane_id"), .{}),
                std.json.fmt(try requiredString(presentation, "right_lane_id"), .{}),
                std.json.fmt(try requiredString(presentation, "pair_id"), .{}),
                allowed_inputs,
                std.json.fmt(presentation_fingerprint, .{}),
                std.json.fmt(grader_presentation_fingerprint, .{}),
                std.json.fmt(alias_evidence.fingerprint, .{}),
                alias_evidence.aliases_json,
                std.json.fmt(run_receipt_fingerprints.items[0].string, .{}),
                std.json.fmt(run_receipt_fingerprints.items[1].string, .{}),
                std.json.fmt(try requiredString(presentation, "left_output_fingerprint"), .{}),
                std.json.fmt(try requiredString(presentation, "right_output_fingerprint"), .{}),
                std.json.fmt(try requiredString(presentation, "rubric_fingerprint"), .{}),
                std.json.fmt(position_map_commitment.?, .{}),
                std.json.fmt(position_nonce_hex[0..], .{}),
                semantic_observation_receipt,
                std.json.fmt(grader_role, .{}),
                std.json.fmt(grader_key, .{}),
                sibling_outputs,
                std.json.fmt(materializer_fingerprint, .{}),
            },
        );
    defer allocator.free(unsigned);
    const signed_receipt = try attestation.signReceiptAlloc(allocator, unsigned, .{
        .id = "hctp-grade-broker",
        .version = "v1",
        .binary_fingerprint = materializer_fingerprint,
        .key_id = "materializer-key",
    }, "materializer", 100, seed);
    defer allocator.free(signed_receipt);
    const receipt_fingerprint = try digestJsonTextAlloc(allocator, signed_receipt);
    defer allocator.free(receipt_fingerprint);
    const grader_envelope = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-presentation-envelope/v1\",\"grade_presentation_receipt_fingerprint\":{f},\"identifier_alias_map_fingerprint\":{f},\"presentation\":{s},\"semantic_observation\":{s}}}",
        .{
            std.json.fmt(receipt_fingerprint, .{}),
            std.json.fmt(alias_evidence.fingerprint, .{}),
            finalized_grader_presentation,
            semantic_observation.canonical,
        },
    );
    defer allocator.free(grader_envelope);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-grade-presentation-materialization-response/v1\",\"grade_presentation_receipt\":{s},\"grader_envelope\":{s}}}",
        .{ signed_receipt, grader_envelope },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--seed-fd")) return error.InvalidArguments;
    const seed_fd = try parseFd(args[2]);
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
    const carrier = try carrierAlloc(allocator, try object(parsed.value), seed);
    defer allocator.free(carrier);
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(carrier);
    try stdout_writer.interface.writeByte('\n');
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

test "sealed grade materializer rejects non-anonymous and wrong-direction capability endpoints" {
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

test "sealed grade materializer rejects aliased capability endpoints" {
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

test "sealed grade materializer detects an inherited descriptor above 64" {
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
        error.MaterializerInheritedFdLeak,
        requireClosedDescriptorRange(raw_leaked_fd, raw_leaked_fd + 1),
    );
}

test "sealed grade materializer accepts exactly one raw key and rejects trailing bytes" {
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
