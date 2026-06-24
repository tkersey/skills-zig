const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const query_engine = @import("query/engine.zig");
const skill_decision_receipt = @import("skill_decision_receipt.zig");
const skill_decision_signals = @import("skill_decision_signals.zig");
const resolve_intent_closed = @import("resolve_intent_closed/mod.zig");

pub const Confidence = enum {
    strong,
    moderate,
    weak,

    pub fn score(self: Confidence) f64 {
        return switch (self) {
            .strong => 0.95,
            .moderate => 0.70,
            .weak => 0.35,
        };
    }
};

pub const Candidate = struct {
    decision_id: []u8,
    session_id: []u8,
    turn_index: i64,
    turn_id: []u8,
    question: []u8,
    selected_route: []u8,
    rejected_routes: []const []u8 = &.{},
    explicit_rationale: []const []u8 = &.{},
    explicit_assumptions: []const []u8 = &.{},
    evidence_refs: []const []u8 = &.{},
    source_kind: []u8,
    confidence: Confidence,
    contamination_flags: []u8,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.decision_id);
        allocator.free(self.session_id);
        allocator.free(self.turn_id);
        allocator.free(self.question);
        allocator.free(self.selected_route);
        freeStringSlice(allocator, self.rejected_routes);
        freeStringSlice(allocator, self.explicit_rationale);
        freeStringSlice(allocator, self.explicit_assumptions);
        freeStringSlice(allocator, self.evidence_refs);
        allocator.free(self.source_kind);
        allocator.free(self.contamination_flags);
    }
};

pub const Filters = struct {
    decision_id: ?[]const u8 = null,
    turn_id: ?[]const u8 = null,
    turn_index: ?i64 = null,
    skill: ?[]const u8 = null,
    contains: ?[]const u8 = null,
    regex: ?[]const u8 = null,
};

pub fn compileCandidates(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, filters: Filters) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    errdefer deinitCandidates(allocator, out.items);
    const regex_atoms = if (filters.regex) |pattern| try query_engine.compileTextPatternAtoms(allocator, pattern) else null;
    defer if (regex_atoms) |atoms| allocator.free(atoms);

    for (trace.turns.items) |turn| {
        if (filters.turn_index) |wanted| {
            if (turn.turn_index != wanted) continue;
            try appendTurnSelectorCandidate(allocator, &out, trace, turn);
            continue;
        }
        if (filters.turn_id) |wanted| {
            if (!std.mem.eql(u8, turn.turn_id, wanted)) continue;
            try appendTurnSelectorCandidate(allocator, &out, trace, turn);
            continue;
        }

        const text = turn.final_answer orelse turn.assistant_preview orelse "";
        if (text.len == 0) continue;
        if (!passesTextFilters(text, filters, regex_atoms)) continue;

        if (try appendResolveArtifactCandidate(allocator, &out, trace, turn, text)) continue;

        if (std.mem.indexOf(u8, text, "skill_decision_receipt") != null) {
            if (skill_decision_receipt.parseText(allocator, text)) |parsed_value| {
                var parsed = parsed_value;
                defer parsed.deinit();
                if (filters.skill) |skill| if (!eqlIgnoreCase(parsed.receipt.skill, skill)) continue;
                var generated_decision_id: ?[]u8 = null;
                defer if (generated_decision_id) |id| allocator.free(id);
                const decision_id = if (parsed.receipt.decision_id.len > 0) parsed.receipt.decision_id else blk: {
                    generated_decision_id = try tryHashDecisionId(allocator, trace, turn, parsed.receipt.selected_route, parsed.receipt.question);
                    break :blk generated_decision_id.?;
                };
                const rejected = try cloneStringList(allocator, parsed.receipt.rejected_routes);
                defer freeStringSlice(allocator, rejected);
                const evidence = try singletonList(allocator, "sdr");
                defer freeStringSlice(allocator, evidence);
                try out.append(allocator, try initCandidate(allocator, trace, turn, .{
                    .decision_id = decision_id,
                    .question = if (parsed.receipt.question.len > 0) parsed.receipt.question else "skill decision receipt",
                    .selected_route = if (parsed.receipt.selected_route.len > 0) parsed.receipt.selected_route else "unknown",
                    .source_kind = "sdr_receipt",
                    .confidence = .strong,
                    .rejected_routes = rejected,
                    .evidence_refs = evidence,
                    .source_text = text,
                }));
                continue;
            } else |_| {}
        }

        const selected_maybe = try extractStructuredValue(allocator, text, "selected_route");
        if (selected_maybe) |selected| {
            defer allocator.free(selected);
            const question_maybe = try extractStructuredValue(allocator, text, "question");
            const question = question_maybe orelse try allocator.dupe(u8, "structured decision");
            defer allocator.free(question);
            const decision_id = try tryHashDecisionId(allocator, trace, turn, selected, question);
            defer allocator.free(decision_id);
            const evidence = try singletonList(allocator, "structured:selected_route");
            defer freeStringSlice(allocator, evidence);
            try out.append(allocator, try initCandidate(allocator, trace, turn, .{
                .decision_id = decision_id,
                .question = question,
                .selected_route = selected,
                .source_kind = "structured_route",
                .confidence = .strong,
                .evidence_refs = evidence,
                .source_text = text,
            }));
            continue;
        }

        if (explicitSelectionText(text) and !outcomeOnlyText(text)) {
            const selected = try routePreview(allocator, text);
            defer allocator.free(selected);
            const question = try questionPreview(allocator, turn);
            defer allocator.free(question);
            const decision_id = try tryHashDecisionId(allocator, trace, turn, selected, question);
            defer allocator.free(decision_id);
            const rationale = try rationaleLines(allocator, text);
            defer freeStringSlice(allocator, rationale);
            const assumptions = try assumptionLines(allocator, text);
            defer freeStringSlice(allocator, assumptions);
            const evidence = try singletonList(allocator, "visible_assistant_text");
            defer freeStringSlice(allocator, evidence);
            try out.append(allocator, try initCandidate(allocator, trace, turn, .{
                .decision_id = decision_id,
                .question = question,
                .selected_route = selected,
                .source_kind = "explicit_prose",
                .confidence = .moderate,
                .explicit_rationale = rationale,
                .explicit_assumptions = assumptions,
                .evidence_refs = evidence,
                .source_text = text,
            }));
        }
    }

    filterByDecisionId(allocator, &out, filters.decision_id);
    return out.toOwnedSlice(allocator);
}

