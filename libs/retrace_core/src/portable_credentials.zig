const std = @import("std");

pub const Kind = enum {
    uri_userinfo,
    authorization,
    jwt,
    vendor_token,
    aws_access_key,
    private_key,
    assignment,
};

pub const Match = struct {
    value_start: usize,
    value_end: usize,
    kind: Kind,
};

pub fn next(text: []const u8, start: usize) ?Match {
    if (start >= text.len) return null;

    var index = start;
    while (index < text.len) : (index += 1) {
        if (uriUserinfoAt(text, index)) |match| return match;
        if (credentialAssignmentAt(text, index)) |match| return match;
        if (authorizationAt(text, index)) |match| return match;
        if (privateKeyAt(text, index)) |match| return match;
        if (awsAccessKeyAt(text, index)) |match| return match;
        if (jwtAt(text, index)) |match| return match;
        if (vendorTokenAt(text, index)) |match| return match;
    }
    return null;
}

pub fn contains(text: []const u8) bool {
    return next(text, 0) != null;
}

pub fn isSensitiveJsonKey(key: []const u8) bool {
    inline for (.{
        "authorization",
        "password",
        "passwd",
        "secret",
        "secret_key",
        "token",
        "api_key",
        "apikey",
        "private_key",
        "access_key",
        "access_key_id",
        "access_token",
        "refresh_token",
        "auth_token",
        "client_secret",
        "credential",
        "credentials",
        "provider_credentials",
        "aws_access_key_id",
        "aws_secret_access_key",
        "signing_key",
        "signing_seed",
        "sealing_key",
        "sealing_seed",
        "seal_key",
        "seal_seed",
        "custody_key",
        "custody_seed",
        "capability",
        "capability_key",
        "capability_seed",
        "capability_token",
        "capability_ref",
    }) |exact| {
        if (normalizedEquals(key, exact)) return true;
    }

    inline for (.{
        "_password",
        "_passwd",
        "_secret",
        "_secret_key",
        "_token",
        "_authorization",
        "_credential",
        "_credentials",
        "_api_key",
        "_apikey",
        "_private_key",
        "_access_key",
        "_access_key_id",
        "_access_token",
        "_refresh_token",
        "_auth_token",
        "_client_secret",
        "_signing_key",
        "_signing_seed",
        "_sealing_key",
        "_sealing_seed",
        "_seal_key",
        "_seal_seed",
        "_custody_key",
        "_custody_seed",
        "_capability",
        "_capability_key",
        "_capability_seed",
        "_capability_token",
        "_capability_ref",
    }) |suffix| {
        if (normalizedEndsWith(key, suffix)) return true;
    }
    return false;
}

pub fn validateJson(value: std.json.Value) !void {
    switch (value) {
        .string => |text| try validatePortableText(text),
        .array => |items| for (items.items) |item| try validateJson(item),
        .object => |map| {
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                if (isSensitiveJsonKey(entry.key_ptr.*)) return error.PortableCredentialDetected;
                try validateJson(entry.value_ptr.*);
            }
        },
        else => {},
    }
}

/// Validate text fragments that one semantic message renders adjacently. This
/// closes boundary-splitting evasions without joining unrelated messages or
/// inspecting sealed ciphertext carriers.
pub fn validateAdjacentTextSlices(allocator: std.mem.Allocator, slices: []const []const u8) !void {
    var joined = std.Io.Writer.Allocating.init(allocator);
    defer joined.deinit();
    for (slices) |slice| try joined.writer.writeAll(slice);
    const text = try joined.toOwnedSlice();
    defer allocator.free(text);
    try validatePortableText(text);
}

fn validatePortableText(text: []const u8) !void {
    var cursor: usize = 0;
    while (next(text, cursor)) |match| {
        const matched_value = text[match.value_start..match.value_end];
        if (!isGeneratedCredentialPlaceholder(matched_value)) return error.PortableCredentialDetected;
        if (match.value_end <= cursor) return error.PortableCredentialDetected;
        cursor = match.value_end;
    }
}

