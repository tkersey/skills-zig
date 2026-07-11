const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;
const MaxInputBytes = 4 * 1024 * 1024;
const Version = core_cli.normalizeVersion(app_meta.version);
threadlocal var runtime_io: ?std.Io = null;

const UsageText =
    \\ledger validate
    \\
    \\usage: ledger validate {plan-source-contract,policy-synthesis-receipt,review-fold} --input FILE|-
    \\
    \\Purely validate one governance artifact. This command never reads or writes .ledger and never grants authority.
    \\
    \\contracts:
    \\  plan-source-contract       Validate a PSC-v1 plan source contract
    \\  policy-synthesis-receipt  Validate a PSR-v1 policy synthesis receipt
    \\  review-fold               Validate an RF-v2 review-fold receipt
    \\
    \\options:
    \\  --input FILE|-  Canonical JSON input path, or - for stdin
    \\  -h, --help      Show help
    \\  -V, --version   Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger validate",
    .help_text = UsageText,
};

const Contract = enum {
    plan_source_contract,
    policy_synthesis_receipt,
    review_fold,

    fn parse(raw: []const u8) ?Contract {
        if (std.mem.eql(u8, raw, "plan-source-contract")) return .plan_source_contract;
        if (std.mem.eql(u8, raw, "policy-synthesis-receipt")) return .policy_synthesis_receipt;
        if (std.mem.eql(u8, raw, "review-fold")) return .review_fold;
        return null;
    }

    fn name(self: Contract) []const u8 {
        return switch (self) {
            .plan_source_contract => "plan-source-contract",
            .policy_synthesis_receipt => "policy-synthesis-receipt",
            .review_fold => "review-fold",
        };
    }
};

const Args = struct {
    contract: Contract,
    input_path: []const u8,
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

pub fn runWithArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    runtime_io = io;
    defer runtime_io = null;

    for (argv[1..]) |token| {
        if (core_cli.isHelpArg(token)) {
            try printHelp();
            return 0;
        }
        if (core_cli.isVersionArg(token)) {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print("{s}\n", .{Version});
            return 0;
        }
    }

    const args = try parseArgs(argv);
    const input = try readInputAlloc(allocator, args.input_path);
    defer allocator.free(input);

    var issues = Issues{};
    defer issues.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        try issues.add(allocator, "malformed-json");
        try emitDecision(allocator, args.contract, &issues);
        return 2;
    };
    defer parsed.deinit();

    switch (args.contract) {
        .plan_source_contract => try validatePlanSourceContract(allocator, parsed.value, &issues),
        .policy_synthesis_receipt => try validatePolicySynthesisReceipt(allocator, parsed.value, &issues),
        .review_fold => try validateReviewFold(allocator, parsed.value, &issues),
    }

    try emitDecision(allocator, args.contract, &issues);
    return if (issues.values.items.len == 0) 0 else 2;
}

fn defaultIo() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io orelse Io.io();
}

fn printHelp() !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 3 or !std.mem.eql(u8, argv[1], "validate")) return error.MissingContract;
    const contract = Contract.parse(argv[2]) orelse return error.UnknownContract;
    var input_path: ?[]const u8 = null;
    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--input")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            input_path = argv[i];
            continue;
        }
        return error.UnknownOption;
    }
    return .{
        .contract = contract,
        .input_path = input_path orelse return error.MissingInput,
    };
}

fn readInputAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var reader = std.Io.File.stdin().reader(defaultIo(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
    }
    return std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(MaxInputBytes));
}

fn emitDecision(allocator: std.mem.Allocator, contract: Contract, issues: *Issues) !void {
    issues.sort();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"ledger-validate-decision/v1\",\"contract\":");
    try std.json.Stringify.value(contract.name(), .{}, &out.writer);
    try out.writer.writeAll(",\"verdict\":");
    try std.json.Stringify.value(if (issues.values.items.len == 0) "pass" else "blocked", .{}, &out.writer);
    try out.writer.writeAll(",\"errors\":");
    try std.json.Stringify.value(issues.values.items, .{}, &out.writer);
    try out.writer.writeAll(",\"authority_granted\":false,\"storage_mutated\":false}\n");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(bytes);
}

