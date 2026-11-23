const std = @import("std");
const diag = @import("diag.zig");
const json = @import("json.zig");
const assess = @import("assess.zig");
const receipt = @import("receipt.zig");
const compare = @import("compare.zig");
const render = @import("render.zig");
const verify = @import("verify.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Judgment = @import("documents.zig").Judgment;

const Parts = struct {
    obligations: []const u8 = "",
    runs: []const u8 = "[]",
    records: []const u8 = "[]",
    artifacts: []const u8 = "[]",
    target: []const u8 = "target bytes",
    context: []const u8 = "context bytes",
    evaluator: []const u8 = "evaluator bytes",
    support: []const u8 = "support bytes",
    contract_tail: []const u8 = "",
    evidence_context: ?[]const u8 = null,
    reorder_subject: bool = false,
};

fn digest(text: []const u8) assess.Hex {
    return assess.sha256Hex(text);
}

fn print(arena: Allocator, comptime format: []const u8, arguments: anytype) []const u8 {
    return std.fmt.allocPrint(arena, format, arguments) catch @panic("test allocation");
}

fn artifact(arena: Allocator, id: []const u8, role: []const u8, content: []const u8) []const u8 {
    const format = "{{\"id\":\"{s}\",\"role\":\"{s}\",\"path\":\"{s}.txt\"," ++
        "\"sha256\":\"{s}\",\"size_bytes\":{d}}}";
    return print(arena, format, .{ id, role, id, &digest(content), content.len });
}

fn subjectBytes(arena: Allocator, parts: Parts) []const u8 {
    const target = artifact(arena, "candidate", "target", parts.target);
    const context = artifact(arena, "context", "context", parts.context);
    const evaluator = artifact(arena, "observer", "evaluator", parts.evaluator);
    const support = artifact(arena, "fixture", "support", parts.support);
    const list = if (parts.reorder_subject)
        print(arena, "{s},{s},{s},{s}", .{ support, evaluator, context, target })
    else
        print(arena, "{s},{s},{s},{s}", .{ target, context, evaluator, support });
    return print(arena, "{{\"schema\":\"assay-subject/v1\",\"id\":\"subject\"," ++
        "\"context_artifact\":\"context\",\"artifacts\":[{s}]}}\n", .{list});
}

fn contractBytes(arena: Allocator, parts: Parts) []const u8 {
    return print(arena, "{{\"schema\":\"assay-contract/v1\",\"id\":\"contract/v1\"," ++
        "\"claim_kind\":\"artifact\",\"scope\":\"Bounded finite cases.\"," ++
        "\"context_sha256\":\"{s}\",\"evaluators\":[{{\"id\":\"observer/v1\"," ++
        "\"artifact_id\":\"observer\",\"sha256\":\"{s}\",\"method\":\"Observe.\"}}]," ++
        "\"obligations\":[{s}]{s}}}\n", .{
        &digest(parts.context), &digest(parts.evaluator), parts.obligations, parts.contract_tail,
    });
}

fn evidenceBytes(
    arena: Allocator,
    parts: Parts,
    contract: []const u8,
    subject: []const u8,
) []const u8 {
    const context = parts.evidence_context orelse &digest(parts.context);
    return print(arena, "{{\"schema\":\"assay-evidence/v1\",\"contract_sha256\":\"{s}\"," ++
        "\"subject_sha256\":\"{s}\",\"context_sha256\":\"{s}\",\"runs\":{s}," ++
        "\"records\":{s},\"artifacts\":{s}}}\n", .{
        &digest(contract), &digest(subject), context, parts.runs, parts.records, parts.artifacts,
    });
}

fn sources(arena: Allocator, parts: Parts) assess.Sources {
    const contract = contractBytes(arena, parts);
    const subject = subjectBytes(arena, parts);
    return .{
        .contract = contract,
        .subject = subject,
        .evidence = evidenceBytes(arena, parts, contract, subject),
    };
}

fn obligation(
    arena: Allocator,
    id: []const u8,
    required: bool,
    gates: [2][]const u8,
    check: []const u8,
) []const u8 {
    return print(arena, "{{\"id\":\"{s}\",\"required\":{},\"statement\":\"Holds.\"," ++
        "\"scope\":\"One case.\",\"basis\":\"empirical\",\"evaluator_id\":\"observer/v1\"," ++
        "\"decisive_when\":{{\"supported\":\"{s}\",\"refuted\":\"{s}\"}},\"check\":{s}}}", .{
        id, required, gates[0], gates[1], check,
    });
}

const null_check = "{\"kind\":\"scalar_equal\",\"expected\":null}";
const judged_check = "{\"kind\":\"domain_judgment\",\"qualification\":\"Policy applies.\"}";
const strict = [2][]const u8{ "complete_run", "observation" };
const witness = [2][]const u8{ "observation", "observation" };
const complete_both = [2][]const u8{ "complete_run", "complete_run" };

fn run(arena: Allocator, id: []const u8, outcome: []const u8, reason: []const u8) []const u8 {
    return print(arena, "{{\"id\":\"{s}\",\"evaluator_id\":\"observer/v1\"," ++
        "\"evaluator_sha256\":\"{s}\",\"outcome\":\"{s}\",\"reason\":\"{s}\"}}", .{
        id, &digest("evaluator bytes"), outcome, reason,
    });
}

fn observed(arena: Allocator, id: []const u8, run_id: []const u8, value: []const u8) []const u8 {
    return print(arena, "{{\"obligation_id\":\"{s}\",\"run_id\":\"{s}\",\"status\":\"observed\"," ++
        "\"observation\":{s},\"artifact_ids\":[]}}", .{ id, run_id, value });
}

fn scalarObservation(arena: Allocator, value: []const u8) []const u8 {
    return print(arena, "{{\"kind\":\"scalar\",\"value\":{s}}}", .{value});
}

fn scalarRecord(
    arena: Allocator,
    id: []const u8,
    run_id: []const u8,
    value: []const u8,
) []const u8 {
    return observed(arena, id, run_id, scalarObservation(arena, value));
}

fn scalarCheck(arena: Allocator, expected: []const u8) []const u8 {
    return print(arena, "{{\"kind\":\"scalar_equal\",\"expected\":{s}}}", .{expected});
}

fn list1(arena: Allocator, item: []const u8) []const u8 {
    return print(arena, "[{s}]", .{item});
}

fn judgment(arena: Allocator, value: []const u8) []const u8 {
    return print(arena, "{{\"kind\":\"judgment\",\"judgment\":\"{s}\",\"reason\":\"Rule.\"}}", .{
        value,
    });
}

const Derived = struct { loaded: assess.Loaded, derivation: assess.Derivation };

fn derive(arena: Allocator, input: assess.Sources) !Derived {
    var d: diag.Diagnostic = .{};
    const loaded = assess.load(arena, &d, input) catch |err| {
        std.debug.print("unexpected rejection {s}: {s} at {?s}\n", .{
            @tagName(d.code), d.message(), d.location(),
        });
        return err;
    };
    const result: Derived = .{ .loaded = loaded, .derivation = undefined };
    var owned = result;
    owned.derivation = try assess.derive(arena, &owned.loaded);
    return owned;
}

fn expectRejected(
    arena: Allocator,
    input: assess.Sources,
    code: diag.Code,
    at: ?[]const u8,
) !void {
    var d: diag.Diagnostic = .{};
    try testing.expectError(error.Rejected, assess.load(arena, &d, input));
    testing.expectEqual(code, d.code) catch |err| {
        std.debug.print("got {s}: {s} at {?s}\n", .{
            @tagName(d.code), d.message(), d.location(),
        });
        return err;
    };
    if (at) |location| try testing.expectEqualStrings(location, d.location().?);
}

fn rejects(arena: Allocator, parts: Parts, code: diag.Code, at: ?[]const u8) !void {
    try expectRejected(arena, sources(arena, parts), code, at);
}

fn single(arena: Allocator, gates: [2][]const u8, outcome: []const u8, value: []const u8) Parts {
    return .{
        .obligations = obligation(arena, "case", true, gates, null_check),
        .runs = print(arena, "[{s}]", .{run(arena, "r1", outcome, "Stopped early.")}),
        .records = print(arena, "[{s}]", .{
            observed(arena, "case", "r1", scalarObservation(arena, value)),
        }),
    };
}

fn expectOne(parts: Parts, judgment_value: Judgment, code: assess.ReasonCode) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try derive(arena_state.allocator(), sources(arena_state.allocator(), parts));
    try testing.expectEqual(judgment_value, result.derivation.items[0].judgment);
    try testing.expectEqual(code, result.derivation.items[0].reason_code);
}

