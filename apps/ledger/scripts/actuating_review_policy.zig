const std = @import("std");

const MaxInputBytes = 4 * 1024 * 1024;
const MaxReferenceBytes = 4 * 1024 * 1024;
const MinimumStandardCleanRuns = 5;

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

const Artifact = struct {
    repo: []const u8,
    base_ref: []const u8,
    base_sha: []const u8,
    head_sha: []const u8,
    state_fingerprint: []const u8,
};

const WorkflowBinding = struct {
    requestId: []const u8,
    requestFingerprint: []const u8,
};

const Attempt = struct {
    workflow_binding: WorkflowBinding,
    review_attempt_id: []const u8,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    base_sha: []const u8,
    head_sha: []const u8,
    target_fingerprint: []const u8,
    context_identity_matches: bool,
    principal_kind: []const u8,
    principal_reduced: bool,
    fallback_used: bool,
    principal_source: []const u8,
    verdict_status: []const u8,
    finding_count: usize,
    record_ref: []const u8,
};

const Request = struct {
    request_id: []const u8,
    request_fingerprint: ?[]const u8 = null,
    lens: []const u8,
    role: []const u8,
    selection_reason: []const u8,
    contract_id: ?[]const u8 = null,
    contract_ref: ?[]const u8 = null,
    contract_digest: ?[]const u8 = null,
    instructions_ref: ?[]const u8 = null,
    instruction_digest: ?[]const u8 = null,
    state: []const u8,
    not_required_reason: ?[]const u8 = null, // Legacy input retained only for explicit fail-closed rejection.
    attempts: []const Attempt,
    review_fold_refs: []const []const u8,
};

const StandardAttemptEvidence = struct {
    artifact: Artifact,
    goal_contract_digest: []const u8,
    resolution_digest: ?[]const u8 = null,
    review_contract_digest: []const u8,
    request_id: []const u8,
    request_fingerprint: []const u8,
    contract_id: []const u8,
    contract_digest: []const u8,
    instruction_digest: []const u8,
    attempt: Attempt,
};

const AuxiliaryRemediationCarry = struct {
    kind: []const u8,
    from_attempt_id: []const u8,
    to_artifact: Artifact,
    from_goal_contract_digest: []const u8,
    to_goal_contract_digest: []const u8,
    resolution_digest: []const u8,
    source_auxiliary_request_ids: []const []const u8,
    review_fold_refs: []const []const u8,
    correctness_decision_refs: []const []const u8,
    preservation_observation_refs: []const []const u8,
    progress_observation_refs: []const []const u8,
    actuation_event_refs: []const []const u8,
    ship_ref: []const u8,
};

const StandardCleanChain = struct {
    standard_attempts: []const StandardAttemptEvidence,
    carry_transitions: []const AuxiliaryRemediationCarry,
};

const Policy = struct {
    version: []const u8,
    policy_id: []const u8,
    run_id: []const u8,
    goal_contract_digest: []const u8,
    resolution_digest: ?[]const u8 = null,
    artifact: Artifact,
    standard_required_clean_runs: usize,
    required_lenses: []const []const u8,
    requests: []const Request,
    standard_clean_attempt_ids: []const []const u8,
    invalidation_reasons: []const []const u8,
    review_contract_ref: ?[]const u8 = null,
    review_contract_digest: ?[]const u8 = null,
    standard_clean_chain: ?StandardCleanChain = null,
};

const Envelope = struct {
    actuation_review_policy: Policy,
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
        try stderr_writer.interface.print("ledger validate actuation-review-policy: {s}\n", .{@errorName(err)});
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
        .ignore_unknown_fields = false,
    }) catch {
        try issues.add(allocator, "malformed-or-schema-invalid-json");
        try emitDecision(allocator, io, args.phase, &issues);
        return 2;
    };
    defer parsed.deinit();

    try validatePolicy(allocator, io, parsed.value.actuation_review_policy, args.phase, true, &issues);
    try emitDecision(allocator, io, args.phase, &issues);
    return if (issues.values.items.len == 0) 0 else 2;
}

