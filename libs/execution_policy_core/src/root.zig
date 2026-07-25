const std = @import("std");

pub const atom = @import("atom.zig");
pub const canonical_json = @import("canonical_json.zig");
pub const condition = @import("condition.zig");
pub const errors = @import("errors.zig");
pub const potential = @import("potential.zig");
const compiler = @import("compiler.zig");
const schema = @import("schema.zig");
const selection = @import("selection.zig");
const transition = @import("transition.zig");

pub const CompiledPolicy = compiler.CompiledPolicy;
pub const CompileResult = compiler.CompileResult;
pub const State = schema.State;
pub const Decision = schema.Decision;
pub const TransitionReceipt = schema.TransitionReceipt;
pub const Digest = canonical_json.Digest;
pub const ErrorCode = errors.ErrorCode;
pub const ValidationError = errors.ValidationError;
pub const ValidationReport = errors.ValidationReport;
pub const PotentialComparison = potential.PotentialComparison;

pub fn compilePolicy(allocator: std.mem.Allocator, bytes: []const u8) !CompileResult {
    return compiler.compile(allocator, bytes);
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

pub fn canonicalPolicyDigest(allocator: std.mem.Allocator, policy: *const CompiledPolicy) !Digest {
    return .{ .text = try allocator.dupe(u8, policy.digest()) };
}

pub fn select(allocator: std.mem.Allocator, policy: *const CompiledPolicy, state: *const State) !Decision {
    return selection.select(allocator, compiler.runtimePolicy(policy), state);
}

pub fn validateReceipt(
    allocator: std.mem.Allocator,
    policy: *const CompiledPolicy,
    state: *const State,
    decision: *const Decision,
    receipt: *const TransitionReceipt,
) !ValidationReport {
    return transition.validateReceiptForDigest(allocator, compiler.runtimePolicy(policy), state, decision, receipt, policy.digest());
}

pub fn applyReceipt(
    allocator: std.mem.Allocator,
    policy: *const CompiledPolicy,
    state: *const State,
    decision: *const Decision,
    receipt: *const TransitionReceipt,
    updated_at: []const u8,
) !State {
    return transition.applyReceiptForDigest(allocator, compiler.runtimePolicy(policy), state, decision, receipt, updated_at, policy.digest());
}

pub fn comparePotential(before: []const i64, after: []const i64) PotentialComparison {
    return potential.comparePotential(before, after);
}

test "public API compiles policy before execution" {
    var result = try compilePolicy(std.testing.allocator,
        \\{
        \\  "policy_id":"p1",
        \\  "revision":1,
        \\  "declared_atoms":["fact:start","fact:done"],
        \\  "actions":[{"id":"a1","results":{"success":["fact:done"]}}],
        \\  "policy_rules":[
        \\    {"id":"r1","condition":{"all":["fact:start"]},"actions":["a1"]},
        \\    {"id":"r2","condition":{"all":["fact:done"]},"terminal":"success"}
        \\  ],
        \\  "terminals":[{"id":"success","condition":{"all":["fact:done"]}}]
        \\}
    );
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => |policy| try std.testing.expect(std.mem.startsWith(u8, policy.digest(), "sha256:")),
        .report => return error.ExpectedCompiledPolicy,
    }
}

test "public API exposes digest and potential comparison" {
    var result = try compilePolicy(std.testing.allocator,
        \\{"policy_id":"p1","revision":1,"declared_atoms":[],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}]}
    );
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => |policy| {
            var digest = try canonicalPolicyDigest(std.testing.allocator, policy);
            defer digest.deinit(std.testing.allocator);
            try std.testing.expect(std.mem.startsWith(u8, digest.text, "sha256:"));
        },
        .report => return error.ExpectedCompiledPolicy,
    }

    const comparison = comparePotential(&.{ 1, 2 }, &.{ 1, 1 });
    try std.testing.expectEqual(potential.Relation.improved, comparison.relation);
    try std.testing.expectEqual(@as(?usize, 1), comparison.first_difference);
}

test "public API validates and applies transition receipt" {
    var result = try compilePolicy(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:done"],"actions":[{"id":"a","results":{"success":["fact:done"]}}],"policy_rules":[{"id":"r1","actions":["a"]},{"id":"r2","condition":{"all":["fact:done"]},"terminal":"success"}],"terminals":[{"id":"success","condition":{"all":["fact:done"]}}]}
    );
    defer result.deinit(std.testing.allocator);
    const policy = switch (result) {
        .policy => |policy| policy,
        .report => return error.ExpectedCompiledPolicy,
    };
    const state_text = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"policy_id":"p","revision":1,"policy_digest":"{s}","satisfied_atoms":[]}}
    , .{policy.digest()});
    defer std.testing.allocator.free(state_text);
    var state = try parseState(std.testing.allocator, state_text);
    defer state.deinit(std.testing.allocator);
    var decision = try parseDecision(std.testing.allocator,
        \\{"decision_id":"d","winner":{"kind":"action","id":"a"}}
    );
    defer decision.deinit(std.testing.allocator);
    const receipt_text = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"policy_id":"p","revision":1,"policy_digest":"{s}","decision_id":"d","action_id":"a","result":"success","predicted_effects":["fact:done"],"observed":{{"facts":["fact:done"],"potential":[0]}},"state_after":{{"state_id":"s2","potential":[0]}}}}
    , .{policy.digest()});
    defer std.testing.allocator.free(receipt_text);
    var receipt = try parseTransitionReceipt(std.testing.allocator, receipt_text);
    defer receipt.deinit(std.testing.allocator);

    var report = try validateReceipt(std.testing.allocator, policy, &state, &decision, &receipt);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());

    var next = try applyReceipt(std.testing.allocator, policy, &state, &decision, &receipt, "2026-06-24T00:00:00Z");
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("s2", next.root().object.get("state_id").?.string);
}