fn validatePlanSourceContract(allocator: std.mem.Allocator, root: std.json.Value, issues: *Issues) !void {
    const root_object = asObject(root) orelse {
        try issues.add(allocator, "input-object-required");
        return;
    };
    const psc_value = root_object.get("plan_source_contract") orelse root;
    const psc = asObject(psc_value) orelse {
        try issues.add(allocator, "plan-source-contract-object-required");
        return;
    };

    if (!fieldEqualsString(psc, "contract_version", "PSC-v1")) try issues.add(allocator, "contract-version");
    if (!fieldEqualsString(psc, "source_owner", "spec-pipeline")) try issues.add(allocator, "source-owner");
    for ([_][]const u8{ "spec_id", "implementation_spec", "decision_packet", "proof_bar", "target_branch" }) |field| {
        if (!isPresent(psc.get(field))) {
            if (std.mem.eql(u8, field, "spec_id")) try issues.add(allocator, "spec-id-required");
            if (std.mem.eql(u8, field, "implementation_spec")) try issues.add(allocator, "implementation-spec-required");
            if (std.mem.eql(u8, field, "decision_packet")) try issues.add(allocator, "decision-packet-required");
            if (std.mem.eql(u8, field, "proof_bar")) try issues.add(allocator, "proof-bar-required");
            if (std.mem.eql(u8, field, "target_branch")) try issues.add(allocator, "target-branch-required");
        }
    }
    if (!isEmptyListLike(psc.get("do_not_execute_before"))) try issues.add(allocator, "do-not-execute-before-not-empty");

    const sgr_outer = asObjectValue(psc.get("sgr_v2")) orelse {
        try issues.add(allocator, "sgr-v2-required");
        return;
    };
    const sgr = asObjectValue(sgr_outer.get("spec_governance_receipt")) orelse {
        try issues.add(allocator, "spec-governance-receipt-required");
        return;
    };
    if (!fieldEqualsString(sgr, "receipt_version", "SGR-v2")) try issues.add(allocator, "sgr-receipt-version");
    if (!fieldInStrings(sgr, "mode", &.{ "full", "repair" })) try issues.add(allocator, "sgr-mode");
    if (!fieldEqualsString(sgr, "status", "complete")) try issues.add(allocator, "sgr-status");
    if (!fieldEqualsString(sgr, "lane", "spec_to_plan")) try issues.add(allocator, "sgr-lane");

    const gate = asObjectValue(sgr.get("gate"));
    if (gate == null or !fieldEqualsYes(gate.?, "plan_allowed")) try issues.add(allocator, "sgr-plan-allowed");
    if (gate == null or !fieldEqualsNo(gate.?, "material_open_questions_remaining")) try issues.add(allocator, "sgr-open-questions");
    const lint = asObjectValue(sgr.get("lint"));
    if (lint == null or !fieldEqualsString(lint.?, "verdict", "pass")) try issues.add(allocator, "sgr-lint-verdict");
    if (lint == null or !fieldEqualsNo(lint.?, "blocked_handoff")) try issues.add(allocator, "sgr-lint-blocked-handoff");
    const handoff = asObjectValue(sgr.get("execution_handoff"));
    if (handoff == null or !fieldEqualsYes(handoff.?, "ready_for_plan")) try issues.add(allocator, "sgr-ready-for-plan");
    if (handoff == null or !fieldEqualsString(handoff.?, "next_owner", "$plan")) try issues.add(allocator, "sgr-next-owner");
    if (handoff == null or !isEmptyListLike(handoff.?.get("do_not_execute_before"))) try issues.add(allocator, "sgr-do-not-execute-before-not-empty");
    const auto_handoff = asObjectValue(sgr.get("auto_plan_handoff"));
    if (auto_handoff == null or !fieldEqualsYes(auto_handoff.?, "eligible")) try issues.add(allocator, "sgr-auto-handoff-ineligible");
    if (auto_handoff == null or !fieldInStrings(auto_handoff.?, "invocation", &.{ "same_turn_tail_call", "manual" })) try issues.add(allocator, "sgr-auto-handoff-invocation");
}

fn validatePolicySynthesisReceipt(allocator: std.mem.Allocator, root: std.json.Value, issues: *Issues) !void {
    const root_object = asObject(root) orelse {
        try issues.add(allocator, "input-object-required");
        return;
    };
    const psr_value = root_object.get("policy_synthesis_receipt") orelse root;
    const psr = asObject(psr_value) orelse {
        try issues.add(allocator, "policy-synthesis-receipt-object-required");
        return;
    };

    if (!fieldEqualsString(psr, "receipt_version", "PSR-v1")) try issues.add(allocator, "receipt-version");
    for ([_][]const u8{ "plan_id", "revision", "source_digest", "initial_policy_digest", "final_policy_digest" }) |field| {
        if (!isPresent(psr.get(field))) {
            if (std.mem.eql(u8, field, "plan_id")) try issues.add(allocator, "plan-id-required");
            if (std.mem.eql(u8, field, "revision")) try issues.add(allocator, "revision-required");
            if (std.mem.eql(u8, field, "source_digest")) try issues.add(allocator, "source-digest-required");
            if (std.mem.eql(u8, field, "initial_policy_digest")) try issues.add(allocator, "initial-policy-digest-required");
            if (std.mem.eql(u8, field, "final_policy_digest")) try issues.add(allocator, "final-policy-digest-required");
        }
    }

    const passes_value = psr.get("passes");
    const passes = asArrayValue(passes_value) orelse {
        try issues.add(allocator, "passes-nonempty-array-required");
        return validatePsrTail(allocator, psr, issues);
    };
    if (passes.items.len == 0) try issues.add(allocator, "passes-nonempty-array-required");

    const required_lenses = [_]struct { name: []const u8, issue: []const u8 }{
        .{ .name = "source_fidelity", .issue = "missing-lens:source_fidelity" },
        .{ .name = "semantic_authority", .issue = "missing-lens:semantic_authority" },
        .{ .name = "system_regime", .issue = "missing-lens:system_regime" },
        .{ .name = "belief_and_observation", .issue = "missing-lens:belief_and_observation" },
        .{ .name = "action_completeness", .issue = "missing-lens:action_completeness" },
        .{ .name = "policy_closure", .issue = "missing-lens:policy_closure" },
        .{ .name = "safety_and_rollback", .issue = "missing-lens:safety_and_rollback" },
        .{ .name = "proof_and_terminal_state", .issue = "missing-lens:proof_and_terminal_state" },
        .{ .name = "simplicity_and_actuation_readiness", .issue = "missing-lens:simplicity_and_actuation_readiness" },
    };
    for (required_lenses) |required| {
        var found = false;
        for (passes.items) |pass_value| {
            const pass = asObject(pass_value) orelse continue;
            if (fieldEqualsString(pass, "lens", required.name)) found = true;
        }
        if (!found) try issues.add(allocator, required.issue);
    }
    for (passes.items) |pass_value| {
        const pass = asObject(pass_value) orelse {
            try issues.add(allocator, "pass-object-required");
            continue;
        };
        if (!fieldInStrings(pass, "disposition", &.{ "changed", "clean", "blocked", "return_to_spec", "return_to_grill" })) {
            try issues.add(allocator, "pass-disposition");
        }
        if (fieldEqualsString(pass, "disposition", "clean") and !isEmptyListLike(pass.get("material_changes"))) {
            try issues.add(allocator, "clean-with-material-changes");
        }
    }
    if (!hasFinalCleanSweep(passes.items)) try issues.add(allocator, "complete-clean-sweep-not-witnessed");
    try validatePsrTail(allocator, psr, issues);
}

