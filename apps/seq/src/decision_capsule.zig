const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const decision_anchor = retrace_core.decision_anchor;
const historical_decisions = @import("historical_decisions.zig");
const dcp_schema = retrace_core.dcp_schema;
const output = @import("output/mod.zig");

pub const Mode = enum {
    capsule,
    candidates,
    anchors,
    validate,

    pub fn parse(text: ?[]const u8) !Mode {
        const value = text orelse return .capsule;
        if (std.ascii.eqlIgnoreCase(value, "capsule")) return .capsule;
        if (std.ascii.eqlIgnoreCase(value, "candidates")) return .candidates;
        if (std.ascii.eqlIgnoreCase(value, "anchors")) return .anchors;
        if (std.ascii.eqlIgnoreCase(value, "validate")) return .validate;
        return error.InvalidModeArg;
    }
};

pub const OutcomePolicy = enum {
    explicit,
    conservative,
    none,

    pub fn parse(text: ?[]const u8) !OutcomePolicy {
        const value = text orelse return .conservative;
        if (std.ascii.eqlIgnoreCase(value, "explicit")) return .explicit;
        if (std.ascii.eqlIgnoreCase(value, "conservative")) return .conservative;
        if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
        return error.InvalidModeArg;
    }
};

pub const BuildOptions = struct {
    filters: historical_decisions.Filters = .{},
    outcome_policy: OutcomePolicy = .conservative,
    strict: bool = true,
    include_excerpts: bool = false,
    excerpt_chars: usize = 240,
    source_thread_id: ?[]const u8 = null,
};

pub const CapsuleResult = struct {
    json: []u8,
    packet_id: []u8,
    decision_id: []u8,
    anchors_available: []const []u8,
    warning_codes: []const []u8,

    pub fn deinit(self: *CapsuleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        allocator.free(self.packet_id);
        allocator.free(self.decision_id);
        for (self.anchors_available) |value| allocator.free(value);
        allocator.free(self.anchors_available);
        for (self.warning_codes) |value| allocator.free(value);
        allocator.free(self.warning_codes);
    }
};

pub const OutcomeBoundary = struct {
    first_turn_index: ?i64 = null,
    ambiguous: bool = false,
};

pub fn buildCapsuleJson(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    rollout_path: []const u8,
    opts: BuildOptions,
) !CapsuleResult {
    const candidates = try historical_decisions.compileCandidates(allocator, trace, opts.filters);
    defer historical_decisions.deinitCandidates(allocator, candidates);
    const selected_index = try selectCandidate(candidates, opts.strict);
    const selected = candidates[selected_index];

    const outcome = detectOutcome(trace, selected.turn_index, opts.outcome_policy);
    var anchors = try decision_anchor.compute(allocator, trace, selected.turn_index, outcome.first_turn_index, outcome.ambiguous);
    defer anchors.deinit(allocator);
    const source_digest = try decision_anchor.sourceTurnDigest(allocator, trace);
    defer allocator.free(source_digest);
    const source_episode_id = try dcp_schema.sourceEpisodeIdAlloc(allocator, selected.session_id, selected.turn_id);
    defer allocator.free(source_episode_id);

    var body_without_id = std.Io.Writer.Allocating.init(allocator);
    defer body_without_id.deinit();
    try writePacketBody(&body_without_id.writer, trace, rollout_path, selected, anchors, source_digest, source_episode_id, outcome, null, opts);
    const canonical_body = try body_without_id.toOwnedSlice();
    defer allocator.free(canonical_body);
    const packet_id = try dcp_schema.packetIdForTextExcludingPacketId(allocator, canonical_body);
    errdefer allocator.free(packet_id);

    var full = std.Io.Writer.Allocating.init(allocator);
    defer full.deinit();
    try writePacketBody(&full.writer, trace, rollout_path, selected, anchors, source_digest, source_episode_id, outcome, packet_id, opts);
    const json = try full.toOwnedSlice();
    errdefer allocator.free(json);

    const available = try availableAnchorNames(allocator, anchors);
    errdefer freeStringSlice(allocator, available);
    const warnings = try warningCodes(allocator, trace, anchors, outcome);
    errdefer freeStringSlice(allocator, warnings);
    return .{
        .json = json,
        .packet_id = packet_id,
        .decision_id = try allocator.dupe(u8, selected.decision_id),
        .anchors_available = available,
        .warning_codes = warnings,
    };
}

