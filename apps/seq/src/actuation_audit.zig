const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const output = @import("output/mod.zig");

pub const classify = @import("actuation/classify.zig");
pub const render = @import("actuation/render.zig");
pub const refactor_kernel = @import("actuation/refactor_kernel.zig");

pub const audit_version = "SEQ-ACTAUDIT-v1";
pub const run_version = "SEQ-ACTRUN-v1";
pub const scanner_version = "actuation-audit-scanner-v1";

pub const AuditOptions = struct {
    strict: bool = false,
    include_workers: bool = false,
    include_excerpts: bool = false,
    exclude_current: bool = false,
    root: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    last: ?[]const u8 = null,
};

pub const Identity = struct {
    run_id: []u8,
    session_id: []u8,
    path: []u8,
    repo: ?[]u8,
    branch: ?[]u8,
    started_at: ?[]u8,
    ended_at: ?[]u8,
    model: ?[]u8,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.session_id);
        allocator.free(self.path);
        freeOpt(allocator, self.repo);
        freeOpt(allocator, self.branch);
        freeOpt(allocator, self.started_at);
        freeOpt(allocator, self.ended_at);
        freeOpt(allocator, self.model);
    }
};

pub const CorpusSnapshot = struct {
    audit_version_text: []u8,
    scanner_version_text: []u8,
    sessions_root: ?[]u8,
    candidate_files: usize,
    files_opened: usize,
    session_path_digest: []u8,
    time_window: ?[]u8,
    current_session_exclusion: bool,
    worker_inclusion: bool,

    pub fn deinit(self: *CorpusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.audit_version_text);
        allocator.free(self.scanner_version_text);
        freeOpt(allocator, self.sessions_root);
        allocator.free(self.session_path_digest);
        freeOpt(allocator, self.time_window);
    }
};

pub const RunLedger = struct {
    identity: Identity,
    classification: classify.Result,
    refactor_kernel: refactor_kernel.Result,
    corpus_snapshot: CorpusSnapshot,
    limitations: [][]u8,
    diagnostic_query_json: []u8,

    pub fn deinit(self: *RunLedger, allocator: std.mem.Allocator) void {
        self.identity.deinit(allocator);
        self.classification.deinit(allocator);
        self.refactor_kernel.deinit(allocator);
        self.corpus_snapshot.deinit(allocator);
        freeStringList(allocator, self.limitations);
        allocator.free(self.diagnostic_query_json);
    }
};

pub fn compileRunLedger(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, opts: AuditOptions) !RunLedger {
    var classification = try classify.classifyTrace(allocator, trace, .{ .strict = opts.strict });
    errdefer classification.deinit(allocator);
    var rk = try refactor_kernel.analyzeTrace(allocator, trace, classification.true_run);
    errdefer rk.deinit(allocator);
    var identity = try buildIdentity(allocator, trace, opts);
    errdefer identity.deinit(allocator);
    var snapshot = try buildCorpusSnapshot(allocator, trace, opts);
    errdefer snapshot.deinit(allocator);
    const limitations = try buildLimitations(allocator, trace, opts);
    errdefer freeStringList(allocator, limitations);
    const diagnostic = try render.diagnosticQueryJson(allocator, identity.session_id, identity.path);
    errdefer allocator.free(diagnostic);
    return .{
        .identity = identity,
        .classification = classification,
        .refactor_kernel = rk,
        .corpus_snapshot = snapshot,
        .limitations = limitations,
        .diagnostic_query_json = diagnostic,
    };
}

