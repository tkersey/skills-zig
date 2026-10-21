const std = @import("std");
const store_module = @import("store.zig");
const oauth = @import("oauth.zig");
const jwt = @import("jwt.zig");
const transport_module = @import("transport.zig");

pub const refresh_margin_seconds = 60;
pub const models_max = 512;

pub const Clock = struct {
    context: ?*anyopaque = null,
    now_fn: *const fn (?*anyopaque, std.Io) i64 = wallTime,

    pub fn now(self: Clock, io: std.Io) !i64 {
        const value = self.now_fn(self.context, io);
        if (value < 0) return error.InvalidClock;
        return value;
    }

    fn wallTime(_: ?*anyopaque, io: std.Io) i64 {
        return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, 1_000_000_000));
    }
};

pub const Phase = enum {
    pending,
    signed_out,
    ready,
    plan_usage_disabled,
    refresh_required,
    reauthentication_required,
};

pub const Status = struct {
    app: []const u8,
    account: []const u8,
    client_id: ?[]const u8,
    subject: ?[]const u8,
    email: ?[]const u8,
    phase: Phase,
    expires_at: ?i64,
};

pub fn status(record: store_module.Record, now: i64) Status {
    return .{
        .app = record.app,
        .account = record.label,
        .client_id = record.client_id,
        .subject = record.subject,
        .email = record.email,
        .phase = phaseFor(record, now),
        .expires_at = if (record.tokens) |tokens| tokens.expires_at else null,
    };
}

fn phaseFor(record: store_module.Record, now: i64) Phase {
    if (record.refresh_pending) return .reauthentication_required;
    if (record.tokens) |tokens| {
        if (!oauth.hasPlanScope(tokens.scope)) return .plan_usage_disabled;
        if (tokens.expires_at <= now) return .refresh_required;
        return .ready;
    }
    return if (record.subject == null) .pending else .signed_out;
}

pub const Credential = struct {
    version: u32 = 1,
    provider: []const u8 = "chatgpt",
    app: []const u8,
    account: []const u8,
    issuer: []const u8 = oauth.issuer,
    client_id: []const u8,
    subject: []const u8,
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    resource: []const u8 = oauth.resource,
    scope: []const u8,
    expires_at: i64,
};