pub fn compileCandidates(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, filters: historical_decisions.Filters) ![]historical_decisions.Candidate {
    return historical_decisions.compileCandidates(allocator, trace, filters);
}

pub fn deinitCandidates(allocator: std.mem.Allocator, candidates: []historical_decisions.Candidate) void {
    historical_decisions.deinitCandidates(allocator, candidates);
}

pub fn detectOutcome(trace: canonical_trace.CanonicalSessionTrace, decision_turn_index: i64, policy: OutcomePolicy) OutcomeBoundary {
    if (policy == .none) return .{};
    for (trace.turns.items) |turn| {
        if (turn.turn_index <= decision_turn_index) continue;
        const user = turn.user_message orelse "";
        const assistant = turn.final_answer orelse "";
        const combined_has_explicit =
            containsOutcomeSignal(user) or
            containsOutcomeSignal(assistant) or
            turnHasOutcomeTool(trace, turn.turn_index);
        if (combined_has_explicit) return .{ .first_turn_index = turn.turn_index };
        if (policy == .conservative and (containsConservativeOutcome(user) or containsConservativeOutcome(assistant))) {
            return .{ .first_turn_index = turn.turn_index };
        }
    }
    return .{};
}

fn selectCandidate(candidates: []historical_decisions.Candidate, strict: bool) !usize {
    if (candidates.len == 0) return error.NoDecisionCandidate;
    var best_idx: usize = 0;
    var comparable: usize = 0;
    var best_score = candidates[0].confidence.score();
    for (candidates, 0..) |candidate, idx| {
        const score = candidate.confidence.score();
        if (score > best_score) {
            best_score = score;
            best_idx = idx;
            comparable = 0;
        } else if (idx != best_idx and @abs(score - best_score) < 0.001) {
            comparable += 1;
        }
    }
    if (strict and best_score < historical_decisions.Confidence.moderate.score()) return error.NoDecisionCandidate;
    if (comparable > 0) return error.DecisionAmbiguous;
    return best_idx;
}

