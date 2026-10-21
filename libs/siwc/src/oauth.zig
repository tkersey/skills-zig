const std = @import("std");
const encoding = @import("encoding.zig");

pub const issuer = "https://auth.openai.com";
pub const authorization_endpoint = issuer ++ "/api/accounts/authorize";
pub const token_endpoint = issuer ++ "/api/accounts/oauth/token";
pub const discovery_endpoint = issuer ++ "/.well-known/openid-configuration";
pub const resource = "https://api.openai.com/v1";
pub const scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
pub const registration_client_id = "dynamic_agent_client";
pub const token_bytes_max = 32768;
pub const reply_bytes_max = 131072;
pub const callback_bytes_max = 16384;
pub const token_lifetime_seconds_max = 86400;

pub const Secrets = struct {
    state: [43]u8,
    nonce: [43]u8,
    verifier: [43]u8,

    pub fn fromRandom(random: [96]u8) Secrets {
        var result: Secrets = undefined;
        const encoder = std.base64.url_safe_no_pad.Encoder;
        _ = encoder.encode(&result.state, random[0..32]);
        _ = encoder.encode(&result.nonce, random[32..64]);
        _ = encoder.encode(&result.verifier, random[64..96]);
        return result;
    }

    pub fn deinit(self: *Secrets) void {
        std.crypto.secureZero(u8, &self.state);
        std.crypto.secureZero(u8, &self.nonce);
        std.crypto.secureZero(u8, &self.verifier);
    }
};

pub const AuthorizeOptions = struct {
    client_id: []const u8,
    app: []const u8,
    host_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    nonce: []const u8,
    verifier: []const u8,
    enable_plan: bool = false,
    id_token_hint: ?[]const u8 = null,
};

pub fn authorizeUrl(allocator: std.mem.Allocator, options: AuthorizeOptions) ![]u8 {
    try validateAuthorize(options);
    var challenge_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(options.verifier, &challenge_bytes, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &challenge_bytes);
    var pairs: [16]encoding.Pair = undefined;
    const required = [_]encoding.Pair{
        .{ .name = "client_id", .value = options.client_id },
        .{ .name = "ext_agent_host_id", .value = options.host_id },
        .{ .name = "response_type", .value = "code" },
        .{ .name = "redirect_uri", .value = options.redirect_uri },
        .{ .name = "scope", .value = scopes },
        .{ .name = "resource", .value = resource },
        .{ .name = "state", .value = options.state },
        .{ .name = "nonce", .value = options.nonce },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "code_challenge", .value = &challenge },
    };
    @memcpy(pairs[0..required.len], &required);
    var count: usize = required.len;
    if (std.mem.eql(u8, options.client_id, registration_client_id)) {
        pairs[count] = .{ .name = "agent_name_hint", .value = options.app };
        count += 1;
    }
    if (options.enable_plan) {
        pairs[count] = .{ .name = "prompt", .value = "consent" };
        count += 1;
    }
    if (options.id_token_hint) |hint| {
        pairs[count] = .{ .name = "id_token_hint", .value = hint };
        count += 1;
    }
    const query = try encoding.encodeForm(allocator, pairs[0..count]);
    defer allocator.free(query);
    return std.fmt.allocPrint(allocator, "{s}?{s}", .{ authorization_endpoint, query });
}

fn validateAuthorize(options: AuthorizeOptions) !void {
    try validateText(options.client_id, 256);
    try validateText(options.app, 128);
    try validateText(options.host_id, 256);
    try validateRedirect(options.redirect_uri);
    try validateRandom(options.state);
    try validateRandom(options.nonce);
    try validateVerifier(options.verifier);
    if (options.id_token_hint) |hint| {
        try validateText(hint, token_bytes_max);
        if (std.mem.eql(u8, options.client_id, registration_client_id))
            return error.UnexpectedIdentityHint;
    }
}

fn validateVerifier(value: []const u8) !void {
    if (value.len < 43 or value.len > 128) return error.InvalidVerifier;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "-._~", byte) == null) return error.InvalidVerifier;
    }
}

