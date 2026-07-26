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

pub fn select(
    allocator: std.mem.Allocator,
    policy: *const CompiledPolicy,
    state: *const State,
) !Decision {
    return selection.select(allocator, compiler.runtimePolicy(policy), state);
}

pub fn validateReceipt(
    allocator: std.mem.Allocator,
    policy: *const CompiledPolicy,
    state: *const State,
    decision: *const Decision,
    receipt: *const TransitionReceipt,
) !ValidationReport {
    return transition.validateReceiptForDigest(
        allocator,
        compiler.runtimePolicy(policy),
        state,
        decision,
        receipt,
        policy.digest(),
    );
}

pub fn applyReceipt(
    allocator: std.mem.Allocator,
    policy: *const CompiledPolicy,
    state: *const State,
    decision: *const Decision,
    receipt: *const TransitionReceipt,
    updated_at: []const u8,
) !State {
    return transition.applyReceiptForDigest(
        allocator,
        compiler.runtimePolicy(policy),
        state,
        decision,
        receipt,
        updated_at,
        policy.digest(),
    );
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
        .policy => |policy| try std.testing.expect(
            std.mem.startsWith(u8, policy.digest(), "sha256:"),
        ),
        .report => return error.ExpectedCompiledPolicy,
    }
}

test "public API exposes digest and potential comparison" {
    var result = try compilePolicy(std.testing.allocator,
        \\{"policy_id":"p1","revision":1,"declared_atoms":[],
        \\"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}]}
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
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:done"],
        \\"actions":[{"id":"a","results":{"success":["fact:done"]}}],
        \\"policy_rules":[{"id":"r1","actions":["a"]},
        \\{"id":"r2","condition":{"all":["fact:done"]},"terminal":"success"}],
        \\"terminals":[{"id":"success","condition":{"all":["fact:done"]}}]}
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
        \\{{"policy_id":"p","revision":1,"policy_digest":"{s}",
        \\"decision_id":"d","action_id":"a","result":"success",
        \\"predicted_effects":["fact:done"],
        \\"observed":{{"facts":["fact:done"],"potential":[0]}},
        \\"state_after":{{"state_id":"s2","potential":[0]}}}}
    , .{policy.digest()});
    defer std.testing.allocator.free(receipt_text);
    var receipt = try parseTransitionReceipt(std.testing.allocator, receipt_text);
    defer receipt.deinit(std.testing.allocator);

    var report = try validateReceipt(
        std.testing.allocator,
        policy,
        &state,
        &decision,
        &receipt,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());

    var next = try applyReceipt(
        std.testing.allocator,
        policy,
        &state,
        &decision,
        &receipt,
        "2026-06-24T00:00:00Z",
    );
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("s2", next.root().object.get("state_id").?.string);
}

test "rich EPG compiles and executes from consumer-owned state" {
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
    const state_text = try std.fmt.allocPrint(
        std.testing.allocator,
        \\{{"policy_id":"compile-demo","revision":1,"policy_digest":"{s}",
        \\"state_id":"consumer-s0","satisfied_atoms":["fact:START"],
        \\"completed_actions":[],"failed_actions":[],"potential":[1]}}
    ,
        .{policy.digest()},
    );
    defer std.testing.allocator.free(state_text);
    var state = try parseState(std.testing.allocator, state_text);
    defer state.deinit(std.testing.allocator);
    var decision = try select(std.testing.allocator, policy, &state);
    defer decision.deinit(std.testing.allocator);
    const winner = decision.root().object.get("winner").?.object;
    try std.testing.expectEqualStrings("action", winner.get("kind").?.string);
    try std.testing.expectEqualStrings("A", winner.get("id").?.string);
    try std.testing.expectEqualStrings(
        policy.digest(),
        state.root().object.get("policy_digest").?.string,
    );
}