fn validatePsrTail(allocator: std.mem.Allocator, psr: std.json.ObjectMap, issues: *Issues) !void {
    const radical = asObjectValue(psr.get("radical_candidate"));
    if (radical == null or !fieldInStrings(radical.?, "disposition", &.{ "adopt", "reject", "defer", "return_to_spec", "none" })) {
        try issues.add(allocator, "radical-candidate-disposition");
    }
    const convergence = asObjectValue(psr.get("convergence"));
    if (convergence == null or !fieldEqualsBool(convergence.?, "complete_clean_sweep", true)) try issues.add(allocator, "complete-clean-sweep-required");
    if (convergence == null or !fieldEqualsBool(convergence.?, "independent_press_pass_clean", true)) try issues.add(allocator, "requires-press-pass");
    if (convergence == null or !fieldEqualsBool(convergence.?, "improvements_exhausted", true)) try issues.add(allocator, "improvements-not-exhausted");
    if (convergence == null or !isEmptyListLike(convergence.?.get("unresolved_errors"))) try issues.add(allocator, "unresolved-errors");
    if (convergence == null or !isEmptyListLike(convergence.?.get("untreated_material_risks"))) try issues.add(allocator, "untreated-material-risks");

    const source_contract = asObjectValue(psr.get("source_contract"));
    if (source_contract == null or !fieldInStrings(source_contract.?, "kind", &.{ "direct", "PSC-v1", "revision" })) {
        try issues.add(allocator, "source-contract-kind");
    } else if (fieldEqualsString(source_contract.?, "kind", "PSC-v1")) {
        if (!fieldEqualsString(source_contract.?, "source_owner", "spec-pipeline")) try issues.add(allocator, "psc-source-owner");
        if (!isPresent(source_contract.?.get("spec_id"))) try issues.add(allocator, "psc-spec-id-required");
    }
}