fn validateRandom(value: []const u8) !void {
    if (value.len != 43) return error.InvalidRandomValue;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
            return error.InvalidRandomValue;
    }
}

pub fn validateText(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidText;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidText;
    }
}

pub fn validateRedirect(value: []const u8) !void {
    const prefix = "http://127.0.0.1:";
    const suffix = "/auth/callback";
    if (!std.mem.startsWith(u8, value, prefix) or !std.mem.endsWith(u8, value, suffix))
        return error.InvalidRedirect;
    if (value.len <= prefix.len + suffix.len) return error.InvalidRedirect;
    const port_text = value[prefix.len .. value.len - suffix.len];
    if (port_text.len > 5) return error.InvalidRedirect;
    for (port_text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidRedirect;
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidRedirect;
    if (port == 0) return error.InvalidRedirect;
}

pub const Callback = struct {
    allocator: std.mem.Allocator,
    code: []u8,
    client_id: []u8,

    pub fn deinit(self: *Callback) void {
        std.crypto.secureZero(u8, self.code);
        self.allocator.free(self.code);
        self.allocator.free(self.client_id);
        self.* = undefined;
    }
};

pub fn parseCallback(
    allocator: std.mem.Allocator,
    query: []const u8,
    expected_state: []const u8,
    expected_client_id: ?[]const u8,
) !Callback {
    if (query.len > callback_bytes_max) return error.CallbackTooLarge;
    var fields = try encoding.parseForm(allocator, query);
    defer fields.deinit();
    const state = fields.get("state") orelse return error.MissingState;
    if (!encoding.secretEqual(state, expected_state)) return error.StateMismatch;
    if (fields.get("error")) |failure| {
        if (fields.get("code") != null) return error.InvalidCallback;
        if (std.mem.eql(u8, failure, "access_denied")) return error.AccessDenied;
        return error.AuthorizationRejected;
    }
    const code = fields.get("code") orelse return error.MissingCode;
    try validateText(code, 4096);
    const client = try callbackClient(fields.get("client_id"), expected_client_id);
    const owned_code = try allocator.dupe(u8, code);
    errdefer allocator.free(owned_code);
    return .{
        .allocator = allocator,
        .code = owned_code,
        .client_id = try allocator.dupe(u8, client),
    };
}

fn callbackClient(returned: ?[]const u8, expected: ?[]const u8) ![]const u8 {
    if (expected) |client| {
        if (returned) |actual| {
            if (!std.mem.eql(u8, client, actual)) return error.ClientMismatch;
        }
        try validateIssuedClient(client);
        return client;
    }
    const client = returned orelse return error.MissingClient;
    try validateIssuedClient(client);
    return client;
}

pub fn validateIssuedClient(client: []const u8) !void {
    try validateText(client, 256);
    if (std.mem.eql(u8, client, registration_client_id)) return error.InvalidClient;
}

pub fn authorizationForm(
    allocator: std.mem.Allocator,
    code: []const u8,
    client_id: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
) ![]u8 {
    try validateIssuedClient(client_id);
    try validateRedirect(redirect_uri);
    try validateText(code, 4096);
    try validateVerifier(verifier);
    return encoding.encodeForm(allocator, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "code", .value = code },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "code_verifier", .value = verifier },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "resource", .value = resource },
    });
}

pub fn refreshForm(
    allocator: std.mem.Allocator,
    client_id: []const u8,
    refresh_token: []const u8,
) ![]u8 {
    try validateIssuedClient(client_id);
    try validateText(refresh_token, token_bytes_max);
    return encoding.encodeForm(allocator, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "resource", .value = resource },
    });
}

pub fn revocationForm(
    allocator: std.mem.Allocator,
    client_id: []const u8,
    refresh_token: []const u8,
) ![]u8 {
    try validateIssuedClient(client_id);
    try validateText(refresh_token, token_bytes_max);
    return encoding.encodeForm(allocator, &.{
        .{ .name = "token", .value = refresh_token },
        .{ .name = "token_type_hint", .value = "refresh_token" },
        .{ .name = "client_id", .value = client_id },
    });
}