test "rich EPG cannot author runtime state or self-certify authority" {
    const fixture = @embedFile("fixtures/valid_architectonic_epg.json");
    const injections = [_][]const u8{
        "\"gate\":null,\"revision_summary\"",
        "\"handoff\":{},\"revision_summary\"",
        "\"initial_state\":{},\"revision_summary\"",
        "\"policy_ready\":true,\"revision_summary\"",
        "\"execution_authorized\":true,\"revision_summary\"",
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
                try std.testing.expectEqual(
                    ErrorCode.self_certification_forbidden,
                    report.errors[0].code,
                );
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

test "rich EPG rejects Plan-authored source currentness" {
    const fixture = @embedFile("fixtures/valid_architectonic_epg.json");
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixture,
        "\"locked_decision_refs\": []",
        "\"locked_decision_refs\": [], \"current\": \"yes\"",
    );
    defer std.testing.allocator.free(bytes);

    var result = try compilePolicy(std.testing.allocator, bytes);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => return error.ExpectedCompileRejection,
        .report => |report| {
            var saw_forbidden_currentness = false;
            for (report.errors) |item| {
                if (item.code == .self_certification_forbidden and
                    std.mem.eql(u8, item.path, "$.source.current"))
                {
                    saw_forbidden_currentness = true;
                }
            }
            try std.testing.expect(saw_forbidden_currentness);
        },
    }
}

test "rich EPG accepts architectonic not_required without fabricated seams" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        @embedFile("fixtures/valid_architectonic_epg.json"),
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value.object.getPtr("execution_policy_graph").?;
    const architectonic = root.object.getPtr("architectonic").?;
    architectonic.object.getPtr("mode").?.* = .{ .string = "not_required" };
    architectonic.object.getPtr("reason").?.* = .{
        .string = "One bounded operation inside an unchanged exact boundary.",
    };
    architectonic.object.getPtr("seams").?.array.items.len = 0;

    _ = architectonic.object.orderedRemove("composition");
    _ = architectonic.object.orderedRemove("conceptual_compression");

    const actions = root.object.getPtr("actions").?;
    for (actions.array.items) |*action| {
        inline for ([_][]const u8{
            "architectonic_seam_refs",
            "realizes_factor_refs",
            "retires_factor_refs",
            "preservation_observation_refs",
        }) |key| {
            _ = action.object.orderedRemove(key);
        }
    }
    const revision = root.object.getPtr("revision_summary").?;
    _ = revision.object.orderedRemove("architectonic_changes");
    _ = revision.object.orderedRemove("plan_transport");
    _ = revision.object.orderedRemove("square_results");

    const bytes = try canonical_json.canonicalizeValueAlloc(
        std.testing.allocator,
        parsed.value,
    );
    defer std.testing.allocator.free(bytes);
    var result = try compilePolicy(std.testing.allocator, bytes);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => {},
        .report => |report| {
            std.debug.print("unexpected compile errors: {any}\n", .{report.errors});
            return error.ExpectedCompiledPolicy;
        },
    }
}

fn expectFixtureReplacementRejected(
    needle: []const u8,
    replacement: []const u8,
) !void {
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        @embedFile("fixtures/valid_architectonic_epg.json"),
        needle,
        replacement,
    );
    defer std.testing.allocator.free(bytes);
    var result = try compilePolicy(std.testing.allocator, bytes);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => return error.ExpectedCompileRejection,
        .report => |report| try std.testing.expect(!report.ok()),
    }
}

fn compileFixtureReplacement(
    needle: []const u8,
    replacement: []const u8,
) !CompileResult {
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        @embedFile("fixtures/valid_architectonic_epg.json"),
        needle,
        replacement,
    );
    defer std.testing.allocator.free(bytes);
    return compilePolicy(std.testing.allocator, bytes);
}

