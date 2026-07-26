const std = @import("std");

pub const ErrorCode = enum {
    schema_invalid,
    id_duplicate,
    reference_unknown,
    atom_invalid,
    atom_unknown,
    action_cycle,
    action_unreachable,
    outcome_dangling,
    self_certification_forbidden,
    architectonic_incomplete,
    architectonic_unbound,
    factor_unearned,
    factor_disposition_conflict,
    factor_scope_mismatch,
    critical_unknown_unobservable,
    obligation_uncovered,
    risky_action_unshielded,
    source_stale,
    policy_digest_mismatch,
    state_digest_mismatch,
    active_action_conflict,
    no_eligible_action,
    policy_dead_end,
    receipt_identity_mismatch,
    receipt_prediction_mismatch,
    observation_outcome_unknown,
    proof_missing,
    surprise_result_mismatch,
    potential_mismatch,
    transition_invalid,
};

pub const ValidationError = struct {
    code: ErrorCode,
    path: []u8,
    evidence_refs: [][]u8 = &.{},

    pub fn deinit(self: *ValidationError, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.evidence_refs) |ref| allocator.free(ref);
        if (self.evidence_refs.len > 0) allocator.free(self.evidence_refs);
        self.* = undefined;
    }
};

pub const ValidationReport = struct {
    errors: []ValidationError = &.{},

    pub fn ok(self: ValidationReport) bool {
        return self.errors.len == 0;
    }

    pub fn deinit(self: *ValidationReport, allocator: std.mem.Allocator) void {
        for (self.errors) |*err| err.deinit(allocator);
        if (self.errors.len > 0) allocator.free(self.errors);
        self.* = undefined;
    }
};

pub fn emptyReport() ValidationReport {
    return .{};
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ValidationError) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        for (self.errors.items) |*err| err.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Builder, code: ErrorCode, path: []const u8) !void {
        try self.errors.append(self.allocator, .{
            .code = code,
            .path = try self.allocator.dupe(u8, path),
        });
    }

    pub fn finish(self: *Builder) !ValidationReport {
        const owned = try self.errors.toOwnedSlice(self.allocator);
        self.* = .{ .allocator = self.allocator };
        return .{ .errors = owned };
    }
};

test "empty validation report is ok" {
    var report = emptyReport();
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());
}

test "validation report builder owns paths" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.add(.schema_invalid, "$.policy_id");

    var report = try builder.finish();
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(ErrorCode.schema_invalid, report.errors[0].code);
    try std.testing.expectEqualStrings("$.policy_id", report.errors[0].path);
}