fn isGeneratedCredentialPlaceholder(value: []const u8) bool {
    const prefix = "<CREDENTIAL_";
    if (!std.mem.startsWith(u8, value, prefix) or value.len <= prefix.len + 1 or value[value.len - 1] != '>') return false;
    const ordinal = value[prefix.len .. value.len - 1];
    if (ordinal[0] < '1' or ordinal[0] > '9') return false;
    for (ordinal[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn uriUserinfoAt(text: []const u8, index: usize) ?Match {
    if (index >= text.len or !std.ascii.isAlphabetic(text[index])) return null;
    if (index != 0 and isUriSchemeByte(text[index - 1])) return null;

    var cursor = index + 1;
    while (cursor < text.len and isUriSchemeByte(text[cursor])) : (cursor += 1) {}
    if (cursor + 3 > text.len or !std.mem.eql(u8, text[cursor .. cursor + 3], "://")) return null;

    const authority_start = cursor + 3;
    var authority_end = authority_start;
    while (authority_end < text.len and !isUriAuthorityTerminator(text[authority_end])) : (authority_end += 1) {}
    if (authority_start == authority_end) return null;

    const authority = text[authority_start..authority_end];
    const at_offset = std.mem.indexOfScalar(u8, authority, '@') orelse return null;
    if (at_offset == 0 or at_offset + 1 >= authority.len) return null;
    if (std.mem.indexOfScalar(u8, authority[at_offset + 1 ..], '@') != null) return null;

    const userinfo_end = authority_start + at_offset;
    const userinfo = text[authority_start..userinfo_end];
    if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon_offset| {
        const password_start = authority_start + colon_offset + 1;
        if (colon_offset == 0 or password_start >= userinfo_end) return null;
        return .{
            .value_start = password_start,
            .value_end = userinfo_end,
            .kind = .uri_userinfo,
        };
    }
    return .{
        .value_start = authority_start,
        .value_end = userinfo_end,
        .kind = .uri_userinfo,
    };
}

fn credentialAssignmentAt(text: []const u8, index: usize) ?Match {
    if (index != 0 and isCredentialKeyByte(text[index - 1])) return null;
    if (index >= 2 and text[index - 2] == '/' and text[index - 1] == '/') return null;

    var cursor = index;
    var key_quote: ?u8 = null;
    if (cursor < text.len and (text[cursor] == '"' or text[cursor] == '\'')) {
        key_quote = text[cursor];
        cursor += 1;
    }
    const flag = key_quote == null and cursor + 2 <= text.len and std.mem.eql(u8, text[cursor .. cursor + 2], "--");
    if (flag) cursor += 2;

    const key_start = cursor;
    while (cursor < text.len and isCredentialKeyByte(text[cursor])) : (cursor += 1) {}
    if (cursor == key_start or cursor - key_start > 128) return null;
    const key = text[key_start..cursor];
    if (!isSensitiveJsonKey(key)) return null;

    if (key_quote) |closing_quote| {
        if (cursor >= text.len or text[cursor] != closing_quote) return null;
        cursor += 1;
    }

    if (flag) {
        if (cursor >= text.len) return null;
        if (text[cursor] == '=') {
            cursor += 1;
        } else if (!std.ascii.isWhitespace(text[cursor])) {
            return null;
        }
    } else {
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or (text[cursor] != ':' and text[cursor] != '=')) return null;
        if (text[cursor] == ':' and cursor + 1 < text.len and text[cursor + 1] == '/') return null;
        cursor += 1;
    }
    while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}

    var value_quote: ?u8 = null;
    if (cursor < text.len and (text[cursor] == '"' or text[cursor] == '\'')) {
        value_quote = text[cursor];
        cursor += 1;
    }

    if (normalizedEquals(key, "authorization")) skipAuthorizationScheme(text, &cursor);
    const value_start = cursor;
    if (value_quote) |closing_quote| {
        while (cursor < text.len and text[cursor] != closing_quote) {
            cursor += if (text[cursor] == '\\' and cursor + 1 < text.len) 2 else 1;
        }
    } else {
        while (cursor < text.len and !isSecretDelimiter(text[cursor])) : (cursor += 1) {}
    }
    if (cursor == value_start) return null;
    return .{ .value_start = value_start, .value_end = cursor, .kind = .assignment };
}

fn authorizationAt(text: []const u8, index: usize) ?Match {
    if (index != 0 and std.ascii.isAlphanumeric(text[index - 1])) return null;
    const schemes = [_][]const u8{ "bearer", "basic" };
    for (schemes) |scheme| {
        if (index + scheme.len >= text.len or !std.ascii.eqlIgnoreCase(text[index .. index + scheme.len], scheme)) continue;
        var cursor = index + scheme.len;
        if (!std.ascii.isWhitespace(text[cursor])) continue;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        const value_start = cursor;
        while (cursor < text.len and isAuthorizationValueByte(text[cursor])) : (cursor += 1) {}
        const value = text[value_start..cursor];
        if (!looksLikeAuthorizationSecret(value, scheme)) continue;
        return .{ .value_start = value_start, .value_end = cursor, .kind = .authorization };
    }
    return null;
}

fn privateKeyAt(text: []const u8, index: usize) ?Match {
    const Envelope = struct { begin: []const u8, end: []const u8 };
    const envelopes = [_]Envelope{
        .{ .begin = "-----BEGIN PRIVATE KEY-----", .end = "-----END PRIVATE KEY-----" },
        .{ .begin = "-----BEGIN ENCRYPTED PRIVATE KEY-----", .end = "-----END ENCRYPTED PRIVATE KEY-----" },
        .{ .begin = "-----BEGIN OPENSSH PRIVATE KEY-----", .end = "-----END OPENSSH PRIVATE KEY-----" },
        .{ .begin = "-----BEGIN RSA PRIVATE KEY-----", .end = "-----END RSA PRIVATE KEY-----" },
        .{ .begin = "-----BEGIN EC PRIVATE KEY-----", .end = "-----END EC PRIVATE KEY-----" },
        .{ .begin = "-----BEGIN DSA PRIVATE KEY-----", .end = "-----END DSA PRIVATE KEY-----" },
        .{ .begin = "-----BEGIN PGP PRIVATE KEY BLOCK-----", .end = "-----END PGP PRIVATE KEY BLOCK-----" },
    };
    for (envelopes) |envelope| {
        const begin = envelope.begin;
        const end = envelope.end;
        if (!std.mem.startsWith(u8, text[index..], begin)) continue;
        const end_start = std.mem.indexOfPos(u8, text, index + begin.len, end) orelse text.len;
        return .{
            .value_start = index,
            .value_end = if (end_start == text.len) text.len else end_start + end.len,
            .kind = .private_key,
        };
    }
    return null;
}

fn awsAccessKeyAt(text: []const u8, index: usize) ?Match {
    const key_len = 20;
    if (index != 0 and isCredentialTokenByte(text[index - 1])) return null;
    if (index + key_len > text.len) return null;
    if (!std.mem.startsWith(u8, text[index..], "AKIA") and !std.mem.startsWith(u8, text[index..], "ASIA")) return null;
    for (text[index + 4 .. index + key_len]) |byte| {
        if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte)) return null;
    }
    if (index + key_len < text.len and isCredentialTokenByte(text[index + key_len])) return null;
    return .{ .value_start = index, .value_end = index + key_len, .kind = .aws_access_key };
}

