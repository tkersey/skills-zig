const ledger_actuation_core = @import("ledger_actuation_core");
const canonical_json = @import("execution_policy_core").canonical_json;
const std = @import("std");

const GenesisDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
const TestConstructionDigest =
    "sha256:1111111111111111111111111111111111111111111111111111111111111111";
const TestSubjectDigest = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
const TestChangedDigest = "sha256:3333333333333333333333333333333333333333333333333333333333333333";
const TestSetOneDigest = "sha256:4444444444444444444444444444444444444444444444444444444444444444";
const TestSetTwoDigest = "sha256:5555555555555555555555555555555555555555555555555555555555555555";
const MaxEvents = 10_000;

pub const Window = struct {
    session_id: []const u8,
    session_path: []const u8,
    start_epoch_s: ?i64,
    end_epoch_s: ?i64,
};

const ClassState = struct {
    class_id: []const u8,
    boundary_key: []const u8,
    law_ref: []const u8,
    owner_boundary: []const u8,
    severity: []const u8,
    status: []const u8,
    set_ref: []const u8,
    occurrences: usize,
};

const Counts = struct {
    total_events: usize = 0,
    window_events: usize = 0,
    timestamp_overlap_events: usize = 0,
    session_unbound_overlap_events: usize = 0,
    constructions: usize = 0,
    effects: usize = 0,
    counterexample_sets: usize = 0,
    recurrence_observations: usize = 0,
    accepted_class_checks: usize = 0,
    recurrent_class_checks: usize = 0,
    owner_local_covered: usize = 0,
    owner_local_missing: usize = 0,
    recurrent_example_only: usize = 0,
    aggregate_only: usize = 0,
    subject_bound_events: usize = 0,
    operation_prepared: usize = 0,
    operation_observed: usize = 0,
    subject_changes: usize = 0,
    candidate_count: usize = 0,
    incumbent_independent_candidates: usize = 0,
    predecessor_factor_count: usize = 0,
    successor_factor_count: usize = 0,
    preserved_factor_count: usize = 0,
    retired_factor_count: usize = 0,
    introduced_factor_count: usize = 0,
    replacement_relation_count: usize = 0,
    essential_addition_count: usize = 0,
    surface_completeness_bound: bool = false,
    review_recompilation: bool = false,
    current_review_binding: bool = false,
};

pub fn auditEvidenceStoreAlloc(
    allocator: std.mem.Allocator,
    evidence_path: []const u8,
    goal_id: []const u8,
    window: Window,
    session_event_digests: []const []const u8,
) ![]u8 {
    const bytes = try ledger_actuation_core.validatedEvidenceSnapshotAlloc(
        allocator,
        evidence_path,
        goal_id,
    );
    defer allocator.free(bytes);
    return auditEvidenceBytesAlloc(
        allocator,
        bytes,
        evidence_path,
        goal_id,
        window,
        .{ .digests = session_event_digests },
    );
}

pub fn hasStrictFailure(allocator: std.mem.Allocator, rendered: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const root = try asObject(parsed.value);
    const window = try asObject(try field(root, "window"));
    if (try integerField(window, "event_count") == 0) return true;
    const checks = try asObject(try field(root, "construction_checks"));
    for ([_][]const u8{
        "aggregate_only_violations",
        "owner_local_implementation_missing",
        "recurrent_example_only_violations",
    }) |name| if (try integerField(checks, name) > 0) return true;
    if (try integerField(checks, "candidate_count") !=
        @typeInfo(ledger_actuation_core.CandidateFamily).@"enum".fields.len)
    {
        return true;
    }
    if (try integerField(checks, "incumbent_independent_candidates") == 0) return true;
    if (!try boolField(checks, "surface_completeness_bound")) return true;
    if (!try boolField(checks, "current_review_binding")) return true;
    return false;
}

fn auditEvidenceBytesAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    evidence_path: []const u8,
    goal_id: []const u8,
    window: Window,
    binding: EventBinding,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store_state = AuditState{ .allocator = arena };
    var session_state = AuditState{ .allocator = arena };
    var events: std.ArrayList(VerifiedEvent) = .empty;
    defer events.deinit(arena);

    const records = if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
    if (records.len == 0 and bytes.len != 0) return error.BlankEvidenceRecord;
    var lines = std.mem.splitScalar(u8, records, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) return error.BlankEvidenceRecord;
        const event = try validateEvidenceLine(&store_state, line, goal_id);
        try applyArtifactState(&store_state, event, false);
        try events.append(arena, event);
    }
    if (store_state.counts.total_events == 0) return error.EmptyEvidenceStore;
    const last_bound_index = lastBoundEventIndex(events.items, binding);
    for (events.items, 0..) |event, index| {
        try applyWindowEvent(
            &session_state,
            event,
            window,
            binding,
            last_bound_index != null and index <= last_bound_index.?,
        );
    }
    if (session_state.counts.window_events > 0) try auditCurrentProofState(&session_state);
    session_state.counts.total_events = store_state.counts.total_events;
    var current_accepted: usize = 0;
    var recurrent_classes: usize = 0;
    var recurrent_accepted: usize = 0;
    for (store_state.classes.items) |class| {
        if (class.occurrences > 1) recurrent_classes += 1;
        if (std.mem.eql(u8, class.status, "accepted")) {
            current_accepted += 1;
            if (class.occurrences > 1) recurrent_accepted += 1;
        }
    }
    return renderAlloc(
        allocator,
        evidence_path,
        goal_id,
        window,
        store_state.head_digest,
        session_state.subjects.count(),
        current_accepted,
        recurrent_classes,
        recurrent_accepted,
        session_state.counts,
    );
}

const AuditState = struct {
    allocator: std.mem.Allocator,
    classes: std.ArrayList(ClassState) = .empty,
    subjects: std.StringHashMapUnmanaged(void) = .empty,
    counts: Counts = .{},
    expected_sequence: usize = 1,
    expected_previous: []const u8 = GenesisDigest,
    head_digest: []const u8 = GenesisDigest,
    current_construction: ?std.json.Value = null,
    current_construction_ref: ?[]const u8 = null,
    latest_counterexample_set_ref: ?[]const u8 = null,
};

const VerifiedEvent = struct {
    object: std.json.ObjectMap,
    kind: []const u8,
    body: std.json.Value,
    event_digest: []const u8,
    recorded_at: i64,
};

const EventBinding = union(enum) {
    all,
    digests: []const []const u8,

    fn contains(self: EventBinding, digest: []const u8) bool {
        return switch (self) {
            .all => true,
            .digests => |digests| blk: {
                for (digests) |candidate| {
                    if (std.mem.eql(u8, candidate, digest)) break :blk true;
                }
                break :blk false;
            },
        };
    }
};

fn lastBoundEventIndex(events: []const VerifiedEvent, binding: EventBinding) ?usize {
    var result: ?usize = null;
    for (events, 0..) |event, index| {
        if (binding.contains(event.event_digest)) result = index;
    }
    return result;
}

