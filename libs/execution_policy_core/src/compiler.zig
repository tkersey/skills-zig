const std = @import("std");
const atom = @import("atom.zig");
const canonical_json = @import("canonical_json.zig");
const errors = @import("errors.zig");
const schema = @import("schema.zig");
const validation = @import("validation.zig");

pub const CompiledPolicy = opaque {
    pub fn deinit(self: *CompiledPolicy, allocator: std.mem.Allocator) void {
        const impl = policyImplMut(self);
        impl.deinit(allocator);
        allocator.destroy(impl);
    }

    pub fn digest(self: *const CompiledPolicy) []const u8 {
        return policyImpl(self).source_digest_.text;
    }

    pub fn initialState(self: *const CompiledPolicy, allocator: std.mem.Allocator) !?schema.State {
        const state = policyImpl(self).initial_state_ orelse return null;
        return try schema.parseArtifact(schema.State, allocator, state.raw_json);
    }
};

const CompiledPolicyImpl = struct {
    source_: schema.Policy,
    runtime_: schema.Policy,
    source_digest_: canonical_json.Digest,
    initial_state_: ?schema.State,

    fn deinit(self: *CompiledPolicyImpl, allocator: std.mem.Allocator) void {
        self.source_.deinit(allocator);
        self.runtime_.deinit(allocator);
        self.source_digest_.deinit(allocator);
        if (self.initial_state_) |*state| state.deinit(allocator);
        self.* = undefined;
    }
};

pub const CompileResult = union(enum) {
    policy: *CompiledPolicy,
    report: errors.ValidationReport,

    pub fn deinit(self: *CompileResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .policy => |policy| policy.deinit(allocator),
            .report => |*report| report.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub fn compile(allocator: std.mem.Allocator, bytes: []const u8) !CompileResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return .{ .report = try singleError(allocator, .schema_invalid, "$") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .report = try singleError(allocator, .schema_invalid, "$") };
    }

    const outer = parsed.value.object;
    if (outer.get("execution_policy_graph")) |wrapped| {
        if (outer.count() != 1) {
            return .{ .report = try singleError(allocator, .schema_invalid, "$") };
        }
        if (wrapped != .object) {
            return .{
                .report = try singleError(
                    allocator,
                    .schema_invalid,
                    "$.execution_policy_graph",
                ),
            };
        }
        return compileRich(allocator, wrapped);
    }
    if (stringField(outer, "policy_version")) |version| {
        if (std.mem.eql(u8, version, "EPG-v1")) return compileRich(allocator, parsed.value);
    }
    return compileLegacy(allocator, bytes);
}

pub fn runtimePolicy(policy: *const CompiledPolicy) *const schema.Policy {
    return &policyImpl(policy).runtime_;
}

fn compileLegacy(allocator: std.mem.Allocator, bytes: []const u8) !CompileResult {
    var source = schema.parseArtifact(schema.Policy, allocator, bytes) catch {
        return .{ .report = try singleError(allocator, .schema_invalid, "$") };
    };
    errdefer source.deinit(allocator);

    var report = try validation.validatePolicy(allocator, &source);
    if (!report.ok()) {
        source.deinit(allocator);
        return .{ .report = report };
    }
    report.deinit(allocator);

    var runtime = try schema.parseArtifact(schema.Policy, allocator, bytes);
    errdefer runtime.deinit(allocator);
    const digest = try canonical_json.digestRawJson(allocator, source.raw_json);
    return .{ .policy = try createCompiledPolicy(allocator, .{
        .source_ = source,
        .runtime_ = runtime,
        .source_digest_ = digest,
        .initial_state_ = null,
    }) };
}

fn compileRich(allocator: std.mem.Allocator, rich_value: std.json.Value) !CompileResult {
    var report = try validateRich(allocator, rich_value.object);
    if (!report.ok()) return .{ .report = report };
    report.deinit(allocator);

    const source_json = try canonical_json.canonicalizeValueAlloc(allocator, rich_value);
    defer allocator.free(source_json);
    var source = try schema.parseArtifact(schema.Policy, allocator, source_json);
    errdefer source.deinit(allocator);

    const runtime_json = try lowerRich(allocator, rich_value.object);
    defer allocator.free(runtime_json);
    var runtime = try schema.parseArtifact(schema.Policy, allocator, runtime_json);
    errdefer runtime.deinit(allocator);

    var runtime_report = try validation.validateCompiledRuntimePolicy(allocator, &runtime);
    if (!runtime_report.ok()) {
        source.deinit(allocator);
        runtime.deinit(allocator);
        return .{ .report = runtime_report };
    }
    runtime_report.deinit(allocator);

    var digest = try canonical_json.digestRawJson(allocator, source.raw_json);
    errdefer digest.deinit(allocator);
    var state = try lowerInitialState(allocator, rich_value.object, digest.text);
    errdefer if (state) |*value| value.deinit(allocator);
    return .{ .policy = try createCompiledPolicy(allocator, .{
        .source_ = source,
        .runtime_ = runtime,
        .source_digest_ = digest,
        .initial_state_ = state,
    }) };
}

fn createCompiledPolicy(allocator: std.mem.Allocator, value: CompiledPolicyImpl) !*CompiledPolicy {
    const impl = try allocator.create(CompiledPolicyImpl);
    impl.* = value;
    return @ptrCast(impl);
}

fn policyImpl(policy: *const CompiledPolicy) *const CompiledPolicyImpl {
    return @ptrCast(@alignCast(policy));
}

fn policyImplMut(policy: *CompiledPolicy) *CompiledPolicyImpl {
    return @ptrCast(@alignCast(policy));
}

const Factor = struct {
    id: []const u8,
    disposition: []const u8,
    realized: bool = false,
    retired: bool = false,
};

const RichIds = struct {
    obligations: []const []const u8,
    facts: []const []const u8,
    unknowns: []const []const u8,
    observations: []const []const u8,
    actions: []const []const u8,
};

const ArchitectonicState = struct {
    seam_ids: []const []const u8,
    factors: []Factor,
};

const seam_authorities = [_][]const u8{
    "source_fixed",
    "source_bounded",
    "plan_local",
};
const seam_axes = [_][]const u8{
    "data_shape",
    "behavior",
    "syntax_semantics",
    "composition",
    "representation",
    "ownership",
    "context",
    "transport",
    "proof",
};
const typed_holes = [_][]const u8{
    "object",
    "map",
    "representation",
    "interpreter",
    "composition",
    "equivalence",
    "owner",
    "proof",
};
const factor_statuses = [_][]const u8{
    "live",
    "moved",
    "expired",
    "duplicated",
    "invalid",
    "unknown",
};
const factor_dispositions = [_][]const u8{
    "preserve",
    "factor",
    "quotient",
    "ablate",
    "normalize",
    "introduce",
};

fn validateRich(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) !errors.ValidationReport {
    var builder = errors.Builder.init(allocator);
    defer builder.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    try validateRichEnvelope(&builder, root, temp);
    const ids = try collectRichIds(temp, &builder, root);
    try validateRegimeShape(&builder, root, ids.observations);
    if (try validateArchitectonic(&builder, root, ids, temp)) |state| {
        try validateRichActions(&builder, root, ids, state, temp);
    }
    try validatePolicyRules(&builder, root, ids.actions, temp);
    try validateObservationOutcomes(&builder, root, temp);
    try validateUnknownAndObligationCoverage(&builder, root, ids.obligations);
    try validateRiskShields(&builder, root, ids.actions, temp);
    try validateConditions(&builder, root, temp);
    try validateSquareResults(&builder, root);
    try validateLoweringShape(&builder, root, temp);
    return builder.finish();
}

