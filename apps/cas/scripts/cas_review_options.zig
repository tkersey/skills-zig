//! Caller-owned thread/start configuration for a durable CAS review attempt.
//! CAS owns the repository and review prompt; the installed protocol owns the
//! remaining parameter names and their value semantics.

const std = @import("std");
const canonical = @import("definition_core").canonical_json;
const contract = @import("cas_app_server_contract");

pub const ThreadStartOptions = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(std.json.Value),
    canonical_json: []const u8,
    digest: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, raw_json: []const u8) !ThreadStartOptions {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        });
        errdefer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.ThreadStartOptionsExpectedObject,
        };
        if (object.contains("cwd")) return error.ThreadStartCwdOwnedByCas;
        if (object.contains("developerInstructions")) {
            return error.ThreadStartDeveloperInstructionsOwnedByCas;
        }
        if (object.get("ephemeral")) |value| {
            if (value == .bool and value.bool) return error.EphemeralReviewThreadUnsupported;
        }
        const canonical_json = try canonical.canonicalJsonAlloc(allocator, parsed.value);
        errdefer allocator.free(canonical_json);
        const digest = if (object.count() == 0)
            null
        else
            try canonical.digestBytesAlloc(allocator, canonical_json);
        return .{
            .allocator = allocator,
            .parsed = parsed,
            .canonical_json = canonical_json,
            .digest = digest,
        };
    }

    pub fn deinit(self: ThreadStartOptions) void {
        if (self.digest) |value| self.allocator.free(value);
        self.allocator.free(self.canonical_json);
        self.parsed.deinit();
    }

    pub fn buildParamsAlloc(
        self: ThreadStartOptions,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        developer_instructions: ?[]const u8,
    ) ![]u8 {
        return buildThreadStartParamsAlloc(allocator, cwd, developer_instructions, self);
    }

    /// Check names against this executable's generated experimental protocol.
    /// The server validates field types and nested config; CAS does not maintain
    /// a second configuration schema or discard future supported parameters.
    pub fn validateSchema(
        self: ThreadStartOptions,
        allocator: std.mem.Allocator,
        bundle: contract.SchemaBundle,
    ) !void {
        const bytes = try clientRequestSchemaBytes(bundle);
        var schema = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidThreadStartSchema,
        };
        defer schema.deinit();
        const definitions = try schemaObjectField(schema.value, "definitions");
        const thread_start = try schemaObjectField(.{ .object = definitions }, "ThreadStartParams");
        const properties = try schemaObjectField(.{ .object = thread_start }, "properties");
        var entries = self.parsed.value.object.iterator();
        while (entries.next()) |entry| {
            if (!properties.contains(entry.key_ptr.*)) return error.UnsupportedThreadStartOption;
        }
    }
};