pub const TokenReply = struct {
    parsed: std.json.Parsed(std.json.Value),
    access_token: []const u8,
    refresh_token: ?[]const u8,
    id_token: ?[]const u8,
    scope: []const u8,
    expires_at: i64,
    earliest_refresh_at: ?i64,

    pub fn deinit(self: *TokenReply) void {
        std.crypto.secureZero(u8, @constCast(self.access_token));
        if (self.refresh_token) |token| std.crypto.secureZero(u8, @constCast(token));
        if (self.id_token) |token| std.crypto.secureZero(u8, @constCast(token));
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn parseTokenReply(
    allocator: std.mem.Allocator,
    body: []const u8,
    now_sec: i64,
) !TokenReply {
    return parseTokenReplyWithScope(allocator, body, now_sec, null);
}

pub fn parseRefreshTokenReply(
    allocator: std.mem.Allocator,
    body: []const u8,
    now_sec: i64,
    previous_scope: []const u8,
) !TokenReply {
    return parseTokenReplyWithScope(allocator, body, now_sec, previous_scope);
}

fn parseTokenReplyWithScope(
    allocator: std.mem.Allocator,
    body: []const u8,
    now_sec: i64,
    previous_scope: ?[]const u8,
) !TokenReply {
    if (body.len > reply_bytes_max or now_sec < 0) return error.InvalidTokenReply;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .max_value_len = token_bytes_max,
    });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTokenReply;
    const object = parsed.value.object;
    if (object.contains("error")) return error.TokenExchangeRejected;
    const token_type = try requiredString(object, "token_type", 32);
    if (!std.ascii.eqlIgnoreCase(token_type, "Bearer")) return error.InvalidTokenType;
    const expires = object.get("expires_in") orelse return error.MissingExpiry;
    if (expires != .integer or expires.integer <= 0 or
        expires.integer > token_lifetime_seconds_max) return error.InvalidExpiry;
    const deadline = std.math.add(i64, now_sec, expires.integer) catch
        return error.InvalidExpiry;
    var earliest: ?i64 = null;
    if (object.get("earliest_refresh_at")) |value| {
        if (value != .null) {
            const seconds = switch (value) {
                .integer => value.integer,
                .string => try parseRefreshTimestamp(value.string),
                else => return error.InvalidRefreshTime,
            };
            if (seconds < 0 or seconds >= deadline) return error.InvalidRefreshTime;
            earliest = seconds;
        }
    }
    const scope = if (object.contains("scope"))
        try requiredString(object, "scope", 4096)
    else if (previous_scope) |previous| blk: {
        try validateText(previous, 4096);
        break :blk try parsed.arena.allocator().dupe(u8, previous);
    } else return error.MissingTokenField;
    return .{
        .parsed = parsed,
        .access_token = try requiredString(object, "access_token", token_bytes_max),
        .refresh_token = try optionalString(object, "refresh_token", token_bytes_max),
        .id_token = try optionalString(object, "id_token", token_bytes_max),
        .scope = scope,
        .expires_at = deadline,
        .earliest_refresh_at = earliest,
    };
}

fn parseRefreshTimestamp(text: []const u8) !i64 {
    if (text.len < 20 or text.len > token_bytes_max) return error.InvalidRefreshTime;
    if (text[4] != '-' or text[7] != '-' or
        (text[10] != 'T' and text[10] != 't') or
        text[13] != ':' or text[16] != ':') return error.InvalidRefreshTime;
    const year = try timestampDigits(text[0..4]);
    const month = try timestampDigits(text[5..7]);
    const day = try timestampDigits(text[8..10]);
    const hour = try timestampDigits(text[11..13]);
    const minute = try timestampDigits(text[14..16]);
    const second = try timestampDigits(text[17..19]);
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const month_days: i64 = switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (leap) 29 else 28,
        else => return error.InvalidRefreshTime,
    };
    if (day < 1 or day > month_days or hour > 23 or minute > 59 or second > 59)
        return error.InvalidRefreshTime;
    var index: usize = 19;
    var round_up: i64 = 0;
    if (text[index] == '.') {
        index += 1;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
            if (text[index] != '0') round_up = 1;
        }
        if (index == start) return error.InvalidRefreshTime;
    }
    const offset = try timestampOffset(text[index..]);
    const adjusted_year = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const shifted_month = month + @as(i64, if (month > 2) -3 else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    const days = era * 146097 + day_of_era - 719468;
    const seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset;
    if (seconds < 0) return error.InvalidRefreshTime;
    return seconds + round_up;
}

