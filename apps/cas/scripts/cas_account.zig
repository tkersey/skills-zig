const app_meta = @import("app_meta");
const budget_governor = @import("budget_governor.zig");
const cas = @import("cas_proxy_client.zig");
const cas_websocket = @import("cas_websocket_transport.zig");
const core_cli = @import("core_cli");
const core_json = @import("core_json");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_account",
    .help_text = UsageText,
};

const UsageText =
    \\cas_account
    \\
    \\Read Codex app-server account status through safe account APIs.
    \\
    \\Usage:
    \\  cas_account status --cwd DIR [options]
    \\
    \\Options:
    \\  --cwd DIR                         Repository cwd for Codex app-server state.
    \\  --json                            Emit stable JSON output.
    \\  --usage                           Include account/usage/read summary.
    \\  --show-email                      Include account email. Redacted by default.
    \\  --hooks MODE                      Hook policy: inherit|off|require-observed (default: inherit).
    \\  --codex-path PATH                 Codex executable (default: codex).
    \\  --read-only                       Decline exec + file approvals.
    \\  --help                            Show help.
    \\  --version                         Show version.
    \\  version                           Show version.
    \\
    \\Examples:
    \\  cas account status --cwd /path/to/repo --json
    \\  cas account status --cwd /path/to/repo --usage --show-email
;

const Command = enum {
    status,

    fn text(self: Command) []const u8 {
        return switch (self) {
            .status => "status",
        };
    }
};

const ParsedArgs = struct {
    command: ?Command = null,
    cwd: ?[]const u8 = null,
    json: bool = false,
    usage: bool = false,
    show_email: bool = false,
    read_only: bool = false,
    hook_policy: cas.hooks.HookPolicy = .inherit,
    codex_path: []const u8 = "codex",
    show_help: bool = false,
    show_version: bool = false,
};

const AccountClient = struct {
    client: cas.Client,
    managed_server: ?cas_websocket.ManagedServer = null,

    fn deinit(self: *AccountClient, allocator: std.mem.Allocator) void {
        self.client.close();
        self.client.deinit();
        if (self.managed_server) |*server| {
            server.kill();
            server.deinit(allocator);
        }
    }
};

const AccountOut = struct {
    type: ?[]const u8 = null,
    planType: ?[]const u8 = null,
    email: ?[]const u8 = null,
    emailRedacted: bool = false,
};

const AuthOut = struct {
    requiresOpenaiAuth: ?bool = null,
    authMethod: ?[]const u8 = null,
};

const RateLimitsOut = struct {
    governor: budget_governor.GovernorOut,
    rateLimitReachedType: ?[]const u8 = null,
    hasCredits: bool = false,
};

const UsageSummaryOut = struct {
    lifetimeTokens: ?i64 = null,
    peakDailyTokens: ?i64 = null,
    longestRunningTurnSec: ?i64 = null,
    currentStreakDays: ?i64 = null,
    longestStreakDays: ?i64 = null,
};

const UsageOut = struct {
    summary: UsageSummaryOut,
    dailyBucketCount: usize = 0,
};

const StatusOut = struct {
    ok: bool = true,
    command: []const u8 = "status",
    transport: []const u8,
    account: AccountOut,
    auth: AuthOut,
    rateLimits: RateLimitsOut,
    usage: ?UsageOut = null,
    failureCode: ?[]const u8 = null,
    failureHint: ?[]const u8 = null,
};

const FailureOut = struct {
    ok: bool = false,
    command: []const u8 = "status",
    failureCode: []const u8,
    failureHint: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const opts = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    if (opts.show_version) return printVersion();
    if (opts.show_help) return printHelp();
    if (opts.command == null) core_cli.exitUsageFailure(
        HelpSurface,
        Version,
        "MissingCommand",
        "status",
    );

    const cwd = opts.cwd orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingValue", "--cwd");
    };

    var account_client = startAccountClient(allocator, opts, cwd, init.io) catch |err| {
        try fail(allocator, opts, "transportFailure", @errorName(err), 1);
    };
    defer account_client.deinit(allocator);

    runStatus(allocator, opts, &account_client.client) catch |err| {
        const code = classifyFailure(err);
        try fail(allocator, opts, code, failureHint(code), 1);
    };
}