test "scalar fidelity keeps null, false, zero, empty, and exact numbers distinct" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectOne(single(arena, witness, "complete", "null"), .supported, .scalar_equal);
    for ([_][]const u8{ "false", "0", "\"\"", "7", "\"null\"" }) |value| {
        try expectOne(single(arena, witness, "complete", value), .refuted, .scalar_unequal);
    }
    const cases = [_]struct { expected: []const u8, actual: []const u8, equal: bool }{
        .{ .expected = "1", .actual = "1.0", .equal = true },
        .{ .expected = "1", .actual = "1e0", .equal = true },
        .{ .expected = "0", .actual = "-0", .equal = true },
        .{ .expected = "9007199254740993", .actual = "9007199254740992", .equal = false },
        .{
            .expected = "123456789012345678901234567890",
            .actual = "1.2345678901234567890123456789e29",
            .equal = true,
        },
        .{ .expected = "1", .actual = "\"1\"", .equal = false },
        .{ .expected = "false", .actual = "0", .equal = false },
        .{ .expected = "\"\\u00e9\"", .actual = "\"\u{e9}\"", .equal = true },
    };
    for (cases) |case| {
        var parts = single(arena, witness, "complete", case.actual);
        const check = scalarCheck(arena, case.expected);
        parts.obligations = obligation(arena, "case", true, witness, check);
        const expected_judgment: Judgment = if (case.equal) .supported else .refuted;
        try expectOne(parts, expected_judgment, if (case.equal) .scalar_equal else .scalar_unequal);
    }
}