fn timestampDigits(text: []const u8) !i64 {
    var value: i64 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidRefreshTime;
        value = value * 10 + byte - '0';
    }
    return value;
}

fn timestampOffset(text: []const u8) !i64 {
    if (std.mem.eql(u8, text, "Z") or std.mem.eql(u8, text, "z")) return 0;
    if (text.len != 6 or (text[0] != '+' and text[0] != '-') or text[3] != ':')
        return error.InvalidRefreshTime;
    const hours = try timestampDigits(text[1..3]);
    const minutes = try timestampDigits(text[4..6]);
    if (hours > 23 or minutes > 59) return error.InvalidRefreshTime;
    const seconds = hours * 3600 + minutes * 60;
    return if (text[0] == '-') -seconds else seconds;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8, maximum: usize) ![]const u8 {
    const value = object.get(key) orelse return error.MissingTokenField;
    if (value != .string) return error.InvalidTokenField;
    try validateText(value.string, maximum);
    return value.string;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8, maximum: usize) !?[]const u8 {
    if (!object.contains(key)) return null;
    return try requiredString(object, key, maximum);
}

pub fn hasPlanScope(scope: []const u8) bool {
    var values = std.mem.tokenizeScalar(u8, scope, ' ');
    while (values.next()) |value| {
        if (std.mem.eql(u8, value, "chatgpt.tokens.use.direct")) return true;
    }
    return false;
}

test "authorization uses the PKCE RFC 7636 challenge and bounded loopback callback" {
    const allocator = std.testing.allocator;
    const secrets = Secrets.fromRandom(@splat(7));
    const options: AuthorizeOptions = .{
        .client_id = registration_client_id,
        .app = "Example & Tool",
        .host_id = "urn:uuid:00000000-0000-4000-8000-000000000000",
        .redirect_uri = "http://127.0.0.1:1455/auth/callback",
        .state = &secrets.state,
        .nonce = &secrets.nonce,
        .verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
    };
    const url = try authorizeUrl(allocator, options);
    defer allocator.free(url);
    var fields = try encoding.parseForm(allocator, url[authorization_endpoint.len + 1 ..]);
    defer fields.deinit();
    try std.testing.expectEqualStrings("Example & Tool", fields.get("agent_name_hint").?);
    try std.testing.expectEqualStrings(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        fields.get("code_challenge").?,
    );
    try std.testing.expectEqualStrings(resource, fields.get("resource").?);
    for ([_][]const u8{
        "http://localhost:1455/auth/callback",
        "http://127.0.0.1:0/auth/callback",
        "http://127.0.0.1:65536/auth/callback",
        "http://127.0.0.1:1455/callback",
    }) |bad| try std.testing.expectError(error.InvalidRedirect, validateRedirect(bad));
}

test "callbacks validate state before denial and preserve the selected client" {
    const allocator = std.testing.allocator;
    var initial = try parseCallback(allocator, "code=c&state=s&client_id=oaiapp_one", "s", null);
    defer initial.deinit();
    try std.testing.expectEqualStrings("oaiapp_one", initial.client_id);
    var returning = try parseCallback(allocator, "code=c&state=s", "s", "oaiapp_one");
    defer returning.deinit();
    try std.testing.expectEqualStrings("oaiapp_one", returning.client_id);
    try std.testing.expectError(error.MissingClient, parseCallback(
        allocator,
        "code=c&state=s",
        "s",
        null,
    ));
    try std.testing.expectError(error.ClientMismatch, parseCallback(
        allocator,
        "code=c&state=s&client_id=other",
        "s",
        "oaiapp_one",
    ));
    try std.testing.expectError(error.StateMismatch, parseCallback(
        allocator,
        "error=access_denied&state=other",
        "s",
        null,
    ));
    try std.testing.expectError(error.AccessDenied, parseCallback(
        allocator,
        "error=access_denied&state=s",
        "s",
        null,
    ));
    try std.testing.expectError(error.DuplicateParameter, parseCallback(
        allocator,
        "code=c&state=s&state=s",
        "s",
        null,
    ));
}