fn runStatus(allocator: std.mem.Allocator, opts: ParsedArgs, client: *cas.Client) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const account_json = try client.requestJson("account/read", "{\"refreshToken\":false}");
    defer allocator.free(account_json);
    const rate_limits_json = try client.requestJson("account/rateLimits/read", null);
    defer allocator.free(rate_limits_json);

    const account_auth = try parseAccountRead(arena, account_json, opts.show_email);
    const auth =
        if (account_auth.auth.requiresOpenaiAuth == true or account_auth.account.type == null)
            readAuthFallback(arena, allocator, client, account_auth.auth) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => account_auth.auth,
            }
        else
            account_auth.auth;

    const rate_limits = try parseRateLimits(arena, rate_limits_json);
    const usage = if (opts.usage) blk: {
        const usage_json = try client.requestJson("account/usage/read", null);
        defer allocator.free(usage_json);
        break :blk try parseUsage(arena, usage_json);
    } else null;

    const payload = StatusOut{
        .transport = transportText(client.transport_kind),
        .account = account_auth.account,
        .auth = auth,
        .rateLimits = rate_limits,
        .usage = usage,
    };

    try writeStatus(opts.json, payload);
}

fn writeStatus(json: bool, payload: StatusOut) !void {
    if (json) {
        var stdout_writer = std.Io.File.stdout().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        const stdout = &stdout_writer.interface;
        try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        var stdout_writer = std.Io.File.stdout().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        const stdout = &stdout_writer.interface;
        try stdout.print("cas account status\n", .{});
        try stdout.print("transport: {s}\n", .{payload.transport});
        try stdout.print("account: {s}", .{payload.account.type orelse "none"});
        if (payload.account.planType) |plan| try stdout.print(" ({s})", .{plan});
        if (payload.account.email) |email| try stdout.print(" {s}", .{email});
        if (payload.account.emailRedacted) try stdout.writeAll(" [email redacted]");
        try stdout.writeAll("\n");
        try stdout.print("auth: requiresOpenaiAuth={any}", .{payload.auth.requiresOpenaiAuth});
        if (payload.auth.authMethod) |method| try stdout.print(" method={s}", .{method});
        try stdout.writeAll("\n");
        try stdout.print("rate limits: tier={s} used={any} resetMins={any} " ++
            "reached={s} credits={any}\n", .{
            payload.rateLimits.governor.effectiveTier,
            payload.rateLimits.governor.usedPercent,
            payload.rateLimits.governor.remainingMins,
            payload.rateLimits.rateLimitReachedType orelse "none",
            payload.rateLimits.hasCredits,
        });
        if (payload.usage) |usage_out| {
            try stdout.print("usage: lifetimeTokens={any} dailyBuckets={d}\n", .{
                usage_out.summary.lifetimeTokens,
                usage_out.dailyBucketCount,
            });
        }
    }
}

const AccountAuth = struct {
    account: AccountOut,
    auth: AuthOut,
};

fn parseAccountRead(allocator: std.mem.Allocator, json: []const u8, show_email: bool) !AccountAuth {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.ExpectedJsonObject,
    };

    var account = AccountOut{};
    if (root.get("account")) |account_val| {
        switch (account_val) {
            .object => |account_obj| {
                account.type = core_json.stringField(account_obj, "type");
                account.planType = core_json.stringField(account_obj, "planType");
                if (core_json.stringField(account_obj, "email")) |email| {
                    if (show_email) {
                        account.email = email;
                    } else {
                        account.emailRedacted = true;
                    }
                }
            },
            .null => {},
            else => return error.InvalidAccount,
        }
    }

    const auth = AuthOut{
        .requiresOpenaiAuth = boolField(root, "requiresOpenaiAuth"),
    };
    return .{ .account = account, .auth = auth };
}

fn readAuthFallback(
    parse_allocator: std.mem.Allocator,
    request_allocator: std.mem.Allocator,
    client: *cas.Client,
    existing: AuthOut,
) !AuthOut {
    const auth_json = try client.requestJson(
        "getAuthStatus",
        "{\"includeToken\":false,\"refreshToken\":false}",
    );
    defer request_allocator.free(auth_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, parse_allocator, auth_json, .{});
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return existing,
    };
    const auth_method = if (core_json.stringField(root, "authMethod")) |method|
        try parse_allocator.dupe(u8, method)
    else
        null;
    return .{
        .requiresOpenaiAuth = boolField(
            root,
            "requiresOpenaiAuth",
        ) orelse existing.requiresOpenaiAuth,
        .authMethod = auth_method,
    };
}

