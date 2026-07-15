const std = @import("std");

const MaxInputBytes = 4 * 1024 * 1024;

const Phase = enum {
    preflight,
    closeout,

    fn parse(raw: []const u8) ?Phase {
        if (std.mem.eql(u8, raw, "preflight")) return .preflight;
        if (std.mem.eql(u8, raw, "closeout")) return .closeout;
        return null;
    }

    fn name(self: Phase) []const u8 {
        return @tagName(self);
    }
};

const Args = struct {
    phase: Phase,
    input_path: []const u8,
};

const Witness = struct {
    statement: []const u8,
    verifier: []const []const u8,
};

const OwnerRefinement = struct {
    kind: []const u8,
    construction: []const u8,
};

const ProgressWitness = struct {
    kind: []const u8,
    statement: []const u8,
    verifier: []const []const u8,
};

const CorrectnessRefinement = struct {
    class_ref: []const u8,
    discrepancy: []const u8,
    law_delta: []const u8,
    owner_refinement: OwnerRefinement,
    preservation_witness: Witness,
    progress_witness: ProgressWitness,
};

const Finding = struct {
    finding_id: []const u8,
    disposition: []const u8,
    quotient_key: []const u8,
    owner_boundary: []const u8,
};

const EquivalenceClass = struct {
    quotient_key: []const u8,
    finding_ids: []const []const u8,
    owner_boundary: []const u8,
    law_family: []const u8,
};

const Compression = struct {
    equivalence_classes: []const EquivalenceClass,
};

const ReviewFold = struct {
    version: []const u8,
    goal_id: ?[]const u8 = null,
    findings: []const Finding,
    compression: Compression,
};

const ResolutionHistory = struct {
    goal_id: []const u8 = "",
    prior_resolution_refs: []const []const u8 = &.{},
    prior_synthesis_refs: []const []const u8 = &.{},
};

const BoundaryIdentity = struct {
    source_worlds: []const []const u8 = &.{},
    target_worlds: []const []const u8 = &.{},
    carriers: []const []const u8 = &.{},
    operations: []const []const u8 = &.{},
    observations: []const []const u8 = &.{},
    laws: []const []const u8 = &.{},
};

const SeparationObstruction = struct {
    statement: []const u8 = "",
    falsifier: []const u8 = "",
};

const StructuralObligation = struct {
    kind: []const u8 = "",
    target: []const u8 = "",
    verifier: []const []const u8 = &.{},
    observation_ref: ?[]const u8 = null,
};

const SelectedWorkNode = struct {
    node_id: []const u8 = "",
    run_id: []const u8 = "",
    owner_boundary: []const u8 = "",
    paths: []const []const u8 = &.{},
    verifier: []const []const u8 = &.{},
};

const OwnerSynthesis = struct {
    version: []const u8 = "",
    synthesis_id: []const u8 = "",
    stable_component_key: []const u8 = "",
    boundary_identity: BoundaryIdentity = .{},
    class_refs: []const []const u8 = &.{},
    prior_decision_refs: []const []const u8 = &.{},
    prior_synthesis_refs: []const []const u8 = &.{},
    owner_boundaries: []const []const u8 = &.{},
    pressure_signals: []const []const u8 = &.{},
    disposition: []const u8 = "",
    canonical_owner: ?[]const u8 = null,
    construction: ?[]const u8 = null,
    separation_obstruction: ?SeparationObstruction = null,
    structural_obligations: []const StructuralObligation = &.{},
    selected_work_node_ref: ?[]const u8 = null,
    falsifier: ?[]const u8 = null,
};

const Decision = struct {
    decision_id: []const u8,
    owner_boundary: []const u8,
    finding_ids: []const []const u8,
    liability_classes: []const []const u8,
    strategy: []const u8,
    correctness_refinement: ?CorrectnessRefinement = null,
    blockers: []const []const u8,
    owner_synthesis_ref: ?[]const u8 = null,
    selected_work_node: ?SelectedWorkNode = null,
};

const SemanticBalance = struct {
    uncovered_liabilities: []const []const u8,
    required_retirements: []const []const u8,
    completed_retirements: []const []const u8,
    dominated_remaining: []const []const u8,
};

const Outcome = struct {
    status: []const u8,
    semantic_balance: SemanticBalance,
};

const Resolution = struct {
    version: []const u8,
    resolution_id: []const u8,
    run_id: []const u8,
    review_folds: []const ReviewFold,
    finding_ids: []const []const u8,
    resolution_history: ?ResolutionHistory = null,
    owner_syntheses: []const OwnerSynthesis = &.{},
    decisions: []const Decision,
    outcome: Outcome,
};

const Envelope = struct {
    review_resolution: Resolution,
};

const Issues = struct {
    values: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Issues, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }

    fn add(self: *Issues, allocator: std.mem.Allocator, issue: []const u8) !void {
        for (self.values.items) |existing| {
            if (std.mem.eql(u8, existing, issue)) return;
        }
        try self.values.append(allocator, issue);
    }

    fn sort(self: *Issues) void {
        std.mem.sort([]const u8, self.values.items, {}, lessString);
    }
};

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const code = runWithArgv(init.gpa, init.io, argv) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(init.io, &.{});
        try stderr_writer.interface.print("ledger validate review-resolution: {s}\n", .{@errorName(err)});
        return err;
    };
    if (code != 0) std.process.exit(code);
}

pub fn runWithArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    if (argv.len == 2 and (std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "--help"))) {
        try printHelp(io);
        return 0;
    }
    const args = try parseArgs(argv);
    const input = try readInputAlloc(allocator, io, args.input_path);
    defer allocator.free(input);

    var issues = Issues{};
    defer issues.deinit(allocator);

    var parsed = std.json.parseFromSlice(Envelope, allocator, input, .{
        .ignore_unknown_fields = true,
    }) catch {
        try issues.add(allocator, "malformed-or-schema-invalid-json");
        try emitDecision(allocator, io, args.phase, &issues);
        return 2;
    };
    defer parsed.deinit();

    try validateResolution(allocator, parsed.value.review_resolution, args.phase, &issues);
    try emitDecision(allocator, io, args.phase, &issues);
    return if (issues.values.items.len == 0) 0 else 2;
}

fn printHelp(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    try stdout_writer.interface.writeAll(
        \\ledger validate review-resolution
        \\
        \\usage: ledger validate review-resolution --phase {preflight|closeout} --input FILE|-
        \\
        \\Purely check correctness refinement and owner-boundary synthesis in one review-resolution/v1 JSON snapshot. Verifiers and observation references are not executed or dereferenced; the decision grants no authority and mutates no storage.
        \\
    );
}

fn parseArgs(argv: []const []const u8) !Args {
    var phase: ?Phase = null;
    var input_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--phase")) {
            i += 1;
            if (i >= argv.len) return error.MissingPhase;
            phase = Phase.parse(argv[i]) orelse return error.InvalidPhase;
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--input")) {
            i += 1;
            if (i >= argv.len) return error.MissingInput;
            input_path = argv[i];
            continue;
        }
        return error.UnknownOption;
    }
    return .{
        .phase = phase orelse return error.MissingPhase,
        .input_path = input_path orelse return error.MissingInput,
    };
}

fn readInputAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var reader = std.Io.File.stdin().reader(io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MaxInputBytes));
}

fn emitDecision(allocator: std.mem.Allocator, io: std.Io, phase: Phase, issues: *Issues) !void {
    issues.sort();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"actuating-review-resolution-decision/v1\",\"phase\":");
    try std.json.Stringify.value(phase.name(), .{}, &out.writer);
    try out.writer.writeAll(",\"verdict\":");
    try std.json.Stringify.value(if (issues.values.items.len == 0) "pass" else "blocked", .{}, &out.writer);
    try out.writer.writeAll(",\"errors\":");
    try std.json.Stringify.value(issues.values.items, .{}, &out.writer);
    try out.writer.writeAll(",\"authority_granted\":false,\"storage_mutated\":false}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    try stdout_writer.interface.writeAll(bytes);
}