test "token replies bind expiry and reject missing wrong typed and duplicate fields" {
    const allocator = std.testing.allocator;
    const valid =
        \\{"access_token":"a","refresh_token":"r","id_token":"i","token_type":"Bearer","scope":"openid chatgpt.tokens.use.direct","expires_in":3600}
    ;
    var reply = try parseTokenReply(allocator, valid, 100);
    defer reply.deinit();
    try std.testing.expectEqual(@as(i64, 3700), reply.expires_at);
    try std.testing.expect(hasPlanScope(reply.scope));
    try std.testing.expect(!hasPlanScope("openid not-chatgpt.tokens.use.direct"));
    try std.testing.expectError(error.InvalidTokenReply, parseTokenReply(allocator, "[]", 0));
    try std.testing.expectError(error.MissingTokenField, parseTokenReply(allocator, "{}", 0));
    try std.testing.expectError(error.DuplicateField, parseTokenReply(
        allocator,
        "{\"token_type\":\"Bearer\",\"token_type\":\"Bearer\"}",
        0,
    ));
    try std.testing.expectError(error.InvalidTokenField, parseTokenReply(
        allocator,
        "{\"token_type\":4}",
        0,
    ));
    try std.testing.expectError(error.InvalidTokenType, parseTokenReply(
        allocator,
        "{\"token_type\":\"Basic\"}",
        0,
    ));
    try std.testing.expectError(error.InvalidExpiry, parseTokenReply(
        allocator,
        "{\"token_type\":\"Bearer\",\"expires_in\":0}",
        0,
    ));
    try std.testing.expectError(error.TokenExchangeRejected, parseTokenReply(
        allocator,
        "{\"error\":\"invalid_grant\"}",
        0,
    ));
}

test "returning authorization keeps registration and reconsent explicit" {
    const allocator = std.testing.allocator;
    var secrets = Secrets.fromRandom(@splat(9));
    defer secrets.deinit();
    const url = try authorizeUrl(allocator, .{
        .client_id = "oaiapp_existing",
        .app = "actual-tool",
        .host_id = "urn:uuid:00000000-0000-4000-8000-000000000000",
        .redirect_uri = "http://127.0.0.1:65535/auth/callback",
        .state = &secrets.state,
        .nonce = &secrets.nonce,
        .verifier = &secrets.verifier,
        .enable_plan = true,
        .id_token_hint = "opaque.id.token",
    });
    defer allocator.free(url);
    var fields = try encoding.parseForm(allocator, url[authorization_endpoint.len + 1 ..]);
    defer fields.deinit();
    try std.testing.expect(fields.get("agent_name_hint") == null);
    try std.testing.expectEqualStrings("consent", fields.get("prompt").?);
    try std.testing.expectEqualStrings("oaiapp_existing", fields.get("client_id").?);
    const form = try refreshForm(allocator, "oaiapp_existing", "opaque & token");
    defer allocator.free(form);
    var refresh = try encoding.parseForm(allocator, form);
    defer refresh.deinit();
    try std.testing.expect(refresh.get("scope") == null);
    try std.testing.expectEqualStrings("opaque & token", refresh.get("refresh_token").?);
    try std.testing.expectError(error.InvalidClient, refreshForm(
        allocator,
        registration_client_id,
        "token",
    ));
    try std.testing.expectError(error.InvalidVerifier, authorizationForm(
        allocator,
        "code",
        "oaiapp_existing",
        "short",
        "http://127.0.0.1:1/auth/callback",
    ));
}

