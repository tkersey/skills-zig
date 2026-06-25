const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;

pub const artifacts = @import("artifacts.zig");
pub const calibration = @import("calibration.zig");
pub const classify = @import("classify.zig");
pub const decisions = @import("decisions.zig");
pub const datasets = @import("datasets.zig");
pub const horizon = @import("horizon.zig");
pub const lineage = @import("lineage.zig");
pub const potential = @import("potential.zig");
pub const regret = @import("regret.zig");
pub const render = @import("render.zig");
pub const shield = @import("shield.zig");
pub const unknowns = @import("unknowns.zig");

pub const audit_version = "SEQ-EXECPAUDIT-v1";
pub const run_version = "EPRUN-v1";
pub const scanner_version = "execution-policy-audit-scanner-v1";

pub const AuditOptions = struct {
    include_workers: bool = false,
    exclude_current: bool = false,
    root: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    policy_root: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    last: ?[]const u8 = null,
};

pub const Identity = struct {
    run_id: []u8,
    session_id: []u8,
    path: []u8,
    repo: ?[]u8,
    started_at: ?[]u8,
    ended_at: ?[]u8,
    model: ?[]u8,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.session_id);
        allocator.free(self.path);
        freeOpt(allocator, self.repo);
        freeOpt(allocator, self.started_at);
        freeOpt(allocator, self.ended_at);
        freeOpt(allocator, self.model);
    }
};

pub const CorpusSnapshot = struct {
    audit_version_text: []u8,
    scanner_version_text: []u8,
    sessions_root: ?[]u8,
    policy_root: ?[]u8,
    session_path_digest: []u8,
    current_session_exclusion: bool,
    worker_inclusion: bool,

    pub fn deinit(self: *CorpusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.audit_version_text);
        allocator.free(self.scanner_version_text);
        freeOpt(allocator, self.sessions_root);
        freeOpt(allocator, self.policy_root);
        allocator.free(self.session_path_digest);
    }
};

pub const RunLedger = struct {
    identity: Identity,
    classification: classify.Result,
    governance: Governance,
    learning: Learning,
    corpus_snapshot: CorpusSnapshot,
    diagnostic_query_json: []u8,

    pub fn deinit(self: *RunLedger, allocator: std.mem.Allocator) void {
        self.identity.deinit(allocator);
        self.classification.deinit(allocator);
        self.governance.deinit(allocator);
        self.learning.deinit(allocator);
        self.corpus_snapshot.deinit(allocator);
        allocator.free(self.diagnostic_query_json);
    }
};

pub const Governance = struct {
    lineage_summary: lineage.Summary,
    horizon_summary: horizon.Summary,
    shield_summary: shield.Summary,
    potential_summary: potential.Summary,
    strict_findings_json: []u8,

    pub fn deinit(self: *Governance, allocator: std.mem.Allocator) void {
        self.lineage_summary.deinit(allocator);
        self.horizon_summary.deinit(allocator);
        self.shield_summary.deinit(allocator);
        self.potential_summary.deinit(allocator);
        allocator.free(self.strict_findings_json);
    }
};

pub const Learning = struct {
    calibration_summary: calibration.Summary,
    unknowns_summary: unknowns.Summary,
    regret_summary: regret.Summary,
    decisions_summary: decisions.Summary,
    repeated_state_action_json: []u8,

    pub fn deinit(self: *Learning, allocator: std.mem.Allocator) void {
        self.calibration_summary.deinit(allocator);
        self.unknowns_summary.deinit(allocator);
        self.regret_summary.deinit(allocator);
        self.decisions_summary.deinit(allocator);
        allocator.free(self.repeated_state_action_json);
    }
};

pub fn compileRunLedger(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, opts: AuditOptions) !RunLedger {
    var identity = try buildIdentity(allocator, trace, opts);
    errdefer identity.deinit(allocator);
    var classification = try classify.classifyTrace(allocator, trace);
    errdefer classification.deinit(allocator);
    var governance = try buildGovernance(allocator, trace, classification.true_run);
    errdefer governance.deinit(allocator);
    var learning = try buildLearning(allocator, trace);
    errdefer learning.deinit(allocator);
    var snapshot = try buildCorpusSnapshot(allocator, trace, opts);
    errdefer snapshot.deinit(allocator);
    const diagnostic = try render.diagnosticQueryJson(allocator, identity.session_id, identity.path);
    errdefer allocator.free(diagnostic);
    return .{
        .identity = identity,
        .classification = classification,
        .governance = governance,
        .learning = learning,
        .corpus_snapshot = snapshot,
        .diagnostic_query_json = diagnostic,
    };
}