fn fixtureState(
    allocator: std.mem.Allocator,
    digest: []const u8,
    atoms_json: []const u8,
    proof_refs_json: []const u8,
) !State {
    const bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"policy_id\":\"compile-demo\",\"revision\":1," ++
            "\"policy_digest\":\"{s}\",\"satisfied_atoms\":{s}," ++
            "\"completed_actions\":[],\"failed_actions\":[]," ++
            "\"proof_refs\":{s},\"potential\":[1]}}",
        .{ digest, atoms_json, proof_refs_json },
    );
    defer allocator.free(bytes);
    return parseState(allocator, bytes);
}

fn expectWinnerKind(decision: *const Decision, kind: []const u8) !void {
    const winner = decision.root().object.get("winner").?.object;
    try std.testing.expectEqualStrings(kind, winner.get("kind").?.string);
}

const nonconsequential_action_json =
    \\{
    \\  "action_id":"B",
    \\  "kind":"inspect",
    \\  "preconditions":{"all":[],"any":[],"none":[]},
    \\  "requires_actions":[],
    \\  "architectonic_seam_refs":[],
    \\  "realizes_factor_refs":[],
    \\  "retires_factor_refs":[],
    \\  "preservation_observation_refs":[],
    \\  "expected_effects":{"facts_added":[],"unknowns_resolved":[],"obligations_closed":[]},
    \\  "expected_observation_refs":[],
    \\  "failure_observation_refs":[],
    \\  "proof_obligations":[],
    \\  "rollback":{"trigger_atoms":[],"action_id":null},
    \\  "utility":{"obligation_reduction":0,"information_gain":1,
    \\    "downstream_unlock":0,"proof_gain":0,"execution_cost":1,
    \\    "irreversible_risk":0,"semantic_surface_growth":0,"rework_risk":0},
    \\  "repeatable":false
    \\}
;

test "rich compiler fails closed on malformed source enums and mappings" {
    const cases = [_]struct {
        needle: []const u8,
        replacement: []const u8,
    }{
        .{
            .needle = "\"policy_version\": \"EPG-v1\"",
            .replacement = "\"policy_version\": \"EPG-v2\"",
        },
        .{ .needle = "\"goal\": {", .replacement = "\"missing_goal\": {" },
        .{ .needle = "\"kind\": \"probe\"", .replacement = "\"kind\": \"mutaet\"" },
        .{ .needle = "\"status\": \"open\"", .replacement = "\"status\": \"opne\"" },
        .{ .needle = "\"urgency\": \"critical\"", .replacement = "\"urgency\": \"critcal\"" },
        .{
            .needle = "\"atom\": \"fact:START\"",
            .replacement = "\"missing_atom\": \"fact:START\"",
        },
        .{ .needle = "\"atom\": \"obs:OBS=ok\"", .replacement = "\"atom\": \"obs:OBS=bad\"" },
        .{
            .needle = "\"observation_refs\": [\n            \"OBS\"\n" ++
                "          ],\n          \"status\": \"open\"",
            .replacement = "\"observation_refs\": [\"MISSING\"],\n" ++
                "          \"status\": \"open\"",
        },
    };
    for (cases) |case| {
        try expectFixtureReplacementRejected(case.needle, case.replacement);
    }
}

test "unsupported explicit version is never reinterpreted as legacy" {
    var result = try compilePolicy(
        std.testing.allocator,
        "{\"policy_version\":\"EPG-v2\",\"policy_id\":\"p\"," ++
            "\"revision\":1,\"declared_atoms\":[],\"actions\":[{\"id\":\"a\"}]," ++
            "\"policy_rules\":[{\"id\":\"r\",\"actions\":[\"a\"]}]}",
    );
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => return error.ExpectedCompileRejection,
        .report => |report| {
            try std.testing.expectEqual(ErrorCode.schema_invalid, report.errors[0].code);
            try std.testing.expectEqualStrings("$.policy_version", report.errors[0].path);
        },
    }
}