const value_at = "/records/0/observation/value";

test "scalar checks reject structured, malformed, and oversized values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "[]", "{}" }) |value| {
        try rejects(arena, single(arena, witness, "complete", value), .invalid_document, value_at);
        var parts = single(arena, witness, "complete", "null");
        parts.obligations = obligation(arena, "case", true, witness, scalarCheck(arena, value));
        try rejects(arena, parts, .invalid_document, "/obligations/0/check/expected");
    }
    var missing = single(arena, witness, "complete", "null");
    missing.records = list1(arena, observed(arena, "case", "r1", "{\"kind\":\"scalar\"}"));
    try rejects(arena, missing, .invalid_document, value_at);
    const at_limit = print(arena, "\"{s}\"", .{&json.repeat('x', 16 * 1024)});
    try expectOne(single(arena, witness, "complete", at_limit), .refuted, .scalar_unequal);
    const above = print(arena, "\"{s}\"", .{&json.repeat('x', 16 * 1024 + 1)});
    try rejects(arena, single(arena, witness, "complete", above), .resource_limit, null);
    const huge = "1e99999999999999999999";
    try rejects(arena, single(arena, witness, "complete", huge), .invalid_document, null);
}

test "completion gates separate execution from judgment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectOne(single(arena, strict, "interrupted", "7"), .refuted, .scalar_unequal);
    try expectOne(single(arena, strict, "interrupted", "null"), .unresolved, .run_incomplete);
    try expectOne(single(arena, strict, "complete", "null"), .supported, .scalar_equal);
    try expectOne(single(arena, strict, "complete", "7"), .refuted, .scalar_unequal);
    try expectOne(single(arena, witness, "interrupted", "null"), .supported, .scalar_equal);
    try expectOne(single(arena, complete_both, "timed_out", "7"), .unresolved, .run_incomplete);
    try expectOne(single(arena, complete_both, "error", "null"), .unresolved, .run_incomplete);
    var parts = single(arena, strict, "interrupted", "null");
    parts.obligations = obligation(arena, "case", true, complete_both, judged_check);
    parts.records = list1(arena, observed(arena, "case", "r1", judgment(arena, "unresolved")));
    try expectOne(parts, .unresolved, .evaluator_unresolved);
    parts.records = list1(arena, observed(arena, "case", "r1", judgment(arena, "refuted")));
    try expectOne(parts, .unresolved, .run_incomplete);
    parts.obligations = obligation(arena, "case", true, witness, judged_check);
    try expectOne(parts, .refuted, .qualified_judgment);
    parts.records = list1(arena, observed(arena, "case", "r1", judgment(arena, "supported")));
    try expectOne(parts, .supported, .qualified_judgment);
    parts.records = list1(arena, scalarRecord(arena, "case", "r1", "null"));
    try rejects(arena, parts, .invalid_document, "/records/0/observation/kind");
}