fn validateEvidenceLine(
    state: *AuditState,
    line: []const u8,
    goal_id: []const u8,
) !VerifiedEvent {
    const canonical = try canonical_json.canonicalizeAlloc(state.allocator, line);
    if (!std.mem.eql(u8, canonical, line)) return error.NonCanonicalEvidence;
    const parsed = try std.json.parseFromSlice(std.json.Value, state.allocator, line, .{});
    const event = try asObject(parsed.value);
    try requireExactKeys(event, &.{
        "body",     "body_digest",    "construction_ref", "event_digest", "event_id",
        "goal_id",  "kind",           "previous_digest",  "recorded_at",  "schema",
        "sequence", "subject_digest",
    });
    if (!std.mem.eql(u8, try stringField(event, "schema"), "actuating-evidence-event/v1")) {
        return error.InvalidEvidenceSchema;
    }
    const sequence = try integerField(event, "sequence");
    if (sequence <= 0 or @as(usize, @intCast(sequence)) != state.expected_sequence) {
        return error.EvidenceSequenceMismatch;
    }
    var expected_id_buffer: [32]u8 = undefined;
    const expected_id = try std.fmt.bufPrint(
        &expected_id_buffer,
        "e-{d}",
        .{state.expected_sequence},
    );
    if (!std.mem.eql(u8, try stringField(event, "event_id"), expected_id)) {
        return error.EvidenceEventIdMismatch;
    }
    if (!std.mem.eql(u8, try stringField(event, "goal_id"), goal_id)) {
        return error.EvidenceGoalMismatch;
    }
    if (!std.mem.eql(u8, try stringField(event, "previous_digest"), state.expected_previous)) {
        return error.EvidencePreviousDigestMismatch;
    }
    try validateTupleDigests(event);
    const kind = try stringField(event, "kind");
    try validateKind(kind);
    const body_value = try field(event, "body");
    const body = try canonicalValueAlloc(state.allocator, body_value);
    const body_digest = try digestAlloc(state.allocator, body);
    if (!std.mem.eql(u8, body_digest, try stringField(event, "body_digest"))) {
        return error.EvidenceBodyDigestMismatch;
    }
    const basis = try eventBasisAlloc(state.allocator, event, body);
    const expected_event_digest = try digestAlloc(state.allocator, basis);
    if (!std.mem.eql(u8, expected_event_digest, try stringField(event, "event_digest"))) {
        return error.EvidenceEventDigestMismatch;
    }
    const event_digest = try stringField(event, "event_digest");
    state.head_digest = event_digest;
    state.expected_previous = state.head_digest;
    state.expected_sequence += 1;
    try recordValidatedEvent(state);
    return .{
        .object = event,
        .kind = kind,
        .body = body_value,
        .event_digest = event_digest,
        .recorded_at = try integerField(event, "recorded_at"),
    };
}

fn applyWindowEvent(
    state: *AuditState,
    event: VerifiedEvent,
    window: Window,
    binding: EventBinding,
    causal_state: bool,
) !void {
    const timestamp_in_window =
        (window.start_epoch_s == null or event.recorded_at >= window.start_epoch_s.?) and
        (window.end_epoch_s == null or event.recorded_at <= window.end_epoch_s.?);
    if (timestamp_in_window) state.counts.timestamp_overlap_events += 1;
    const in_window = timestamp_in_window and binding.contains(event.event_digest);
    if (timestamp_in_window and !in_window) state.counts.session_unbound_overlap_events += 1;
    if (causal_state) try applyArtifactState(state, event, in_window);
    if (!in_window) return;
    try applyCountedWindowEvent(state, event);
}

fn auditCurrentProofState(state: *AuditState) !void {
    if (state.current_construction) |body| {
        try auditConstruction(
            body,
            state.current_construction_ref,
            state.classes.items,
            state.latest_counterexample_set_ref,
            &state.counts,
        );
    } else auditMissingConstruction(state.classes.items, &state.counts);
}

fn applyArtifactState(state: *AuditState, event: VerifiedEvent, in_window: bool) !void {
    if (std.mem.eql(u8, event.kind, "goal_contract_registered")) {
        state.classes.clearRetainingCapacity();
        state.current_construction = null;
        state.current_construction_ref = null;
        state.latest_counterexample_set_ref = null;
        if (in_window) resetConstructionChecks(&state.counts);
    }
    if (std.mem.eql(u8, event.kind, "counterexample_set_registered")) {
        state.latest_counterexample_set_ref = try applyCounterexampleSet(
            state.allocator,
            &state.classes,
            event.body,
            in_window,
            &state.counts,
        );
    }
    if (std.mem.eql(u8, event.kind, "construction_contract_registered")) {
        state.current_construction = event.body;
        state.current_construction_ref = try optionalStringField(event.object, "construction_ref");
    }
    if (!in_window and std.mem.eql(u8, event.kind, "construction_contract_registered")) {
        var ignored = Counts{};
        try auditConstruction(
            event.body,
            state.current_construction_ref,
            state.classes.items,
            state.latest_counterexample_set_ref,
            &ignored,
        );
    }
}

fn applyCountedWindowEvent(state: *AuditState, event: VerifiedEvent) !void {
    state.counts.window_events += 1;
    const subject = try optionalStringField(event.object, "subject_digest");
    if (subject) |digest| {
        try requireDigest(digest);
        try state.subjects.put(state.allocator, digest, {});
        state.counts.subject_bound_events += 1;
    }
    if (std.mem.eql(u8, event.kind, "construction_contract_registered")) {
        state.counts.constructions += 1;
        try auditConstruction(
            event.body,
            try optionalStringField(event.object, "construction_ref"),
            state.classes.items,
            state.latest_counterexample_set_ref,
            &state.counts,
        );
    } else if (std.mem.eql(u8, event.kind, "effect_recorded")) {
        state.counts.effects += 1;
        const event_subject = subject orelse return error.MissingEffectSubject;
        const effect = try asObject(event.body);
        const pre_subject = try stringField(effect, "pre_effect_subject_digest");
        try requireDigest(pre_subject);
        if (!std.mem.eql(u8, pre_subject, event_subject)) state.counts.subject_changes += 1;
    } else if (std.mem.eql(u8, event.kind, "counterexample_set_registered")) {
        state.counts.counterexample_sets += 1;
        if (state.current_construction) |body| {
            try auditConstruction(
                body,
                state.current_construction_ref,
                state.classes.items,
                state.latest_counterexample_set_ref,
                &state.counts,
            );
        } else auditMissingConstruction(state.classes.items, &state.counts);
    } else if (std.mem.eql(u8, event.kind, "operation_prepared")) {
        state.counts.operation_prepared += 1;
    } else if (std.mem.eql(u8, event.kind, "operation_observed")) {
        state.counts.operation_observed += 1;
    }
}

fn validateTupleDigests(event: std.json.ObjectMap) !void {
    const construction_ref = try optionalStringField(event, "construction_ref");
    const subject_digest = try optionalStringField(event, "subject_digest");
    if (construction_ref) |value| try requireDigest(value);
    if (subject_digest) |value| try requireDigest(value);
}

fn recordValidatedEvent(state: *AuditState) !void {
    if (state.counts.total_events == MaxEvents) return error.TooManyEvents;
    state.counts.total_events += 1;
}