fn writePacketBody(
    writer: anytype,
    trace: canonical_trace.CanonicalSessionTrace,
    rollout_path: []const u8,
    candidate: historical_decisions.Candidate,
    anchors: decision_anchor.Anchors,
    source_digest: []const u8,
    source_episode_id: []const u8,
    outcome: OutcomeBoundary,
    packet_id: ?[]const u8,
    opts: BuildOptions,
) !void {
    try writer.writeAll("{\n  \"decision_context_packet\": {\n");
    try writer.writeAll("    \"anchors\": {\n");
    try writeAnchor(writer, "pre_decision", anchors.pre_decision, true);
    try writeAnchor(writer, "post_decision_pre_outcome", anchors.post_decision_pre_outcome, true);
    try writeAnchor(writer, "outcome_aware", anchors.outcome_aware, false);
    try writer.writeAll("    },\n");

    try writer.writeAll("    \"artifact_state\": {\n");
    try writeJsonFieldOpt(writer, "branch", trace.session.git_branch, true, 6);
    try writeJsonFieldOpt(writer, "cwd", trace.session.cwd, true, 6);
    try writeJsonFieldNull(writer, "dependency_refs", true, 6, true);
    try writeJsonFieldNull(writer, "dirty_fingerprint", true, 6, false);
    try writeJsonFieldNull(writer, "dirty_patch_ref", true, 6, false);
    try writeJsonFieldNull(writer, "generated_artifact_refs", true, 6, true);
    try writeJsonFieldOpt(writer, "head", trace.session.git_commit_hash, true, 6);
    try writeJsonFieldOpt(writer, "repository_root", trace.session.cwd, true, 6);
    try writeJsonField(writer, "reconstructability", reconstructability(trace), false, 6);
    try writer.writeAll("    },\n");

    try writer.writeAll("    \"contamination\": {\n");
    try writeBoolField(writer, "current_audit_prompt", containsContamination(trace, "SEQ-DECISION-CAPSULE") or containsContamination(trace, "$spec-pipeline"), true, 6);
    try writeBoolField(writer, "generated_reports", containsContamination(trace, "generated report") or containsContamination(trace, "PROPOSED_PLAN"), true, 6);
    try writeBoolField(writer, "injected_skill_blocks", containsContamination(trace, "<skills_instructions>") or containsContamination(trace, "SKILL.md"), true, 6);
    try writeBoolField(writer, "quoted_material", containsContamination(trace, "```text") or containsContamination(trace, "<INSTRUCTIONS>"), false, 6);
    try writer.writeAll("    },\n");

    try writer.writeAll("    \"episode\": {\n");
    try writeStringArrayField(writer, "evidence_refs", candidate.evidence_refs, true, 6);
    try writeStringArrayField(writer, "explicit_assumptions", candidate.explicit_assumptions, true, 6);
    try writeStringArrayField(writer, "explicit_rationale", candidate.explicit_rationale, true, 6);
    try writeStringArrayField(writer, "outcome_refs", if (outcome.first_turn_index != null) &[_][]const u8{"first_outcome_turn"} else &[_][]const u8{}, true, 6);
    try writeJsonField(writer, "question", candidate.question, true, 6);
    try writeStringArrayField(writer, "rejected_routes", candidate.rejected_routes, true, 6);
    try writeJsonField(writer, "selected_route", candidate.selected_route, true, 6);
    try writeStringArrayField(writer, "skills_and_instructions", skillsRefs(trace), true, 6);
    try writeStringArrayField(writer, "tools_and_artifacts", toolsRefs(trace, candidate.turn_index), false, 6);
    try writer.writeAll("    },\n");

    try writeStringArrayField(writer, "limitations", limitationList(anchors, trace), true, 4);
    if (packet_id) |id| try writeJsonField(writer, "packet_id", id, true, 4);
    try writeJsonField(writer, "packet_version", dcp_schema.version, true, 4);

    try writer.writeAll("    \"source\": {\n");
    try writeJsonField(writer, "decision_id", candidate.decision_id, true, 6);
    try writeJsonFieldOpt(writer, "root_session_id", trace.session.session_id, true, 6);
    try writeJsonField(writer, "rollout_path", rollout_path, true, 6);
    try writeJsonField(writer, "session_id", candidate.session_id, true, 6);
    try writeJsonField(writer, "source_episode_id", source_episode_id, true, 6);
    try writeJsonFieldOpt(writer, "source_codex_version", trace.session.cli_version, true, 6);
    try writeJsonFieldOpt(writer, "source_model", trace.session.model, true, 6);
    try writeJsonFieldOpt(writer, "source_model_provider", trace.session.model_provider, true, 6);
    try writeJsonFieldOpt(writer, "thread_id", opts.source_thread_id, true, 6);
    try writeJsonFieldNull(writer, "worker_session_id", false, 6, false);
    try writer.writeAll("    },\n");

    try writer.writeAll("    \"turns\": {\n");
    try writeJsonFieldOpt(writer, "decision_turn_id", candidate.turn_id, true, 6);
    try writeIntField(writer, "decision_turn_index", candidate.turn_index, true, 6);
    try writeIntOrNullField(writer, "first_outcome_turn_index", outcome.first_turn_index, true, 6);
    try writeJsonFieldOpt(writer, "following_turn_id", turnIdAt(trace, candidate.turn_index + 1), true, 6);
    try writeJsonFieldOpt(writer, "preceding_turn_id", turnIdAt(trace, candidate.turn_index - 1), true, 6);
    try writeJsonField(writer, "source_turn_digest", source_digest, true, 6);
    try writeIntField(writer, "total_turns", @intCast(trace.turns.items.len), false, 6);
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n}\n");
}

fn writeAnchor(writer: anytype, name: []const u8, anchor: decision_anchor.Anchor, comma: bool) !void {
    try writer.print("      \"{s}\": {{\n", .{name});
    try writeStringOrNullField(writer, "anchor_digest", anchor.anchor_digest, true, 8);
    try writeBoolField(writer, "available", anchor.available, true, 8);
    try writeIntOrNullField(writer, "drop_last_n_turns", anchor.drop_last_n_turns, true, 8);
    try writeIntOrNullField(writer, "keep_through_turn_index", anchor.keep_through_turn_index, false, 8);
    try writer.writeAll(if (comma) "      },\n" else "      }\n");
}