fn statusRecord(arena: Allocator, status: []const u8, reason: []const u8) []const u8 {
    return print(arena, "[{{\"obligation_id\":\"case\",\"run_id\":\"r1\",\"status\":\"{s}\"," ++
        "\"reason\":\"{s}\",\"artifact_ids\":[]}}]", .{ status, reason });
}

test "missing, skipped, and unavailable observations stay unresolved and distinct" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = single(arena, witness, "complete", "null");
    parts.records = "[]";
    try expectOne(parts, .unresolved, .missing_observation);
    parts.runs = "[]";
    try expectOne(parts, .unresolved, .missing_observation);
    parts = single(arena, witness, "complete", "null");
    parts.records = statusRecord(arena, "skipped", "Case was skipped.");
    try expectOne(parts, .unresolved, .skipped);
    parts.records = statusRecord(arena, "unavailable", "Value was undefined.");
    try expectOne(parts, .unresolved, .unavailable);
    parts.records = statusRecord(arena, "skipped", "");
    try expectRejected(arena, sources(arena, parts), .invalid_document, "/records/0/reason");
    parts.records = print(arena, "[{{\"obligation_id\":\"case\",\"run_id\":\"r1\"," ++
        "\"status\":\"skipped\",\"reason\":\"x\",\"observation\":{s},\"artifact_ids\":[]}}]", .{
        scalarObservation(arena, "null"),
    });
    try expectRejected(arena, sources(arena, parts), .invalid_document, "/records/0/observation");
    parts = single(arena, witness, "timed_out", "null");
    parts.runs = print(arena, "[{s}]", .{run(arena, "r1", "timed_out", "")});
    try expectRejected(arena, sources(arena, parts), .invalid_document, "/runs/0/reason");
}

test "records cannot conflict, duplicate, or reference unknown entities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = single(arena, witness, "complete", "null");
    const runs = print(arena, "[{s},{s}]", .{
        run(arena, "r1", "complete", ""), run(arena, "r2", "complete", ""),
    });
    parts.runs = runs;
    const a = observed(arena, "case", "r1", scalarObservation(arena, "null"));
    const b = observed(arena, "case", "r2", scalarObservation(arena, "7"));
    const duplicated = print(arena, "[{s},{s}]", .{ a, a });
    const conflicting = print(arena, "[{s},{s}]", .{ a, b });
    for ([_][]const u8{ duplicated, conflicting }) |records| {
        parts.records = records;
        try rejects(arena, parts, .conflicting_record, "/records/1/obligation_id");
    }
    parts.records = list1(arena, scalarRecord(arena, "other", "r1", "null"));
    try rejects(arena, parts, .unknown_reference, "/records/0/obligation_id");
    parts.records = list1(arena, scalarRecord(arena, "case", "r9", "null"));
    try rejects(arena, parts, .unknown_reference, "/records/0/run_id");
    parts.runs = print(arena, "[{s},{s}]", .{
        run(arena, "r1", "complete", ""), run(arena, "r1", "complete", ""),
    });
    parts.records = "[]";
    try expectRejected(arena, sources(arena, parts), .duplicate_id, "/runs/1/id");
    parts.runs = runs;
    parts.artifacts = print(arena, "[{{\"id\":\"log\",\"sha256\":\"{s}\",\"size_bytes\":3," ++
        "\"locator\":\"logs/run.txt\",\"description\":\"Raw log.\"}}]", .{&digest("log")});
    const with_refs = "{\"obligation_id\":\"case\",\"run_id\":\"r1\",\"status\":\"observed\"," ++
        "\"observation\":{\"kind\":\"scalar\",\"value\":null},\"artifact_ids\":";
    parts.records = "[" ++ with_refs ++ "[\"log\",\"log\"]}]";
    try expectRejected(arena, sources(arena, parts), .duplicate_id, "/records/0/artifact_ids/1");
    parts.records = "[" ++ with_refs ++ "[\"gone\"]}]";
    try rejects(arena, parts, .unknown_reference, "/records/0/artifact_ids/0");
    parts.records = "[" ++ with_refs ++ "[\"log\"]}]";
    const result = try derive(arena, sources(arena, parts));
    try testing.expectEqual(Judgment.supported, result.derivation.overall);
}

