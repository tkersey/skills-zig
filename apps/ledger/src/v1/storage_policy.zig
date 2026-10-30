const std = @import("std");
const definition_core = @import("definition_core");
const json = definition_core.json;

pub const schema = "ledger-storage-policy/v1";
pub const max_policy_bytes: usize = 64 * 1024;

pub const Limits = struct {
    logical_bytes: u64,
    staging_bytes: u64,
    metadata_bytes: u64,
    minimum_free_bytes: u64,
    recovery_reserve_bytes: u64,
};

pub const Maintenance = struct {
    max_entries: u64,
    max_read_bytes: u64,
    max_write_bytes: u64,
    max_elapsed_ms: u64,
    max_manifest_bytes: u64,
    max_provenance_edges: u64,
    max_clock_jump_seconds: u64,
    health_history_entries: u64,
};

pub const Thresholds = struct {
    high_water_basis_points: u64,
    low_water_basis_points: u64,
    warning_horizon_seconds: u64,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    budget_id: []const u8,
    limits: Limits,
    maintenance: Maintenance,
    thresholds: Thresholds,
    automatic_maintenance: bool,
    digest: []const u8,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.budget_id);
        self.allocator.free(self.digest);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Plan {
    if (bytes.len > max_policy_bytes) return error.StoragePolicyTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    defer parsed.deinit();
    const root = try json.object(parsed.value);
    const fields = &.{
        "schema", "budget_id", "limits", "maintenance", "thresholds", "automatic_maintenance",
    };
    try json.requireExactKeys(root, fields);
    try json.requireFields(root, fields);
    if (!std.mem.eql(u8, try json.requiredString(root, "schema"), schema)) {
        return error.UnsupportedStoragePolicySchema;
    }
    const budget_id = try json.requiredString(root, "budget_id");
    const limits = try parseNumbers(Limits, try json.field(root, "limits"));
    const maintenance = try parseNumbers(Maintenance, try json.field(root, "maintenance"));
    const thresholds = try parseNumbers(Thresholds, try json.field(root, "thresholds"));
    const automatic_maintenance = try json.boolean(try json.field(root, "automatic_maintenance"));
    try validate(limits, maintenance, thresholds);
    const owned_budget_id = try allocator.dupe(u8, budget_id);
    errdefer allocator.free(owned_budget_id);
    const digest = try definition_core.canonical_json.digestValueAlloc(allocator, parsed.value);
    return .{
        .allocator = allocator,
        .budget_id = owned_budget_id,
        .limits = limits,
        .maintenance = maintenance,
        .thresholds = thresholds,
        .automatic_maintenance = automatic_maintenance,
        .digest = digest,
    };
}

fn parseNumbers(comptime T: type, value: std.json.Value) !T {
    const map = try json.object(value);
    const fields = @typeInfo(T).@"struct".field_names;
    const names = comptime names: {
        var result: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, index| result[index] = field;
        break :names result;
    };
    try json.requireExactKeys(map, &names);
    try json.requireFields(map, &names);
    var result: T = undefined;
    inline for (fields) |field| {
        @field(result, field) = try json.unsigned64(try json.field(map, field));
    }
    return result;
}

fn validate(limits: Limits, maintenance: Maintenance, thresholds: Thresholds) !void {
    if (limits.recovery_reserve_bytes > limits.logical_bytes) {
        return error.InvalidRecoveryReserve;
    }
    if (maintenance.max_entries == 0 or maintenance.max_read_bytes == 0 or
        maintenance.max_write_bytes == 0 or maintenance.max_elapsed_ms == 0 or
        maintenance.max_manifest_bytes == 0 or maintenance.max_provenance_edges == 0)
    {
        return error.InvalidMaintenanceLimit;
    }
    if (thresholds.high_water_basis_points > 10_000 or
        thresholds.low_water_basis_points >= thresholds.high_water_basis_points)
    {
        return error.InvalidWatermarks;
    }
}