fn validateRichEnvelope(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !void {
    if (!stringEquals(root, "policy_version", "EPG-v1")) {
        try builder.add(.schema_invalid, "$.policy_version");
    }
    try requireString(builder, root, "policy_id", "$.policy_id");
    try requireString(builder, root, "plan_id", "$.plan_id");
    try requireInteger(builder, root, "revision", "$.revision");
    if (root.get("gate") != null) {
        try builder.add(.self_certification_forbidden, "$.gate");
    }
    if (root.get("handoff") != null) {
        try builder.add(.self_certification_forbidden, "$.handoff");
    }
    try validateSourceShape(builder, root);
    try validateHorizonShape(builder, root);
    try validateChallengeShape(builder, root);
    try validateInvalidatorsShape(builder, root, allocator);
    try validateRevisionShape(builder, root, allocator);
}

fn collectRichIds(
    allocator: std.mem.Allocator,
    builder: *errors.Builder,
    root: std.json.ObjectMap,
) !RichIds {
    const goal = objectField(root, "goal");
    if (goal == null) try builder.add(.schema_invalid, "$.goal");
    const obligations = if (goal) |value|
        try collectIds(
            allocator,
            builder,
            arrayField(value, "obligations"),
            "obligation_id",
            "$.goal.obligations",
        )
    else
        &.{};
    const belief = objectField(root, "belief");
    if (belief == null) try builder.add(.schema_invalid, "$.belief");
    const facts = if (belief) |value|
        try collectIds(
            allocator,
            builder,
            arrayField(value, "facts"),
            "fact_id",
            "$.belief.facts",
        )
    else
        &.{};
    const unknowns = if (belief) |value|
        try collectIds(
            allocator,
            builder,
            arrayField(value, "unknowns"),
            "unknown_id",
            "$.belief.unknowns",
        )
    else
        &.{};
    return .{
        .obligations = obligations,
        .facts = facts,
        .unknowns = unknowns,
        .observations = try collectIds(
            allocator,
            builder,
            arrayField(root, "observations"),
            "observation_id",
            "$.observations",
        ),
        .actions = try collectIds(
            allocator,
            builder,
            arrayField(root, "actions"),
            "action_id",
            "$.actions",
        ),
    };
}

fn validateArchitectonic(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    ids: RichIds,
    allocator: std.mem.Allocator,
) !?ArchitectonicState {
    var seam_ids: std.ArrayList([]const u8) = .empty;
    var factors: std.ArrayList(Factor) = .empty;
    const architectonic = objectField(root, "architectonic") orelse {
        try builder.add(.architectonic_incomplete, "$.architectonic");
        return null;
    };
    const seams = arrayField(architectonic, "seams") orelse {
        try builder.add(.architectonic_incomplete, "$.architectonic.seams");
        return null;
    };
    if (seams.len == 0) {
        try builder.add(.architectonic_incomplete, "$.architectonic.seams");
    }
    for (seams, 0..) |value, index| {
        try validateSeam(
            builder,
            value,
            index,
            ids,
            &seam_ids,
            &factors,
            allocator,
        );
    }
    try validateIncumbentFactorRefs(builder, seams, factors.items, allocator);
    try validateArchitectonicComposition(
        builder,
        architectonic,
        seam_ids.items,
        allocator,
    );
    try validateConceptualCompression(
        builder,
        architectonic,
        ids.obligations,
        factors.items,
        allocator,
    );
    return .{ .seam_ids = seam_ids.items, .factors = factors.items };
}

fn validateSeam(
    builder: *errors.Builder,
    value: std.json.Value,
    index: usize,
    ids: RichIds,
    seam_ids: *std.ArrayList([]const u8),
    factors: *std.ArrayList(Factor),
    allocator: std.mem.Allocator,
) !void {
    const path = try std.fmt.allocPrint(
        allocator,
        "$.architectonic.seams[{d}]",
        .{index},
    );
    if (value != .object) {
        try builder.add(.schema_invalid, path);
        return;
    }
    const seam = value.object;
    const id = stringField(seam, "seam_id") orelse {
        try builder.add(.schema_invalid, try suffix(allocator, path, ".seam_id"));
        return;
    };
    atom.validateStableId(id) catch {
        try builder.add(.atom_invalid, try suffix(allocator, path, ".seam_id"));
    };
    if (contains(seam_ids.items, id)) {
        try builder.add(.id_duplicate, try suffix(allocator, path, ".seam_id"));
    } else {
        try seam_ids.append(allocator, id);
    }
    try validateSeamShape(builder, seam, path, ids, allocator);
    try validateSeamFactors(
        builder,
        seam,
        path,
        ids.obligations,
        factors,
        allocator,
    );
}

fn validateSeamShape(
    builder: *errors.Builder,
    seam: std.json.ObjectMap,
    path: []const u8,
    ids: RichIds,
    allocator: std.mem.Allocator,
) !void {
    if (!oneOf(stringField(seam, "authority"), &seam_authorities)) {
        try builder.add(.schema_invalid, try suffix(allocator, path, ".authority"));
    }
    if (!oneOf(stringField(seam, "axis"), &seam_axes)) {
        try builder.add(.schema_invalid, try suffix(allocator, path, ".axis"));
    }
    if (!oneOf(stringField(seam, "typed_hole"), &typed_holes)) {
        try builder.add(.schema_invalid, try suffix(allocator, path, ".typed_hole"));
    }
    try validateRefField(
        builder,
        seam,
        "live_obligation_refs",
        ids.obligations,
        path,
        allocator,
    );
    try validateRefField(
        builder,
        seam,
        "required_observation_refs",
        ids.observations,
        path,
        allocator,
    );
    try validateRefField(
        builder,
        seam,
        "decision_observation_refs",
        ids.observations,
        path,
        allocator,
    );
    inline for ([_][]const u8{
        "compatibility_and_migration",
        "host_capabilities",
        "residual_obligations",
        "invalidators",
    }) |key| {
        try requireStringArray(
            builder,
            seam,
            key,
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key }),
        );
    }
    try validateSeamSelection(builder, seam, path, allocator);
}

fn validateRefField(
    builder: *errors.Builder,
    object: std.json.ObjectMap,
    key: []const u8,
    allowed: []const []const u8,
    base_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ base_path, key },
    );
    try requireStringArray(builder, object, key, path);
    try validateStringRefs(builder, stringValues(object, key), allowed, path);
}

fn validateSeamSelection(
    builder: *errors.Builder,
    seam: std.json.ObjectMap,
    path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const incumbent = objectField(seam, "incumbent");
    if (incumbent == null or emptyStringField(incumbent.?, "organization")) {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".incumbent"),
        );
    } else {
        try requireStringArray(
            builder,
            incumbent.?,
            "factor_refs",
            try suffix(allocator, path, ".incumbent.factor_refs"),
        );
    }
    const movements = objectField(seam, "candidate_movements");
    if (movements == null or emptyStringField(movements.?, "preserve") or
        emptyStringField(movements.?, "restrict_admitted_domain") or
        emptyStringField(movements.?, "strengthen_representation_or_owner") or
        emptyStringField(movements.?, "ablate_or_normalize"))
    {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".candidate_movements"),
        );
    }
    const disposition = stringField(seam, "disposition");
    if (!oneOf(disposition, &.{ "selected", "evidence_conditioned" })) {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".disposition"),
        );
    }
    try validateSelectedOrganization(builder, seam, path, disposition, allocator);
    if (emptyStringField(seam, "law")) {
        try builder.add(.architectonic_incomplete, try suffix(allocator, path, ".law"));
    }
    if (emptyStringField(seam, "falsifier")) {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".falsifier"),
        );
    }
    const boundary = objectField(seam, "boundary");
    if (boundary == null or emptyStringField(boundary.?, "owner") or
        emptyStringField(boundary.?, "source") or
        emptyStringField(boundary.?, "target"))
    {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".boundary"),
        );
    }
}

fn validateSelectedOrganization(
    builder: *errors.Builder,
    seam: std.json.ObjectMap,
    path: []const u8,
    disposition: ?[]const u8,
    allocator: std.mem.Allocator,
) !void {
    const selected = disposition == null or
        std.mem.eql(u8, disposition.?, "selected") or
        std.mem.eql(u8, disposition.?, "evidence_conditioned");
    if (selected and emptyStringField(seam, "selected_organization")) {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".selected_organization"),
        );
    }
    if (disposition != null and
        std.mem.eql(u8, disposition.?, "evidence_conditioned") and
        emptyArrayField(seam, "decision_observation_refs"))
    {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".decision_observation_refs"),
        );
    }
}

fn validateSeamFactors(
    builder: *errors.Builder,
    seam: std.json.ObjectMap,
    path: []const u8,
    obligation_ids: []const []const u8,
    factors: *std.ArrayList(Factor),
    allocator: std.mem.Allocator,
) !void {
    const rows = arrayField(seam, "factors") orelse {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".factors"),
        );
        return;
    };
    if (rows.len == 0) {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".factors"),
        );
    }
    for (rows, 0..) |value, index| {
        const factor_path = try std.fmt.allocPrint(
            allocator,
            "{s}.factors[{d}]",
            .{ path, index },
        );
        try validateFactor(
            builder,
            value,
            factor_path,
            obligation_ids,
            factors,
            allocator,
        );
    }
}

fn validateFactor(
    builder: *errors.Builder,
    value: std.json.Value,
    path: []const u8,
    obligation_ids: []const []const u8,
    factors: *std.ArrayList(Factor),
    allocator: std.mem.Allocator,
) !void {
    if (value != .object) {
        try builder.add(.schema_invalid, path);
        return;
    }
    const factor = value.object;
    const id = stringField(factor, "factor_id") orelse {
        try builder.add(.schema_invalid, try suffix(allocator, path, ".factor_id"));
        return;
    };
    atom.validateStableId(id) catch {
        try builder.add(.atom_invalid, try suffix(allocator, path, ".factor_id"));
    };
    if (factorIndex(factors.items, id) != null) {
        try builder.add(.id_duplicate, try suffix(allocator, path, ".factor_id"));
        return;
    }
    if (emptyStringField(factor, "owner")) {
        try builder.add(
            .architectonic_incomplete,
            try suffix(allocator, path, ".owner"),
        );
    }
    if (!oneOf(stringField(factor, "obligation_status"), &factor_statuses)) {
        try builder.add(
            .schema_invalid,
            try suffix(allocator, path, ".obligation_status"),
        );
    }
    const disposition = stringField(factor, "disposition") orelse "";
    if (!oneOf(disposition, &factor_dispositions)) {
        try builder.add(
            .schema_invalid,
            try suffix(allocator, path, ".disposition"),
        );
    }
    const live_refs = stringValues(factor, "live_obligation_refs");
    if (factorRetained(disposition) and live_refs.len == 0) {
        try builder.add(
            .factor_unearned,
            try suffix(allocator, path, ".live_obligation_refs"),
        );
    }
    try validateStringRefs(
        builder,
        live_refs,
        obligation_ids,
        try suffix(allocator, path, ".live_obligation_refs"),
    );
    try factors.append(allocator, .{ .id = id, .disposition = disposition });
}

fn validateIncumbentFactorRefs(
    builder: *errors.Builder,
    seams: []const std.json.Value,
    factors: []const Factor,
    allocator: std.mem.Allocator,
) !void {
    for (seams, 0..) |value, index| {
        if (value != .object) continue;
        const incumbent = objectField(value.object, "incumbent") orelse continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "$.architectonic.seams[{d}].incumbent.factor_refs",
            .{index},
        );
        for (stringValues(incumbent, "factor_refs")) |ref_value| {
            const ref = valueString(ref_value) orelse continue;
            if (factorIndex(factors, ref) == null) {
                try builder.add(.reference_unknown, path);
            }
        }
    }
}