test "aggregation uses required obligations only and never succeeds vacuously" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const obligations = print(arena, "{s},{s},{s}", .{
        obligation(arena, "a", true, witness, null_check),
        obligation(arena, "b", true, witness, null_check),
        obligation(arena, "c", false, witness, null_check),
    });
    const Case = struct { a: ?[]const u8, b: ?[]const u8, c: ?[]const u8, overall: Judgment };
    const cases = [_]Case{
        .{ .a = "null", .b = "null", .c = "7", .overall = .supported },
        .{ .a = "7", .b = null, .c = "null", .overall = .refuted },
        .{ .a = null, .b = "null", .c = "null", .overall = .unresolved },
        .{ .a = null, .b = null, .c = null, .overall = .unresolved },
    };
    for (cases) |case| {
        var records: std.ArrayList(u8) = .empty;
        try records.append(arena, '[');
        for ([_]?[]const u8{ case.a, case.b, case.c }, [_][]const u8{ "a", "b", "c" }) |value, id| {
            const present = value orelse continue;
            if (records.items.len > 1) try records.append(arena, ',');
            try records.appendSlice(arena, scalarRecord(arena, id, "r1", present));
        }
        try records.append(arena, ']');
        const result = try derive(arena, sources(arena, .{
            .obligations = obligations,
            .runs = print(arena, "[{s}]", .{run(arena, "r1", "complete", "")}),
            .records = records.items,
        }));
        try testing.expectEqual(case.overall, result.derivation.overall);
    }
    const only_optional = obligation(arena, "a", false, witness, null_check);
    try rejects(arena, .{ .obligations = only_optional }, .invalid_document, "/obligations");
    try rejects(arena, .{ .obligations = "" }, .invalid_document, "/obligations");
}

test "documents are closed, typed, and reference-checked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = single(arena, witness, "complete", "null");
    var parts = base;
    const misspelled = "{\"kind\":\"scalar_equal\",\"expect\":null}";
    parts.obligations = obligation(arena, "case", true, witness, misspelled);
    try rejects(arena, parts, .invalid_document, "/obligations/0/check/expect");
    parts = base;
    parts.contract_tail = ",\"extra\":1";
    try expectRejected(arena, sources(arena, parts), .invalid_document, "/extra");
    parts.contract_tail = ",\"scope\":\"again\"";
    try expectRejected(arena, sources(arena, parts), .duplicate_key, "/scope");
    parts = base;
    parts.obligations = print(arena, "{s},{s}", .{ base.obligations, base.obligations });
    try expectRejected(arena, sources(arena, parts), .duplicate_id, "/obligations/1/id");
    parts = base;
    parts.obligations = replace(arena, base.obligations, "observer/v1", "ghost");
    try rejects(arena, parts, .unknown_reference, "/obligations/0/evaluator_id");
    parts = base;
    parts.obligations = replace(arena, base.obligations, "\"Holds.\"", "\"\"");
    try expectRejected(arena, sources(arena, parts), .invalid_document, "/obligations/0/statement");
    var input = sources(arena, base);
    input.contract = replace(arena, input.contract, "assay-contract/v1", "assay-contract/v2");
    try expectRejected(arena, input, .unsupported_schema, "/schema");
    input = sources(arena, base);
    input.subject = replace(arena, input.subject, "\"support\"", "\"context\"");
    try expectRejected(arena, input, .invalid_document, "/artifacts");
    input = sources(arena, base);
    input.subject = replace(arena, input.subject, "fixture.txt", "../fixture.txt");
    try expectRejected(arena, input, .invalid_document, "/artifacts/3/path");
}

