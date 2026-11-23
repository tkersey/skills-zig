const std = @import("std");
const limits = @import("limits.zig");
const diag = @import("diag.zig");
const json = @import("json.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Loc = diag.Loc;
const Diagnostic = diag.Diagnostic;
const Fields = json.Fields;
pub const Scalar = json.Scalar;

pub const ClaimKind = enum { artifact, repair, procedure };
pub const Basis = enum { empirical, structural, qualified_judgment };
pub const Gate = enum { observation, complete_run };
pub const Role = enum { target, context, evaluator, support };
pub const Outcome = enum { complete, interrupted, timed_out, @"error" };
pub const Judgment = enum { supported, refuted, unresolved };
pub const Status = enum { observed, skipped, unavailable };

pub const Check = union(enum) {
    scalar_equal: Scalar,
    domain_judgment: []const u8,
};

pub const Evaluator = struct {
    id: []const u8,
    artifact_id: []const u8,
    sha256: []const u8,
    method: []const u8,
};

pub const Obligation = struct {
    id: []const u8,
    required: bool,
    statement: []const u8,
    scope: []const u8,
    basis: Basis,
    evaluator: u32,
    supported_gate: Gate,
    refuted_gate: Gate,
    check: Check,
};

pub const Contract = struct {
    id: []const u8,
    claim_kind: ClaimKind,
    scope: []const u8,
    context_sha256: []const u8,
    evaluators: []const Evaluator,
    obligations: []const Obligation,
    evaluator_ids: IdSet,
    obligation_ids: IdSet,
};

pub const Artifact = struct {
    id: []const u8,
    role: Role,
    path: []const u8,
    sha256: []const u8,
    size_bytes: u64,
};

pub const Subject = struct {
    id: []const u8,
    context: u32,
    artifacts: []const Artifact,
    artifact_ids: IdSet,

    pub fn find(self: Subject, id: []const u8) ?u32 {
        return self.artifact_ids.get(id);
    }

    pub fn bytesDeclared(self: Subject) u64 {
        var total: u64 = 0;
        for (self.artifacts) |artifact| total += artifact.size_bytes;
        return total;
    }
};

pub const Run = struct {
    id: []const u8,
    evaluator_id: []const u8,
    evaluator_sha256: []const u8,
    outcome: Outcome,
    reason: []const u8,
};

pub const Observation = union(enum) {
    scalar: Scalar,
    judgment: struct { judgment: Judgment, reason: []const u8 },
};

pub const Record = struct {
    obligation: u32,
    run: u32,
    status: Status,
    observation: ?Observation,
    reason: ?[]const u8,
};

pub const EvidenceArtifact = struct {
    id: []const u8,
    sha256: []const u8,
    size_bytes: u64,
    locator: []const u8,
    description: []const u8,
};

pub const Evidence = struct {
    runs: []const Run,
    records: []const Record,
    artifacts: []const EvidenceArtifact,
    record_by_obligation: []const ?u32,
};

pub const IdSet = std.StringHashMapUnmanaged(u32);

fn claim(
    arena: Allocator,
    set: *IdSet,
    fields: Fields,
    id: []const u8,
    index: usize,
) diag.Error!void {
    const entry = try set.getOrPut(arena, id);
    if (entry.found_existing) {
        return fields.reject(.duplicate_id, "id", "duplicate identifier {s}", .{id});
    }
    entry.value_ptr.* = @intCast(index);
}

pub fn decodeContract(arena: Allocator, d: *Diagnostic, root: *const Value) diag.Error!Contract {
    const fields = try Fields.document(d, "contract", root, "assay-contract/v1", &.{
        "schema", "id", "claim_kind", "scope", "context_sha256", "evaluators", "obligations",
    });
    var evaluator_ids: IdSet = .empty;
    const evaluators = try decodeEvaluators(arena, fields, &evaluator_ids);
    var obligation_ids: IdSet = .empty;
    return .{
        .id = try fields.identifier("id"),
        .claim_kind = try fields.enumeration(ClaimKind, "claim_kind"),
        .scope = try fields.text("scope", limits.text_bytes_max, true),
        .context_sha256 = try fields.digest("context_sha256"),
        .evaluators = evaluators,
        .obligations = try decodeObligations(arena, fields, &evaluator_ids, &obligation_ids),
        .evaluator_ids = evaluator_ids,
        .obligation_ids = obligation_ids,
    };
}

fn decodeEvaluators(arena: Allocator, parent: Fields, ids: *IdSet) diag.Error![]Evaluator {
    const items = try parent.array("evaluators", limits.evaluators_max);
    const result = try arena.alloc(Evaluator, items.len);
    const list_loc = parent.loc.key("evaluators");
    for (items, result, 0..) |*item, *evaluator, index| {
        const loc = list_loc.index(index);
        const fields = try Fields.of(parent.d, parent.role, &loc, item);
        try fields.closed(&.{ "id", "artifact_id", "sha256", "method" });
        evaluator.* = .{
            .id = try fields.identifier("id"),
            .artifact_id = try fields.identifier("artifact_id"),
            .sha256 = try fields.digest("sha256"),
            .method = try fields.text("method", limits.text_bytes_max, true),
        };
        try claim(arena, ids, fields, evaluator.id, index);
    }
    return result;
}

fn decodeObligations(
    arena: Allocator,
    parent: Fields,
    evaluators: *const IdSet,
    ids: *IdSet,
) ![]Obligation {
    const items = try parent.array("obligations", limits.obligations_max);
    const result = try arena.alloc(Obligation, items.len);
    const list_loc = parent.loc.key("obligations");
    var required_count: usize = 0;
    for (items, result, 0..) |*item, *obligation, index| {
        const loc = list_loc.index(index);
        obligation.* = try decodeObligation(parent.d, parent.role, &loc, item, evaluators);
        const fields = try Fields.of(parent.d, parent.role, &loc, item);
        try claim(arena, ids, fields, obligation.id, index);
        required_count += @intFromBool(obligation.required);
    }
    if (required_count == 0) {
        return parent.reject(
            .invalid_document,
            "obligations",
            "a required obligation is needed",
            .{},
        );
    }
    return result;
}

fn decodeObligation(
    d: *Diagnostic,
    role: []const u8,
    loc: *const Loc,
    item: *const Value,
    evaluators: *const IdSet,
) diag.Error!Obligation {
    const fields = try Fields.of(d, role, loc, item);
    try fields.closed(&.{
        "id",           "required",      "statement", "scope", "basis",
        "evaluator_id", "decisive_when", "check",
    });
    const evaluator_id = try fields.identifier("evaluator_id");
    const evaluator = evaluators.get(evaluator_id) orelse {
        return fields.reject(.unknown_reference, "evaluator_id", "unknown evaluator {s}", .{
            evaluator_id,
        });
    };
    var gate_loc: Loc = undefined;
    const gates = try fields.object("decisive_when", &gate_loc);
    try gates.closed(&.{ "supported", "refuted" });
    return .{
        .id = try fields.identifier("id"),
        .required = try fields.boolean("required"),
        .statement = try fields.text("statement", limits.text_bytes_max, true),
        .scope = try fields.text("scope", limits.text_bytes_max, true),
        .basis = try fields.enumeration(Basis, "basis"),
        .evaluator = evaluator,
        .supported_gate = try gates.enumeration(Gate, "supported"),
        .refuted_gate = try gates.enumeration(Gate, "refuted"),
        .check = try decodeCheck(fields),
    };
}

fn decodeCheck(parent: Fields) diag.Error!Check {
    var loc: Loc = undefined;
    const fields = try parent.object("check", &loc);
    const kind = try fields.enumeration(std.meta.Tag(Check), "kind");
    switch (kind) {
        .scalar_equal => {
            try fields.closed(&.{ "kind", "expected" });
            return .{ .scalar_equal = try fields.scalar("expected") };
        },
        .domain_judgment => {
            try fields.closed(&.{ "kind", "qualification" });
            return .{
                .domain_judgment = try fields.text("qualification", limits.text_bytes_max, false),
            };
        },
    }
}

pub fn decodeSubject(arena: Allocator, d: *Diagnostic, root: *const Value) diag.Error!Subject {
    const fields = try Fields.document(d, "subject", root, "assay-subject/v1", &.{
        "schema", "id", "context_artifact", "artifacts",
    });
    const id = try fields.identifier("id");
    var artifact_ids: IdSet = .empty;
    const artifacts = try decodeArtifacts(arena, fields, &artifact_ids);
    const context_id = try fields.identifier("context_artifact");
    var context: ?u32 = null;
    var targets: usize = 0;
    for (artifacts, 0..) |artifact, index| {
        targets += @intFromBool(artifact.role == .target);
        if (artifact.role != .context) continue;
        if (context != null) {
            return fields.reject(
                .invalid_document,
                "artifacts",
                "exactly one context required",
                .{},
            );
        }
        context = @intCast(index);
    }
    if (targets == 0) {
        return fields.reject(.invalid_document, "artifacts", "a target artifact is required", .{});
    }
    const subject: Subject = .{ .id = id, .context = context orelse {
        return fields.reject(.invalid_document, "artifacts", "exactly one context required", .{});
    }, .artifacts = artifacts, .artifact_ids = artifact_ids };
    const named = subject.find(context_id) orelse {
        return fields.reject(.unknown_reference, "context_artifact", "unknown artifact {s}", .{
            context_id,
        });
    };
    if (named != subject.context) {
        return fields.reject(.invalid_document, "context_artifact", "role context required", .{});
    }
    return subject;
}

fn decodeArtifacts(arena: Allocator, parent: Fields, ids: *IdSet) diag.Error![]Artifact {
    const items = try parent.array("artifacts", limits.subject_artifacts_max);
    const result = try arena.alloc(Artifact, items.len);
    const list_loc = parent.loc.key("artifacts");
    var paths: IdSet = .empty;
    var total: u64 = 0;
    for (items, result, 0..) |*item, *artifact, index| {
        const loc = list_loc.index(index);
        const fields = try Fields.of(parent.d, parent.role, &loc, item);
        try fields.closed(&.{ "id", "role", "path", "sha256", "size_bytes" });
        artifact.* = .{
            .id = try fields.identifier("id"),
            .role = try fields.enumeration(Role, "role"),
            .path = try fields.text("path", limits.path_bytes_max, true),
            .sha256 = try fields.digest("sha256"),
            .size_bytes = try fields.count("size_bytes", limits.artifact_bytes_max),
        };
        if (!isRelativePath(artifact.path)) {
            return fields.reject(.invalid_document, "path", "relative POSIX path required", .{});
        }
        try claim(arena, ids, fields, artifact.id, index);
        const path_entry = try paths.getOrPut(arena, artifact.path);
        if (path_entry.found_existing) {
            return fields.reject(.invalid_document, "path", "duplicate artifact path", .{});
        }
        total += artifact.size_bytes;
        if (total > limits.artifacts_bytes_max) {
            return fields.reject(.resource_limit, "size_bytes", "aggregate exceeds {d} bytes", .{
                limits.artifacts_bytes_max,
            });
        }
    }
    return result;
}

pub fn isRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > limits.path_bytes_max) return false;
    if (path[0] == '/' or path[path.len - 1] == '/') return false;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return false;
    if (std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

pub const Raw = struct {
    contract_sha256: []const u8,
    subject_sha256: []const u8,
};

pub fn decodeEvidence(
    arena: Allocator,
    d: *Diagnostic,
    root: *const Value,
    contract: Contract,
    raw: Raw,
) diag.Error!Evidence {
    const fields = try Fields.document(d, "evidence", root, "assay-evidence/v1", &.{
        "schema",    "contract_sha256", "subject_sha256", "context_sha256", "runs", "records",
        "artifacts",
    });
    const bindings = [_]struct { name: []const u8, expected: []const u8, label: []const u8 }{
        .{ .name = "contract_sha256", .expected = raw.contract_sha256, .label = "contract" },
        .{ .name = "subject_sha256", .expected = raw.subject_sha256, .label = "subject" },
        .{ .name = "context_sha256", .expected = contract.context_sha256, .label = "context" },
    };
    for (bindings) |binding| {
        const actual = try fields.digest(binding.name);
        if (!std.mem.eql(u8, actual, binding.expected)) {
            return fields.reject(
                .identity_mismatch,
                binding.name,
                "names a different {s} digest",
                .{binding.label},
            );
        }
    }
    var run_ids: IdSet = .empty;
    const runs = try decodeRuns(arena, fields, contract, &run_ids);
    var artifact_ids: IdSet = .empty;
    const artifacts = try decodeEvidenceArtifacts(arena, fields, &artifact_ids);
    const by_obligation = try arena.alloc(?u32, contract.obligations.len);
    @memset(by_obligation, null);
    const context: RecordContext = .{
        .contract = contract,
        .runs = runs,
        .run_ids = &run_ids,
        .artifact_ids = &artifact_ids,
        .by_obligation = by_obligation,
    };
    return .{
        .runs = runs,
        .records = try decodeRecords(arena, fields, context),
        .artifacts = artifacts,
        .record_by_obligation = by_obligation,
    };
}

fn decodeRuns(arena: Allocator, parent: Fields, contract: Contract, ids: *IdSet) ![]Run {
    const items = try parent.array("runs", limits.runs_max);
    const result = try arena.alloc(Run, items.len);
    const list_loc = parent.loc.key("runs");
    for (items, result, 0..) |*item, *run, index| {
        const loc = list_loc.index(index);
        const fields = try Fields.of(parent.d, parent.role, &loc, item);
        try fields.closed(&.{ "id", "evaluator_id", "evaluator_sha256", "outcome", "reason" });
        run.* = .{
            .id = try fields.identifier("id"),
            .evaluator_id = try fields.identifier("evaluator_id"),
            .evaluator_sha256 = try fields.digest("evaluator_sha256"),
            .outcome = try fields.enumeration(Outcome, "outcome"),
            .reason = undefined,
        };
        run.reason = try fields.text("reason", limits.text_bytes_max, run.outcome != .complete);
        try claim(arena, ids, fields, run.id, index);
        const evaluator = findEvaluator(contract, run.evaluator_id) orelse {
            return fields.reject(.unknown_reference, "evaluator_id", "unknown evaluator {s}", .{
                run.evaluator_id,
            });
        };
        if (!std.mem.eql(u8, evaluator.sha256, run.evaluator_sha256)) {
            return fields.reject(
                .identity_mismatch,
                "evaluator_sha256",
                "evaluator digest differs",
                .{},
            );
        }
    }
    return result;
}

fn findEvaluator(contract: Contract, id: []const u8) ?Evaluator {
    const index = contract.evaluator_ids.get(id) orelse return null;
    return contract.evaluators[index];
}

fn decodeEvidenceArtifacts(arena: Allocator, parent: Fields, ids: *IdSet) ![]EvidenceArtifact {
    const items = try parent.array("artifacts", limits.evidence_artifacts_max);
    const result = try arena.alloc(EvidenceArtifact, items.len);
    const list_loc = parent.loc.key("artifacts");
    for (items, result, 0..) |*item, *artifact, index| {
        const loc = list_loc.index(index);
        const fields = try Fields.of(parent.d, parent.role, &loc, item);
        try fields.closed(&.{ "id", "sha256", "size_bytes", "locator", "description" });
        artifact.* = .{
            .id = try fields.identifier("id"),
            .sha256 = try fields.digest("sha256"),
            .size_bytes = try fields.count("size_bytes", std.math.maxInt(u64)),
            .locator = try fields.text("locator", limits.path_bytes_max, true),
            .description = try fields.text("description", limits.text_bytes_max, false),
        };
        try claim(arena, ids, fields, artifact.id, index);
    }
    return result;
}

const RecordContext = struct {
    contract: Contract,
    runs: []const Run,
    run_ids: *const IdSet,
    artifact_ids: *const IdSet,
    by_obligation: []?u32,
};

fn decodeRecords(arena: Allocator, parent: Fields, context: RecordContext) ![]Record {
    const items = try parent.array("records", limits.records_max);
    const result = try arena.alloc(Record, items.len);
    const list_loc = parent.loc.key("records");
    for (items, result, 0..) |*item, *record, index| {
        const loc = list_loc.index(index);
        const fields = try Fields.of(parent.d, parent.role, &loc, item);
        record.* = try decodeRecord(arena, fields, context);
        const slot = &context.by_obligation[record.obligation];
        if (slot.* != null) {
            const id = context.contract.obligations[record.obligation].id;
            return fields.reject(
                .conflicting_record,
                "obligation_id",
                "second record for {s}",
                .{id},
            );
        }
        slot.* = @intCast(index);
    }
    return result;
}

fn decodeRecord(arena: Allocator, fields: Fields, context: RecordContext) diag.Error!Record {
    const status = try fields.enumeration(Status, "status");
    try fields.closed(if (status == .observed)
        &.{ "obligation_id", "run_id", "status", "observation", "artifact_ids" }
    else
        &.{ "obligation_id", "run_id", "status", "reason", "artifact_ids" });
    const obligation_id = try fields.identifier("obligation_id");
    const obligation = findObligation(context.contract, obligation_id) orelse {
        return fields.reject(.unknown_reference, "obligation_id", "unknown obligation {s}", .{
            obligation_id,
        });
    };
    const run_id = try fields.identifier("run_id");
    const run = context.run_ids.get(run_id) orelse {
        return fields.reject(.unknown_reference, "run_id", "unknown run {s}", .{run_id});
    };
    const evaluator_index = context.contract.obligations[obligation].evaluator;
    const expected = context.contract.evaluators[evaluator_index];
    if (!std.mem.eql(u8, context.runs[run].evaluator_id, expected.id)) {
        return fields.reject(.identity_mismatch, "run_id", "run uses a different evaluator", .{});
    }
    try checkArtifactReferences(arena, fields, context.artifact_ids);
    const check = context.contract.obligations[obligation].check;
    return .{
        .obligation = obligation,
        .run = run,
        .status = status,
        .observation = if (status == .observed) try decodeObservation(fields, check) else null,
        .reason = if (status == .observed)
            null
        else
            try fields.text("reason", limits.text_bytes_max, true),
    };
}

fn findObligation(contract: Contract, id: []const u8) ?u32 {
    return contract.obligation_ids.get(id);
}

fn checkArtifactReferences(arena: Allocator, fields: Fields, known: *const IdSet) !void {
    const references = try fields.array("artifact_ids", limits.evidence_artifacts_max);
    var seen: IdSet = .empty;
    for (references, 0..) |reference, index| {
        const list_loc = fields.loc.key("artifact_ids");
        const loc = list_loc.index(index);
        if (reference != .string or !json.isIdentifier(reference.string)) {
            return fields.d.fail(
                .invalid_document,
                &loc,
                "{s}: identifier required",
                .{fields.role},
            );
        }
        if (!known.contains(reference.string)) {
            return fields.d.fail(.unknown_reference, &loc, "{s}: unknown artifact {s}", .{
                fields.role, reference.string,
            });
        }
        const entry = try seen.getOrPut(arena, reference.string);
        if (entry.found_existing) {
            return fields.d.fail(.duplicate_id, &loc, "{s}: duplicate artifact reference", .{
                fields.role,
            });
        }
    }
}

fn decodeObservation(parent: Fields, check: Check) diag.Error!Observation {
    var loc: Loc = undefined;
    const fields = try parent.object("observation", &loc);
    const kind = try fields.enumeration(enum { scalar, judgment }, "kind");
    const expected: @TypeOf(kind) = switch (check) {
        .scalar_equal => .scalar,
        .domain_judgment => .judgment,
    };
    if (kind != expected) {
        return fields.reject(.invalid_document, "kind", "observation kind differs from check", .{});
    }
    switch (kind) {
        .scalar => {
            try fields.closed(&.{ "kind", "value" });
            return .{ .scalar = try fields.scalar("value") };
        },
        .judgment => {
            try fields.closed(&.{ "kind", "judgment", "reason" });
            return .{ .judgment = .{
                .judgment = try fields.enumeration(Judgment, "judgment"),
                .reason = try fields.text("reason", limits.text_bytes_max, true),
            } };
        },
    }
}

pub fn bindContractToSubject(d: *Diagnostic, contract: Contract, subject: Subject) !void {
    const contract_root = Loc.root;
    const context = subject.artifacts[subject.context];
    if (!std.mem.eql(u8, contract.context_sha256, context.sha256)) {
        const loc = contract_root.key("context_sha256");
        return d.fail(
            .identity_mismatch,
            &loc,
            "contract: context digest differs from subject",
            .{},
        );
    }
    const list_loc = contract_root.key("evaluators");
    for (contract.evaluators, 0..) |evaluator, index| {
        const item_loc = list_loc.index(index);
        const artifact_loc = item_loc.key("artifact_id");
        const artifact_index = subject.find(evaluator.artifact_id) orelse {
            return d.fail(
                .unknown_reference,
                &artifact_loc,
                "contract: unknown subject artifact {s}",
                .{evaluator.artifact_id},
            );
        };
        const artifact = subject.artifacts[artifact_index];
        if (artifact.role != .evaluator) {
            return d.fail(
                .invalid_document,
                &artifact_loc,
                "contract: artifact role is not evaluator",
                .{},
            );
        }
        if (!std.mem.eql(u8, artifact.sha256, evaluator.sha256)) {
            const digest_loc = item_loc.key("sha256");
            return d.fail(
                .identity_mismatch,
                &digest_loc,
                "contract: evaluator digest differs",
                .{},
            );
        }
    }
}

test "relative path grammar" {
    try std.testing.expect(isRelativePath("a/b.c"));
    const bad_paths = [_][]const u8{
        "",    "/a",    "a/", "a//b", "./a", "a/../b", "..", "a\\b",
        "C:x", "a\x00",
    };
    for (bad_paths) |bad| {
        try std.testing.expect(!isRelativePath(bad));
    }
}