fn parseRateLimits(allocator: std.mem.Allocator, json: []const u8) !RateLimitsOut {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.ExpectedJsonObject,
    };
    const governor = budget_governor.computeBudgetGovernor(root, null);
    const bucket = selectedRateLimitBucket(root, governor);
    return .{
        .governor = governor,
        .rateLimitReachedType = if (bucket) |selected| core_json.stringField(
            selected,
            "rateLimitReachedType",
        ) else null,
        .hasCredits = if (bucket) |selected| bucketHasCredits(selected) else false,
    };
}

fn parseUsage(allocator: std.mem.Allocator, json: []const u8) !UsageOut {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return .{ .summary = .{} },
    };
    const summary_obj = core_json.objectField(root, "summary") orelse root;
    return .{
        .summary = .{
            .lifetimeTokens = intFieldAny(summary_obj, &.{ "lifetimeTokens", "lifetime_tokens" }),
            .peakDailyTokens = intFieldAny(
                summary_obj,
                &.{ "peakDailyTokens", "peak_daily_tokens" },
            ),
            .longestRunningTurnSec = intFieldAny(
                summary_obj,
                &.{ "longestRunningTurnSec", "longest_running_turn_sec" },
            ),
            .currentStreakDays = intFieldAny(
                summary_obj,
                &.{ "currentStreakDays", "current_streak_days" },
            ),
            .longestStreakDays = intFieldAny(
                summary_obj,
                &.{ "longestStreakDays", "longest_streak_days" },
            ),
        },
        .dailyBucketCount = try usageBucketCount(allocator, parsed.value, json.len),
    };
}

fn startAccountClient(
    allocator: std.mem.Allocator,
    opts: ParsedArgs,
    cwd: []const u8,
    io: std.Io,
) !AccountClient {
    const resolved_codex_path = cas.resolveExecutableAlloc(
        allocator,
        opts.codex_path,
    ) catch opts.codex_path;
    defer if (resolved_codex_path.ptr != opts.codex_path.ptr) allocator.free(resolved_codex_path);

    var managed_server: ?cas_websocket.ManagedServer = cas_websocket.startManagedLoopbackServer(
        allocator,
        cwd,
        resolved_codex_path,
        opts.hook_policy,
        io,
    ) catch null;
    const client = if (managed_server) |server|
        cas.Client.start(
            allocator,
            clientOptions(opts, cwd, io, resolved_codex_path, server.listen_url),
        ) catch blk: {
            var owned_server = server;
            defer owned_server.deinit(allocator);
            owned_server.kill();
            managed_server = null;
            break :blk try cas.Client.start(
                allocator,
                clientOptions(opts, cwd, io, resolved_codex_path, null),
            );
        }
    else
        try cas.Client.start(allocator, clientOptions(opts, cwd, io, resolved_codex_path, null));

    return .{ .client = client, .managed_server = managed_server };
}

fn clientOptions(
    opts: ParsedArgs,
    cwd: []const u8,
    io: std.Io,
    codex_path: []const u8,
    websocket_url: ?[]const u8,
) cas.ClientOptions {
    return .{
        .cwd = cwd,
        .io = io,
        .codex_path = codex_path,
        .client_name = "cas-account",
        .client_title = "CAS Account",
        .client_version = Version,
        .read_only = true,
        .hook_policy = opts.hook_policy,
        .websocket_url = websocket_url,
    };
}

fn parseArgs(argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (core_cli.isHelpArg(arg)) {
            out.show_help = true;
            return out;
        }
        if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
            out.show_version = true;
            return out;
        }
        if (out.command == null and std.mem.eql(u8, arg, "status")) {
            out.command = .status;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--usage")) {
            out.usage = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--show-email")) {
            out.show_email = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--read-only")) {
            out.read_only = true;
            continue;
        }

        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const value = argv[i];

        if (std.mem.eql(u8, arg, "--cwd")) {
            out.cwd = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex-path")) {
            out.codex_path = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--hooks")) {
            out.hook_policy = cas.hooks.HookPolicy.parse(value) orelse
                return error.InvalidHooksPolicy;
            continue;
        }
        return error.UnknownArg;
    }
    return out;
}