const fixture =
    \\{"schema":"ledger-storage-policy/v1","budget_id":"host budget",
    \\"limits":{"logical_bytes":10737418240,"staging_bytes":536870912,
    \\"metadata_bytes":134217728,"minimum_free_bytes":1073741824,
    \\"recovery_reserve_bytes":67108864},"maintenance":{"max_entries":10000,
    \\"max_read_bytes":67108864,"max_write_bytes":16777216,"max_elapsed_ms":1000,
    \\"max_manifest_bytes":8388608,"max_provenance_edges":10000,
    \\"max_clock_jump_seconds":86400,"health_history_entries":64},
    \\"thresholds":{"high_water_basis_points":8000,"low_water_basis_points":7000,
    \\"warning_horizon_seconds":604800},"automatic_maintenance":true}
;

fn replaceFixture(allocator: std.mem.Allocator, before: []const u8, after: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, fixture, before, after);
}

fn expectRejected(before: []const u8, after: []const u8, expected: anyerror) !void {
    const bytes = try replaceFixture(std.testing.allocator, before, after);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(expected, parse(std.testing.allocator, bytes));
}

test "storage policy owns its identity and exact canonical digest" {
    const allocator = std.testing.allocator;
    var plan = try parse(allocator, fixture);
    defer plan.deinit();
    try std.testing.expectEqualStrings("host budget", plan.budget_id);
    try std.testing.expectEqual(@as(u64, 10737418240), plan.limits.logical_bytes);
    try std.testing.expect(plan.automatic_maintenance);
    try std.testing.expect(definition_core.canonical_json.isFingerprint(plan.digest));
    const bytes = try replaceFixture(allocator, "10737418240", "1.073741824e10");
    var equivalent = try parse(allocator, bytes);
    allocator.free(bytes);
    defer equivalent.deinit();
    try std.testing.expectEqualStrings(plan.digest, equivalent.digest);
    try std.testing.expectEqualStrings(plan.budget_id, equivalent.budget_id);
    const changed = try replaceFixture(allocator, "10737418240", "10737418241");
    defer allocator.free(changed);
    var different = try parse(allocator, changed);
    defer different.deinit();
    try std.testing.expect(!std.mem.eql(u8, plan.digest, different.digest));
}

test "storage policy accepts exact full unsigned integer range" {
    const literals = [_][]const u8{
        "9223372036854775808", "18446744073709551615", "184467440737095516150e-1",
    };
    for (literals) |literal| {
        const bytes = try replaceFixture(std.testing.allocator, "10737418240", literal);
        defer std.testing.allocator.free(bytes);
        var plan = try parse(std.testing.allocator, bytes);
        defer plan.deinit();
        try std.testing.expectEqual(
            if (literal.len == 19) @as(u64, 9223372036854775808) else std.math.maxInt(u64),
            plan.limits.logical_bytes,
        );
    }
    try expectRejected("10737418240", "18446744073709551616", error.ExpectedUnsigned);
    try expectRejected("10737418240", "1e20", error.ExpectedUnsigned);
    try expectRejected("10737418240", "1e9223372036854775807", error.ExpectedUnsigned);
    try expectRejected("10737418240", "-1", error.ExpectedUnsigned);
    try expectRejected("10737418240", "10737418240.1", error.ExpectedInteger);
    try expectRejected("10737418240", "1e-100", error.ExpectedInteger);
    try expectRejected("10737418240", "\"10737418240\"", error.ExpectedInteger);
}