pub fn deinitCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |*candidate| candidate.deinit(allocator);
    allocator.free(candidates);
}

const CandidateInput = struct {
    decision_id: []const u8,
    question: []const u8,
    selected_route: []const u8,
    rejected_routes: []const []u8 = &.{},
    explicit_rationale: []const []u8 = &.{},
    explicit_assumptions: []const []u8 = &.{},
    evidence_refs: []const []u8 = &.{},
    source_kind: []const u8,
    confidence: Confidence,
    source_text: []const u8,
};

fn initCandidate(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    turn: canonical_trace.TurnRecord,
    input: CandidateInput,
) !Candidate {
    return .{
        .decision_id = try allocator.dupe(u8, input.decision_id),
        .session_id = try allocator.dupe(u8, trace.session.session_id orelse inferSessionIdFromPath(trace.session.path)),
        .turn_index = turn.turn_index,
        .turn_id = try allocator.dupe(u8, turn.turn_id),
        .question = try allocator.dupe(u8, input.question),
        .selected_route = try allocator.dupe(u8, input.selected_route),
        .rejected_routes = try cloneStringList(allocator, input.rejected_routes),
        .explicit_rationale = try cloneStringList(allocator, input.explicit_rationale),
        .explicit_assumptions = try cloneStringList(allocator, input.explicit_assumptions),
        .evidence_refs = try cloneStringList(allocator, input.evidence_refs),
        .source_kind = try allocator.dupe(u8, input.source_kind),
        .confidence = input.confidence,
        .contamination_flags = try allocator.dupe(u8, skill_decision_signals.contaminationFlags(input.source_text)),
    };
}

fn appendTurnSelectorCandidate(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Candidate),
    trace: canonical_trace.CanonicalSessionTrace,
    turn: canonical_trace.TurnRecord,
) !void {
    const selected = try routePreview(allocator, turn.final_answer orelse turn.assistant_preview orelse turn.user_message orelse turn.turn_id);
    defer allocator.free(selected);
    const question = try questionPreview(allocator, turn);
    defer allocator.free(question);
    const decision_id = try tryHashDecisionId(allocator, trace, turn, selected, question);
    defer allocator.free(decision_id);
    const evidence = try singletonList(allocator, "turn_selector");
    defer freeStringSlice(allocator, evidence);
    try out.append(allocator, try initCandidate(allocator, trace, turn, .{
        .decision_id = decision_id,
        .question = question,
        .selected_route = selected,
        .source_kind = "turn_selector",
        .confidence = .strong,
        .evidence_refs = evidence,
        .source_text = turn.final_answer orelse turn.user_message orelse turn.turn_id,
    }));
}

