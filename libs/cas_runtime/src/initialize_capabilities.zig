const std = @import("std");

pub const max_initialize_capabilities_bytes: usize = 64 * 1024;

pub const InitializeCapabilityBuilder = struct {
    experimental_api: bool = true,
    opt_out_notification_methods: []const []const u8 = &.{},
    mcp_server_openai_form_elicitation: bool = false,
    request_attestation: bool = false,
    additional_json: ?[]const u8 = null,

    const max_additional_fields: usize = 64;
    const max_notification_methods: usize = 256;
    const max_method_bytes: usize = 1024;

    pub fn validate(self: InitializeCapabilityBuilder, allocator: std.mem.Allocator) !void {
        var parsed = try self.parseAdditional(allocator);
        defer if (parsed) |*value| value.deinit();
    }

    /// The parsed object's arena remains alive through validation and emission.
    /// Keep the initializer's default numeric interpretation distinct from CAS
    /// review configuration's lexeme-preserving identity serialization.
    fn parseAdditional(
        self: InitializeCapabilityBuilder,
        allocator: std.mem.Allocator,
    ) !?std.json.Parsed(std.json.Value) {
        if (self.opt_out_notification_methods.len > max_notification_methods) {
            return error.InitializeCapabilitiesTooLarge;
        }
        for (self.opt_out_notification_methods) |method| {
            if (method.len == 0 or method.len > max_method_bytes) {
                return error.InvalidInitializeCapabilities;
            }
        }
        const raw = self.additional_json orelse return null;
        if (raw.len > max_initialize_capabilities_bytes) {
            return error.InitializeCapabilitiesTooLarge;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err|
            switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidInitializeCapabilities,
            };
        errdefer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidInitializeCapabilities,
        };
        try validateAdditionalObject(object);
        return parsed;
    }

    fn validateAdditionalObject(object: std.json.ObjectMap) !void {
        if (object.count() > max_additional_fields) return error.InitializeCapabilitiesTooLarge;
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.*.len == 0 or isTypedCapability(entry.key_ptr.*))
                return error.DuplicateInitializeCapabilityOwner;
        }
    }

    pub fn buildAlloc(self: InitializeCapabilityBuilder, allocator: std.mem.Allocator) ![]u8 {
        var parsed = try self.parseAdditional(allocator);
        defer if (parsed) |*value| value.deinit();
        return self.buildParsedAlloc(allocator, if (parsed) |value| value.value.object else null);
    }

    fn buildParsedAlloc(
        self: InitializeCapabilityBuilder,
        allocator: std.mem.Allocator,
        additional: ?std.json.ObjectMap,
    ) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        self.writeJson(additional, &output.writer) catch return error.OutOfMemory;
        if (output.written().len > max_initialize_capabilities_bytes) {
            return error.InitializeCapabilitiesTooLarge;
        }
        return output.toOwnedSlice();
    }

    fn writeJson(
        self: InitializeCapabilityBuilder,
        additional: ?std.json.ObjectMap,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{\"experimentalApi\":");
        try std.json.Stringify.value(self.experimental_api, .{}, writer);
        try writer.writeAll(",\"optOutNotificationMethods\":");
        try std.json.Stringify.value(self.opt_out_notification_methods, .{}, writer);
        try writer.writeAll(",\"mcpServerOpenaiFormElicitation\":");
        try std.json.Stringify.value(self.mcp_server_openai_form_elicitation, .{}, writer);
        try writer.writeAll(",\"requestAttestation\":");
        try std.json.Stringify.value(self.request_attestation, .{}, writer);

        if (additional) |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try writer.writeByte(',');
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
            }
        }
        try writer.writeByte('}');
    }

    fn isTypedCapability(key: []const u8) bool {
        return std.mem.eql(u8, key, "experimentalApi") or
            std.mem.eql(u8, key, "optOutNotificationMethods") or
            std.mem.eql(u8, key, "mcpServerOpenaiFormElicitation") or
            std.mem.eql(u8, key, "requestAttestation");
    }
};

const default_fields = "{\"experimentalApi\":true,\"optOutNotificationMethods\":[]," ++
    "\"mcpServerOpenaiFormElicitation\":false,\"requestAttestation\":false";

test "capability output preserves initializer numeric interpretation and additive order" {
    const allocator = std.testing.allocator;
    const raw = try (InitializeCapabilityBuilder{
        .additional_json =
        \\{"nullValue":null,"disabled":false,"emptyArray":[],"emptyObject":{},"nested":{"integer":1,"decimal":1.0,"exponent":1e2,"large":9223372036854775808,"fraction":9007199254740992.1}}
        ,
    }).buildAlloc(allocator);
    defer allocator.free(raw);
    try std.testing.expectEqualStrings(
        default_fields ++
            \\,"nullValue":null,"disabled":false,"emptyArray":[],"emptyObject":{},"nested":{"integer":1,"decimal":1,"exponent":100,"large":9223372036854775808,"fraction":9007199254740992}}
        ,
        raw,
    );
}

test "capability output is owned after escaped input and option storage are destroyed" {
    const allocator = std.testing.allocator;
    const raw = blk: {
        const additions = try allocator.dupe(u8, "{\"futur\\u0065\":{\"value\":\"owned\\ntext\"}}");
        defer allocator.free(additions);
        const method = try allocator.dupe(u8, "thread/started");
        defer allocator.free(method);
        break :blk try (InitializeCapabilityBuilder{
            .additional_json = additions,
            .opt_out_notification_methods = &.{method},
        }).buildAlloc(allocator);
    };
    defer allocator.free(raw);
    try std.testing.expectEqualStrings(
        "{\"experimentalApi\":true,\"optOutNotificationMethods\":[\"thread/started\"]," ++
            "\"mcpServerOpenaiFormElicitation\":false,\"requestAttestation\":false," ++
            "\"future\":{\"value\":\"owned\\ntext\"}}",
        raw,
    );
}

