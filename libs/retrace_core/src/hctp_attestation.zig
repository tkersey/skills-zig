const std = @import("std");
const canonical_json = @import("canonical_json.zig");

pub const Producer = struct {
    id: []const u8,
    version: []const u8,
    binary_fingerprint: []const u8,
    key_id: []const u8,
};

pub fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return canonical_json.digestBytesAlloc(allocator, bytes);
}

pub fn digestValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return canonical_json.digestValueAlloc(allocator, value);
}

pub fn subjectFingerprintAlloc(allocator: std.mem.Allocator, subject: std.json.Value) ![]u8 {
    _ = try object(subject);
    const bytes = try canonical_json.canonicalObjectOmittingKeyAlloc(allocator, subject, "attestation");
    defer allocator.free(bytes);
    return digestBytesAlloc(allocator, bytes);
}

pub fn signReceiptAlloc(
    allocator: std.mem.Allocator,
    receipt_text: []const u8,
    producer: Producer,
    role: []const u8,
    issued_at_unix: i64,
    seed: [32]u8,
) ![]u8 {
    var receipt_parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt_text, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer receipt_parsed.deinit();
    const receipt = try object(receipt_parsed.value);
    const subject_schema = try requiredString(receipt, "schema");
    const subject_fingerprint = try subjectFingerprintAlloc(allocator, receipt_parsed.value);
    defer allocator.free(subject_fingerprint);

    const unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-attestation/v1\",\"subject_schema\":{f},\"subject_fingerprint\":{f},\"producer_id\":{f},\"producer_version\":{f},\"binary_fingerprint\":{f},\"key_id\":{f},\"role\":{f},\"issued_at_unix\":{d},\"signature\":{{\"algorithm\":\"ed25519\",\"value_base64\":\"\"}}}}",
        .{
            std.json.fmt(subject_schema, .{}),
            std.json.fmt(subject_fingerprint, .{}),
            std.json.fmt(producer.id, .{}),
            std.json.fmt(producer.version, .{}),
            std.json.fmt(producer.binary_fingerprint, .{}),
            std.json.fmt(producer.key_id, .{}),
            std.json.fmt(role, .{}),
            issued_at_unix,
        },
    );
    defer allocator.free(unsigned);
    var attestation_parsed = try std.json.parseFromSlice(std.json.Value, allocator, unsigned, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer attestation_parsed.deinit();
    const attestation = try object(attestation_parsed.value);
    const preimage = try attestationPreimageAlloc(allocator, attestation);
    defer allocator.free(preimage);
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const signature = try key_pair.sign(preimage, null);
    const signature_bytes = signature.toBytes();
    var encoded_buffer: [std.base64.standard.Encoder.calcSize(signature_bytes.len)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, &signature_bytes);

    const signed = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-attestation/v1\",\"subject_schema\":{f},\"subject_fingerprint\":{f},\"producer_id\":{f},\"producer_version\":{f},\"binary_fingerprint\":{f},\"key_id\":{f},\"role\":{f},\"issued_at_unix\":{d},\"signature\":{{\"algorithm\":\"ed25519\",\"value_base64\":{f}}}}}",
        .{
            std.json.fmt(subject_schema, .{}),
            std.json.fmt(subject_fingerprint, .{}),
            std.json.fmt(producer.id, .{}),
            std.json.fmt(producer.version, .{}),
            std.json.fmt(producer.binary_fingerprint, .{}),
            std.json.fmt(producer.key_id, .{}),
            std.json.fmt(role, .{}),
            issued_at_unix,
            std.json.fmt(encoded, .{}),
        },
    );
    defer allocator.free(signed);
    var signed_parsed = try std.json.parseFromSlice(std.json.Value, allocator, signed, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer signed_parsed.deinit();
    return canonicalObjectReplacingAlloc(allocator, receipt, "attestation", signed_parsed.value);
}

pub fn publicKeyBase64Alloc(allocator: std.mem.Allocator, seed: [32]u8) ![]u8 {
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const bytes = key_pair.public_key.toBytes();
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const result = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(result, &bytes);
    return result;
}

pub fn canonicalJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return canonical_json.canonicalJsonAlloc(allocator, value);
}

fn attestationPreimageAlloc(allocator: std.mem.Allocator, attestation: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = attestation.iterator();
    while (iterator.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    sortKeys(keys.items);
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try out.writer.writeByte(',');
        try canonical_json.writeCanonicalString(&out.writer, key);
        try out.writer.writeByte(':');
        if (std.mem.eql(u8, key, "signature")) {
            try writeCanonicalObjectOmitting(
                allocator,
                &out.writer,
                try object(attestation.get(key).?),
                "value_base64",
            );
        } else {
            try canonical_json.writeCanonicalJson(allocator, &out.writer, attestation.get(key).?);
        }
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeCanonicalObjectOmitting(
    allocator: std.mem.Allocator,
    writer: anytype,
    value: std.json.ObjectMap,
    omitted_key: []const u8,
) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = value.iterator();
    while (iterator.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, omitted_key)) try keys.append(allocator, entry.key_ptr.*);
    }
    sortKeys(keys.items);
    try writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try writer.writeByte(',');
        try canonical_json.writeCanonicalString(writer, key);
        try writer.writeByte(':');
        try canonical_json.writeCanonicalJson(allocator, writer, value.get(key).?);
    }
    try writer.writeByte('}');
}

fn canonicalObjectReplacingAlloc(
    allocator: std.mem.Allocator,
    object_value: std.json.ObjectMap,
    replaced_key: []const u8,
    replacement: std.json.Value,
) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = object_value.iterator();
    while (iterator.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    sortKeys(keys.items);
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try out.writer.writeByte(',');
        try canonical_json.writeCanonicalString(&out.writer, key);
        try out.writer.writeByte(':');
        try canonical_json.writeCanonicalJson(
            allocator,
            &out.writer,
            if (std.mem.eql(u8, key, replaced_key)) replacement else object_value.get(key).?,
        );
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

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |value_object| value_object,
        else => error.ExpectedObject,
    };
}

fn requiredString(parent: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = parent.get(key) orelse return error.MissingField;
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

test "signed receipts bind the canonical subject and producer" {
    const receipt =
        \\{"schema":"test-receipt/v1","producer":{"id":"runner","version":"v1","binary_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","key_id":"runner-key"},"value":"ok","attestation":null}
    ;
    const signed = try signReceiptAlloc(std.testing.allocator, receipt, .{
        .id = "runner",
        .version = "v1",
        .binary_fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .key_id = "runner-key",
    }, "runner", 1, [_]u8{0x42} ** 32);
    defer std.testing.allocator.free(signed);
    try std.testing.expect(std.mem.indexOf(u8, signed, "hylo-attestation/v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, signed, "\"value_base64\":\"\"") == null);
}