pub const Lease = struct {
    arena: std.heap.ArenaAllocator,
    value: Credential,

    fn init(allocator: std.mem.Allocator, record: store_module.Record) !Lease {
        const tokens = record.tokens orelse return error.NotSignedIn;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const value: Credential = .{
            .app = try a.dupe(u8, record.app),
            .account = try a.dupe(u8, record.label),
            .client_id = try a.dupe(u8, record.client_id orelse return error.InvalidRegistration),
            .subject = try a.dupe(u8, record.subject orelse return error.InvalidRegistration),
            .access_token = try a.dupe(u8, tokens.access_token),
            .scope = try a.dupe(u8, tokens.scope),
            .expires_at = tokens.expires_at,
        };
        return .{ .arena = arena, .value = value };
    }

    pub fn deinit(self: *Lease) void {
        std.crypto.secureZero(u8, @constCast(self.value.access_token));
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_module.Store,
    transport: transport_module.Transport,
    clock: Clock = .{},
    random_fn: *const fn (std.Io, []u8) anyerror!void = secureRandom,
    last_http_status: ?u16 = null,

    pub fn beginLogin(self: *Manager, options: LoginOptions) !Login {
        try oauth.validateRedirect(options.redirect_uri);
        var account = if (options.new_account)
            try self.store.lock(options.label)
        else
            try self.lockExisting(options.label);
        errdefer account.deinit();
        if (options.new_account) try account.reserveNew();
        var record = try account.load();
        errdefer record.deinit();
        const host_id = try self.store.getOrCreateHostId();
        defer self.store.allocator.free(host_id);
        var random: [96]u8 = undefined;
        try self.random_fn(self.io, &random);
        defer std.crypto.secureZero(u8, &random);
        var secrets = oauth.Secrets.fromRandom(random);
        errdefer secrets.deinit();
        const redirect = try self.allocator.dupe(u8, options.redirect_uri);
        errdefer self.allocator.free(redirect);
        const url = try oauth.authorizeUrl(self.allocator, .{
            .client_id = record.value.client_id orelse oauth.registration_client_id,
            .app = self.store.app,
            .host_id = host_id,
            .redirect_uri = redirect,
            .state = &secrets.state,
            .nonce = &secrets.nonce,
            .verifier = &secrets.verifier,
            .enable_plan = options.enable_plan,
        });
        return .{
            .manager = self,
            .account = account,
            .record = record,
            .secrets = secrets,
            .redirect_uri = redirect,
            .authorization_url = url,
        };
    }

    pub fn credential(self: *Manager, label: []const u8) !Lease {
        var account = try self.lockExisting(label);
        defer account.deinit();
        var record = try account.load();
        defer record.deinit();
        if (record.value.refresh_pending) return error.ReauthenticationRequired;
        const tokens = record.value.tokens orelse return error.NotSignedIn;
        if (!oauth.hasPlanScope(tokens.scope)) return error.PlanUsageNotEnabled;
        const now = try self.clock.now(self.io);
        if (tokens.expires_at > now) {
            if (tokens.expires_at - now > refresh_margin_seconds or
                (tokens.earliest_refresh_at orelse 0) > now)
                return Lease.init(self.allocator, record.value);
        }
        return self.refresh(&account, record.value);
    }

    fn refresh(self: *Manager, account: *store_module.Account, old: store_module.Record) !Lease {
        const tokens = old.tokens orelse return error.NotSignedIn;
        const form = try oauth.refreshForm(self.allocator, old.client_id.?, tokens.refresh_token);
        defer erase(self.allocator, form);
        var pending = old;
        pending.refresh_pending = true;
        try account.save(pending);
        var response = try self.request(.{ .token = form });
        defer response.deinit();
        if (response.status != 200) {
            if (try terminalTokenFailure(self.allocator, response.body)) {
                pending.tokens = null;
                pending.refresh_pending = false;
                try account.save(pending);
            }
            return error.ReauthenticationRequired;
        }
        var reply = try oauth.parseRefreshTokenReply(
            self.allocator,
            response.body,
            try self.clock.now(self.io),
            tokens.scope,
        );
        defer reply.deinit();
        var identity: ?jwt.Identity = null;
        defer if (identity) |*value| value.deinit();
        if (reply.id_token) |id_token| {
            identity = try self.verifyIdentity(id_token, old.client_id.?, null);
            if (!std.mem.eql(u8, identity.?.subject, old.subject.?))
                return error.IdentityMismatch;
        }
        var updated = old;
        updated.tokens = try tokenSet(reply, tokens.id_token);
        updated.refresh_pending = false;
        if (identity) |value| updated.email = value.email;
        try account.save(updated);
        if (!oauth.hasPlanScope(reply.scope)) return error.PlanUsageNotEnabled;
        if (reply.expires_at <= try self.clock.now(self.io)) return error.CredentialExpired;
        return Lease.init(self.allocator, updated);
    }

    pub fn logout(self: *Manager, label: []const u8) !LogoutResult {
        var account = try self.lockExisting(label);
        defer account.deinit();
        var record = try account.load();
        defer record.deinit();
        var result: LogoutResult = .{ .had_session = record.value.tokens != null };
        var signed_out = record.value;
        signed_out.tokens = null;
        signed_out.refresh_pending = false;
        try account.save(signed_out);
        if (record.value.tokens) |tokens| {
            self.revoke(record.value.client_id.?, tokens.refresh_token) catch |err| {
                result.revocation_error = @errorName(err);
            };
            result.revoked = result.revocation_error == null;
        }
        return result;
    }

    fn revoke(self: *Manager, client_id: []const u8, refresh_token: []const u8) !void {
        var configuration = try self.discovery();
        defer configuration.deinit();
        const form = try oauth.revocationForm(self.allocator, client_id, refresh_token);
        defer erase(self.allocator, form);
        var response = try self.request(.{ .revoke = .{
            .url = configuration.parsed.value.revocation_endpoint,
            .form = form,
        } });
        defer response.deinit();
        if (response.status < 200 or response.status >= 300) return error.RevocationFailed;
    }

    pub fn models(self: *Manager, label: []const u8) !Catalogue {
        var lease = try self.credential(label);
        defer lease.deinit();
        var response = try self.request(.{ .models = lease.value.access_token });
        defer response.deinit();
        if (response.status != 200) return error.ModelsRequestFailed;
        return Catalogue.parse(self.allocator, response.body);
    }

    fn discovery(self: *Manager) !transport_module.Discovery {
        var response = try self.request(.discovery);
        defer response.deinit();
        if (response.status != 200) return error.DiscoveryFailed;
        return transport_module.Discovery.parse(self.allocator, response.body);
    }

    fn verifyIdentity(
        self: *Manager,
        id_token: []const u8,
        client_id: []const u8,
        nonce: ?[]const u8,
    ) !jwt.Identity {
        var configuration = try self.discovery();
        defer configuration.deinit();
        var response = try self.request(.{ .keys = configuration.parsed.value.jwks_uri });
        defer response.deinit();
        if (response.status != 200) return error.SigningKeysUnavailable;
        return jwt.verify(self.allocator, id_token, response.body, .{
            .client_id = client_id,
            .nonce = nonce,
            .now_sec = try self.clock.now(self.io),
        });
    }

    fn request(self: *Manager, request_value: transport_module.Request) !transport_module.Response {
        self.last_http_status = null;
        const response = try self.transport.request(self.allocator, self.io, request_value);
        self.last_http_status = response.status;
        return response;
    }

    fn lockExisting(self: *Manager, label: []const u8) !store_module.Account {
        var record = try self.store.load(label);
        record.deinit();
        return self.store.lock(label);
    }
};

pub const LoginOptions = struct {
    label: []const u8,
    new_account: bool = false,
    redirect_uri: []const u8,
    enable_plan: bool = false,
};

pub const Login = struct {
    manager: *Manager,
    account: store_module.Account,
    record: std.json.Parsed(store_module.Record),
    secrets: oauth.Secrets,
    redirect_uri: []u8,
    authorization_url: []u8,
    consumed: bool = false,

    pub fn deinit(self: *Login) void {
        const allocator = self.manager.allocator;
        self.account.deinit();
        self.record.deinit();
        self.secrets.deinit();
        allocator.free(self.redirect_uri);
        erase(allocator, self.authorization_url);
        self.* = undefined;
    }

    pub fn complete(self: *Login, callback: oauth.Callback) !void {
        if (self.consumed) return error.LoginAlreadyConsumed;
        self.consumed = true;
        try oauth.validateIssuedClient(callback.client_id);
        if (self.record.value.client_id) |expected| {
            if (!std.mem.eql(u8, expected, callback.client_id)) return error.ClientMismatch;
        }
        var updated = self.record.value;
        updated.client_id = callback.client_id;
        try self.account.save(updated);
        const manager = self.manager;
        const form = try oauth.authorizationForm(
            manager.allocator,
            callback.code,
            callback.client_id,
            &self.secrets.verifier,
            self.redirect_uri,
        );
        defer erase(manager.allocator, form);
        var response = try manager.request(.{ .token = form });
        defer response.deinit();
        if (response.status != 200) return error.TokenExchangeRejected;
        var reply = try oauth.parseTokenReply(
            manager.allocator,
            response.body,
            try manager.clock.now(manager.io),
        );
        defer reply.deinit();
        const id_token = reply.id_token orelse return error.IdTokenMissing;
        var identity = try manager.verifyIdentity(
            id_token,
            callback.client_id,
            &self.secrets.nonce,
        );
        defer identity.deinit();
        if (updated.subject) |expected| {
            if (!std.mem.eql(u8, expected, identity.subject)) return error.IdentityMismatch;
        }
        updated.subject = identity.subject;
        updated.email = identity.email;
        updated.tokens = try tokenSet(reply, null);
        updated.refresh_pending = false;
        try self.account.save(updated);
    }
};

pub const LogoutResult = struct {
    had_session: bool,
    revoked: bool = false,
    revocation_error: ?[]const u8 = null,
};

pub const Model = struct { slug: []const u8, display_name: []const u8 };

pub const Catalogue = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(Value),
    visible: []Model,

    const Entry = struct { slug: []const u8, display_name: []const u8, visibility: []const u8 };
    const Value = struct { models: []Entry };

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Catalogue {
        if (bytes.len > transport_module.response_bytes_max) return error.ResponseTooLarge;
        const parsed = try std.json.parseFromSlice(Value, allocator, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        errdefer parsed.deinit();
        if (parsed.value.models.len > models_max) return error.TooManyModels;
        var visible: std.ArrayList(Model) = .empty;
        errdefer visible.deinit(allocator);
        for (parsed.value.models) |entry| {
            try oauth.validateText(entry.slug, 256);
            try oauth.validateText(entry.display_name, 256);
            try oauth.validateText(entry.visibility, 32);
            if (!std.mem.eql(u8, entry.visibility, "list")) continue;
            try visible.append(allocator, .{
                .slug = entry.slug,
                .display_name = entry.display_name,
            });
        }
        return .{
            .allocator = allocator,
            .parsed = parsed,
            .visible = try visible.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Catalogue) void {
        self.allocator.free(self.visible);
        self.parsed.deinit();
        self.* = undefined;
    }
};

fn tokenSet(reply: oauth.TokenReply, previous_id: ?[]const u8) !store_module.TokenSet {
    return .{
        .access_token = reply.access_token,
        .refresh_token = reply.refresh_token orelse return error.RefreshTokenMissing,
        .id_token = reply.id_token orelse previous_id orelse return error.IdTokenMissing,
        .scope = reply.scope,
        .expires_at = reply.expires_at,
        .earliest_refresh_at = reply.earliest_refresh_at,
    };
}

fn terminalTokenFailure(allocator: std.mem.Allocator, bytes: []const u8) !bool {
    const Failure = struct { @"error": []const u8 };
    if (bytes.len > oauth.reply_bytes_max) return false;
    const parsed = std.json.parseFromSlice(Failure, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.@"error", "invalid_grant") or
        std.mem.eql(u8, parsed.value.@"error", "invalid_client");
}

fn erase(allocator: std.mem.Allocator, value: []u8) void {
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

fn secureRandom(io: std.Io, bytes: []u8) !void {
    try io.randomSecure(bytes);
}

test "catalogue preserves provider order and excludes hidden entries" {
    var catalogue = try Catalogue.parse(std.testing.allocator,
        \\{"models":[{"slug":"first","display_name":"First","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"},{"slug":"last","display_name":"Last","visibility":"list"}]}
    );
    defer catalogue.deinit();
    try std.testing.expectEqual(@as(usize, 2), catalogue.visible.len);
    try std.testing.expectEqualStrings("first", catalogue.visible[0].slug);
    try std.testing.expectEqualStrings("last", catalogue.visible[1].slug);
}