fn jwtAt(text: []const u8, index: usize) ?Match {
    if (index != 0 and isBase64UrlByte(text[index - 1])) return null;
    if (!std.mem.startsWith(u8, text[index..], "eyJ")) return null;

    var cursor = index;
    var dots: usize = 0;
    var segment_len: usize = 0;
    while (cursor < text.len) : (cursor += 1) {
        const byte = text[cursor];
        if (isBase64UrlByte(byte)) {
            segment_len += 1;
            continue;
        }
        if (byte == '.' and dots < 2 and segment_len > 0) {
            dots += 1;
            segment_len = 0;
            continue;
        }
        break;
    }
    if (dots != 2 or segment_len == 0 or cursor - index < 24) return null;
    if (cursor < text.len and (isBase64UrlByte(text[cursor]) or text[cursor] == '.')) return null;
    return .{ .value_start = index, .value_end = cursor, .kind = .jwt };
}

fn vendorTokenAt(text: []const u8, index: usize) ?Match {
    if (index != 0 and isCredentialTokenByte(text[index - 1])) return null;
    const Candidate = struct { prefix: []const u8, minimum_suffix: usize };
    const candidates = [_]Candidate{
        .{ .prefix = "sk-proj-", .minimum_suffix = 8 },
        .{ .prefix = "sk-", .minimum_suffix = 8 },
        .{ .prefix = "rk_live_", .minimum_suffix = 6 },
        .{ .prefix = "sk_live_", .minimum_suffix = 6 },
        .{ .prefix = "ghp_", .minimum_suffix = 6 },
        .{ .prefix = "gho_", .minimum_suffix = 6 },
        .{ .prefix = "ghu_", .minimum_suffix = 6 },
        .{ .prefix = "ghs_", .minimum_suffix = 6 },
        .{ .prefix = "ghr_", .minimum_suffix = 6 },
        .{ .prefix = "github_pat_", .minimum_suffix = 6 },
        .{ .prefix = "glpat-", .minimum_suffix = 6 },
        .{ .prefix = "npm_", .minimum_suffix = 6 },
        .{ .prefix = "pypi-", .minimum_suffix = 8 },
        .{ .prefix = "xoxb-", .minimum_suffix = 6 },
        .{ .prefix = "xoxp-", .minimum_suffix = 6 },
        .{ .prefix = "xoxa-", .minimum_suffix = 6 },
        .{ .prefix = "xoxr-", .minimum_suffix = 6 },
        .{ .prefix = "hf_", .minimum_suffix = 8 },
        .{ .prefix = "AIza", .minimum_suffix = 20 },
        .{ .prefix = "HYL1-", .minimum_suffix = 6 },
    };
    for (candidates) |candidate| {
        const prefix = candidate.prefix;
        const minimum_suffix = candidate.minimum_suffix;
        if (index + prefix.len > text.len or !std.mem.startsWith(u8, text[index..], prefix)) continue;
        var cursor = index + prefix.len;
        while (cursor < text.len and isCredentialTokenByte(text[cursor])) : (cursor += 1) {}
        if (cursor - (index + prefix.len) < minimum_suffix) continue;
        return .{ .value_start = index, .value_end = cursor, .kind = .vendor_token };
    }
    return null;
}