pub fn renderRunJson(allocator: std.mem.Allocator, ledger: RunLedger) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeAll("{\"run_version\":");
    try output.writeJsonString(writer, run_version);
    try writer.writeAll(",\"identity\":{\"run_id\":");
    try output.writeJsonString(writer, ledger.identity.run_id);
    try writer.writeAll(",\"session_id\":");
    try output.writeJsonString(writer, ledger.identity.session_id);
    try writer.writeAll(",\"path\":");
    try output.writeJsonString(writer, ledger.identity.path);
    try writer.writeAll(",\"repo\":");
    try writeJsonOpt(writer, ledger.identity.repo);
    try writer.writeAll(",\"branch\":");
    try writeJsonOpt(writer, ledger.identity.branch);
    try writer.writeAll(",\"started_at\":");
    try writeJsonOpt(writer, ledger.identity.started_at);
    try writer.writeAll(",\"ended_at\":");
    try writeJsonOpt(writer, ledger.identity.ended_at);
    try writer.writeAll(",\"model\":");
    try writeJsonOpt(writer, ledger.identity.model);
    try writer.writeAll("},\"classification\":{\"candidate\":");
    try writer.writeAll(if (ledger.classification.candidate) "true" else "false");
    try writer.writeAll(",\"true_actuating\":");
    try writer.writeAll(if (ledger.classification.true_run) "true" else "false");
    try writer.writeAll(",\"evidence_refs\":");
    try render.writeStringArray(writer, ledger.classification.evidence_refs);
    try writer.writeAll(",\"contamination_flags\":");
    try render.writeStringArray(writer, ledger.classification.contamination_flags);
    try writer.writeAll(",\"reason\":");
    try output.writeJsonString(writer, ledger.classification.reason);
    try writer.writeAll("},\"refactor_kernel\":");
    try writeRefactorKernelJson(writer, ledger.refactor_kernel);
    try writer.writeAll(",\"corpus_snapshot\":{\"audit_version\":");
    try output.writeJsonString(writer, ledger.corpus_snapshot.audit_version_text);
    try writer.writeAll(",\"scanner_version\":");
    try output.writeJsonString(writer, ledger.corpus_snapshot.scanner_version_text);
    try writer.writeAll(",\"candidate_files\":");
    try writer.print("{d}", .{ledger.corpus_snapshot.candidate_files});
    try writer.writeAll(",\"files_opened\":");
    try writer.print("{d}", .{ledger.corpus_snapshot.files_opened});
    try writer.writeAll(",\"session_path_digest\":");
    try output.writeJsonString(writer, ledger.corpus_snapshot.session_path_digest);
    try writer.writeAll(",\"current_session_exclusion\":");
    try writer.writeAll(if (ledger.corpus_snapshot.current_session_exclusion) "true" else "false");
    try writer.writeAll(",\"worker_inclusion\":");
    try writer.writeAll(if (ledger.corpus_snapshot.worker_inclusion) "true" else "false");
    try writer.writeAll("},\"limitations\":");
    try render.writeStringArray(writer, ledger.limitations);
    try writer.writeAll(",\"diagnostic_query_json\":");
    try output.writeJsonString(writer, ledger.diagnostic_query_json);
    try writer.writeAll("}");
    return writer_alloc.toOwnedSlice();
}

pub fn writeRefactorKernelJson(writer: anytype, rk: refactor_kernel.Result) !void {
    try writer.writeAll("{\"classification\":");
    try output.writeJsonString(writer, rk.classification);
    try writer.writeAll(",\"confidence\":");
    try output.writeJsonString(writer, rk.confidence);
    try writer.writeAll(",\"formal_decision_present\":");
    try writeJsonBool(writer, rk.formal_decision_present);
    try writer.writeAll(",\"outcome_present\":");
    try writeJsonBool(writer, rk.outcome_present);
    try writer.writeAll(",\"explicit_phrase_present\":");
    try writeJsonBool(writer, rk.explicit_phrase_present);
    try writer.writeAll(",\"selected_route_present\":");
    try writeJsonBool(writer, rk.selected_route_present);
    try writer.writeAll(",\"next_resolution_mode_present\":");
    try writeJsonBool(writer, rk.next_resolution_mode_present);
    try writer.writeAll(",\"potential_hidden_kernel\":");
    try writeJsonBool(writer, rk.potential_hidden_kernel);
    try writer.writeAll(",\"graph_bypass\":");
    try writeJsonBool(writer, rk.graph_bypass);
    try writer.writeAll(",\"patch_calls\":");
    try writer.print("{d}", .{rk.patch_calls});
    try writer.writeAll(",\"update_plan_calls\":");
    try writer.print("{d}", .{rk.update_plan_calls});
    try writer.writeAll(",\"mutations_without_graph_control\":");
    try writer.print("{d}", .{rk.mutations_without_graph_control});
    try writer.writeAll(",\"accepted_liability_markers\":");
    try writer.print("{d}", .{rk.accepted_liability_markers});
    try writer.writeAll(",\"owner_boundary_markers\":");
    try writer.print("{d}", .{rk.owner_boundary_markers});
    try writer.writeAll(",\"review_fold_markers\":");
    try writer.print("{d}", .{rk.review_fold_markers});
    try writer.writeAll(",\"cas_bottleneck_markers\":");
    try writer.print("{d}", .{rk.cas_bottleneck_markers});
    try writer.writeAll(",\"rko_graph_bypass_yes\":");
    try writeJsonBool(writer, rk.rko_graph_bypass_yes);
    try writer.writeAll(",\"rko_mutations_without_control_nonzero\":");
    try writeJsonBool(writer, rk.rko_mutations_without_control_nonzero);
    try writer.writeAll(",\"reasons\":");
    try render.writeStringArray(writer, rk.reasons);
    try writer.writeByte('}');
}