fn printHelp(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    try stdout_writer.interface.writeAll(
        \\ledger validate actuation-review-policy
        \\
        \\usage: ledger validate actuation-review-policy --phase {preflight|closeout} --input FILE|-
        \\
        \\Purely check one actuation-review-policy/v1 or v2 JSON snapshot. The decision grants no authority and mutates no storage.
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
    try out.writer.writeAll("{\"schema\":\"actuation-review-policy-decision/v1\",\"phase\":");
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

fn validatePolicy(
    allocator: std.mem.Allocator,
    io: std.Io,
    policy: Policy,
    phase: Phase,
    verify_references: bool,
    issues: *Issues,
) !void {
    const is_v1 = std.mem.eql(u8, policy.version, "actuation-review-policy/v1");
    const is_v2 = std.mem.eql(u8, policy.version, "actuation-review-policy/v2");
    if (!is_v1 and !is_v2) try issues.add(allocator, "policy-version");
    for ([_][]const u8{ policy.policy_id, policy.run_id }) |value| {
        if (!isNonblank(value)) try issues.add(allocator, "required-policy-identity");
    }
    try validateArtifact(allocator, policy.artifact, "required-policy-identity", "artifact-state-fingerprint", issues);
    if (!isDigest(policy.goal_contract_digest)) try issues.add(allocator, "goal-contract-digest");
    if (policy.resolution_digest) |digest| if (!isDigest(digest)) try issues.add(allocator, "resolution-digest");
    if (policy.standard_required_clean_runs < MinimumStandardCleanRuns) try issues.add(allocator, "standard-clean-runs-below-policy-minimum");
    if (policy.required_lenses.len == 0 or policy.requests.len == 0) try issues.add(allocator, "requests-required");
    if (policy.required_lenses.len != policy.requests.len) try issues.add(allocator, "registry-request-cardinality");

    if (is_v1) {
        if (policy.review_contract_ref != null or policy.review_contract_digest != null or policy.standard_clean_chain != null) {
            try issues.add(allocator, "v1-standard-clean-chain");
        }
    } else if (is_v2) {
        if (policy.review_contract_ref == null or !isNonblank(policy.review_contract_ref.?)) {
            try issues.add(allocator, "review-contract-ref-required");
        }
        if (policy.review_contract_digest == null or !isDigest(policy.review_contract_digest.?)) {
            try issues.add(allocator, "review-contract-digest-required");
        }
        if (policy.standard_clean_chain == null) try issues.add(allocator, "standard-clean-chain-required");
        if (verify_references and policy.review_contract_ref != null and policy.review_contract_digest != null) {
            try verifyReferenceDigest(
                allocator,
                io,
                policy.review_contract_ref.?,
                policy.review_contract_digest.?,
                "review-contract-ref-unreadable",
                "review-contract-digest-mismatch",
                issues,
            );
        }
    }

    var standard_index: ?usize = null;
    for (policy.required_lenses, 0..) |lens, index| {
        if (!isNonblank(lens)) try issues.add(allocator, "registry-lens-empty");
        if (containsString(policy.required_lenses[0..index], lens)) try issues.add(allocator, "registry-lens-duplicate");
        if (countRequestsWithLens(policy.requests, lens) != 1) try issues.add(allocator, "registry-request-coverage");
    }

    for (policy.requests, 0..) |request, request_index| {
        if (!isNonblank(request.request_id) or !isNonblank(request.lens) or !isNonblank(request.selection_reason)) {
            try issues.add(allocator, "request-identity");
        }
        if (containsRequestIdentity(policy.requests[0..request_index], request)) try issues.add(allocator, "request-identity-duplicate");
        if (!containsString(policy.required_lenses, request.lens)) try issues.add(allocator, "request-lens-not-registered");
        if (!stringIn(request.role, &.{ "standard", "auxiliary" })) try issues.add(allocator, "request-role");
        if (!stringIn(request.state, &.{ "selected-pending", "clean", "findings-folded", "candidate-pressure", "blocked", "rerun-required" })) {
            try issues.add(allocator, "request-state");
        }

        if (std.mem.eql(u8, request.role, "standard")) {
            if (standard_index != null) try issues.add(allocator, "multiple-standard-requests") else standard_index = request_index;
            if (std.mem.eql(u8, request.state, "not-required")) try issues.add(allocator, "standard-not-required");
        }

        if (std.mem.eql(u8, request.state, "not-required")) {
            if (std.mem.eql(u8, request.role, "auxiliary")) {
                try issues.add(allocator, "auxiliary-request-required");
            } else {
                try issues.add(allocator, "not-required-role");
            }
            if (hasBoundRequest(request) or request.attempts.len != 0 or request.review_fold_refs.len != 0) {
                try issues.add(allocator, "not-required-has-execution-evidence");
            }
        } else {
            if (optionalNonblank(request.not_required_reason)) try issues.add(allocator, "selected-request-has-not-required-reason");
            try validateBoundRequest(allocator, io, request, verify_references, issues);
        }

        for (request.attempts, 0..) |attempt, attempt_index| {
            try validateAttempt(allocator, policy, request, attempt, issues);
            if (attemptIdentitySeen(policy.requests, request_index, attempt_index, attempt.review_attempt_id)) {
                try issues.add(allocator, "review-attempt-duplicate");
            }
        }
    }
    if (standard_index == null) try issues.add(allocator, "standard-request-required");

    if (is_v2) if (standard_index) |index| {
        if (policy.standard_clean_chain) |chain| {
            try validateStandardCleanChain(allocator, policy, chain, policy.requests[index], phase, issues);
        }
    };

    switch (phase) {
        .preflight => try validatePreflight(allocator, policy, is_v2, issues),
        .closeout => if (standard_index) |index| try validateCloseout(allocator, policy, index, is_v2, issues),
    }
}

fn validateBoundRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
    verify_references: bool,
    issues: *Issues,
) !void {
    const request_fingerprint = request.request_fingerprint orelse {
        try issues.add(allocator, "request-fingerprint-required");
        return;
    };
    const contract_id = request.contract_id orelse {
        try issues.add(allocator, "contract-id-required");
        return;
    };
    const contract_ref = request.contract_ref orelse {
        try issues.add(allocator, "contract-ref-required");
        return;
    };
    const contract_digest = request.contract_digest orelse {
        try issues.add(allocator, "contract-digest-required");
        return;
    };
    const instructions_ref = request.instructions_ref orelse {
        try issues.add(allocator, "instructions-ref-required");
        return;
    };
    const instruction_digest = request.instruction_digest orelse {
        try issues.add(allocator, "instruction-digest-required");
        return;
    };
    if (!isNonblank(contract_id) or !isNonblank(contract_ref) or !isNonblank(instructions_ref)) try issues.add(allocator, "bound-request-reference");
    if (!isDigest(request_fingerprint) or !isDigest(contract_digest) or !isDigest(instruction_digest)) try issues.add(allocator, "bound-request-digest");
    if (!std.mem.eql(u8, request_fingerprint, instruction_digest)) try issues.add(allocator, "request-instruction-digest-mismatch");
    if (!verify_references) return;
    try verifyReferenceDigest(allocator, io, contract_ref, contract_digest, "contract-ref-unreadable", "contract-digest-mismatch", issues);
    try verifyReferenceDigest(allocator, io, instructions_ref, instruction_digest, "instructions-ref-unreadable", "instruction-digest-mismatch", issues);
}

fn validateAttempt(allocator: std.mem.Allocator, policy: Policy, request: Request, attempt: Attempt, issues: *Issues) !void {
    try validateAttemptEvidence(
        allocator,
        policy.artifact,
        request.request_id,
        request.request_fingerprint orelse "",
        attempt,
        issues,
    );
}

fn validateAttemptEvidence(
    allocator: std.mem.Allocator,
    artifact: Artifact,
    request_id: []const u8,
    request_fingerprint: []const u8,
    attempt: Attempt,
    issues: *Issues,
) !void {
    for ([_][]const u8{ attempt.review_attempt_id, attempt.review_thread_id, attempt.review_turn_id, attempt.principal_source, attempt.record_ref }) |value| {
        if (!isNonblank(value)) try issues.add(allocator, "attempt-identity");
    }
    if (!std.mem.eql(u8, attempt.workflow_binding.requestId, request_id) or
        !std.mem.eql(u8, attempt.workflow_binding.requestFingerprint, request_fingerprint))
    {
        try issues.add(allocator, "attempt-workflow-binding");
    }
    if (!std.mem.eql(u8, attempt.base_sha, artifact.base_sha) or
        !std.mem.eql(u8, attempt.head_sha, artifact.head_sha) or
        !std.mem.eql(u8, attempt.target_fingerprint, artifact.state_fingerprint))
    {
        try issues.add(allocator, "attempt-artifact-binding");
    }
    if (!attempt.context_identity_matches) try issues.add(allocator, "attempt-context-identity");
    if (!std.mem.eql(u8, attempt.principal_kind, "strong") or attempt.principal_reduced or attempt.fallback_used) {
        try issues.add(allocator, "attempt-source-quality");
    }
    if (!stringIn(attempt.verdict_status, &.{ "clean", "findings" })) try issues.add(allocator, "attempt-verdict");
    if (std.mem.eql(u8, attempt.verdict_status, "clean") and attempt.finding_count != 0) try issues.add(allocator, "clean-has-findings");
    if (std.mem.eql(u8, attempt.verdict_status, "findings") and attempt.finding_count == 0) try issues.add(allocator, "findings-empty");
}

fn validatePreflight(allocator: std.mem.Allocator, policy: Policy, is_v2: bool, issues: *Issues) !void {
    if (!is_v2 and policy.standard_clean_attempt_ids.len != 0) try issues.add(allocator, "preflight-standard-credit");
    if (policy.invalidation_reasons.len != 0) try issues.add(allocator, "preflight-invalidated");
    for (policy.requests) |request| {
        if (request.attempts.len != 0 or request.review_fold_refs.len != 0) try issues.add(allocator, "preflight-has-review-evidence");
        if (std.mem.eql(u8, request.role, "standard") and !std.mem.eql(u8, request.state, "selected-pending")) {
            try issues.add(allocator, "preflight-standard-state");
        }
        if (std.mem.eql(u8, request.role, "auxiliary") and !std.mem.eql(u8, request.state, "selected-pending")) {
            try issues.add(allocator, "preflight-auxiliary-state");
        }
    }
}

fn validateCloseout(allocator: std.mem.Allocator, policy: Policy, standard_index: usize, is_v2: bool, issues: *Issues) !void {
    if (policy.invalidation_reasons.len != 0) try issues.add(allocator, "closeout-invalidated");
    const standard = policy.requests[standard_index];
    if (!std.mem.eql(u8, standard.state, "clean")) try issues.add(allocator, "standard-not-clean");
    if (!is_v2) {
        const required = policy.standard_required_clean_runs;
        if (standard.attempts.len < required) {
            try issues.add(allocator, "standard-clean-suffix-short");
        } else {
            const suffix = standard.attempts[standard.attempts.len - required ..];
            for (suffix) |attempt| if (!std.mem.eql(u8, attempt.verdict_status, "clean")) try issues.add(allocator, "standard-clean-suffix-broken");
            if (policy.standard_clean_attempt_ids.len != required) {
                try issues.add(allocator, "standard-clean-attempt-projection");
            } else {
                for (suffix, policy.standard_clean_attempt_ids) |attempt, projected| {
                    if (!std.mem.eql(u8, attempt.review_attempt_id, projected)) try issues.add(allocator, "standard-clean-attempt-projection");
                }
            }
        }
    }

    for (policy.requests) |request| {
        if (!std.mem.eql(u8, request.role, "auxiliary")) continue;
        if (request.attempts.len == 0) {
            try issues.add(allocator, "auxiliary-evidence-required");
            continue;
        }
        const latest = request.attempts[request.attempts.len - 1];
        if (std.mem.eql(u8, request.state, "clean")) {
            if (!std.mem.eql(u8, latest.verdict_status, "clean")) try issues.add(allocator, "auxiliary-clean-state");
        } else if (std.mem.eql(u8, request.state, "findings-folded")) {
            if (!std.mem.eql(u8, latest.verdict_status, "findings") or request.review_fold_refs.len == 0) {
                try issues.add(allocator, "auxiliary-findings-fold");
            }
        } else {
            try issues.add(allocator, "auxiliary-closeout-open");
        }
    }
}

fn validateStandardCleanChain(
    allocator: std.mem.Allocator,
    policy: Policy,
    chain: StandardCleanChain,
    standard: Request,
    phase: Phase,
    issues: *Issues,
) !void {
    const review_contract_digest = policy.review_contract_digest orelse "";

    for (chain.standard_attempts, 0..) |evidence, index| {
        try validateArtifact(
            allocator,
            evidence.artifact,
            "standard-chain-artifact-identity",
            "standard-chain-artifact-fingerprint",
            issues,
        );
        for ([_][]const u8{
            evidence.goal_contract_digest,
            evidence.review_contract_digest,
            evidence.request_id,
            evidence.request_fingerprint,
            evidence.contract_id,
            evidence.contract_digest,
            evidence.instruction_digest,
        }) |value| {
            if (!isNonblank(value)) try issues.add(allocator, "standard-chain-attempt-identity");
        }
        if (!isDigest(evidence.goal_contract_digest) or
            !isDigest(evidence.review_contract_digest) or
            !isDigest(evidence.request_fingerprint) or
            !isDigest(evidence.contract_digest) or
            !isDigest(evidence.instruction_digest))
        {
            try issues.add(allocator, "standard-chain-attempt-digest");
        }
        if (evidence.resolution_digest) |digest| if (!isDigest(digest)) {
            try issues.add(allocator, "standard-chain-resolution-digest");
        };
        if (!std.mem.eql(u8, evidence.review_contract_digest, review_contract_digest)) {
            try issues.add(allocator, "standard-chain-review-contract");
        }
        if (!std.mem.eql(u8, evidence.request_fingerprint, evidence.instruction_digest)) {
            try issues.add(allocator, "standard-chain-request-instruction-digest");
        }
        try validateAttemptEvidence(
            allocator,
            evidence.artifact,
            evidence.request_id,
            evidence.request_fingerprint,
            evidence.attempt,
            issues,
        );
        for (chain.standard_attempts[0..index]) |prior| {
            if (std.mem.eql(u8, prior.attempt.review_attempt_id, evidence.attempt.review_attempt_id)) {
                try issues.add(allocator, "standard-chain-attempt-duplicate");
            }
        }
        for (policy.requests) |request| {
            if (!std.mem.eql(u8, request.role, "auxiliary")) continue;
            if (std.mem.eql(u8, request.request_id, evidence.request_id)) {
                try issues.add(allocator, "standard-chain-cross-lane-credit");
            }
            for (request.attempts) |attempt| {
                if (std.mem.eql(u8, attempt.review_attempt_id, evidence.attempt.review_attempt_id)) {
                    try issues.add(allocator, "standard-chain-cross-lane-credit");
                }
            }
        }
    }

    for (chain.carry_transitions, 0..) |carry, index| {
        try validateCarryIdentity(allocator, chain, standard, carry, index, issues);
        const from_index = findStandardAttempt(chain.standard_attempts, carry.from_attempt_id) orelse {
            try issues.add(allocator, "standard-chain-carry-source");
            continue;
        };
        const from = chain.standard_attempts[from_index];
        if (!std.mem.eql(u8, from.attempt.verdict_status, "clean")) {
            try issues.add(allocator, "standard-chain-carry-source-not-clean");
        }
        if (from_index + 1 < chain.standard_attempts.len) {
            const to = chain.standard_attempts[from_index + 1];
            if (artifactsEqual(from.artifact, to.artifact)) {
                try issues.add(allocator, "standard-chain-unexpected-carry");
            } else {
                try validateCarryConnection(allocator, from, to.artifact, to.goal_contract_digest, to.resolution_digest, to.contract_id, to.contract_digest, carry, issues);
            }
        } else if (phase == .preflight) {
            try validateCarryConnection(
                allocator,
                from,
                policy.artifact,
                policy.goal_contract_digest,
                policy.resolution_digest,
                standard.contract_id orelse "",
                standard.contract_digest orelse "",
                carry,
                issues,
            );
        } else {
            try issues.add(allocator, "standard-chain-dangling-carry");
        }
    }

    if (chain.standard_attempts.len > 1) {
        for (chain.standard_attempts[0 .. chain.standard_attempts.len - 1], chain.standard_attempts[1..]) |from, to| {
            const carry = findCarry(chain.carry_transitions, from.attempt.review_attempt_id);
            if (artifactsEqual(from.artifact, to.artifact)) {
                if (carry != null) try issues.add(allocator, "standard-chain-unexpected-carry");
                if (!sameStandardEpoch(from, to)) try issues.add(allocator, "standard-chain-epoch-drift");
            } else if (carry == null) {
                try issues.add(allocator, "standard-chain-missing-carry");
            }
        }
    }

    try validateCurrentStandardProjection(allocator, policy, chain, standard, phase, issues);
    try validateStandardCleanProjection(allocator, policy, chain, phase, issues);
}

fn validateCarryIdentity(
    allocator: std.mem.Allocator,
    chain: StandardCleanChain,
    standard: Request,
    carry: AuxiliaryRemediationCarry,
    carry_index: usize,
    issues: *Issues,
) !void {
    if (!std.mem.eql(u8, carry.kind, "auxiliary-remediation")) try issues.add(allocator, "standard-chain-carry-kind");
    for ([_][]const u8{
        carry.from_attempt_id,
        carry.from_goal_contract_digest,
        carry.to_goal_contract_digest,
        carry.resolution_digest,
        carry.ship_ref,
    }) |value| {
        if (!isNonblank(value)) try issues.add(allocator, "standard-chain-carry-identity");
    }
    if (!isDigest(carry.from_goal_contract_digest) or
        !isDigest(carry.to_goal_contract_digest) or
        !isDigest(carry.resolution_digest))
    {
        try issues.add(allocator, "standard-chain-carry-digest");
    }
    if (std.mem.eql(u8, carry.from_goal_contract_digest, carry.to_goal_contract_digest)) {
        try issues.add(allocator, "standard-chain-carry-goal-contract");
    }
    try validateArtifact(
        allocator,
        carry.to_artifact,
        "standard-chain-carry-artifact",
        "standard-chain-carry-artifact",
        issues,
    );
    try validateReferenceList(allocator, carry.source_auxiliary_request_ids, "standard-chain-carry-auxiliary-sources", issues);
    try validateReferenceList(allocator, carry.review_fold_refs, "standard-chain-carry-review-folds", issues);
    try validateReferenceList(allocator, carry.correctness_decision_refs, "standard-chain-carry-correctness", issues);
    try validateReferenceList(allocator, carry.preservation_observation_refs, "standard-chain-carry-preservation", issues);
    try validateReferenceList(allocator, carry.progress_observation_refs, "standard-chain-carry-progress", issues);
    try validateReferenceList(allocator, carry.actuation_event_refs, "standard-chain-carry-actuation", issues);
    for (chain.carry_transitions[0..carry_index]) |prior| {
        if (std.mem.eql(u8, prior.from_attempt_id, carry.from_attempt_id)) {
            try issues.add(allocator, "standard-chain-carry-duplicate");
        }
    }
    for (carry.source_auxiliary_request_ids) |request_id| {
        if (std.mem.eql(u8, request_id, standard.request_id)) {
            try issues.add(allocator, "standard-chain-carry-standard-source");
        }
        for (chain.standard_attempts) |attempt| {
            if (std.mem.eql(u8, request_id, attempt.request_id)) {
                try issues.add(allocator, "standard-chain-carry-standard-source");
            }
        }
    }
}

fn validateCarryConnection(
    allocator: std.mem.Allocator,
    from: StandardAttemptEvidence,
    to_artifact: Artifact,
    to_goal_contract_digest: []const u8,
    to_resolution_digest: ?[]const u8,
    to_contract_id: []const u8,
    to_contract_digest: []const u8,
    carry: AuxiliaryRemediationCarry,
    issues: *Issues,
) !void {
    if (!artifactsEqual(carry.to_artifact, to_artifact) or !sameArtifactBase(from.artifact, to_artifact)) {
        try issues.add(allocator, "standard-chain-carry-artifact");
    }
    if (std.mem.eql(u8, from.artifact.head_sha, to_artifact.head_sha) or
        std.mem.eql(u8, from.artifact.state_fingerprint, to_artifact.state_fingerprint))
    {
        try issues.add(allocator, "standard-chain-carry-no-artifact-change");
    }
    if (!std.mem.eql(u8, carry.from_goal_contract_digest, from.goal_contract_digest) or
        !std.mem.eql(u8, carry.to_goal_contract_digest, to_goal_contract_digest))
    {
        try issues.add(allocator, "standard-chain-carry-goal-contract");
    }
    const resolution_digest = to_resolution_digest orelse {
        try issues.add(allocator, "standard-chain-carry-resolution");
        return;
    };
    if (!std.mem.eql(u8, carry.resolution_digest, resolution_digest)) {
        try issues.add(allocator, "standard-chain-carry-resolution");
    }
    if (!std.mem.eql(u8, from.contract_id, to_contract_id) or
        !std.mem.eql(u8, from.contract_digest, to_contract_digest))
    {
        try issues.add(allocator, "standard-chain-carry-contract-drift");
    }
}

fn validateCurrentStandardProjection(
    allocator: std.mem.Allocator,
    policy: Policy,
    chain: StandardCleanChain,
    standard: Request,
    phase: Phase,
    issues: *Issues,
) !void {
    var current_index: usize = 0;
    for (chain.standard_attempts) |evidence| {
        if (!artifactsEqual(evidence.artifact, policy.artifact)) continue;
        if (!std.mem.eql(u8, evidence.goal_contract_digest, policy.goal_contract_digest) or
            !optionalStringsEqual(evidence.resolution_digest, policy.resolution_digest) or
            !std.mem.eql(u8, evidence.request_id, standard.request_id) or
            !std.mem.eql(u8, evidence.request_fingerprint, standard.request_fingerprint orelse "") or
            !std.mem.eql(u8, evidence.contract_id, standard.contract_id orelse "") or
            !std.mem.eql(u8, evidence.contract_digest, standard.contract_digest orelse "") or
            !std.mem.eql(u8, evidence.instruction_digest, standard.instruction_digest orelse ""))
        {
            try issues.add(allocator, "standard-chain-current-request");
            continue;
        }
        if (current_index >= standard.attempts.len or !attemptsEqual(evidence.attempt, standard.attempts[current_index])) {
            try issues.add(allocator, "standard-chain-current-projection");
        }
        current_index += 1;
    }
    if (current_index != standard.attempts.len) try issues.add(allocator, "standard-chain-current-projection");

    if (phase == .preflight) {
        if (current_index != 0) try issues.add(allocator, "standard-chain-preflight-current-evidence");
        if (chain.standard_attempts.len != 0) {
            const last = chain.standard_attempts[chain.standard_attempts.len - 1];
            const carry = findCarry(chain.carry_transitions, last.attempt.review_attempt_id);
            if (carry == null or artifactsEqual(last.artifact, policy.artifact)) {
                try issues.add(allocator, "standard-chain-preflight-carry-required");
            }
        } else if (chain.carry_transitions.len != 0) {
            try issues.add(allocator, "standard-chain-unexpected-carry");
        }
    } else {
        if (current_index == 0 or chain.standard_attempts.len == 0 or
            !artifactsEqual(chain.standard_attempts[chain.standard_attempts.len - 1].artifact, policy.artifact))
        {
            try issues.add(allocator, "standard-chain-current-clean-required");
        }
    }
}

fn validateStandardCleanProjection(
    allocator: std.mem.Allocator,
    policy: Policy,
    chain: StandardCleanChain,
    phase: Phase,
    issues: *Issues,
) !void {
    var suffix_start = chain.standard_attempts.len;
    while (suffix_start > 0 and std.mem.eql(u8, chain.standard_attempts[suffix_start - 1].attempt.verdict_status, "clean")) {
        suffix_start -= 1;
    }
    const suffix_len = chain.standard_attempts.len - suffix_start;
    const projected_len = @min(suffix_len, policy.standard_required_clean_runs);
    if (policy.standard_clean_attempt_ids.len != projected_len) {
        try issues.add(allocator, "standard-clean-attempt-projection");
    } else {
        const projection_start = chain.standard_attempts.len - projected_len;
        for (chain.standard_attempts[projection_start..], policy.standard_clean_attempt_ids) |evidence, projected| {
            if (!std.mem.eql(u8, evidence.attempt.review_attempt_id, projected)) {
                try issues.add(allocator, "standard-clean-attempt-projection");
            }
        }
    }
    if (phase == .closeout and suffix_len < policy.standard_required_clean_runs) {
        try issues.add(allocator, "standard-clean-suffix-short");
    }
}

fn validateArtifact(
    allocator: std.mem.Allocator,
    artifact: Artifact,
    identity_issue: []const u8,
    fingerprint_issue: []const u8,
    issues: *Issues,
) !void {
    for ([_][]const u8{ artifact.repo, artifact.base_ref, artifact.base_sha, artifact.head_sha }) |value| {
        if (!isNonblank(value)) try issues.add(allocator, identity_issue);
    }
    if (!isDigest(artifact.state_fingerprint)) try issues.add(allocator, fingerprint_issue);
}

fn validateReferenceList(allocator: std.mem.Allocator, refs: []const []const u8, issue: []const u8, issues: *Issues) !void {
    if (refs.len == 0) {
        try issues.add(allocator, issue);
        return;
    }
    for (refs, 0..) |ref, index| {
        if (!isNonblank(ref) or containsString(refs[0..index], ref)) try issues.add(allocator, issue);
    }
}

fn artifactsEqual(lhs: Artifact, rhs: Artifact) bool {
    return std.mem.eql(u8, lhs.repo, rhs.repo) and
        std.mem.eql(u8, lhs.base_ref, rhs.base_ref) and
        std.mem.eql(u8, lhs.base_sha, rhs.base_sha) and
        std.mem.eql(u8, lhs.head_sha, rhs.head_sha) and
        std.mem.eql(u8, lhs.state_fingerprint, rhs.state_fingerprint);
}

fn sameArtifactBase(lhs: Artifact, rhs: Artifact) bool {
    return std.mem.eql(u8, lhs.repo, rhs.repo) and
        std.mem.eql(u8, lhs.base_ref, rhs.base_ref) and
        std.mem.eql(u8, lhs.base_sha, rhs.base_sha);
}

fn sameStandardEpoch(lhs: StandardAttemptEvidence, rhs: StandardAttemptEvidence) bool {
    return std.mem.eql(u8, lhs.goal_contract_digest, rhs.goal_contract_digest) and
        optionalStringsEqual(lhs.resolution_digest, rhs.resolution_digest) and
        std.mem.eql(u8, lhs.review_contract_digest, rhs.review_contract_digest) and
        std.mem.eql(u8, lhs.request_id, rhs.request_id) and
        std.mem.eql(u8, lhs.request_fingerprint, rhs.request_fingerprint) and
        std.mem.eql(u8, lhs.contract_id, rhs.contract_id) and
        std.mem.eql(u8, lhs.contract_digest, rhs.contract_digest) and
        std.mem.eql(u8, lhs.instruction_digest, rhs.instruction_digest);
}

fn optionalStringsEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn attemptsEqual(lhs: Attempt, rhs: Attempt) bool {
    return std.mem.eql(u8, lhs.workflow_binding.requestId, rhs.workflow_binding.requestId) and
        std.mem.eql(u8, lhs.workflow_binding.requestFingerprint, rhs.workflow_binding.requestFingerprint) and
        std.mem.eql(u8, lhs.review_attempt_id, rhs.review_attempt_id) and
        std.mem.eql(u8, lhs.review_thread_id, rhs.review_thread_id) and
        std.mem.eql(u8, lhs.review_turn_id, rhs.review_turn_id) and
        std.mem.eql(u8, lhs.base_sha, rhs.base_sha) and
        std.mem.eql(u8, lhs.head_sha, rhs.head_sha) and
        std.mem.eql(u8, lhs.target_fingerprint, rhs.target_fingerprint) and
        lhs.context_identity_matches == rhs.context_identity_matches and
        std.mem.eql(u8, lhs.principal_kind, rhs.principal_kind) and
        lhs.principal_reduced == rhs.principal_reduced and
        lhs.fallback_used == rhs.fallback_used and
        std.mem.eql(u8, lhs.principal_source, rhs.principal_source) and
        std.mem.eql(u8, lhs.verdict_status, rhs.verdict_status) and
        lhs.finding_count == rhs.finding_count and
        std.mem.eql(u8, lhs.record_ref, rhs.record_ref);
}

fn findStandardAttempt(attempts: []const StandardAttemptEvidence, attempt_id: []const u8) ?usize {
    for (attempts, 0..) |attempt, index| {
        if (std.mem.eql(u8, attempt.attempt.review_attempt_id, attempt_id)) return index;
    }
    return null;
}

fn findCarry(carries: []const AuxiliaryRemediationCarry, from_attempt_id: []const u8) ?AuxiliaryRemediationCarry {
    for (carries) |carry| {
        if (std.mem.eql(u8, carry.from_attempt_id, from_attempt_id)) return carry;
    }
    return null;
}

fn verifyReferenceDigest(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    expected: []const u8,
    unreadable_issue: []const u8,
    mismatch_issue: []const u8,
    issues: *Issues,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MaxReferenceBytes)) catch {
        try issues.add(allocator, unreadable_issue);
        return;
    };
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (expected.len != "sha256:".len + hex.len or !std.mem.eql(u8, expected["sha256:".len..], &hex)) {
        try issues.add(allocator, mismatch_issue);
    }
}