fn appendResolveArtifactCandidate(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Candidate),
    trace: canonical_trace.CanonicalSessionTrace,
    turn: canonical_trace.TurnRecord,
    text: []const u8,
) !bool {
    if (std.mem.indexOf(u8, text, "_version") == null and std.mem.indexOf(u8, text, "minimum_behavioral_kernel_certificate") == null) return false;
    var artifact = resolve_intent_closed.parseArtifact(allocator, text, turn.turn_id, .structured_skill_artifact) catch return false;
    defer artifact.deinit(allocator);
    if (artifact.kind == .unknown) return false;

    const event_kind = resolveDecisionEventKind(artifact);
    const artifact_id = artifact.id orelse artifact.fingerprint orelse turn.turn_id;
    const campaign_id = artifact.campaign_id orelse trace.session.session_id orelse inferSessionIdFromPath(trace.session.path);
    const decision_id = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ campaign_id, event_kind, artifact_id });
    defer allocator.free(decision_id);
    const question = try std.fmt.allocPrint(allocator, "resolve controller {s}", .{event_kind});
    defer allocator.free(question);
    const selected_route = artifact.disposition orelse resolveArtifactKindLabel(artifact.kind);
    const evidence = try singletonList(allocator, "controller-derived");
    defer freeStringSlice(allocator, evidence);

    try out.append(allocator, try initCandidate(allocator, trace, turn, .{
        .decision_id = decision_id,
        .question = question,
        .selected_route = selected_route,
        .source_kind = "controller-derived",
        .confidence = .strong,
        .evidence_refs = evidence,
        .source_text = text,
    }));
    return true;
}

fn resolveDecisionEventKind(artifact: resolve_intent_closed.ArtifactRow) []const u8 {
    return switch (artifact.kind) {
        .acceptance_contract => if (artifact.sealed == true) "acceptance_seal" else "acceptance_rebase",
        .counterexample => "cex_disposition",
        .counterexample_basis => if (artifact.sealed == true) "basis_seal" else "class_merge_split",
        .potential_cycle => if (artifact.valid) "phi_pass" else "phi_fail",
        .mbkc => "kernel_accept",
        .reduction_certificate => "realization_invalid",
        .review_batch => "review_batch",
        .review_aperture => "review_aperture",
        .delivery => "tuple_close",
        .holdout => "terminal_close",
        .controller_event => "controller_event",
        .unknown => "unknown",
    };
}

fn resolveArtifactKindLabel(kind: resolve_intent_closed.ArtifactKind) []const u8 {
    return switch (kind) {
        .acceptance_contract => "acceptance_contract",
        .review_batch => "review_batch",
        .review_aperture => "review_aperture",
        .counterexample => "counterexample",
        .counterexample_basis => "counterexample_basis",
        .potential_cycle => "potential_cycle",
        .mbkc => "mbkc",
        .reduction_certificate => "reduction_certificate",
        .delivery => "delivery",
        .holdout => "holdout",
        .controller_event => "controller_event",
        .unknown => "unknown",
    };
}

fn passesTextFilters(text: []const u8, filters: Filters, regex_atoms: ?[]const query_engine.RegexAtom) bool {
    if (filters.contains) |needle| if (!containsIgnoreCase(text, needle)) return false;
    if (regex_atoms) |atoms| if (!query_engine.textMatchesPatternAtoms(text, atoms, true)) return false;
    if (filters.skill) |skill| if (!containsIgnoreCase(text, skill)) return false;
    return true;
}

fn explicitSelectionText(text: []const u8) bool {
    const needles = [_][]const u8{
        "i'll use",
        "i will use",
        "i'm using",
        "i'll implement",
        "i will implement",
        "i'm going to",
        "selected route",
        "chosen route",
        "i’ll use",
        "i’ll implement",
    };
    for (needles) |needle| if (containsIgnoreCase(text, needle)) return true;
    return false;
}

fn outcomeOnlyText(text: []const u8) bool {
    const needles = [_][]const u8{ "test passed", "tests passed", "test failed", "tests failed", "review found", "review finding", "merged", "rollback", "deployment" };
    for (needles) |needle| if (containsIgnoreCase(text, needle)) return true;
    return false;
}

fn extractStructuredValue(allocator: std.mem.Allocator, text: []const u8, key: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n-*`");
        if (!std.ascii.startsWithIgnoreCase(trimmed, key)) continue;
        var rest = trimmed[key.len..];
        rest = std.mem.trim(u8, rest, " \t:=`\"");
        if (rest.len == 0) continue;
        return try allocator.dupe(u8, rest);
    }
    return null;
}

fn routePreview(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const collapsed = try collapsedPreview(allocator, text, 120);
    if (collapsed.len == 0) {
        allocator.free(collapsed);
        return allocator.dupe(u8, "unknown");
    }
    return collapsed;
}

