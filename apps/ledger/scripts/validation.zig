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
    \\usage: ledger validate CONTRACT --input FILE|-
    \\
    \\Purely validate one governance or review artifact. This command never reads or writes .ledger and never grants authority.
    \\
    \\contracts:
    \\  plan-source-contract       Validate a PSC-v1 plan source contract
    \\  policy-synthesis-receipt  Validate a PSR-v1 policy synthesis receipt
    \\  source-memory-checkpoint  Validate a source-memory-checkpoint/v1 receipt
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
    source_memory_checkpoint,

    fn parse(raw: []const u8) ?Contract {
        if (std.mem.eql(u8, raw, "plan-source-contract")) return .plan_source_contract;
        if (std.mem.eql(u8, raw, "policy-synthesis-receipt")) return .policy_synthesis_receipt;
        if (std.mem.eql(u8, raw, "source-memory-checkpoint")) return .source_memory_checkpoint;
        return null;
    }

    fn name(self: Contract) []const u8 {
        return switch (self) {
            .plan_source_contract => "plan-source-contract",
            .policy_synthesis_receipt => "policy-synthesis-receipt",
            .source_memory_checkpoint => "source-memory-checkpoint",
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
    const input = try readInputAlloc(allocator, args.contract, args.input_path);
    defer allocator.free(input);

    var issues = Issues{};
    defer issues.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        try issues.add(allocator, "malformed-json");
        try emitDecision(allocator, args.contract, &issues);
        return 2;
    };
    defer parsed.deinit();

    try validateContract(allocator, args.contract, parsed.value, &issues);

    try emitDecision(allocator, args.contract, &issues);
    return if (issues.values.items.len == 0) 0 else 2;
}