fn validateRichActions(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    ids: RichIds,
    state: ArchitectonicState,
    allocator: std.mem.Allocator,
) !void {
    const actions = arrayField(root, "actions") orelse &.{};
    const seam_bound = try allocator.alloc(bool, state.seam_ids.len);
    @memset(seam_bound, false);
    for (actions, 0..) |value, index| {
        if (value != .object) continue;
        const action = value.object;
        const path = try std.fmt.allocPrint(
            allocator,
            "$.actions[{d}]",
            .{index},
        );
        const action_id = stringField(action, "action_id") orelse continue;
        try validateActionBindings(
            builder,
            action,
            action_id,
            path,
            ids,
            state,
            seam_bound,
            allocator,
        );
        try validateActionEffects(builder, action, path, ids, allocator);
    }
    for (seam_bound) |bound| {
        if (!bound) try builder.add(
            .architectonic_unbound,
            "$.architectonic.seams",
        );
    }
    for (state.factors) |factor| {
        const needs_realization = std.mem.eql(u8, factor.disposition, "factor") or
            std.mem.eql(u8, factor.disposition, "introduce");
        if (needs_realization and !factor.realized) {
            try builder.add(.factor_unearned, "$.architectonic.seams.factors");
        }
        if (!factorRetained(factor.disposition) and !factor.retired) {
            try builder.add(
                .factor_disposition_conflict,
                "$.architectonic.seams.factors",
            );
        }
    }
}

fn validateActionBindings(
    builder: *errors.Builder,
    action: std.json.ObjectMap,
    action_id: []const u8,
    path: []const u8,
    ids: RichIds,
    state: ArchitectonicState,
    seam_bound: []bool,
    allocator: std.mem.Allocator,
) !void {
    const seam_refs = stringValues(action, "architectonic_seam_refs");
    if (seam_refs.len == 0) {
        try builder.add(
            .architectonic_unbound,
            try suffix(allocator, path, ".architectonic_seam_refs"),
        );
    }
    for (seam_refs) |value| {
        const ref = valueString(value) orelse continue;
        if (indexOf(state.seam_ids, ref)) |index| {
            seam_bound[index] = true;
        } else {
            try builder.add(
                .reference_unknown,
                try suffix(allocator, path, ".architectonic_seam_refs"),
            );
        }
    }
    try validateActionFactorRefs(
        builder,
        action,
        path,
        state.factors,
        allocator,
    );
    try validateRefField(
        builder,
        action,
        "preservation_observation_refs",
        ids.observations,
        path,
        allocator,
    );
    for (stringValues(action, "requires_actions")) |value| {
        const ref = valueString(value) orelse continue;
        if (!contains(ids.actions, ref)) {
            try builder.add(
                .reference_unknown,
                try suffix(allocator, path, ".requires_actions"),
            );
        }
        if (std.mem.eql(u8, ref, action_id)) {
            try builder.add(
                .action_cycle,
                try suffix(allocator, path, ".requires_actions"),
            );
        }
    }
}

fn validateActionFactorRefs(
    builder: *errors.Builder,
    action: std.json.ObjectMap,
    path: []const u8,
    factors: []Factor,
    allocator: std.mem.Allocator,
) !void {
    for (stringValues(action, "realizes_factor_refs")) |value| {
        const ref = valueString(value) orelse continue;
        if (factorIndex(factors, ref)) |index| {
            if (!factorRetained(factors[index].disposition)) {
                try builder.add(
                    .factor_disposition_conflict,
                    try suffix(allocator, path, ".realizes_factor_refs"),
                );
            }
            factors[index].realized = true;
        } else {
            try builder.add(
                .reference_unknown,
                try suffix(allocator, path, ".realizes_factor_refs"),
            );
        }
    }
    for (stringValues(action, "retires_factor_refs")) |value| {
        const ref = valueString(value) orelse continue;
        if (factorIndex(factors, ref)) |index| {
            if (factorRetained(factors[index].disposition)) {
                try builder.add(
                    .factor_disposition_conflict,
                    try suffix(allocator, path, ".retires_factor_refs"),
                );
            }
            factors[index].retired = true;
        } else {
            try builder.add(
                .reference_unknown,
                try suffix(allocator, path, ".retires_factor_refs"),
            );
        }
    }
}

fn validateActionEffects(
    builder: *errors.Builder,
    action: std.json.ObjectMap,
    path: []const u8,
    ids: RichIds,
    allocator: std.mem.Allocator,
) !void {
    const effects = objectField(action, "expected_effects") orelse {
        try builder.add(
            .schema_invalid,
            try suffix(allocator, path, ".expected_effects"),
        );
        return;
    };
    try validateRefField(
        builder,
        effects,
        "facts_added",
        ids.facts,
        try suffix(allocator, path, ".expected_effects"),
        allocator,
    );
    try validateRefField(
        builder,
        effects,
        "unknowns_resolved",
        ids.unknowns,
        try suffix(allocator, path, ".expected_effects"),
        allocator,
    );
    try validateRefField(
        builder,
        effects,
        "obligations_closed",
        ids.obligations,
        try suffix(allocator, path, ".expected_effects"),
        allocator,
    );
    try validateRefField(
        builder,
        action,
        "expected_observation_refs",
        ids.observations,
        path,
        allocator,
    );
    try validateRefField(
        builder,
        action,
        "failure_observation_refs",
        ids.observations,
        path,
        allocator,
    );
    if (isRiskyKind(stringField(action, "kind")) and
        emptyArrayField(action, "proof_obligations"))
    {
        try builder.add(
            .proof_missing,
            try suffix(allocator, path, ".proof_obligations"),
        );
    }
}

fn validatePolicyRules(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    action_ids: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    const policy = objectField(root, "policy") orelse {
        try builder.add(.schema_invalid, "$.policy");
        return;
    };
    if (!stringEquals(policy, "selection", "lexicographic_utility")) {
        try builder.add(.schema_invalid, "$.policy.selection");
    }
    const rules = arrayField(policy, "rules") orelse {
        try builder.add(.schema_invalid, "$.policy.rules");
        return;
    };
    if (rules.len == 0) try builder.add(.policy_dead_end, "$.policy.rules");
    var priorities: std.ArrayList(i64) = .empty;
    var selected_actions: std.ArrayList([]const u8) = .empty;
    for (rules, 0..) |value, index| {
        if (value != .object) continue;
        const rule = value.object;
        const path = try std.fmt.allocPrint(
            allocator,
            "$.policy.rules[{d}]",
            .{index},
        );
        const priority = integerField(rule, "priority") orelse {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".priority"),
            );
            continue;
        };
        if (containsInt(priorities.items, priority)) {
            try builder.add(
                .id_duplicate,
                try suffix(allocator, path, ".priority"),
            );
        } else {
            try priorities.append(allocator, priority);
        }
        const candidates = stringValues(rule, "candidate_action_ids");
        for (candidates) |ref| {
            const action_ref = valueString(ref) orelse continue;
            if (!contains(action_ids, action_ref)) {
                try builder.add(
                    .reference_unknown,
                    try suffix(allocator, path, ".candidate_action_ids"),
                );
            } else if (!contains(selected_actions.items, action_ref)) {
                try selected_actions.append(allocator, action_ref);
            }
        }
        const terminal = nullableStringField(rule, "terminal");
        if (candidates.len == 0 and terminal == null) {
            try builder.add(.policy_dead_end, path);
        }
        if (candidates.len > 0 and terminal != null) {
            try builder.add(.schema_invalid, path);
        }
    }
    for (action_ids) |id| {
        if (!contains(selected_actions.items, id)) {
            try builder.add(.action_unreachable, "$.actions");
        }
    }
}

fn validateObservationOutcomes(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !void {
    const observations = arrayField(root, "observations") orelse &.{};
    for (observations, 0..) |value, index| {
        if (value != .object) continue;
        const observation = value.object;
        const id = stringField(observation, "observation_id") orelse continue;
        const outcomes = arrayField(observation, "outcomes") orelse {
            try builder.add(.schema_invalid, "$.observations.outcomes");
            continue;
        };
        if (outcomes.len == 0) try builder.add(.schema_invalid, "$.observations.outcomes");
        for (outcomes) |outcome_value| {
            if (outcome_value != .object) {
                try builder.add(.schema_invalid, "$.observations.outcomes");
                continue;
            }
            const outcome_atom = stringField(outcome_value.object, "atom") orelse "";
            const prefix = try std.fmt.allocPrint(allocator, "obs:{s}=", .{id});
            if (!std.mem.startsWith(u8, outcome_atom, prefix) or !validAtom(outcome_atom)) {
                try builder.add(
                    .atom_invalid,
                    try std.fmt.allocPrint(
                        allocator,
                        "$.observations[{d}].outcomes",
                        .{index},
                    ),
                );
            }
        }
    }
}

fn validateUnknownAndObligationCoverage(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    obligation_ids: []const []const u8,
) !void {
    const unknowns = if (objectField(root, "belief")) |belief|
        arrayField(belief, "unknowns") orelse &.{}
    else
        &.{};
    const actions = arrayField(root, "actions") orelse &.{};
    for (unknowns) |value| {
        if (value != .object) continue;
        const unknown = value.object;
        const id = stringField(unknown, "unknown_id") orelse continue;
        const urgent = oneOf(
            stringField(unknown, "urgency"),
            &.{ "critical", "high" },
        );
        if (stringEquals(unknown, "status", "open") and urgent) {
            if (emptyArrayField(unknown, "observation_refs")) {
                try builder.add(
                    .critical_unknown_unobservable,
                    "$.belief.unknowns.observation_refs",
                );
            }
            if (!actionResolves(actions, id)) {
                try builder.add(
                    .critical_unknown_unobservable,
                    "$.belief.unknowns",
                );
            }
        }
    }
    for (obligation_ids) |id| {
        if (!actionCloses(actions, id)) {
            try builder.add(.obligation_uncovered, "$.goal.obligations");
        }
    }
}

fn lowerRich(allocator: std.mem.Allocator, root: std.json.ObjectMap) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try writeNamedString(writer, "policy_id", stringField(root, "policy_id").?);
    try writer.writeAll(",\"revision\":");
    try writer.print("{d}", .{integerField(root, "revision").?});
    try writer.writeAll(",\"declared_atoms\":");
    try writeStringSlice(writer, try collectDeclaredAtoms(temp, root));
    try writer.writeAll(",\"safety_invariants\":[{\"custom_atoms\":");
    try writeCustomAtoms(writer, root, true);
    try writer.writeAll("}],\"forbidden_states\":[{\"custom_atoms\":");
    try writeCustomAtoms(writer, root, false);
    try writer.writeAll("}],\"observations\":[");
    try writeLoweredObservations(writer, root);
    try writer.writeAll("],\"actions\":[");
    try writeLoweredActions(temp, writer, root);
    try writer.writeAll("],\"policy_rules\":[");
    try writeLoweredRules(writer, root);
    try writer.writeAll("],\"terminals\":[");
    try writeLoweredTerminals(writer, root);
    try writer.writeAll("],\"potential_dimensions\":[");
    try writeLoweredDimensions(writer, root);
    try writer.writeAll("],\"safety_shield\":[");
    try writeLoweredShields(writer, root);
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn writeLoweredObservations(
    writer: *std.Io.Writer,
    root: std.json.ObjectMap,
) !void {
    const observations = arrayField(root, "observations") orelse return;
    for (observations, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        const observation = value.object;
        try writer.writeByte('{');
        try writeNamedString(
            writer,
            "id",
            stringField(observation, "observation_id").?,
        );
        try writer.writeAll(",\"outcomes\":[");
        if (arrayField(observation, "outcomes")) |outcomes| {
            for (outcomes, 0..) |outcome, outcome_index| {
                if (outcome_index > 0) try writer.writeByte(',');
                try writeJsonString(
                    writer,
                    stringField(outcome.object, "outcome").?,
                );
            }
        }
        try writer.writeAll("]}");
    }
}

fn writeLoweredActions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    root: std.json.ObjectMap,
) !void {
    for (arrayField(root, "actions").?, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try writeLoweredAction(allocator, writer, root, value.object);
    }
}