fn applyCounterexampleSet(
    allocator: std.mem.Allocator,
    classes: *std.ArrayList(ClassState),
    body_value: std.json.Value,
    in_window: bool,
    counts: *Counts,
) ![]const u8 {
    const artifact = try artifactObject(body_value, "counterexample-set/v1");
    const artifact_id = try stringField(artifact, "artifact_id");
    try requireDigest(artifact_id);
    const predecessors = try asArray(try field(artifact, "predecessor_refs"));
    const payload = try asObject(try field(artifact, "payload"));
    const class_values = try asArray(try field(payload, "classes"));
    for (class_values.items) |item| {
        const class = try asObject(item);
        const class_id = try stringField(class, "class_id");
        const boundary_key = try stringField(class, "boundary_key");
        const law_ref = try stringField(class, "law_ref");
        const owner_boundary = try stringField(class, "owner_boundary");
        const severity = try stringField(class, "severity");
        const status = try stringField(class, "status");
        try validateClassSeverity(severity);
        try validateClassStatus(status);
        if (findClass(classes.items, class_id)) |existing| {
            if (!std.mem.eql(u8, existing.boundary_key, boundary_key) or
                !std.mem.eql(u8, existing.law_ref, law_ref) or
                !std.mem.eql(u8, existing.owner_boundary, owner_boundary))
            {
                return error.CounterexampleIdentityDrift;
            }
            if (std.mem.eql(u8, existing.set_ref, artifact_id)) {
                return error.DuplicateCounterexampleClass;
            }
            if (!stringArrayContains(predecessors, existing.set_ref)) {
                return error.MissingCounterexampleSetPredecessor;
            }
            existing.severity = severity;
            existing.status = status;
            existing.set_ref = artifact_id;
            existing.occurrences += 1;
            if (in_window) counts.recurrence_observations += 1;
        } else try classes.append(allocator, .{
            .class_id = class_id,
            .boundary_key = boundary_key,
            .law_ref = law_ref,
            .owner_boundary = owner_boundary,
            .severity = severity,
            .status = status,
            .set_ref = artifact_id,
            .occurrences = 1,
        });
    }
    return artifact_id;
}

fn auditConstruction(
    body_value: std.json.Value,
    construction_ref: ?[]const u8,
    classes: []const ClassState,
    latest_counterexample_set_ref: ?[]const u8,
    counts: *Counts,
) !void {
    resetConstructionChecks(counts);
    var requirements = try std.heap.page_allocator.alloc(
        ledger_actuation_core.ConstructionClassRequirement,
        classes.len,
    );
    defer std.heap.page_allocator.free(requirements);
    var requirement_count: usize = 0;
    for (classes) |class| {
        if (!std.mem.eql(u8, class.status, "accepted")) continue;
        requirements[requirement_count] = .{
            .class_id = class.class_id,
            .law_ref = class.law_ref,
            .owner_boundary = class.owner_boundary,
            .severity = class.severity,
            .occurrences = class.occurrences,
        };
        requirement_count += 1;
    }
    const audit = try ledger_actuation_core.auditConstruction(
        body_value,
        construction_ref,
        requirements[0..requirement_count],
        latest_counterexample_set_ref,
    );
    counts.accepted_class_checks = audit.accepted_class_checks;
    counts.recurrent_class_checks = audit.recurrent_class_checks;
    counts.owner_local_covered = audit.owner_local_covered;
    counts.owner_local_missing = audit.owner_local_missing;
    counts.recurrent_example_only = audit.recurrent_example_only;
    counts.aggregate_only = audit.aggregate_only;
    counts.candidate_count = audit.candidate_count;
    counts.incumbent_independent_candidates = audit.incumbent_independent_candidates;
    counts.predecessor_factor_count = audit.predecessor_factor_count;
    counts.successor_factor_count = audit.successor_factor_count;
    counts.preserved_factor_count = audit.preserved_factor_count;
    counts.retired_factor_count = audit.retired_factor_count;
    counts.introduced_factor_count = audit.introduced_factor_count;
    counts.replacement_relation_count = audit.replacement_relation_count;
    counts.essential_addition_count = audit.essential_addition_count;
    counts.surface_completeness_bound = audit.surface_completeness_bound;
    counts.review_recompilation = audit.review_recompilation;
    counts.current_review_binding = audit.current_review_binding;
}

fn resetConstructionChecks(counts: *Counts) void {
    counts.accepted_class_checks = 0;
    counts.recurrent_class_checks = 0;
    counts.owner_local_covered = 0;
    counts.owner_local_missing = 0;
    counts.recurrent_example_only = 0;
    counts.aggregate_only = 0;
    counts.candidate_count = 0;
    counts.incumbent_independent_candidates = 0;
    counts.predecessor_factor_count = 0;
    counts.successor_factor_count = 0;
    counts.preserved_factor_count = 0;
    counts.retired_factor_count = 0;
    counts.introduced_factor_count = 0;
    counts.replacement_relation_count = 0;
    counts.essential_addition_count = 0;
    counts.surface_completeness_bound = false;
    counts.review_recompilation = false;
    counts.current_review_binding = false;
}

fn auditMissingConstruction(classes: []const ClassState, counts: *Counts) void {
    resetConstructionChecks(counts);
    for (classes) |class| {
        if (!std.mem.eql(u8, class.status, "accepted")) continue;
        counts.accepted_class_checks += 1;
        counts.owner_local_missing += 1;
        if (class.occurrences > 1) counts.recurrent_class_checks += 1;
    }
}

fn renderAlloc(
    allocator: std.mem.Allocator,
    evidence_path: []const u8,
    goal_id: []const u8,
    window: Window,
    head_digest: []const u8,
    distinct_subjects: usize,
    current_accepted: usize,
    recurrent_classes: usize,
    recurrent_accepted: usize,
    counts: Counts,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(
        "{\"authority_granted\":false,\"closure_established\":false," ++
            "\"construction_checks\":{",
    );
    try writeConstructionChecks(writer, counts);
    try writer.writeAll("},\"counterexamples\":{");
    try writeCounterexampleCounts(
        writer,
        counts,
        current_accepted,
        recurrent_classes,
        recurrent_accepted,
    );
    try writer.writeAll("},\"evidence\":{\"event_count\":");
    try writer.print("{d},\"goal_id\":", .{counts.total_events});
    try writeJsonString(writer, goal_id);
    try writer.writeAll(",\"hash_chain_valid\":true,\"head_digest\":");
    try writeJsonString(writer, head_digest);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, evidence_path);
    try writer.writeAll(
        "},\"limitations\":[\"structural audit only; semantic Counterexample adequacy " ++
            "review credit publication and closure remain owner decisions\"]," ++
            "\"schema\":\"SEQ-ACTKERNEL-v1\",\"semantic_decision_established\":false," ++
            "\"session\":{\"ended_epoch_s\":",
    );
    try writeOptionalInt(writer, window.end_epoch_s);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, window.session_path);
    try writer.writeAll(",\"session_id\":");
    try writeJsonString(writer, window.session_id);
    try writer.writeAll(",\"started_epoch_s\":");
    try writeOptionalInt(writer, window.start_epoch_s);
    try writer.writeAll("},\"subjects\":{");
    try writeSubjectCounts(writer, counts, distinct_subjects);
    try writer.writeAll("},\"window\":{");
    try writeWindowCounts(writer, counts);
    try writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn writeConstructionChecks(writer: *std.Io.Writer, counts: Counts) !void {
    try writer.print(
        "\"accepted_class_checks\":{d},\"aggregate_only_violations\":{d}," ++
            "\"candidate_count\":{d},\"essential_addition_count\":{d}," ++
            "\"incumbent_independent_candidates\":{d},\"introduced_factor_count\":{d},",
        .{
            counts.accepted_class_checks,
            counts.aggregate_only,
            counts.candidate_count,
            counts.essential_addition_count,
            counts.incumbent_independent_candidates,
            counts.introduced_factor_count,
        },
    );
    try writer.print(
        "\"owner_local_implementation_covered\":{d}," ++
            "\"owner_local_implementation_missing\":{d}," ++
            "\"predecessor_factor_count\":{d},\"preserved_factor_count\":{d}," ++
            "\"replacement_relation_count\":{d},\"retired_factor_count\":{d},",
        .{
            counts.owner_local_covered,
            counts.owner_local_missing,
            counts.predecessor_factor_count,
            counts.preserved_factor_count,
            counts.replacement_relation_count,
            counts.retired_factor_count,
        },
    );
    try writer.print(
        "\"current_review_binding\":{},\"recurrent_class_checks\":{d}," ++
            "\"recurrent_example_only_violations\":{d}," ++
            "\"review_recompilation\":{},\"successor_factor_count\":{d}," ++
            "\"surface_completeness_bound\":{}",
        .{
            counts.current_review_binding,
            counts.recurrent_class_checks,
            counts.recurrent_example_only,
            counts.review_recompilation,
            counts.successor_factor_count,
            counts.surface_completeness_bound,
        },
    );
}

