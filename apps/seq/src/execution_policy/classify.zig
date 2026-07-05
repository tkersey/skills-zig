const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const artifacts_mod = @import("artifacts.zig");

pub const RuntimeState = enum {
    authoritative_policy_runtime,
    structured_manual_runtime,
    declared_unstructured,
    candidate_only,
    contamination_only,

    pub fn text(self: RuntimeState) []const u8 {
        return @tagName(self);
    }
};

pub const EvidenceRef = struct {
    evidence_id: []u8,
    source: []u8,
    artifact_kind: []u8,
    artifact_id: []u8,
    digest: []u8,
    matched_field: []u8,
    excerpt: []u8,
    authority: []u8,

    pub fn deinit(self: *EvidenceRef, allocator: std.mem.Allocator) void {
        allocator.free(self.evidence_id);
        allocator.free(self.source);
        allocator.free(self.artifact_kind);
        allocator.free(self.artifact_id);
        allocator.free(self.digest);
        allocator.free(self.matched_field);
        allocator.free(self.excerpt);
        allocator.free(self.authority);
    }
};

pub const Result = struct {
    runtime_state: RuntimeState,
    candidate: bool,
    true_run: bool,
    verdict: []u8,
    policy_id: ?[]u8,
    evidence_refs: []EvidenceRef,
    evidence_ref_json: []u8,
    contamination_flags: [][]u8,
    limitations: [][]u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.verdict);
        if (self.policy_id) |id| allocator.free(id);
        for (self.evidence_refs) |*ref| ref.deinit(allocator);
        allocator.free(self.evidence_refs);
        allocator.free(self.evidence_ref_json);
        freeStringList(allocator, self.contamination_flags);
        freeStringList(allocator, self.limitations);
    }
};

const Counts = struct {
    valid_epg: usize = 0,
    valid_eps: usize = 0,
    valid_epd: usize = 0,
    valid_etr: usize = 0,
    controller: usize = 0,
    declaration: usize = 0,
    weak: usize = 0,
};

pub fn classifyTrace(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) !Result {
    var evidence: std.ArrayList(EvidenceRef) = .empty;
    errdefer freeEvidenceRefs(allocator, evidence.items);
    var contamination: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, contamination.items);
    var limitations: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, limitations.items);
    var counts = Counts{};
    var policy_id: ?[]u8 = null;
    errdefer if (policy_id) |id| allocator.free(id);

    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| {
            try inspectText(allocator, &evidence, &contamination, &counts, &policy_id, "message", turn.turn_index, "user", text);
        }
        if (turn.final_answer orelse turn.assistant_preview) |text| {
            try inspectText(allocator, &evidence, &contamination, &counts, &policy_id, "message", turn.turn_index, "assistant", text);
        }
    }
    for (trace.tools.items, 0..) |tool, idx| {
        const turn_index: i64 = @intCast(idx + 1);
        if (tool.command_text) |text| try inspectToolText(allocator, &evidence, &counts, turn_index, "tool_call", text);
        if (tool.input_text) |text| try inspectToolText(allocator, &evidence, &counts, turn_index, "tool_call", text);
        if (tool.output_text) |text| try inspectToolText(allocator, &evidence, &counts, turn_index, "tool_output", text);
    }

    if (evidence.items.len == 0 and contamination.items.len == 0) try limitations.append(allocator, try allocator.dupe(u8, "no policy runtime artifacts found"));

    const full_artifact_loop = counts.valid_epg > 0 and counts.valid_eps > 0 and counts.valid_epd > 0 and counts.valid_etr > 0;
    const state: RuntimeState = if (evidence.items.len == 0 and contamination.items.len > 0)
        .contamination_only
    else if (full_artifact_loop and counts.controller > 0)
        .authoritative_policy_runtime
    else if (full_artifact_loop)
        .structured_manual_runtime
    else if (counts.declaration > 0)
        .declared_unstructured
    else if (counts.weak > 0 or hasAnyPolicyArtifact(counts))
        .candidate_only
    else
        .contamination_only;

    const candidate = state != .contamination_only;
    const true_run = state == .authoritative_policy_runtime or state == .structured_manual_runtime;
    const verdict = switch (state) {
        .authoritative_policy_runtime => "true_run_authoritative",
        .structured_manual_runtime => "true_run_structured_manual",
        .declared_unstructured => "declared_unstructured",
        .candidate_only => "candidate_only",
        .contamination_only => "contamination_only",
    };

    const evidence_json = try evidenceRefsJson(allocator, evidence.items);
    errdefer allocator.free(evidence_json);

    return .{
        .runtime_state = state,
        .candidate = candidate,
        .true_run = true_run,
        .verdict = try allocator.dupe(u8, verdict),
        .policy_id = policy_id,
        .evidence_refs = try evidence.toOwnedSlice(allocator),
        .evidence_ref_json = evidence_json,
        .contamination_flags = try contamination.toOwnedSlice(allocator),
        .limitations = try limitations.toOwnedSlice(allocator),
    };
}