fn validateResolution(allocator: std.mem.Allocator, resolution: Resolution, phase: Phase, issues: *Issues) !void {
    if (!std.mem.eql(u8, resolution.version, "review-resolution/v1")) try issues.add(allocator, "resolution-version");
    if (!isNonblank(resolution.resolution_id) or !isNonblank(resolution.run_id)) try issues.add(allocator, "resolution-identity");
    if (resolution.review_folds.len == 0) try issues.add(allocator, "review-fold-required");
    if (!stringIn(resolution.outcome.status, &.{ "pending", "clean", "resolved", "blocked" })) try issues.add(allocator, "resolution-outcome-status");

    for (resolution.finding_ids, 0..) |finding_id, index| {
        if (!isNonblank(finding_id)) try issues.add(allocator, "resolution-finding-id-empty");
        if (containsString(resolution.finding_ids[0..index], finding_id)) try issues.add(allocator, "resolution-finding-id-duplicate");
        if (!isResolutionInputFinding(resolution.review_folds, finding_id)) try issues.add(allocator, "resolution-finding-not-input");
        if (countDecisionsWithFinding(resolution.decisions, finding_id) != 1) try issues.add(allocator, "resolution-finding-decision-coverage");
    }

    for (resolution.review_folds) |fold| {
        if (!std.mem.eql(u8, fold.version, "RF-v2")) try issues.add(allocator, "review-fold-version");
        for (fold.compression.equivalence_classes) |class| {
            if (!isNonblank(class.quotient_key) or !isNonblank(class.owner_boundary) or !isNonblank(class.law_family)) {
                try issues.add(allocator, "equivalence-class-identity");
            }
            if (class.finding_ids.len == 0) try issues.add(allocator, "equivalence-class-empty");
            for (class.finding_ids, 0..) |finding_id, index| {
                if (!isNonblank(finding_id) or containsString(class.finding_ids[0..index], finding_id)) {
                    try issues.add(allocator, "equivalence-class-finding-identity");
                }
                if (!foldHasFinding(fold, finding_id, class.quotient_key, class.owner_boundary)) {
                    try issues.add(allocator, "equivalence-class-finding-mismatch");
                }
            }
        }
        for (fold.findings) |finding| {
            if (!isNonblank(finding.finding_id) or !isNonblank(finding.quotient_key) or !isNonblank(finding.owner_boundary)) {
                try issues.add(allocator, "finding-identity");
            }
            if (std.mem.eql(u8, finding.disposition, "resolution-input")) {
                if (!containsString(resolution.finding_ids, finding.finding_id)) try issues.add(allocator, "resolution-input-not-retained");
                if (!foldHasClass(fold, finding.quotient_key, finding.finding_id, finding.owner_boundary)) {
                    try issues.add(allocator, "resolution-input-class-mismatch");
                }
                if (countDecisionsWithClass(resolution.decisions, finding.quotient_key) != 1) {
                    try issues.add(allocator, "resolution-class-decision-coverage");
                }
            } else if (containsString(resolution.finding_ids, finding.finding_id)) {
                try issues.add(allocator, "non-resolution-finding-retained");
            }
        }
    }

    try validateOwnerSyntheses(allocator, resolution, phase, issues);

    for (resolution.decisions, 0..) |decision, decision_index| {
        if (!isNonblank(decision.decision_id) or !isNonblank(decision.owner_boundary)) try issues.add(allocator, "decision-identity");
        if (decisionIdentitySeen(resolution.decisions[0..decision_index], decision)) try issues.add(allocator, "decision-identity-duplicate");
        if (!stringIn(decision.strategy, &.{ "local-repair", "replacement-kernel", "blocked" })) try issues.add(allocator, "decision-strategy");
        if (decision.finding_ids.len == 0) try issues.add(allocator, "decision-findings-required");
        for (decision.finding_ids, 0..) |finding_id, finding_index| {
            if (!isNonblank(finding_id) or containsString(decision.finding_ids[0..finding_index], finding_id)) {
                try issues.add(allocator, "decision-finding-identity");
            }
            if (!containsString(resolution.finding_ids, finding_id)) try issues.add(allocator, "decision-finding-not-retained");
            if (!isResolutionInputFinding(resolution.review_folds, finding_id)) try issues.add(allocator, "decision-finding-not-input");
        }
        if (decision.liability_classes.len != 1) try issues.add(allocator, "decision-class-cardinality");
        for (decision.liability_classes, 0..) |class_ref, class_index| {
            if (!isNonblank(class_ref) or containsString(decision.liability_classes[0..class_index], class_ref)) {
                try issues.add(allocator, "decision-class-identity");
            }
        }
        if (decision.liability_classes.len == 1 and !classMatchesDecision(resolution.review_folds, decision.liability_classes[0], decision)) {
            try issues.add(allocator, "decision-class-mismatch");
        }
        try validateDecisionSynthesisBinding(allocator, resolution, decision, issues);

        if (std.mem.eql(u8, decision.strategy, "blocked")) {
            if (decision.blockers.len == 0) try issues.add(allocator, "blocked-decision-without-blocker");
            if (decision.correctness_refinement != null) try issues.add(allocator, "blocked-decision-has-refinement");
            try issues.add(allocator, "mutation-blocked-by-resolution");
            continue;
        }

        if (decision.blockers.len != 0) try issues.add(allocator, "nonblocked-decision-has-blocker");
        const decision_refinement = decision.correctness_refinement orelse {
            try issues.add(allocator, "correctness-refinement-required");
            continue;
        };
        try validateRefinement(allocator, resolution, decision, decision_refinement, issues);
    }

    try validateSemanticBalance(allocator, resolution, issues);
    if (phase == .preflight and !std.mem.eql(u8, resolution.outcome.status, "pending")) {
        try issues.add(allocator, "preflight-outcome-not-pending");
    }
    if (phase == .closeout) try validateCloseout(allocator, resolution, issues);
}