test "raw identities bind exact bytes and every declared relationship" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = single(arena, witness, "complete", "null");
    const valid = sources(arena, base);
    const first = try derive(arena, valid);
    var input = valid;
    input.contract = valid.contract[0 .. valid.contract.len - 1];
    try expectRejected(arena, input, .identity_mismatch, "/contract_sha256");
    input = valid;
    input.subject = print(arena, "{s} ", .{valid.subject});
    try expectRejected(arena, input, .identity_mismatch, "/subject_sha256");
    var parts = base;
    parts.reorder_subject = true;
    const reordered = try derive(arena, sources(arena, parts));
    const before = &first.loaded;
    const after = &reordered.loaded;
    try testing.expect(!std.mem.eql(u8, &before.subject_sha256, &after.subject_sha256));
    try testing.expect(!std.mem.eql(u8, &before.assessment_id, &after.assessment_id));
    parts = base;
    parts.evidence_context = &digest("other context");
    try expectRejected(arena, sources(arena, parts), .identity_mismatch, "/context_sha256");
    input = valid;
    input.subject = replace(arena, valid.subject, &digest("context bytes"), &digest("drift"));
    input.evidence = evidenceBytes(arena, base, input.contract, input.subject);
    try expectRejected(arena, input, .identity_mismatch, "/context_sha256");
    input = valid;
    input.subject = replace(arena, valid.subject, &digest("evaluator bytes"), &digest("drift"));
    input.evidence = evidenceBytes(arena, base, input.contract, input.subject);
    try expectRejected(arena, input, .identity_mismatch, "/evaluators/0/sha256");
    parts = base;
    parts.runs = list1(arena, runWithEvaluator(arena, "drift"));
    try rejects(arena, parts, .identity_mismatch, "/runs/0/evaluator_sha256");
}

test "a record must come from the obligation's evaluator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = single(arena, witness, "complete", "null");
    const input = sources(arena, parts);
    const second = print(arena, "\"method\":\"Observe.\"}},{{\"id\":\"other/v1\"," ++
        "\"artifact_id\":\"observer\",\"sha256\":\"{s}\",\"method\":\"Other.\"}}]", .{
        &digest("evaluator bytes"),
    });
    const contract = replace(arena, input.contract, "\"method\":\"Observe.\"}]", second);
    const other_run = replace(arena, run(arena, "r1", "complete", ""), "observer/v1", "other/v1");
    parts.runs = print(arena, "[{s}]", .{other_run});
    var mismatched = sources(arena, parts);
    mismatched.contract = contract;
    mismatched.evidence = evidenceBytes(arena, parts, contract, mismatched.subject);
    try expectRejected(arena, mismatched, .identity_mismatch, "/records/0/run_id");
}

fn receiptBytes(arena: Allocator, result: *const Derived, checked: verify.Verification) []const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    render.assessment(
        &output.writer,
        .{ .version = "0.1.0" },
        &result.loaded,
        result.derivation,
        checked,
    ) catch @panic("render");
    return output.written();
}

fn expectReceiptRejected(
    arena: Allocator,
    bytes: []const u8,
    code: diag.Code,
    at: ?[]const u8,
) !void {
    var d: diag.Diagnostic = .{};
    try testing.expectError(error.Rejected, receipt.check(arena, &d, bytes, "assessment"));
    testing.expectEqual(code, d.code) catch |err| {
        std.debug.print("got {s}: {s} at {?s}\n", .{
            @tagName(d.code), d.message(), d.location(),
        });
        return err;
    };
    if (at) |location| try testing.expectEqualStrings(location, d.location().?);
}

fn replace(arena: Allocator, bytes: []const u8, old: []const u8, new: []const u8) []const u8 {
    std.debug.assert(std.mem.count(u8, bytes, old) == 1);
    return std.mem.replaceOwned(u8, arena, bytes, old, new) catch @panic("replace");
}

fn runWithEvaluator(arena: Allocator, content: []const u8) []const u8 {
    const original = run(arena, "r1", "complete", "");
    return replace(arena, original, &digest("evaluator bytes"), &digest(content));
}

const Alteration = struct {
    old: []const u8,
    new: []const u8,
    code: diag.Code = .receipt_mismatch,
    at: ?[]const u8,
};

const alterations = [_]Alteration{
    .{
        .old = "\"overall\":\"refuted\"",
        .new = "\"overall\":\"supported\"",
        .at = "/derivation/overall",
    },
    .{
        .old = "\"required_refuted\":1",
        .new = "\"required_refuted\":0",
        .at = "/derivation/counts",
    },
    .{
        .old = "\"reason_code\":\"scalar_unequal\"",
        .new = "\"reason_code\":\"run_incomplete\"",
        .at = "/derivation/obligations",
    },
    .{
        .old = "Stopped early.",
        .new = "Stopped later.",
        .at = "/assessment_id",
    },
    .{
        .old = "\"kernel\":\"assay-kernel/v1\"}",
        .new = "\"kernel\":\"assay-kernel/v2\"}",
        .code = .unsupported_schema,
        .at = "/producer/kernel",
    },
    .{
        .old = "\"files_checked\":0",
        .new = "\"files_checked\":4",
        .at = "/verification/subject_bytes",
    },
    .{
        .old = "\"schema\":\"assay-assessment/v1\"",
        .new = "\"schema\":\"assay-assessment/v1\",\"schema\":\"assay-assessment/v1\"",
        .code = .duplicate_key,
        .at = "/schema",
    },
};