fn inspectText(
    allocator: std.mem.Allocator,
    evidence: *std.ArrayList(EvidenceRef),
    contamination: *std.ArrayList([]u8),
    counts: *Counts,
    policy_id: *?[]u8,
    source: []const u8,
    turn_index: i64,
    role: []const u8,
    text: []const u8,
) !void {
    const contaminated = try classifyContamination(allocator, contamination, text);
    if (contaminated) {
        counts.weak += 1;
        return;
    }
    if (contains(text, "execution policy runtime") or contains(text, "$actuating policy runtime") or contains(text, "EPG-guided")) {
        counts.declaration += 1;
        try appendEvidence(allocator, evidence, source, turn_index, role, "runtime_declaration", "declaration", "", "runtime", text, "message");
    }
    if (contains(text, "EPG") or contains(text, "EPS") or contains(text, "EPD") or contains(text, "ETR")) counts.weak += 1;
    try collectArtifactsFromText(allocator, evidence, counts, policy_id, source, turn_index, role, text);
}

fn inspectToolText(
    allocator: std.mem.Allocator,
    evidence: *std.ArrayList(EvidenceRef),
    counts: *Counts,
    turn_index: i64,
    source: []const u8,
    text: []const u8,
) !void {
    if (contains(text, "graph_control_receipt") or contains(text, "GCR-v1")) {
        counts.controller += 1;
        try appendEvidence(allocator, evidence, source, turn_index, "tool", "controller_event", "gcr", "", "runtime", text, "controller_event");
    }
    if (contains(text, "ASL") or contains(text, "FPSR-v1") or contains(text, "fixed_point_slice_result")) {
        counts.controller += 1;
        try appendEvidence(allocator, evidence, source, turn_index, "tool", "controller_event", "fpsr", "", "runtime", text, "controller_event");
    }
}

fn collectArtifactsFromText(
    allocator: std.mem.Allocator,
    evidence: *std.ArrayList(EvidenceRef),
    counts: *Counts,
    policy_id: *?[]u8,
    source: []const u8,
    turn_index: i64,
    role: []const u8,
    text: []const u8,
) !void {
    var parsed: std.ArrayList(artifacts_mod.ParsedArtifact) = .empty;
    defer {
        for (parsed.items) |*artifact| artifact.deinit(allocator);
        parsed.deinit(allocator);
    }
    try artifacts_mod.collectFromText(allocator, text, &parsed);
    for (parsed.items) |artifact| {
        if (!artifact.valid) continue;
        switch (artifact.kind) {
            .epg => {
                counts.valid_epg += 1;
                if (policy_id.* == null) policy_id.* = try allocator.dupe(u8, artifact.artifact_id);
            },
            .eps => counts.valid_eps += 1,
            .epd => counts.valid_epd += 1,
            .etr => counts.valid_etr += 1,
        }
        try appendEvidence(allocator, evidence, source, turn_index, role, @tagName(artifact.kind), artifact.artifact_id, artifact.digest, "artifact", text, "structured_artifact");
    }
}

fn classifyContamination(allocator: std.mem.Allocator, contamination: *std.ArrayList([]u8), text: []const u8) !bool {
    var contaminated = false;
    if ((contains(text, "# SPEC:") or contains(text, "Spec ID:")) and contains(text, "execution-policy-audit")) {
        try addUnique(allocator, contamination, "policy_audit_spec_prompt");
        contaminated = true;
    }
    if ((contains(text, "<skill>") or contains(text, "SKILL.md")) and (contains(text, "EPG") or contains(text, "execution policy"))) {
        try addUnique(allocator, contamination, "pasted_skill_block");
        contaminated = true;
    }
    if ((contains(text, "example") or contains(text, "documentation") or contains(text, "schema")) and contains(text, "EPG")) {
        try addUnique(allocator, contamination, "policy_example_or_schema");
        contaminated = true;
    }
    return contaminated;
}