test "explicit architectonics permit unrelated unbound actions" {
    const fixture = @embedFile("fixtures/valid_architectonic_epg.json");
    const actions_end = "\n    ],\n    \"policy\": {";
    try std.testing.expect(std.mem.indexOf(u8, fixture, actions_end) != null);
    const inserted = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixture,
        actions_end,
        "," ++ nonconsequential_action_json ++ actions_end,
    );
    defer std.testing.allocator.free(inserted);
    const candidates = "\"candidate_action_ids\": [\n            \"A\"\n          ]";
    try std.testing.expect(std.mem.indexOf(u8, inserted, candidates) != null);
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        inserted,
        candidates,
        "\"candidate_action_ids\": [\"A\", \"B\"]",
    );
    defer std.testing.allocator.free(bytes);
    var result = try compilePolicy(std.testing.allocator, bytes);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => {},
        .report => |report| {
            std.debug.print("unexpected compile errors: {any}\n", .{report.errors});
            return error.ExpectedCompiledPolicy;
        },
    }
}

test "equal policy priorities remain utility ordered" {
    var result = try compileFixtureReplacement(
        "\"rule_id\": \"R-S\",\n          \"priority\": 2",
        "\"rule_id\": \"R-S\",\n          \"priority\": 1",
    );
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => {},
        .report => return error.ExpectedCompiledPolicy,
    }
}

test "underdetermined square compiles only with an observation route" {
    const square =
        \\[
        \\  {"seam_ref":"S","horizontal_before_refs":["A"],
        \\   "vertical_change_refs":["S"],"horizontal_after_refs":["A"],
        \\   "preserved_observation_refs":["OBS"],"result":"underdetermined",
        \\   "falsifier":"The deciding observation is unavailable."}
        \\]
    ;
    var result = try compileFixtureReplacement(
        "\"square_results\": []",
        "\"square_results\": " ++ square,
    );
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => {},
        .report => return error.ExpectedCompiledPolicy,
    }

    const selected_fixture = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        @embedFile("fixtures/valid_architectonic_epg.json"),
        "\"disposition\": \"evidence_conditioned\"",
        "\"disposition\": \"selected\"",
    );
    defer std.testing.allocator.free(selected_fixture);
    const selected_square = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        selected_fixture,
        "\"square_results\": []",
        "\"square_results\": " ++ square,
    );
    defer std.testing.allocator.free(selected_square);
    var rejected = try compilePolicy(std.testing.allocator, selected_square);
    defer rejected.deinit(std.testing.allocator);
    switch (rejected) {
        .policy => return error.ExpectedCompileRejection,
        .report => {},
    }
}

fn compileProofBoundFixture() !CompileResult {
    const proof =
        \\[{"proof_id":"PROOF-A","statement":"Action A is proved.",
        \\"evidence_kind":"command","command_or_evidence":"zig build test",
        \\"artifact_binding":"action"}]
    ;
    const with_action_proof = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        @embedFile("fixtures/valid_architectonic_epg.json"),
        "\"proof_obligations\": []",
        "\"proof_obligations\": " ++ proof,
    );
    defer std.testing.allocator.free(with_action_proof);
    const with_terminal_proof = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        with_action_proof,
        "\"proof_refs\": []",
        "\"proof_refs\": [\"PROOF-A\"]",
    );
    defer std.testing.allocator.free(with_terminal_proof);
    return compilePolicy(std.testing.allocator, with_terminal_proof);
}

fn fixtureReceipt(
    allocator: std.mem.Allocator,
    digest: []const u8,
    observations_json: []const u8,
    proof_refs_json: []const u8,
) !TransitionReceipt {
    const bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"policy_id\":\"compile-demo\",\"revision\":1," ++
            "\"policy_digest\":\"{s}\",\"decision_id\":\"d\"," ++
            "\"action_id\":\"A\",\"result\":\"success\"," ++
            "\"predicted_effects\":[\"unknown:U=resolved\",\"obligation:O=closed\"]," ++
            "\"observed\":{{\"observations\":{s},\"resolved_unknowns\":[\"U\"]," ++
            "\"closed_obligations\":[\"O\"],\"potential\":[0]}}," ++
            "\"state_after\":{{\"state_id\":\"s1\",\"potential\":[0]}}," ++
            "\"proof_refs\":{s}}}",
        .{ digest, observations_json, proof_refs_json },
    );
    defer allocator.free(bytes);
    return parseTransitionReceipt(allocator, bytes);
}