fn skipAuthorizationScheme(text: []const u8, cursor: *usize) void {
    const schemes = [_][]const u8{ "bearer", "basic" };
    for (schemes) |scheme| {
        if (cursor.* + scheme.len >= text.len or !std.ascii.eqlIgnoreCase(text[cursor.* .. cursor.* + scheme.len], scheme)) continue;
        if (!std.ascii.isWhitespace(text[cursor.* + scheme.len])) continue;
        cursor.* += scheme.len;
        while (cursor.* < text.len and std.ascii.isWhitespace(text[cursor.*])) cursor.* += 1;
        return;
    }
}

fn looksLikeAuthorizationSecret(value: []const u8, scheme: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(scheme, "basic")) {
        if (value.len < 8) return false;
        var has_base64_signal = false;
        for (value) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '/' and byte != '=') return false;
            if (std.ascii.isUpper(byte) or std.ascii.isDigit(byte) or byte == '+' or byte == '/' or byte == '=') has_base64_signal = true;
        }
        return has_base64_signal;
    }
    if (value.len < 12) return false;
    var has_non_letter = false;
    for (value) |byte| {
        if (!std.ascii.isAlphabetic(byte)) has_non_letter = true;
    }
    return has_non_letter or value.len >= 24;
}

fn normalizedEquals(raw: []const u8, expected: []const u8) bool {
    var raw_cursor: usize = 0;
    var expected_cursor: usize = 0;
    while (true) {
        const raw_segment = nextKeySegment(raw, &raw_cursor);
        const expected_segment = nextKeySegment(expected, &expected_cursor);
        if (raw_segment == null or expected_segment == null) return raw_segment == null and expected_segment == null;
        if (!std.ascii.eqlIgnoreCase(raw_segment.?, expected_segment.?)) return false;
    }
}

fn normalizedEndsWith(raw: []const u8, suffix: []const u8) bool {
    const raw_count = keySegmentCount(raw);
    const suffix_count = keySegmentCount(suffix);
    if (suffix_count == 0 or raw_count <= suffix_count) return false;

    var raw_cursor: usize = 0;
    var skipped: usize = 0;
    while (skipped < raw_count - suffix_count) : (skipped += 1) _ = nextKeySegment(raw, &raw_cursor) orelse return false;
    var suffix_cursor: usize = 0;
    while (true) {
        const raw_segment = nextKeySegment(raw, &raw_cursor);
        const suffix_segment = nextKeySegment(suffix, &suffix_cursor);
        if (raw_segment == null or suffix_segment == null) return raw_segment == null and suffix_segment == null;
        if (!std.ascii.eqlIgnoreCase(raw_segment.?, suffix_segment.?)) return false;
    }
}

