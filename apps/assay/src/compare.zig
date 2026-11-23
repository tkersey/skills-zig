const std = @import("std");
const documents = @import("documents.zig");
const receipt = @import("receipt.zig");

const Allocator = std.mem.Allocator;
const Judgment = documents.Judgment;

pub const IncompatibilityCode = enum {
    contract_changed,
    context_changed,
    support_artifacts_changed,
};

pub const Incompatibility = struct {
    code: IncompatibilityCode,
    detail: []const u8,
    artifact_ids: []const []const u8,
};

pub const TransitionKind = enum {
    unchanged,
    gained_support,
    lost_support,
    refutation_resolved_to_unresolved,
    new_refutation,
};

pub const Transition = struct {
    obligation: u32,
    baseline: Judgment,
    candidate: Judgment,
    kind: TransitionKind,
};

pub const Preservation = enum {
    supported,
    refuted,
    unresolved,
    no_baseline_support,
    not_comparable,
};

pub const Comparison = struct {
    baseline: *const receipt.Verified,
    candidate: *const receipt.Verified,
    incompatibilities: []const Incompatibility,
    transitions: []const Transition,
    preservation: Preservation,

    pub fn comparable(self: Comparison) bool {
        return self.incompatibilities.len == 0;
    }
};

pub fn compare(
    arena: Allocator,
    baseline: *const receipt.Verified,
    candidate: *const receipt.Verified,
) error{OutOfMemory}!Comparison {
    const incompatibilities = try findIncompatibilities(arena, baseline, candidate);
    if (incompatibilities.len != 0) {
        return .{
            .baseline = baseline,
            .candidate = candidate,
            .incompatibilities = incompatibilities,
            .transitions = &.{},
            .preservation = .not_comparable,
        };
    }
    const before = baseline.derivation.items;
    const after = candidate.derivation.items;
    std.debug.assert(before.len == after.len);
    const transitions = try arena.alloc(Transition, before.len);
    for (before, after, transitions, 0..) |left, right, *transition, index| {
        transition.* = .{
            .obligation = @intCast(index),
            .baseline = left.judgment,
            .candidate = right.judgment,
            .kind = classify(left.judgment, right.judgment),
        };
    }
    return .{
        .baseline = baseline,
        .candidate = candidate,
        .incompatibilities = &.{},
        .transitions = transitions,
        .preservation = preservation(baseline.loaded.contract, transitions),
    };
}

pub fn classify(baseline: Judgment, candidate: Judgment) TransitionKind {
    if (baseline == candidate) return .unchanged;
    if (candidate == .supported) return .gained_support;
    if (baseline == .supported) return .lost_support;
    if (baseline == .refuted) return .refutation_resolved_to_unresolved;
    return .new_refutation;
}

fn preservation(contract: documents.Contract, transitions: []const Transition) Preservation {
    var any = false;
    var unresolved = false;
    for (transitions) |transition| {
        if (!contract.obligations[transition.obligation].required) continue;
        if (transition.baseline != .supported) continue;
        any = true;
        switch (transition.candidate) {
            .refuted => return .refuted,
            .unresolved => unresolved = true,
            .supported => {},
        }
    }
    if (!any) return .no_baseline_support;
    return if (unresolved) .unresolved else .supported;
}

fn findIncompatibilities(
    arena: Allocator,
    baseline: *const receipt.Verified,
    candidate: *const receipt.Verified,
) error{OutOfMemory}![]const Incompatibility {
    var result: std.ArrayList(Incompatibility) = .empty;
    const left = &baseline.loaded;
    const right = &candidate.loaded;
    if (!std.mem.eql(u8, &left.contract_sha256, &right.contract_sha256)) {
        try result.append(arena, .{
            .code = .contract_changed,
            .detail = "The raw contract digests differ.",
            .artifact_ids = &.{},
        });
    }
    const left_context = left.subject.artifacts[left.subject.context].sha256;
    const right_context = right.subject.artifacts[right.subject.context].sha256;
    if (!std.mem.eql(u8, left_context, right_context)) {
        try result.append(arena, .{
            .code = .context_changed,
            .detail = "The context artifact digests differ.",
            .artifact_ids = &.{},
        });
    }
    const changed = try changedSupportArtifacts(arena, left.subject, right.subject);
    if (changed.len != 0) {
        try result.append(arena, .{
            .code = .support_artifacts_changed,
            .detail = "Non-target subject artifacts differ by id, role, path, digest, or size.",
            .artifact_ids = changed,
        });
    }
    return result.items;
}

fn changedSupportArtifacts(
    arena: Allocator,
    left: documents.Subject,
    right: documents.Subject,
) error{OutOfMemory}![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for ([_][2]documents.Subject{ .{ left, right }, .{ right, left } }) |pair| {
        for (pair[0].artifacts) |artifact| {
            if (artifact.role == .target) continue;
            if (sameArtifact(artifact, pair[1])) continue;
            if (containsId(ids.items, artifact.id)) continue;
            try ids.append(arena, artifact.id);
        }
    }
    std.mem.sort([]const u8, ids.items, {}, lessThan);
    return ids.items;
}

fn sameArtifact(artifact: documents.Artifact, other: documents.Subject) bool {
    const index = other.find(artifact.id) orelse return false;
    const match = other.artifacts[index];
    return match.role == artifact.role and match.size_bytes == artifact.size_bytes and
        std.mem.eql(u8, match.path, artifact.path) and
        std.mem.eql(u8, match.sha256, artifact.sha256);
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |existing| {
        if (std.mem.eql(u8, existing, id)) return true;
    }
    return false;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "transition classification is total and named" {
    const cases = [_]struct { Judgment, Judgment, TransitionKind }{
        .{ .supported, .supported, .unchanged },
        .{ .refuted, .refuted, .unchanged },
        .{ .unresolved, .unresolved, .unchanged },
        .{ .refuted, .supported, .gained_support },
        .{ .unresolved, .supported, .gained_support },
        .{ .supported, .refuted, .lost_support },
        .{ .supported, .unresolved, .lost_support },
        .{ .refuted, .unresolved, .refutation_resolved_to_unresolved },
        .{ .unresolved, .refuted, .new_refutation },
    };
    for (cases) |case| try std.testing.expectEqual(case[2], classify(case[0], case[1]));
}