test "capability admission retains field method byte limits and error precedence" {
    const allocator = std.testing.allocator;
    const invalid_values = [_][]const u8{
        "null", "false", "[]", "1", "{", "{} trailing", "{\"f\":1,\"f\":2}",
    };
    for (invalid_values) |invalid| {
        try std.testing.expectError(
            error.InvalidInitializeCapabilities,
            (InitializeCapabilityBuilder{ .additional_json = invalid }).buildAlloc(allocator),
        );
    }
    for ([_][]const u8{
        "{\"\":true}",
        "{\"experimentalApi\":false}",
        "{\"optOutNotificationMethods\":[]}",
        "{\"mcpServerOpenaiFormElicitation\":false}",
        "{\"requestAttestation\":false}",
    }) |reserved| {
        try std.testing.expectError(
            error.DuplicateInitializeCapabilityOwner,
            (InitializeCapabilityBuilder{ .additional_json = reserved }).buildAlloc(allocator),
        );
    }
    var object: std.Io.Writer.Allocating = .init(allocator);
    defer object.deinit();
    try object.writer.writeByte('{');
    for (0..64) |index| {
        if (index != 0) try object.writer.writeByte(',');
        try object.writer.print("\"field{d}\":false", .{index});
    }
    try object.writer.writeByte('}');
    const bounded = try (InitializeCapabilityBuilder{
        .additional_json = object.written(),
    }).buildAlloc(allocator);
    allocator.free(bounded);
    object.writer.undo(1);
    try object.writer.writeAll(",\"overflow\":false}");
    try std.testing.expectError(error.InitializeCapabilitiesTooLarge, (InitializeCapabilityBuilder{
        .additional_json = object.written(),
    }).buildAlloc(allocator));

    const oversized = try allocator.alloc(u8, max_initialize_capabilities_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.InitializeCapabilitiesTooLarge, (InitializeCapabilityBuilder{
        .additional_json = oversized,
    }).buildAlloc(allocator));
    try std.testing.expectError(error.InvalidInitializeCapabilities, (InitializeCapabilityBuilder{
        .opt_out_notification_methods = &.{""},
        .additional_json = oversized,
    }).buildAlloc(allocator));
    const methods: [257][]const u8 = @splat("m");
    try std.testing.expectError(error.InitializeCapabilitiesTooLarge, (InitializeCapabilityBuilder{
        .opt_out_notification_methods = &methods,
    }).buildAlloc(allocator));
    const method: [1025]u8 = @splat('m');
    try std.testing.expectError(error.InvalidInitializeCapabilities, (InitializeCapabilityBuilder{
        .opt_out_notification_methods = &.{&method},
    }).buildAlloc(allocator));
    // Every field is individually admitted, but the final object exceeds the
    // same aggregate limit as the old builder.
    const large_methods: [64][]const u8 = @splat(method[0..1024]);
    try std.testing.expectError(error.InitializeCapabilitiesTooLarge, (InitializeCapabilityBuilder{
        .opt_out_notification_methods = &large_methods,
    }).buildAlloc(allocator));
}

test "capability building removes one complete validation parse allocation sequence" {
    const allocator = std.testing.allocator;
    const large_string = try allocator.alloc(u8, 48 * 1024);
    defer allocator.free(large_string);
    @memset(large_string, 'a');
    const large = try allocator.print("{{\"future\":\"{s}\"}}", .{large_string});
    defer allocator.free(large);
    const additions = [_]?[]const u8{
        null, "{}", "{\"future\":{\"enabled\":true,\"values\":[1,2,3]}}", large,
    };
    for (additions) |additional| {
        const builder = InitializeCapabilityBuilder{ .additional_json = additional };
        // Relocation makes the allocator sequence independent of heap layout.
        var validation = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
        try builder.validate(validation.allocator());
        var candidate = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
        const actual = try builder.buildAlloc(candidate.allocator());
        defer candidate.allocator().free(actual);
        var legacy = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
        const expected = try legacyBuildAlloc(builder, legacy.allocator());
        defer legacy.allocator().free(expected);
        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expectEqual(
            legacy.alloc_index,
            candidate.alloc_index + validation.alloc_index,
        );
        try std.testing.expectEqual(
            legacy.allocated_bytes,
            candidate.allocated_bytes + validation.allocated_bytes,
        );
        if (additional != null) try std.testing.expect(validation.alloc_index > 0);
    }
}

/// Test-only baseline: the replaced builder validated, freed the parsed tree,
/// then parsed again while writing. The wire writer itself is unchanged.
fn legacyBuildAlloc(builder: InitializeCapabilityBuilder, allocator: std.mem.Allocator) ![]u8 {
    try builder.validate(allocator);
    var parsed: ?std.json.Parsed(std.json.Value) = if (builder.additional_json) |raw|
        try std.json.parseFromSlice(std.json.Value, allocator, raw, .{})
    else
        null;
    defer if (parsed) |*value| value.deinit();
    return builder.buildParsedAlloc(allocator, if (parsed) |value| value.value.object else null);
}
