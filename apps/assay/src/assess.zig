const std = @import("std");
const diag = @import("diag.zig");
const json = @import("json.zig");
const documents = @import("documents.zig");

const Allocator = std.mem.Allocator;
const Diagnostic = diag.Diagnostic;
const Judgment = documents.Judgment;
const Gate = documents.Gate;

pub const kernel = "assay-kernel/v1";
pub const Hex = [64]u8;

pub fn sha256Hex(bytes: []const u8) Hex {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn assessmentId(contract: Hex, subject: Hex, evidence: Hex) Hex {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(kernel ++ "\ncontract=");
    hasher.update(&contract);
    hasher.update("\nsubject=");
    hasher.update(&subject);
    hasher.update("\nevidence=");
    hasher.update(&evidence);
    hasher.update("\n");
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub const Sources = struct {
    contract: []const u8,
    subject: []const u8,
    evidence: []const u8,
};

pub const Loaded = struct {
    sources: Sources,
    contract: documents.Contract,
    subject: documents.Subject,
    evidence: documents.Evidence,
    contract_sha256: Hex,
    subject_sha256: Hex,
    evidence_sha256: Hex,
    assessment_id: Hex,
};

pub fn load(arena: Allocator, d: *Diagnostic, sources: Sources) diag.Error!Loaded {
    const contract_sha256 = sha256Hex(sources.contract);
    const subject_sha256 = sha256Hex(sources.subject);
    const evidence_sha256 = sha256Hex(sources.evidence);
    const contract_value = try json.parse(arena, sources.contract, d, "contract");
    const contract = try documents.decodeContract(arena, d, &contract_value);
    const subject_value = try json.parse(arena, sources.subject, d, "subject");
    const subject = try documents.decodeSubject(arena, d, &subject_value);
    const evidence_value = try json.parse(arena, sources.evidence, d, "evidence");
    const evidence = try documents.decodeEvidence(arena, d, &evidence_value, contract, .{
        .contract_sha256 = &contract_sha256,
        .subject_sha256 = &subject_sha256,
    });
    try documents.bindContractToSubject(d, contract, subject);
    return .{
        .sources = sources,
        .contract = contract,
        .subject = subject,
        .evidence = evidence,
        .contract_sha256 = contract_sha256,
        .subject_sha256 = subject_sha256,
        .evidence_sha256 = evidence_sha256,
        .assessment_id = assessmentId(contract_sha256, subject_sha256, evidence_sha256),
    };
}

pub const ReasonCode = enum {
    scalar_equal,
    scalar_unequal,
    qualified_judgment,
    evaluator_unresolved,
    missing_observation,
    skipped,
    unavailable,
    run_incomplete,
};

pub const Derived = struct {
    obligation: u32,
    judgment: Judgment,
    reason_code: ReasonCode,
    record: ?u32,
    completion_gate: ?Gate,
};

pub const Counts = struct {
    required_supported: u32 = 0,
    required_refuted: u32 = 0,
    required_unresolved: u32 = 0,
    optional_supported: u32 = 0,
    optional_refuted: u32 = 0,
    optional_unresolved: u32 = 0,
};

pub const Derivation = struct {
    items: []const Derived,
    overall: Judgment,
    counts: Counts,
    run_outcomes: std.enums.EnumArray(documents.Outcome, u32),
};

pub fn derive(arena: Allocator, loaded: *const Loaded) error{OutOfMemory}!Derivation {
    const obligations = loaded.contract.obligations;
    const items = try arena.alloc(Derived, obligations.len);
    var counts: Counts = .{};
    for (obligations, items, 0..) |obligation, *item, index| {
        item.* = deriveOne(loaded, @intCast(index));
        const slot = switch (item.judgment) {
            .supported => if (obligation.required)
                &counts.required_supported
            else
                &counts.optional_supported,
            .refuted => if (obligation.required)
                &counts.required_refuted
            else
                &counts.optional_refuted,
            .unresolved => if (obligation.required)
                &counts.required_unresolved
            else
                &counts.optional_unresolved,
        };
        slot.* += 1;
    }
    var outcomes: std.enums.EnumArray(documents.Outcome, u32) = .initFill(0);
    for (loaded.evidence.runs) |run| outcomes.getPtr(run.outcome).* += 1;
    const overall: Judgment = if (counts.required_refuted > 0)
        .refuted
    else if (counts.required_unresolved > 0)
        .unresolved
    else
        .supported;
    std.debug.assert(overall != .supported or counts.required_supported > 0);
    return .{ .items = items, .overall = overall, .counts = counts, .run_outcomes = outcomes };
}

fn deriveOne(loaded: *const Loaded, index: u32) Derived {
    const obligation = loaded.contract.obligations[index];
    const unresolved: Derived = .{
        .obligation = index,
        .judgment = .unresolved,
        .reason_code = .missing_observation,
        .record = null,
        .completion_gate = null,
    };
    const record_index = loaded.evidence.record_by_obligation[index] orelse return unresolved;
    const record = loaded.evidence.records[record_index];
    var result = unresolved;
    result.record = record_index;
    const observation = record.observation orelse {
        result.reason_code = if (record.status == .skipped) .skipped else .unavailable;
        return result;
    };
    const proposal: Judgment, const native: ReasonCode = switch (observation) {
        .scalar => |actual| if (actual.eql(obligation.check.scalar_equal))
            .{ .supported, .scalar_equal }
        else
            .{ .refuted, .scalar_unequal },
        .judgment => |value| .{ value.judgment, .qualified_judgment },
    };
    if (proposal == .unresolved) {
        result.reason_code = .evaluator_unresolved;
        return result;
    }
    const gate = if (proposal == .supported) obligation.supported_gate else obligation.refuted_gate;
    const outcome = loaded.evidence.runs[record.run].outcome;
    result.completion_gate = gate;
    if (gate == .complete_run and outcome != .complete) {
        result.reason_code = .run_incomplete;
        return result;
    }
    result.judgment = proposal;
    result.reason_code = native;
    return result;
}

test "assessment identity framing matches the published derivation" {
    const zero: Hex = @splat('0');
    const id = assessmentId(zero, zero, zero);
    const expected = sha256Hex("assay-kernel/v1\ncontract=" ++ zero ++ "\nsubject=" ++
        zero ++ "\nevidence=" ++ zero ++ "\n");
    try std.testing.expectEqualSlices(u8, &expected, &id);
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &sha256Hex(""),
    );
}