test "storage policy rejects unknown duplicate missing and wrongly typed fields" {
    try expectRejected("\"schema\":", "\"extra\":0,\"schema\":", error.UnknownField);
    try expectRejected("\"limits\":{", "\"limits\":{\"extra\":0,", error.UnknownField);
    try expectRejected("\"maintenance\":{", "\"maintenance\":{\"extra\":0,", error.UnknownField);
    try expectRejected("\"thresholds\":{", "\"thresholds\":{\"extra\":0,", error.UnknownField);
    try expectRejected("\"budget_id\":\"host budget\",", "", error.MissingField);
    try expectRejected("\"staging_bytes\":536870912,", "", error.MissingField);
    try expectRejected("\"max_entries\":10000,", "", error.MissingField);
    try expectRejected("\"low_water_basis_points\":7000,", "", error.MissingField);
    try expectRejected(
        "\"budget_id\":",
        "\"budget_id\":\"other\",\"budget_id\":",
        error.DuplicateField,
    );
    try expectRejected(
        "\"max_entries\":",
        "\"max_entries\":1,\"max_entries\":",
        error.DuplicateField,
    );
    try expectRejected(
        "\"automatic_maintenance\":true",
        "\"automatic_maintenance\":1",
        error.ExpectedBoolean,
    );
    try expectRejected("\"host budget\"", "null", error.ExpectedString);
    try expectRejected("\"host budget\"", "\"\"", error.InvalidString);
    try expectRejected(
        "ledger-storage-policy/v1",
        "ledger-storage-policy/v2",
        error.UnsupportedStoragePolicySchema,
    );
    try expectRejected("536870912", "true", error.ExpectedInteger);
    try std.testing.expectError(error.ExpectedObject, parse(std.testing.allocator, "[]"));
}

test "storage policy checks work watermarks and reserve without extra quota restrictions" {
    const work_fields = [_][2][]const u8{
        .{ "max_entries", "10000" },
        .{ "max_read_bytes", "67108864" },
        .{ "max_write_bytes", "16777216" },
        .{ "max_elapsed_ms", "1000" },
        .{ "max_manifest_bytes", "8388608" },
        .{ "max_provenance_edges", "10000" },
    };
    for (work_fields) |field| {
        var before_buffer: [80]u8 = undefined;
        var after_buffer: [80]u8 = undefined;
        const before = try std.fmt.bufPrint(&before_buffer, "\"{s}\":{s}", .{ field[0], field[1] });
        const after = try std.fmt.bufPrint(&after_buffer, "\"{s}\":0", .{field[0]});
        try expectRejected(before, after, error.InvalidMaintenanceLimit);
    }
    try expectRejected(
        "\"high_water_basis_points\":8000",
        "\"high_water_basis_points\":7000",
        error.InvalidWatermarks,
    );
    try expectRejected(
        "\"high_water_basis_points\":8000",
        "\"high_water_basis_points\":10001",
        error.InvalidWatermarks,
    );
    try expectRejected(
        "\"low_water_basis_points\":7000",
        "\"low_water_basis_points\":9000",
        error.InvalidWatermarks,
    );
    try expectRejected(
        "\"recovery_reserve_bytes\":67108864",
        "\"recovery_reserve_bytes\":10737418241",
        error.InvalidRecoveryReserve,
    );
    const cases = [_][2][]const u8{
        .{ "\"recovery_reserve_bytes\":67108864", "\"recovery_reserve_bytes\":10737418240" },
        .{ "\"high_water_basis_points\":8000", "\"high_water_basis_points\":10000" },
        .{ "\"low_water_basis_points\":7000", "\"low_water_basis_points\":0" },
        .{ "\"max_clock_jump_seconds\":86400", "\"max_clock_jump_seconds\":0" },
        .{ "\"health_history_entries\":64", "\"health_history_entries\":0" },
        .{ "\"warning_horizon_seconds\":604800", "\"warning_horizon_seconds\":0" },
        .{ "\"staging_bytes\":536870912", "\"staging_bytes\":18446744073709551615" },
        .{ "\"minimum_free_bytes\":1073741824", "\"minimum_free_bytes\":-0" },
    };
    for (cases) |case| {
        const bytes = try replaceFixture(std.testing.allocator, case[0], case[1]);
        defer std.testing.allocator.free(bytes);
        var plan = try parse(std.testing.allocator, bytes);
        defer plan.deinit();
    }
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var plan = try parse(allocator, fixture);
    defer plan.deinit();
}

test "storage policy bounds source size and releases allocations on failure" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, max_policy_bytes + 1);
    defer allocator.free(bytes);
    @memset(bytes, ' ');
    @memcpy(bytes[0..fixture.len], fixture);
    var plan = try parse(allocator, bytes[0..max_policy_bytes]);
    defer plan.deinit();
    try std.testing.expectError(error.StoragePolicyTooLarge, parse(allocator, bytes));
    try std.testing.checkAllAllocationFailures(allocator, allocationProbe, .{});
}
