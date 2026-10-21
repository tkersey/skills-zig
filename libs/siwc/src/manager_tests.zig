const std = @import("std");
const manager_module = @import("manager.zig");
const store_module = @import("store.zig");
const oauth = @import("oauth.zig");
const vectors = @import("jwt_vectors.zig");
const transport_module = @import("transport.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;
const app = "test-app";
const label = "personal";
const now_seconds = 1_700_000_100;
const redirect_uri = "http://127.0.0.1:23456/auth/callback";
const discovery =
    \\{"issuer":"https://auth.openai.com","jwks_uri":"https://auth.openai.com/keys","revocation_endpoint":"https://auth.openai.com/revoke"}
;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    store: store_module.Store,
    now: i64 = now_seconds,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const parent = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(parent);
        const path = try std.fs.path.join(allocator, &.{ parent, "private" });
        errdefer allocator.free(path);
        return .{
            .tmp = tmp,
            .path = path,
            .store = try store_module.Store.open(io, allocator, path, app, .create),
        };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.tmp.cleanup();
        allocator.free(self.path);
    }

    fn seed(self: *Fixture, record: store_module.Record) !void {
        var account = try self.store.lock(label);
        defer account.deinit();
        try account.reserveNew();
        try account.save(record);
    }

    fn script(self: *Fixture, steps: []const Step) Script {
        return .{ .store = &self.store, .now = &self.now, .steps = steps };
    }

    fn manager(self: *Fixture, scripted: *Script) manager_module.Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .store = &self.store,
            .transport = .{ .context = scripted, .request_fn = Script.request },
            .clock = .{ .context = &self.now, .now_fn = testClock },
            .random_fn = testRandom,
        };
    }
};

const Phase = enum { unchecked, registered, refresh_pending, signed_out };
const Step = struct {
    kind: std.meta.Tag(transport_module.Request),
    body: []const u8 = "",
    status: u16 = 200,
    failure: ?anyerror = null,
    persisted: Phase = .unchecked,
    form_contains: ?[]const u8 = null,
    advance_seconds: i64 = 0,
};

const Script = struct {
    store: *store_module.Store,
    now: *i64,
    steps: []const Step,
    next: usize = 0,

    fn request(
        context: *anyopaque,
        memory: std.mem.Allocator,
        _: std.Io,
        request_value: transport_module.Request,
    ) !transport_module.Response {
        const self: *Script = @ptrCast(@alignCast(context));
        if (self.next >= self.steps.len) return error.UnexpectedNetworkRequest;
        const step = self.steps[self.next];
        self.next += 1;
        try std.testing.expectEqual(step.kind, std.meta.activeTag(request_value));
        try self.inspect(step.persisted);
        if (step.form_contains) |expected| {
            const form = switch (request_value) {
                .token => |value| value,
                .revoke => |value| value.form,
                else => return error.UnexpectedRequestKind,
            };
            try std.testing.expect(std.mem.indexOf(u8, form, expected) != null);
        }
        self.now.* += step.advance_seconds;
        if (step.failure) |failure| return failure;
        return .{
            .allocator = memory,
            .status = step.status,
            .body = try memory.dupe(u8, step.body),
        };
    }

    fn inspect(self: *Script, phase: Phase) !void {
        if (phase == .unchecked) return;
        var parsed = try self.store.load(label);
        defer parsed.deinit();
        const record = parsed.value;
        try std.testing.expectEqualStrings("oaiapp_test", record.client_id.?);
        switch (phase) {
            .registered => {
                try std.testing.expect(record.tokens == null and record.subject == null);
                try std.testing.expect(!record.refresh_pending);
            },
            .refresh_pending => {
                try std.testing.expect(record.refresh_pending);
                try std.testing.expectEqualStrings("old-refresh", record.tokens.?.refresh_token);
                try std.testing.expectEqualStrings("old-access", record.tokens.?.access_token);
            },
            .signed_out => {
                try std.testing.expect(record.tokens == null and !record.refresh_pending);
                try std.testing.expectEqualStrings("subject", record.subject.?);
            },
            .unchecked => unreachable,
        }
    }

    fn expectConsumed(self: *const Script) !void {
        try std.testing.expectEqual(self.steps.len, self.next);
    }
};