test "rich EPG compiles to an executable policy with a derived initial state" {
    var result = try compilePolicy(
        std.testing.allocator,
        @embedFile("fixtures/valid_architectonic_epg.json"),
    );
    defer result.deinit(std.testing.allocator);
    const policy = switch (result) {
        .policy => |policy| policy,
        .report => |report| {
            std.debug.print("unexpected compile errors: {any}\n", .{report.errors});
            return error.ExpectedCompiledPolicy;
        },
    };
    var state = (try policy.initialState(std.testing.allocator)) orelse return error.ExpectedInitialState;
    defer state.deinit(std.testing.allocator);
    var decision = try select(std.testing.allocator, policy, &state);
    defer decision.deinit(std.testing.allocator);
    const winner = decision.root().object.get("winner").?.object;
    try std.testing.expectEqualStrings("action", winner.get("kind").?.string);
    try std.testing.expectEqualStrings("A", winner.get("id").?.string);
    try std.testing.expectEqualStrings(policy.digest(), state.root().object.get("policy_digest").?.string);
}

test "rich EPG cannot self-certify readiness or name an execution handoff" {
    const fixture = @embedFile("fixtures/valid_architectonic_epg.json");
    const injections = [_][]const u8{
        "\"gate\":null,\"revision_summary\"",
        "\"handoff\":{},\"revision_summary\"",
    };
    for (injections) |injection| {
        const bytes = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            fixture,
            "\"revision_summary\"",
            injection,
        );
        defer std.testing.allocator.free(bytes);

        var result = try compilePolicy(std.testing.allocator, bytes);
        defer result.deinit(std.testing.allocator);
        switch (result) {
            .policy => return error.ExpectedCompileRejection,
            .report => |report| {
                try std.testing.expect(!report.ok());
                try std.testing.expectEqual(ErrorCode.self_certification_forbidden, report.errors[0].code);
            },
        }
    }
}

test "malformed rich EPG returns a report before lowering" {
    const fixture = @embedFile("fixtures/valid_architectonic_epg.json");
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixture,
        "\"utility\": {",
        "\"missing_utility\": {",
    );
    defer std.testing.allocator.free(bytes);

    var result = try compilePolicy(std.testing.allocator, bytes);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => return error.ExpectedCompileRejection,
        .report => |report| try std.testing.expect(!report.ok()),
    }
}

test "wrapped rich EPG rejects unsigned sibling claims" {
    const fixture = @embedFile("fixtures/valid_architectonic_epg.json");
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixture,
        "{\n  \"execution_policy_graph\"",
        "{\n  \"gate\": true,\n  \"execution_policy_graph\"",
    );
    defer std.testing.allocator.free(bytes);

    var result = try compilePolicy(std.testing.allocator, bytes);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => return error.ExpectedCompileRejection,
        .report => |report| {
            try std.testing.expect(!report.ok());
            try std.testing.expectEqual(ErrorCode.schema_invalid, report.errors[0].code);
            try std.testing.expectEqualStrings("$", report.errors[0].path);
        },
    }
}

test "rich EPG requires source binding and a bounded horizon" {
    const fixture = @embedFile("fixtures/valid_architectonic_epg.json");
    const replacements = [_]struct { needle: []const u8, replacement: []const u8 }{
        .{ .needle = "\"source\": {", .replacement = "\"missing_source\": {" },
        .{ .needle = "\"horizon\": {", .replacement = "\"missing_horizon\": {" },
    };
    for (replacements) |replacement| {
        const bytes = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            fixture,
            replacement.needle,
            replacement.replacement,
        );
        defer std.testing.allocator.free(bytes);

        var result = try compilePolicy(std.testing.allocator, bytes);
        defer result.deinit(std.testing.allocator);
        switch (result) {
            .policy => return error.ExpectedCompileRejection,
            .report => |report| try std.testing.expect(!report.ok()),
        }
    }
}

test "rich EPG rejects source that declares itself stale" {
    const fixture = @embedFile("fixtures/valid_architectonic_epg.json");
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixture,
        "\"current\": \"yes\"",
        "\"current\": \"no\"",
    );
    defer std.testing.allocator.free(bytes);

    var result = try compilePolicy(std.testing.allocator, bytes);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => return error.ExpectedCompileRejection,
        .report => |report| {
            var saw_source_stale = false;
            for (report.errors) |item| {
                if (item.code == .source_stale) saw_source_stale = true;
            }
            try std.testing.expect(saw_source_stale);
        },
    }
}