fn validateOwnerSyntheses(
    allocator: std.mem.Allocator,
    resolution: Resolution,
    phase: Phase,
    issues: *Issues,
) !void {
    if (resolution.decisions.len != 0 and resolution.resolution_history == null) {
        try issues.add(allocator, "resolution-history-required");
    }
    if (resolution.decisions.len != 0 and resolution.owner_syntheses.len == 0) {
        try issues.add(allocator, "owner-synthesis-required");
    }
    if (resolution.owner_syntheses.len != 0 and resolution.resolution_history == null) {
        try issues.add(allocator, "owner-synthesis-history-required");
    }

    if (resolution.resolution_history) |history| {
        if (!isNonblank(history.goal_id)) try issues.add(allocator, "resolution-history-goal");
        try validateStringSet(allocator, history.prior_resolution_refs, "resolution-history-resolution-refs", issues);
        try validateStringSet(allocator, history.prior_synthesis_refs, "resolution-history-synthesis-refs", issues);
        if (resolution.owner_syntheses.len != 0) {
            for (resolution.review_folds) |fold| {
                const fold_goal_id = fold.goal_id orelse {
                    try issues.add(allocator, "resolution-history-goal-binding");
                    continue;
                };
                if (!std.mem.eql(u8, fold_goal_id, history.goal_id)) {
                    try issues.add(allocator, "resolution-history-goal-binding");
                }
            }
        }
        for (history.prior_synthesis_refs) |prior_ref| {
            if (countSynthesesJoiningPrior(resolution.owner_syntheses, prior_ref) != 1) {
                try issues.add(allocator, "owner-synthesis-history-join");
            }
        }
    }

    var selected_node_count: usize = 0;
    var repair_decision_count: usize = 0;
    for (resolution.decisions) |decision| {
        if (decision.selected_work_node != null) selected_node_count += 1;
        if (!std.mem.eql(u8, decision.strategy, "blocked")) repair_decision_count += 1;
    }
    if (selected_node_count > 1 or (repair_decision_count != 0 and selected_node_count != 1)) {
        try issues.add(allocator, "owner-synthesis-selected-node-cardinality");
    }

    for (resolution.owner_syntheses, 0..) |synthesis, synthesis_index| {
        if (!std.mem.eql(u8, synthesis.version, "owner-boundary-synthesis/v1")) {
            try issues.add(allocator, "owner-synthesis-version");
        }
        if (!isNonblank(synthesis.synthesis_id)) try issues.add(allocator, "owner-synthesis-identity");
        if (synthesisIdentitySeen(resolution.owner_syntheses[0..synthesis_index], synthesis.synthesis_id)) {
            try issues.add(allocator, "owner-synthesis-identity-duplicate");
        }
        if (synthesisComponentSeen(resolution.owner_syntheses[0..synthesis_index], synthesis.stable_component_key)) {
            try issues.add(allocator, "owner-synthesis-component-duplicate");
        }

        try validateBoundaryIdentity(allocator, synthesis.boundary_identity, issues);
        const expected_component_key = try canonicalComponentKeyAlloc(allocator, synthesis.boundary_identity);
        defer allocator.free(expected_component_key);
        if (!std.mem.eql(u8, synthesis.stable_component_key, expected_component_key)) {
            try issues.add(allocator, "owner-synthesis-stable-component-key");
        }

        if (synthesis.class_refs.len == 0) try issues.add(allocator, "owner-synthesis-classes-required");
        try validateStringSet(allocator, synthesis.class_refs, "owner-synthesis-class-identity", issues);
        for (synthesis.class_refs) |class_ref| {
            if (!isResolutionInputClass(resolution.review_folds, class_ref)) {
                try issues.add(allocator, "owner-synthesis-class-not-input");
            }
        }
        try validateStringSet(allocator, synthesis.prior_decision_refs, "owner-synthesis-prior-decision-refs", issues);
        try validateStringSet(allocator, synthesis.prior_synthesis_refs, "owner-synthesis-prior-synthesis-refs", issues);
        for (synthesis.prior_synthesis_refs) |prior_ref| {
            const history = resolution.resolution_history orelse {
                try issues.add(allocator, "owner-synthesis-history-required");
                break;
            };
            if (!containsString(history.prior_synthesis_refs, prior_ref)) {
                try issues.add(allocator, "owner-synthesis-history-join");
            }
            if (std.mem.eql(u8, prior_ref, synthesis.synthesis_id)) {
                try issues.add(allocator, "owner-synthesis-history-cycle");
            }
        }

        if (synthesis.owner_boundaries.len == 0) try issues.add(allocator, "owner-synthesis-owners-required");
        try validateStringSet(allocator, synthesis.owner_boundaries, "owner-synthesis-owner-identity", issues);
        try validateStringSet(allocator, synthesis.pressure_signals, "owner-synthesis-pressure-identity", issues);
        for (synthesis.pressure_signals) |signal| {
            if (!stringIn(signal, &.{
                "recurrence-after-repair",
                "multiple-law-owners",
                "new-semantic-machinery",
                "multi-abstraction-displacement",
                "post-kernel-symptom-repair",
            })) try issues.add(allocator, "owner-synthesis-pressure-signal");
        }

        try validateSynthesisDisposition(allocator, resolution, synthesis, phase, issues);
    }

    for (resolution.review_folds) |fold| for (fold.compression.equivalence_classes) |class| {
        if (classHasResolutionInput(fold, class) and countSynthesesWithClass(resolution.owner_syntheses, class.quotient_key) != 1) {
            try issues.add(allocator, "owner-synthesis-class-coverage");
        }
    };
}

fn validateBoundaryIdentity(
    allocator: std.mem.Allocator,
    identity: BoundaryIdentity,
    issues: *Issues,
) !void {
    const fields = [_][]const []const u8{
        identity.source_worlds,
        identity.target_worlds,
        identity.carriers,
        identity.operations,
        identity.observations,
        identity.laws,
    };
    for (fields) |values| {
        if (values.len == 0) try issues.add(allocator, "owner-synthesis-boundary-identity");
        try validateStringSet(allocator, values, "owner-synthesis-boundary-identity", issues);
    }
}

fn validateSynthesisDisposition(
    allocator: std.mem.Allocator,
    resolution: Resolution,
    synthesis: OwnerSynthesis,
    phase: Phase,
    issues: *Issues,
) !void {
    const disposition = synthesis.disposition;
    if (!stringIn(disposition, &.{ "reuse-owner", "converge-kernel", "separate-laws", "blocked" })) {
        try issues.add(allocator, "owner-synthesis-disposition");
        return;
    }

    if (synthesis.selected_work_node_ref) |node_ref| {
        if (!isNonblank(node_ref)) try issues.add(allocator, "owner-synthesis-selected-node-ref");
    }

    if (std.mem.eql(u8, disposition, "reuse-owner")) {
        if (synthesis.pressure_signals.len != 0) try issues.add(allocator, "reuse-owner-has-pressure");
        if (synthesis.owner_boundaries.len != 1) try issues.add(allocator, "reuse-owner-not-local");
        try validateRepairSynthesisCore(allocator, synthesis, issues);
        if (synthesis.structural_obligations.len != 0) try issues.add(allocator, "reuse-owner-adds-structural-obligation");
        if (synthesis.separation_obstruction != null) try issues.add(allocator, "reuse-owner-has-separation-obstruction");
    } else if (std.mem.eql(u8, disposition, "converge-kernel")) {
        if (synthesis.pressure_signals.len == 0) try issues.add(allocator, "converge-kernel-without-pressure");
        try validateRepairSynthesisCore(allocator, synthesis, issues);
        if (synthesis.structural_obligations.len == 0) try issues.add(allocator, "converge-kernel-obligations-required");
        if (synthesis.separation_obstruction != null) try issues.add(allocator, "converge-kernel-has-separation-obstruction");
    } else if (std.mem.eql(u8, disposition, "separate-laws")) {
        const obstruction = synthesis.separation_obstruction orelse {
            try issues.add(allocator, "separate-laws-obstruction-required");
            return;
        };
        if (!isNonblank(obstruction.statement) or !isNonblank(obstruction.falsifier)) {
            try issues.add(allocator, "separate-laws-obstruction-required");
        }
        if (synthesis.structural_obligations.len != 0 or synthesis.selected_work_node_ref != null) {
            try issues.add(allocator, "separate-laws-has-repair");
        }
        if (countDecisionsWithSynthesis(resolution.decisions, synthesis.synthesis_id) != 0) {
            try issues.add(allocator, "separate-laws-has-repair");
        }
    } else {
        if (!optionalNonblank(synthesis.falsifier)) try issues.add(allocator, "blocked-synthesis-falsifier");
        if (synthesis.structural_obligations.len != 0 or synthesis.selected_work_node_ref != null) {
            try issues.add(allocator, "blocked-synthesis-has-repair");
        }
    }

    try validateStructuralObligations(allocator, resolution, synthesis, phase, issues);
    const selected_for_synthesis = countSelectedNodesWithSynthesis(resolution.decisions, synthesis.synthesis_id);
    if (synthesis.selected_work_node_ref) |node_ref| {
        if (selected_for_synthesis != 1 or !synthesisHasSelectedNode(resolution.decisions, synthesis.synthesis_id, node_ref)) {
            try issues.add(allocator, "owner-synthesis-selected-node-binding");
        }
    } else if (selected_for_synthesis != 0) {
        try issues.add(allocator, "owner-synthesis-selected-node-binding");
    }
}

fn validateRepairSynthesisCore(
    allocator: std.mem.Allocator,
    synthesis: OwnerSynthesis,
    issues: *Issues,
) !void {
    const canonical_owner = synthesis.canonical_owner orelse {
        try issues.add(allocator, "owner-synthesis-canonical-owner");
        return;
    };
    if (!isNonblank(canonical_owner) or !containsString(synthesis.owner_boundaries, canonical_owner)) {
        try issues.add(allocator, "owner-synthesis-canonical-owner");
    }
    if (!optionalNonblank(synthesis.construction)) try issues.add(allocator, "owner-synthesis-construction");
    if (!optionalNonblank(synthesis.falsifier)) try issues.add(allocator, "owner-synthesis-falsifier");
}