fn testClock(context: ?*anyopaque, _: std.Io) i64 {
    const now: *i64 = @ptrCast(@alignCast(context.?));
    return now.*;
}

fn testRandom(_: std.Io, bytes: []u8) !void {
    @memset(bytes, 0);
}

fn connectedRecord() store_module.Record {
    return .{
        .app = app,
        .label = label,
        .client_id = "oaiapp_test",
        .subject = "subject",
        .email = "test@example.invalid",
        .tokens = .{
            .access_token = "old-access",
            .refresh_token = "old-refresh",
            .id_token = vectors.login,
            .scope = oauth.scopes,
            .expires_at = now_seconds + 3600,
        },
    };
}

const Reply = struct {
    access_token: []const u8 = "new-access",
    refresh_token: ?[]const u8 = "new-refresh",
    id_token: ?[]const u8 = null,
    token_type: []const u8 = "Bearer",
    scope: []const u8 = oauth.scopes,
    expires_in: i64 = 3600,
};

fn replyBytes(reply: Reply) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, reply, .{
        .emit_null_optional_fields = false,
    });
}

fn completeLogin(manager: *manager_module.Manager, new_account: bool) !void {
    var login = try manager.beginLogin(.{
        .label = label,
        .new_account = new_account,
        .redirect_uri = redirect_uri,
    });
    defer login.deinit();
    var callback = try oauth.parseCallback(
        allocator,
        "code=synthetic-code&state=" ++ vectors.login_nonce ++ "&client_id=oaiapp_test",
        &login.secrets.state,
        login.record.value.client_id,
    );
    defer callback.deinit();
    try login.complete(callback);
    try std.testing.expectError(error.LoginAlreadyConsumed, login.complete(callback));
}

test "login frees new and stored host identifiers with the store allocator" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var memory = std.heap.ArenaAllocator.init(allocator);
    defer memory.deinit();
    var script = fixture.script(&.{});
    var manager = fixture.manager(&script);
    manager.allocator = memory.allocator();
    for ([_]bool{ true, false }) |new_account| {
        var login = try manager.beginLogin(.{
            .label = label,
            .new_account = new_account,
            .redirect_uri = redirect_uri,
        });
        defer login.deinit();
        try std.testing.expect(std.mem.indexOf(
            u8,
            login.authorization_url,
            "ext_agent_host_id=",
        ) != null);
    }
    try script.expectConsumed();
}

test "initial login persists issued registration before exchange and verifies identity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const reply = try replyBytes(.{ .id_token = vectors.login });
    defer allocator.free(reply);
    const steps = [_]Step{
        .{
            .kind = .token,
            .body = reply,
            .persisted = .registered,
            .form_contains = "client_id=oaiapp_test",
        },
        .{ .kind = .discovery, .body = discovery },
        .{ .kind = .keys, .body = vectors.jwks },
    };
    var script = fixture.script(&steps);
    var manager = fixture.manager(&script);
    try completeLogin(&manager, true);
    try script.expectConsumed();
    var parsed = try fixture.store.load(label);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("subject", parsed.value.subject.?);
    try std.testing.expectEqualStrings("test@example.invalid", parsed.value.email.?);
    try std.testing.expectEqualStrings("new-refresh", parsed.value.tokens.?.refresh_token);
    try std.testing.expectEqual(
        manager_module.Phase.ready,
        manager_module.status(parsed.value, fixture.now).phase,
    );
    var lease = try manager.credential(label);
    defer lease.deinit();
    try std.testing.expectEqualStrings("new-access", lease.value.access_token);
    try script.expectConsumed();
}