fn keySegmentCount(raw: []const u8) usize {
    var cursor: usize = 0;
    var count: usize = 0;
    while (nextKeySegment(raw, &cursor) != null) count += 1;
    return count;
}

fn nextKeySegment(raw: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < raw.len and !std.ascii.isAlphanumeric(raw[cursor.*])) cursor.* += 1;
    if (cursor.* == raw.len) return null;

    const start = cursor.*;
    var end = start + 1;
    while (end < raw.len and std.ascii.isAlphanumeric(raw[end])) : (end += 1) {
        if (!std.ascii.isUpper(raw[end])) continue;
        const previous = raw[end - 1];
        const next_is_lower = end + 1 < raw.len and std.ascii.isLower(raw[end + 1]);
        if (std.ascii.isLower(previous) or std.ascii.isDigit(previous) or (std.ascii.isUpper(previous) and next_is_lower)) break;
    }
    cursor.* = end;
    return raw[start..end];
}

fn isCredentialKeyByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn isCredentialTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

fn isBase64UrlByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn isAuthorizationValueByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == '~' or byte == '+' or byte == '/' or byte == '=';
}

fn isSecretDelimiter(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '"' or byte == '\'' or byte == ',' or byte == ';' or byte == '}' or byte == ']' or byte == '\\';
}

fn isUriSchemeByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.';
}

fn isUriAuthorityTerminator(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '/' or byte == '?' or byte == '#' or byte == '"' or byte == '\'' or byte == '<' or byte == '>' or byte == '\\';
}

test "portable credential matching covers every admitted credential shape" {
    const cases = [_]struct {
        text: []const u8,
        value: []const u8,
        kind: Kind,
    }{
        .{ .text = "https://alice:correct-horse@example.com/repo", .value = "correct-horse", .kind = .uri_userinfo },
        .{ .text = "https://ghp_1234567890@localhost/repo", .value = "ghp_1234567890", .kind = .uri_userinfo },
        .{ .text = "https://reader@example.com/repo", .value = "reader", .kind = .uri_userinfo },
        .{ .text = "Bearer opaque-token-1234", .value = "opaque-token-1234", .kind = .authorization },
        .{ .text = "Basic dXNlcjpwYXNzd29yZA==", .value = "dXNlcjpwYXNzd29yZA==", .kind = .authorization },
        .{ .text = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.signature", .value = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.signature", .kind = .jwt },
        .{ .text = "use github_pat_1234567890abcdef now", .value = "github_pat_1234567890abcdef", .kind = .vendor_token },
        .{ .text = "AWS=AKIA1234567890ABCDEF", .value = "AKIA1234567890ABCDEF", .kind = .aws_access_key },
        .{ .text = "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----", .value = "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----", .kind = .private_key },
        .{ .text = "api_key = 'short-secret'", .value = "short-secret", .kind = .assignment },
        .{ .text = "Authorization: Bearer assigned-token-123", .value = "assigned-token-123", .kind = .assignment },
        .{ .text = "--custody-key HYL1-abcdef123456", .value = "HYL1-abcdef123456", .kind = .assignment },
    };

    for (cases) |case| {
        const match = next(case.text, 0) orelse return error.ExpectedCredentialMatch;
        try std.testing.expectEqual(case.kind, match.kind);
        try std.testing.expectEqualStrings(case.value, case.text[match.value_start..match.value_end]);
        try std.testing.expect(contains(case.text));
    }
}

test "next begins at the requested offset" {
    const text = "ghp_1234567890 then sk-abcdefgh1234";
    const first = next(text, 0) orelse return error.ExpectedCredentialMatch;
    try std.testing.expectEqualStrings("ghp_1234567890", text[first.value_start..first.value_end]);
    const second = next(text, first.value_end) orelse return error.ExpectedCredentialMatch;
    try std.testing.expectEqualStrings("sk-abcdefgh1234", text[second.value_start..second.value_end]);
    try std.testing.expect(next(text, second.value_end) == null);
}