test "rich receipt preserves action observation and proof bindings" {
    var result = try compileProofBoundFixture();
    defer result.deinit(std.testing.allocator);
    const policy = switch (result) {
        .policy => |value| value,
        .report => return error.ExpectedCompiledPolicy,
    };
    var state = try fixtureState(
        std.testing.allocator,
        policy.digest(),
        "[\"fact:START\"]",
        "[]",
    );
    defer state.deinit(std.testing.allocator);
    var decision = try select(std.testing.allocator, policy, &state);
    defer decision.deinit(std.testing.allocator);

    var missing_observation = try fixtureReceipt(
        std.testing.allocator,
        policy.digest(),
        "{}",
        "[\"PROOF-A\"]",
    );
    defer missing_observation.deinit(std.testing.allocator);
    var observation_report = try validateReceipt(
        std.testing.allocator,
        policy,
        &state,
        &decision,
        &missing_observation,
    );
    defer observation_report.deinit(std.testing.allocator);
    try std.testing.expect(!observation_report.ok());

    var wrong_proof = try fixtureReceipt(
        std.testing.allocator,
        policy.digest(),
        "{\"OBS\":\"ok\"}",
        "[\"PROOF-OTHER\"]",
    );
    defer wrong_proof.deinit(std.testing.allocator);
    var proof_report = try validateReceipt(
        std.testing.allocator,
        policy,
        &state,
        &decision,
        &wrong_proof,
    );
    defer proof_report.deinit(std.testing.allocator);
    try std.testing.expect(!proof_report.ok());
}

test "successful proof receipt unlocks proof-bound terminal" {
    var result = try compileProofBoundFixture();
    defer result.deinit(std.testing.allocator);
    const policy = switch (result) {
        .policy => |value| value,
        .report => return error.ExpectedCompiledPolicy,
    };
    const terminal_atoms =
        "[\"unknown:U=resolved\",\"obligation:O=closed\",\"obs:OBS=ok\"]";
    var unproved = try fixtureState(
        std.testing.allocator,
        policy.digest(),
        terminal_atoms,
        "[]",
    );
    defer unproved.deinit(std.testing.allocator);
    var blocked = try select(std.testing.allocator, policy, &unproved);
    defer blocked.deinit(std.testing.allocator);
    try expectWinnerKind(&blocked, "policy_dead_end");

    var initial = try fixtureState(
        std.testing.allocator,
        policy.digest(),
        "[\"fact:START\"]",
        "[]",
    );
    defer initial.deinit(std.testing.allocator);
    var decision = try select(std.testing.allocator, policy, &initial);
    defer decision.deinit(std.testing.allocator);
    var receipt = try fixtureReceipt(
        std.testing.allocator,
        policy.digest(),
        "{\"OBS\":\"ok\"}",
        "[\"PROOF-A\"]",
    );
    defer receipt.deinit(std.testing.allocator);
    var proved = try applyReceipt(
        std.testing.allocator,
        policy,
        &initial,
        &decision,
        &receipt,
        "2026-07-25T00:00:00Z",
    );
    defer proved.deinit(std.testing.allocator);
    var terminal = try select(std.testing.allocator, policy, &proved);
    defer terminal.deinit(std.testing.allocator);
    try expectWinnerKind(&terminal, "terminal");
}