fn boolField(obj: core_json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn intFieldAny(obj: core_json.ObjectMap, keys: []const []const u8) ?i64 {
    for (keys) |key| {
        if (core_json.intField(obj, key)) |value| return value;
    }
    return null;
}

fn selectedRateLimitBucket(
    root: core_json.ObjectMap,
    governor: budget_governor.GovernorOut,
) ?core_json.ObjectMap {
    if (std.mem.eql(u8, governor.bucketSource, "single_bucket")) {
        return core_json.objectField(root, "rateLimits");
    }
    if (std.mem.eql(u8, governor.bucketSource, "by_limit_id")) {
        const by_id = core_json.objectField(root, "rateLimitsByLimitId") orelse return null;
        if (governor.bucketKey) |key| return core_json.objectField(by_id, key);
    }
    return null;
}

fn bucketHasCredits(bucket: core_json.ObjectMap) bool {
    if (bucket.get("rateLimitResetCredits")) |credits| {
        return creditValueIsPresent(credits);
    }
    if (bucket.get("credits")) |credits| {
        return creditValueIsPresent(credits);
    }
    return false;
}

fn creditValueIsPresent(value: std.json.Value) bool {
    return switch (value) {
        .integer => |n| n > 0,
        .float => |n| n > 0,
        .bool => |b| b,
        .object => |obj| creditObjectHasCount(obj),
        .null => false,
        else => true,
    };
}

fn creditObjectHasCount(obj: core_json.ObjectMap) bool {
    if (core_json.intField(obj, "availableCount")) |n| return n > 0;
    if (core_json.intField(obj, "count")) |n| return n > 0;
    if (core_json.intField(obj, "remaining")) |n| return n > 0;
    if (core_json.intField(obj, "total")) |n| return n > 0;
    return true;
}

// Parsed JSON is a tree with fewer values than source bytes. The pending DFS stack
// therefore has an input-derived bound, including wide arrays and deeply nested objects.
const ValueSearch = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(std.json.Value) = .empty,
    maximum_nodes: usize,
    visited: usize = 0,

    fn deinit(self: *ValueSearch) void {
        self.pending.deinit(self.allocator);
    }

    fn find(
        self: *ValueSearch,
        root: std.json.Value,
        key: []const u8,
        comptime T: type,
        comptime match: fn (std.json.Value) ?T,
    ) !?T {
        self.pending.clearRetainingCapacity();
        self.visited = 0;
        try self.pending.append(self.allocator, root);
        while (self.pending.pop()) |value| {
            if (self.visited >= self.maximum_nodes) return error.InvalidAccount;
            self.visited += 1;
            const children = switch (value) {
                .object => |obj| blk: {
                    if (obj.get(key)) |candidate| {
                        if (match(candidate)) |found| return found;
                    }
                    break :blk obj.values();
                },
                .array => |arr| arr.items,
                else => continue,
            };
            if (children.len > self.maximum_nodes - self.pending.items.len) {
                return error.InvalidAccount;
            }
            // Push in reverse so object insertion order and array order match the
            // former recursive pre-order search, including wrong-typed direct keys.
            var index = children.len;
            while (index > 0) {
                index -= 1;
                try self.pending.append(self.allocator, children[index]);
            }
        }
        return null;
    }
};

fn usageBucketCount(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    source_bytes: usize,
) !usize {
    var search = ValueSearch{ .allocator = allocator, .maximum_nodes = source_bytes };
    defer search.deinit();
    for ([_][]const u8{ "dailyUsageBuckets", "dailyBuckets", "last_buckets", "buckets" }) |key| {
        if (try search.find(root, key, usize, arrayLength)) |length| return length;
    }
    return nonNegativeUsize(try search.find(
        root,
        "bucket_count",
        i64,
        core_json.intFromValue,
    )) orelse 0;
}

fn arrayLength(value: std.json.Value) ?usize {
    return switch (value) {
        .array => |arr| arr.items.len,
        else => null,
    };
}

