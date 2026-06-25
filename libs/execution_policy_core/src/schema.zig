const std = @import("std");
const errors = @import("errors.zig");

pub const ArtifactKind = enum {
    policy,
    state,
    decision,
    transition_receipt,
};

pub const Policy = RawArtifact(.policy);
pub const State = RawArtifact(.state);
pub const Decision = RawArtifact(.decision);
pub const TransitionReceipt = RawArtifact(.transition_receipt);

fn RawArtifact(comptime kind_value: ArtifactKind) type {
    return struct {
        pub const kind: ArtifactKind = kind_value;

        raw_json: []u8,
        parsed: std.json.Parsed(std.json.Value),

        const Self = @This();

        pub fn root(self: *const Self) std.json.Value {
            return self.parsed.value;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.parsed.deinit();
            allocator.free(self.raw_json);
            self.* = undefined;
        }
    };
}

pub fn parseArtifact(comptime Artifact: type, allocator: std.mem.Allocator, bytes: []const u8) !Artifact {
    const raw_json = try allocator.dupe(u8, bytes);
    errdefer allocator.free(raw_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    return .{
        .raw_json = raw_json,
        .parsed = parsed,
    };
}

pub const ParseResult = union(enum) {
    artifact: Policy,
    report: errors.ValidationReport,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .artifact => |*artifact| artifact.deinit(allocator),
            .report => |*report| report.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub fn parsePolicyReport(allocator: std.mem.Allocator, bytes: []const u8) !ParseResult {
    var policy = parseArtifact(Policy, allocator, bytes) catch {
        return .{ .report = try singleSchemaInvalid(allocator, "$") };
    };
    errdefer policy.deinit(allocator);
    if (policy.root() != .object) {
        const report = try singleSchemaInvalid(allocator, "$");
        policy.deinit(allocator);
        return .{ .report = report };
    }
    return .{ .artifact = policy };
}

pub fn singleSchemaInvalid(allocator: std.mem.Allocator, path: []const u8) !errors.ValidationReport {
    var builder = errors.Builder.init(allocator);
    defer builder.deinit();
    try builder.add(.schema_invalid, path);
    return builder.finish();
}

pub fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => null,
    };
}

pub fn requiredString(root_value: std.json.Value, key: []const u8) ?[]const u8 {
    const root_object = object(root_value) orelse return null;
    const field = root_object.get(key) orelse return null;
    return switch (field) {
        .string => |value| value,
        else => null,
    };
}

test "raw artifacts own duplicated JSON" {
    var policy = try parseArtifact(Policy, std.testing.allocator, "{\"policy_id\":\"p1\"}");
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(ArtifactKind.policy, Policy.kind);
    try std.testing.expectEqualStrings("{\"policy_id\":\"p1\"}", policy.raw_json);
    try std.testing.expectEqualStrings("p1", requiredString(policy.root(), "policy_id").?);
}

test "artifact parser lifetime is tied to returned owner" {
    const input = try std.testing.allocator.dupe(u8, "{\"policy_id\":\"owned\"}");
    var policy = try parseArtifact(Policy, std.testing.allocator, input);
    defer policy.deinit(std.testing.allocator);
    @memset(input, 'x');
    std.testing.allocator.free(input);

    try std.testing.expectEqualStrings("owned", requiredString(policy.root(), "policy_id").?);
}

test "parse report returns stable schema invalid path" {
    var result = try parsePolicyReport(std.testing.allocator, "[]");
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .report => |report| {
            try std.testing.expect(!report.ok());
            try std.testing.expectEqual(errors.ErrorCode.schema_invalid, report.errors[0].code);
            try std.testing.expectEqualStrings("$", report.errors[0].path);
        },
        .artifact => return error.ExpectedReport,
    }
}