fn writeLoweredRules(
    writer: *std.Io.Writer,
    root: std.json.ObjectMap,
) !void {
    const policy = objectField(root, "policy").?;
    for (arrayField(policy, "rules").?, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        const rule = value.object;
        try writer.writeByte('{');
        try writeNamedString(writer, "id", stringField(rule, "rule_id").?);
        try writer.writeAll(",\"priority\":");
        try writer.print("{d}", .{integerField(rule, "priority").?});
        try writer.writeAll(",\"condition\":");
        try writeValue(writer, rule.get("when") orelse emptyCondition());
        try writer.writeAll(",\"actions\":");
        try writeStringArrayValue(writer, rule.get("candidate_action_ids"));
        if (nullableStringField(rule, "terminal")) |terminal| {
            try writer.writeAll(",\"terminal\":");
            try writeJsonString(writer, terminal);
        }
        try writer.writeByte('}');
    }
}

fn writeLoweredTerminals(
    writer: *std.Io.Writer,
    root: std.json.ObjectMap,
) !void {
    const terminals = objectField(root, "terminal_states").?;
    var iterator = terminals.iterator();
    var first = true;
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeByte('{');
        try writeNamedString(writer, "id", entry.key_ptr.*);
        try writer.writeAll(",\"condition\":");
        const condition_value = entry.value_ptr.object.get("when") orelse
            emptyCondition();
        try writeValue(writer, condition_value);
        try writer.writeByte('}');
    }
}

fn writeLoweredDimensions(
    writer: *std.Io.Writer,
    root: std.json.ObjectMap,
) !void {
    const potential = objectField(root, "potential").?;
    for (arrayField(potential, "dimensions").?, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        const dimension = value.object;
        try writer.writeByte('{');
        try writeNamedString(
            writer,
            "id",
            stringField(dimension, "dimension_id").?,
        );
        try writer.writeAll(",\"direction\":");
        try writeJsonString(writer, stringField(dimension, "direction").?);
        if (dimension.get("terminal_threshold")) |threshold| {
            try writer.writeAll(",\"terminal_threshold\":");
            try writeValue(writer, threshold);
        }
        try writer.writeByte('}');
    }
}

fn writeLoweredAction(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    root: std.json.ObjectMap,
    action: std.json.ObjectMap,
) !void {
    const action_id = stringField(action, "action_id").?;
    const kind = stringField(action, "kind") orelse "";
    try writer.writeByte('{');
    try writeNamedString(writer, "id", action_id);
    try writer.writeAll(",\"precondition\":");
    try writeValue(writer, action.get("preconditions") orelse emptyCondition());
    try writer.writeAll(",\"requires_actions\":");
    try writeStringArrayValue(writer, action.get("requires_actions"));
    try writer.writeAll(",\"repeatable\":");
    try writer.writeAll(if (boolField(action, "repeatable") orelse false) "true" else "false");
    if (isRiskyKind(kind)) try writer.writeAll(",\"risky\":true");
    if (std.mem.eql(u8, kind, "prove")) try writer.writeAll(",\"prove\":true");
    try writer.writeAll(",\"results\":{\"success\":");
    try writeLoweredActionResults(allocator, writer, root, action);
    try writer.writeAll(",\"failure\":[]}");
    const rollback = objectField(action, "rollback");
    if (rollback != null and nullableStringField(rollback.?, "action_id") != null) {
        try writer.writeAll(",\"rollback_actions\":[");
        try writeJsonString(writer, nullableStringField(rollback.?, "action_id").?);
        try writer.writeByte(']');
    }
    try writer.writeAll(",\"utility\":[");
    try writeLoweredActionUtility(writer, root, action);
    try writer.writeAll("]}");
}

fn writeLoweredActionResults(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    root: std.json.ObjectMap,
    action: std.json.ObjectMap,
) !void {
    var effects: std.ArrayList([]const u8) = .empty;
    const expected = objectField(action, "expected_effects").?;
    if (objectField(root, "belief")) |belief| {
        const facts = arrayField(belief, "facts") orelse &.{};
        for (stringValues(expected, "facts_added")) |fact_id_value| {
            const fact_id = valueString(fact_id_value) orelse continue;
            if (atomForId(facts, "fact_id", fact_id)) |fact_atom| {
                try appendUnique(&effects, allocator, fact_atom);
            }
        }
    }
    for (stringValues(expected, "unknowns_resolved")) |id_value| {
        const id = valueString(id_value) orelse continue;
        try appendIdAtom(
            &effects,
            allocator,
            "unknown:{s}=resolved",
            id,
        );
    }
    for (stringValues(expected, "obligations_closed")) |id_value| {
        const id = valueString(id_value) orelse continue;
        try appendIdAtom(
            &effects,
            allocator,
            "obligation:{s}=closed",
            id,
        );
    }
    try writeStringSlice(writer, effects.items);
}

fn writeLoweredActionUtility(
    writer: *std.Io.Writer,
    root: std.json.ObjectMap,
    action: std.json.ObjectMap,
) !void {
    const utility = objectField(action, "utility").?;
    const policy = objectField(root, "policy").?;
    const order = arrayField(policy, "utility_order").?;
    for (order, 0..) |order_value, index| {
        if (index > 0) try writer.writeByte(',');
        const order_object = order_value.object;
        var it = order_object.iterator();
        const entry = it.next().?;
        const key = entry.value_ptr.string;
        const raw = integerField(utility, key) orelse 0;
        const oriented = if (std.mem.eql(u8, entry.key_ptr.*, "minimize")) 100 - raw else raw;
        try writer.print("{d}", .{oriented});
    }
}

fn writeLoweredShields(writer: *std.Io.Writer, root: std.json.ObjectMap) !void {
    const shield = objectField(root, "safety_shield") orelse return;
    const rules = arrayField(shield, "rules") orelse return;
    const actions = arrayField(root, "actions") orelse &.{};
    var first = true;
    for (rules) |value| {
        if (value != .object) continue;
        const rule = value.object;
        for (actions) |action_value| {
            if (action_value != .object) continue;
            const action = action_value.object;
            const action_id = stringField(action, "action_id") orelse continue;
            const kind = stringField(action, "kind") orelse "";
            const forbidden_id = stringArrayContains(
                rule,
                "forbids_action_ids",
                action_id,
            );
            const forbidden_kind = stringArrayContains(
                rule,
                "forbids_action_kinds",
                kind,
            );
            if (!forbidden_id and !forbidden_kind) continue;
            const required = stringValues(rule, "requires_atoms");
            if (required.len == 0) {
                if (!first) try writer.writeByte(',');
                first = false;
                try writeShieldRow(writer, action_id, rule, null);
            } else for (required) |required_atom_value| {
                const required_atom = valueString(required_atom_value) orelse continue;
                if (!first) try writer.writeByte(',');
                first = false;
                try writeShieldRow(writer, action_id, rule, required_atom);
            }
        }
    }
}

fn writeShieldRow(
    writer: *std.Io.Writer,
    action_id: []const u8,
    rule: std.json.ObjectMap,
    missing_atom: ?[]const u8,
) !void {
    try writer.writeByte('{');
    try writeNamedString(writer, "action_id", action_id);
    try writer.writeAll(",\"response\":");
    const source_response = stringField(rule, "response") orelse "block";
    const response = if (std.mem.eql(u8, source_response, "block"))
        "blocked"
    else
        source_response;
    try writeJsonString(writer, response);
    try writer.writeAll(",\"condition\":");
    if (missing_atom == null) {
        try writeValue(writer, rule.get("when") orelse emptyCondition());
    } else {
        const condition = objectField(rule, "when");
        try writer.writeAll("{\"all\":");
        try writeStringArrayValue(writer, if (condition) |row| row.get("all") else null);
        try writer.writeAll(",\"any\":");
        try writeStringArrayValue(writer, if (condition) |row| row.get("any") else null);
        try writer.writeAll(",\"none\":[");
        var first = true;
        if (condition != null) if (arrayField(condition.?, "none")) |none| {
            for (none) |item| {
                if (item != .string) continue;
                if (!first) try writer.writeByte(',');
                first = false;
                try writeJsonString(writer, item.string);
            }
        };
        if (!first) try writer.writeByte(',');
        try writeJsonString(writer, missing_atom.?);
        try writer.writeAll("]}");
    }
    try writer.writeByte('}');
}