fn nonNegativeUsize(value: ?i64) ?usize {
    const n = value orelse return null;
    if (n < 0) return null;
    return @intCast(n);
}

fn transportText(kind: cas.TransportKind) []const u8 {
    return kind.text();
}

fn classifyFailure(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestFailed => "requestFailed",
        error.ExpectedJsonObject, error.InvalidAccount => "invalidResponse",
        error.OutOfMemory => "outOfMemory",
        else => "accountStatusFailed",
    };
}

fn failureHint(code: []const u8) []const u8 {
    if (std.mem.eql(
        u8,
        code,
        "requestFailed",
    )) return "account status request failed; raw app-server errors are intentio" ++
        "nally redacted";
    if (std.mem.eql(
        u8,
        code,
        "invalidResponse",
    )) return "account status response did not match the expected safe status shape";
    return "account status failed";
}

fn fail(
    allocator: std.mem.Allocator,
    opts: ParsedArgs,
    code: []const u8,
    hint: ?[]const u8,
    exit_code: u8,
) !noreturn {
    if (opts.json) {
        const payload = FailureOut{
            .failureCode = code,
            .failureHint = hint,
        };
        var stdout_writer = std.Io.File.stdout().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        const stdout = &stdout_writer.interface;
        try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        var stderr_writer = std.Io.File.stderr().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        const stderr = &stderr_writer.interface;
        if (hint) |h| try stderr.print(
            "cas_account status: {s}: {s}\n",
            .{ code, h },
        ) else try stderr.print("cas_account status: {s}\n", .{code});
    }
    _ = allocator;
    std.process.exit(exit_code);
}

fn printVersion() !void {
    var stdout_writer = std.Io.File.stdout().writer(
        std.Io.Threaded.global_single_threaded.io(),
        &.{},
    );
    try core_cli.printVersion(&stdout_writer.interface, Version);
}

fn printHelp() !void {
    var stdout_writer = std.Io.File.stdout().writer(
        std.Io.Threaded.global_single_threaded.io(),
        &.{},
    );
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
}

test "parseArgs accepts status privacy flags" {
    const argv = [_][]const u8{
        "cas_account",
        "status",
        "--cwd",
        "/tmp/repo",
        "--json",
        "--usage",
        "--show-email",
        "--hooks",
        "off",
        "--codex-path",
        "codex-dev",
        "--read-only",
    };
    const parsed = try parseArgs(&argv);
    try std.testing.expectEqual(Command.status, parsed.command.?);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.usage);
    try std.testing.expect(parsed.show_email);
    try std.testing.expectEqualStrings("codex-dev", parsed.codex_path);
}

test "account output preserves unix socket transport identity" {
    try std.testing.expectEqualStrings("stdio", transportText(.stdio));
    try std.testing.expectEqualStrings("websocket", transportText(.websocket));
    try std.testing.expectEqualStrings("unix_socket", transportText(.unix_socket));
}

test "parseAccountRead redacts email by default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\{"account":{"type":"chatgpt","email":"user@example.com","planType":"plus"},"requiresOpenaiAuth":false}
    ;
    const parsed = try parseAccountRead(arena_state.allocator(), raw, false);
    try std.testing.expectEqualStrings("chatgpt", parsed.account.type.?);
    try std.testing.expectEqualStrings("plus", parsed.account.planType.?);
    try std.testing.expect(parsed.account.email == null);
    try std.testing.expect(parsed.account.emailRedacted);
    try std.testing.expectEqual(false, parsed.auth.requiresOpenaiAuth.?);
}

test "parseAccountRead can show email explicitly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":false}
    ;
    const parsed = try parseAccountRead(arena_state.allocator(), raw, true);
    try std.testing.expectEqualStrings("user@example.com", parsed.account.email.?);
    try std.testing.expect(!parsed.account.emailRedacted);
}

test "parseRateLimits reuses budget governor and classifies reached state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\{"rateLimits":{"limitId":"codex","limitName":"Codex","planType":"plus","rateLimitReachedType":"none","rateLimitResetCredits":{"availableCount":1},"primary":{"usedPercent":20,"resetsAt":2000,"windowDurationMins":60}}}
    ;
    const parsed = try parseRateLimits(arena_state.allocator(), raw);
    try std.testing.expect(parsed.governor.ok);
    try std.testing.expectEqualStrings("none", parsed.rateLimitReachedType.?);
    try std.testing.expect(parsed.hasCredits);
}

