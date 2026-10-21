const std = @import("std");
const siwc = @import("siwc");
const args = @import("args.zig");

pub const api_base_url = "https://api.openai.com/v1";
pub const environment_entries_max = 4096;
pub const environment_bytes_max = 4 * 1024 * 1024;

pub fn validateDestination(parent: *const std.process.Environ.Map) !void {
    for ([_][]const u8{ "OPENAI_BASE_URL", "OPENAI_API_BASE" }) |key| {
        if (parent.get(key)) |destination| {
            if (!std.mem.eql(u8, destination, api_base_url) and
                !std.mem.eql(u8, destination, api_base_url ++ "/"))
                return error.UntrustedApiDestination;
        }
    }
}

pub fn makeEnvironment(
    allocator: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
    access_token: []const u8,
) !std.process.Environ.Map {
    try validateDestination(parent);
    try validateToken(access_token);
    try validateEnvironment(parent);
    var environment = try parent.clone(allocator);
    errdefer environment.deinit();
    for ([_][]const u8{
        "OPENAI_ORGANIZATION", "OPENAI_ORG_ID", "OPENAI_PROJECT", "OPENAI_PROJECT_ID",
    }) |key| _ = environment.swapRemove(key);
    try environment.put("OPENAI_API_KEY", access_token);
    try environment.put("OPENAI_BASE_URL", api_base_url);
    try validateEnvironment(&environment);
    return environment;
}

pub fn execute(
    io: std.Io,
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
) !noreturn {
    if (argv.len == 0 or argv[0].len == 0) return error.ChildCommandRequired;
    try args.validateArguments(argv);
    try validateDestination(environment);
    try validateEnvironment(environment);
    return std.process.replace(io, .{
        .argv = argv,
        .environ_map = environment,
        .expand_arg0 = .no_expand,
    });
}

fn validateToken(token: []const u8) !void {
    if (token.len == 0 or token.len > siwc.store.token_bytes_max) return error.InvalidAccessToken;
    for (token) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return error.InvalidAccessToken;
    }
}

fn validateEnvironment(environment: *const std.process.Environ.Map) !void {
    if (environment.count() > environment_entries_max) return error.EnvironmentTooLarge;
    var bytes: usize = 0;
    for (environment.keys(), environment.values()) |key, value| {
        if (key.len >= environment_bytes_max - bytes) return error.EnvironmentTooLarge;
        bytes += key.len + 1;
        if (value.len >= environment_bytes_max - bytes) return error.EnvironmentTooLarge;
        bytes += value.len + 1;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvironment;
    }
}

test "credential environment overrides credentials preserves parent and strips billing selectors" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", "/test/home");
    try parent.put("SOME_APPLICATION_SETTING", "preserved");
    try parent.put("OPENAI_API_KEY", "old-test-key");
    try parent.put("OPENAI_API_BASE", api_base_url ++ "/");
    const selectors = [_][]const u8{
        "OPENAI_ORGANIZATION", "OPENAI_ORG_ID", "OPENAI_PROJECT", "OPENAI_PROJECT_ID",
    };
    for (selectors) |key| try parent.put(key, "old-selector");
    var environment = try makeEnvironment(std.testing.allocator, &parent, "test-access-token");
    defer environment.deinit();
    try std.testing.expectEqualStrings("test-access-token", environment.get("OPENAI_API_KEY").?);
    try std.testing.expectEqualStrings(api_base_url, environment.get("OPENAI_BASE_URL").?);
    try std.testing.expectEqualStrings("/usr/bin:/bin", environment.get("PATH").?);
    try std.testing.expectEqualStrings("/test/home", environment.get("HOME").?);
    try std.testing.expectEqualStrings("preserved", environment.get("SOME_APPLICATION_SETTING").?);
    for (selectors) |key| try std.testing.expect(!environment.contains(key));
    try std.testing.expectEqualStrings("old-test-key", parent.get("OPENAI_API_KEY").?);
    for (selectors) |key| try std.testing.expect(parent.contains(key));
}

test "credential destination accepts only the exact official API origin and path" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try validateDestination(&environment);
    for ([_][]const u8{ "OPENAI_BASE_URL", "OPENAI_API_BASE" }) |key| {
        try environment.put(key, api_base_url);
        try validateDestination(&environment);
        try environment.put(key, api_base_url ++ "/");
        try validateDestination(&environment);
        for ([_][]const u8{
            "",
            "http://api.openai.com/v1",
            "https://api.openai.com.evil.invalid/v1",
            "https://api.openai.com/v1?key=x",
            "https://other.invalid/v1",
            "https://user@api.openai.com/v1",
            "https://api.openai.com/v1//",
        }) |destination| {
            try environment.put(key, destination);
            try std.testing.expectError(
                error.UntrustedApiDestination,
                makeEnvironment(std.testing.allocator, &environment, "test-token"),
            );
        }
        _ = environment.swapRemove(key);
    }
}

test "credential environment rejects malformed access tokens and preserves allocation ownership" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    for ([_][]const u8{ "", "line\nbreak", "contains space", "null\x00byte", "\x7f" }) |token| {
        try std.testing.expectError(
            error.InvalidAccessToken,
            makeEnvironment(std.testing.allocator, &environment, token),
        );
    }
    var token: [siwc.store.token_bytes_max + 1]u8 = undefined;
    @memset(&token, 'a');
    try validateToken(token[0 .. siwc.store.token_bytes_max - 1]);
    try validateToken(token[0..siwc.store.token_bytes_max]);
    try std.testing.expectError(error.InvalidAccessToken, validateToken(&token));
    try environment.put("INVALID", "contains\x00null");
    try std.testing.expectError(
        error.InvalidEnvironment,
        makeEnvironment(std.testing.allocator, &environment, "test-token"),
    );
}

test "process replacement refuses missing executables before process creation" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectError(
        error.ChildCommandRequired,
        execute(std.testing.io, &.{}, &environment),
    );
    try std.testing.expectError(
        error.ChildCommandRequired,
        execute(std.testing.io, &.{""}, &environment),
    );
}
