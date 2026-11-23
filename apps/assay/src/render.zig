const std = @import("std");
const limits = @import("limits.zig");
const diag = @import("diag.zig");
const documents = @import("documents.zig");
const assess = @import("assess.zig");
const verify = @import("verify.zig");
const receipt = @import("receipt.zig");
const compare = @import("compare.zig");

const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const Error = Stringify.Error;

pub const Producer = struct { version: []const u8 };

fn field(s: *Stringify, name: []const u8, value: anytype) Error!void {
    try s.objectField(name);
    try s.write(value);
}

fn authority(s: *Stringify) Error!void {
    try field(s, "authority_granted", false);
    try field(s, "storage_mutated", false);
}

fn scalar(s: *Stringify, value: documents.Scalar) Error!void {
    switch (value) {
        .number => |token| try s.print("{s}", .{token}),
        .null => try s.write(null),
        .boolean => |flag| try s.write(flag),
        .string => |text| try s.write(text),
    }
}

fn observation(s: *Stringify, value: ?documents.Observation) Error!void {
    const present = value orelse return s.write(null);
    try s.beginObject();
    switch (present) {
        .scalar => |actual| {
            try field(s, "kind", "scalar");
            try s.objectField("value");
            try scalar(s, actual);
        },
        .judgment => |judged| {
            try field(s, "kind", "judgment");
            try field(s, "judgment", judged.judgment);
            try field(s, "reason", judged.reason);
        },
    }
    try s.endObject();
}

fn check(s: *Stringify, value: documents.Check) Error!void {
    try s.beginObject();
    try field(s, "kind", std.meta.activeTag(value));
    switch (value) {
        .scalar_equal => |expected| {
            try s.objectField("expected");
            try scalar(s, expected);
        },
        .domain_judgment => |qualification| try field(s, "qualification", qualification),
    }
    try s.endObject();
}

fn recordOf(loaded: *const assess.Loaded, item: assess.Derived) ?documents.Record {
    return if (item.record) |index| loaded.evidence.records[index] else null;
}

fn runOf(loaded: *const assess.Loaded, item: assess.Derived) ?documents.Run {
    const record = recordOf(loaded, item) orelse return null;
    return loaded.evidence.runs[record.run];
}

fn obligation(s: *Stringify, loaded: *const assess.Loaded, item: assess.Derived) Error!void {
    const declared = loaded.contract.obligations[item.obligation];
    const run = runOf(loaded, item);
    const record = recordOf(loaded, item);
    try s.beginObject();
    try field(s, "id", declared.id);
    try field(s, "required", declared.required);
    try field(s, "judgment", item.judgment);
    try field(s, "reason_code", item.reason_code);
    try field(s, "basis", declared.basis);
    try field(s, "evaluator_id", loaded.contract.evaluators[declared.evaluator].id);
    try field(s, "run_id", if (run) |value| value.id else null);
    try field(s, "run_outcome", if (run) |value| value.outcome else null);
    try s.objectField("observation");
    try observation(s, if (record) |value| value.observation else null);
    try field(s, "completion_gate", item.completion_gate);
    try s.endObject();
}

pub fn derivation(
    s: *Stringify,
    loaded: *const assess.Loaded,
    value: assess.Derivation,
) Error!void {
    try s.beginObject();
    try field(s, "kernel", assess.kernel);
    try field(s, "contract_sha256", &loaded.contract_sha256);
    try field(s, "subject_sha256", &loaded.subject_sha256);
    try field(s, "evidence_sha256", &loaded.evidence_sha256);
    try field(s, "context_sha256", loaded.contract.context_sha256);
    try field(s, "claim_kind", loaded.contract.claim_kind);
    try field(s, "overall", value.overall);
    try field(s, "counts", value.counts);
    try s.objectField("run_outcomes");
    try s.beginObject();
    for (std.enums.values(documents.Outcome)) |outcome| {
        try field(s, @tagName(outcome), value.run_outcomes.get(outcome));
    }
    try s.endObject();
    try s.objectField("obligations");
    try s.beginArray();
    for (value.items) |item| try obligation(s, loaded, item);
    try s.endArray();
    try s.objectField("evidence_artifacts");
    try s.beginArray();
    for (loaded.evidence.artifacts) |artifact| {
        try s.beginObject();
        try field(s, "id", artifact.id);
        try field(s, "sha256", artifact.sha256);
        try field(s, "availability", "not_checked");
        try s.endObject();
    }
    try s.endArray();
    try authority(s);
    try s.endObject();
}