fn validateContract(allocator: std.mem.Allocator, contract: Contract, value: std.json.Value, issues: *Issues) !void {
    switch (contract) {
        .plan_source_contract => try validatePlanSourceContract(allocator, value, issues),
        .policy_synthesis_receipt => try validatePolicySynthesisReceipt(allocator, value, issues),
        .source_memory_checkpoint => try validateSourceMemoryCheckpoint(allocator, value, issues),
    }
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

fn inputLimitForContract(contract: Contract) usize {
    _ = contract;
    return MaxInputBytes;
}

fn readInputAlloc(allocator: std.mem.Allocator, contract: Contract, path: []const u8) ![]u8 {
    const limit = inputLimitForContract(contract);
    if (std.mem.eql(u8, path, "-")) {
        var reader = std.Io.File.stdin().reader(defaultIo(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(limit));
    }
    return std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(limit));
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

const CheckpointParticipant = enum {
    learnings,
    synesthesia,
    negative_ledger,
};

const ParticipantValidation = struct {
    canonical_blocked: bool = false,
    admission_blocked: bool = false,
};

fn validateSourceMemoryCheckpoint(allocator: std.mem.Allocator, root: std.json.Value, issues: *Issues) !void {
    const root_object = asObject(root) orelse {
        try issues.add(allocator, "input-object-required");
        return;
    };
    const receipt_value = root_object.get("source_memory_checkpoint") orelse root;
    const receipt = asObject(receipt_value) orelse {
        try issues.add(allocator, "source-memory-checkpoint-object-required");
        return;
    };

    if (!fieldEqualsString(receipt, "schema", "source-memory-checkpoint/v1")) try issues.add(allocator, "checkpoint-schema");
    const checkpoint_id = nonblankString(receipt.get("checkpoint_id")) orelse "";
    if (!std.mem.startsWith(u8, checkpoint_id, "SMC-")) try issues.add(allocator, "checkpoint-id");
    if (!isNonblankString(receipt.get("trigger"))) try issues.add(allocator, "checkpoint-trigger");
    if (!validSha256Fingerprint(receipt.get("subject_fingerprint"))) try issues.add(allocator, "subject-fingerprint");
    if (!validSha256Fingerprint(receipt.get("evidence_fingerprint"))) try issues.add(allocator, "evidence-fingerprint");

    const participants = asObjectValue(receipt.get("participants")) orelse {
        try issues.add(allocator, "participants-object-required");
        return;
    };
    if (participants.count() != 3 or participants.get("learnings") == null or participants.get("synesthesia") == null or participants.get("negative-ledger") == null) {
        try issues.add(allocator, "participant-set");
    }

    const learning = try validateCheckpointParticipant(allocator, asObjectValue(participants.get("learnings")), .learnings, issues);
    const synesthesia = try validateCheckpointParticipant(allocator, asObjectValue(participants.get("synesthesia")), .synesthesia, issues);
    const negative = try validateCheckpointParticipant(allocator, asObjectValue(participants.get("negative-ledger")), .negative_ledger, issues);

    const canonical_blocked = learning.canonical_blocked or synesthesia.canonical_blocked or negative.canonical_blocked;
    const admission_blocked = learning.admission_blocked or synesthesia.admission_blocked or negative.admission_blocked;
    const expected_status: []const u8 = if (canonical_blocked) "blocked" else if (admission_blocked) "degraded" else "complete";
    if (!fieldEqualsString(receipt, "status", expected_status)) try issues.add(allocator, "aggregate-status");
}

fn validateCheckpointParticipant(
    allocator: std.mem.Allocator,
    maybe_participant: ?std.json.ObjectMap,
    source: CheckpointParticipant,
    issues: *Issues,
) !ParticipantValidation {
    const participant = maybe_participant orelse {
        try issues.add(allocator, "participant-object-required");
        return .{ .canonical_blocked = true };
    };
    const disposition = stringField(participant, "disposition") orelse "";
    const admission = stringField(participant, "admission") orelse "";
    const record_id = nonblankString(participant.get("record_id"));
    const note_id = nonblankString(participant.get("note_id"));

    if (!validCheckpointDisposition(source, disposition)) try issues.add(allocator, "participant-disposition");
    if (!stringIn(admission, &.{ "created", "duplicate-skip", "not-eligible", "not-applicable", "blocked" })) {
        try issues.add(allocator, "admission-disposition");
    }
    if (record_id) |id| {
        if (!validRecordId(source, id)) try issues.add(allocator, "record-id-prefix");
    }
    if (note_id) |id| {
        if (!std.mem.startsWith(u8, id, "MSN-")) try issues.add(allocator, "note-id-prefix");
    }

    const canonical_record = dispositionHasCanonicalRecord(source, disposition);
    const canonical_write = dispositionIsCanonicalWrite(source, disposition);
    const canonical_blocked = std.mem.eql(u8, disposition, "blocked") or !validCheckpointDisposition(source, disposition);
    if (canonical_record != (record_id != null)) try issues.add(allocator, "record-id-compatibility");
    if (canonical_write and !nonblankStringArray(participant.get("proof_refs"))) try issues.add(allocator, "participant-proof-refs");
    if (!canonical_write and !std.mem.eql(u8, disposition, "appended") and !isNonblankString(participant.get("reason"))) {
        try issues.add(allocator, "participant-reason");
    }

    const admission_creates_or_reuses_note = stringIn(admission, &.{ "created", "duplicate-skip" });
    if (admission_creates_or_reuses_note and (!canonical_record or note_id == null)) try issues.add(allocator, "admission-note-compatibility");
    if (!admission_creates_or_reuses_note and note_id != null) try issues.add(allocator, "admission-note-compatibility");
    if (std.mem.eql(u8, admission, "not-eligible") and (!canonical_record or !isNonblankString(participant.get("admission_reason")))) {
        try issues.add(allocator, "admission-eligibility-compatibility");
    }
    if (std.mem.eql(u8, admission, "blocked") and (!canonical_record or !isNonblankString(participant.get("admission_reason")))) {
        try issues.add(allocator, "admission-blocked-compatibility");
    }
    if (stringIn(disposition, &.{ "candidate", "no-op", "mapped", "blocked" }) and !std.mem.eql(u8, admission, "not-applicable")) {
        try issues.add(allocator, "admission-source-compatibility");
    }
    if (canonical_record and std.mem.eql(u8, admission, "not-applicable")) try issues.add(allocator, "admission-source-compatibility");

    return .{
        .canonical_blocked = canonical_blocked,
        .admission_blocked = std.mem.eql(u8, admission, "blocked"),
    };
}

fn validCheckpointDisposition(source: CheckpointParticipant, disposition: []const u8) bool {
    return switch (source) {
        .learnings => stringIn(disposition, &.{ "appended", "duplicate-skip", "no-op", "blocked" }),
        .synesthesia => stringIn(disposition, &.{ "appended", "candidate", "no-op", "blocked" }),
        .negative_ledger => stringIn(disposition, &.{ "mapped", "captured", "transitioned", "no-op", "blocked" }),
    };
}

fn dispositionIsCanonicalWrite(source: CheckpointParticipant, disposition: []const u8) bool {
    return switch (source) {
        .learnings, .synesthesia => std.mem.eql(u8, disposition, "appended"),
        .negative_ledger => stringIn(disposition, &.{ "captured", "transitioned" }),
    };
}

fn dispositionHasCanonicalRecord(source: CheckpointParticipant, disposition: []const u8) bool {
    if (dispositionIsCanonicalWrite(source, disposition)) return true;
    return source == .learnings and std.mem.eql(u8, disposition, "duplicate-skip");
}

fn validRecordId(source: CheckpointParticipant, id: []const u8) bool {
    return switch (source) {
        .learnings => std.mem.startsWith(u8, id, "lrn-"),
        .synesthesia => std.mem.startsWith(u8, id, "SYN-"),
        .negative_ledger => std.mem.startsWith(u8, id, "NEG-"),
    };
}

fn validSha256Fingerprint(value: ?std.json.Value) bool {
    const raw = nonblankString(value) orelse return false;
    const hex = if (std.mem.startsWith(u8, raw, "sha256:")) raw[7..] else raw;
    if (hex.len != 64) return false;
    for (hex) |char| if (!std.ascii.isHex(char)) return false;
    return true;
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

fn nonblankStringArray(value: ?std.json.Value) bool {
    const array = asArrayValue(value) orelse return false;
    if (array.items.len == 0) return false;
    for (array.items) |item| if (!isNonblankString(item)) return false;
    return true;
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

test "source memory checkpoint validation accepts a complete all no-op receipt" {
    const input =
        \\{"schema":"source-memory-checkpoint/v1","checkpoint_id":"SMC-20260715-0001","trigger":"delivery-boundary","subject_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","evidence_fingerprint":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","participants":{"learnings":{"disposition":"no-op","reason":"capture gate not met","admission":"not-applicable"},"synesthesia":{"disposition":"no-op","reason":"literal model sufficient","admission":"not-applicable"},"negative-ledger":{"disposition":"no-op","reason":"no failed route evidence","admission":"not-applicable"}},"status":"complete"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    try validateSourceMemoryCheckpoint(std.testing.allocator, parsed.value, &issues);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "source memory checkpoint preserves canonical success across admission degradation" {
    const input =
        \\{"schema":"source-memory-checkpoint/v1","checkpoint_id":"SMC-20260715-0002","trigger":"validation-transition","subject_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","evidence_fingerprint":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","participants":{"learnings":{"disposition":"appended","record_id":"lrn-20260715T000000Z-12345678","proof_refs":["test:learning"],"admission":"blocked","admission_reason":"memory-note unavailable"},"synesthesia":{"disposition":"no-op","reason":"literal model sufficient","admission":"not-applicable"},"negative-ledger":{"disposition":"no-op","reason":"no failed route evidence","admission":"not-applicable"}},"status":"degraded"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    try validateSourceMemoryCheckpoint(std.testing.allocator, parsed.value, &issues);
    try std.testing.expectEqual(@as(usize, 0), issues.values.items.len);
}

test "source memory checkpoint rejects missing participants and illegal candidate admission" {
    const input =
        \\{"schema":"source-memory-checkpoint/v1","checkpoint_id":"SMC-20260715-0003","trigger":"delivery-boundary","subject_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","evidence_fingerprint":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","participants":{"learnings":{"disposition":"no-op","reason":"capture gate not met","admission":"not-applicable"},"synesthesia":{"disposition":"candidate","reason":"needs endorsement","admission":"created","note_id":"MSN-illegal"}},"status":"complete"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    var issues = Issues{};
    defer issues.deinit(std.testing.allocator);
    try validateSourceMemoryCheckpoint(std.testing.allocator, parsed.value, &issues);
    try std.testing.expect(containsIssue(issues.values.items, "participant-set"));
    try std.testing.expect(containsIssue(issues.values.items, "participant-object-required"));
    try std.testing.expect(containsIssue(issues.values.items, "admission-note-compatibility"));
    try std.testing.expect(containsIssue(issues.values.items, "admission-source-compatibility"));
    try std.testing.expect(containsIssue(issues.values.items, "aggregate-status"));
}

fn containsIssue(issues: []const []const u8, expected: []const u8) bool {
    for (issues) |issue| if (std.mem.eql(u8, issue, expected)) return true;
    return false;
}