fn validateReviewFold(allocator: std.mem.Allocator, root: std.json.Value, issues: *Issues) !void {
    const root_object = asObject(root) orelse {
        try issues.add(allocator, "input-object-required");
        return;
    };
    const receipt_value = root_object.get("review_fold") orelse root;
    const receipt = asObject(receipt_value) orelse {
        try issues.add(allocator, "review-fold-object-required");
        return;
    };

    if (!fieldEqualsString(receipt, "version", "RF-v2")) try issues.add(allocator, "receipt-version");
    if (!isNonblankString(receipt.get("fold_id"))) try issues.add(allocator, "fold-id-missing");
    if (!isNonblankString(receipt.get("goal_id"))) try issues.add(allocator, "goal-id-missing");

    const source = asObjectValue(receipt.get("source"));
    if (source == null) try issues.add(allocator, "source-missing");
    const source_state = if (source) |value| stringField(value, "source_state") orelse "" else "";
    if (source == null or !fieldInStrings(source.?, "backend", &.{ "cas", "github-comments", "human-review", "prior-artifact", "local-audit", "other" })) try issues.add(allocator, "source-backend");
    if (source == null or !isNonblankString(source.?.get("source_batch_id")) or !isNonblankString(source.?.get("source_ref"))) try issues.add(allocator, "source-identity");
    if (!stringIn(source_state, &.{ "clean", "findings", "invalid-proof", "incomplete" })) try issues.add(allocator, "source-state");
    if (source) |value| {
        const artifact = asObjectValue(value.get("artifact"));
        if (artifact == null or !allNonblankFields(artifact.?, &.{ "repo", "base_sha", "branch", "head_sha", "state_fingerprint" })) try issues.add(allocator, "source-artifact");
    } else try issues.add(allocator, "source-artifact");

    const intent = asObjectValue(receipt.get("intent_anchor"));
    if (intent == null or !isNonblankString(intent.?.get("original_goal"))) {
        try issues.add(allocator, "intent-anchor");
    } else if (asArrayValue(intent.?.get("accepted_scope")) == null or asArrayValue(intent.?.get("non_goals")) == null) {
        try issues.add(allocator, "intent-scope");
    }
    for ([_][]const u8{ "strategy", "selected_work_node", "clean_run", "clean_count", "clean_run_accounting", "closure_verdict", "mutation_authority" }) |forbidden| {
        if (receipt.get(forbidden) != null) try issues.add(allocator, "receipt-owned-field");
    }

    const findings = asArrayValue(receipt.get("findings")) orelse {
        try issues.add(allocator, "findings-shape");
        return validateReviewCompressionAndRoutes(allocator, receipt, &.{}, issues);
    };
    for (findings.items) |finding_value| {
        if (asObject(finding_value) == null) try issues.add(allocator, "findings-shape");
    }
    if (std.mem.eql(u8, source_state, "clean") and findings.items.len != 0) try issues.add(allocator, "clean-source-has-findings");
    if (std.mem.eql(u8, source_state, "findings") and findings.items.len == 0) try issues.add(allocator, "findings-source-empty");

    for (findings.items, 0..) |finding_value, index| {
        const finding = asObject(finding_value) orelse continue;
        const finding_id = nonblankString(finding.get("finding_id")) orelse "";
        if (finding_id.len == 0 or duplicateFindingId(findings.items, index, finding_id)) try issues.add(allocator, "finding-id");
        if (!isNonblankString(finding.get("source_ref"))) try issues.add(allocator, "finding-source");
        const claim = nonblankString(finding.get("claim")) orelse "";
        if (claim.len == 0) try issues.add(allocator, "finding-claim");
        const validity = stringField(finding, "validity") orelse "";
        const liability = stringField(finding, "liability") orelse "";
        const intent_relation = stringField(finding, "intent_relation") orelse "";
        const novelty = stringField(finding, "novelty") orelse "";
        const disposition = stringField(finding, "disposition") orelse "";
        if (!stringIn(validity, &.{ "valid", "invalid", "unproven", "needs-owner" })) try issues.add(allocator, "finding-validity");
        if (!stringIn(liability, &.{ "blocks-goal", "regression-risk", "proof-gap", "misuse-hazard", "invariant-gap", "complexity-stall", "style", "new-requirement", "out-of-scope" })) try issues.add(allocator, "finding-liability");
        if (!stringIn(intent_relation, &.{ "core", "adjacent", "unrelated", "expands-scope" })) try issues.add(allocator, "finding-intent");
        if (!stringIn(novelty, &.{ "duplicate", "same-class", "new-class" })) try issues.add(allocator, "finding-novelty");
        if (!stringIn(disposition, &.{ "reject", "proof-only", "ask-human", "follow-up", "resolution-input", "blocked" })) try issues.add(allocator, "finding-disposition");
        if (std.mem.eql(u8, disposition, "follow-up") and std.mem.eql(u8, intent_relation, "core")) try issues.add(allocator, "follow-up-intent");

        const material = isMaterialLiability(liability);
        const quotient = nonblankString(finding.get("quotient_key")) orelse "";
        const duplicate_covered = std.mem.eql(u8, novelty, "duplicate") and std.mem.eql(u8, disposition, "reject") and quotientHasRoutedFinding(findings.items, quotient);
        if (std.mem.eql(u8, intent_relation, "core") and material and !validDisposition(validity, disposition) and !duplicate_covered) try issues.add(allocator, "core-material-disposition");

        const authority = asObjectValue(finding.get("mutation_authority"));
        if (authority == null or !fieldEqualsBool(authority.?, "allowed", false)) try issues.add(allocator, "finding-mutation-authority");
        if (authority == null or !isNonblankString(authority.?.get("reason"))) try issues.add(allocator, "finding-mutation-reason");
        if (quotient.len == 0) try issues.add(allocator, "finding-quotient");

        if (material) {
            const observed = nonblankString(finding.get("observed_fact")) orelse "";
            if (observed.len == 0 or std.mem.eql(u8, observed, claim)) try issues.add(allocator, "material-observed-fact");
            if (!isNonblankString(finding.get("owner_boundary"))) try issues.add(allocator, "material-owner_boundary");
            if (!isNonblankString(finding.get("law_family"))) try issues.add(allocator, "material-law_family");
            if (!isNonblankString(finding.get("falsifier"))) try issues.add(allocator, "material-falsifier");
            if (!nonblankStringArray(finding.get("evidence_refs"))) try issues.add(allocator, "material-evidence");
        }
        if (std.mem.eql(u8, disposition, "resolution-input")) {
            if (!std.mem.eql(u8, source_state, "findings")) try issues.add(allocator, "resolution-input-source-state");
            if (!std.mem.eql(u8, validity, "valid")) try issues.add(allocator, "resolution-input-validity");
            if (!stringIn(intent_relation, &.{ "core", "adjacent" })) try issues.add(allocator, "resolution-input-intent");
            if (!material) try issues.add(allocator, "resolution-input-liability");
        }
        for ([_][]const u8{ "strategy", "selected_work_node", "clean_run", "clean_count", "closure_verdict" }) |forbidden| {
            if (finding.get(forbidden) != null) try issues.add(allocator, "finding-owned-field");
        }
    }
    try validateReviewCompressionAndRoutes(allocator, receipt, findings.items, issues);
}