fn verification(s: *Stringify, value: verify.Verification) Error!void {
    try s.beginObject();
    try field(s, "subject_bytes", value.status);
    try field(s, "files_checked", value.files_checked);
    try field(s, "bytes_read", value.bytes_read);
    try s.endObject();
}

pub fn assessment(
    w: *Writer,
    producer: Producer,
    loaded: *const assess.Loaded,
    value: assess.Derivation,
    checked: verify.Verification,
) Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "schema", "assay-assessment/v1");
    try field(&s, "assessment_id", &loaded.assessment_id);
    try s.objectField("producer");
    try s.beginObject();
    try field(&s, "product", "assay");
    try field(&s, "version", producer.version);
    try field(&s, "kernel", assess.kernel);
    try s.endObject();
    try s.objectField("inputs");
    try s.beginObject();
    try field(&s, "contract_utf8", loaded.sources.contract);
    try field(&s, "subject_utf8", loaded.sources.subject);
    try field(&s, "evidence_utf8", loaded.sources.evidence);
    try s.endObject();
    try s.objectField("derivation");
    try derivation(&s, loaded, value);
    try s.objectField("verification");
    try verification(&s, checked);
    try s.endObject();
    try w.writeByte('\n');
}

fn explanationItem(s: *Stringify, loaded: *const assess.Loaded, item: assess.Derived) Error!void {
    const declared = loaded.contract.obligations[item.obligation];
    const record = recordOf(loaded, item);
    const run = runOf(loaded, item);
    try s.beginObject();
    try field(s, "obligation_id", declared.id);
    try field(s, "statement", declared.statement);
    try field(s, "scope", declared.scope);
    try s.objectField("check");
    try check(s, declared.check);
    try s.objectField("observation");
    try observation(s, if (record) |value| value.observation else null);
    try field(s, "reason_code", item.reason_code);
    try field(s, "run_id", if (run) |value| value.id else null);
    try field(s, "run_outcome", if (run) |value| value.outcome else null);
    try field(s, "completion_gate", item.completion_gate);
    try field(s, "record_reason", if (record) |value| value.reason else null);
    try s.endObject();
}

fn explanationRuns(s: *Stringify, loaded: *const assess.Loaded) Error!void {
    try s.beginArray();
    for (loaded.evidence.runs) |run| {
        try s.beginObject();
        try field(s, "id", run.id);
        try field(s, "evaluator_id", run.evaluator_id);
        try field(s, "outcome", run.outcome);
        try field(s, "reason", run.reason);
        try s.endObject();
    }
    try s.endArray();
}

pub fn explanation(w: *Writer, verified: *const receipt.Verified) Error!void {
    var s: Stringify = .{ .writer = w };
    const loaded = &verified.loaded;
    try s.beginObject();
    try field(&s, "schema", "assay-explanation/v2");
    try field(&s, "assessment_id", &loaded.assessment_id);
    try field(&s, "receipt_consistency", "verified");
    try s.objectField("derivation");
    try derivation(&s, loaded, verified.derivation);
    try s.objectField("runs");
    try explanationRuns(&s, loaded);
    try s.objectField("explanations");
    try s.beginArray();
    for (verified.derivation.items) |item| try explanationItem(&s, loaded, item);
    try s.endArray();
    try field(&s, "subject_bytes", "not_reverified");
    try s.objectField("recorded_verification");
    try s.beginObject();
    try field(&s, "trust", "unauthenticated_receipt_claim");
    try s.objectField("verification");
    try verification(&s, verified.recorded);
    try s.endObject();
    try authority(&s);
    try s.endObject();
    try w.writeByte('\n');
}

pub fn comparison(w: *Writer, value: compare.Comparison) Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "schema", "assay-comparison/v1");
    try field(&s, "baseline_assessment_id", &value.baseline.loaded.assessment_id);
    try field(&s, "candidate_assessment_id", &value.candidate.loaded.assessment_id);
    try field(&s, "comparability", if (value.comparable()) "comparable" else "incomparable");
    try field(&s, "incompatibilities", value.incompatibilities);
    try field(&s, "baseline_overall", value.baseline.derivation.overall);
    try field(&s, "candidate_overall", value.candidate.derivation.overall);
    try s.objectField("transitions");
    try s.beginArray();
    const obligations = value.baseline.loaded.contract.obligations;
    for (value.transitions) |transition| {
        try s.beginObject();
        try field(&s, "obligation_id", obligations[transition.obligation].id);
        try field(&s, "required", obligations[transition.obligation].required);
        try field(&s, "baseline", transition.baseline);
        try field(&s, "candidate", transition.candidate);
        try field(&s, "kind", transition.kind);
        try s.endObject();
    }
    try s.endArray();
    try field(&s, "preservation", value.preservation);
    try authority(&s);
    try s.endObject();
    try w.writeByte('\n');
}