fn hasBoundRequest(request: Request) bool {
    return request.request_fingerprint != null or request.contract_id != null or request.contract_ref != null or
        request.contract_digest != null or request.instructions_ref != null or request.instruction_digest != null;
}

fn optionalNonblank(value: ?[]const u8) bool {
    return if (value) |text| isNonblank(text) else false;
}

fn isNonblank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

fn isDigest(value: []const u8) bool {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return false;
    for (value["sha256:".len..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn stringIn(value: []const u8, expected: []const []const u8) bool {
    return containsString(expected, value);
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn containsRequestIdentity(requests: []const Request, request: Request) bool {
    for (requests) |prior| {
        if (std.mem.eql(u8, prior.request_id, request.request_id) or std.mem.eql(u8, prior.lens, request.lens)) return true;
        if (prior.request_fingerprint != null and request.request_fingerprint != null and
            std.mem.eql(u8, prior.request_fingerprint.?, request.request_fingerprint.?)) return true;
    }
    return false;
}

fn countRequestsWithLens(requests: []const Request, lens: []const u8) usize {
    var count: usize = 0;
    for (requests) |request| if (std.mem.eql(u8, request.lens, lens)) {
        count += 1;
    };
    return count;
}

fn attemptIdentitySeen(requests: []const Request, request_index: usize, attempt_index: usize, attempt_id: []const u8) bool {
    for (requests, 0..) |request, candidate_request_index| {
        for (request.attempts, 0..) |attempt, candidate_attempt_index| {
            if (candidate_request_index > request_index or
                (candidate_request_index == request_index and candidate_attempt_index >= attempt_index)) return false;
            if (std.mem.eql(u8, attempt.review_attempt_id, attempt_id)) return true;
        }
    }
    return false;
}

fn lessString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

const digest_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const digest_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const digest_c = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const digest_d = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const digest_e = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const digest_f = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

const current_artifact = Artifact{ .repo = "/repo", .base_ref = "main", .base_sha = "base", .head_sha = "head", .state_fingerprint = digest_b };
const prior_artifact = Artifact{ .repo = "/repo", .base_ref = "main", .base_sha = "base", .head_sha = "prior-head", .state_fingerprint = digest_c };

fn makeAttemptFor(
    id: []const u8,
    request_id: []const u8,
    fingerprint: []const u8,
    artifact: Artifact,
    verdict: []const u8,
    findings: usize,
) Attempt {
    return .{
        .workflow_binding = .{ .requestId = request_id, .requestFingerprint = fingerprint },
        .review_attempt_id = id,
        .review_thread_id = id,
        .review_turn_id = id,
        .base_sha = artifact.base_sha,
        .head_sha = artifact.head_sha,
        .target_fingerprint = artifact.state_fingerprint,
        .context_identity_matches = true,
        .principal_kind = "strong",
        .principal_reduced = false,
        .fallback_used = false,
        .principal_source = "cas-lane",
        .verdict_status = verdict,
        .finding_count = findings,
        .record_ref = "cas:record",
    };
}

fn makeAttempt(id: []const u8, fingerprint: []const u8, verdict: []const u8, findings: usize) Attempt {
    return makeAttemptFor(
        id,
        if (std.mem.eql(u8, fingerprint, digest_a)) "standard-request" else if (std.mem.eql(u8, fingerprint, digest_e)) "footgun-request" else if (std.mem.eql(u8, fingerprint, digest_c)) "invariant-request" else if (std.mem.eql(u8, fingerprint, digest_f)) "fresh-eyes-request" else "complexity-request",
        fingerprint,
        current_artifact,
        verdict,
        findings,
    );
}

fn makeStandardEvidence(
    artifact: Artifact,
    goal_contract_digest: []const u8,
    resolution_digest: ?[]const u8,
    request_id: []const u8,
    request_fingerprint: []const u8,
    attempt: Attempt,
) StandardAttemptEvidence {
    return .{
        .artifact = artifact,
        .goal_contract_digest = goal_contract_digest,
        .resolution_digest = resolution_digest,
        .review_contract_digest = digest_f,
        .request_id = request_id,
        .request_fingerprint = request_fingerprint,
        .contract_id = "standard-review-v1",
        .contract_digest = digest_a,
        .instruction_digest = request_fingerprint,
        .attempt = attempt,
    };
}

const standard_attempts = [_]Attempt{
    makeAttempt("standard-1", digest_a, "clean", 0),
    makeAttempt("standard-2", digest_a, "clean", 0),
    makeAttempt("standard-3", digest_a, "clean", 0),
    makeAttempt("standard-4", digest_a, "clean", 0),
    makeAttempt("standard-5", digest_a, "clean", 0),
};
const prior_standard_attempts = [_]Attempt{
    makeAttemptFor("standard-prior-1", "standard-request-prior", digest_e, prior_artifact, "clean", 0),
    makeAttemptFor("standard-prior-2", "standard-request-prior", digest_e, prior_artifact, "clean", 0),
};
const v2_standard_history = [_]StandardAttemptEvidence{
    makeStandardEvidence(prior_artifact, digest_d, null, "standard-request-prior", digest_e, prior_standard_attempts[0]),
    makeStandardEvidence(prior_artifact, digest_d, null, "standard-request-prior", digest_e, prior_standard_attempts[1]),
    makeStandardEvidence(current_artifact, digest_a, digest_c, "standard-request", digest_a, standard_attempts[2]),
    makeStandardEvidence(current_artifact, digest_a, digest_c, "standard-request", digest_a, standard_attempts[3]),
    makeStandardEvidence(current_artifact, digest_a, digest_c, "standard-request", digest_a, standard_attempts[4]),
};
const carry_source_ids = [_][]const u8{"complexity-request-prior"};
const carry_fold_refs = [_][]const u8{"rf:complexity-prior"};
const carry_decision_refs = [_][]const u8{"resolution:complexity-prior"};
const carry_preservation_refs = [_][]const u8{"actuation:observe:preservation"};
const carry_progress_refs = [_][]const u8{"actuation:observe:progress"};
const carry_event_refs = [_][]const u8{"actuation:event:repair"};
const v2_carries = [_]AuxiliaryRemediationCarry{.{
    .kind = "auxiliary-remediation",
    .from_attempt_id = "standard-prior-2",
    .to_artifact = current_artifact,
    .from_goal_contract_digest = digest_d,
    .to_goal_contract_digest = digest_a,
    .resolution_digest = digest_c,
    .source_auxiliary_request_ids = &carry_source_ids,
    .review_fold_refs = &carry_fold_refs,
    .correctness_decision_refs = &carry_decision_refs,
    .preservation_observation_refs = &carry_preservation_refs,
    .progress_observation_refs = &carry_progress_refs,
    .actuation_event_refs = &carry_event_refs,
    .ship_ref = "ship:repair",
}};
const footgun_attempts = [_]Attempt{makeAttempt("footgun-1", digest_e, "clean", 0)};
const invariant_attempts = [_]Attempt{makeAttempt("invariant-1", digest_c, "clean", 0)};
const complexity_attempts = [_]Attempt{makeAttempt("complexity-1", digest_d, "findings", 1)};
const fresh_eyes_attempts = [_]Attempt{makeAttempt("fresh-eyes-1", digest_f, "clean", 0)};
const required_lenses = [_][]const u8{ "standard", "footgun-finder", "invariant-ace", "complexity-mitigator", "fresh-eyes" };
const standard_ids = [_][]const u8{ "standard-1", "standard-2", "standard-3", "standard-4", "standard-5" };
const v2_standard_ids = [_][]const u8{ "standard-prior-1", "standard-prior-2", "standard-3", "standard-4", "standard-5" };
const v2_prior_ids = [_][]const u8{ "standard-prior-1", "standard-prior-2" };
const fold_refs = [_][]const u8{"rf:complexity-1"};
const closeout_requests = [_]Request{
    .{ .request_id = "standard-request", .request_fingerprint = digest_a, .lens = "standard", .role = "standard", .selection_reason = "closure-grade", .contract_id = "standard-review-v1", .contract_ref = "/dev/null", .contract_digest = digest_a, .instructions_ref = "/dev/null", .instruction_digest = digest_a, .state = "clean", .attempts = &standard_attempts, .review_fold_refs = &.{} },
    .{ .request_id = "footgun-request", .request_fingerprint = digest_e, .lens = "footgun-finder", .role = "auxiliary", .selection_reason = "required auxiliary lane", .contract_id = "footgun-lens-v1", .contract_ref = "/dev/null", .contract_digest = digest_e, .instructions_ref = "/dev/null", .instruction_digest = digest_e, .state = "clean", .attempts = &footgun_attempts, .review_fold_refs = &.{} },
    .{ .request_id = "invariant-request", .request_fingerprint = digest_c, .lens = "invariant-ace", .role = "auxiliary", .selection_reason = "authority boundary changed", .contract_id = "invariant-gate-v1", .contract_ref = "/dev/null", .contract_digest = digest_c, .instructions_ref = "/dev/null", .instruction_digest = digest_c, .state = "clean", .attempts = &invariant_attempts, .review_fold_refs = &.{} },
    .{ .request_id = "complexity-request", .request_fingerprint = digest_d, .lens = "complexity-mitigator", .role = "auxiliary", .selection_reason = "cross-file state", .contract_id = "complexity-preflight-v1", .contract_ref = "/dev/null", .contract_digest = digest_d, .instructions_ref = "/dev/null", .instruction_digest = digest_d, .state = "findings-folded", .attempts = &complexity_attempts, .review_fold_refs = &fold_refs },
    .{ .request_id = "fresh-eyes-request", .request_fingerprint = digest_f, .lens = "fresh-eyes", .role = "auxiliary", .selection_reason = "required whole-target reinspection", .contract_id = "fresh-eyes-lens-v1", .contract_ref = "/dev/null", .contract_digest = digest_f, .instructions_ref = "/dev/null", .instruction_digest = digest_f, .state = "clean", .attempts = &fresh_eyes_attempts, .review_fold_refs = &.{} },
};

fn validCloseoutPolicy(requests: []const Request) Policy {
    return .{
        .version = "actuation-review-policy/v1",
        .policy_id = "policy-1",
        .run_id = "run-1",
        .goal_contract_digest = digest_a,
        .resolution_digest = digest_c,
        .artifact = .{ .repo = "/repo", .base_ref = "main", .base_sha = "base", .head_sha = "head", .state_fingerprint = digest_b },
        .standard_required_clean_runs = MinimumStandardCleanRuns,
        .required_lenses = &required_lenses,
        .requests = requests,
        .standard_clean_attempt_ids = &standard_ids,
        .invalidation_reasons = &.{},
    };
}

fn validV2CloseoutPolicy(requests: []const Request) Policy {
    return .{
        .version = "actuation-review-policy/v2",
        .policy_id = "policy-1",
        .run_id = "run-current",
        .goal_contract_digest = digest_a,
        .resolution_digest = digest_c,
        .artifact = current_artifact,
        .standard_required_clean_runs = MinimumStandardCleanRuns,
        .required_lenses = &required_lenses,
        .requests = requests,
        .standard_clean_attempt_ids = &v2_standard_ids,
        .invalidation_reasons = &.{},
        .review_contract_ref = "/dev/null",
        .review_contract_digest = digest_f,
        .standard_clean_chain = .{
            .standard_attempts = &v2_standard_history,
            .carry_transitions = &v2_carries,
        },
    };
}

fn validV2PreflightPolicy(requests: []const Request) Policy {
    var policy = validV2CloseoutPolicy(requests);
    policy.standard_clean_attempt_ids = &v2_prior_ids;
    policy.standard_clean_chain = .{
        .standard_attempts = v2_standard_history[0..2],
        .carry_transitions = &v2_carries,
    };
    return policy;
}

fn validateForTest(policy: Policy, phase: Phase) !Issues {
    var issues = Issues{};
    errdefer issues.deinit(std.testing.allocator);
    try validatePolicy(std.testing.allocator, std.testing.io, policy, phase, false, &issues);
    return issues;
}

fn hasIssue(issues: Issues, expected: []const u8) bool {
    return containsString(issues.values.items, expected);
}

test "closeout accepts generic registry coverage and disjoint lane accounting" {
    var issues = try validateForTest(validCloseoutPolicy(&closeout_requests), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "preflight accepts selected rows without review evidence" {
    var requests = closeout_requests;
    for (&requests) |*request| {
        request.state = "selected-pending";
        request.attempts = &.{};
        request.review_fold_refs = &.{};
    }
    var policy = validCloseoutPolicy(&requests);
    policy.standard_clean_attempt_ids = &.{};
    var issues = try validateForTest(policy, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "v2 preflight preserves prior standard clean credit through one certified auxiliary carry" {
    var requests = closeout_requests;
    for (&requests) |*request| {
        request.state = "selected-pending";
        request.attempts = &.{};
        request.review_fold_refs = &.{};
    }
    var issues = try validateForTest(validV2PreflightPolicy(&requests), .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "v2 closeout composes two prior and three current standard cleans" {
    var requests = closeout_requests;
    requests[0].attempts = standard_attempts[2..];
    var issues = try validateForTest(validV2CloseoutPolicy(&requests), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "v2 chain survives strict JSON round trip" {
    var requests = closeout_requests;
    requests[0].attempts = standard_attempts[2..];
    const envelope = Envelope{ .actuation_review_policy = validV2CloseoutPolicy(&requests) };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(envelope, .{}, &out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Envelope, std.testing.allocator, bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("actuation-review-policy/v2", parsed.value.actuation_review_policy.version);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.actuation_review_policy.standard_clean_chain.?.standard_attempts.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.actuation_review_policy.standard_clean_chain.?.carry_transitions.len);
}

test "v2 closeout composes multiple certified auxiliary carries" {
    const middle_artifact = Artifact{ .repo = "/repo", .base_ref = "main", .base_sha = "base", .head_sha = "middle-head", .state_fingerprint = digest_d };
    const prior_attempts = [_]Attempt{makeAttemptFor("multi-prior-1", "standard-request-prior", digest_e, prior_artifact, "clean", 0)};
    const middle_attempts = [_]Attempt{
        makeAttemptFor("multi-middle-1", "standard-request-middle", digest_d, middle_artifact, "clean", 0),
        makeAttemptFor("multi-middle-2", "standard-request-middle", digest_d, middle_artifact, "clean", 0),
    };
    const current_attempts = [_]Attempt{
        makeAttemptFor("multi-current-1", "standard-request", digest_a, current_artifact, "clean", 0),
        makeAttemptFor("multi-current-2", "standard-request", digest_a, current_artifact, "clean", 0),
    };
    const history = [_]StandardAttemptEvidence{
        makeStandardEvidence(prior_artifact, digest_c, null, "standard-request-prior", digest_e, prior_attempts[0]),
        makeStandardEvidence(middle_artifact, digest_e, digest_b, "standard-request-middle", digest_d, middle_attempts[0]),
        makeStandardEvidence(middle_artifact, digest_e, digest_b, "standard-request-middle", digest_d, middle_attempts[1]),
        makeStandardEvidence(current_artifact, digest_a, digest_c, "standard-request", digest_a, current_attempts[0]),
        makeStandardEvidence(current_artifact, digest_a, digest_c, "standard-request", digest_a, current_attempts[1]),
    };
    const carries = [_]AuxiliaryRemediationCarry{
        .{
            .kind = "auxiliary-remediation",
            .from_attempt_id = "multi-prior-1",
            .to_artifact = middle_artifact,
            .from_goal_contract_digest = digest_c,
            .to_goal_contract_digest = digest_e,
            .resolution_digest = digest_b,
            .source_auxiliary_request_ids = &carry_source_ids,
            .review_fold_refs = &carry_fold_refs,
            .correctness_decision_refs = &carry_decision_refs,
            .preservation_observation_refs = &carry_preservation_refs,
            .progress_observation_refs = &carry_progress_refs,
            .actuation_event_refs = &carry_event_refs,
            .ship_ref = "ship:middle-repair",
        },
        .{
            .kind = "auxiliary-remediation",
            .from_attempt_id = "multi-middle-2",
            .to_artifact = current_artifact,
            .from_goal_contract_digest = digest_e,
            .to_goal_contract_digest = digest_a,
            .resolution_digest = digest_c,
            .source_auxiliary_request_ids = &carry_source_ids,
            .review_fold_refs = &carry_fold_refs,
            .correctness_decision_refs = &carry_decision_refs,
            .preservation_observation_refs = &carry_preservation_refs,
            .progress_observation_refs = &carry_progress_refs,
            .actuation_event_refs = &carry_event_refs,
            .ship_ref = "ship:current-repair",
        },
    };
    const ids = [_][]const u8{ "multi-prior-1", "multi-middle-1", "multi-middle-2", "multi-current-1", "multi-current-2" };
    var requests = closeout_requests;
    requests[0].attempts = &current_attempts;
    var policy = validV2CloseoutPolicy(&requests);
    policy.standard_clean_attempt_ids = &ids;
    policy.standard_clean_chain = .{ .standard_attempts = &history, .carry_transitions = &carries };
    var issues = try validateForTest(policy, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "v2 auxiliary carry preserves but never increments standard credit" {
    var requests = closeout_requests;
    for (&requests) |*request| {
        request.state = "selected-pending";
        request.attempts = &.{};
        request.review_fold_refs = &.{};
    }
    var policy = validV2PreflightPolicy(&requests);
    const inflated_ids = [_][]const u8{ "standard-prior-1", "standard-prior-2", "carry-is-not-credit" };
    policy.standard_clean_attempt_ids = &inflated_ids;
    var issues = try validateForTest(policy, .preflight);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "standard-clean-attempt-projection"));
}

test "v2 tuple movement without an auxiliary carry is invalid proof" {
    var requests = closeout_requests;
    requests[0].attempts = standard_attempts[2..];
    var policy = validV2CloseoutPolicy(&requests);
    var chain = policy.standard_clean_chain.?;
    chain.carry_transitions = &.{};
    policy.standard_clean_chain = chain;
    var issues = try validateForTest(policy, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "standard-chain-missing-carry"));
}

test "v2 standard findings reset instead of crossing an auxiliary carry" {
    var requests = closeout_requests;
    requests[0].attempts = standard_attempts[2..];
    var history = v2_standard_history;
    history[1].attempt.verdict_status = "findings";
    history[1].attempt.finding_count = 1;
    var policy = validV2CloseoutPolicy(&requests);
    var chain = policy.standard_clean_chain.?;
    chain.standard_attempts = &history;
    policy.standard_clean_chain = chain;
    var issues = try validateForTest(policy, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "standard-chain-carry-source-not-clean"));
    try std.testing.expect(hasIssue(issues, "standard-clean-suffix-short"));
}

test "v2 closeout requires a clean standard attempt on the current tuple" {
    var requests = closeout_requests;
    for (&requests) |*request| {
        request.state = "selected-pending";
        request.attempts = &.{};
        request.review_fold_refs = &.{};
    }
    var issues = try validateForTest(validV2PreflightPolicy(&requests), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "standard-chain-dangling-carry"));
    try std.testing.expect(hasIssue(issues, "standard-chain-current-clean-required"));
}

test "v2 review contract drift cannot inherit prior credit" {
    var requests = closeout_requests;
    requests[0].attempts = standard_attempts[2..];
    var history = v2_standard_history;
    history[0].review_contract_digest = digest_d;
    var policy = validV2CloseoutPolicy(&requests);
    var chain = policy.standard_clean_chain.?;
    chain.standard_attempts = &history;
    policy.standard_clean_chain = chain;
    var issues = try validateForTest(policy, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "standard-chain-review-contract"));
}

test "v1 rejects v2 chain fields instead of changing semantics in place" {
    var policy = validCloseoutPolicy(&closeout_requests);
    policy.review_contract_ref = "/dev/null";
    policy.review_contract_digest = digest_f;
    policy.standard_clean_chain = .{ .standard_attempts = &.{}, .carry_transitions = &.{} };
    var issues = try validateForTest(policy, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "v1-standard-clean-chain"));
}

test "policy requires at least five standard clean runs" {
    var policy = validCloseoutPolicy(&closeout_requests);
    policy.standard_required_clean_runs = MinimumStandardCleanRuns - 1;
    var issues = try validateForTest(policy, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "standard-clean-runs-below-policy-minimum"));
}

test "every auxiliary lens is mandatory" {
    var requests = closeout_requests;
    requests[4].state = "not-required";
    var issues = try validateForTest(validCloseoutPolicy(&requests), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "request-state"));
    try std.testing.expect(hasIssue(issues, "auxiliary-request-required"));
}

test "duplicate attempts cannot manufacture a clean suffix" {
    var attempts = standard_attempts;
    attempts[1].review_attempt_id = attempts[0].review_attempt_id;
    var requests = closeout_requests;
    requests[0].attempts = &attempts;
    var issues = try validateForTest(validCloseoutPolicy(&requests), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "review-attempt-duplicate"));
}

test "stale tuple evidence cannot receive closeout credit" {
    var attempts = standard_attempts;
    attempts[2].head_sha = "stale-head";
    var requests = closeout_requests;
    requests[0].attempts = &attempts;
    var issues = try validateForTest(validCloseoutPolicy(&requests), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "attempt-artifact-binding"));
}

test "auxiliary attempt identity cannot count as standard credit" {
    var projected = standard_ids;
    projected[0] = "invariant-1";
    var policy = validCloseoutPolicy(&closeout_requests);
    policy.standard_clean_attempt_ids = &projected;
    var issues = try validateForTest(policy, .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "standard-clean-attempt-projection"));
}

test "the declared registry and request rows must be bijective" {
    var requests = closeout_requests;
    requests[4].lens = "invariant-ace";
    var issues = try validateForTest(validCloseoutPolicy(&requests), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "registry-request-coverage"));
    try std.testing.expect(hasIssue(issues, "request-identity-duplicate"));
}

test "request identity is the exact instruction digest" {
    var requests = closeout_requests;
    requests[0].request_fingerprint = digest_b;
    var issues = try validateForTest(validCloseoutPolicy(&requests), .closeout);
    defer issues.deinit(std.testing.allocator);
    try std.testing.expect(hasIssue(issues, "request-instruction-digest-mismatch"));
}

test "sha256 comparison binds exact referenced bytes" {
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    const empty_digest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try verifyReferenceDigest(std.testing.allocator, std.testing.io, "/dev/null", empty_digest, "unreadable", "mismatch", &issues);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
    try verifyReferenceDigest(std.testing.allocator, std.testing.io, "/dev/null", digest_a, "unreadable", "mismatch", &issues);
    try std.testing.expect(hasIssue(issues, "mismatch"));
}