test "failed initial exchange retains registration for the explicit account" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const steps = [_]Step{.{
        .kind = .token,
        .status = 400,
        .body = "{\"error\":\"invalid_grant\"}",
        .persisted = .registered,
    }};
    var script = fixture.script(&steps);
    var manager = fixture.manager(&script);
    try std.testing.expectError(error.TokenExchangeRejected, completeLogin(&manager, true));
    var parsed = try fixture.store.load(label);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("oaiapp_test", parsed.value.client_id.?);
    try std.testing.expect(parsed.value.tokens == null and parsed.value.subject == null);
    var returning = try manager.beginLogin(.{ .label = label, .redirect_uri = redirect_uri });
    defer returning.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        returning.authorization_url,
        "client_id=oaiapp_test",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        returning.authorization_url,
        "dynamic_agent_client",
    ) == null);
    try script.expectConsumed();
}

test "rejected signature nonce or subject cannot replace an established identity" {
    const tampered = try allocator.dupe(u8, vectors.login);
    defer allocator.free(tampered);
    const signature_start = std.mem.lastIndexOfScalar(u8, tampered, '.').? + 1;
    tampered[signature_start] = if (tampered[signature_start] == 'A') 'B' else 'A';
    const Case = struct { token: []const u8, subject: []const u8, failure: anyerror };
    const cases = [_]Case{
        .{ .token = tampered, .subject = "subject", .failure = error.InvalidSignature },
        .{ .token = vectors.valid, .subject = "subject", .failure = error.NonceMismatch },
        .{ .token = vectors.login, .subject = "old-subject", .failure = error.IdentityMismatch },
    };
    for (cases) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var previous = connectedRecord();
        previous.subject = case.subject;
        try fixture.seed(previous);
        const reply = try replyBytes(.{ .id_token = case.token });
        defer allocator.free(reply);
        const steps = [_]Step{
            .{ .kind = .token, .body = reply },
            .{ .kind = .discovery, .body = discovery },
            .{ .kind = .keys, .body = vectors.jwks },
        };
        var script = fixture.script(&steps);
        var manager = fixture.manager(&script);
        try std.testing.expectError(case.failure, completeLogin(&manager, false));
        var parsed = try fixture.store.load(label);
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case.subject, parsed.value.subject.?);
        try std.testing.expectEqualStrings("oaiapp_test", parsed.value.client_id.?);
        try std.testing.expectEqualStrings("old-refresh", parsed.value.tokens.?.refresh_token);
        try std.testing.expectEqualStrings("old-access", parsed.value.tokens.?.access_token);
        try script.expectConsumed();
    }
}

test "current credentials and earliest refresh window do not perform network calls" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var previous = connectedRecord();
    previous.tokens.?.expires_at = fixture.now + 10;
    previous.tokens.?.earliest_refresh_at = fixture.now + 5;
    try fixture.seed(previous);
    var script = fixture.script(&.{});
    var manager = fixture.manager(&script);
    var lease = try manager.credential(label);
    defer lease.deinit();
    try std.testing.expectEqualStrings("old-access", lease.value.access_token);
    try script.expectConsumed();
}

test "rotation marks pending before request and publishes the entire new set once" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var previous = connectedRecord();
    previous.tokens.?.expires_at = fixture.now - 1;
    try fixture.seed(previous);
    const reply = try replyBytes(.{});
    defer allocator.free(reply);
    const steps = [_]Step{.{
        .kind = .token,
        .body = reply,
        .persisted = .refresh_pending,
        .form_contains = "refresh_token=old-refresh",
    }};
    var script = fixture.script(&steps);
    var manager = fixture.manager(&script);
    var first = try manager.credential(label);
    defer first.deinit();
    try std.testing.expectEqualStrings("new-access", first.value.access_token);
    var parsed = try fixture.store.load(label);
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.refresh_pending);
    try std.testing.expectEqualStrings("new-access", parsed.value.tokens.?.access_token);
    try std.testing.expectEqualStrings("new-refresh", parsed.value.tokens.?.refresh_token);
    try std.testing.expectEqualStrings(vectors.login, parsed.value.tokens.?.id_token);
    var second = try manager.credential(label);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.value.access_token, second.value.access_token);
    try script.expectConsumed();
}