fn writeJsonBool(writer: anytype, value: bool) !void {
    try writer.writeAll(if (value) "true" else "false");
}

fn buildIdentity(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, opts: AuditOptions) !Identity {
    const session_id = trace.session.session_id orelse inferSessionIdFromPath(trace.session.path);
    const run_id = try stableRunId(allocator, session_id, trace.session.path);
    errdefer allocator.free(run_id);
    return .{
        .run_id = run_id,
        .session_id = try allocator.dupe(u8, session_id),
        .path = try allocator.dupe(u8, trace.session.path),
        .repo = try dupOpt(allocator, opts.repo orelse trace.session.cwd orelse opts.workdir),
        .branch = try dupOpt(allocator, trace.session.git_branch),
        .started_at = try dupOpt(allocator, trace.session.start_time orelse firstTurnStart(trace)),
        .ended_at = try dupOpt(allocator, trace.session.end_time orelse lastTurnEnd(trace)),
        .model = try dupOpt(allocator, trace.session.model),
    };
}

fn buildCorpusSnapshot(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, opts: AuditOptions) !CorpusSnapshot {
    return .{
        .audit_version_text = try allocator.dupe(u8, audit_version),
        .scanner_version_text = try allocator.dupe(u8, scanner_version),
        .sessions_root = try dupOpt(allocator, opts.root),
        .candidate_files = 1,
        .files_opened = 1,
        .session_path_digest = try sha256Text(allocator, trace.session.path),
        .time_window = try timeWindowText(allocator, opts),
        .current_session_exclusion = opts.exclude_current,
        .worker_inclusion = opts.include_workers,
    };
}

fn buildLimitations(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, opts: AuditOptions) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    if (!opts.include_workers) try out.append(allocator, try allocator.dupe(u8, "worker sessions excluded"));
    if (!opts.include_excerpts) try out.append(allocator, try allocator.dupe(u8, "raw prompts and full excerpts excluded"));
    if (trace.warnings.items.len > 0) try out.append(allocator, try allocator.dupe(u8, "canonical trace parser warnings present"));
    return out.toOwnedSlice(allocator);
}

fn stableRunId(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    try writer_alloc.writer.print("{s}|{s}", .{ session_id, path });
    const canonical = try writer_alloc.toOwnedSlice();
    defer allocator.free(canonical);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "ACTRUN-{s}", .{hex[0..16]});
}

fn sha256Text(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex[0..]});
}

fn timeWindowText(allocator: std.mem.Allocator, opts: AuditOptions) !?[]u8 {
    if (opts.last) |last| return try std.fmt.allocPrint(allocator, "last:{s}", .{last});
    if (opts.since == null and opts.until == null) return null;
    return try std.fmt.allocPrint(allocator, "since:{s}|until:{s}", .{ opts.since orelse "", opts.until orelse "" });
}

fn firstTurnStart(trace: canonical_trace.CanonicalSessionTrace) ?[]const u8 {
    if (trace.turns.items.len == 0) return null;
    return trace.turns.items[0].started_at;
}