fn reconstructability(trace: canonical_trace.CanonicalSessionTrace) []const u8 {
    if (trace.session.git_commit_hash != null) return "head_only";
    if (trace.session.path.len > 0) return "transcript_only";
    return "unavailable";
}

fn turnIdAt(trace: canonical_trace.CanonicalSessionTrace, index: i64) ?[]const u8 {
    if (index < 1) return null;
    for (trace.turns.items) |turn| if (turn.turn_index == index) return turn.turn_id;
    return null;
}

fn containsOutcomeSignal(text: []const u8) bool {
    const needles = [_][]const u8{ "test passed", "test failed", "tests passed", "tests failed", "review finding", "verdict", "rollback", "reversal", "merged", "deployment", "blocked", "error:" };
    for (needles) |needle| if (std.ascii.indexOfIgnoreCase(text, needle) != null) return true;
    return false;
}

fn containsConservativeOutcome(text: []const u8) bool {
    const needles = [_][]const u8{ "learned", "revealed", "turns out", "now know", "failed because", "passes now" };
    for (needles) |needle| if (std.ascii.indexOfIgnoreCase(text, needle) != null) return true;
    return false;
}

fn turnHasOutcomeTool(trace: canonical_trace.CanonicalSessionTrace, turn_index: i64) bool {
    for (trace.tools.items) |tool| {
        if (tool.turn_index == null or tool.turn_index.? != turn_index) continue;
        if (tool.exit_code != null) return true;
        if (tool.output_text) |text| if (containsOutcomeSignal(text)) return true;
    }
    return false;
}

fn containsContamination(trace: canonical_trace.CanonicalSessionTrace, needle: []const u8) bool {
    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| if (std.mem.indexOf(u8, text, needle) != null) return true;
        if (turn.final_answer) |text| if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn skillsRefs(trace: canonical_trace.CanonicalSessionTrace) []const []const u8 {
    _ = trace;
    return &.{};
}

fn toolsRefs(trace: canonical_trace.CanonicalSessionTrace, turn_index: i64) []const []const u8 {
    _ = trace;
    _ = turn_index;
    return &.{};
}

fn limitationList(anchors: decision_anchor.Anchors, trace: canonical_trace.CanonicalSessionTrace) []const []const u8 {
    _ = trace;
    if (!anchors.pre_decision.available) return &.{"pre_decision_unavailable"};
    if (!anchors.post_decision_pre_outcome.available) return &.{"post_decision_pre_outcome_unavailable"};
    return &.{};
}

fn availableAnchorNames(allocator: std.mem.Allocator, anchors: decision_anchor.Anchors) ![]const []u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, &out);
    if (anchors.pre_decision.available) try out.append(allocator, try allocator.dupe(u8, "pre_decision"));
    if (anchors.post_decision_pre_outcome.available) try out.append(allocator, try allocator.dupe(u8, "post_decision_pre_outcome"));
    if (anchors.outcome_aware.available) try out.append(allocator, try allocator.dupe(u8, "outcome_aware"));
    return out.toOwnedSlice(allocator);
}

fn warningCodes(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, anchors: decision_anchor.Anchors, outcome: OutcomeBoundary) ![]const []u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, &out);
    if (reconstructability(trace)[0] != 'e') try out.append(allocator, try allocator.dupe(u8, "artifact_state_not_exact"));
    if (!anchors.pre_decision.available) try out.append(allocator, try allocator.dupe(u8, "pre_decision_unavailable"));
    if (!anchors.post_decision_pre_outcome.available) try out.append(allocator, try allocator.dupe(u8, "post_decision_pre_outcome_unavailable"));
    if (outcome.ambiguous) try out.append(allocator, try allocator.dupe(u8, "outcome_boundary_ambiguous"));
    return out.toOwnedSlice(allocator);
}

fn writeJsonField(writer: anytype, name: []const u8, value: []const u8, comma: bool, indent: usize) !void {
    try writeIndent(writer, indent);
    try output.writeJsonString(writer, name);
    try writer.writeAll(": ");
    try output.writeJsonString(writer, value);
    try writer.writeAll(if (comma) ",\n" else "\n");
}

fn writeJsonFieldOpt(writer: anytype, name: []const u8, value: ?[]const u8, comma: bool, indent: usize) !void {
    try writeIndent(writer, indent);
    try output.writeJsonString(writer, name);
    try writer.writeAll(": ");
    if (value) |text| try output.writeJsonString(writer, text) else try writer.writeAll("null");
    try writer.writeAll(if (comma) ",\n" else "\n");
}