test "refresh omission retains saved grants and persists rotated credentials" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var previous = connectedRecord();
    previous.tokens.?.expires_at = fixture.now - 1;
    previous.tokens.?.scope = "openid chatgpt.tokens.use.direct";
    try fixture.seed(previous);
    const steps = [_]Step{.{
        .kind = .token,
        .body =
        \\{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer",
        \\"expires_in":3600,"earliest_refresh_at":"2023-11-14T22:15:01.5Z"}
        ,
        .persisted = .refresh_pending,
    }};
    var script = fixture.script(&steps);
    var manager = fixture.manager(&script);
    var lease = try manager.credential(label);
    defer lease.deinit();
    try std.testing.expectEqualStrings(previous.tokens.?.scope, lease.value.scope);
    var persisted = try fixture.store.load(label);
    defer persisted.deinit();
    try std.testing.expect(!persisted.value.refresh_pending);
    try std.testing.expectEqualStrings("new-refresh", persisted.value.tokens.?.refresh_token);
    try std.testing.expectEqualStrings(previous.tokens.?.scope, persisted.value.tokens.?.scope);
    try std.testing.expectEqual(
        @as(?i64, 1_700_000_102),
        persisted.value.tokens.?.earliest_refresh_at,
    );
    try script.expectConsumed();
}

test "refresh downscope persists the narrower grant without exporting a credential" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var previous = connectedRecord();
    previous.tokens.?.expires_at = fixture.now - 1;
    try fixture.seed(previous);
    const reply = try replyBytes(.{ .scope = "openid" });
    defer allocator.free(reply);
    const steps = [_]Step{.{ .kind = .token, .body = reply, .persisted = .refresh_pending }};
    var script = fixture.script(&steps);
    var manager = fixture.manager(&script);
    try std.testing.expectError(error.PlanUsageNotEnabled, manager.credential(label));
    var persisted = try fixture.store.load(label);
    defer persisted.deinit();
    try std.testing.expect(!persisted.value.refresh_pending);
    try std.testing.expectEqualStrings("openid", persisted.value.tokens.?.scope);
    try std.testing.expectEqualStrings("new-refresh", persisted.value.tokens.?.refresh_token);
    try std.testing.expectError(error.PlanUsageNotEnabled, manager.credential(label));
    try script.expectConsumed();
}

test "uncertain network and server failures never replay a refresh token" {
    const cases = [_]Step{
        .{ .kind = .token, .failure = error.SyntheticNetworkFailure },
        .{ .kind = .token, .status = 503, .body = "{\"error\":\"temporarily_unavailable\"}" },
    };
    for (cases) |step| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var previous = connectedRecord();
        previous.tokens.?.expires_at = fixture.now - 1;
        try fixture.seed(previous);
        var requested = step;
        requested.persisted = .refresh_pending;
        var script = fixture.script(&.{requested});
        var manager = fixture.manager(&script);
        try std.testing.expectError(
            step.failure orelse error.ReauthenticationRequired,
            manager.credential(label),
        );
        var parsed = try fixture.store.load(label);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.refresh_pending);
        try std.testing.expectEqualStrings("old-refresh", parsed.value.tokens.?.refresh_token);
        try std.testing.expectError(error.ReauthenticationRequired, manager.credential(label));
        try script.expectConsumed();
    }
}