pub const commands = [_][]const u8{ "capabilities", "assess", "compare", "explain" };
const input_schemas = [_][]const u8{
    "assay-contract/v1", "assay-subject/v1", "assay-evidence/v1", "assay-assessment/v1",
};
const output_schemas = [_][]const u8{
    "assay-capabilities/v1", "assay-assessment/v1",    "assay-comparison/v1",
    "assay-explanation/v2",  "assay-command-error/v1",
};

pub fn capabilities(w: *Writer, producer: Producer) Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "schema", "assay-capabilities/v1");
    try field(&s, "product", "assay");
    try field(&s, "version", producer.version);
    try field(&s, "kernel", assess.kernel);
    try field(&s, "commands", commands);
    try field(&s, "input_schemas", input_schemas);
    try field(&s, "output_schemas", output_schemas);
    try field(&s, "check_kinds", [_][]const u8{ "scalar_equal", "domain_judgment" });
    try field(&s, "formats", [_][]const u8{ "json", "text" });
    try field(&s, "default_format", "json");
    try field(&s, "exit_codes", .{
        .supported = 0,
        .refuted = 1,
        .command_error = 2,
        .unresolved = 3,
        .processing_complete = 0,
    });
    try s.objectField("limits");
    try s.beginObject();
    for (limits.published) |entry| try field(&s, entry.key, entry.value);
    try s.endObject();
    try field(&s, "boundary", .{
        .executes_evaluators = false,
        .network_access = false,
        .subject_verification = "optional_local_manifest_files",
        .receipt_authentication = "none",
        .authority_granted = false,
        .storage_mutated = false,
    });
    try s.endObject();
    try w.writeByte('\n');
}

pub fn commandError(w: *Writer, d: *const diag.Diagnostic) Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "schema", "assay-command-error/v1");
    try field(&s, "code", d.code);
    try field(&s, "message", d.message());
    try field(&s, "location", d.location());
    try authority(&s);
    try s.endObject();
    try w.writeByte('\n');
}

pub fn commandErrorText(w: *Writer, d: *const diag.Diagnostic) Error!void {
    try w.print("assay: error {s}: ", .{@tagName(d.code)});
    try quoted(w, d.message());
    if (d.location()) |location| {
        try w.writeAll(" at ");
        try quoted(w, location);
    }
    try w.writeAll("\nauthority granted: false; storage mutated: false\n");
}

fn quoted(w: *Writer, text: []const u8) Error!void {
    try Stringify.encodeJsonString(text, .{ .escape_unicode = true }, w);
}

fn scalarText(w: *Writer, value: documents.Scalar) Error!void {
    if (value == .string) return quoted(w, value.string);
    var s: Stringify = .{ .writer = w };
    try scalar(&s, value);
}

fn observationText(w: *Writer, value: ?documents.Observation) Error!void {
    const present = value orelse return w.writeAll("none");
    switch (present) {
        .scalar => |actual| try scalarText(w, actual),
        .judgment => |judged| {
            try w.print("{s} ", .{@tagName(judged.judgment)});
            try quoted(w, judged.reason);
        },
    }
}

fn countsText(w: *Writer, counts: assess.Counts) Error!void {
    try w.print(
        "required: {d} supported, {d} refuted, {d} unresolved; " ++
            "optional: {d} supported, {d} refuted, {d} unresolved\n",
        .{
            counts.required_supported, counts.required_refuted, counts.required_unresolved,
            counts.optional_supported, counts.optional_refuted, counts.optional_unresolved,
        },
    );
}

fn checkText(w: *Writer, value: documents.Check) Error!void {
    switch (value) {
        .scalar_equal => |expected| {
            try w.writeAll("  check: scalar_equal, expected ");
            try scalarText(w, expected);
        },
        .domain_judgment => |qualification| {
            try w.writeAll("  check: qualified evaluator judgment, ");
            try quoted(w, qualification);
        },
    }
    try w.writeByte('\n');
}