pub fn buildThreadStartParamsAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    developer_instructions: ?[]const u8,
    options: ?ThreadStartOptions,
) ![]u8 {
    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    try params.put(allocator, "cwd", .{ .string = cwd });
    try params.put(allocator, "experimentalRawEvents", .{ .bool = false });
    try params.put(allocator, "developerInstructions", if (developer_instructions) |value|
        .{ .string = value }
    else
        .null);
    if (options) |caller| {
        var entries = caller.parsed.value.object.iterator();
        while (entries.next()) |entry| {
            try params.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return canonical.canonicalJsonAlloc(allocator, .{ .object = params });
}

fn clientRequestSchemaBytes(bundle: contract.SchemaBundle) ![]const u8 {
    var bytes: ?[]const u8 = null;
    for (bundle.documents) |document| {
        if (!std.mem.eql(u8, document.name, "ClientRequest.json")) continue;
        if (bytes != null) return error.InvalidThreadStartSchema;
        bytes = document.bytes;
    }
    return bytes orelse error.ThreadStartSchemaUnavailable;
}

fn schemaObjectField(value: std.json.Value, key: []const u8) !std.json.ObjectMap {
    if (value != .object) return error.InvalidThreadStartSchema;
    const child = value.object.get(key) orelse return error.ThreadStartSchemaUnavailable;
    return switch (child) {
        .object => |object| object,
        else => error.InvalidThreadStartSchema,
    };
}

test "review options preserve omission null nested configuration and exact numbers" {
    const raw =
        \\{"serviceTier":null,"environments":[],"experimentalRawEvents":true,"config":{"arbitrary_future_setting":{"enabled":true,"unset":null,"values":["x",9007199254740992.1,9223372036854775808]},"shell_environment_policy":{"set":{"ZIG_LOCAL_CACHE_DIR":"/tmp/local","ZIG_GLOBAL_CACHE_DIR":"/tmp/global"}}}}
    ;
    const options = try ThreadStartOptions.init(std.testing.allocator, raw);
    defer options.deinit();
    const request = try options.buildParamsAlloc(
        std.testing.allocator,
        "/repo",
        "review this contract",
    );
    defer std.testing.allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();
    const params = parsed.value.object;
    try std.testing.expectEqualStrings("/repo", params.get("cwd").?.string);
    try std.testing.expectEqualStrings(
        "review this contract",
        params.get("developerInstructions").?.string,
    );
    try std.testing.expect(params.get("experimentalRawEvents").?.bool);
    try std.testing.expect(params.get("serviceTier").? == .null);
    try std.testing.expectEqual(@as(usize, 0), params.get("environments").?.array.items.len);
    try std.testing.expect(!params.contains("sandbox"));
    try std.testing.expect(!params.contains("model"));
    const caller_config = try canonical.canonicalJsonAlloc(
        std.testing.allocator,
        options.parsed.value.object.get("config").?,
    );
    defer std.testing.allocator.free(caller_config);
    const request_config = try canonical.canonicalJsonAlloc(
        std.testing.allocator,
        params.get("config").?,
    );
    defer std.testing.allocator.free(request_config);
    try std.testing.expectEqualStrings(caller_config, request_config);
    const values = params.get("config").?.object.get("arbitrary_future_setting").?.object
        .get("values").?.array.items;
    try std.testing.expectEqualStrings("9007199254740992.1", values[1].number_string);
    try std.testing.expectEqualStrings("9223372036854775808", values[2].number_string);
}

test "review options own their input and retain legacy defaults for an empty object" {
    const allocator = std.testing.allocator;
    const original = try allocator.dupe(u8, "{\"model\":\"review-model\"}");
    const owned = try ThreadStartOptions.init(allocator, original);
    allocator.free(original);
    defer owned.deinit();
    const request = try owned.buildParamsAlloc(allocator, "/repo", null);
    defer allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "review-model") != null);

    const empty = try ThreadStartOptions.init(allocator, " { } ");
    defer empty.deinit();
    try std.testing.expectEqualStrings("{}", empty.canonical_json);
    try std.testing.expect(empty.digest == null);
    const defaults = try empty.buildParamsAlloc(allocator, "/repo", null);
    defer allocator.free(defaults);
    try std.testing.expectEqualStrings(
        "{\"cwd\":\"/repo\",\"developerInstructions\":null,\"experimentalRawEvents\":false}",
        defaults,
    );
    const no_options = try buildThreadStartParamsAlloc(allocator, "/repo", null, null);
    defer allocator.free(no_options);
    try std.testing.expectEqualStrings(defaults, no_options);
}

test "review options reject nonobjects duplicate fields and CAS ownership collisions" {
    for ([_][]const u8{ "null", "[]", "true", "1", "\"text\"" }) |raw| {
        try std.testing.expectError(
            error.ThreadStartOptionsExpectedObject,
            ThreadStartOptions.init(std.testing.allocator, raw),
        );
    }
    for ([_][]const u8{
        "{\"model\":\"a\",\"model\":\"b\"}",
        "{\"config\":{\"a\":1,\"a\":2}}",
    }) |raw| {
        try std.testing.expectError(
            error.DuplicateField,
            ThreadStartOptions.init(std.testing.allocator, raw),
        );
    }
    try std.testing.expectError(
        error.ThreadStartCwdOwnedByCas,
        ThreadStartOptions.init(std.testing.allocator, "{\"cwd\":null}"),
    );
    try std.testing.expectError(
        error.ThreadStartDeveloperInstructionsOwnedByCas,
        ThreadStartOptions.init(std.testing.allocator, "{\"developerInstructions\":\"other\"}"),
    );
    try std.testing.expectError(
        error.EphemeralReviewThreadUnsupported,
        ThreadStartOptions.init(std.testing.allocator, "{\"ephemeral\":true}"),
    );
    for ([_][]const u8{ "false", "null" }) |value| {
        const raw = try std.testing.allocator.print("{{\"ephemeral\":{s}}}", .{value});
        defer std.testing.allocator.free(raw);
        const options = try ThreadStartOptions.init(std.testing.allocator, raw);
        defer options.deinit();
        const request = try options.buildParamsAlloc(std.testing.allocator, "/repo", null);
        defer std.testing.allocator.free(request);
        try std.testing.expect(std.mem.indexOf(u8, request, raw[1 .. raw.len - 1]) != null);
    }
}

