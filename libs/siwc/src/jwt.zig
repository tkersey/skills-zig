const std = @import("std");
const encoding = @import("encoding.zig");
const oauth = @import("oauth.zig");

pub const token_bytes_max = 32768;
pub const jwks_bytes_max = 262144;
pub const jwks_keys_max = 32;
pub const clock_skew_seconds = 60;

pub const VerifyOptions = struct {
    client_id: []const u8,
    nonce: ?[]const u8,
    now_sec: i64,
};

pub const Identity = struct {
    parsed: std.json.Parsed(std.json.Value),
    issuer: []const u8,
    subject: []const u8,
    email: ?[]const u8,

    pub fn deinit(self: *Identity) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

const Segments = struct {
    header: []const u8,
    payload: []const u8,
    signature: []const u8,
    signed: []const u8,
};

pub fn verify(
    allocator: std.mem.Allocator,
    token: []const u8,
    jwks_json: []const u8,
    options: VerifyOptions,
) !Identity {
    if (options.now_sec < 0) return error.InvalidClock;
    try oauth.validateIssuedClient(options.client_id);
    const segments = try split(token);
    const header_bytes = try encoding.decodeBase64(allocator, segments.header, 2048);
    defer allocator.free(header_bytes);
    const header = try parseObject(allocator, header_bytes);
    defer header.deinit();
    const kid = try validateHeader(header.value.object);
    const signature = try encoding.decodeBase64(allocator, segments.signature, 512);
    defer allocator.free(signature);
    try verifySignature(allocator, jwks_json, kid, segments.signed, signature);
    const payload = try encoding.decodeBase64(allocator, segments.payload, token_bytes_max);
    defer allocator.free(payload);
    const parsed = try parseObject(allocator, payload);
    errdefer parsed.deinit();
    try validateClaims(parsed.value.object, options);
    return .{
        .parsed = parsed,
        .issuer = oauth.issuer,
        .subject = try string(parsed.value.object, "sub", 256),
        .email = if (parsed.value.object.contains("email"))
            try string(parsed.value.object, "email", 320)
        else
            null,
    };
}

fn split(token: []const u8) !Segments {
    if (token.len == 0 or token.len > token_bytes_max) return error.InvalidToken;
    var parts = std.mem.splitScalar(u8, token, '.');
    const header = parts.next() orelse return error.InvalidToken;
    const payload = parts.next() orelse return error.InvalidToken;
    const signature = parts.next() orelse return error.InvalidToken;
    if (header.len == 0 or payload.len == 0 or signature.len == 0 or parts.next() != null)
        return error.InvalidToken;
    return .{
        .header = header,
        .payload = payload,
        .signature = signature,
        .signed = token[0 .. header.len + 1 + payload.len],
    };
}

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = token_bytes_max,
    });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonObject;
    return parsed;
}

fn validateHeader(header: std.json.ObjectMap) ![]const u8 {
    const algorithm = try string(header, "alg", 16);
    if (!std.mem.eql(u8, algorithm, "RS256")) return error.UnsupportedAlgorithm;
    if (header.contains("crit") or header.contains("b64")) return error.UnsupportedCriticalHeader;
    return string(header, "kid", 256);
}

fn verifySignature(
    allocator: std.mem.Allocator,
    jwks_json: []const u8,
    kid: []const u8,
    signed: []const u8,
    signature: []const u8,
) !void {
    if (jwks_json.len > jwks_bytes_max) return error.JwksTooLarge;
    const parsed = try parseObject(allocator, jwks_json);
    defer parsed.deinit();
    const keys = parsed.value.object.get("keys") orelse return error.MissingSigningKeys;
    if (keys != .array or keys.array.items.len == 0 or keys.array.items.len > jwks_keys_max)
        return error.InvalidSigningKeys;
    var selected: ?std.json.ObjectMap = null;
    for (keys.array.items) |key| {
        if (key != .object) return error.InvalidSigningKey;
        const key_id = key.object.get("kid") orelse continue;
        if (key_id != .string) return error.InvalidSigningKey;
        if (!std.mem.eql(u8, key_id.string, kid)) continue;
        if (selected != null) return error.AmbiguousSigningKey;
        selected = key.object;
    }
    const key = selected orelse return error.UnknownSigningKey;
    try validateKey(key);
    const modulus = try encoding.decodeBase64(allocator, try string(key, "n", 1024), 512);
    defer allocator.free(modulus);
    const exponent = try encoding.decodeBase64(allocator, try string(key, "e", 16), 4);
    defer allocator.free(exponent);
    try verifyRsa(modulus, exponent, signed, signature);
}