fn writeCounterexampleCounts(
    writer: *std.Io.Writer,
    counts: Counts,
    current_accepted: usize,
    recurrent_classes: usize,
    recurrent_accepted: usize,
) !void {
    try writer.print(
        "\"current_accepted_classes\":{d},\"current_recurrent_accepted_classes\":{d}," ++
            "\"recurrence_observations_in_window\":{d}," ++
            "\"recurrent_classes_at_store_end\":{d}",
        .{
            current_accepted,
            recurrent_accepted,
            counts.recurrence_observations,
            recurrent_classes,
        },
    );
}

fn writeSubjectCounts(
    writer: *std.Io.Writer,
    counts: Counts,
    distinct_subjects: usize,
) !void {
    try writer.print(
        "\"distinct_subjects\":{d},\"operation_observed\":{d}," ++
            "\"operation_prepared\":{d},\"subject_bound_events\":{d}," ++
            "\"subject_changes\":{d}",
        .{
            distinct_subjects,
            counts.operation_observed,
            counts.operation_prepared,
            counts.subject_bound_events,
            counts.subject_changes,
        },
    );
}

fn writeWindowCounts(writer: *std.Io.Writer, counts: Counts) !void {
    try writer.print(
        "\"construction_registrations\":{d},\"counterexample_set_registrations\":{d}," ++
            "\"effect_records\":{d},\"event_count\":{d}," ++
            "\"session_unbound_overlap_events\":{d},\"timestamp_overlap_events\":{d}",
        .{
            counts.constructions,
            counts.counterexample_sets,
            counts.effects,
            counts.window_events,
            counts.session_unbound_overlap_events,
            counts.timestamp_overlap_events,
        },
    );
}

fn eventBasisAlloc(
    allocator: std.mem.Allocator,
    event: std.json.ObjectMap,
    body: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"body\":");
    try writer.writeAll(body);
    for ([_][]const u8{
        "body_digest",
        "construction_ref",
        "event_id",
        "goal_id",
        "kind",
        "previous_digest",
    }) |name| {
        try writer.writeAll(",");
        try writeJsonString(writer, name);
        try writer.writeByte(':');
        try std.json.Stringify.value(try field(event, name), .{}, writer);
    }
    try writer.print(",\"recorded_at\":{d},\"schema\":", .{try integerField(event, "recorded_at")});
    try writeJsonString(writer, try stringField(event, "schema"));
    try writer.print(
        ",\"sequence\":{d},\"subject_digest\":",
        .{try integerField(event, "sequence")},
    );
    try std.json.Stringify.value(try field(event, "subject_digest"), .{}, writer);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn artifactObject(body: std.json.Value, schema: []const u8) !std.json.ObjectMap {
    const document = try asObject(body);
    try requireExactKeys(document, &.{"artifact"});
    const artifact = try asObject(try field(document, "artifact"));
    if (!std.mem.eql(u8, try stringField(artifact, "schema"), schema)) {
        return error.InvalidRegisteredArtifact;
    }
    return artifact;
}

fn canonicalValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var raw: std.Io.Writer.Allocating = .init(allocator);
    defer raw.deinit();
    try std.json.Stringify.value(value, .{}, &raw.writer);
    return canonical_json.canonicalizeAlloc(allocator, raw.written());
}

fn digestAlloc(allocator: std.mem.Allocator, canonical: []const u8) ![]u8 {
    const digest = try canonical_json.digestCanonicalBytes(allocator, canonical);
    return digest.text;
}

fn findClass(classes: []ClassState, id: []const u8) ?*ClassState {
    for (classes) |*class| if (std.mem.eql(u8, class.class_id, id)) return class;
    return null;
}

fn stringArrayContains(array: std.json.Array, value: []const u8) bool {
    for (array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, value)) return true;
    }
    return false;
}

fn validateKind(kind: []const u8) !void {
    const kinds = [_][]const u8{
        "goal_contract_registered",
        "counterexample_set_registered",
        "construction_contract_registered",
        "operation_prepared",
        "effect_recorded",
        "operation_observed",
        "operation_aborted",
        "publication_observed",
        "review_campaign_started",
        "review_request_bound",
        "review_attempt_started",
        "review_attempt_completed",
        "review_transport_failed",
    };
    for (kinds) |candidate| if (std.mem.eql(u8, kind, candidate)) return;
    return error.InvalidEvidenceKind;
}

fn validateClassSeverity(value: []const u8) !void {
    for ([_][]const u8{ "critical", "high", "medium", "low" }) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return;
    }
    return error.InvalidClassSeverity;
}

fn validateClassStatus(value: []const u8) !void {
    for ([_][]const u8{ "accepted", "rejected", "blocked", "follow-up" }) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return;
    }
    return error.InvalidClassStatus;
}

fn requireDigest(value: []const u8) !void {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) {
        return error.InvalidDigest;
    }
    for (value[7..]) |byte| if (!std.ascii.isHex(byte)) return error.InvalidDigest;
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn asArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.ExpectedArray,
    };
}

fn field(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (try field(object, name)) {
        .string => |value| value,
        else => error.ExpectedString,
    };
}

fn optionalStringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    return switch (try field(object, name)) {
        .null => null,
        .string => |value| value,
        else => error.ExpectedOptionalString,
    };
}