fn questionPreview(allocator: std.mem.Allocator, turn: canonical_trace.TurnRecord) ![]u8 {
    if (turn.user_message) |text| return collapsedPreview(allocator, text, 160);
    if (turn.user_preview) |text| return collapsedPreview(allocator, text, 160);
    return std.fmt.allocPrint(allocator, "turn {d}", .{turn.turn_index});
}

fn collapsedPreview(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var last_space = false;
    for (text) |ch| {
        const is_space = ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
        if (is_space) {
            if (last_space or out.items.len == 0) continue;
            try out.append(allocator, ' ');
            last_space = true;
        } else {
            try out.append(allocator, ch);
            last_space = false;
        }
        if (out.items.len >= max_len) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    return out.toOwnedSlice(allocator);
}

fn rationaleLines(allocator: std.mem.Allocator, text: []const u8) ![]const []u8 {
    return selectedLines(allocator, text, &.{ "because", "since", "so that", "rationale" });
}

fn assumptionLines(allocator: std.mem.Allocator, text: []const u8) ![]const []u8 {
    return selectedLines(allocator, text, &.{ "assuming", "assumption", "if " });
}

fn selectedLines(allocator: std.mem.Allocator, text: []const u8, needles: []const []const u8) ![]const []u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, &out);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        for (needles) |needle| {
            if (!containsIgnoreCase(line, needle)) continue;
            const preview = try collapsedPreview(allocator, line, 180);
            if (preview.len > 0) try out.append(allocator, preview) else allocator.free(preview);
            break;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn tryHashDecisionId(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, turn: canonical_trace.TurnRecord, selected_route: []const u8, question: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    if (trace.session.session_id) |id| try writer.writeAll(id);
    try writer.writeByte('|');
    try writer.writeAll(turn.turn_id);
    try writer.writeByte('|');
    try writer.writeAll(selected_route);
    try writer.writeByte('|');
    try writer.writeAll(question);
    const canonical = try writer_alloc.toOwnedSlice();
    defer allocator.free(canonical);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "DEC-{s}", .{hex[0..16]});
}

fn filterByDecisionId(allocator: std.mem.Allocator, out: *std.ArrayList(Candidate), wanted: ?[]const u8) void {
    const id = wanted orelse return;
    var write_idx: usize = 0;
    for (out.items, 0..) |*candidate, idx| {
        if (std.mem.eql(u8, candidate.decision_id, id)) {
            if (write_idx != idx) out.items[write_idx] = candidate.*;
            write_idx += 1;
        } else {
            candidate.deinit(allocator);
        }
    }
    out.items.len = write_idx;
}

fn singletonList(allocator: std.mem.Allocator, value: []const u8) ![]const []u8 {
    const out = try allocator.alloc([]u8, 1);
    out[0] = try allocator.dupe(u8, value);
    return out;
}

fn cloneStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []u8 {
    const out = try allocator.alloc([]u8, values.len);
    errdefer {
        for (out[0..]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (values, 0..) |value, idx| out[idx] = try allocator.dupe(u8, value);
    return out;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn inferSessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, base, "rollout-") and std.mem.endsWith(u8, base, ".jsonl")) {
        return base["rollout-".len .. base.len - ".jsonl".len];
    }
    return base;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "explicit prose creates a moderate decision candidate" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "rollout-demo.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout-demo.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "t1"),
        .turn_index = 1,
        .status = .complete,
        .user_message = try std.testing.allocator.dupe(u8, "Which parser route?"),
        .final_answer = try std.testing.allocator.dupe(u8, "I will use the canonical parser because it owns turn identity."),
    });

    const candidates = try compileCandidates(std.testing.allocator, trace, .{});
    defer deinitCandidates(std.testing.allocator, candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqual(Confidence.moderate, candidates[0].confidence);
}

test "outcome prose is not promoted to decision candidate" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "rollout-demo.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout-demo.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "t1"),
        .turn_index = 1,
        .status = .complete,
        .final_answer = try std.testing.allocator.dupe(u8, "Tests passed for the selected route."),
    });

    const candidates = try compileCandidates(std.testing.allocator, trace, .{});
    defer deinitCandidates(std.testing.allocator, candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "regex filter uses pattern alternatives" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "rollout-demo.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout-demo.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "t1"),
        .turn_index = 1,
        .status = .complete,
        .user_message = try std.testing.allocator.dupe(u8, "Which route?"),
        .final_answer = try std.testing.allocator.dupe(u8, "Chosen route: canonical parser"),
    });

    const candidates = try compileCandidates(std.testing.allocator, trace, .{ .regex = "selected route|chosen route" });
    defer deinitCandidates(std.testing.allocator, candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
}