fn validateStructuralObligations(
    allocator: std.mem.Allocator,
    resolution: Resolution,
    synthesis: OwnerSynthesis,
    phase: Phase,
    issues: *Issues,
) !void {
    const balance = resolution.outcome.semantic_balance;
    for (synthesis.structural_obligations, 0..) |obligation, index| {
        if (!stringIn(obligation.kind, &.{ "install", "collapse", "retire", "delegate" }) or
            !isNonblank(obligation.target) or
            !validVerifier(obligation.verifier))
        {
            try issues.add(allocator, "structural-obligation-invalid");
        }
        for (synthesis.structural_obligations[0..index]) |prior| {
            if (std.mem.eql(u8, prior.target, obligation.target)) {
                try issues.add(allocator, "structural-obligation-duplicate-target");
            }
        }
        if (obligation.observation_ref) |observation_ref| {
            if (!isNonblank(observation_ref)) try issues.add(allocator, "structural-obligation-observation");
        } else if (phase == .closeout) {
            try issues.add(allocator, "structural-obligation-observation-required");
        }
        if (!std.mem.eql(u8, obligation.kind, "install")) {
            if (!containsString(balance.required_retirements, obligation.target)) {
                try issues.add(allocator, "structural-obligation-retirement-binding");
            }
            if (phase == .closeout and !containsString(balance.completed_retirements, obligation.target)) {
                try issues.add(allocator, "structural-obligation-retirement-incomplete");
            }
        }
    }
}

fn validateDecisionSynthesisBinding(
    allocator: std.mem.Allocator,
    resolution: Resolution,
    decision: Decision,
    issues: *Issues,
) !void {
    const synthesis_ref = decision.owner_synthesis_ref orelse {
        try issues.add(allocator, "decision-owner-synthesis-required");
        return;
    };
    if (!isNonblank(synthesis_ref)) {
        try issues.add(allocator, "decision-owner-synthesis-required");
        return;
    }
    const synthesis = findSynthesis(resolution.owner_syntheses, synthesis_ref) orelse {
        try issues.add(allocator, "decision-owner-synthesis-not-found");
        return;
    };
    if (countSynthesesWithId(resolution.owner_syntheses, synthesis_ref) != 1) {
        try issues.add(allocator, "decision-owner-synthesis-not-unique");
    }
    for (decision.liability_classes) |class_ref| {
        if (!containsString(synthesis.class_refs, class_ref)) try issues.add(allocator, "decision-owner-synthesis-class-binding");
    }
    if (!containsString(synthesis.owner_boundaries, decision.owner_boundary)) {
        try issues.add(allocator, "decision-owner-synthesis-owner-binding");
    }

    const expected_disposition = if (std.mem.eql(u8, decision.strategy, "local-repair"))
        "reuse-owner"
    else if (std.mem.eql(u8, decision.strategy, "replacement-kernel"))
        "converge-kernel"
    else if (std.mem.eql(u8, decision.strategy, "blocked"))
        "blocked"
    else
        "";
    if (!std.mem.eql(u8, synthesis.disposition, expected_disposition)) {
        try issues.add(allocator, "decision-owner-synthesis-strategy-binding");
    }

    if (!std.mem.eql(u8, decision.strategy, "blocked")) {
        if (decision.correctness_refinement) |decision_refinement| {
            const synthesis_construction = synthesis.construction orelse "";
            if (!std.mem.eql(u8, decision_refinement.owner_refinement.construction, synthesis_construction)) {
                try issues.add(allocator, "decision-owner-synthesis-construction-binding");
            }
        }
    }
    if (std.mem.eql(u8, synthesis.disposition, "reuse-owner")) {
        const canonical_owner = synthesis.canonical_owner orelse "";
        if (!std.mem.eql(u8, decision.owner_boundary, canonical_owner)) {
            try issues.add(allocator, "reuse-owner-not-local");
        }
    }

    if (decision.selected_work_node) |node| {
        if (!isNonblank(node.node_id) or
            !std.mem.eql(u8, node.run_id, resolution.run_id) or
            !validStringSet(node.paths) or
            !validVerifier(node.verifier))
        {
            try issues.add(allocator, "selected-work-node-invalid");
        }
        const canonical_owner = synthesis.canonical_owner orelse "";
        if (!std.mem.eql(u8, node.owner_boundary, canonical_owner)) {
            try issues.add(allocator, "selected-work-node-owner-binding");
        }
        const selected_ref = synthesis.selected_work_node_ref orelse "";
        if (!std.mem.eql(u8, node.node_id, selected_ref)) {
            try issues.add(allocator, "owner-synthesis-selected-node-binding");
        }
    }
}

fn validateRefinement(
    allocator: std.mem.Allocator,
    resolution: Resolution,
    decision: Decision,
    decision_refinement: CorrectnessRefinement,
    issues: *Issues,
) !void {
    if (!isNonblank(decision_refinement.class_ref) or !isNonblank(decision_refinement.law_delta) or !isNonblank(decision_refinement.owner_refinement.construction)) {
        try issues.add(allocator, "correctness-refinement-identity");
    }
    if (!stringIn(decision_refinement.discrepancy, &.{ "excess", "deficit", "incoherence", "partiality", "misbinding" })) {
        try issues.add(allocator, "correctness-refinement-discrepancy");
    }
    if (decision.liability_classes.len != 1 or !std.mem.eql(u8, decision.liability_classes[0], decision_refinement.class_ref)) {
        try issues.add(allocator, "correctness-refinement-class-binding");
    }
    if (countDecisionsWithClass(resolution.decisions, decision_refinement.class_ref) != 1) try issues.add(allocator, "correctness-refinement-class-duplicate");
    if (!classMatchesDecision(resolution.review_folds, decision_refinement.class_ref, decision)) try issues.add(allocator, "correctness-refinement-class-mismatch");

    if (std.mem.eql(u8, decision.strategy, "local-repair")) {
        if (!std.mem.eql(u8, decision_refinement.owner_refinement.kind, "restore-existing-law")) {
            try issues.add(allocator, "local-repair-refinement-kind");
        }
    } else if (std.mem.eql(u8, decision.strategy, "replacement-kernel")) {
        if (!stringIn(decision_refinement.owner_refinement.kind, &.{ "strengthen-representation", "replace-owner" })) {
            try issues.add(allocator, "replacement-kernel-refinement-kind");
        }
    }

    try validateWitness(allocator, decision_refinement.preservation_witness, "preservation-witness", issues);
    try validateProgressWitness(allocator, decision_refinement.discrepancy, decision_refinement.progress_witness, issues);
}

fn validateWitness(allocator: std.mem.Allocator, witness: Witness, issue: []const u8, issues: *Issues) !void {
    if (!isNonblank(witness.statement) or !validVerifier(witness.verifier)) try issues.add(allocator, issue);
}

fn validateProgressWitness(
    allocator: std.mem.Allocator,
    discrepancy: []const u8,
    witness: ProgressWitness,
    issues: *Issues,
) !void {
    if (!isNonblank(witness.statement) or !validVerifier(witness.verifier)) try issues.add(allocator, "progress-witness");
    const expected = if (std.mem.eql(u8, discrepancy, "excess"))
        "exclude"
    else if (std.mem.eql(u8, discrepancy, "deficit"))
        "restore"
    else if (std.mem.eql(u8, discrepancy, "incoherence"))
        "reconcile"
    else if (std.mem.eql(u8, discrepancy, "partiality"))
        "totalize"
    else if (std.mem.eql(u8, discrepancy, "misbinding"))
        "rebind"
    else
        "";
    if (!std.mem.eql(u8, witness.kind, expected)) try issues.add(allocator, "progress-witness-kind");
}

fn validateCloseout(allocator: std.mem.Allocator, resolution: Resolution, issues: *Issues) !void {
    if (!stringIn(resolution.outcome.status, &.{ "clean", "resolved" })) try issues.add(allocator, "closeout-outcome-open");
    if (std.mem.eql(u8, resolution.outcome.status, "clean") and (resolution.finding_ids.len != 0 or resolution.decisions.len != 0)) {
        try issues.add(allocator, "closeout-clean-has-resolution");
    }
    if (std.mem.eql(u8, resolution.outcome.status, "resolved") and resolution.finding_ids.len == 0) {
        try issues.add(allocator, "closeout-resolved-without-findings");
    }
    for (resolution.decisions) |decision| {
        if (std.mem.eql(u8, decision.strategy, "blocked")) try issues.add(allocator, "closeout-blocked-decision");
    }
    const balance = resolution.outcome.semantic_balance;
    if (balance.uncovered_liabilities.len != 0) try issues.add(allocator, "closeout-uncovered-liabilities");
    if (balance.dominated_remaining.len != 0) try issues.add(allocator, "closeout-dominated-remaining");
    for (balance.required_retirements) |required| {
        if (!containsString(balance.completed_retirements, required)) try issues.add(allocator, "closeout-retirement-debt");
    }
}