test "parseRateLimits scopes reached state to selected codex bucket" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\{"rateLimitsByLimitId":{"other":{"limitId":"other","rateLimitReachedType":"hard","primary":{"usedPercent":99,"resetsAt":2000,"windowDurationMins":60}},"codex":{"limitId":"codex","limitName":"Codex","rateLimitReachedType":"none","rateLimitResetCredits":{"availableCount":2},"primary":{"usedPercent":20,"resetsAt":2000,"windowDurationMins":60}}}}
    ;
    const parsed = try parseRateLimits(arena_state.allocator(), raw);
    try std.testing.expectEqualStrings("codex", parsed.governor.bucketKey.?);
    try std.testing.expectEqualStrings("none", parsed.rateLimitReachedType.?);
    try std.testing.expect(parsed.hasCredits);
}

test "parseUsage summarizes known fields without raw payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\{"summary":{"lifetimeTokens":100,"peakDailyTokens":50,"longestRunningTurnSec":30,"currentStreakDays":2,"longestStreakDays":5},"dailyUsageBuckets":[{"startDate":"2026-06-17","tokens":10}]}
    ;
    const parsed = try parseUsage(arena_state.allocator(), raw);
    try std.testing.expectEqual(@as(i64, 100), parsed.summary.lifetimeTokens.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.dailyBucketCount);
}

test "parseUsage accepts snake_case summary fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\{"summary":{"lifetime_tokens":100,"peak_daily_tokens":50,"longest_running_turn_sec":30,"current_streak_days":2,"longest_streak_days":5},"bucket_count":3}
    ;
    const parsed = try parseUsage(arena_state.allocator(), raw);
    try std.testing.expectEqual(@as(i64, 100), parsed.summary.lifetimeTokens.?);
    try std.testing.expectEqual(@as(i64, 50), parsed.summary.peakDailyTokens.?);
    try std.testing.expectEqual(@as(i64, 30), parsed.summary.longestRunningTurnSec.?);
    try std.testing.expectEqual(@as(usize, 3), parsed.dailyBucketCount);
}

test "usage search preserves key priority and depth-first order" {
    const allocator = std.testing.allocator;
    const json =
        \\{"dailyBuckets":[0,1],"first":{"dailyUsageBuckets":null,
        \\"nested":{"dailyUsageBuckets":[0,1,2]}},"second":{"dailyUsageBuckets":[0]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(
        @as(usize, 3),
        try usageBucketCount(allocator, parsed.value, json.len),
    );
}

test "usage search bounds explicit frames and propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkUsageSearch, .{});
}

fn checkUsageSearch(allocator: std.mem.Allocator) !void {
    const json = "{\"items\":[{\"bucket_count\":4},{\"bucket_count\":9}]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(
        @as(usize, 4),
        try usageBucketCount(allocator, parsed.value, json.len),
    );
}

test "usage search rejects exhausted input-derived node budget" {
    const json = "{\"items\":[{\"bucket_count\":4}]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidAccount,
        usageBucketCount(std.testing.allocator, parsed.value, 1),
    );
}

test "usage search handles deep and wide JSON without recursion" {
    const allocator = std.testing.allocator;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"nested\":");
    try json.appendNTimes(allocator, '[', 2048);
    try json.appendSlice(allocator, "{\"bucket_count\":7}");
    try json.appendNTimes(allocator, ']', 2048);
    try json.append(allocator, '}');
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 7), try usageBucketCount(
        allocator,
        parsed.value,
        json.items.len,
    ));
    json.clearRetainingCapacity();
    try json.appendSlice(allocator, "{\"nested\":[");
    for (0..512) |_| try json.appendSlice(allocator, "{},");
    try json.appendSlice(allocator, "{\"bucket_count\":9}]}");
    var wide = try std.json.parseFromSlice(std.json.Value, allocator, json.items, .{});
    defer wide.deinit();
    try std.testing.expectEqual(@as(usize, 9), try usageBucketCount(
        allocator,
        wide.value,
        json.items.len,
    ));
}