fn lowerInitialState(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    policy_digest: []const u8,
) !?schema.State {
    const initial = objectField(root, "initial_state") orelse return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"artifact\":\"EPS-v1\"");
    try writer.writeAll(",\"policy_id\":");
    try writeJsonString(writer, stringField(root, "policy_id").?);
    try writer.writeAll(",\"revision\":");
    try writer.print("{d}", .{integerField(root, "revision").?});
    try writer.writeAll(",\"policy_digest\":");
    try writeJsonString(writer, policy_digest);
    try writer.writeAll(",\"state_id\":");
    try writeJsonString(writer, stringField(initial, "state_id") orelse "initial");
    try writer.writeAll(",\"satisfied_atoms\":");
    try writeStringArrayValue(writer, initial.get("satisfied_atoms"));
    try writer.writeAll(",\"completed_actions\":");
    try writeStringArrayValue(writer, initial.get("completed_actions"));
    try writer.writeAll(",\"failed_actions\":");
    try writeStringArrayValue(writer, initial.get("failed_actions"));
    if (nullableStringField(initial, "active_action_id")) |active| {
        try writer.writeAll(",\"active_action_id\":");
        try writeJsonString(writer, active);
    }
    try writer.writeAll(",\"potential\":[");
    const potential = objectField(root, "potential").?;
    const order = stringValues(potential, "lexicographic_order");
    const current = objectField(initial, "current_potential") orelse
        objectField(potential, "initial").?;
    for (order, 0..) |dimension_value, index| {
        const dimension = valueString(dimension_value) orelse continue;
        if (index > 0) try writer.writeByte(',');
        const value = current.get(dimension) orelse std.json.Value{ .integer = 0 };
        try writeValue(writer, value);
    }
    try writer.writeAll("]}");
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    return try schema.parseArtifact(schema.State, allocator, bytes);
}

fn collectDeclaredAtoms(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    try collectGoalAtoms(&result, allocator, objectField(root, "goal").?);
    if (objectField(root, "belief")) |belief| {
        try collectBeliefAtoms(&result, allocator, belief);
    }
    try collectObservationAtoms(&result, allocator, root);
    try collectActionAtoms(&result, allocator, root);
    return result.toOwnedSlice(allocator);
}

fn collectGoalAtoms(
    result: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    goal: std.json.ObjectMap,
) !void {
    if (arrayField(goal, "terminal_predicates")) |rows| {
        for (rows) |value| if (value == .object) {
            if (stringField(value.object, "atom")) |value_atom| {
                try appendUnique(result, allocator, value_atom);
            }
        };
    }
    if (arrayField(goal, "safety_invariants")) |rows| {
        for (rows) |value| if (value == .object) {
            if (stringField(value.object, "violation_atom")) |value_atom| {
                try appendUnique(result, allocator, value_atom);
            }
        };
    }
    if (arrayField(goal, "forbidden_states")) |rows| {
        for (rows) |value| if (value == .object) {
            if (stringField(value.object, "atom")) |value_atom| {
                try appendUnique(result, allocator, value_atom);
            }
        };
    }
    if (arrayField(goal, "obligations")) |rows| {
        for (rows) |value| if (value == .object) {
            if (stringField(value.object, "obligation_id")) |id| {
                try appendIdAtom(
                    result,
                    allocator,
                    "obligation:{s}=closed",
                    id,
                );
            }
        };
    }
}

fn collectBeliefAtoms(
    result: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    belief: std.json.ObjectMap,
) !void {
    if (arrayField(belief, "facts")) |rows| {
        for (rows) |value| if (value == .object) {
            if (stringField(value.object, "atom")) |value_atom| {
                try appendUnique(result, allocator, value_atom);
            }
        };
    }
    if (arrayField(belief, "unknowns")) |rows| {
        for (rows) |value| if (value == .object) {
            if (stringField(value.object, "unknown_id")) |id| {
                try appendIdAtom(
                    result,
                    allocator,
                    "unknown:{s}=resolved",
                    id,
                );
                try appendIdAtom(
                    result,
                    allocator,
                    "unknown:{s}=blocked",
                    id,
                );
            }
        };
    }
}

fn collectObservationAtoms(
    result: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) !void {
    if (arrayField(root, "observations")) |rows| {
        for (rows) |value| if (value == .object) {
            if (arrayField(value.object, "outcomes")) |outcomes| {
                for (outcomes) |outcome| if (outcome == .object) {
                    if (stringField(outcome.object, "atom")) |value_atom| {
                        try appendUnique(result, allocator, value_atom);
                    }
                };
            }
        };
    }
}

fn collectActionAtoms(
    result: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) !void {
    if (arrayField(root, "actions")) |rows| {
        for (rows) |value| if (value == .object) {
            if (stringField(value.object, "action_id")) |id| {
                try appendIdAtom(
                    result,
                    allocator,
                    "action:{s}=success",
                    id,
                );
                try appendIdAtom(
                    result,
                    allocator,
                    "action:{s}=failure",
                    id,
                );
            }
        };
    }
}

fn validateConditions(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !void {
    const declared = try collectDeclaredAtoms(allocator, root);
    try validateActionConditions(builder, root, declared, allocator);
    try validatePolicyConditions(builder, root, declared, allocator);
    try validateTerminalConditions(builder, root, declared);
    try validateShieldConditions(builder, root, declared);
}

fn validateActionConditions(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    declared: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    const actions = arrayField(root, "actions") orelse &.{};
    for (actions, 0..) |value, index| {
        if (value != .object) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "$.actions[{d}].preconditions",
            .{index},
        );
        try validateCondition(
            builder,
            value.object.get("preconditions"),
            declared,
            path,
        );
        const rollback = objectField(value.object, "rollback");
        if (rollback) |row| for (stringValues(row, "trigger_atoms")) |item_value| {
            const item = valueString(item_value) orelse continue;
            if (!validAtom(item)) {
                try builder.add(
                    .atom_invalid,
                    "$.actions.rollback.trigger_atoms",
                );
            }
            if (!contains(declared, item)) {
                try builder.add(
                    .atom_unknown,
                    "$.actions.rollback.trigger_atoms",
                );
            }
        };
    }
}

fn validatePolicyConditions(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    declared: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (objectField(root, "policy")) |policy| {
        const rules = arrayField(policy, "rules") orelse &.{};
        for (rules, 0..) |value, index| if (value == .object) {
            const path = try std.fmt.allocPrint(
                allocator,
                "$.policy.rules[{d}].when",
                .{index},
            );
            try validateCondition(
                builder,
                value.object.get("when"),
                declared,
                path,
            );
            for (stringValues(value.object, "replan_if_atoms")) |item_value| {
                const item = valueString(item_value) orelse continue;
                if (!validAtom(item)) {
                    try builder.add(
                        .atom_invalid,
                        "$.policy.rules.replan_if_atoms",
                    );
                }
                if (!contains(declared, item)) {
                    try builder.add(
                        .atom_unknown,
                        "$.policy.rules.replan_if_atoms",
                    );
                }
            }
        };
    }
}

fn validateTerminalConditions(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    declared: []const []const u8,
) !void {
    if (objectField(root, "terminal_states")) |terminals| {
        var it = terminals.iterator();
        while (it.next()) |entry| if (entry.value_ptr.* == .object) {
            try validateCondition(
                builder,
                entry.value_ptr.object.get("when"),
                declared,
                "$.terminal_states.when",
            );
        };
    }
}

fn validateShieldConditions(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    declared: []const []const u8,
) !void {
    if (objectField(root, "safety_shield")) |shield| {
        const rules = arrayField(shield, "rules") orelse &.{};
        for (rules) |value| if (value == .object) {
            try validateCondition(
                builder,
                value.object.get("when"),
                declared,
                "$.safety_shield.rules.when",
            );
            for (stringValues(value.object, "requires_atoms")) |item_value| {
                const item = valueString(item_value) orelse continue;
                if (!validAtom(item)) {
                    try builder.add(
                        .atom_invalid,
                        "$.safety_shield.rules.requires_atoms",
                    );
                }
                if (!contains(declared, item)) {
                    try builder.add(
                        .atom_unknown,
                        "$.safety_shield.rules.requires_atoms",
                    );
                }
            }
        };
    }
}

fn validateCondition(
    builder: *errors.Builder,
    maybe_value: ?std.json.Value,
    declared: []const []const u8,
    path: []const u8,
) !void {
    const value = maybe_value orelse {
        try builder.add(.schema_invalid, path);
        return;
    };
    if (value != .object) {
        try builder.add(.schema_invalid, path);
        return;
    }
    for ([_][]const u8{ "all", "any", "none" }) |key| {
        const items = value.object.get(key) orelse {
            try builder.add(.schema_invalid, path);
            continue;
        };
        if (items != .array) {
            try builder.add(.schema_invalid, path);
            continue;
        }
        for (items.array.items) |item| {
            if (item != .string or !validAtom(if (item == .string) item.string else "")) {
                try builder.add(.atom_invalid, path);
            } else if (!contains(declared, item.string)) {
                try builder.add(.atom_unknown, path);
            }
        }
    }
}