fn validateSemanticBalance(allocator: std.mem.Allocator, resolution: Resolution, issues: *Issues) !void {
    const balance = resolution.outcome.semantic_balance;
    try validateStringSet(allocator, balance.uncovered_liabilities, "semantic-balance-uncovered-identity", issues);
    try validateStringSet(allocator, balance.required_retirements, "semantic-balance-required-identity", issues);
    try validateStringSet(allocator, balance.completed_retirements, "semantic-balance-completed-identity", issues);
    try validateStringSet(allocator, balance.dominated_remaining, "semantic-balance-dominated-identity", issues);

    for (balance.completed_retirements) |completed| {
        if (!containsString(balance.required_retirements, completed)) try issues.add(allocator, "semantic-balance-completed-not-required");
    }
    if (std.mem.eql(u8, resolution.outcome.status, "pending")) {
        for (balance.required_retirements) |required| {
            const outstanding = !containsString(balance.completed_retirements, required);
            if (outstanding != containsString(balance.dominated_remaining, required)) {
                try issues.add(allocator, "pending-retirement-balance-mismatch");
            }
        }
        for (balance.dominated_remaining) |dominated| {
            if (!containsString(balance.required_retirements, dominated) or containsString(balance.completed_retirements, dominated)) {
                try issues.add(allocator, "pending-retirement-balance-mismatch");
            }
        }
    }
    if (std.mem.eql(u8, resolution.outcome.status, "blocked")) try issues.add(allocator, "mutation-blocked-by-outcome");
}

fn validateStringSet(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    issue: []const u8,
    issues: *Issues,
) !void {
    for (values, 0..) |value, index| {
        if (!isNonblank(value) or containsString(values[0..index], value)) try issues.add(allocator, issue);
    }
}

fn validVerifier(verifier: []const []const u8) bool {
    if (verifier.len == 0) return false;
    for (verifier) |arg| if (!isNonblank(arg)) return false;
    return true;
}

fn validStringSet(values: []const []const u8) bool {
    if (values.len == 0) return false;
    for (values, 0..) |value, index| {
        if (!isNonblank(value) or containsString(values[0..index], value)) return false;
    }
    return true;
}

fn optionalNonblank(value: ?[]const u8) bool {
    return if (value) |present| isNonblank(present) else false;
}