fn integerField(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (try field(object, name)) {
        .integer => |value| value,
        else => error.ExpectedInteger,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) !bool {
    return switch (try field(object, name)) {
        .bool => |value| value,
        else => error.ExpectedBoolean,
    };
}

fn requireExactKeys(object: std.json.ObjectMap, keys: []const []const u8) !void {
    if (object.count() != keys.len) return error.UnexpectedField;
    for (keys) |key| if (!object.contains(key)) return error.MissingField;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeOptionalInt(writer: *std.Io.Writer, value: ?i64) !void {
    if (value) |integer| try writer.print("{d}", .{integer}) else try writer.writeAll("null");
}

const TestEvent = struct {
    bytes: []u8,
    digest: []u8,

    fn deinit(self: TestEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.digest);
    }
};

fn testEventAlloc(
    allocator: std.mem.Allocator,
    sequence: usize,
    previous_digest: []const u8,
    kind: []const u8,
    recorded_at: i64,
    body_input: []const u8,
) !TestEvent {
    const body = try canonical_json.canonicalizeAlloc(allocator, body_input);
    defer allocator.free(body);
    const body_digest = try digestAlloc(allocator, body);
    defer allocator.free(body_digest);
    var partial: std.Io.Writer.Allocating = .init(allocator);
    defer partial.deinit();
    try partial.writer.writeAll("{\"body\":");
    try partial.writer.writeAll(body);
    try partial.writer.writeAll(",\"body_digest\":");
    try writeJsonString(&partial.writer, body_digest);
    try partial.writer.writeAll(",\"construction_ref\":");
    try writeJsonString(&partial.writer, TestConstructionDigest);
    try partial.writer.writeAll(",\"event_digest\":null,\"event_id\":");
    var id_buffer: [32]u8 = undefined;
    const event_id = try std.fmt.bufPrint(&id_buffer, "e-{d}", .{sequence});
    try writeJsonString(&partial.writer, event_id);
    try partial.writer.writeAll(",\"goal_id\":\"goal-1\",\"kind\":");
    try writeJsonString(&partial.writer, kind);
    try partial.writer.writeAll(",\"previous_digest\":");
    try writeJsonString(&partial.writer, previous_digest);
    try partial.writer.print(
        ",\"recorded_at\":{d},\"schema\":\"actuating-evidence-event/v1\",\"sequence\":{d}",
        .{ recorded_at, sequence },
    );
    try partial.writer.writeAll(",\"subject_digest\":");
    try writeJsonString(&partial.writer, TestSubjectDigest);
    try partial.writer.writeByte('}');
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, partial.written(), .{});
    defer parsed.deinit();
    const event = try asObject(parsed.value);
    const basis = try eventBasisAlloc(allocator, event, body);
    defer allocator.free(basis);
    const event_digest = try digestAlloc(allocator, basis);
    errdefer allocator.free(event_digest);
    var final: std.Io.Writer.Allocating = .init(allocator);
    defer final.deinit();
    try final.writer.writeAll("{\"body\":");
    try final.writer.writeAll(body);
    try final.writer.writeAll(",\"body_digest\":");
    try writeJsonString(&final.writer, body_digest);
    try final.writer.writeAll(",\"construction_ref\":");
    try writeJsonString(&final.writer, TestConstructionDigest);
    try final.writer.writeAll(",\"event_digest\":");
    try writeJsonString(&final.writer, event_digest);
    try final.writer.writeAll(",\"event_id\":");
    try writeJsonString(&final.writer, event_id);
    try final.writer.writeAll(",\"goal_id\":\"goal-1\",\"kind\":");
    try writeJsonString(&final.writer, kind);
    try final.writer.writeAll(",\"previous_digest\":");
    try writeJsonString(&final.writer, previous_digest);
    try final.writer.print(
        ",\"recorded_at\":{d},\"schema\":\"actuating-evidence-event/v1\",\"sequence\":{d}",
        .{ recorded_at, sequence },
    );
    try final.writer.writeAll(",\"subject_digest\":");
    try writeJsonString(&final.writer, TestSubjectDigest);
    try final.writer.writeByte('}');
    return .{ .bytes = try final.toOwnedSlice(), .digest = event_digest };
}

const TestFactorJson =
    "{\"description\":\"owner remains authoritative\",\"factor_id\":\"factor-owner\"," ++
    "\"kind\":\"law-owner\",\"law_refs\":[\"law-1\"]," ++
    "\"observation_refs\":[\"proof-1\"],\"owner\":\"src\"}";

const TestCandidatesJson =
    "[{\"candidate_id\":\"candidate-realization\",\"derivation\":\"incumbent-independent\"," ++
    "\"factors\":[" ++ TestFactorJson ++ "],\"falsifier\":\"realization fails\"," ++
    "\"family\":\"realization-preserve\",\"law_refs\":[\"law-1\"]," ++
    "\"observation_refs\":[\"proof-1\"],\"residual_obligations\":[]," ++
    "\"status\":\"selected\",\"summary\":\"preserve realization\"}," ++
    "{\"candidate_id\":\"candidate-restriction\",\"derivation\":\"incumbent-relative\"," ++
    "\"factors\":[" ++ TestFactorJson ++ "],\"falsifier\":\"restriction required\"," ++
    "\"family\":\"admitted-domain-restriction\",\"law_refs\":[\"law-1\"]," ++
    "\"observation_refs\":[\"proof-1\"],\"residual_obligations\":[]," ++
    "\"status\":\"dominated\",\"summary\":\"restrict domain\"}," ++
    "{\"candidate_id\":\"candidate-strengthening\",\"derivation\":\"incumbent-relative\"," ++
    "\"factors\":[" ++ TestFactorJson ++ "],\"falsifier\":\"strengthening required\"," ++
    "\"family\":\"representation-or-owner-strengthening\",\"law_refs\":[\"law-1\"]," ++
    "\"observation_refs\":[\"proof-1\"],\"residual_obligations\":[]," ++
    "\"status\":\"dominated\",\"summary\":\"strengthen owner\"}," ++
    "{\"candidate_id\":\"candidate-ablation\",\"derivation\":\"incumbent-relative\"," ++
    "\"factors\":[" ++ TestFactorJson ++ "],\"falsifier\":\"ablation required\"," ++
    "\"family\":\"ablation-normalization\",\"law_refs\":[\"law-1\"]," ++
    "\"observation_refs\":[\"proof-1\"],\"residual_obligations\":[]," ++
    "\"status\":\"dominated\",\"summary\":\"ablate mechanism\"}]";

const TestAdjudicationJson =
    "{\"falsifier\":\"smaller candidate exists\",\"reduction_disposition\":\"minimal\"," ++
    "\"reduction_reason\":\"no factor can be removed\"," ++
    "\"selected_reason\":\"smallest law-preserving construction\"}";

const TestInitialRecompilationJson =
    "{\"adjudication\":" ++ TestAdjudicationJson ++ ",\"candidates\":" ++
    TestCandidatesJson ++ ",\"counterexample_set_ref\":null," ++
    "\"evaluated_class_refs\":[],\"selected_candidate_id\":\"candidate-realization\"," ++
    "\"trigger\":\"initial\"}";

const TestSuccessorRecompilationJson =
    "{\"adjudication\":" ++ TestAdjudicationJson ++ ",\"candidates\":" ++
    TestCandidatesJson ++ ",\"counterexample_set_ref\":\"" ++ TestSetTwoDigest ++ "\"," ++
    "\"evaluated_class_refs\":[\"class-1\"]," ++
    "\"selected_candidate_id\":\"candidate-realization\"," ++
    "\"trigger\":\"accepted-review-fold\"}";

const TestInitialSupersessionJson =
    "{\"disposition\":\"initial\",\"essential_additions\":[]," ++
    "\"introduced_factor_refs\":[\"factor-owner\"],\"preserved_factor_refs\":[]," ++
    "\"replacement_relations\":[],\"retired_factor_refs\":[]," ++
    "\"surface_completeness_proof_ref\":\"proof-1\"}";

const TestSuccessorSupersessionJson =
    "{\"disposition\":\"unchanged-realization\",\"essential_additions\":[]," ++
    "\"introduced_factor_refs\":[],\"preserved_factor_refs\":[\"factor-owner\"]," ++
    "\"replacement_relations\":[],\"retired_factor_refs\":[]," ++
    "\"surface_completeness_proof_ref\":\"proof-1\"}";