fn buildGovernance(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, true_run: bool) !Governance {
    var lineage_summary = try lineage.analyze(allocator, trace, true_run);
    errdefer lineage_summary.deinit(allocator);
    var horizon_summary = try horizon.analyze(allocator, trace, true_run);
    errdefer horizon_summary.deinit(allocator);
    var shield_summary = try shield.analyze(allocator, trace);
    errdefer shield_summary.deinit(allocator);
    var potential_summary = try potential.analyze(allocator, trace, true_run);
    errdefer potential_summary.deinit(allocator);
    const strict = try combineStrictFindings(allocator, &.{
        lineage_summary.lineage_violations_json,
        horizon_summary.strict_findings_json,
        shield_summary.strict_findings_json,
        potential_summary.strict_findings_json,
    });
    errdefer allocator.free(strict);
    return .{
        .lineage_summary = lineage_summary,
        .horizon_summary = horizon_summary,
        .shield_summary = shield_summary,
        .potential_summary = potential_summary,
        .strict_findings_json = strict,
    };
}

fn combineStrictFindings(allocator: std.mem.Allocator, sources: []const []const u8) ![]u8 {
    const candidates = [_][]const u8{
        "mutation_without_epg_eps_epd_lineage",
        "mutation_despite_shield",
        "materialization_gcr_action_mismatch",
        "commitment_horizon_violation",
        "invalid_etr_state_transition",
        "success_terminal_without_proof",
        "source_stale_policy_execution",
    };
    var findings: std.ArrayList([]const u8) = .empty;
    defer findings.deinit(allocator);
    for (candidates) |candidate| {
        for (sources) |source| {
            if (std.mem.indexOf(u8, source, candidate) != null) {
                try findings.append(allocator, candidate);
                break;
            }
        }
    }
    const slice = try findings.toOwnedSlice(allocator);
    defer allocator.free(slice);
    return render.stringArrayJson(allocator, slice);
}

fn buildLearning(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) !Learning {
    var calibration_summary = try calibration.analyze(allocator, trace);
    errdefer calibration_summary.deinit(allocator);
    var unknowns_summary = try unknowns.analyze(allocator, trace);
    errdefer unknowns_summary.deinit(allocator);
    var regret_summary = try regret.analyze(allocator, trace);
    errdefer regret_summary.deinit(allocator);
    var decisions_summary = try decisions.analyze(allocator, trace);
    errdefer decisions_summary.deinit(allocator);
    const recurrence = try repeatedStateActionJson(allocator, trace);
    errdefer allocator.free(recurrence);
    return .{
        .calibration_summary = calibration_summary,
        .unknowns_summary = unknowns_summary,
        .regret_summary = regret_summary,
        .decisions_summary = decisions_summary,
        .repeated_state_action_json = recurrence,
    };
}

fn repeatedStateActionJson(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) ![]u8 {
    var repeated = false;
    for (trace.turns.items) |turn| {
        const text = turn.user_message orelse turn.assistant_preview orelse turn.final_answer orelse "";
        if (std.ascii.indexOfIgnoreCase(text, "same-state/action recurrence") != null or
            std.ascii.indexOfIgnoreCase(text, "repeated failed action") != null or
            std.ascii.indexOfIgnoreCase(text, "negative-ledger") != null)
        {
            repeated = true;
        }
    }
    return if (repeated)
        render.stringArrayJson(allocator, &[_][]const u8{"same_state_action_recurrence_candidate"})
    else
        render.stringArrayJson(allocator, &[_][]const u8{});
}

fn buildIdentity(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, opts: AuditOptions) !Identity {
    const session_id = trace.session.session_id orelse inferSessionIdFromPath(trace.session.path);
    const run_id = try stableRunId(allocator, session_id, trace.session.path);
    errdefer allocator.free(run_id);
    return .{
        .run_id = run_id,
        .session_id = try allocator.dupe(u8, session_id),
        .path = try allocator.dupe(u8, trace.session.path),
        .repo = try dupOpt(allocator, opts.repo orelse trace.session.cwd),
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
        .policy_root = try dupOpt(allocator, opts.policy_root),
        .session_path_digest = try sha256Text(allocator, trace.session.path),
        .current_session_exclusion = opts.exclude_current,
        .worker_inclusion = opts.include_workers,
    };
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
    return std.fmt.allocPrint(allocator, "EPRUN-{s}", .{hex[0..16]});
}

fn sha256Text(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex[0..]});
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

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |v| allocator.free(v);
}

test "run ledger carries governance strict findings separately from classification" {
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
            \\success_terminal reached; proof missing; materialized action differs from EPD
        ),
    });
    var ledger = try compileRunLedger(std.testing.allocator, trace, .{});
    defer ledger.deinit(std.testing.allocator);
    try std.testing.expect(ledger.classification.true_run);
    try std.testing.expect(std.mem.indexOf(u8, ledger.governance.strict_findings_json, "success_terminal_without_proof") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger.governance.strict_findings_json, "materialization_gcr_action_mismatch") != null);
    try std.testing.expectEqual(@as(i64, 1), ledger.learning.calibration_summary.transition_count);
    try std.testing.expect(std.mem.indexOf(u8, ledger.learning.decisions_summary.decision_ids_json, "p+1+s1+d") != null);
}