fn canonicalComponentKeyAlloc(allocator: std.mem.Allocator, identity: BoundaryIdentity) ![]u8 {
    const source_worlds = try sortedStringsAlloc(allocator, identity.source_worlds);
    defer allocator.free(source_worlds);
    const target_worlds = try sortedStringsAlloc(allocator, identity.target_worlds);
    defer allocator.free(target_worlds);
    const carriers = try sortedStringsAlloc(allocator, identity.carriers);
    defer allocator.free(carriers);
    const operations = try sortedStringsAlloc(allocator, identity.operations);
    defer allocator.free(operations);
    const observations = try sortedStringsAlloc(allocator, identity.observations);
    defer allocator.free(observations);
    const laws = try sortedStringsAlloc(allocator, identity.laws);
    defer allocator.free(laws);

    var canonical: std.Io.Writer.Allocating = .init(allocator);
    defer canonical.deinit();
    try canonical.writer.writeAll("owner-boundary-synthesis/boundary-identity/v1\n");
    try std.json.Stringify.value(.{
        .source_worlds = source_worlds,
        .target_worlds = target_worlds,
        .carriers = carriers,
        .operations = operations,
        .observations = observations,
        .laws = laws,
    }, .{}, &canonical.writer);
    const canonical_bytes = try canonical.toOwnedSlice();
    defer allocator.free(canonical_bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn sortedStringsAlloc(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    const sorted = try allocator.alloc([]const u8, values.len);
    @memcpy(sorted, values);
    std.mem.sort([]const u8, sorted, {}, lessString);
    return sorted;
}

fn classHasResolutionInput(fold: ReviewFold, class: EquivalenceClass) bool {
    for (class.finding_ids) |finding_id| {
        for (fold.findings) |finding| {
            if (std.mem.eql(u8, finding.finding_id, finding_id) and std.mem.eql(u8, finding.disposition, "resolution-input")) {
                return true;
            }
        }
    }
    return false;
}

fn isResolutionInputClass(review_folds: []const ReviewFold, class_ref: []const u8) bool {
    for (review_folds) |fold| {
        for (fold.compression.equivalence_classes) |class| {
            if (std.mem.eql(u8, class.quotient_key, class_ref) and classHasResolutionInput(fold, class)) return true;
        }
    }
    return false;
}

fn synthesisIdentitySeen(prior: []const OwnerSynthesis, synthesis_id: []const u8) bool {
    for (prior) |synthesis| if (std.mem.eql(u8, synthesis.synthesis_id, synthesis_id)) return true;
    return false;
}

fn synthesisComponentSeen(prior: []const OwnerSynthesis, component_key: []const u8) bool {
    if (!isNonblank(component_key)) return false;
    for (prior) |synthesis| if (std.mem.eql(u8, synthesis.stable_component_key, component_key)) return true;
    return false;
}

fn countSynthesesWithClass(syntheses: []const OwnerSynthesis, class_ref: []const u8) usize {
    var count: usize = 0;
    for (syntheses) |synthesis| if (containsString(synthesis.class_refs, class_ref)) {
        count += 1;
    };
    return count;
}

fn countSynthesesJoiningPrior(syntheses: []const OwnerSynthesis, prior_ref: []const u8) usize {
    var count: usize = 0;
    for (syntheses) |synthesis| if (containsString(synthesis.prior_synthesis_refs, prior_ref)) {
        count += 1;
    };
    return count;
}

fn countSynthesesWithId(syntheses: []const OwnerSynthesis, synthesis_id: []const u8) usize {
    var count: usize = 0;
    for (syntheses) |synthesis| if (std.mem.eql(u8, synthesis.synthesis_id, synthesis_id)) {
        count += 1;
    };
    return count;
}

fn findSynthesis(syntheses: []const OwnerSynthesis, synthesis_id: []const u8) ?OwnerSynthesis {
    for (syntheses) |synthesis| {
        if (std.mem.eql(u8, synthesis.synthesis_id, synthesis_id)) return synthesis;
    }
    return null;
}

fn countDecisionsWithSynthesis(decisions_for_resolution: []const Decision, synthesis_id: []const u8) usize {
    var count: usize = 0;
    for (decisions_for_resolution) |decision| {
        const synthesis_ref = decision.owner_synthesis_ref orelse continue;
        if (std.mem.eql(u8, synthesis_ref, synthesis_id)) count += 1;
    }
    return count;
}

fn countSelectedNodesWithSynthesis(decisions_for_resolution: []const Decision, synthesis_id: []const u8) usize {
    var count: usize = 0;
    for (decisions_for_resolution) |decision| {
        const synthesis_ref = decision.owner_synthesis_ref orelse continue;
        if (std.mem.eql(u8, synthesis_ref, synthesis_id) and decision.selected_work_node != null) count += 1;
    }
    return count;
}

fn synthesisHasSelectedNode(decisions_for_resolution: []const Decision, synthesis_id: []const u8, node_id: []const u8) bool {
    for (decisions_for_resolution) |decision| {
        const synthesis_ref = decision.owner_synthesis_ref orelse continue;
        const node = decision.selected_work_node orelse continue;
        if (std.mem.eql(u8, synthesis_ref, synthesis_id) and std.mem.eql(u8, node.node_id, node_id)) return true;
    }
    return false;
}

fn isResolutionInputFinding(review_folds: []const ReviewFold, finding_id: []const u8) bool {
    for (review_folds) |fold| for (fold.findings) |finding| {
        if (std.mem.eql(u8, finding.finding_id, finding_id) and std.mem.eql(u8, finding.disposition, "resolution-input")) return true;
    };
    return false;
}

fn foldHasFinding(fold: ReviewFold, finding_id: []const u8, class_ref: []const u8, owner: []const u8) bool {
    for (fold.findings) |finding| {
        if (std.mem.eql(u8, finding.finding_id, finding_id) and
            std.mem.eql(u8, finding.quotient_key, class_ref) and
            std.mem.eql(u8, finding.owner_boundary, owner)) return true;
    }
    return false;
}

fn foldHasClass(fold: ReviewFold, class_ref: []const u8, finding_id: []const u8, owner: []const u8) bool {
    for (fold.compression.equivalence_classes) |class| {
        if (std.mem.eql(u8, class.quotient_key, class_ref) and
            std.mem.eql(u8, class.owner_boundary, owner) and
            containsString(class.finding_ids, finding_id)) return true;
    }
    return false;
}

fn classMatchesDecision(review_folds: []const ReviewFold, class_ref: []const u8, decision: Decision) bool {
    var found = false;
    for (review_folds) |fold| {
        for (fold.compression.equivalence_classes) |class| {
            if (!std.mem.eql(u8, class.quotient_key, class_ref)) continue;
            found = true;
            if (!std.mem.eql(u8, class.owner_boundary, decision.owner_boundary)) return false;
            for (class.finding_ids) |finding_id| {
                if (isResolutionInputFinding(review_folds, finding_id) and !containsString(decision.finding_ids, finding_id)) return false;
            }
        }
    }
    if (!found) return false;
    for (decision.finding_ids) |finding_id| {
        if (!findingMatchesClass(review_folds, finding_id, class_ref, decision.owner_boundary)) return false;
    }
    return true;
}

fn findingMatchesClass(review_folds: []const ReviewFold, finding_id: []const u8, class_ref: []const u8, owner: []const u8) bool {
    for (review_folds) |fold| for (fold.findings) |finding| {
        if (std.mem.eql(u8, finding.finding_id, finding_id) and
            std.mem.eql(u8, finding.disposition, "resolution-input") and
            std.mem.eql(u8, finding.quotient_key, class_ref) and
            std.mem.eql(u8, finding.owner_boundary, owner)) return true;
    };
    return false;
}

fn countDecisionsWithClass(resolution_decisions: []const Decision, class_ref: []const u8) usize {
    var count: usize = 0;
    for (resolution_decisions) |decision| {
        if (containsString(decision.liability_classes, class_ref)) count += 1;
    }
    return count;
}

fn countDecisionsWithFinding(resolution_decisions: []const Decision, finding_id: []const u8) usize {
    var count: usize = 0;
    for (resolution_decisions) |decision| if (containsString(decision.finding_ids, finding_id)) {
        count += 1;
    };
    return count;
}

fn decisionIdentitySeen(prior: []const Decision, decision: Decision) bool {
    for (prior) |candidate| if (std.mem.eql(u8, candidate.decision_id, decision.decision_id)) return true;
    return false;
}

fn isNonblank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

fn stringIn(value: []const u8, expected: []const []const u8) bool {
    return containsString(expected, value);
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn lessString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

const command = [_][]const u8{ "zig", "build", "test" };
const finding_ids = [_][]const u8{"finding-1"};
const class_ids = [_][]const u8{"class-1"};
const findings = [_]Finding{.{
    .finding_id = "finding-1",
    .disposition = "resolution-input",
    .quotient_key = "class-1",
    .owner_boundary = "parser",
}};
const classes = [_]EquivalenceClass{.{
    .quotient_key = "class-1",
    .finding_ids = &finding_ids,
    .owner_boundary = "parser",
    .law_family = "parse-totality",
}};
const folds = [_]ReviewFold{.{
    .version = "RF-v2",
    .goal_id = "goal-1",
    .findings = &findings,
    .compression = .{ .equivalence_classes = &classes },
}};
const fixture_source_worlds = [_][]const u8{"review-findings"};
const fixture_target_worlds = [_][]const u8{"repair-plan"};
const fixture_carriers = [_][]const u8{"RF-v2-class"};
const fixture_operations = [_][]const u8{"repair"};
const fixture_observations = [_][]const u8{"verifier"};
const fixture_laws = [_][]const u8{"parse-totality"};
const owners = [_][]const u8{"parser"};
const work_paths = [_][]const u8{"apps/ledger/scripts/actuating_review_resolution.zig"};
const component_identity = BoundaryIdentity{
    .source_worlds = &fixture_source_worlds,
    .target_worlds = &fixture_target_worlds,
    .carriers = &fixture_carriers,
    .operations = &fixture_operations,
    .observations = &fixture_observations,
    .laws = &fixture_laws,
};
const refinement = CorrectnessRefinement{
    .class_ref = "class-1",
    .discrepancy = "excess",
    .law_delta = "Malformed input cannot inhabit Parsed",
    .owner_refinement = .{ .kind = "restore-existing-law", .construction = "Reject malformed input in the parser constructor" },
    .preservation_witness = .{ .statement = "Previously valid input still parses", .verifier = &command },
    .progress_witness = .{ .kind = "exclude", .statement = "The malformed-input class is rejected", .verifier = &command },
};
const no_blockers = [_][]const u8{};
const decisions = [_]Decision{.{
    .decision_id = "decision-1",
    .owner_boundary = "parser",
    .finding_ids = &finding_ids,
    .liability_classes = &class_ids,
    .strategy = "local-repair",
    .correctness_refinement = refinement,
    .blockers = &no_blockers,
    .owner_synthesis_ref = "synthesis-1",
    .selected_work_node = .{
        .node_id = "work-node-1",
        .run_id = "run-1",
        .owner_boundary = "parser",
        .paths = &work_paths,
        .verifier = &command,
    },
}};
const empty = [_][]const u8{};
const no_obligations = [_]StructuralObligation{};
const fixture_syntheses = [_]OwnerSynthesis{.{
    .version = "owner-boundary-synthesis/v1",
    .synthesis_id = "synthesis-1",
    .stable_component_key = "sha256:6dad45c63c96e2835c9b7d40f6c727b08b3df176ef92eae3db6b998657902c46",
    .boundary_identity = component_identity,
    .class_refs = &class_ids,
    .prior_decision_refs = &empty,
    .prior_synthesis_refs = &empty,
    .owner_boundaries = &owners,
    .pressure_signals = &empty,
    .disposition = "reuse-owner",
    .canonical_owner = "parser",
    .construction = "Reject malformed input in the parser constructor",
    .separation_obstruction = null,
    .structural_obligations = &no_obligations,
    .selected_work_node_ref = "work-node-1",
    .falsifier = "A local repair requires a second law owner or new semantic machinery",
}};
const no_syntheses = [_]OwnerSynthesis{};
const kernel_owners = [_][]const u8{ "parser", "review-kernel" };
const kernel_pressure = [_][]const u8{"multiple-law-owners"};
const kernel_retirements = [_][]const u8{"parser"};
const pending_kernel_obligations = [_]StructuralObligation{
    .{ .kind = "install", .target = "review-kernel", .verifier = &command },
    .{ .kind = "retire", .target = "parser", .verifier = &command },
};
const completed_kernel_obligations = [_]StructuralObligation{
    .{ .kind = "install", .target = "review-kernel", .verifier = &command, .observation_ref = "artifact:install-proof" },
    .{ .kind = "retire", .target = "parser", .verifier = &command, .observation_ref = "artifact:retirement-proof" },
};
const kernel_refinement = CorrectnessRefinement{
    .class_ref = "class-1",
    .discrepancy = "excess",
    .law_delta = "Malformed input cannot inhabit Parsed",
    .owner_refinement = .{ .kind = "replace-owner", .construction = "Install one review kernel and retire the parser-local implementation" },
    .preservation_witness = .{ .statement = "Previously valid input still parses", .verifier = &command },
    .progress_witness = .{ .kind = "exclude", .statement = "The malformed-input class is rejected", .verifier = &command },
};
const kernel_decisions = [_]Decision{.{
    .decision_id = "decision-1",
    .owner_boundary = "parser",
    .finding_ids = &finding_ids,
    .liability_classes = &class_ids,
    .strategy = "replacement-kernel",
    .correctness_refinement = kernel_refinement,
    .blockers = &no_blockers,
    .owner_synthesis_ref = "synthesis-1",
    .selected_work_node = .{
        .node_id = "work-node-1",
        .run_id = "run-1",
        .owner_boundary = "review-kernel",
        .paths = &work_paths,
        .verifier = &command,
    },
}};
const pending_kernel_syntheses = [_]OwnerSynthesis{.{
    .version = "owner-boundary-synthesis/v1",
    .synthesis_id = "synthesis-1",
    .stable_component_key = "sha256:6dad45c63c96e2835c9b7d40f6c727b08b3df176ef92eae3db6b998657902c46",
    .boundary_identity = component_identity,
    .class_refs = &class_ids,
    .prior_decision_refs = &empty,
    .prior_synthesis_refs = &empty,
    .owner_boundaries = &kernel_owners,
    .pressure_signals = &kernel_pressure,
    .disposition = "converge-kernel",
    .canonical_owner = "review-kernel",
    .construction = "Install one review kernel and retire the parser-local implementation",
    .separation_obstruction = null,
    .structural_obligations = &pending_kernel_obligations,
    .selected_work_node_ref = "work-node-1",
    .falsifier = "The liabilities require distinct laws and cannot share an owner",
}};
const completed_kernel_syntheses = [_]OwnerSynthesis{.{
    .version = "owner-boundary-synthesis/v1",
    .synthesis_id = "synthesis-1",
    .stable_component_key = "sha256:6dad45c63c96e2835c9b7d40f6c727b08b3df176ef92eae3db6b998657902c46",
    .boundary_identity = component_identity,
    .class_refs = &class_ids,
    .prior_decision_refs = &empty,
    .prior_synthesis_refs = &empty,
    .owner_boundaries = &kernel_owners,
    .pressure_signals = &kernel_pressure,
    .disposition = "converge-kernel",
    .canonical_owner = "review-kernel",
    .construction = "Install one review kernel and retire the parser-local implementation",
    .separation_obstruction = null,
    .structural_obligations = &completed_kernel_obligations,
    .selected_work_node_ref = "work-node-1",
    .falsifier = "The liabilities require distinct laws and cannot share an owner",
}};
const clean_findings = [_]Finding{};
const clean_classes = [_]EquivalenceClass{};
const clean_folds = [_]ReviewFold{.{
    .version = "RF-v2",
    .goal_id = "goal-1",
    .findings = &clean_findings,
    .compression = .{ .equivalence_classes = &clean_classes },
}};
const no_decisions = [_]Decision{};

fn validResolution(status: []const u8) Resolution {
    return .{
        .version = "review-resolution/v1",
        .resolution_id = "resolution-1",
        .run_id = "run-1",
        .review_folds = &folds,
        .finding_ids = &finding_ids,
        .resolution_history = .{
            .goal_id = "goal-1",
            .prior_resolution_refs = &empty,
            .prior_synthesis_refs = &empty,
        },
        .owner_syntheses = &fixture_syntheses,
        .decisions = &decisions,
        .outcome = .{
            .status = status,
            .semantic_balance = .{
                .uncovered_liabilities = &empty,
                .required_retirements = &empty,
                .completed_retirements = &empty,
                .dominated_remaining = &empty,
            },
        },
    };
}

fn kernelResolution(status: []const u8) Resolution {
    const closeout = std.mem.eql(u8, status, "resolved");
    return .{
        .version = "review-resolution/v1",
        .resolution_id = "resolution-1",
        .run_id = "run-1",
        .review_folds = &folds,
        .finding_ids = &finding_ids,
        .resolution_history = .{
            .goal_id = "goal-1",
            .prior_resolution_refs = &empty,
            .prior_synthesis_refs = &empty,
        },
        .owner_syntheses = if (closeout) &completed_kernel_syntheses else &pending_kernel_syntheses,
        .decisions = &kernel_decisions,
        .outcome = .{
            .status = status,
            .semantic_balance = .{
                .uncovered_liabilities = &empty,
                .required_retirements = &kernel_retirements,
                .completed_retirements = if (closeout) &kernel_retirements else &empty,
                .dominated_remaining = if (closeout) &empty else &kernel_retirements,
            },
        },
    };
}

fn validateForTest(resolution: Resolution, phase: Phase) !Issues {
    var issues = Issues{};
    errdefer issues.deinit(std.testing.allocator);
    try validateResolution(std.testing.allocator, resolution, phase, &issues);
    return issues;
}

fn hasIssue(issues: Issues, expected: []const u8) bool {
    return containsString(issues.values.items, expected);
}

test "preflight accepts one refinement per counterexample class" {
    var issues = try validateForTest(validResolution("pending"), .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "closeout accepts a structurally resolved refinement" {
    var issues = try validateForTest(validResolution("resolved"), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "preflight accepts a pressure-backed replacement kernel" {
    var issues = try validateForTest(kernelResolution("pending"), .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "closeout accepts observed kernel obligations and exact retirement" {
    var issues = try validateForTest(kernelResolution("resolved"), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "closeout accepts a clean fold without refinements" {
    var resolution = validResolution("clean");
    resolution.review_folds = &clean_folds;
    resolution.finding_ids = &empty;
    resolution.resolution_history = null;
    resolution.owner_syntheses = &no_syntheses;
    resolution.decisions = &no_decisions;
    var issues = try validateForTest(resolution, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "preflight accepts only a pending mutation resolution" {
    var issues = try validateForTest(validResolution("resolved"), .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "preflight-outcome-not-pending"));
}

test "non-blocked decision requires correctness refinement" {
    var changed = decisions;
    changed[0].correctness_refinement = null;
    var resolution = validResolution("pending");
    resolution.decisions = &changed;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "correctness-refinement-required"));
}

test "one class cannot manufacture duplicate refinements" {
    const duplicated = [_]Decision{ decisions[0], decisions[0] };
    var resolution = validResolution("pending");
    resolution.decisions = &duplicated;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "resolution-class-decision-coverage"));
    try std.testing.expect(hasIssue(issues, "correctness-refinement-class-duplicate"));
}

test "refinement must bind the quotient owner and finding set" {
    var changed = decisions;
    changed[0].owner_boundary = "handler";
    var resolution = validResolution("pending");
    resolution.decisions = &changed;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "correctness-refinement-class-mismatch"));
}

test "blocked decision retains class coverage but cannot authorize mutation" {
    const blockers = [_][]const u8{"authority is absent"};
    var changed = decisions;
    changed[0].strategy = "blocked";
    changed[0].correctness_refinement = null;
    changed[0].blockers = &blockers;
    changed[0].selected_work_node = null;
    var changed_syntheses = fixture_syntheses;
    changed_syntheses[0].disposition = "blocked";
    changed_syntheses[0].canonical_owner = null;
    changed_syntheses[0].construction = null;
    changed_syntheses[0].selected_work_node_ref = null;
    changed_syntheses[0].falsifier = "Sufficient owner evidence becomes available";
    var resolution = validResolution("blocked");
    resolution.decisions = &changed;
    resolution.owner_syntheses = &changed_syntheses;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "mutation-blocked-by-resolution"));
    try std.testing.expect(hasIssue(issues, "mutation-blocked-by-outcome"));
    try std.testing.expect(!hasIssue(issues, "resolution-class-decision-coverage"));
    try std.testing.expect(!hasIssue(issues, "decision-owner-synthesis-strategy-binding"));
}

test "decision findings must be retained RF-v2 resolution inputs" {
    const ghost_findings = [_][]const u8{"ghost"};
    var changed = decisions;
    changed[0].finding_ids = &ghost_findings;
    var resolution = validResolution("pending");
    resolution.decisions = &changed;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "decision-finding-not-retained"));
    try std.testing.expect(hasIssue(issues, "decision-finding-not-input"));
    try std.testing.expect(hasIssue(issues, "decision-class-mismatch"));
}

test "local repair may only restore an existing law" {
    var changed = decisions;
    var changed_refinement = refinement;
    changed_refinement.owner_refinement.kind = "replace-owner";
    changed[0].correctness_refinement = changed_refinement;
    var resolution = validResolution("pending");
    resolution.decisions = &changed;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "local-repair-refinement-kind"));
}