fn writeJsonFieldNull(writer: anytype, name: []const u8, comma: bool, indent: usize, array: bool) !void {
    try writeIndent(writer, indent);
    try output.writeJsonString(writer, name);
    try writer.writeAll(": ");
    try writer.writeAll(if (array) "[]" else "null");
    try writer.writeAll(if (comma) ",\n" else "\n");
}

fn writeStringOrNullField(writer: anytype, name: []const u8, value: ?[]const u8, comma: bool, indent: usize) !void {
    try writeJsonFieldOpt(writer, name, value, comma, indent);
}

fn writeBoolField(writer: anytype, name: []const u8, value: bool, comma: bool, indent: usize) !void {
    try writeIndent(writer, indent);
    try output.writeJsonString(writer, name);
    try writer.writeAll(if (value) ": true" else ": false");
    try writer.writeAll(if (comma) ",\n" else "\n");
}

fn writeIntField(writer: anytype, name: []const u8, value: i64, comma: bool, indent: usize) !void {
    try writeIndent(writer, indent);
    try output.writeJsonString(writer, name);
    try writer.print(": {d}", .{value});
    try writer.writeAll(if (comma) ",\n" else "\n");
}

fn writeIntOrNullField(writer: anytype, name: []const u8, value: ?i64, comma: bool, indent: usize) !void {
    try writeIndent(writer, indent);
    try output.writeJsonString(writer, name);
    if (value) |number| try writer.print(": {d}", .{number}) else try writer.writeAll(": null");
    try writer.writeAll(if (comma) ",\n" else "\n");
}

fn writeStringArrayField(writer: anytype, name: []const u8, values: []const []const u8, comma: bool, indent: usize) !void {
    try writeIndent(writer, indent);
    try output.writeJsonString(writer, name);
    try writer.writeAll(": [");
    for (values, 0..) |value, idx| {
        if (idx > 0) try writer.writeAll(", ");
        try output.writeJsonString(writer, value);
    }
    try writer.writeAll(if (comma) "],\n" else "]\n");
}

fn writeIndent(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(' ');
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

test "capsule output validates against native schema" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "rollout-demo.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.session_id = try std.testing.allocator.dupe(u8, "demo");
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout-demo.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "t1"),
        .turn_index = 1,
        .status = .complete,
        .user_message = try std.testing.allocator.dupe(u8, "Which route?"),
        .final_answer = try std.testing.allocator.dupe(u8, "I will use route A because it is explicit."),
    });
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout-demo.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "t2"),
        .turn_index = 2,
        .status = .complete,
        .final_answer = try std.testing.allocator.dupe(u8, "Tests passed."),
    });
    var result = try buildCapsuleJson(std.testing.allocator, trace, "rollout-demo.jsonl", .{ .strict = true });
    defer result.deinit(std.testing.allocator);
    var report = try dcp_schema.validateText(std.testing.allocator, result.json);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"source_episode_id\": \"session:demo#turn:t1\"") != null);
}

test "capsule emits explicit source thread id override" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "rollout-demo.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.session_id = try std.testing.allocator.dupe(u8, "demo");
    trace.session.thread_name = try std.testing.allocator.dupe(u8, "Display Name");
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout-demo.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "t1"),
        .turn_index = 1,
        .status = .complete,
        .user_message = try std.testing.allocator.dupe(u8, "Which route?"),
        .final_answer = try std.testing.allocator.dupe(u8, "I will use route A because it is explicit."),
    });
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout-demo.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "t2"),
        .turn_index = 2,
        .status = .complete,
        .final_answer = try std.testing.allocator.dupe(u8, "Tests passed."),
    });

    var without_override = try buildCapsuleJson(std.testing.allocator, trace, "rollout-demo.jsonl", .{ .strict = true });
    defer without_override.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, without_override.json, "\"thread_id\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_override.json, "\"thread_id\": \"Display Name\"") == null);

    var with_override = try buildCapsuleJson(std.testing.allocator, trace, "rollout-demo.jsonl", .{ .strict = true, .source_thread_id = "thread-123" });
    defer with_override.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, with_override.json, "\"thread_id\": \"thread-123\"") != null);
}