fn obligationText(w: *Writer, loaded: *const assess.Loaded, item: assess.Derived) Error!void {
    const declared = loaded.contract.obligations[item.obligation];
    const run = runOf(loaded, item);
    const record = recordOf(loaded, item);
    try w.print("- {s} [{s}] {s} ({s})\n", .{
        declared.id,
        if (declared.required) "required" else "optional",
        @tagName(item.judgment),
        @tagName(item.reason_code),
    });
    try w.writeAll("  statement: ");
    try quoted(w, declared.statement);
    try w.writeAll("\n  scope: ");
    try quoted(w, declared.scope);
    try w.print("\n  basis: {s}; evaluator: {s}\n", .{
        @tagName(declared.basis),
        loaded.contract.evaluators[declared.evaluator].id,
    });
    try checkText(w, declared.check);
    try w.writeAll("  observed: ");
    try observationText(w, if (record) |value| value.observation else null);
    try w.writeAll("\n  run: ");
    if (run) |value| {
        try w.print("{s} ({s})", .{ value.id, @tagName(value.outcome) });
    } else try w.writeAll("none");
    try w.print("; gate: {s}\n", .{if (item.completion_gate) |gate| @tagName(gate) else "none"});
    if (record) |value| if (value.reason) |reason| {
        try w.writeAll("  record reason: ");
        try quoted(w, reason);
        try w.writeByte('\n');
    };
}

fn derivationText(w: *Writer, loaded: *const assess.Loaded, value: assess.Derivation) Error!void {
    try w.print("assessment {s}\noverall: {s} ({s} claim)\n", .{
        &loaded.assessment_id,
        @tagName(value.overall),
        @tagName(loaded.contract.claim_kind),
    });
    try countsText(w, value.counts);
    try w.writeAll("obligations:\n");
    for (value.items) |item| try obligationText(w, loaded, item);
    if (loaded.evidence.runs.len > 0) try w.writeAll("runs:\n");
    for (loaded.evidence.runs) |run| {
        try w.print("- {s} ({s})", .{ run.id, @tagName(run.outcome) });
        if (run.reason.len > 0) {
            try w.writeAll(": ");
            try quoted(w, run.reason);
        }
        try w.writeByte('\n');
    }
    for (loaded.evidence.artifacts) |artifact| {
        try w.print("evidence artifact {s}: availability not_checked\n", .{artifact.id});
    }
}

pub fn assessmentText(
    w: *Writer,
    loaded: *const assess.Loaded,
    value: assess.Derivation,
    checked: verify.Verification,
) Error!void {
    try derivationText(w, loaded, value);
    try w.print("subject bytes: {s} ({d} files, {d} bytes)\n", .{
        @tagName(checked.status), checked.files_checked, checked.bytes_read,
    });
    try w.writeAll("authority granted: false; storage mutated: false\n");
}

pub fn explanationText(w: *Writer, verified: *const receipt.Verified) Error!void {
    try w.writeAll("receipt consistency: verified\n");
    try derivationText(w, &verified.loaded, verified.derivation);
    try w.print(
        "subject bytes: not_reverified (recorded unauthenticated claim: {s})\n",
        .{@tagName(verified.recorded.status)},
    );
    try w.writeAll("authority granted: false; storage mutated: false\n");
}

pub fn comparisonText(w: *Writer, value: compare.Comparison) Error!void {
    try w.print("baseline {s}: {s}\ncandidate {s}: {s}\n", .{
        &value.baseline.loaded.assessment_id,
        @tagName(value.baseline.derivation.overall),
        &value.candidate.loaded.assessment_id,
        @tagName(value.candidate.derivation.overall),
    });
    const comparability = if (value.comparable()) "comparable" else "incomparable";
    try w.print("comparability: {s}\n", .{comparability});
    for (value.incompatibilities) |entry| {
        try w.print("- {s}: {s}", .{ @tagName(entry.code), entry.detail });
        for (entry.artifact_ids) |id| try w.print(" {s}", .{id});
        try w.writeByte('\n');
    }
    const obligations = value.baseline.loaded.contract.obligations;
    for (value.transitions) |transition| {
        try w.print("- {s} [{s}] {s} -> {s}: {s}\n", .{
            obligations[transition.obligation].id,
            if (obligations[transition.obligation].required) "required" else "optional",
            @tagName(transition.baseline),
            @tagName(transition.candidate),
            @tagName(transition.kind),
        });
    }
    try w.print("preservation: {s}\n", .{@tagName(value.preservation)});
    try w.writeAll("authority granted: false; storage mutated: false\n");
}