const TestBodies = [_][]const u8{
    "{\"artifact\":{\"payload\":{},\"schema\":\"goal-contract/v3\"}}",
    "{\"artifact\":{\"artifact_id\":\"" ++ TestConstructionDigest ++
        "\",\"payload\":{\"architecture\":{" ++
        "\"governing_law_refs\":[\"law-1\"]},\"counterexample_class_refs\":[]," ++
        "\"proof_obligations\":[],\"recompilation\":" ++ TestInitialRecompilationJson ++
        ",\"semantic_surface\":{\"predecessor_factors\":[],\"successor_factors\":[" ++
        TestFactorJson ++ "]},\"supersession\":" ++ TestInitialSupersessionJson ++
        "},\"schema\":\"construction-contract/v3\"}}",
    "{\"artifact\":{\"artifact_id\":\"" ++ TestSetOneDigest ++
        "\",\"payload\":{\"classes\":[{\"boundary_key\":\"boundary\"," ++
        "\"class_id\":\"class-1\",\"law_ref\":\"law-1\"," ++
        "\"owner_boundary\":\"src\",\"severity\":\"medium\"," ++
        "\"status\":\"accepted\"}]},\"predecessor_refs\":[]," ++
        "\"schema\":\"counterexample-set/v1\"}}",
    "{\"artifact\":{\"artifact_id\":\"" ++ TestSetTwoDigest ++
        "\",\"payload\":{\"classes\":[{\"boundary_key\":\"boundary\"," ++
        "\"class_id\":\"class-1\",\"law_ref\":\"law-1\"," ++
        "\"owner_boundary\":\"src\",\"severity\":\"medium\"," ++
        "\"status\":\"accepted\"}]},\"predecessor_refs\":[\"" ++
        TestSetOneDigest ++ "\"]," ++
        "\"schema\":\"counterexample-set/v1\"}}",
    "{\"artifact\":{\"artifact_id\":\"" ++ TestConstructionDigest ++
        "\",\"payload\":{\"architecture\":{" ++
        "\"governing_law_refs\":[\"law-1\"]}," ++
        "\"counterexample_class_refs\":[\"class-1\"],\"proof_obligations\":[{" ++
        "\"law_ref\":\"law-1\",\"owner_boundary\":\"src\"," ++
        "\"proof_kind\":\"implementation\"," ++
        "\"proof_mode\":\"example-regression\"}],\"recompilation\":" ++
        TestSuccessorRecompilationJson ++
        ",\"semantic_surface\":{\"predecessor_factors\":[" ++ TestFactorJson ++
        "],\"successor_factors\":[" ++ TestFactorJson ++
        "]},\"supersession\":" ++ TestSuccessorSupersessionJson ++
        "},\"schema\":\"construction-contract/v3\"}}",
    "{\"changed_paths\":[\"src/main.zig\"],\"pre_effect_subject_digest\":\"" ++
        TestChangedDigest ++
        "\",\"schema\":\"effect-recorded/v1\",\"step_id\":\"edit-1\"}",
};

const TestKinds = [_][]const u8{
    "goal_contract_registered",         "construction_contract_registered",
    "counterexample_set_registered",    "counterexample_set_registered",
    "construction_contract_registered", "effect_recorded",
};

fn testEvidenceStoreAlloc(allocator: std.mem.Allocator) ![]u8 {
    var events: [TestBodies.len]TestEvent = undefined;
    var initialized: usize = 0;
    defer for (events[0..initialized]) |event| event.deinit(allocator);
    var previous: []const u8 = GenesisDigest;
    var store: std.Io.Writer.Allocating = .init(allocator);
    defer store.deinit();
    for (TestBodies, 0..) |body, index| {
        events[index] = try testEventAlloc(
            allocator,
            index + 1,
            previous,
            TestKinds[index],
            100 + @as(i64, @intCast(index)),
            body,
        );
        initialized += 1;
        previous = events[index].digest;
        try store.writer.writeAll(events[index].bytes);
        try store.writer.writeByte('\n');
    }
    return store.toOwnedSlice();
}

test "kernel audit verifies Evidence and exposes recurrent example-only proof" {
    const store = try testEvidenceStoreAlloc(std.testing.allocator);
    defer std.testing.allocator.free(store);
    const rendered = try auditEvidenceBytesAlloc(
        std.testing.allocator,
        store,
        "/tmp/evidence.jsonl",
        "goal-1",
        .{
            .session_id = "session-1",
            .session_path = "/tmp/session.jsonl",
            .start_epoch_s = 99,
            .end_epoch_s = 110,
        },
        .all,
    );
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "\"schema\":\"SEQ-ACTKERNEL-v1\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "\"recurrent_example_only_violations\":1") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "\"owner_local_implementation_covered\":0") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "\"owner_local_implementation_missing\":1") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"effect_records\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"closure_established\":false") != null);
    try std.testing.expect(try hasStrictFailure(std.testing.allocator, rendered));
}

test "kernel strict audit fails when no session Evidence is bound" {
    const store = try testEvidenceStoreAlloc(std.testing.allocator);
    defer std.testing.allocator.free(store);
    const no_digests = [_][]const u8{};
    const rendered = try auditEvidenceBytesAlloc(
        std.testing.allocator,
        store,
        "/tmp/evidence.jsonl",
        "goal-1",
        .{
            .session_id = "session-1",
            .session_path = "/tmp/session.jsonl",
            .start_epoch_s = 99,
            .end_epoch_s = 110,
        },
        .{ .digests = &no_digests },
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"event_count\":0") != null);
    try std.testing.expect(try hasStrictFailure(std.testing.allocator, rendered));
}

test "kernel audit evaluates inherited proof debt for a bound session" {
    const store = try testEvidenceStoreAlloc(std.testing.allocator);
    defer std.testing.allocator.free(store);
    const rendered = try auditEvidenceBytesAlloc(
        std.testing.allocator,
        store,
        "/tmp/evidence.jsonl",
        "goal-1",
        .{
            .session_id = "session-1",
            .session_path = "/tmp/session.jsonl",
            .start_epoch_s = 105,
            .end_epoch_s = 105,
        },
        .all,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"event_count\":1") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "\"owner_local_implementation_missing\":1") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "\"recurrent_example_only_violations\":1") != null,
    );
}

test "kernel audit rejects interior blank Evidence records" {
    const event = try testEventAlloc(
        std.testing.allocator,
        1,
        GenesisDigest,
        "goal_contract_registered",
        100,
        "{\"artifact\":{\"payload\":{},\"schema\":\"goal-contract/v3\"}}",
    );
    defer event.deinit(std.testing.allocator);
    const store = try std.fmt.allocPrint(std.testing.allocator, "{s}\n\n{s}", .{
        event.bytes,
        event.bytes,
    });
    defer std.testing.allocator.free(store);
    try std.testing.expectError(
        error.BlankEvidenceRecord,
        auditEvidenceBytesAlloc(
            std.testing.allocator,
            store,
            "/tmp/evidence.jsonl",
            "goal-1",
            .{
                .session_id = "session-1",
                .session_path = "/tmp/session.jsonl",
                .start_epoch_s = null,
                .end_epoch_s = null,
            },
            .all,
        ),
    );
}