test "review options schema admits future fields and rejects unsupported names" {
    const documents = [_]contract.Document{.{
        .name = "ClientRequest.json",
        .bytes =
        \\{"definitions":{"ThreadStartParams":{"properties":{"futureOption":{},"config":{}}}}}
        ,
    }};
    const options = try ThreadStartOptions.init(
        std.testing.allocator,
        "{\"futureOption\":{\"nested\":[]},\"config\":{\"unknown_config_key\":42}}",
    );
    defer options.deinit();
    try options.validateSchema(std.testing.allocator, .{ .documents = &documents });
    const unknown = try ThreadStartOptions.init(std.testing.allocator, "{\"futureTypo\":true}");
    defer unknown.deinit();
    try std.testing.expectError(
        error.UnsupportedThreadStartOption,
        unknown.validateSchema(std.testing.allocator, .{ .documents = &documents }),
    );
}

test "review options schema fails explicitly when its generated definition is unavailable" {
    const options = try ThreadStartOptions.init(std.testing.allocator, "{}");
    defer options.deinit();
    try std.testing.expectError(
        error.ThreadStartSchemaUnavailable,
        options.validateSchema(std.testing.allocator, .{ .documents = &.{} }),
    );
    const missing = [_]contract.Document{.{ .name = "ClientRequest.json", .bytes = "{}" }};
    try std.testing.expectError(
        error.ThreadStartSchemaUnavailable,
        options.validateSchema(std.testing.allocator, .{ .documents = &missing }),
    );
    const invalid = [_]contract.Document{.{
        .name = "ClientRequest.json",
        .bytes = "{\"definitions\":{\"ThreadStartParams\":[]}}",
    }};
    try std.testing.expectError(
        error.InvalidThreadStartSchema,
        options.validateSchema(std.testing.allocator, .{ .documents = &invalid }),
    );
}

test "review options digest is canonical and configuration sensitive" {
    const first = try ThreadStartOptions.init(
        std.testing.allocator,
        "{\"sandbox\":\"read-only\",\"config\":{\"z\":1.00,\"a\":[1,2]}}",
    );
    defer first.deinit();
    const equivalent = try ThreadStartOptions.init(
        std.testing.allocator,
        " { \"config\": {\"a\": [1,2], \"z\": 1}, \"sandbox\": \"read-only\" } ",
    );
    defer equivalent.deinit();
    try std.testing.expectEqualStrings(first.canonical_json, equivalent.canonical_json);
    try std.testing.expectEqualStrings(first.digest.?, equivalent.digest.?);
    try std.testing.expect(canonical.isFingerprint(first.digest.?));
    const different = try ThreadStartOptions.init(
        std.testing.allocator,
        "{\"sandbox\":\"workspace-write\",\"config\":{\"z\":1,\"a\":[1,2]}}",
    );
    defer different.deinit();
    try std.testing.expect(!std.mem.eql(u8, first.digest.?, different.digest.?));
}

fn exerciseReviewOptionsAllocation(allocator: std.mem.Allocator) !void {
    const options = try ThreadStartOptions.init(
        allocator,
        "{\"config\":{\"nested\":[{\"precise\":9007199254740992.1}]}}",
    );
    defer options.deinit();
    const request = try options.buildParamsAlloc(allocator, "/repo", "review contract");
    defer allocator.free(request);
    const documents = [_]contract.Document{.{
        .name = "ClientRequest.json",
        .bytes = "{\"definitions\":{\"ThreadStartParams\":{\"properties\":{\"config\":{}}}}}",
    }};
    try options.validateSchema(allocator, .{ .documents = &documents });
}

test "review options release partial ownership on allocation failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        exerciseReviewOptionsAllocation,
        .{},
    );
}