fn lastTurnEnd(trace: canonical_trace.CanonicalSessionTrace) ?[]const u8 {
    var idx = trace.turns.items.len;
    while (idx > 0) {
        idx -= 1;
        if (trace.turns.items[idx].completed_at) |value| return value;
    }
    return null;
}

fn inferSessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".jsonl")) return base[0 .. base.len - ".jsonl".len];
    return base;
}

fn dupOpt(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn writeJsonOpt(writer: anytype, value: ?[]const u8) !void {
    if (value) |v| try output.writeJsonString(writer, v) else try writer.writeAll("null");
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |v| allocator.free(v);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "actuation ledger classifies explicit run and emits bounded json" {
    var trace = try fixtureTrace(std.testing.allocator, "$actuating $land", "Using $actuating; reading skill.");
    defer trace.deinit(std.testing.allocator);
    try trace.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"),
        .tool_name = try std.testing.allocator.dupe(u8, "exec_command"),
        .command_text = try std.testing.allocator.dupe(u8, "sed -n '1,260p' /Users/tk/.dotfiles/codex/skills/actuating/SKILL.md"),
        .kind = .exec_command,
    });

    var ledger = try compileRunLedger(std.testing.allocator, trace, .{ .strict = true, .repo = "/repo", .root = "/sessions" });
    defer ledger.deinit(std.testing.allocator);
    try std.testing.expect(ledger.classification.candidate);
    try std.testing.expect(ledger.classification.true_run);
    try std.testing.expect(ledger.classification.evidence_refs.len >= 2);
    try std.testing.expect(std.mem.startsWith(u8, ledger.identity.run_id, "ACTRUN-"));
    try std.testing.expect(std.mem.indexOf(u8, ledger.diagnostic_query_json, "\"dataset\":\"actuation_runs\"") != null);

    const json = try renderRunJson(std.testing.allocator, ledger);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"true_actuating\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"refactor_kernel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "$actuating") == null);
}

test "actuation ledger excludes weak pasted skill and accepts ASR artifact" {
    var weak_trace = try fixtureTrace(std.testing.allocator, "<skill><name>actuating</name>$actuating example</skill>", null);
    defer weak_trace.deinit(std.testing.allocator);
    var weak = try compileRunLedger(std.testing.allocator, weak_trace, .{ .strict = true });
    defer weak.deinit(std.testing.allocator);
    try std.testing.expect(!weak.classification.candidate);
    try std.testing.expect(!weak.classification.true_run);
    try std.testing.expect(weak.classification.contamination_flags.len > 0);

    var asr_trace = try fixtureTrace(std.testing.allocator, "ordinary request", "ASR-v2: actuation summary ready");
    defer asr_trace.deinit(std.testing.allocator);
    var asr = try compileRunLedger(std.testing.allocator, asr_trace, .{ .strict = true });
    defer asr.deinit(std.testing.allocator);
    try std.testing.expect(asr.classification.true_run);
}

fn fixtureTrace(allocator: std.mem.Allocator, user_text: []const u8, assistant_text: ?[]const u8) !canonical_trace.CanonicalSessionTrace {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(allocator, "/tmp/run.jsonl"),
    };
    errdefer trace.deinit(allocator);
    trace.session.session_id = try allocator.dupe(u8, "session-1");
    trace.session.cwd = try allocator.dupe(u8, "/repo");
    trace.session.git_branch = try allocator.dupe(u8, "feature");
    trace.session.model = try allocator.dupe(u8, "gpt-test");
    trace.session.start_time = try allocator.dupe(u8, "2026-06-23T00:00:00Z");
    trace.session.end_time = try allocator.dupe(u8, "2026-06-23T00:01:00Z");
    try trace.turns.append(allocator, .{
        .path = try allocator.dupe(u8, "/tmp/run.jsonl"),
        .turn_id = try allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .started_at = try allocator.dupe(u8, "2026-06-23T00:00:00Z"),
        .completed_at = try allocator.dupe(u8, "2026-06-23T00:01:00Z"),
        .user_message = try allocator.dupe(u8, user_text),
        .final_answer = if (assistant_text) |text| try allocator.dupe(u8, text) else null,
    });
    return trace;
}