fn validateKey(key: std.json.ObjectMap) !void {
    if (!std.mem.eql(u8, try string(key, "kty", 16), "RSA")) return error.InvalidSigningKey;
    if (key.contains("alg") and !std.mem.eql(u8, try string(key, "alg", 16), "RS256"))
        return error.InvalidSigningKey;
    if (key.contains("use") and !std.mem.eql(u8, try string(key, "use", 16), "sig"))
        return error.InvalidSigningKey;
    if (key.get("key_ops")) |operations| {
        if (operations != .array or operations.array.items.len > 8)
            return error.InvalidSigningKey;
        var can_verify = false;
        for (operations.array.items) |operation| {
            if (operation != .string) return error.InvalidSigningKey;
            if (std.mem.eql(u8, operation.string, "verify")) can_verify = true;
        }
        if (!can_verify) return error.InvalidSigningKey;
    }
}

fn verifyRsa(modulus: []const u8, exponent: []const u8, signed: []const u8, sig: []const u8) !void {
    if (modulus.len != 256 and modulus.len != 384 and modulus.len != 512)
        return error.UnsupportedKeySize;
    if (exponent.len == 0 or exponent.len > 4) return error.InvalidSigningKey;
    if (sig.len != modulus.len or modulus[0] & 0x80 == 0 or exponent[0] == 0)
        return error.InvalidSignature;
    const rsa = std.crypto.Certificate.rsa;
    const key = rsa.PublicKey.fromBytes(exponent, modulus) catch return error.InvalidSigningKey;
    switch (modulus.len) {
        inline 256, 384, 512 => |length| {
            rsa.PKCS1v1_5Signature.verify(
                length,
                sig[0..length],
                signed,
                key,
                std.crypto.hash.sha2.Sha256,
            ) catch return error.InvalidSignature;
        },
        else => return error.UnsupportedKeySize,
    }
}

fn validateClaims(claims: std.json.ObjectMap, options: VerifyOptions) !void {
    if (!std.mem.eql(u8, try string(claims, "iss", 256), oauth.issuer))
        return error.IssuerMismatch;
    try validateAudience(claims, options.client_id);
    _ = try string(claims, "sub", 256);
    const expires = try integer(claims, "exp");
    if (expires <= options.now_sec) return error.TokenExpired;
    const issued = try integer(claims, "iat");
    const latest = std.math.add(i64, options.now_sec, clock_skew_seconds) catch
        return error.InvalidClock;
    if (issued < 0 or issued > latest or issued >= expires) return error.InvalidIssuedTime;
    if (claims.contains("nbf")) {
        if (try integer(claims, "nbf") > latest) return error.TokenNotYetValid;
    }
    if (options.nonce) |expected| {
        const nonce = try string(claims, "nonce", 256);
        if (!encoding.secretEqual(nonce, expected)) return error.NonceMismatch;
    } else if (claims.contains("nonce")) {
        _ = try string(claims, "nonce", 256);
    }
}

fn validateAudience(claims: std.json.ObjectMap, client_id: []const u8) !void {
    const audience = claims.get("aud") orelse return error.MissingClaim;
    var require_authorized_party = false;
    switch (audience) {
        .string => |value| {
            if (!std.mem.eql(u8, value, client_id)) return error.AudienceMismatch;
        },
        .array => |values| {
            if (values.items.len == 0 or values.items.len > 16) return error.InvalidAudience;
            var matches: usize = 0;
            for (values.items) |value| {
                if (value != .string) return error.InvalidAudience;
                if (std.mem.eql(u8, value.string, client_id)) matches += 1;
            }
            if (matches != 1) return error.AudienceMismatch;
            require_authorized_party = values.items.len > 1;
        },
        else => return error.InvalidAudience,
    }
    if (require_authorized_party or claims.contains("azp")) {
        if (!std.mem.eql(u8, try string(claims, "azp", 256), client_id))
            return error.AuthorizedPartyMismatch;
    }
}

fn string(object: std.json.ObjectMap, name: []const u8, limit: usize) ![]const u8 {
    const value = object.get(name) orelse return error.MissingClaim;
    if (value != .string) return error.InvalidClaim;
    try oauth.validateText(value.string, limit);
    return value.string;
}

fn integer(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return error.MissingClaim;
    if (value != .integer) return error.InvalidClaim;
    return value.integer;
}