fn appendEvidence(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(EvidenceRef),
    source: []const u8,
    turn_index: i64,
    role: []const u8,
    artifact_kind: []const u8,
    artifact_id: []const u8,
    digest: []const u8,
    matched_field: []const u8,
    text: []const u8,
    authority: []const u8,
) !void {
    const evidence_id = try std.fmt.allocPrint(allocator, "ev-{s}-{d}-{s}-{d}", .{ source, turn_index, artifact_kind, list.items.len + 1 });
    errdefer allocator.free(evidence_id);
    const clipped = try clippedExcerpt(allocator, text, 160);
    errdefer allocator.free(clipped);
    try list.append(allocator, .{
        .evidence_id = evidence_id,
        .source = try allocator.dupe(u8, source),
        .artifact_kind = try allocator.dupe(u8, artifact_kind),
        .artifact_id = try allocator.dupe(u8, artifact_id),
        .digest = try allocator.dupe(u8, digest),
        .matched_field = try allocator.dupe(u8, matched_field),
        .excerpt = clipped,
        .authority = try allocator.dupe(u8, authority),
    });
    _ = role;
}

fn evidenceRefsJson(allocator: std.mem.Allocator, refs: []const EvidenceRef) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeByte('[');
    for (refs, 0..) |ref, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"evidence_id\":\"");
        try writer.writeAll(ref.evidence_id);
        try writer.writeAll("\",\"source\":\"");
        try writer.writeAll(ref.source);
        try writer.writeAll("\",\"artifact_kind\":\"");
        try writer.writeAll(ref.artifact_kind);
        try writer.writeAll("\",\"artifact_id\":\"");
        try writer.writeAll(ref.artifact_id);
        try writer.writeAll("\",\"digest\":\"");
        try writer.writeAll(ref.digest);
        try writer.writeAll("\",\"matched_field\":\"");
        try writer.writeAll(ref.matched_field);
        try writer.writeAll("\",\"authority\":\"");
        try writer.writeAll(ref.authority);
        try writer.writeAll("\"}");
    }
    try writer.writeByte(']');
    return writer_alloc.toOwnedSlice();
}

fn hasAnyPolicyArtifact(counts: Counts) bool {
    return counts.valid_epg > 0 or counts.valid_eps > 0 or counts.valid_epd > 0 or counts.valid_etr > 0;
}

fn clippedExcerpt(allocator: std.mem.Allocator, text: []const u8, max: usize) ![]u8 {
    const end = @min(text.len, max);
    return allocator.dupe(u8, text[0..end]);
}

fn addUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn freeEvidenceRefs(allocator: std.mem.Allocator, refs: []EvidenceRef) void {
    for (refs) |*ref| ref.deinit(allocator);
    allocator.free(refs);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "classifies policy spec contamination separately from runtime" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy-spec.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy-spec.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .user_message = try std.testing.allocator.dupe(u8, "# SPEC: `seq execution-policy-audit` EPG schema example"),
    });
    var result = try classifyTrace(std.testing.allocator, trace);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(RuntimeState.contamination_only, result.runtime_state);
    try std.testing.expect(!result.true_run);
}

test "classifies valid policy artifact loop plus controller as authoritative runtime" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy-runtime.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy-runtime.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .assistant_preview = try std.testing.allocator.dupe(u8,
            \\execution policy runtime
            \\EPG-v1 {"policy_id":"p","revision":1,"declared_atoms":["fact:start","fact:done"],"actions":[{"id":"a","results":{"success":["fact:done"]}}],"policy_rules":[{"id":"r","actions":["a"]},{"id":"done","condition":{"all":["fact:done"]}}]}
            \\EPS-v1 {"state_id":"s1","policy_id":"p","revision":1,"policy_digest":"sha256:abc","satisfied_atoms":["fact:start"]}
            \\EPD-v1 {"decision_id":"d","winner":{"kind":"action","id":"a"}}
            \\ETR-v1 {"policy_id":"p","revision":1,"policy_digest":"sha256:abc","decision_id":"d","action_id":"a","result":"success","predicted_effects":["fact:done"],"observed":{"facts":["fact:done"],"potential":[0]},"state_after":{"state_id":"s2","potential":[0]}}
        ),
    });
    try trace.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy-runtime.jsonl"),
        .kind = .exec_command,
        .output_text = try std.testing.allocator.dupe(u8, "{\"graph_control_receipt\":{\"receipt_version\":\"GCR-v1\",\"receipt_id\":\"GCR-1\"}}"),
    });
    var result = try classifyTrace(std.testing.allocator, trace);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(RuntimeState.authoritative_policy_runtime, result.runtime_state);
    try std.testing.expect(result.true_run);
    try std.testing.expectEqualStrings("p", result.policy_id.?);
}