fn validateReviewCompressionAndRoutes(allocator: std.mem.Allocator, receipt: std.json.ObjectMap, findings: []const std.json.Value, issues: *Issues) !void {
    const compression = asObjectValue(receipt.get("compression"));
    const classes = if (compression) |value| asArrayValue(value.get("equivalence_classes")) else null;
    if (classes == null) try issues.add(allocator, "compression-coverage");
    if (classes) |rows| {
        for (rows.items, 0..) |row_value, row_index| {
            const row = asObject(row_value) orelse {
                try issues.add(allocator, "compression-key");
                continue;
            };
            const key = nonblankString(row.get("quotient_key")) orelse "";
            if (key.len == 0 or duplicateStringField(rows.items, row_index, "quotient_key", key)) try issues.add(allocator, "compression-key");
            const owner = nonblankString(row.get("owner_boundary")) orelse "";
            const law = nonblankString(row.get("law_family")) orelse "";
            if (owner.len == 0 or law.len == 0) try issues.add(allocator, "compression-owner-law");
            const member_ids = asArrayValue(row.get("finding_ids"));
            if (member_ids == null or !classCoverageMatches(findings, key, member_ids.?.items)) try issues.add(allocator, "compression-coverage");
            for (findings) |finding_value| {
                const finding = asObject(finding_value) orelse continue;
                const quotient = nonblankString(finding.get("quotient_key")) orelse continue;
                if (!std.mem.eql(u8, quotient, key) or !isMaterialLiability(stringField(finding, "liability") orelse "")) continue;
                if (!fieldEqualsString(finding, "owner_boundary", owner) or !fieldEqualsString(finding, "law_family", law)) {
                    try issues.add(allocator, "compression-owner-law-mismatch");
                }
            }
        }
        for (findings) |finding_value| {
            const finding = asObject(finding_value) orelse continue;
            const quotient = nonblankString(finding.get("quotient_key")) orelse continue;
            if (countRowsWithField(rows.items, "quotient_key", quotient) != 1) try issues.add(allocator, "compression-coverage");
        }
    }

    const routes = asArrayValue(receipt.get("routing_obligations"));
    if (routes == null) {
        try issues.add(allocator, "routing-obligations-array-required");
        if (hasRoutedLiability(findings)) try issues.add(allocator, "routing-coverage");
        return;
    }
    for (routes.?.items, 0..) |row_value, row_index| {
        const row = asObject(row_value) orelse {
            try issues.add(allocator, "routing-owner");
            continue;
        };
        const trigger = stringField(row, "trigger") orelse "";
        const expected_owner = routeOwner(trigger) orelse "";
        if (expected_owner.len == 0 or !fieldEqualsString(row, "owner_lens", expected_owner)) try issues.add(allocator, "routing-owner");
        if (duplicateStringField(routes.?.items, row_index, "trigger", trigger)) try issues.add(allocator, "routing-coverage");
        const ids = asArrayValue(row.get("finding_ids"));
        if (ids == null or !routeCoverageMatches(findings, trigger, ids.?.items)) try issues.add(allocator, "routing-coverage");
    }
    for ([_][]const u8{ "misuse-hazard", "invariant-gap", "complexity-stall" }) |trigger| {
        const expected = countFindingsByLiability(findings, trigger);
        const declared = countRowsWithField(routes.?.items, "trigger", trigger);
        if ((expected == 0 and declared != 0) or (expected != 0 and declared != 1)) try issues.add(allocator, "routing-coverage");
    }
}

fn asObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn asObjectValue(value: ?std.json.Value) ?std.json.ObjectMap {
    return if (value) |actual| asObject(actual) else null;
}

fn asArrayValue(value: ?std.json.Value) ?std.json.Array {
    if (value) |actual| return switch (actual) {
        .array => |array| array,
        else => null,
    };
    return null;
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    if (value) |actual| return switch (actual) {
        .string => |string| string,
        else => null,
    };
    return null;
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return stringValue(object.get(field));
}