fn validateRiskShields(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    action_ids: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    const actions = arrayField(root, "actions") orelse &.{};
    const shield = objectField(root, "safety_shield") orelse {
        for (actions) |value| {
            if (value != .object) continue;
            if (isRiskyKind(stringField(value.object, "kind"))) {
                try builder.add(.risky_action_unshielded, "$.safety_shield");
            }
        }
        return;
    };
    const rules = arrayField(shield, "rules") orelse {
        try builder.add(.schema_invalid, "$.safety_shield.rules");
        return;
    };
    for (rules, 0..) |value, index| {
        if (value != .object) {
            try builder.add(.schema_invalid, "$.safety_shield.rules");
            continue;
        }
        const row = value.object;
        const responses = [_][]const u8{ "block", "rollback", "return_to_spec" };
        if (!oneOf(stringField(row, "response"), &responses)) {
            try builder.add(
                .schema_invalid,
                try std.fmt.allocPrint(
                    allocator,
                    "$.safety_shield.rules[{d}].response",
                    .{index},
                ),
            );
        }
        for (stringValues(row, "forbids_action_ids")) |ref_value| {
            const ref = valueString(ref_value) orelse continue;
            if (!contains(action_ids, ref)) {
                try builder.add(
                    .reference_unknown,
                    "$.safety_shield.rules.forbids_action_ids",
                );
            }
        }
    }
    for (actions) |value| {
        if (value != .object) continue;
        const action = value.object;
        if (!isRiskyKind(stringField(action, "kind"))) continue;
        const id = stringField(action, "action_id") orelse continue;
        const kind = stringField(action, "kind") orelse "";
        var covered = false;
        for (rules) |rule_value| {
            if (rule_value != .object) continue;
            if (stringArrayContains(rule_value.object, "forbids_action_ids", id) or
                stringArrayContains(rule_value.object, "forbids_action_kinds", kind))
            {
                covered = true;
                break;
            }
        }
        if (!covered) try builder.add(.risky_action_unshielded, "$.actions");
    }
}

fn validateSquareResults(builder: *errors.Builder, root: std.json.ObjectMap) !void {
    const revision = objectField(root, "revision_summary") orelse return;
    const squares = arrayField(revision, "square_results") orelse return;
    for (squares) |value| {
        if (value != .object) continue;
        const result = stringField(value.object, "result") orelse continue;
        if (std.mem.eql(u8, result, "fails") or std.mem.eql(u8, result, "underdetermined")) {
            try builder.add(.architectonic_incomplete, "$.revision_summary.square_results");
        }
    }
}

fn validateSourceShape(builder: *errors.Builder, root: std.json.ObjectMap) !void {
    const source = objectField(root, "source") orelse {
        try builder.add(.schema_invalid, "$.source");
        return;
    };
    const source_modes = [_][]const u8{
        "spec_handoff",
        "direct_brief",
        "existing_policy_revision",
    };
    if (!oneOf(stringField(source, "mode"), &source_modes)) {
        try builder.add(.schema_invalid, "$.source.mode");
    }
    if (emptyStringField(source, "authority")) {
        try builder.add(.schema_invalid, "$.source.authority");
    }
    try requireStringArray(builder, source, "source_refs", "$.source.source_refs");
    if (emptyArrayField(source, "source_refs")) {
        try builder.add(.schema_invalid, "$.source.source_refs");
    }
    const source_digest = stringField(source, "source_digest") orelse "";
    if (!validSha256Digest(source_digest)) {
        try builder.add(.schema_invalid, "$.source.source_digest");
    }
    try requireStringArray(
        builder,
        source,
        "locked_decision_refs",
        "$.source.locked_decision_refs",
    );
    const current = stringField(source, "current");
    if (!oneOf(current, &.{ "yes", "no", "unknown" })) {
        try builder.add(.schema_invalid, "$.source.current");
    } else if (!std.mem.eql(u8, current.?, "yes")) {
        try builder.add(.source_stale, "$.source.current");
    }

    const artifact_state = objectField(source, "artifact_state") orelse {
        try builder.add(.schema_invalid, "$.source.artifact_state");
        return;
    };
    const repo_bound = stringField(artifact_state, "repo_bound");
    if (!oneOf(repo_bound, &.{ "yes", "no", "unknown" })) {
        try builder.add(
            .schema_invalid,
            "$.source.artifact_state.repo_bound",
        );
    }
    if (repo_bound != null and std.mem.eql(u8, repo_bound.?, "yes")) {
        inline for ([_][]const u8{
            "repository",
            "branch",
            "base",
            "head",
            "dirty_fingerprint",
        }) |key| {
            if (emptyStringField(artifact_state, key)) {
                try builder.add(
                    .schema_invalid,
                    "$.source.artifact_state",
                );
            }
        }
    }
}

fn validateRegimeShape(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    observation_ids: []const []const u8,
) !void {
    const regime = objectField(root, "regime") orelse {
        try builder.add(.schema_invalid, "$.regime");
        return;
    };
    const kinds = [_][]const u8{ "clear", "complicated", "complex", "chaotic" };
    if (!oneOf(stringField(regime, "kind"), &kinds)) {
        try builder.add(.schema_invalid, "$.regime.kind");
    }
    if (!oneOf(stringField(regime, "confidence"), &.{ "high", "medium", "low" })) {
        try builder.add(.schema_invalid, "$.regime.confidence");
    }
    if (emptyStringField(regime, "rationale")) {
        try builder.add(.schema_invalid, "$.regime.rationale");
    }
    try requireStringArray(
        builder,
        regime,
        "reclassify_on_observation_refs",
        "$.regime.reclassify_on_observation_refs",
    );
    try validateStringRefs(
        builder,
        stringValues(regime, "reclassify_on_observation_refs"),
        observation_ids,
        "$.regime.reclassify_on_observation_refs",
    );
}

fn validateHorizonShape(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
) !void {
    const horizon = objectField(root, "horizon") orelse {
        try builder.add(.schema_invalid, "$.horizon");
        return;
    };
    inline for ([_][]const u8{
        "mutation_actions_max",
        "evidence_actions_max",
        "delivery_transitions_max",
    }) |key| {
        const value = integerField(horizon, key);
        if (value == null or value.? < 0) {
            try builder.add(.schema_invalid, "$.horizon");
        }
    }
}

fn validateChallengeShape(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
) !void {
    const challenge = objectField(root, "challenge") orelse {
        try builder.add(.schema_invalid, "$.challenge");
        return;
    };
    if (emptyStringField(challenge, "candidate")) {
        try builder.add(.schema_invalid, "$.challenge.candidate");
    }
    const dispositions = [_][]const u8{
        "adopt",
        "reject",
        "defer",
        "return_to_spec",
        "none",
    };
    if (!oneOf(stringField(challenge, "disposition"), &dispositions)) {
        try builder.add(.schema_invalid, "$.challenge.disposition");
    }
    if (emptyStringField(challenge, "reason")) {
        try builder.add(.schema_invalid, "$.challenge.reason");
    }
    try requireStringArray(
        builder,
        challenge,
        "affected_refs",
        "$.challenge.affected_refs",
    );
    if (boolField(challenge, "source_change_required") == null) {
        try builder.add(
            .schema_invalid,
            "$.challenge.source_change_required",
        );
    }
}

fn validateInvalidatorsShape(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !void {
    const invalidators = root.get("invalidators") orelse {
        try builder.add(.schema_invalid, "$.invalidators");
        return;
    };
    if (invalidators != .array) {
        try builder.add(.schema_invalid, "$.invalidators");
        return;
    }
    var ids: std.ArrayList([]const u8) = .empty;
    for (invalidators.array.items, 0..) |value, index| {
        const path = try std.fmt.allocPrint(allocator, "$.invalidators[{d}]", .{index});
        if (value != .object) {
            try builder.add(.schema_invalid, path);
            continue;
        }
        const id = stringField(value.object, "invalidator_id") orelse {
            try builder.add(.schema_invalid, try suffix(allocator, path, ".invalidator_id"));
            continue;
        };
        atom.validateStableId(id) catch {
            try builder.add(
                .atom_invalid,
                try suffix(allocator, path, ".invalidator_id"),
            );
        };
        if (contains(ids.items, id)) {
            try builder.add(
                .id_duplicate,
                try suffix(allocator, path, ".invalidator_id"),
            );
        } else {
            try ids.append(allocator, id);
        }
        if (emptyStringField(value.object, "condition")) {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".condition"),
            );
        }
        if (emptyStringField(value.object, "required_action")) {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".required_action"),
            );
        }
        try requireStringArray(
            builder,
            value.object,
            "affected_refs",
            try suffix(allocator, path, ".affected_refs"),
        );
    }
}

fn validateRevisionShape(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !void {
    const revision = objectField(root, "revision_summary") orelse {
        try builder.add(.schema_invalid, "$.revision_summary");
        return;
    };
    inline for ([_][]const u8{ "policy_changes", "semantic_changes", "source_changes" }) |key| {
        const path = try std.fmt.allocPrint(allocator, "$.revision_summary.{s}", .{key});
        try requireStringArray(builder, revision, key, path);
    }
    const architectonic_changes = revision.get("architectonic_changes") orelse {
        try builder.add(.schema_invalid, "$.revision_summary.architectonic_changes");
        return;
    };
    if (architectonic_changes != .array) {
        try builder.add(
            .schema_invalid,
            "$.revision_summary.architectonic_changes",
        );
    }
    const transport = objectField(revision, "plan_transport") orelse {
        try builder.add(.schema_invalid, "$.revision_summary.plan_transport");
        return;
    };
    inline for ([_][]const u8{
        "preserved_action_refs",
        "revised_action_refs",
        "retired_action_refs",
        "introduced_action_refs",
    }) |key| {
        const path = try std.fmt.allocPrint(
            allocator,
            "$.revision_summary.plan_transport.{s}",
            .{key},
        );
        try requireStringArray(builder, transport, key, path);
    }
    const squares = revision.get("square_results") orelse {
        try builder.add(.schema_invalid, "$.revision_summary.square_results");
        return;
    };
    if (squares != .array) {
        try builder.add(.schema_invalid, "$.revision_summary.square_results");
    }
}

fn validateArchitectonicComposition(
    builder: *errors.Builder,
    architectonic: std.json.ObjectMap,
    seam_ids: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    const composition = objectField(architectonic, "composition") orelse {
        try builder.add(.architectonic_incomplete, "$.architectonic.composition");
        return;
    };
    try validateSeamDependencyEdges(
        builder,
        composition,
        seam_ids,
        allocator,
    );
    try validateIndependentSeamSets(
        builder,
        composition,
        seam_ids,
        allocator,
    );
}

fn validateSeamDependencyEdges(
    builder: *errors.Builder,
    composition: std.json.ObjectMap,
    seam_ids: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    const edges_value = composition.get("seam_dependency_edges") orelse {
        try builder.add(
            .schema_invalid,
            "$.architectonic.composition.seam_dependency_edges",
        );
        return;
    };
    if (edges_value != .array) {
        try builder.add(
            .schema_invalid,
            "$.architectonic.composition.seam_dependency_edges",
        );
    } else for (edges_value.array.items, 0..) |value, index| {
        const path = try std.fmt.allocPrint(
            allocator,
            "$.architectonic.composition.seam_dependency_edges[{d}]",
            .{index},
        );
        if (value != .object) {
            try builder.add(.schema_invalid, path);
            continue;
        }
        const from = stringField(value.object, "from_seam_ref");
        const to = stringField(value.object, "to_seam_ref");
        if (from == null or !contains(seam_ids, from.?)) {
            try builder.add(
                .reference_unknown,
                try suffix(allocator, path, ".from_seam_ref"),
            );
        }
        if (to == null or !contains(seam_ids, to.?)) {
            try builder.add(
                .reference_unknown,
                try suffix(allocator, path, ".to_seam_ref"),
            );
        }
        if (emptyStringField(value.object, "relation")) {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".relation"),
            );
        }
    }
}