test "discrepancy determines the progress witness kind" {
    var changed = decisions;
    var changed_refinement = refinement;
    changed_refinement.progress_witness.kind = "restore";
    changed[0].correctness_refinement = changed_refinement;
    var resolution = validResolution("pending");
    resolution.decisions = &changed;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "progress-witness-kind"));
}

test "preservation and progress witnesses require nonempty verifier argv" {
    var changed = decisions;
    var changed_refinement = refinement;
    changed_refinement.preservation_witness.verifier = &empty;
    changed_refinement.progress_witness.verifier = &empty;
    changed[0].correctness_refinement = changed_refinement;
    var resolution = validResolution("pending");
    resolution.decisions = &changed;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "preservation-witness"));
    try std.testing.expect(hasIssue(issues, "progress-witness"));
}

test "nonblocked decisions cannot retain blockers" {
    const blockers = [_][]const u8{"still blocked"};
    var changed = decisions;
    changed[0].blockers = &blockers;
    var resolution = validResolution("pending");
    resolution.decisions = &changed;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "nonblocked-decision-has-blocker"));
}

test "pending retirement balance is exact" {
    const debt = [_][]const u8{"retire-x"};
    var resolution = validResolution("pending");
    resolution.outcome.semantic_balance.required_retirements = &debt;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "pending-retirement-balance-mismatch"));
}

