const std = @import("std");

pub const discovery_url = "https://auth.openai.com/.well-known/openid-configuration";
pub const token_url = "https://auth.openai.com/api/accounts/oauth/token";
pub const models_url = "https://api.openai.com/v1/models";
pub const response_bytes_max = 1024 * 1024;
pub const request_bytes_max = 128 * 1024;
pub const request_timeout_ms = 30_000;

pub const Request = union(enum) {
    discovery,
    keys: []const u8,
    token: []const u8,
    revoke: struct { url: []const u8, form: []const u8 },
    models: []const u8,

    pub fn url(self: Request) []const u8 {
        return switch (self) {
            .discovery => discovery_url,
            .keys => |value| value,
            .token => token_url,
            .revoke => |value| value.url,
            .models => models_url,
        };
    }

    fn body(self: Request) ?[]const u8 {
        return switch (self) {
            .token => |value| value,
            .revoke => |value| value.form,
            else => null,
        };
    }

    pub fn validate(self: Request) !void {
        switch (self) {
            .keys => |value| try validateAuthUrl(value),
            .revoke => |value| try validateAuthUrl(value.url),
            .models => |value| {
                if (value.len == 0 or value.len > 32 * 1024) return error.InvalidAccessToken;
                for (value) |byte| if (byte <= 0x20 or byte >= 0x7f)
                    return error.InvalidAccessToken;
            },
            else => {},
        }
        if (self.body()) |value| {
            if (value.len == 0 or value.len > request_bytes_max) return error.RequestTooLarge;
        }
    }
};

pub fn validateAuthUrl(url: []const u8) !void {
    if (url.len > 2048 or !std.mem.startsWith(u8, url, "https://auth.openai.com/") or
        std.mem.indexOfAny(u8, url, "\\#\r\n\t ") != null) return error.InvalidAuthEndpoint;
}

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response) void {
        std.crypto.secureZero(u8, self.body);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Transport = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, Request) anyerror!Response,

    pub fn request(
        self: Transport,
        allocator: std.mem.Allocator,
        io: std.Io,
        value: Request,
    ) !Response {
        try value.validate();
        return self.request_fn(self.context, allocator, io, value);
    }
};

pub const Http = struct {
    pub fn transport(self: *Http) Transport {
        return .{ .context = self, .request_fn = request };
    }

    fn request(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        value: Request,
    ) !Response {
        var job = Job{ .allocator = allocator, .io = io, .request = value };
        defer if (job.response) |*response| response.deinit();
        var results: [2]Outcome = undefined;
        var select = std.Io.Select(Outcome).init(io, &results);
        defer select.cancelDiscard();
        try select.concurrent(.work, Job.run, .{&job});
        try select.concurrent(.timeout, waitTimeout, .{io});
        switch (try select.await()) {
            .work => |result| try result,
            .timeout => |result| {
                try result;
                return error.RequestTimedOut;
            },
        }
        select.cancelDiscard();
        const response = job.response orelse return error.MissingResponse;
        job.response = null;
        return response;
    }
};

const Outcome = union(enum) { work: anyerror!void, timeout: std.Io.Cancelable!void };

fn waitTimeout(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(request_timeout_ms), .awake);
}

const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
    response: ?Response = null,

    fn run(self: *Job) !void {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        client.read_buffer_size = 32 * 1024;
        const bearer = switch (self.request) {
            .models => |token| try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token}),
            else => null,
        };
        defer if (bearer) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        };
        var headers: [1]std.http.Header = undefined;
        if (bearer) |value| headers[0] = .{ .name = "Authorization", .value = value };
        const payload = self.request.body();
        var request = try client.request(
            if (payload != null) .POST else .GET,
            try std.Uri.parse(self.request.url()),
            .{
                .redirect_behavior = .unhandled,
                .keep_alive = false,
                .headers = .{
                    .content_type = if (payload != null)
                        .{ .override = "application/x-www-form-urlencoded" }
                    else
                        .omit,
                    .accept_encoding = .omit,
                },
                .privileged_headers = if (bearer != null) &headers else &.{},
            },
        );
        defer request.deinit();
        if (payload) |value| {
            request.transfer_encoding = .{ .content_length = value.len };
            try request.sendBodyComplete(@constCast(value));
        } else try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        const status: u16 = @backingInt(response.head.status);
        if (status >= 300 and status < 400) return error.RedirectNotAllowed;
        var transfer: [4096]u8 = undefined;
        const body = try response.reader(&transfer).allocRemaining(
            self.allocator,
            .limited(response_bytes_max),
        );
        self.response = .{ .allocator = self.allocator, .status = status, .body = body };
    }
};

pub const Discovery = struct {
    parsed: std.json.Parsed(Value),

    const Value = struct {
        issuer: []const u8,
        jwks_uri: []const u8,
        revocation_endpoint: []const u8,
    };

    pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Discovery {
        if (body.len > response_bytes_max) return error.ResponseTooLarge;
        const parsed = try std.json.parseFromSlice(Value, allocator, body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        errdefer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.issuer, "https://auth.openai.com"))
            return error.InvalidIssuer;
        try validateAuthUrl(parsed.value.jwks_uri);
        try validateAuthUrl(parsed.value.revocation_endpoint);
        return .{ .parsed = parsed };
    }

    pub fn deinit(self: *Discovery) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

test "discovery cannot redirect credential or signing-key authority" {
    const allocator = std.testing.allocator;
    var valid = try Discovery.parse(allocator,
        \\{"issuer":"https://auth.openai.com","jwks_uri":"https://auth.openai.com/keys","revocation_endpoint":"https://auth.openai.com/revoke"}
    );
    defer valid.deinit();
    try std.testing.expectError(error.InvalidAuthEndpoint, Discovery.parse(allocator,
        \\{"issuer":"https://auth.openai.com","jwks_uri":"https://evil.example/keys","revocation_endpoint":"https://auth.openai.com/revoke"}
    ));
    for ([_][]const u8{
        "http://auth.openai.com/keys",
        "https://auth.openai.com.evil/keys",
        "https://auth.openai.com@evil/keys",
        "https://auth.openai.com/keys#fragment",
    }) |url| try std.testing.expectError(error.InvalidAuthEndpoint, validateAuthUrl(url));
}

test "transport validates bearer bytes before invoking an implementation" {
    try (Request{ .models = "synthetic-access" }).validate();
    try std.testing.expectError(error.InvalidAccessToken, (Request{ .models = "" }).validate());
    try std.testing.expectError(
        error.InvalidAccessToken,
        (Request{ .models = "token\r\nInjected: yes" }).validate(),
    );
}