fn validateIndependentSeamSets(
    builder: *errors.Builder,
    composition: std.json.ObjectMap,
    seam_ids: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    const sets_value = composition.get("independent_seam_sets") orelse {
        try builder.add(
            .schema_invalid,
            "$.architectonic.composition.independent_seam_sets",
        );
        return;
    };
    if (sets_value != .array) {
        try builder.add(
            .schema_invalid,
            "$.architectonic.composition.independent_seam_sets",
        );
    } else for (sets_value.array.items, 0..) |set_value, set_index| {
        const path = try std.fmt.allocPrint(
            allocator,
            "$.architectonic.composition.independent_seam_sets[{d}]",
            .{set_index},
        );
        if (set_value != .array or set_value.array.items.len == 0) {
            try builder.add(.schema_invalid, path);
            continue;
        }
        for (set_value.array.items) |ref_value| {
            const ref = if (ref_value == .string) ref_value.string else "";
            if (ref_value != .string or !contains(seam_ids, ref)) {
                try builder.add(.reference_unknown, path);
            }
        }
    }
}

fn validateConceptualCompression(
    builder: *errors.Builder,
    architectonic: std.json.ObjectMap,
    obligation_ids: []const []const u8,
    factors: []const Factor,
    allocator: std.mem.Allocator,
) !void {
    const compression = objectField(architectonic, "conceptual_compression") orelse {
        try builder.add(.architectonic_incomplete, "$.architectonic.conceptual_compression");
        return;
    };
    inline for ([_][]const u8{
        "live_obligation_refs",
        "independent_factor_refs",
        "independent_owner_refs",
        "exceptional_path_refs",
        "dominated_factor_refs",
    }) |key| {
        const path = try std.fmt.allocPrint(
            allocator,
            "$.architectonic.conceptual_compression.{s}",
            .{key},
        );
        try requireStringArray(builder, compression, key, path);
    }
    try validateStringRefs(
        builder,
        stringValues(compression, "live_obligation_refs"),
        obligation_ids,
        "$.architectonic.conceptual_compression.live_obligation_refs",
    );
    try validateCompressionFactorRefs(
        builder,
        compression,
        "independent_factor_refs",
        "$.architectonic.conceptual_compression.independent_factor_refs",
        factors,
        true,
    );
    try validateCompressionFactorRefs(
        builder,
        compression,
        "dominated_factor_refs",
        "$.architectonic.conceptual_compression.dominated_factor_refs",
        factors,
        false,
    );
}

fn validateCompressionFactorRefs(
    builder: *errors.Builder,
    compression: std.json.ObjectMap,
    key: []const u8,
    path: []const u8,
    factors: []const Factor,
    retained_expected: bool,
) !void {
    for (stringValues(compression, key)) |ref_value| {
        const ref = valueString(ref_value) orelse continue;
        const index = factorIndex(factors, ref) orelse {
            try builder.add(.reference_unknown, path);
            continue;
        };
        if (factorRetained(factors[index].disposition) != retained_expected) {
            try builder.add(.factor_disposition_conflict, path);
        }
    }
}

fn validateLoweringShape(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !void {
    try validateLoweringObservations(builder, root, allocator);
    const policy = objectField(root, "policy") orelse {
        try builder.add(.schema_invalid, "$.policy");
        return;
    };
    const utility_keys = try collectUtilityKeys(builder, policy, allocator);
    try validateLoweringActions(builder, root, utility_keys, allocator);
    try validateLoweringRules(builder, policy, allocator);
    try validateLoweringTerminals(builder, root);
    try validateLoweringPotentialAndState(builder, root);
}

fn validateLoweringObservations(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !void {
    const observations = root.get("observations") orelse {
        try builder.add(.schema_invalid, "$.observations");
        return;
    };
    if (observations != .array) {
        try builder.add(.schema_invalid, "$.observations");
        return;
    }
    for (observations.array.items, 0..) |value, index| {
        if (value != .object) continue;
        const outcomes = value.object.get("outcomes") orelse {
            try builder.add(.schema_invalid, "$.observations.outcomes");
            continue;
        };
        if (outcomes != .array or outcomes.array.items.len == 0) {
            try builder.add(.schema_invalid, "$.observations.outcomes");
            continue;
        }
        for (outcomes.array.items) |outcome| {
            if (outcome != .object or
                emptyStringField(outcome.object, "outcome") or
                emptyStringField(outcome.object, "atom"))
            {
                try builder.add(
                    .schema_invalid,
                    try std.fmt.allocPrint(
                        allocator,
                        "$.observations[{d}].outcomes",
                        .{index},
                    ),
                );
            }
        }
    }
}

fn collectUtilityKeys(
    builder: *errors.Builder,
    policy: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    const utility_order = policy.get("utility_order") orelse {
        try builder.add(.schema_invalid, "$.policy.utility_order");
        return &.{};
    };
    var utility_keys: std.ArrayList([]const u8) = .empty;
    if (utility_order != .array or utility_order.array.items.len == 0) {
        try builder.add(.schema_invalid, "$.policy.utility_order");
        return utility_keys.items;
    }
    for (utility_order.array.items, 0..) |value, index| {
        if (value != .object or value.object.count() != 1) {
            try builder.add(.schema_invalid, "$.policy.utility_order");
            continue;
        }
        var it = value.object.iterator();
        const entry = it.next().?;
        if (!std.mem.eql(u8, entry.key_ptr.*, "maximize") and
            !std.mem.eql(u8, entry.key_ptr.*, "minimize"))
        {
            try builder.add(.schema_invalid, "$.policy.utility_order");
        }
        if (entry.value_ptr.* != .string or entry.value_ptr.string.len == 0) {
            try builder.add(.schema_invalid, "$.policy.utility_order");
            continue;
        }
        if (contains(utility_keys.items, entry.value_ptr.string)) {
            try builder.add(
                .id_duplicate,
                try std.fmt.allocPrint(
                    allocator,
                    "$.policy.utility_order[{d}]",
                    .{index},
                ),
            );
        } else {
            try utility_keys.append(allocator, entry.value_ptr.string);
        }
    }
    return utility_keys.items;
}

fn validateLoweringActions(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    utility_keys: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    const actions = arrayField(root, "actions") orelse &.{};
    for (actions, 0..) |value, index| {
        if (value != .object) continue;
        const action = value.object;
        const path = try std.fmt.allocPrint(allocator, "$.actions[{d}]", .{index});
        inline for ([_][]const u8{
            "requires_actions",
            "architectonic_seam_refs",
            "realizes_factor_refs",
            "retires_factor_refs",
            "preservation_observation_refs",
            "expected_observation_refs",
            "failure_observation_refs",
        }) |key| {
            try requireStringArray(
                builder,
                action,
                key,
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key }),
            );
        }
        if (boolField(action, "repeatable") == null) {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".repeatable"),
            );
        }
        const effects = objectField(action, "expected_effects") orelse {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".expected_effects"),
            );
            continue;
        };
        try validateLoweringActionValues(
            builder,
            action,
            effects,
            path,
            utility_keys,
            allocator,
        );
    }
}

fn validateLoweringActionValues(
    builder: *errors.Builder,
    action: std.json.ObjectMap,
    effects: std.json.ObjectMap,
    path: []const u8,
    utility_keys: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    inline for ([_][]const u8{
        "facts_added",
        "unknowns_resolved",
        "obligations_closed",
    }) |key| {
        const key_path = try std.fmt.allocPrint(
            allocator,
            "{s}.expected_effects.{s}",
            .{ path, key },
        );
        try requireStringArray(builder, effects, key, key_path);
    }
    const utility = objectField(action, "utility") orelse {
        try builder.add(
            .schema_invalid,
            try suffix(allocator, path, ".utility"),
        );
        return;
    };
    for (utility_keys) |key| {
        const score = integerField(utility, key);
        if (score == null or score.? < 0 or score.? > 100) {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".utility"),
            );
        }
    }
}

fn validateLoweringRules(
    builder: *errors.Builder,
    policy: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !void {
    const rules_value = policy.get("rules") orelse {
        try builder.add(.schema_invalid, "$.policy.rules");
        return;
    };
    if (rules_value != .array) {
        try builder.add(.schema_invalid, "$.policy.rules");
    } else for (rules_value.array.items, 0..) |value, index| {
        const path = try std.fmt.allocPrint(allocator, "$.policy.rules[{d}]", .{index});
        if (value != .object) {
            try builder.add(.schema_invalid, path);
            continue;
        }
        if (emptyStringField(value.object, "rule_id")) {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".rule_id"),
            );
        }
        try requireStringArray(
            builder,
            value.object,
            "candidate_action_ids",
            try suffix(allocator, path, ".candidate_action_ids"),
        );
        const terminal = value.object.get("terminal") orelse {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".terminal"),
            );
            continue;
        };
        if (terminal != .null and terminal != .string) {
            try builder.add(
                .schema_invalid,
                try suffix(allocator, path, ".terminal"),
            );
        }
    }
}