test "receipts recover exact inputs and reject altered derivations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = single(arena, strict, "interrupted", "7");
    parts.contract_tail = "";
    const input = sources(arena, parts);
    const odd_scope = "\"Bounded \\u0066inite\\ncases \u{e9}.\"";
    const odd_contract = replace(arena, input.contract, "\"Bounded finite cases.\"", odd_scope);
    var exotic = input;
    exotic.contract = odd_contract;
    exotic.evidence = evidenceBytes(arena, parts, odd_contract, input.subject);
    const result = try derive(arena, exotic);
    const bytes = receiptBytes(arena, &result, .{});
    var d: diag.Diagnostic = .{};
    const checked = try receipt.check(arena, &d, bytes, "assessment");
    try testing.expectEqualStrings(exotic.contract, checked.loaded.sources.contract);
    try testing.expectEqualStrings(exotic.subject, checked.loaded.sources.subject);
    try testing.expectEqualStrings(exotic.evidence, checked.loaded.sources.evidence);
    try testing.expectEqual(Judgment.refuted, checked.derivation.overall);
    for (alterations) |alteration| {
        const altered = replace(arena, bytes, alteration.old, alteration.new);
        try expectReceiptRejected(arena, altered, alteration.code, alteration.at);
    }
    const evidence_sha256 = &result.loaded.evidence_sha256;
    const evidence_hash = print(arena, "\"evidence_sha256\":\"{s}\"", .{evidence_sha256});
    const zeros = "\"evidence_sha256\":\"" ++ &json.repeat('0', 64) ++ "\"";
    const zeroed = replace(arena, bytes, evidence_hash, zeros);
    try expectReceiptRejected(arena, zeroed, .receipt_mismatch, "/derivation/evidence_sha256");
    try expectReceiptRejected(arena, bytes[0 .. bytes.len / 2], .invalid_json, null);
    const respelled = replace(arena, bytes, "\"required_refuted\":1", "\"required_refuted\":1.0e0");
    _ = try receipt.check(arena, &d, respelled, "assessment");
}

test "recorded verification is retained only as an unauthenticated claim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try derive(arena, sources(arena, single(arena, witness, "complete", "null")));
    const declared = result.loaded.subject.bytesDeclared();
    const claimed = receiptBytes(arena, &result, .{
        .status = .matched_manifest_during_this_invocation,
        .files_checked = 4,
        .bytes_read = declared,
    });
    var d: diag.Diagnostic = .{};
    const checked = try receipt.check(arena, &d, claimed, "assessment");
    const matched = verify.Status.matched_manifest_during_this_invocation;
    try testing.expectEqual(matched, checked.recorded.status);
    var output: std.Io.Writer.Allocating = .init(arena);
    try render.explanation(&output.writer, &checked);
    const explanation = try json.parse(arena, output.written(), &d, "explanation");
    const subject_bytes = explanation.object.get("subject_bytes").?.string;
    try testing.expectEqualStrings("not_reverified", subject_bytes);
    const recorded = explanation.object.get("recorded_verification").?.object;
    try testing.expectEqualStrings("unauthenticated_receipt_claim", recorded.get("trust").?.string);
    const plain = receiptBytes(arena, &result, .{});
    const other = try receipt.check(arena, &d, plain, "assessment");
    const left = try json.parse(arena, plain, &d, "a");
    const right = try json.parse(arena, plain, &d, "b");
    try testing.expect(try receipt.sameValue(arena, left, right));
    try testing.expectEqualSlices(u8, &other.loaded.assessment_id, &checked.loaded.assessment_id);
}

fn verified(arena: Allocator, parts: Parts) !receipt.Verified {
    const result = try derive(arena, sources(arena, parts));
    var d: diag.Diagnostic = .{};
    return receipt.check(arena, &d, receiptBytes(arena, &result, .{}), "assessment");
}