test "token expiry accepts exact bounds and detects overflow" {
    const allocator = std.testing.allocator;
    for ([_]i64{ 1, token_lifetime_seconds_max }) |seconds| {
        const body = try std.fmt.allocPrint(allocator,
            \\{{"access_token":"a","token_type":"Bearer","scope":"openid","expires_in":{d}}}
        , .{seconds});
        defer allocator.free(body);
        var reply = try parseTokenReply(allocator, body, 100);
        defer reply.deinit();
        try std.testing.expectEqual(100 + seconds, reply.expires_at);
        try std.testing.expect(reply.id_token == null);
        try std.testing.expect(reply.refresh_token == null);
    }
    for ([_][]const u8{ "-1", "86401", "1.5", "\"3600\"", "null", "true" }) |seconds| {
        const body = try std.fmt.allocPrint(allocator,
            \\{{"token_type":"Bearer","expires_in":{s}}}
        , .{seconds});
        defer allocator.free(body);
        try std.testing.expectError(error.InvalidExpiry, parseTokenReply(allocator, body, 100));
    }
    try std.testing.expectError(error.InvalidExpiry, parseTokenReply(
        allocator,
        "{\"token_type\":\"Bearer\",\"expires_in\":1}",
        std.math.maxInt(i64),
    ));
}

test "only refresh replies inherit owned previously granted scopes" {
    const allocator = std.testing.allocator;
    const body =
        \\{"access_token":"new","token_type":"Bearer","expires_in":3600}
    ;
    try std.testing.expectError(error.MissingTokenField, parseTokenReply(allocator, body, 100));
    var previous = "openid chatgpt.tokens.use.direct".*;
    var reply = try parseRefreshTokenReply(allocator, body, 100, &previous);
    defer reply.deinit();
    @memset(&previous, 'x');
    try std.testing.expectEqualStrings("openid chatgpt.tokens.use.direct", reply.scope);
    try std.testing.expect(hasPlanScope(reply.scope));
    var limited = try parseRefreshTokenReply(allocator, body, 100, "openid");
    defer limited.deinit();
    try std.testing.expectEqualStrings("openid", limited.scope);
    try std.testing.expect(!hasPlanScope(limited.scope));
}

test "refresh replies retain explicit downscopes and reject invalid explicit scopes" {
    const allocator = std.testing.allocator;
    const body =
        \\{"access_token":"new","token_type":"Bearer","scope":"openid","expires_in":3600}
    ;
    var reply = try parseRefreshTokenReply(allocator, body, 100, scopes);
    defer reply.deinit();
    try std.testing.expectEqualStrings("openid", reply.scope);
    try std.testing.expect(!hasPlanScope(reply.scope));
    for ([_][]const u8{ "null", "5", "false" }) |scope| {
        const invalid = try std.fmt.allocPrint(allocator,
            \\{{"access_token":"new","token_type":"Bearer","scope":{s},"expires_in":3600}}
        , .{scope});
        defer allocator.free(invalid);
        try std.testing.expectError(error.InvalidTokenField, parseRefreshTokenReply(
            allocator,
            invalid,
            100,
            scopes,
        ));
    }
}

test "refresh timestamps normalize UTC offsets leap days and nonzero fractions upward" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { text: []const u8, seconds: i64 }{
        .{ .text = "1970-01-01T00:00:00Z", .seconds = 0 },
        .{ .text = "1970-01-01T00:00:01.000Z", .seconds = 1 },
        .{ .text = "1970-01-01T00:00:01.001Z", .seconds = 2 },
        .{ .text = "1970-01-01T00:00:01.000000000000000000001Z", .seconds = 2 },
        .{ .text = "1970-01-01T00:00:59.999Z", .seconds = 60 },
        .{ .text = "1970-01-01T00:00:01+00:00", .seconds = 1 },
        .{ .text = "1970-01-01T01:30:01+01:30", .seconds = 1 },
        .{ .text = "1969-12-31T22:30:01-01:30", .seconds = 1 },
        .{ .text = "1970-01-01T01:30:01.1+01:30", .seconds = 2 },
        .{ .text = "1970-01-01t00:00:01z", .seconds = 1 },
        .{ .text = "2000-02-29T00:00:00Z", .seconds = 951782400 },
        .{ .text = "2024-02-29T00:00:00Z", .seconds = 1709164800 },
    };
    for (cases) |case| {
        const body = try std.fmt.allocPrint(allocator,
            \\{{"access_token":"a","token_type":"Bearer","scope":"openid","expires_in":3600,"earliest_refresh_at":"{s}"}}
        , .{case.text});
        defer allocator.free(body);
        var reply = try parseTokenReply(allocator, body, case.seconds);
        defer reply.deinit();
        try std.testing.expectEqual(case.seconds, reply.earliest_refresh_at.?);
    }
}