test "kernel audit delegates complete store admission to Ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "evidence.jsonl",
        .data = "{}\n",
    });
    const evidence_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "evidence.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(evidence_path);
    try std.testing.expectError(
        error.UnexpectedField,
        auditEvidenceStoreAlloc(
            std.testing.allocator,
            evidence_path,
            "goal-1",
            .{
                .session_id = "session-1",
                .session_path = "/tmp/session.jsonl",
                .start_epoch_s = null,
                .end_epoch_s = null,
            },
            &.{},
        ),
    );
}

test "kernel audit filters non-monotonic timestamps per event" {
    const effect_body =
        "{\"changed_paths\":[\"src/main.zig\"],\"pre_effect_subject_digest\":\"" ++
        TestChangedDigest ++
        "\",\"schema\":\"effect-recorded/v1\",\"step_id\":\"edit-1\"}";
    const timestamps = [_]i64{ 100, 200, 105 };
    const kinds = [_][]const u8{
        "goal_contract_registered",
        "effect_recorded",
        "effect_recorded",
    };
    const bodies = [_][]const u8{
        "{\"artifact\":{\"payload\":{},\"schema\":\"goal-contract/v3\"}}",
        effect_body,
        effect_body,
    };
    var events: [3]TestEvent = undefined;
    var initialized: usize = 0;
    defer for (events[0..initialized]) |event| event.deinit(std.testing.allocator);
    var previous: []const u8 = GenesisDigest;
    var store: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer store.deinit();
    for (events[0..], 0..) |*event, index| {
        event.* = try testEventAlloc(
            std.testing.allocator,
            index + 1,
            previous,
            kinds[index],
            timestamps[index],
            bodies[index],
        );
        initialized += 1;
        previous = event.digest;
        try store.writer.writeAll(event.bytes);
        try store.writer.writeByte('\n');
    }
    const rendered = try auditEvidenceBytesAlloc(
        std.testing.allocator,
        store.written(),
        "/tmp/evidence.jsonl",
        "goal-1",
        .{
            .session_id = "session-1",
            .session_path = "/tmp/session.jsonl",
            .start_epoch_s = 99,
            .end_epoch_s = 110,
        },
        .all,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"effect_records\":1") != null);
}

test "kernel audit preserves causal state through the last bound event" {
    var envelope = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"subject_digest\":null}",
        .{},
    );
    defer envelope.deinit();
    const object = try asObject(envelope.value);
    const events = [_]VerifiedEvent{
        .{
            .object = object,
            .kind = "operation_prepared",
            .body = .null,
            .event_digest = TestSetOneDigest,
            .recorded_at = 100,
        },
        .{
            .object = object,
            .kind = "goal_contract_registered",
            .body = .null,
            .event_digest = TestSetTwoDigest,
            .recorded_at = 200,
        },
        .{
            .object = object,
            .kind = "operation_prepared",
            .body = .null,
            .event_digest = TestChangedDigest,
            .recorded_at = 105,
        },
    };
    const digests = [_][]const u8{TestChangedDigest};
    const binding: EventBinding = .{ .digests = &digests };
    const last_bound = lastBoundEventIndex(&events, binding);
    try std.testing.expectEqual(@as(?usize, 2), last_bound);
    var state = AuditState{ .allocator = std.testing.allocator };
    defer state.classes.deinit(std.testing.allocator);
    try state.classes.append(std.testing.allocator, .{
        .class_id = "class-1",
        .boundary_key = "boundary",
        .law_ref = "law-1",
        .owner_boundary = "src",
        .severity = "medium",
        .status = "accepted",
        .set_ref = TestSetOneDigest,
        .occurrences = 1,
    });
    for (events, 0..) |event, index| {
        try applyWindowEvent(&state, event, .{
            .session_id = "session-1",
            .session_path = "/tmp/session.jsonl",
            .start_epoch_s = 99,
            .end_epoch_s = 110,
        }, binding, index <= last_bound.?);
    }
    try std.testing.expectEqual(@as(usize, 0), state.classes.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.counts.window_events);
    try std.testing.expectEqual(@as(usize, 2), state.counts.timestamp_overlap_events);
}

test "kernel audit counts only Evidence receipts bound to the selected session" {
    var envelope = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"subject_digest\":null}",
        .{},
    );
    defer envelope.deinit();
    var state = AuditState{ .allocator = std.testing.allocator };
    defer state.classes.deinit(std.testing.allocator);
    const digests = [_][]const u8{TestSetOneDigest};
    for ([_][]const u8{ TestSetOneDigest, TestSetTwoDigest }) |digest| {
        try applyWindowEvent(
            &state,
            .{
                .object = try asObject(envelope.value),
                .kind = "operation_prepared",
                .body = .null,
                .event_digest = digest,
                .recorded_at = 100,
            },
            .{
                .session_id = "session-1",
                .session_path = "/tmp/session.jsonl",
                .start_epoch_s = 99,
                .end_epoch_s = 101,
            },
            .{ .digests = &digests },
            true,
        );
    }
    try std.testing.expectEqual(@as(usize, 1), state.counts.window_events);
    try std.testing.expectEqual(@as(usize, 1), state.counts.operation_prepared);
    try std.testing.expectEqual(@as(usize, 2), state.counts.timestamp_overlap_events);
    try std.testing.expectEqual(@as(usize, 1), state.counts.session_unbound_overlap_events);
}

test "kernel audit validates tuple digests outside the session window" {
    for ([_][]const u8{
        "{\"construction_ref\":\"bad\",\"subject_digest\":null}",
        "{\"construction_ref\":null,\"subject_digest\":\"bad\"}",
    }) |input| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidDigest,
            validateTupleDigests(try asObject(parsed.value)),
        );
    }
}

test "kernel audit accepts Ledger's uppercase digest hex" {
    try requireDigest("sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
}

test "kernel audit binds Construction envelope to artifact identity" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        TestBodies[1],
        .{},
    );
    defer parsed.deinit();
    var counts = Counts{};
    try std.testing.expectError(
        error.ConstructionRefMismatch,
        auditConstruction(parsed.value, TestSetOneDigest, &.{}, null, &counts),
    );
}

test "kernel audit preserves complete Counterexample class identity" {
    var first = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        TestBodies[2],
        .{},
    );
    defer first.deinit();
    const drift_bytes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestBodies[3],
        "\"boundary_key\":\"boundary\"",
        "\"boundary_key\":\"other\"",
    );
    defer std.testing.allocator.free(drift_bytes);
    var drift = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        drift_bytes,
        .{},
    );
    defer drift.deinit();
    var classes: std.ArrayList(ClassState) = .empty;
    defer classes.deinit(std.testing.allocator);
    var counts = Counts{};
    _ = try applyCounterexampleSet(
        std.testing.allocator,
        &classes,
        first.value,
        true,
        &counts,
    );
    try std.testing.expectError(
        error.CounterexampleIdentityDrift,
        applyCounterexampleSet(
            std.testing.allocator,
            &classes,
            drift.value,
            true,
            &counts,
        ),
    );
}

test "kernel audit rejects every legacy Construction schema" {
    for ([_][]const u8{ "construction-contract/v1", "construction-contract/v2" }) |schema| {
        const body = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"artifact\":{{\"artifact_id\":\"{s}\",\"payload\":{{}},\"schema\":\"{s}\"}}}}",
            .{ TestConstructionDigest, schema },
        );
        defer std.testing.allocator.free(body);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            body,
            .{},
        );
        defer parsed.deinit();
        var counts = Counts{};
        try std.testing.expectError(
            error.LegacyConstructionUnsupported,
            auditConstruction(parsed.value, TestConstructionDigest, &.{}, null, &counts),
        );
    }
}