test "closeout rejects open outcomes and semantic debt" {
    const debt = [_][]const u8{"liability-1"};
    var resolution = validResolution("pending");
    resolution.outcome.semantic_balance.uncovered_liabilities = &debt;
    resolution.outcome.semantic_balance.dominated_remaining = &debt;
    resolution.outcome.semantic_balance.required_retirements = &debt;
    var issues = try validateForTest(resolution, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "closeout-outcome-open"));
    try std.testing.expect(hasIssue(issues, "closeout-uncovered-liabilities"));
    try std.testing.expect(hasIssue(issues, "closeout-dominated-remaining"));
    try std.testing.expect(hasIssue(issues, "closeout-retirement-debt"));
}

test "closeout distinguishes clean from resolved" {
    const clean_with_findings = validResolution("clean");
    var clean_issues = try validateForTest(clean_with_findings, .closeout);
    defer clean_issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(clean_issues, "closeout-clean-has-resolution"));

    var resolved_without_findings = validResolution("resolved");
    resolved_without_findings.review_folds = &clean_folds;
    resolved_without_findings.finding_ids = &empty;
    resolved_without_findings.resolution_history = null;
    resolved_without_findings.owner_syntheses = &no_syntheses;
    resolved_without_findings.decisions = &no_decisions;
    var resolved_issues = try validateForTest(resolved_without_findings, .closeout);
    defer resolved_issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(resolved_issues, "closeout-resolved-without-findings"));
}

test "decision-bearing historical snapshots remain readable but require synthesis" {
    var resolution = validResolution("pending");
    resolution.resolution_history = null;
    resolution.owner_syntheses = &no_syntheses;
    var changed_decisions = decisions;
    changed_decisions[0].owner_synthesis_ref = null;
    changed_decisions[0].selected_work_node = null;
    resolution.decisions = &changed_decisions;

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(Envelope{ .review_resolution = resolution }, .{}, &encoded.writer);
    const bytes = try encoded.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Envelope, std.testing.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var issues = try validateForTest(parsed.value.review_resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "resolution-history-required"));
    try std.testing.expect(hasIssue(issues, "owner-synthesis-required"));
    try std.testing.expect(hasIssue(issues, "decision-owner-synthesis-required"));
}

test "stable component key is the order-independent boundary identity digest" {
    const ascending = [_][]const u8{ "a", "b" };
    const descending = [_][]const u8{ "b", "a" };
    const first = BoundaryIdentity{
        .source_worlds = &ascending,
        .target_worlds = &descending,
        .carriers = &ascending,
        .operations = &descending,
        .observations = &ascending,
        .laws = &descending,
    };
    const second = BoundaryIdentity{
        .source_worlds = &descending,
        .target_worlds = &ascending,
        .carriers = &descending,
        .operations = &ascending,
        .observations = &descending,
        .laws = &ascending,
    };
    const first_key = try canonicalComponentKeyAlloc(std.testing.allocator, first);
    defer std.testing.allocator.free(first_key);
    const second_key = try canonicalComponentKeyAlloc(std.testing.allocator, second);
    defer std.testing.allocator.free(second_key);
    try std.testing.expectEqualStrings(first_key, second_key);
}

test "stable component key cannot include transport provenance" {
    var changed_syntheses = fixture_syntheses;
    changed_syntheses[0].stable_component_key = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var resolution = validResolution("pending");
    resolution.owner_syntheses = &changed_syntheses;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "owner-synthesis-stable-component-key"));
}

test "retained synthesis history must join exactly one current component" {
    const retained = [_][]const u8{"synthesis-prior"};
    var resolution = validResolution("pending");
    var history = resolution.resolution_history.?;
    history.prior_synthesis_refs = &retained;
    resolution.resolution_history = history;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "owner-synthesis-history-join"));

    var joined_syntheses = fixture_syntheses;
    joined_syntheses[0].prior_synthesis_refs = &retained;
    resolution.owner_syntheses = &joined_syntheses;
    var joined_issues = try validateForTest(resolution, .preflight);
    defer joined_issues.deinit(std.testing.allocator);
    try std.testing.expect(!hasIssue(joined_issues, "owner-synthesis-history-join"));
}

test "resolution history remains bound to the current fold goal" {
    var changed_folds = folds;
    changed_folds[0].goal_id = "goal-other";
    var resolution = validResolution("pending");
    resolution.review_folds = &changed_folds;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "resolution-history-goal-binding"));
}

test "reuse owner rejects pressure and execution outside the canonical owner" {
    var changed_syntheses = fixture_syntheses;
    changed_syntheses[0].pressure_signals = &kernel_pressure;
    var changed_decisions = decisions;
    changed_decisions[0].selected_work_node.?.owner_boundary = "review-kernel";
    var resolution = validResolution("pending");
    resolution.owner_syntheses = &changed_syntheses;
    resolution.decisions = &changed_decisions;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "reuse-owner-has-pressure"));
    try std.testing.expect(hasIssue(issues, "selected-work-node-owner-binding"));
}

test "repair strategy is synthesis-owned" {
    var changed_syntheses = fixture_syntheses;
    changed_syntheses[0].disposition = "converge-kernel";
    var resolution = validResolution("pending");
    resolution.owner_syntheses = &changed_syntheses;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "decision-owner-synthesis-strategy-binding"));
}

test "separate laws cannot materialize a repair decision" {
    var changed_syntheses = fixture_syntheses;
    changed_syntheses[0].disposition = "separate-laws";
    changed_syntheses[0].canonical_owner = null;
    changed_syntheses[0].construction = null;
    changed_syntheses[0].falsifier = null;
    changed_syntheses[0].separation_obstruction = .{
        .statement = "The classes preserve different observations",
        .falsifier = "One construction satisfies both observation laws",
    };
    var resolution = validResolution("pending");
    resolution.owner_syntheses = &changed_syntheses;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "separate-laws-has-repair"));
    try std.testing.expect(hasIssue(issues, "decision-owner-synthesis-strategy-binding"));
}

test "one resolution can materialize only one synthesis-owned node" {
    var duplicated = [_]Decision{ decisions[0], decisions[0] };
    duplicated[1].decision_id = "decision-2";
    duplicated[1].selected_work_node.?.node_id = "work-node-2";
    var resolution = validResolution("pending");
    resolution.decisions = &duplicated;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "owner-synthesis-selected-node-cardinality"));
}

test "repair resolution cannot defer node selection to execution time" {
    var changed_decisions = decisions;
    changed_decisions[0].selected_work_node = null;
    var changed_syntheses = fixture_syntheses;
    changed_syntheses[0].selected_work_node_ref = null;
    var resolution = validResolution("pending");
    resolution.decisions = &changed_decisions;
    resolution.owner_syntheses = &changed_syntheses;
    var issues = try validateForTest(resolution, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "owner-synthesis-selected-node-cardinality"));
}

test "kernel closeout requires observations for every structural obligation" {
    var resolution = kernelResolution("resolved");
    resolution.owner_syntheses = &pending_kernel_syntheses;
    var issues = try validateForTest(resolution, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "structural-obligation-observation-required"));
}

test "kernel closeout rejects outstanding structural retirement" {
    var resolution = kernelResolution("resolved");
    resolution.outcome.semantic_balance.completed_retirements = &empty;
    var issues = try validateForTest(resolution, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "structural-obligation-retirement-incomplete"));
    try std.testing.expect(hasIssue(issues, "closeout-retirement-debt"));
}