test "refresh timestamps reject malformed calendars clocks offsets and text" {
    for ([_][]const u8{
        "",
        "1970-01-01",
        "1970-01-01T00:00:00",
        "1970-01-01T00:00:00.Z",
        "1970-01-01T00:00:00.1",
        "1970-01-01T00:00:00ZZ",
        "1970-01-01T00:00:00Z ",
        "1970-01-01T00:00:00+00",
        "1970-01-01T00:00:00+00:00Z",
        "1970-01-01T00:00:00+24:00",
        "1970-01-01T00:00:00-00:60",
        "1970-01-01T00:00:00++1:00",
        "1970-01-01T00:00:00+00:+1",
        "1970-00-01T00:00:00Z",
        "1970-13-01T00:00:00Z",
        "1970-01-00T00:00:00Z",
        "1970-04-31T00:00:00Z",
        "2001-02-29T00:00:00Z",
        "2100-02-29T00:00:00Z",
        "2000-02-30T00:00:00Z",
        "1970-01-01T24:00:00Z",
        "1970-01-01T00:60:00Z",
        "1970-01-01T00:00:60Z",
        "1970-01-01T+1:00:00Z",
        "1970-01-01T00:-1:00Z",
        "1970-01-01T00:00:+1Z",
        "+970-01-01T00:00:00Z",
        "1970-+1-01T00:00:00Z",
        "1970-01-+1T00:00:00Z",
        "1970/01/01T00:00:00Z",
        "1970-01-01 00:00:00Z",
        "1969-12-31T23:59:59.9Z",
        "1970-01-01T00:00:00+00:01",
        "0000-01-01T00:00:00Z",
    }) |invalid| {
        try std.testing.expectError(error.InvalidRefreshTime, parseRefreshTimestamp(invalid));
    }
}

test "refresh time retains integer and null support and validates rounded deadline" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "0", "59", "null", "\"1970-01-01T00:00:59.000Z\"" }) |time| {
        const body = try std.fmt.allocPrint(allocator,
            \\{{"access_token":"a","token_type":"Bearer","scope":"openid","expires_in":60,"earliest_refresh_at":{s}}}
        , .{time});
        defer allocator.free(body);
        var reply = try parseTokenReply(allocator, body, 0);
        defer reply.deinit();
        if (std.mem.eql(u8, time, "null")) {
            try std.testing.expect(reply.earliest_refresh_at == null);
        } else {
            try std.testing.expectEqual(
                @as(i64, if (time[0] == '0') 0 else 59),
                reply.earliest_refresh_at.?,
            );
        }
    }
    for ([_][]const u8{
        "-1",
        "60",
        "1.5",
        "true",
        "[]",
        "{}",
        "\"59\"",
        "\"1970-01-01T00:00:59.0001Z\"",
        "\"1970-01-01T00:01:00Z\"",
        "\"9999-12-31T23:59:59Z\"",
    }) |time| {
        const body = try std.fmt.allocPrint(allocator,
            \\{{"access_token":"a","token_type":"Bearer","scope":"openid","expires_in":60,"earliest_refresh_at":{s}}}
        , .{time});
        defer allocator.free(body);
        try std.testing.expectError(error.InvalidRefreshTime, parseTokenReply(allocator, body, 0));
    }
}