fn nonblankString(value: ?std.json.Value) ?[]const u8 {
    const raw = stringValue(value) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn isNonblankString(value: ?std.json.Value) bool {
    return nonblankString(value) != null;
}

fn fieldEqualsString(object: std.json.ObjectMap, field: []const u8, expected: []const u8) bool {
    const actual = stringField(object, field) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn fieldInStrings(object: std.json.ObjectMap, field: []const u8, expected: []const []const u8) bool {
    const actual = stringField(object, field) orelse return false;
    return stringIn(actual, expected);
}

fn stringIn(actual: []const u8, expected: []const []const u8) bool {
    for (expected) |candidate| if (std.mem.eql(u8, actual, candidate)) return true;
    return false;
}

fn fieldEqualsBool(object: std.json.ObjectMap, field: []const u8, expected: bool) bool {
    const value = object.get(field) orelse return false;
    return switch (value) {
        .bool => |actual| actual == expected,
        else => false,
    };
}

fn fieldEqualsYes(object: std.json.ObjectMap, field: []const u8) bool {
    const value = object.get(field) orelse return false;
    return switch (value) {
        .bool => |actual| actual,
        .string => |actual| std.ascii.eqlIgnoreCase(actual, "yes"),
        else => false,
    };
}

fn fieldEqualsNo(object: std.json.ObjectMap, field: []const u8) bool {
    const value = object.get(field) orelse return false;
    return switch (value) {
        .bool => |actual| !actual,
        .string => |actual| std.ascii.eqlIgnoreCase(actual, "no"),
        else => false,
    };
}

fn isPresent(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    return switch (actual) {
        .null => false,
        .bool => |boolean| boolean,
        .integer => |integer| integer != 0,
        .float => |float| float != 0,
        .number_string => |number| number.len != 0 and !std.mem.eql(u8, number, "0"),
        .string => |string| std.mem.trim(u8, string, " \t\r\n").len != 0,
        .array => |array| array.items.len != 0,
        .object => |object| object.count() != 0,
    };
}

fn isEmptyListLike(value: ?std.json.Value) bool {
    const actual = value orelse return true;
    return switch (actual) {
        .null => true,
        .array => |array| array.items.len == 0,
        else => false,
    };
}

fn allNonblankFields(object: std.json.ObjectMap, fields: []const []const u8) bool {
    for (fields) |field| if (!isNonblankString(object.get(field))) return false;
    return true;
}

fn nonblankStringArray(value: ?std.json.Value) bool {
    const array = asArrayValue(value) orelse return false;
    if (array.items.len == 0) return false;
    for (array.items) |item| if (!isNonblankString(item)) return false;
    return true;
}

fn isMaterialLiability(liability: []const u8) bool {
    return stringIn(liability, &.{ "blocks-goal", "regression-risk", "proof-gap", "misuse-hazard", "invariant-gap", "complexity-stall" });
}

fn hasFinalCleanSweep(passes: []const std.json.Value) bool {
    const lenses = [_][]const u8{
        "source_fidelity",
        "semantic_authority",
        "system_regime",
        "belief_and_observation",
        "action_completeness",
        "policy_closure",
        "safety_and_rollback",
        "proof_and_terminal_state",
        "simplicity_and_actuation_readiness",
    };
    if (passes.len < lenses.len) return false;
    const suffix = passes[passes.len - lenses.len ..];
    for (suffix, lenses) |pass_value, lens| {
        const pass = asObject(pass_value) orelse return false;
        if (!fieldEqualsString(pass, "lens", lens)) return false;
        if (!fieldEqualsString(pass, "disposition", "clean")) return false;
        if (!isEmptyListLike(pass.get("material_changes"))) return false;
    }
    return true;
}

fn validDisposition(validity: []const u8, disposition: []const u8) bool {
    if (std.mem.eql(u8, validity, "valid")) return stringIn(disposition, &.{ "resolution-input", "ask-human", "blocked" });
    if (std.mem.eql(u8, validity, "unproven")) return stringIn(disposition, &.{ "proof-only", "blocked" });
    if (std.mem.eql(u8, validity, "needs-owner")) return stringIn(disposition, &.{ "ask-human", "blocked" });
    if (std.mem.eql(u8, validity, "invalid")) return std.mem.eql(u8, disposition, "reject");
    return false;
}

fn duplicateFindingId(findings: []const std.json.Value, current: usize, finding_id: []const u8) bool {
    for (findings, 0..) |value, index| {
        if (index == current) continue;
        const finding = asObject(value) orelse continue;
        const other = nonblankString(finding.get("finding_id")) orelse continue;
        if (std.mem.eql(u8, other, finding_id)) return true;
    }
    return false;
}

fn quotientHasRoutedFinding(findings: []const std.json.Value, quotient: []const u8) bool {
    if (quotient.len == 0) return false;
    for (findings) |value| {
        const finding = asObject(value) orelse continue;
        const other = nonblankString(finding.get("quotient_key")) orelse continue;
        const disposition = stringField(finding, "disposition") orelse continue;
        if (std.mem.eql(u8, other, quotient) and stringIn(disposition, &.{ "resolution-input", "ask-human", "blocked" })) return true;
    }
    return false;
}

fn duplicateStringField(rows: []const std.json.Value, current: usize, field: []const u8, expected: []const u8) bool {
    for (rows, 0..) |value, index| {
        if (index == current) continue;
        const row = asObject(value) orelse continue;
        const actual = nonblankString(row.get(field)) orelse continue;
        if (std.mem.eql(u8, actual, expected)) return true;
    }
    return false;
}

fn countRowsWithField(rows: []const std.json.Value, field: []const u8, expected: []const u8) usize {
    var count: usize = 0;
    for (rows) |value| {
        const row = asObject(value) orelse continue;
        const actual = nonblankString(row.get(field)) orelse continue;
        if (std.mem.eql(u8, actual, expected)) count += 1;
    }
    return count;
}

fn classCoverageMatches(findings: []const std.json.Value, quotient: []const u8, ids: []const std.json.Value) bool {
    var expected_count: usize = 0;
    for (findings) |value| {
        const finding = asObject(value) orelse continue;
        const key = nonblankString(finding.get("quotient_key")) orelse continue;
        if (!std.mem.eql(u8, key, quotient)) continue;
        expected_count += 1;
        const id = nonblankString(finding.get("finding_id")) orelse return false;
        if (countStringValues(ids, id) != 1) return false;
    }
    if (expected_count != ids.len) return false;
    for (ids) |id_value| if (!isNonblankString(id_value)) return false;
    return true;
}

fn countStringValues(values: []const std.json.Value, expected: []const u8) usize {
    var count: usize = 0;
    for (values) |value| {
        const actual = nonblankString(value) orelse continue;
        if (std.mem.eql(u8, actual, expected)) count += 1;
    }
    return count;
}

fn routeOwner(trigger: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, trigger, "misuse-hazard")) return "footgun-finder";
    if (std.mem.eql(u8, trigger, "invariant-gap")) return "invariant-ace";
    if (std.mem.eql(u8, trigger, "complexity-stall")) return "complexity-mitigator";
    return null;
}