test "portable credential matching preserves benign public text" {
    const benign = [_][]const u8{
        "https://example.com/repo",
        "https://token:443/path",
        "token://example.com/path",
        "bearer token authentication",
        "Bearer authentication",
        "a sketch-abcdefgh is not a key",
        "token budget is 1000",
        "execution_order_seed is public replay metadata",
        "sha256:abcdef0123456789",
        "public_key and key_id are references",
        "ghp_short",
        "AKIA123",
        "sketching and basic authentication",
    };
    for (benign) |text| try std.testing.expect(!contains(text));
}

test "sensitive JSON keys are explicit and do not reject generic seeds" {
    inline for (.{
        "password",
        "provider-credentials",
        "github_token",
        "worker_signing_seed",
        "sealed_custody_key",
        "case_materialization_capability",
        "ciphertext_or_capability_ref",
        "clientSecret",
        "ClientSecret",
        "accessToken",
        "AccessToken",
        "apiKey",
        "APIKey",
        "workerClientSecret",
        "myAPIKey",
    }) |key| try std.testing.expect(isSensitiveJsonKey(key));

    inline for (.{
        "execution_order_seed",
        "seed",
        "random_seed",
        "public_key",
        "key_id",
        "token_budget",
        "max_tokens",
        "tokenBudget",
        "maxTokens",
        "publicKey",
        "target_bundle_fingerprint",
    }) |key| try std.testing.expect(!isSensitiveJsonKey(key));
}

test "adjacent semantic text cannot split a credential assignment" {
    try std.testing.expectError(
        error.PortableCredentialDetected,
        validateAdjacentTextSlices(std.testing.allocator, &.{ "client", "Secret=synthetic-value" }),
    );
    try std.testing.expectError(
        error.PortableCredentialDetected,
        validateAdjacentTextSlices(std.testing.allocator, &.{ "api", "Key: synthetic-value" }),
    );
    try validateAdjacentTextSlices(std.testing.allocator, &.{ "token", "Budget is 1000 and maxTokens is 2000" });
}

test "portable validation preserves exact generated placeholders inside credential carriers" {
    inline for (.{
        "api_key=<CREDENTIAL_1>",
        "Authorization: Bearer <CREDENTIAL_2>",
        "Bearer <CREDENTIAL_3>",
        "https://alice:<CREDENTIAL_4>@example.com/repo",
        "https://<CREDENTIAL_5>@example.com/repo",
        "clientSecret=<CREDENTIAL_10>",
    }) |text| try validateJson(.{ .string = text });

    try validateAdjacentTextSlices(std.testing.allocator, &.{ "clientSecret=", "<CREDENTIAL_6>" });
}

test "portable validation continues after placeholders and rejects later credentials" {
    inline for (.{
        "api_key=<CREDENTIAL_1> then ghp_1234567890",
        "Authorization: Bearer <CREDENTIAL_2>; clientSecret=real-secret",
        "https://alice:<CREDENTIAL_3>@example.com/repo sk-abcdefgh1234",
        "api_key=<CREDENTIAL_>",
        "api_key=<CREDENTIAL_0>",
        "api_key=<CREDENTIAL_01>",
        "api_key=<CREDENTIAL_00>",
        "api_key=<CREDENTIAL_4>suffix",
    }) |text| try std.testing.expectError(error.PortableCredentialDetected, validateJson(.{ .string = text }));

    try std.testing.expectError(
        error.PortableCredentialDetected,
        validateAdjacentTextSlices(std.testing.allocator, &.{ "api_key=<CREDENTIAL_5>", " then ghp_1234567890" }),
    );

    var sensitive_key = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"clientSecret\":\"<CREDENTIAL_6>\"}", .{});
    defer sensitive_key.deinit();
    try std.testing.expectError(error.PortableCredentialDetected, validateJson(sensitive_key.value));
}

test "JSON validation rejects credential keys and nested credential values" {
    var safe = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"execution_order_seed\":\"sha256:abc\",\"nested\":[\"https://example.com\",{\"public_key\":\"ref:key-1\"}]}",
        .{},
    );
    defer safe.deinit();
    try validateJson(safe.value);

    var sensitive_key = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"signing_seed\":\"redacted\"}", .{});
    defer sensitive_key.deinit();
    try std.testing.expectError(error.PortableCredentialDetected, validateJson(sensitive_key.value));

    var sensitive_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"note\":{\"text\":\"https://ghp_1234567890@localhost/repo\"}}", .{});
    defer sensitive_value.deinit();
    try std.testing.expectError(error.PortableCredentialDetected, validateJson(sensitive_value.value));
}