fn twoCaseParts(arena: Allocator, a: []const u8, b: []const u8) Parts {
    return .{
        .obligations = print(arena, "{s},{s}", .{
            obligation(arena, "a", true, witness, null_check),
            obligation(arena, "b", true, witness, null_check),
        }),
        .runs = print(arena, "[{s}]", .{run(arena, "r1", "complete", "")}),
        .records = print(arena, "[{s},{s}]", .{
            observed(arena, "a", "r1", scalarObservation(arena, a)),
            observed(arena, "b", "r1", scalarObservation(arena, b)),
        }),
    };
}

test "comparison reports transitions and lost preservation behind equal counts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const baseline = try verified(arena, twoCaseParts(arena, "null", "7"));
    var candidate_parts = twoCaseParts(arena, "7", "null");
    candidate_parts.target = "repaired target bytes";
    const candidate = try verified(arena, candidate_parts);
    try testing.expectEqual(baseline.derivation.counts, candidate.derivation.counts);
    const result = try compare.compare(arena, &baseline, &candidate);
    try testing.expect(result.comparable());
    try testing.expectEqual(compare.TransitionKind.lost_support, result.transitions[0].kind);
    try testing.expectEqual(compare.TransitionKind.gained_support, result.transitions[1].kind);
    try testing.expectEqual(compare.Preservation.refuted, result.preservation);
    const same = try compare.compare(arena, &baseline, &baseline);
    try testing.expectEqual(compare.Preservation.supported, same.preservation);
    try testing.expectEqual(compare.TransitionKind.unchanged, same.transitions[1].kind);
    const unresolved = try verified(arena, .{
        .obligations = twoCaseParts(arena, "null", "null").obligations,
        .runs = "[]",
        .records = "[]",
    });
    const lost = try compare.compare(arena, &baseline, &unresolved);
    try testing.expectEqual(compare.Preservation.unresolved, lost.preservation);
    const gained = try compare.compare(arena, &unresolved, &baseline);
    try testing.expectEqual(compare.Preservation.no_baseline_support, gained.preservation);
}

test "comparison refuses to align different contracts, contexts, or controls" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Code = compare.IncompatibilityCode;
    const base = twoCaseParts(arena, "null", "null");
    const baseline = try verified(arena, base);
    var parts = base;
    parts.obligations = print(arena, "{s}", .{obligation(arena, "a", true, witness, null_check)});
    parts.records = list1(arena, scalarRecord(arena, "a", "r1", "null"));
    const changed_contract = try verified(arena, parts);
    var result = try compare.compare(arena, &baseline, &changed_contract);
    try testing.expect(!result.comparable());
    try testing.expectEqual(Code.contract_changed, result.incompatibilities[0].code);
    try testing.expectEqual(@as(usize, 0), result.transitions.len);
    try testing.expectEqual(compare.Preservation.not_comparable, result.preservation);
    parts = base;
    parts.context = "other context";
    result = try compare.compare(arena, &baseline, &(try verified(arena, parts)));
    try testing.expectEqual(@as(usize, 3), result.incompatibilities.len);
    try testing.expectEqual(Code.context_changed, result.incompatibilities[1].code);
    try testing.expectEqualStrings("context", result.incompatibilities[2].artifact_ids[0]);
    parts = base;
    parts.support = "other support";
    result = try compare.compare(arena, &baseline, &(try verified(arena, parts)));
    try testing.expectEqual(@as(usize, 1), result.incompatibilities.len);
    try testing.expectEqual(Code.support_artifacts_changed, result.incompatibilities[0].code);
    try testing.expectEqualStrings("fixture", result.incompatibilities[0].artifact_ids[0]);
    parts = base;
    parts.evaluator = "other evaluator";
    parts.runs = list1(arena, runWithEvaluator(arena, "other evaluator"));
    result = try compare.compare(arena, &baseline, &(try verified(arena, parts)));
    try testing.expectEqual(Code.contract_changed, result.incompatibilities[0].code);
    try testing.expectEqualStrings("observer", result.incompatibilities[1].artifact_ids[0]);
    parts = base;
    parts.target = "different target";
    const different_target = try verified(arena, parts);
    try testing.expect((try compare.compare(arena, &baseline, &different_target)).comparable());
}