test "kernel audit rejects proof coverage from another owner" {
    const body = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestBodies[4],
        "\"owner_boundary\":\"src\"",
        "\"owner_boundary\":\"other-owner\"",
    );
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        body,
        .{},
    );
    defer parsed.deinit();
    const classes = [_]ClassState{.{
        .class_id = "class-1",
        .boundary_key = "boundary",
        .law_ref = "law-1",
        .owner_boundary = "src",
        .severity = "medium",
        .status = "accepted",
        .set_ref = TestSetOneDigest,
        .occurrences = 1,
    }};
    var counts = Counts{};
    try auditConstruction(
        parsed.value,
        TestConstructionDigest,
        &classes,
        TestSetOneDigest,
        &counts,
    );
    try std.testing.expectEqual(@as(usize, 0), counts.owner_local_covered);
    try std.testing.expectEqual(@as(usize, 1), counts.owner_local_missing);
}

test "kernel strict audit observes the latest Counterexample Set binding" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        TestBodies[4],
        .{},
    );
    defer parsed.deinit();
    const classes = [_]ClassState{.{
        .class_id = "class-1",
        .boundary_key = "boundary",
        .law_ref = "law-1",
        .owner_boundary = "src",
        .severity = "medium",
        .status = "accepted",
        .set_ref = TestSetOneDigest,
        .occurrences = 1,
    }};
    var counts = Counts{};
    try auditConstruction(
        parsed.value,
        TestConstructionDigest,
        &classes,
        TestSetOneDigest,
        &counts,
    );
    try std.testing.expect(!counts.current_review_binding);
    try auditConstruction(
        parsed.value,
        TestConstructionDigest,
        &classes,
        TestSetTwoDigest,
        &counts,
    );
    try std.testing.expect(counts.current_review_binding);
}

test "kernel strict audit resolves the surface completeness proof" {
    const body = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestBodies[4],
        "\"surface_completeness_proof_ref\":\"proof-1\"",
        "\"surface_completeness_proof_ref\":\"not-a-proof\"",
    );
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        body,
        .{},
    );
    defer parsed.deinit();
    var counts = Counts{};
    try auditConstruction(
        parsed.value,
        TestConstructionDigest,
        &.{},
        TestSetOneDigest,
        &counts,
    );
    try std.testing.expect(!counts.surface_completeness_bound);
}

test "kernel audit rechecks active proof when a class recurs" {
    var construction = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        TestBodies[4],
        .{},
    );
    defer construction.deinit();
    var recurrence = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        TestBodies[3],
        .{},
    );
    defer recurrence.deinit();
    var envelope = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"subject_digest\":null}",
        .{},
    );
    defer envelope.deinit();
    var state = AuditState{ .allocator = std.testing.allocator };
    defer state.classes.deinit(std.testing.allocator);
    try state.classes.append(std.testing.allocator, .{
        .class_id = "class-1",
        .boundary_key = "boundary",
        .law_ref = "law-1",
        .owner_boundary = "src",
        .severity = "medium",
        .status = "accepted",
        .set_ref = TestSetOneDigest,
        .occurrences = 1,
    });
    state.current_construction = construction.value;
    state.current_construction_ref = TestConstructionDigest;
    try auditConstruction(
        construction.value,
        TestConstructionDigest,
        state.classes.items,
        TestSetOneDigest,
        &state.counts,
    );
    try applyWindowEvent(&state, .{
        .object = try asObject(envelope.value),
        .kind = "counterexample_set_registered",
        .body = recurrence.value,
        .event_digest = TestSetTwoDigest,
        .recorded_at = 100,
    }, .{
        .session_id = "session-1",
        .session_path = "/tmp/session.jsonl",
        .start_epoch_s = null,
        .end_epoch_s = null,
    }, .all, true);
    try std.testing.expectEqual(@as(usize, 1), state.counts.owner_local_missing);
    try std.testing.expectEqual(@as(usize, 1), state.counts.recurrent_example_only);
}

test "kernel audit exposes accepted proof debt without a Construction" {
    var counterexamples = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        TestBodies[2],
        .{},
    );
    defer counterexamples.deinit();
    var envelope = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"subject_digest\":null}",
        .{},
    );
    defer envelope.deinit();
    var state = AuditState{ .allocator = std.testing.allocator };
    defer state.classes.deinit(std.testing.allocator);
    try applyWindowEvent(&state, .{
        .object = try asObject(envelope.value),
        .kind = "counterexample_set_registered",
        .body = counterexamples.value,
        .event_digest = TestSetTwoDigest,
        .recorded_at = 100,
    }, .{
        .session_id = "session-1",
        .session_path = "/tmp/session.jsonl",
        .start_epoch_s = null,
        .end_epoch_s = null,
    }, .all, true);
    try std.testing.expectEqual(@as(usize, 1), state.counts.accepted_class_checks);
    try std.testing.expectEqual(@as(usize, 1), state.counts.owner_local_missing);
}

test "kernel audit resets Counterexample state at Goal successors" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"subject_digest\":null}",
        .{},
    );
    defer parsed.deinit();
    var state = AuditState{ .allocator = std.testing.allocator };
    try state.classes.append(std.testing.allocator, .{
        .class_id = "class-1",
        .boundary_key = "boundary",
        .law_ref = "law-1",
        .owner_boundary = "src",
        .severity = "medium",
        .status = "accepted",
        .set_ref = TestSetOneDigest,
        .occurrences = 1,
    });
    defer state.classes.deinit(std.testing.allocator);
    try applyWindowEvent(
        &state,
        .{
            .object = try asObject(parsed.value),
            .kind = "goal_contract_registered",
            .body = .null,
            .event_digest = TestSetTwoDigest,
            .recorded_at = 100,
        },
        .{
            .session_id = "session-1",
            .session_path = "/tmp/session.jsonl",
            .start_epoch_s = null,
            .end_epoch_s = null,
        },
        .all,
        true,
    );
    try std.testing.expectEqual(@as(usize, 0), state.classes.items.len);
}

test "kernel audit enforces Ledger event count ceiling" {
    var state = AuditState{ .allocator = std.testing.allocator };
    state.counts.total_events = MaxEvents;
    try std.testing.expectError(error.TooManyEvents, recordValidatedEvent(&state));
}

test "kernel audit rejects a corrupted Evidence digest" {
    var event = try testEventAlloc(
        std.testing.allocator,
        1,
        GenesisDigest,
        "goal_contract_registered",
        100,
        "{\"artifact\":{\"payload\":{},\"schema\":\"goal-contract/v3\"}}",
    );
    defer event.deinit(std.testing.allocator);
    const marker = "\"event_digest\":\"sha256:";
    const offset = (std.mem.indexOf(u8, event.bytes, marker) orelse unreachable) + marker.len;
    event.bytes[offset] = if (event.bytes[offset] == '0') '1' else '0';
    try std.testing.expectError(
        error.EvidenceEventDigestMismatch,
        auditEvidenceBytesAlloc(
            std.testing.allocator,
            event.bytes,
            "/tmp/evidence.jsonl",
            "goal-1",
            .{
                .session_id = "session-1",
                .session_path = "/tmp/session.jsonl",
                .start_epoch_s = null,
                .end_epoch_s = null,
            },
            .all,
        ),
    );
}