fn countFindingsByLiability(findings: []const std.json.Value, liability: []const u8) usize {
    var count: usize = 0;
    for (findings) |value| {
        const finding = asObject(value) orelse continue;
        if (fieldEqualsString(finding, "liability", liability)) count += 1;
    }
    return count;
}

fn hasRoutedLiability(findings: []const std.json.Value) bool {
    for (findings) |value| {
        const finding = asObject(value) orelse continue;
        if (routeOwner(stringField(finding, "liability") orelse "") != null) return true;
    }
    return false;
}

fn routeCoverageMatches(findings: []const std.json.Value, trigger: []const u8, ids: []const std.json.Value) bool {
    const expected_count = countFindingsByLiability(findings, trigger);
    if (expected_count != ids.len) return false;
    for (findings) |value| {
        const finding = asObject(value) orelse continue;
        if (!fieldEqualsString(finding, "liability", trigger)) continue;
        const id = nonblankString(finding.get("finding_id")) orelse return false;
        if (countStringValues(ids, id) != 1) return false;
    }
    for (ids) |id| if (!isNonblankString(id)) return false;
    return true;
}

fn lessString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

test "plan source contract validation passes a complete PSC-v1" {
    const input =
        \\{"plan_source_contract":{"contract_version":"PSC-v1","source_owner":"spec-pipeline","spec_id":"spec-1","implementation_spec":{"ref":"spec"},"decision_packet":{"ref":"decision"},"proof_bar":{"commands":["zig build test"]},"target_branch":"main","do_not_execute_before":[],"sgr_v2":{"spec_governance_receipt":{"receipt_version":"SGR-v2","mode":"full","status":"complete","lane":"spec_to_plan","gate":{"plan_allowed":"yes","material_open_questions_remaining":"no"},"lint":{"verdict":"pass","blocked_handoff":"no"},"execution_handoff":{"ready_for_plan":"yes","next_owner":"$plan","do_not_execute_before":[]},"auto_plan_handoff":{"eligible":"yes","invocation":"same_turn_tail_call"}}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    try validatePlanSourceContract(std.testing.allocator, parsed.value, &issues);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "policy synthesis validation enforces every lens and fixed point" {
    const input =
        \\{"policy_synthesis_receipt":{"receipt_version":"PSR-v1","plan_id":"plan-1","revision":1,"source_digest":"sha256:source","initial_policy_digest":"sha256:before","final_policy_digest":"sha256:after","source_contract":{"kind":"direct"},"passes":[{"lens":"source_fidelity","disposition":"clean","material_changes":[]},{"lens":"semantic_authority","disposition":"clean","material_changes":[]},{"lens":"system_regime","disposition":"clean","material_changes":[]},{"lens":"belief_and_observation","disposition":"clean","material_changes":[]},{"lens":"action_completeness","disposition":"clean","material_changes":[]},{"lens":"policy_closure","disposition":"clean","material_changes":[]},{"lens":"safety_and_rollback","disposition":"clean","material_changes":[]},{"lens":"proof_and_terminal_state","disposition":"clean","material_changes":[]},{"lens":"simplicity_and_actuation_readiness","disposition":"clean","material_changes":[]}],"radical_candidate":{"disposition":"none"},"convergence":{"complete_clean_sweep":true,"independent_press_pass_clean":true,"unresolved_errors":[],"untreated_material_risks":[],"improvements_exhausted":true}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    try validatePolicySynthesisReceipt(std.testing.allocator, parsed.value, &issues);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "policy synthesis validation rejects an incomplete fixed point" {
    const input =
        \\{"policy_synthesis_receipt":{"receipt_version":"PSR-v1","plan_id":"plan-1","revision":1,"source_digest":"sha256:source","initial_policy_digest":"sha256:before","final_policy_digest":"sha256:after","passes":[{"lens":"source_fidelity","disposition":"clean","material_changes":["late change"]}],"radical_candidate":{"disposition":"skip"},"convergence":{"complete_clean_sweep":false,"independent_press_pass_clean":false,"unresolved_errors":["open"],"untreated_material_risks":["risk"],"improvements_exhausted":false}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    try validatePolicySynthesisReceipt(std.testing.allocator, parsed.value, &issues);
    try std.testing.expect(containsIssue(issues.values.items, "clean-with-material-changes"));
    try std.testing.expect(containsIssue(issues.values.items, "radical-candidate-disposition"));
    try std.testing.expect(containsIssue(issues.values.items, "requires-press-pass"));
    try std.testing.expect(containsIssue(issues.values.items, "unresolved-errors"));
    try std.testing.expect(containsIssue(issues.values.items, "untreated-material-risks"));
    try std.testing.expect(containsIssue(issues.values.items, "missing-lens:policy_closure"));
}

test "review fold validation accepts material classified evidence" {
    const input =
        \\{"review_fold":{"version":"RF-v2","fold_id":"rf-1","goal_id":"goal-1","source":{"backend":"cas","source_batch_id":"batch-1","source_state":"findings","artifact":{"repo":"/repo","base_sha":"base","branch":"main","head_sha":"head","state_fingerprint":"sha256:state"},"source_ref":"cas:batch-1"},"intent_anchor":{"original_goal":"fix invariant","accepted_scope":["src"],"non_goals":[]},"findings":[{"finding_id":"finding-1","source_ref":"cas:finding-1","claim":"validation missing","observed_fact":"transition bypasses owner","suggested_repair":"validate","validity":"valid","liability":"invariant-gap","intent_relation":"core","novelty":"new-class","disposition":"resolution-input","quotient_key":"owner-validation","owner_boundary":"state-owner","law_family":"transition-preservation","falsifier":"invalid transition accepted","evidence_refs":["test:transition"],"mutation_authority":{"allowed":false,"reason":"resolution selects work"}}],"compression":{"equivalence_classes":[{"quotient_key":"owner-validation","finding_ids":["finding-1"],"owner_boundary":"state-owner","law_family":"transition-preservation"}]},"routing_obligations":[{"trigger":"invariant-gap","finding_ids":["finding-1"],"owner_lens":"invariant-ace"}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    try validateReviewFold(std.testing.allocator, parsed.value, &issues);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "review fold validation rejects authority and uncovered material evidence" {
    const input =
        \\{"review_fold":{"version":"RF-v2","fold_id":"rf-1","goal_id":"goal-1","source":{"backend":"cas","source_batch_id":"batch-1","source_state":"findings","artifact":{"repo":"/repo","base_sha":"base","branch":"main","head_sha":"head","state_fingerprint":"sha256:state"},"source_ref":"cas:batch-1"},"intent_anchor":{"original_goal":"fix invariant","accepted_scope":["src"],"non_goals":[]},"findings":[{"finding_id":"finding-1","source_ref":"cas:finding-1","claim":"validation missing","observed_fact":"validation missing","validity":"valid","liability":"invariant-gap","intent_relation":"core","novelty":"new-class","disposition":"resolution-input","quotient_key":"owner-validation","owner_boundary":"state-owner","law_family":"transition-preservation","falsifier":"invalid transition accepted","evidence_refs":[],"mutation_authority":{"allowed":true,"reason":"bad"},"selected_work_node":{"id":"bad"}}],"compression":{"equivalence_classes":[]},"routing_obligations":[]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    try validateReviewFold(std.testing.allocator, parsed.value, &issues);
    try std.testing.expect(containsIssue(issues.values.items, "finding-mutation-authority"));
    try std.testing.expect(containsIssue(issues.values.items, "finding-owned-field"));
    try std.testing.expect(containsIssue(issues.values.items, "material-observed-fact"));
    try std.testing.expect(containsIssue(issues.values.items, "material-evidence"));
    try std.testing.expect(containsIssue(issues.values.items, "compression-coverage"));
    try std.testing.expect(containsIssue(issues.values.items, "routing-coverage"));
}

fn containsIssue(issues: []const []const u8, expected: []const u8) bool {
    for (issues) |issue| if (std.mem.eql(u8, issue, expected)) return true;
    return false;
}