fn validateLoweringTerminals(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
) !void {
    const terminals = root.get("terminal_states") orelse {
        try builder.add(.schema_invalid, "$.terminal_states");
        return;
    };
    if (terminals != .object or terminals.object.count() == 0) {
        try builder.add(.schema_invalid, "$.terminal_states");
    } else {
        var it = terminals.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .object or entry.value_ptr.object.get("when") == null) {
                try builder.add(.schema_invalid, "$.terminal_states");
            }
        }
    }
}

fn validateLoweringPotentialAndState(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
) !void {
    const potential = objectField(root, "potential") orelse {
        try builder.add(.schema_invalid, "$.potential");
        return;
    };
    try requireStringArray(
        builder,
        potential,
        "lexicographic_order",
        "$.potential.lexicographic_order",
    );
    const dimensions = potential.get("dimensions") orelse {
        try builder.add(.schema_invalid, "$.potential.dimensions");
        return;
    };
    if (dimensions != .array or dimensions.array.items.len == 0) {
        try builder.add(.schema_invalid, "$.potential.dimensions");
    } else for (dimensions.array.items) |value| {
        if (value != .object or emptyStringField(value.object, "dimension_id") or
            !oneOf(stringField(value.object, "direction"), &.{ "minimize", "maximize" }))
        {
            try builder.add(.schema_invalid, "$.potential.dimensions");
        }
    }
    if (objectField(potential, "initial") == null) {
        try builder.add(.schema_invalid, "$.potential.initial");
    }
    const initial = objectField(root, "initial_state") orelse {
        try builder.add(.schema_invalid, "$.initial_state");
        return;
    };
    if (emptyStringField(initial, "state_id")) {
        try builder.add(.schema_invalid, "$.initial_state.state_id");
    }
    try requireStringArray(
        builder,
        initial,
        "satisfied_atoms",
        "$.initial_state.satisfied_atoms",
    );
    try requireStringArray(
        builder,
        initial,
        "completed_actions",
        "$.initial_state.completed_actions",
    );
    try requireStringArray(
        builder,
        initial,
        "failed_actions",
        "$.initial_state.failed_actions",
    );
    if (objectField(initial, "current_potential") == null) {
        try builder.add(.schema_invalid, "$.initial_state.current_potential");
    }
}

fn requireStringArray(
    builder: *errors.Builder,
    object: std.json.ObjectMap,
    key: []const u8,
    path: []const u8,
) !void {
    const value = object.get(key) orelse {
        try builder.add(.schema_invalid, path);
        return;
    };
    if (value != .array) {
        try builder.add(.schema_invalid, path);
        return;
    }
    for (value.array.items) |item| {
        if (item != .string) try builder.add(.schema_invalid, path);
    }
}

fn writeCustomAtoms(writer: *std.Io.Writer, root: std.json.ObjectMap, invariants: bool) !void {
    const goal = objectField(root, "goal").?;
    const rows = if (invariants)
        arrayField(goal, "safety_invariants") orelse &.{}
    else
        arrayField(goal, "forbidden_states") orelse &.{};
    try writer.writeByte('[');
    var first = true;
    for (rows) |value| {
        if (value != .object) continue;
        const value_atom = if (invariants)
            stringField(value.object, "violation_atom")
        else
            stringField(value.object, "atom");
        if (value_atom == null or !std.mem.startsWith(u8, value_atom.?, "custom:")) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writeJsonString(writer, value_atom.?);
    }
    try writer.writeByte(']');
}

fn collectIds(
    allocator: std.mem.Allocator,
    builder: *errors.Builder,
    maybe_rows: ?[]const std.json.Value,
    key: []const u8,
    path: []const u8,
) ![]const []const u8 {
    const rows = maybe_rows orelse {
        try builder.add(.schema_invalid, path);
        return &.{};
    };
    var ids: std.ArrayList([]const u8) = .empty;
    for (rows, 0..) |value, index| {
        if (value != .object) {
            try builder.add(.schema_invalid, path);
            continue;
        }
        const id = stringField(value.object, key) orelse {
            try builder.add(.schema_invalid, path);
            continue;
        };
        if (id.len == 0) {
            try builder.add(.atom_invalid, path);
            continue;
        }
        atom.validateStableId(id) catch {
            try builder.add(.atom_invalid, path);
            continue;
        };
        if (contains(ids.items, id)) {
            try builder.add(
                .id_duplicate,
                try std.fmt.allocPrint(
                    allocator,
                    "{s}[{d}].{s}",
                    .{ path, index, key },
                ),
            );
        } else {
            try ids.append(allocator, id);
        }
    }
    return ids.toOwnedSlice(allocator);
}

fn appendUnique(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    if (!contains(list.items, value)) try list.append(allocator, value);
}

fn appendIdAtom(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    id: []const u8,
) !void {
    const value = try std.fmt.allocPrint(allocator, format, .{id});
    try appendUnique(list, allocator, value);
}

fn actionResolves(actions: []const std.json.Value, unknown_id: []const u8) bool {
    for (actions) |value| {
        if (value != .object) continue;
        const effects = objectField(value.object, "expected_effects") orelse continue;
        if (stringArrayContains(effects, "unknowns_resolved", unknown_id)) return true;
    }
    return false;
}

fn actionCloses(actions: []const std.json.Value, obligation_id: []const u8) bool {
    for (actions) |value| {
        if (value != .object) continue;
        const effects = objectField(value.object, "expected_effects") orelse continue;
        if (stringArrayContains(effects, "obligations_closed", obligation_id)) return true;
    }
    return false;
}

fn atomForId(
    rows: []const std.json.Value,
    id_key: []const u8,
    id: []const u8,
) ?[]const u8 {
    for (rows) |value| {
        if (value != .object) continue;
        const candidate = stringField(value.object, id_key) orelse "";
        if (std.mem.eql(u8, candidate, id)) {
            return stringField(value.object, "atom");
        }
    }
    return null;
}

fn requireString(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    key: []const u8,
    path: []const u8,
) !void {
    if (emptyStringField(root, key)) try builder.add(.schema_invalid, path);
}

fn requireInteger(
    builder: *errors.Builder,
    root: std.json.ObjectMap,
    key: []const u8,
    path: []const u8,
) !void {
    if (integerField(root, key) == null) try builder.add(.schema_invalid, path);
}

fn singleError(
    allocator: std.mem.Allocator,
    code: errors.ErrorCode,
    path: []const u8,
) !errors.ValidationReport {
    var builder = errors.Builder.init(allocator);
    defer builder.deinit();
    try builder.add(code, path);
    return builder.finish();
}

fn factorIndex(factors: []const Factor, id: []const u8) ?usize {
    for (factors, 0..) |factor, index| if (std.mem.eql(u8, factor.id, id)) return index;
    return null;
}

fn factorRetained(disposition: []const u8) bool {
    return std.mem.eql(u8, disposition, "preserve") or
        std.mem.eql(u8, disposition, "factor") or
        std.mem.eql(u8, disposition, "introduce");
}

fn isRiskyKind(kind: ?[]const u8) bool {
    const value = kind orelse return false;
    return std.mem.eql(u8, value, "mutate") or
        std.mem.eql(u8, value, "stabilize") or
        std.mem.eql(u8, value, "deploy") or
        std.mem.eql(u8, value, "rollback");
}

fn validAtom(value: []const u8) bool {
    _ = atom.parse(value) catch return false;
    return true;
}

fn validSha256Digest(value: []const u8) bool {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return false;
    for (value[7..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn oneOf(value: ?[]const u8, choices: []const []const u8) bool {
    const actual = value orelse return false;
    return contains(choices, actual);
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    return indexOf(values, needle) != null;
}

fn indexOf(values: []const []const u8, needle: []const u8) ?usize {
    for (values, 0..) |value, index| if (std.mem.eql(u8, value, needle)) return index;
    return null;
}

fn containsInt(values: []const i64, needle: i64) bool {
    for (values) |value| if (value == needle) return true;
    return false;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn nullableStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn arrayField(object: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const value = object.get(key) orelse return null;
    return if (value == .array) value.array.items else null;
}

fn stringValues(object: std.json.ObjectMap, key: []const u8) []const std.json.Value {
    const values = arrayField(object, key) orelse return &.{};
    for (values) |value| if (value != .string) return &.{};
    return values;
}

fn stringArrayContains(object: std.json.ObjectMap, key: []const u8, needle: []const u8) bool {
    for (stringValues(object, key)) |value| {
        if (std.mem.eql(u8, value.string, needle)) return true;
    }
    return false;
}

fn valueString(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn validateStringRefs(
    builder: *errors.Builder,
    values: []const std.json.Value,
    known: []const []const u8,
    path: []const u8,
) !void {
    for (values) |value| {
        const ref = valueString(value) orelse {
            try builder.add(.schema_invalid, path);
            continue;
        };
        if (!contains(known, ref)) try builder.add(.reference_unknown, path);
    }
}

fn emptyStringField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = stringField(object, key) orelse return true;
    return value.len == 0;
}

fn emptyArrayField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = arrayField(object, key) orelse return true;
    return value.len == 0;
}

fn stringEquals(object: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, stringField(object, key) orelse "", expected);
}

fn suffix(allocator: std.mem.Allocator, base: []const u8, tail: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, tail });
}

fn writeNamedString(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writeJsonString(writer, key);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeValue(writer: *std.Io.Writer, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeStringSlice(writer: *std.Io.Writer, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}

fn writeStringArrayValue(writer: *std.Io.Writer, maybe_value: ?std.json.Value) !void {
    const value = maybe_value orelse {
        try writer.writeAll("[]");
        return;
    };
    if (value != .array) {
        try writer.writeAll("[]");
        return;
    }
    try writeValue(writer, value);
}

fn emptyCondition() std.json.Value {
    return .null;
}