test "signed independent vector verifies identity and exact registration" {
    const vectors = @import("jwt_vectors.zig");
    const allocator = std.testing.allocator;
    const options: VerifyOptions = .{
        .client_id = "oaiapp_test",
        .nonce = "nonce",
        .now_sec = 1700000100,
    };
    var identity = try verify(allocator, vectors.valid, vectors.jwks, options);
    defer identity.deinit();
    try std.testing.expectEqualStrings(oauth.issuer, identity.issuer);
    try std.testing.expectEqualStrings("subject", identity.subject);
    try std.testing.expectEqualStrings("test@example.invalid", identity.email.?);
    var wrong = options;
    wrong.client_id = "oaiapp_other";
    try std.testing.expectError(error.AudienceMismatch, verify(
        allocator,
        vectors.valid,
        vectors.jwks,
        wrong,
    ));
    wrong = options;
    wrong.nonce = "wrong";
    try std.testing.expectError(error.NonceMismatch, verify(
        allocator,
        vectors.valid,
        vectors.jwks,
        wrong,
    ));
    wrong = options;
    wrong.now_sec = 1700003600;
    try std.testing.expectError(error.TokenExpired, verify(
        allocator,
        vectors.valid,
        vectors.jwks,
        wrong,
    ));
}

test "signed malformed claims and multiple audiences do not bypass identity checks" {
    const vectors = @import("jwt_vectors.zig");
    const allocator = std.testing.allocator;
    const options: VerifyOptions = .{
        .client_id = "oaiapp_test",
        .nonce = "nonce",
        .now_sec = 1700000100,
    };
    var identity = try verify(allocator, vectors.multi_audience, vectors.jwks, options);
    defer identity.deinit();
    const cases = .{
        .{ vectors.missing_azp, error.MissingClaim },
        .{ vectors.wrong_issuer, error.IssuerMismatch },
        .{ vectors.duplicate_subject, error.DuplicateField },
        .{ vectors.wrong_expiry_type, error.InvalidClaim },
        .{ vectors.future_not_before, error.TokenNotYetValid },
        .{ vectors.critical_header, error.UnsupportedCriticalHeader },
        .{ vectors.unsigned_algorithm, error.UnsupportedAlgorithm },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[1], verify(allocator, case[0], vectors.jwks, options));
    }
}

test "signature mutation malformed JWK and duplicate key identifiers are rejected" {
    const vectors = @import("jwt_vectors.zig");
    const allocator = std.testing.allocator;
    const options: VerifyOptions = .{
        .client_id = "oaiapp_test",
        .nonce = "nonce",
        .now_sec = 1700000100,
    };
    const changed = try allocator.dupe(u8, vectors.valid);
    defer allocator.free(changed);
    const index = std.mem.lastIndexOfScalar(u8, changed, '.').? + 1;
    changed[index] = if (changed[index] == 'A') 'B' else 'A';
    try std.testing.expectError(error.InvalidSignature, verify(
        allocator,
        changed,
        vectors.jwks,
        options,
    ));
    try std.testing.expectError(error.AmbiguousSigningKey, verify(
        allocator,
        vectors.valid,
        vectors.duplicate_jwks,
        options,
    ));
    try std.testing.expectError(error.UnknownSigningKey, verify(
        allocator,
        vectors.valid,
        "{\"keys\":[{\"kid\":\"other\"}]}",
        options,
    ));
    try std.testing.expectError(error.InvalidSigningKey, verify(
        allocator,
        vectors.valid,
        "{\"keys\":[{\"kid\":\"vector\",\"kty\":\"oct\"}]}",
        options,
    ));
    try std.testing.expectError(error.InvalidToken, verify(allocator, "a.b", "{}", options));
}

fn identityAllocationProbe(allocator: std.mem.Allocator) !void {
    const vectors = @import("jwt_vectors.zig");
    var identity = try verify(allocator, vectors.valid, vectors.jwks, .{
        .client_id = "oaiapp_test",
        .nonce = "nonce",
        .now_sec = 1700000100,
    });
    defer identity.deinit();
    var callback = try oauth.parseCallback(
        allocator,
        "code=c&state=s&client_id=oaiapp_one",
        "s",
        null,
    );
    defer callback.deinit();
    const form = try oauth.refreshForm(allocator, callback.client_id, "opaque & token");
    defer allocator.free(form);
}

test "identity and callback ownership survives each allocation failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        identityAllocationProbe,
        .{},
    );
}

test "RSA lengths reject empty values before inspecting bytes" {
    const modulus: [256]u8 = @splat(0x80);
    try std.testing.expectError(error.UnsupportedKeySize, verifyRsa("", "", "", ""));
    try std.testing.expectError(error.UnsupportedKeySize, verifyRsa("short", "AQAB", "", ""));
    try std.testing.expectError(error.InvalidSigningKey, verifyRsa(&modulus, "", "", ""));
    try std.testing.expectError(error.InvalidSigningKey, verifyRsa(&modulus, "12345", "", ""));
}

test "initial login fixture binds the complete generated nonce" {
    const vectors = @import("jwt_vectors.zig");
    var identity = try verify(std.testing.allocator, vectors.login, vectors.jwks, .{
        .client_id = "oaiapp_test",
        .nonce = vectors.login_nonce,
        .now_sec = 1700000100,
    });
    defer identity.deinit();
    try std.testing.expectEqualStrings("subject", identity.subject);
}