test "terminal invalid grant clears tokens and keeps the account registration" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var previous = connectedRecord();
    previous.tokens.?.expires_at = fixture.now - 1;
    try fixture.seed(previous);
    const steps = [_]Step{.{
        .kind = .token,
        .status = 400,
        .body = "{\"error\":\"invalid_grant\"}",
        .persisted = .refresh_pending,
    }};
    var script = fixture.script(&steps);
    var manager = fixture.manager(&script);
    try std.testing.expectError(error.ReauthenticationRequired, manager.credential(label));
    var parsed = try fixture.store.load(label);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.tokens == null and !parsed.value.refresh_pending);
    try std.testing.expectEqualStrings("oaiapp_test", parsed.value.client_id.?);
    try std.testing.expectEqualStrings("subject", parsed.value.subject.?);
    try std.testing.expectError(error.NotSignedIn, manager.credential(label));
    try script.expectConsumed();
}

test "identity-only consent is preserved but cannot produce a model credential" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const reply = try replyBytes(.{ .id_token = vectors.login, .scope = "openid offline_access" });
    defer allocator.free(reply);
    const steps = [_]Step{
        .{ .kind = .token, .body = reply, .persisted = .registered },
        .{ .kind = .discovery, .body = discovery },
        .{ .kind = .keys, .body = vectors.jwks },
    };
    var script = fixture.script(&steps);
    var manager = fixture.manager(&script);
    try completeLogin(&manager, true);
    var parsed = try fixture.store.load(label);
    defer parsed.deinit();
    try std.testing.expectEqual(
        manager_module.Phase.plan_usage_disabled,
        manager_module.status(parsed.value, fixture.now).phase,
    );
    try std.testing.expectError(error.PlanUsageNotEnabled, manager.credential(label));
    try script.expectConsumed();
}

test "logout clears local state before revocation and reports confirmation separately" {
    for ([_]bool{ true, false }) |confirmed| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.seed(connectedRecord());
        const steps = [_]Step{
            .{ .kind = .discovery, .body = discovery, .persisted = .signed_out },
            .{
                .kind = .revoke,
                .status = 204,
                .persisted = .signed_out,
                .form_contains = "token=old-refresh",
                .failure = if (confirmed) null else error.SyntheticNetworkFailure,
            },
        };
        var script = fixture.script(&steps);
        var manager = fixture.manager(&script);
        const result = try manager.logout(label);
        try std.testing.expect(result.had_session);
        try std.testing.expectEqual(confirmed, result.revoked);
        if (confirmed) {
            try std.testing.expect(result.revocation_error == null);
        } else try std.testing.expectEqualStrings(
            "SyntheticNetworkFailure",
            result.revocation_error.?,
        );
        var parsed = try fixture.store.load(label);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.tokens == null and !parsed.value.refresh_pending);
        try std.testing.expectEqualStrings("subject", parsed.value.subject.?);
        const repeated = try manager.logout(label);
        try std.testing.expect(!repeated.had_session and !repeated.revoked);
        try script.expectConsumed();
    }
}

test "a refreshed credential expiring during verification preserves rotation without export" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var previous = connectedRecord();
    previous.tokens.?.expires_at = fixture.now - 1;
    try fixture.seed(previous);
    const reply = try replyBytes(.{ .id_token = vectors.login, .expires_in = 1 });
    defer allocator.free(reply);
    const steps = [_]Step{
        .{ .kind = .token, .body = reply, .persisted = .refresh_pending },
        .{ .kind = .discovery, .body = discovery },
        .{ .kind = .keys, .body = vectors.jwks, .advance_seconds = 2 },
    };
    var script = fixture.script(&steps);
    var manager = fixture.manager(&script);
    try std.testing.expectError(error.CredentialExpired, manager.credential(label));
    var parsed = try fixture.store.load(label);
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.refresh_pending);
    try std.testing.expectEqualStrings("new-refresh", parsed.value.tokens.?.refresh_token);
    try std.testing.expect(parsed.value.tokens.?.expires_at <= fixture.now);
    try script.expectConsumed();
}
