const std = @import("std");

pub const atom = @import("atom.zig");
pub const canonical_json = @import("canonical_json.zig");
pub const condition = @import("condition.zig");
pub const errors = @import("errors.zig");
pub const potential = @import("potential.zig");
pub const schema = @import("schema.zig");
pub const selection = @import("selection.zig");
pub const transition = @import("transition.zig");
pub const validation = @import("validation.zig");

pub const Policy = schema.Policy;
pub const State = schema.State;
pub const Decision = schema.Decision;
pub const TransitionReceipt = schema.TransitionReceipt;
pub const Digest = canonical_json.Digest;
pub const ErrorCode = errors.ErrorCode;
pub const ValidationError = errors.ValidationError;
pub const ValidationReport = errors.ValidationReport;
pub const PotentialComparison = potential.PotentialComparison;

pub fn parsePolicy(allocator: std.mem.Allocator, bytes: []const u8) !Policy {
    return schema.parseArtifact(Policy, allocator, bytes);
}

pub fn parseState(allocator: std.mem.Allocator, bytes: []const u8) !State {
    return schema.parseArtifact(State, allocator, bytes);
}

pub fn parseDecision(allocator: std.mem.Allocator, bytes: []const u8) !Decision {
    return schema.parseArtifact(Decision, allocator, bytes);
}

pub fn parseTransitionReceipt(allocator: std.mem.Allocator, bytes: []const u8) !TransitionReceipt {
    return schema.parseArtifact(TransitionReceipt, allocator, bytes);
}

pub fn validatePolicy(allocator: std.mem.Allocator, policy: *const Policy) !ValidationReport {
    return validation.validatePolicy(allocator, policy);
}

pub fn canonicalPolicyDigest(allocator: std.mem.Allocator, policy: *const Policy) !Digest {
    return canonical_json.digestRawJson(allocator, policy.raw_json);
}

pub fn select(allocator: std.mem.Allocator, policy: *const Policy, state: *const State) !Decision {
    return selection.select(allocator, policy, state);
}

pub fn validateReceipt(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    state: *const State,
    decision: *const Decision,
    receipt: *const TransitionReceipt,
) !ValidationReport {
    return transition.validateReceipt(allocator, policy, state, decision, receipt);
}

pub fn applyReceipt(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    state: *const State,
    decision: *const Decision,
    receipt: *const TransitionReceipt,
    updated_at: []const u8,
) !State {
    return transition.applyReceipt(allocator, policy, state, decision, receipt, updated_at);
}

pub fn comparePotential(before: []const i64, after: []const i64) PotentialComparison {
    return potential.comparePotential(before, after);
}

test "public API parses and owns policy bytes" {
    var policy = try parsePolicy(std.testing.allocator,
        \\{
        \\  "policy_id":"p1",
        \\  "revision":1,
        \\  "declared_atoms":["fact:start"],
        \\  "actions":[{"id":"a1"}],
        \\  "policy_rules":[{"id":"r1","actions":["a1"]}]
        \\}
    );
    defer policy.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, policy.raw_json, "\"policy_id\"") != null);

    var report = try validatePolicy(std.testing.allocator, &policy);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());
}

test "public API exposes digest and potential comparison" {
    var policy = try parsePolicy(std.testing.allocator, "{\"policy_id\":\"p1\"}");
    defer policy.deinit(std.testing.allocator);

    var digest = try canonicalPolicyDigest(std.testing.allocator, &policy);
    defer digest.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, digest.text, "sha256:"));

    const comparison = comparePotential(&.{ 1, 2 }, &.{ 1, 1 });
    try std.testing.expectEqual(potential.Relation.improved, comparison.relation);
    try std.testing.expectEqual(@as(?usize, 1), comparison.first_difference);
}

test "public API validates and applies transition receipt" {
    var policy = try parsePolicy(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","results":{"success":["fact:done"]}}]}
    );
    defer policy.deinit(std.testing.allocator);
    var policy_digest = try canonicalPolicyDigest(std.testing.allocator, &policy);
    defer policy_digest.deinit(std.testing.allocator);
    const state_text = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"policy_id":"p","revision":1,"policy_digest":"{s}","satisfied_atoms":[]}}
    , .{policy_digest.text});
    defer std.testing.allocator.free(state_text);
    var state = try parseState(std.testing.allocator, state_text);
    defer state.deinit(std.testing.allocator);
    var decision = try parseDecision(std.testing.allocator,
        \\{"decision_id":"d","winner":{"kind":"action","id":"a"}}
    );
    defer decision.deinit(std.testing.allocator);
    const receipt_text = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"policy_id":"p","revision":1,"policy_digest":"{s}","decision_id":"d","action_id":"a","result":"success","predicted_effects":["fact:done"],"observed":{{"facts":["fact:done"],"potential":[0]}},"state_after":{{"state_id":"s2","potential":[0]}}}}
    , .{policy_digest.text});
    defer std.testing.allocator.free(receipt_text);
    var receipt = try parseTransitionReceipt(std.testing.allocator, receipt_text);
    defer receipt.deinit(std.testing.allocator);

    var report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &receipt);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());

    var next = try applyReceipt(std.testing.allocator, &policy, &state, &decision, &receipt, "2026-06-24T00:00:00Z");
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("s2", next.root().object.get("state_id").?.string);
}