test "runtime selection enforces the compiled action horizon" {
    var result = try compileFixtureReplacement(
        "\"evidence_actions_max\": 1",
        "\"evidence_actions_max\": 0",
    );
    defer result.deinit(std.testing.allocator);
    const policy = switch (result) {
        .policy => |value| value,
        .report => return error.ExpectedCompiledPolicy,
    };
    var state = try fixtureState(
        std.testing.allocator,
        policy.digest(),
        "[\"fact:START\"]",
        "[]",
    );
    defer state.deinit(std.testing.allocator);
    var decision = try select(std.testing.allocator, policy, &state);
    defer decision.deinit(std.testing.allocator);
    try expectWinnerKind(&decision, "policy_dead_end");
}

test "forbidden source state selects its declared response terminal" {
    const forbidden =
        \\[{"forbidden_id":"FORBIDDEN","statement":"Stop here.",
        \\"atom":"custom:forbidden","response_terminal":"success"}]
    ;
    var result = try compileFixtureReplacement(
        "\"forbidden_states\": []",
        "\"forbidden_states\": " ++ forbidden,
    );
    defer result.deinit(std.testing.allocator);
    const policy = switch (result) {
        .policy => |value| value,
        .report => return error.ExpectedCompiledPolicy,
    };
    var state = try fixtureState(
        std.testing.allocator,
        policy.digest(),
        "[\"custom:forbidden\"]",
        "[]",
    );
    defer state.deinit(std.testing.allocator);
    var decision = try select(std.testing.allocator, policy, &state);
    defer decision.deinit(std.testing.allocator);
    try expectWinnerKind(&decision, "terminal");
}

test "rollback shield requires a concrete rollback action" {
    const shield =
        \\{"rules":[{"shield_id":"S","when":{"all":[],"any":[],"none":[]},
        \\"forbids_action_ids":["A"],"forbids_action_kinds":[],
        \\"requires_atoms":[],"response":"rollback","reason":"Rollback A."}]}
    ;
    try expectFixtureReplacementRejected(
        "\"safety_shield\": {\n      \"rules\": []\n    }",
        "\"safety_shield\": " ++ shield,
    );
}

test "compiled rich policy rejects a dangling action outcome" {
    const with_fact = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        @embedFile("fixtures/valid_architectonic_epg.json"),
        "\"fact_id\": \"START\",\n          \"atom\": \"fact:START\"",
        "\"fact_id\": \"START\",\n          \"atom\": \"fact:START\"" ++
            "},{\"fact_id\":\"UNUSED\",\"atom\":\"fact:UNUSED\"",
    );
    defer std.testing.allocator.free(with_fact);
    const with_effect = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        with_fact,
        "\"facts_added\": []",
        "\"facts_added\": [\"UNUSED\"]",
    );
    defer std.testing.allocator.free(with_effect);
    const bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        with_effect,
        "\"expected_observation_refs\": [\n          \"OBS\"\n        ]," ++
            "\n        \"failure_observation_refs\": [\n          \"OBS\"\n        ]",
        "\"expected_observation_refs\": []," ++
            "\n        \"failure_observation_refs\": []",
    );
    defer std.testing.allocator.free(bytes);
    var result = try compilePolicy(std.testing.allocator, bytes);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .policy => return error.ExpectedCompileRejection,
        .report => |report| {
            var saw_dangling = false;
            for (report.errors) |item| {
                if (item.code == .outcome_dangling) saw_dangling = true;
            }
            try std.testing.expect(saw_dangling);
        },
    }
}

fn compileLegacyForAllocationFailure(allocator: std.mem.Allocator) !void {
    var result = compilePolicy(
        allocator,
        "{\"policy_id\":\"p\",\"revision\":1,\"declared_atoms\":[]," ++
            "\"actions\":[{\"id\":\"a\"}]," ++
            "\"policy_rules\":[{\"id\":\"r\",\"actions\":[\"a\"]}]}",
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer result.deinit(allocator);
    switch (result) {
        .policy => {},
        .report => return error.ExpectedCompiledPolicy,
    }
}

test "legacy compiler releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileLegacyForAllocationFailure,
        .{},
    );
}
