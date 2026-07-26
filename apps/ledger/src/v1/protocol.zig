const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const reducer = @import("reducer.zig");
const state_reducer = @import("state_reducer.zig");
const storage = @import("storage.zig");

const required_operator_mask =
    operatorBit(.event_envelope) |
    operatorBit(.sequence) |
    operatorBit(.previous_digest) |
    operatorBit(.body_digest) |
    operatorBit(.event_digest) |
    operatorBit(.event_kinds) |
    operatorBit(.replay);

const protocol_operator_mask =
    required_operator_mask |
    operatorBit(.transition_table) |
    operatorBit(.reducer);

pub fn isConfigured(definition_plan: *const definition.Plan) bool {
    return (definition_plan.operator_mask & protocol_operator_mask) != 0;
}

const PartitionBinding = struct {
    parameter: []u8,
    kind: definition_core.scalar.Kind,
    event_value: definition_core.json_pointer.Pointer,

    fn deinit(
        self: *PartitionBinding,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.parameter);
        self.event_value.deinit(allocator);
        self.* = undefined;
    }
};

const Envelope = struct {
    input_index: u8,
    keys: [][]u8,
    sequence_key: []u8,
    kind_key: []u8,
    previous_digest_key: []u8,
    body_key: []u8,
    body_digest_key: []u8,
    event_digest_key: []u8,
    partition_bindings: []PartitionBinding,

    fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        for (self.keys) |key| allocator.free(key);
        allocator.free(self.keys);
        allocator.free(self.sequence_key);
        allocator.free(self.kind_key);
        allocator.free(self.previous_digest_key);
        allocator.free(self.body_key);
        allocator.free(self.body_digest_key);
        allocator.free(self.event_digest_key);
        for (self.partition_bindings) |*binding| {
            binding.deinit(allocator);
        }
        allocator.free(self.partition_bindings);
        self.* = undefined;
    }
};

const Genesis = union(enum) {
    null,
    digest: []u8,

    fn deinit(self: *Genesis, allocator: std.mem.Allocator) void {
        if (self.* == .digest) allocator.free(self.digest);
        self.* = undefined;
    }
};

pub const Plan = struct {
    envelope: Envelope,
    sequence_start: u64,
    genesis: Genesis,
    event_kinds: [][]u8,
    max_records: usize,
    target_slot_index: u16,
    reducer_plan: ?reducer.Plan,
    state_reducer_plan: ?state_reducer.Plan,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.envelope.deinit(allocator);
        self.genesis.deinit(allocator);
        for (self.event_kinds) |kind| allocator.free(kind);
        allocator.free(self.event_kinds);
        if (self.reducer_plan) |*plan| plan.deinit(allocator);
        if (self.state_reducer_plan) |*plan| plan.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReplayState = struct {
    next_sequence: u64,
    previous_digest: [71]u8 = undefined,
    has_previous_digest: bool = false,
    records: usize = 0,
    reducer_state: reducer.State = .{},
    state_reducer_state: state_reducer.State = .{},

    pub fn init(plan: *const Plan) ReplayState {
        return .{ .next_sequence = plan.sequence_start };
    }

    pub fn deinit(self: *ReplayState, allocator: std.mem.Allocator) void {
        self.reducer_state.deinit(allocator);
        self.state_reducer_state.deinit(allocator);
        self.* = undefined;
    }

    pub fn previousDigest(self: *const ReplayState) ?[]const u8 {
        return if (self.has_previous_digest)
            self.previous_digest[0..]
        else
            null;
    }
};

pub const GeneratedOutput = struct {
    name: []u8,
    value: []u8,

    pub fn deinit(
        self: *GeneratedOutput,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.name);
        @memset(self.value, 0);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const MaterializedEvent = struct {
    content: []u8,
    generated_outputs: []GeneratedOutput,

    pub fn deinit(
        self: *MaterializedEvent,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.content);
        for (self.generated_outputs) |*output| output.deinit(allocator);
        allocator.free(self.generated_outputs);
        self.* = undefined;
    }
};

const ProtocolRules = struct {
    envelope: ?definition.Rule = null,
    sequence: ?definition.Rule = null,
    previous_digest: ?definition.Rule = null,
    body_digest: ?definition.Rule = null,
    event_digest: ?definition.Rule = null,
    event_kinds: ?definition.Rule = null,
    transition_table: ?definition.Rule = null,
    reducer: ?definition.Rule = null,
};

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
) !?Plan {
    const present_mask = definition_plan.operator_mask & protocol_operator_mask;
    if (present_mask == 0) return null;
    if (definition_plan.storage_kind != .event_log) {
        return error.ProtocolRequiresEventLogStorage;
    }
    if ((definition_plan.operator_mask & required_operator_mask) !=
        required_operator_mask)
    {
        return error.IncompleteEventProtocolOperators;
    }
    var rules: ProtocolRules = .{};
    for (definition_plan.rules) |rule| switch (rule.operator) {
        .event_envelope => try setRule(&rules.envelope, rule),
        .sequence => try setRule(&rules.sequence, rule),
        .previous_digest => try setRule(&rules.previous_digest, rule),
        .body_digest => try setRule(&rules.body_digest, rule),
        .event_digest => try setRule(&rules.event_digest, rule),
        .event_kinds => try setRule(&rules.event_kinds, rule),
        .transition_table => try setRule(&rules.transition_table, rule),
        .reducer => try setRule(&rules.reducer, rule),
        else => {},
    };
    if (rules.envelope == null or
        rules.sequence == null or
        rules.previous_digest == null or
        rules.body_digest == null or
        rules.event_digest == null or
        rules.event_kinds == null)
    {
        return error.IncompleteEventProtocolRules;
    }

    var envelope = try compileEnvelope(
        allocator,
        definition_plan,
        rules.envelope.?,
    );
    errdefer envelope.deinit(allocator);
    const sequence_start = try compileSequence(
        allocator,
        rules.sequence.?,
    );
    var genesis = try compileGenesis(
        allocator,
        rules.previous_digest.?,
    );
    errdefer genesis.deinit(allocator);
    try compileMarkerRule(
        allocator,
        rules.body_digest.?,
        .body_digest,
    );
    try compileMarkerRule(
        allocator,
        rules.event_digest.?,
        .event_digest,
    );
    const event_kinds = try compileEventKinds(
        allocator,
        rules.event_kinds.?,
    );
    errdefer {
        for (event_kinds) |kind| allocator.free(kind);
        allocator.free(event_kinds);
    }
    const target_slot_index = try compileTargetSlot(
        storage_plan,
        envelope.input_index,
    );
    var reducer_plan: ?reducer.Plan = null;
    errdefer if (reducer_plan) |*plan| plan.deinit(allocator);
    var state_reducer_plan: ?state_reducer.Plan = null;
    errdefer if (state_reducer_plan) |*plan| plan.deinit(allocator);
    if (rules.reducer) |reducer_rule| {
        if (!definition_plan.requires(.reducer)) {
            return error.UndeclaredReducerRule;
        }
        if (try state_reducer.isRetainedRule(allocator, reducer_rule)) {
            if (definition_plan.requires(.transition_table) or
                rules.transition_table != null)
            {
                return error.RetainedReducerRejectsTransitionTable;
            }
            state_reducer_plan = try state_reducer.compile(
                allocator,
                definition_plan,
                reducer_rule,
                definition_plan.bounds.max_input_bytes,
            );
            try state_reducer.validateEventKinds(
                &state_reducer_plan.?,
                event_kinds,
            );
        } else {
            if (!definition_plan.requires(.transition_table) or
                rules.transition_table == null)
            {
                return error.IncompleteReducerRules;
            }
            reducer_plan = try reducer.compile(
                allocator,
                rules.transition_table.?,
                reducer_rule,
                definition_plan.bounds.max_reducer_states,
            );
        }
    } else if (rules.transition_table != null or
        definition_plan.requires(.transition_table) or
        definition_plan.requires(.reducer))
    {
        return error.IncompleteReducerRules;
    }
    const result: Plan = .{
        .envelope = envelope,
        .sequence_start = sequence_start,
        .genesis = genesis,
        .event_kinds = event_kinds,
        .max_records = definition_plan.bounds.max_records,
        .target_slot_index = target_slot_index,
        .reducer_plan = reducer_plan,
        .state_reducer_plan = state_reducer_plan,
    };
    try validateStorageMaterializations(&result, storage_plan);
    return result;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(4);
    try encoder.writeU16(plan.envelope.input_index);
    try encodeStringSet(plan.envelope.keys, encoder);
    try encoder.writeBytes(plan.envelope.sequence_key);
    try encoder.writeBytes(plan.envelope.kind_key);
    try encoder.writeBytes(plan.envelope.previous_digest_key);
    try encoder.writeBytes(plan.envelope.body_key);
    try encoder.writeBytes(plan.envelope.body_digest_key);
    try encoder.writeBytes(plan.envelope.event_digest_key);
    try encoder.writeCount(plan.envelope.partition_bindings.len);
    for (plan.envelope.partition_bindings) |binding| {
        try encoder.writeBytes(binding.parameter);
        try encoder.writeEnum(binding.kind);
        try encoder.writeBytes(binding.event_value.raw);
    }
    try encoder.writeU64(plan.sequence_start);
    try encoder.writeOptionalBytes(switch (plan.genesis) {
        .null => null,
        .digest => |digest| digest,
    });
    try encodeStringSet(plan.event_kinds, encoder);
    try encoder.writeUsize(plan.max_records);
    try encoder.writeU16(plan.target_slot_index);
    try encoder.writeBool(plan.reducer_plan != null);
    if (plan.reducer_plan) |*compiled| {
        try reducer.encodeCache(compiled, encoder);
    }
    try encoder.writeBool(plan.state_reducer_plan != null);
    if (plan.state_reducer_plan) |*compiled| {
        try state_reducer.encodeCache(compiled, encoder);
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 4) {
        return error.LedgerProtocolCacheVersionMismatch;
    }
    var plan: Plan = plan: {
        const input_index = try decoder.readU16();
        const keys = try decodeStringSet(allocator, decoder, 64);
        errdefer deinitStringSet(allocator, keys);
        var field_keys: [6][]u8 = undefined;
        var initialized: usize = 0;
        errdefer for (field_keys[0..initialized]) |key| allocator.free(key);
        for (&field_keys) |*field_key| {
            field_key.* = try decoder.readBytesAlloc(allocator, 256);
            initialized += 1;
            try definition_core.json.safeIdentifier(field_key.*, 256);
        }
        const partition_bindings = try decodePartitionBindings(
            allocator,
            decoder,
        );
        errdefer {
            for (partition_bindings) |*binding| {
                binding.deinit(allocator);
            }
            allocator.free(partition_bindings);
        }
        const sequence_start = try decoder.readU64();
        const raw_genesis = try decoder.readOptionalBytesAlloc(
            allocator,
            71,
        );
        var genesis: Genesis = if (raw_genesis) |digest| digest: {
            errdefer allocator.free(digest);
            try definition_core.json.digest(digest);
            break :digest .{ .digest = digest };
        } else .null;
        errdefer genesis.deinit(allocator);
        const event_kinds = try decodeStringSet(allocator, decoder, 256);
        errdefer deinitStringSet(allocator, event_kinds);
        var reducer_plan: ?reducer.Plan = null;
        errdefer if (reducer_plan) |*compiled| compiled.deinit(allocator);
        var state_reducer_plan: ?state_reducer.Plan = null;
        errdefer if (state_reducer_plan) |*compiled| {
            compiled.deinit(allocator);
        };
        const max_records = try decoder.readUsize();
        const target_slot_index = try decoder.readU16();
        if (try decoder.readBool()) {
            reducer_plan = try reducer.decodeCache(allocator, decoder);
        }
        if (try decoder.readBool()) {
            state_reducer_plan = try state_reducer.decodeCache(
                allocator,
                decoder,
            );
        }
        break :plan .{
            .envelope = .{
                .input_index = std.math.cast(u8, input_index) orelse
                    return error.CacheProtocolInputIndexInvalid,
                .keys = keys,
                .sequence_key = field_keys[0],
                .kind_key = field_keys[1],
                .previous_digest_key = field_keys[2],
                .body_key = field_keys[3],
                .body_digest_key = field_keys[4],
                .event_digest_key = field_keys[5],
                .partition_bindings = partition_bindings,
            },
            .sequence_start = sequence_start,
            .genesis = genesis,
            .event_kinds = event_kinds,
            .max_records = max_records,
            .target_slot_index = target_slot_index,
            .reducer_plan = reducer_plan,
            .state_reducer_plan = state_reducer_plan,
        };
    };
    errdefer plan.deinit(allocator);
    try validatePlan(&plan);
    return plan;
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
) !void {
    const reducer_declared = definition_plan.requires(.reducer);
    const transition_declared = definition_plan.requires(.transition_table);
    const legacy_reducer = plan.reducer_plan != null;
    const retained_reducer = plan.state_reducer_plan != null;
    try validatePlan(plan);
    if (plan.envelope.input_index >= definition_plan.inputs.len or
        definition_plan.inputs[plan.envelope.input_index].codec != .json or
        plan.max_records != definition_plan.bounds.max_records or
        definition_plan.storage_kind != .event_log or
        (definition_plan.operator_mask & required_operator_mask) !=
            required_operator_mask or
        (legacy_reducer and retained_reducer) or
        reducer_declared != (legacy_reducer or retained_reducer) or
        transition_declared != legacy_reducer)
    {
        return error.CacheProtocolPlanMismatch;
    }
    if (plan.reducer_plan) |*compiled| {
        if (compiled.max_entries !=
            definition_plan.bounds.max_reducer_states)
        {
            return error.CacheProtocolPlanMismatch;
        }
    }
    if (plan.state_reducer_plan) |*compiled| {
        try state_reducer.validatePlan(
            compiled,
            definition_plan,
            definition_plan.bounds.max_input_bytes,
        );
        try state_reducer.validateEventKinds(compiled, plan.event_kinds);
    }
    try validatePartitionBindingsAgainstDefinition(
        plan.envelope.partition_bindings,
        definition_plan,
    );
    const expected_slot = try compileTargetSlot(
        storage_plan,
        plan.envelope.input_index,
    );
    if (plan.target_slot_index != expected_slot) {
        return error.CacheProtocolPlanMismatch;
    }
    try validateStorageMaterializations(plan, storage_plan);
}

pub fn apply(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event_bytes: []const u8,
) !void {
    return applyWithParameters(
        allocator,
        plan,
        state,
        event_bytes,
        null,
    );
}

pub fn applyBound(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event_bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    return applyWithParameters(
        allocator,
        plan,
        state,
        event_bytes,
        parameters,
    );
}

fn applyWithParameters(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event_bytes: []const u8,
    parameters: ?*const definition_core.parameters.Bindings,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event_bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    return applyValueWithParameters(
        allocator,
        plan,
        state,
        parsed.value,
        parameters,
    );
}

pub fn applyValue(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event: std.json.Value,
) !void {
    return applyValueWithParameters(
        allocator,
        plan,
        state,
        event,
        null,
    );
}

pub fn applyValueBound(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event: std.json.Value,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    return applyValueWithParameters(
        allocator,
        plan,
        state,
        event,
        parameters,
    );
}

fn applyValueWithParameters(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event: std.json.Value,
    parameters: ?*const definition_core.parameters.Bindings,
) !void {
    if (state.records >= plan.max_records) {
        return error.ProtocolRecordBoundsExceeded;
    }
    const object = try definition_core.json.object(event);
    try validateEnvelopeKeys(object, plan.envelope.keys);
    try validatePartitionValues(
        plan.envelope.partition_bindings,
        event,
        parameters,
    );

    const sequence_value = object.get(plan.envelope.sequence_key) orelse
        return error.EventEnvelopeFieldMissing;
    const sequence = switch (sequence_value) {
        .integer => |value| if (value >= 0)
            @as(u64, @intCast(value))
        else
            return error.InvalidEventSequence,
        else => return error.InvalidEventSequence,
    };
    if (sequence != state.next_sequence) {
        return error.EventSequenceMismatch;
    }

    const kind = try definition_core.json.string(
        object.get(plan.envelope.kind_key) orelse
            return error.EventEnvelopeFieldMissing,
    );
    if (!containsSorted(plan.event_kinds, kind)) {
        return error.UnknownEventKind;
    }

    const claimed_previous = object.get(
        plan.envelope.previous_digest_key,
    ) orelse return error.EventEnvelopeFieldMissing;
    try validatePreviousDigest(plan, state, claimed_previous);

    const body = object.get(plan.envelope.body_key) orelse
        return error.EventEnvelopeFieldMissing;
    const claimed_body_digest = try definition_core.json.string(
        object.get(plan.envelope.body_digest_key) orelse
            return error.EventEnvelopeFieldMissing,
    );
    try definition_core.json.digest(claimed_body_digest);
    const computed_body_digest =
        try definition_core.canonical_json.digestValueAlloc(
            allocator,
            body,
        );
    defer allocator.free(computed_body_digest);
    if (!std.mem.eql(
        u8,
        claimed_body_digest,
        computed_body_digest,
    )) return error.EventBodyDigestMismatch;

    const claimed_event_digest = try definition_core.json.string(
        object.get(plan.envelope.event_digest_key) orelse
            return error.EventEnvelopeFieldMissing,
    );
    try definition_core.json.digest(claimed_event_digest);
    const computed_event_digest =
        try definition_core.canonical_json.fingerprintObjectOmittingAlloc(
            allocator,
            event,
            plan.envelope.event_digest_key,
        );
    defer allocator.free(computed_event_digest);
    if (!std.mem.eql(
        u8,
        claimed_event_digest,
        computed_event_digest,
    )) return error.EventDigestMismatch;

    if (state.next_sequence == std.math.maxInt(u64)) {
        return error.EventSequenceOverflow;
    }
    if (plan.reducer_plan) |*compiled| {
        try reducer.apply(
            allocator,
            compiled,
            &state.reducer_state,
            event,
        );
    }
    if (plan.state_reducer_plan) |*compiled| {
        try state_reducer.apply(
            allocator,
            compiled,
            &state.state_reducer_state,
            event,
        );
    }
    @memcpy(&state.previous_digest, claimed_event_digest);
    state.has_previous_digest = true;
    state.next_sequence += 1;
    state.records += 1;
}

fn validatePartitionValues(
    bindings: []const PartitionBinding,
    event: std.json.Value,
    parameters: ?*const definition_core.parameters.Bindings,
) !void {
    if (bindings.len == 0) return;
    const bound = parameters orelse
        return error.ProtocolPartitionParametersMissing;
    for (bindings) |binding| {
        const parameter = bound.find(binding.parameter) orelse
            return error.ProtocolPartitionParameterMissing;
        if (parameter.value.kind() != binding.kind) {
            return error.ProtocolPartitionParameterKindMismatch;
        }
        const actual = definition_core.json_pointer.lookup(
            event,
            binding.event_value,
        ) orelse return error.EventPartitionValueMissing;
        const matches = switch (parameter.value) {
            .string => |expected| stringValueEquals(actual, expected),
            .digest => |expected| stringValueEquals(actual, expected),
            .timestamp => |expected| stringValueEquals(actual, expected),
            .safe_identifier => |expected| stringValueEquals(actual, expected),
            .relative_path => |expected| stringValueEquals(actual, expected),
            .integer => |expected| actual == .integer and
                actual.integer == expected,
            .boolean => |expected| actual == .bool and
                actual.bool == expected,
        };
        if (!matches) return error.EventPartitionValueMismatch;
    }
}

fn stringValueEquals(value: std.json.Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
}

pub fn materializeEventAlloc(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const ReplayState,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    unix_seconds: i64,
) ![]u8 {
    if (materialization.generate.len != 0) {
        return error.GeneratedOutputsRequireTransaction;
    }
    const result = try materializeEvent(
        allocator,
        plan,
        state,
        materialization,
        request,
        null,
        unix_seconds,
        std.Io.Threaded.global_single_threaded.io(),
    );
    defer {
        for (result.generated_outputs) |*output| output.deinit(allocator);
        allocator.free(result.generated_outputs);
    }
    return result.content;
}

pub fn materializeEvent(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const ReplayState,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    parameters: ?*const definition_core.parameters.Bindings,
    unix_seconds: i64,
    io: std.Io,
) !MaterializedEvent {
    if (unix_seconds < 0) return error.InvalidEventUnixTimestamp;
    try validateEventMaterialization(plan, materialization);
    try validateForbiddenParameters(materialization, parameters);
    const request_object = try definition_core.json.object(request);
    try validateRequestKeys(
        allocator,
        request_object,
        materialization,
    );
    const body = request_object.get(
        materialization.body_input_field,
    ) orelse return error.EventBodyInputMissing;
    const generated_outputs = try generateOutputsAlloc(
        allocator,
        materialization.generate,
        io,
    );
    errdefer deinitGeneratedOutputs(allocator, generated_outputs);
    const canonical_body = try materializedBodyAlloc(
        allocator,
        plan,
        state,
        materialization,
        request_object,
        body,
        generated_outputs,
        parameters,
    );
    defer allocator.free(canonical_body);
    const body_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            canonical_body,
        );
    defer allocator.free(body_digest);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeByte('{');
    for (plan.envelope.keys, 0..) |key, index| {
        if (index != 0) try output.writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            key,
        );
        try output.writer.writeByte(':');
        if (std.mem.eql(u8, key, plan.envelope.sequence_key)) {
            try output.writer.print("{d}", .{state.next_sequence});
        } else if (std.mem.eql(u8, key, plan.envelope.previous_digest_key)) {
            try writePreviousDigest(&output.writer, plan, state);
        } else if (std.mem.eql(u8, key, plan.envelope.body_key)) {
            try output.writer.writeAll(canonical_body);
        } else if (std.mem.eql(u8, key, plan.envelope.body_digest_key)) {
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                body_digest,
            );
        } else if (std.mem.eql(u8, key, plan.envelope.event_digest_key)) {
            try output.writer.writeAll("\"\"");
        } else {
            const field = findEventField(
                materialization.fields,
                key,
            ) orelse return error.EventMaterializationFieldCoverageMismatch;
            try writeMaterializedField(
                allocator,
                &output.writer,
                field.source,
                request_object,
                state.next_sequence,
                unix_seconds,
            );
        }
    }
    try output.writer.writeByte('}');
    return .{
        .content = try definition_core.canonical_json.finalizeFingerprintAlloc(
            allocator,
            output.written(),
            plan.envelope.event_digest_key,
        ),
        .generated_outputs = generated_outputs,
    };
}

pub fn reconstructInputAlloc(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const ReplayState,
    materialization: *const storage.EventMaterialization,
    event: std.json.Value,
) ![]u8 {
    try validateEventMaterialization(plan, materialization);
    const event_object = try definition_core.json.object(event);
    try validateEnvelopeKeys(event_object, plan.envelope.keys);
    const Mapping = struct {
        key: []const u8,
        value: union(enum) {
            json: std.json.Value,
            literal: []const u8,
        },
    };
    var mappings: [129]Mapping = undefined;
    var count: usize = 0;
    const reconstructed_body = try reconstructedBodyAlloc(
        allocator,
        plan,
        state,
        materialization,
        event_object,
        event_object.get(plan.envelope.body_key) orelse
            return error.EventEnvelopeFieldMissing,
    );
    defer allocator.free(reconstructed_body);
    var parsed_body = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        reconstructed_body,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed_body.deinit();
    mappings[count] = .{
        .key = materialization.body_input_field,
        .value = .{ .json = parsed_body.value },
    };
    count += 1;
    for (materialization.fields) |field| {
        const value = event_object.get(field.field) orelse
            return error.EventEnvelopeFieldMissing;
        switch (field.source) {
            .input_field => |input_field| {
                mappings[count] = .{
                    .key = input_field,
                    .value = .{ .json = value },
                };
                count += 1;
            },
            .literal => |literal| {
                const canonical =
                    try definition_core.canonical_json.canonicalJsonAlloc(
                        allocator,
                        value,
                    );
                defer allocator.free(canonical);
                if (!std.mem.eql(u8, canonical, literal)) {
                    return error.EventLiteralMismatch;
                }
            },
            .sequence_text_prefix => |prefix| {
                const actual = try definition_core.json.string(value);
                const expected = try std.fmt.allocPrint(
                    allocator,
                    "{s}{d}",
                    .{ prefix, state.next_sequence },
                );
                defer allocator.free(expected);
                if (!std.mem.eql(u8, actual, expected)) {
                    return error.EventSequenceTextMismatch;
                }
            },
            .unix_seconds => switch (value) {
                .integer => |timestamp| {
                    if (timestamp < 0) return error.InvalidEventUnixTimestamp;
                },
                else => return error.InvalidEventUnixTimestamp,
            },
        }
    }
    for (materialization.request_literals) |literal| {
        mappings[count] = .{
            .key = literal.field,
            .value = .{ .literal = literal.literal },
        };
        count += 1;
    }
    std.mem.sort(Mapping, mappings[0..count], {}, struct {
        fn lessThan(_: void, left: Mapping, right: Mapping) bool {
            return std.mem.lessThan(u8, left.key, right.key);
        }
    }.lessThan);
    for (mappings[1..count], 1..) |mapping, index| {
        if (std.mem.eql(u8, mappings[index - 1].key, mapping.key)) {
            return error.DuplicateEventInputField;
        }
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    for (mappings[0..count], 0..) |mapping, index| {
        if (index != 0) try output.writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            mapping.key,
        );
        try output.writer.writeByte(':');
        switch (mapping.value) {
            .json => |value| {
                try definition_core.canonical_json.writeCanonicalJson(
                    allocator,
                    &output.writer,
                    value,
                );
            },
            .literal => |literal| try output.writer.writeAll(literal),
        }
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn validateForbiddenParameters(
    materialization: *const storage.EventMaterialization,
    parameters: ?*const definition_core.parameters.Bindings,
) !void {
    const bound = parameters orelse {
        if (materialization.body_fields.len != 0) {
            for (materialization.body_fields) |field| {
                if (field.source == .parameter_sha256) {
                    return error.EventParametersMissing;
                }
            }
        }
        return;
    };
    for (materialization.forbidden_parameters) |name| {
        if (bound.find(name) != null) {
            return error.ForbiddenEventParameter;
        }
    }
}

fn generateOutputsAlloc(
    allocator: std.mem.Allocator,
    definitions: []const storage.SecureTokenGeneration,
    io: std.Io,
) ![]GeneratedOutput {
    const outputs = try allocator.alloc(GeneratedOutput, definitions.len);
    var initialized: usize = 0;
    errdefer {
        for (outputs[0..initialized]) |*output| output.deinit(allocator);
        allocator.free(outputs);
    }
    for (definitions, 0..) |item, index| {
        var random: [64]u8 = undefined;
        defer @memset(&random, 0);
        try std.Io.randomSecure(io, random[0..item.byte_count]);
        const value_len = std.math.add(
            usize,
            item.prefix.len,
            2 * @as(usize, item.byte_count),
        ) catch return error.SecureTokenOutputTooLarge;
        const value = try allocator.alloc(u8, value_len);
        errdefer allocator.free(value);
        @memcpy(value[0..item.prefix.len], item.prefix);
        const hex = "0123456789abcdef";
        for (random[0..item.byte_count], 0..) |byte, byte_index| {
            const offset = item.prefix.len + byte_index * 2;
            value[offset] = hex[byte >> 4];
            value[offset + 1] = hex[byte & 0x0f];
        }
        outputs[index] = .{
            .name = try allocator.dupe(u8, item.name),
            .value = value,
        };
        initialized += 1;
    }
    return outputs;
}

fn deinitGeneratedOutputs(
    allocator: std.mem.Allocator,
    outputs: []GeneratedOutput,
) void {
    for (outputs) |*output| output.deinit(allocator);
    allocator.free(outputs);
}

fn materializedBodyAlloc(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const ReplayState,
    materialization: *const storage.EventMaterialization,
    request: std.json.ObjectMap,
    body: std.json.Value,
    generated_outputs: []const GeneratedOutput,
    parameters: ?*const definition_core.parameters.Bindings,
) ![]u8 {
    if (materialization.body_fields.len == 0) {
        return definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            body,
        );
    }
    const object = try definition_core.json.object(body);
    for (materialization.body_fields) |field| {
        const actual = object.get(field.field);
        switch (field.source) {
            .request_input => |input_name| {
                const body_value = actual orelse
                    return error.EventBodyFieldMissing;
                const request_value = request.get(input_name) orelse
                    return error.EventRequestFieldMissing;
                if (!try valuesEqualForCustody(
                    allocator,
                    body_value,
                    request_value,
                )) return error.EventBodyRequestInputMismatch;
            },
            .literal_mapping => |mapping| {
                const body_value = actual orelse
                    return error.EventBodyFieldMissing;
                if (!try valueMatchesCanonicalLiteral(
                    allocator,
                    body_value,
                    mapping.request_literal,
                )) return error.EventLiteralMismatch;
            },
            .generated_sha256, .parameter_sha256, .state_value => {
                if (actual != null) return error.EventBodyFieldCollision;
            },
        }
    }
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (findEventBodyField(
            materialization.body_fields,
            entry.key_ptr.*,
        ) != null) continue;
        try keys.append(allocator, entry.key_ptr.*);
    }
    sortStrings(keys.items);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    var key_index: usize = 0;
    var field_index: usize = 0;
    var written: usize = 0;
    while (key_index < keys.items.len or
        field_index < materialization.body_fields.len)
    {
        while (field_index < materialization.body_fields.len and
            materialization.body_fields[field_index].source == .request_input)
        {
            field_index += 1;
        }
        if (key_index == keys.items.len and
            field_index == materialization.body_fields.len) break;
        const use_field = field_index < materialization.body_fields.len and
            (key_index == keys.items.len or
                std.mem.order(
                    u8,
                    materialization.body_fields[field_index].field,
                    keys.items[key_index],
                ) == .lt);
        if (written != 0) try output.writer.writeByte(',');
        if (use_field) {
            const field = materialization.body_fields[field_index];
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                field.field,
            );
            try output.writer.writeByte(':');
            try writeMaterializedBodyField(
                allocator,
                &output.writer,
                plan,
                state,
                field.source,
                generated_outputs,
                parameters,
            );
            field_index += 1;
        } else {
            const key = keys.items[key_index];
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                key,
            );
            try output.writer.writeByte(':');
            try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                &output.writer,
                object.get(key).?,
            );
            key_index += 1;
        }
        written += 1;
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn writeMaterializedBodyField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    plan: *const Plan,
    state: *const ReplayState,
    source: storage.EventBodyFieldSource,
    generated_outputs: []const GeneratedOutput,
    parameters: ?*const definition_core.parameters.Bindings,
) !void {
    switch (source) {
        .generated_sha256 => |name| {
            const generated = findGeneratedOutput(
                generated_outputs,
                name,
            ) orelse return error.EventGeneratedOutputMissing;
            const digest =
                try definition_core.canonical_json.digestBytesAlloc(
                    allocator,
                    generated.value,
                );
            defer allocator.free(digest);
            try definition_core.canonical_json.writeCanonicalString(
                writer,
                digest,
            );
        },
        .parameter_sha256 => |config| {
            const bound = parameters orelse
                return error.EventParametersMissing;
            const parameter = bound.find(config.parameter) orelse
                return error.EventParameterMissing;
            const text = scalarText(parameter.value) orelse
                return error.EventParameterMustBeText;
            const digest =
                try definition_core.canonical_json.digestBytesAlloc(
                    allocator,
                    text,
                );
            defer allocator.free(digest);
            const expected = try stateSourceValue(
                plan,
                state,
                config.expected_state,
            );
            if (expected != .string or
                !timingSafeDigestEqual(digest, expected.string))
            {
                return error.EventCapabilityMismatch;
            }
            try definition_core.canonical_json.writeCanonicalString(
                writer,
                digest,
            );
        },
        .state_value => |config| {
            const value = try stateSourceValue(plan, state, config);
            try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                writer,
                value,
            );
        },
        .literal_mapping => |mapping| {
            try writer.writeAll(mapping.stored_literal);
        },
        .request_input => unreachable,
    }
}

fn reconstructedBodyAlloc(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const ReplayState,
    materialization: *const storage.EventMaterialization,
    event: std.json.ObjectMap,
    body: std.json.Value,
) ![]u8 {
    if (materialization.body_fields.len == 0) {
        return definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            body,
        );
    }
    const object = try definition_core.json.object(body);
    for (materialization.body_fields) |field| {
        switch (field.source) {
            .request_input => {
                if (object.get(field.field) != null) {
                    return error.EventBodyFieldSetInvalid;
                }
            },
            else => {
                const actual = object.get(field.field) orelse
                    return error.EventBodyFieldMissing;
                try validateStoredBodyField(
                    allocator,
                    plan,
                    state,
                    field.source,
                    actual,
                );
            },
        }
    }
    const Mapping = struct {
        key: []const u8,
        value: union(enum) {
            json: std.json.Value,
            literal: []const u8,
        },
    };
    var mappings: std.ArrayList(Mapping) = .empty;
    defer mappings.deinit(allocator);
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (findEventBodyField(
            materialization.body_fields,
            entry.key_ptr.*,
        ) == null) try mappings.append(allocator, .{
            .key = entry.key_ptr.*,
            .value = .{ .json = entry.value_ptr.* },
        });
    }
    for (materialization.body_fields) |field| switch (field.source) {
        .request_input => |input_name| {
            try mappings.append(allocator, .{
                .key = field.field,
                .value = .{ .json = try eventValueForRequestInput(
                    materialization,
                    event,
                    input_name,
                ) },
            });
        },
        .literal_mapping => |mapping| {
            try mappings.append(allocator, .{
                .key = field.field,
                .value = .{ .literal = mapping.request_literal },
            });
        },
        .generated_sha256, .parameter_sha256, .state_value => {},
    };
    std.mem.sort(Mapping, mappings.items, {}, struct {
        fn lessThan(_: void, left: Mapping, right: Mapping) bool {
            return std.mem.lessThan(u8, left.key, right.key);
        }
    }.lessThan);
    if (mappings.items.len > 1) {
        for (mappings.items[1..], 1..) |mapping, index| {
            if (std.mem.eql(u8, mappings.items[index - 1].key, mapping.key)) {
                return error.EventBodyFieldSetInvalid;
            }
        }
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    for (mappings.items, 0..) |mapping, index| {
        if (index != 0) try output.writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            mapping.key,
        );
        try output.writer.writeByte(':');
        switch (mapping.value) {
            .json => |value| {
                try definition_core.canonical_json.writeCanonicalJson(
                    allocator,
                    &output.writer,
                    value,
                );
            },
            .literal => |literal| try output.writer.writeAll(literal),
        }
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn validateStoredBodyField(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const ReplayState,
    source: storage.EventBodyFieldSource,
    actual: std.json.Value,
) !void {
    switch (source) {
        .generated_sha256 => {
            if (actual != .string) return error.EventBodyDigestInvalid;
            try definition_core.json.digest(actual.string);
        },
        .parameter_sha256 => |config| {
            const expected = try stateSourceValue(
                plan,
                state,
                config.expected_state,
            );
            if (!try valuesEqualForCustody(
                allocator,
                actual,
                expected,
            )) return error.EventCapabilityMismatch;
        },
        .state_value => |config| {
            const expected = try stateSourceValue(plan, state, config);
            if (!try valuesEqualForCustody(
                allocator,
                actual,
                expected,
            )) return error.EventStateValueMismatch;
        },
        .literal_mapping => |mapping| {
            if (!try valueMatchesCanonicalLiteral(
                allocator,
                actual,
                mapping.stored_literal,
            )) return error.EventLiteralMismatch;
        },
        .request_input => unreachable,
    }
}

fn valueMatchesCanonicalLiteral(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    literal: []const u8,
) !bool {
    const canonical =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            value,
        );
    defer allocator.free(canonical);
    return std.mem.eql(u8, canonical, literal);
}

fn eventValueForRequestInput(
    materialization: *const storage.EventMaterialization,
    event: std.json.ObjectMap,
    input_name: []const u8,
) !std.json.Value {
    for (materialization.fields) |field| switch (field.source) {
        .input_field => |candidate| {
            if (std.mem.eql(u8, candidate, input_name)) {
                return event.get(field.field) orelse
                    error.EventEnvelopeFieldMissing;
            }
        },
        else => {},
    };
    return error.EventBodyRequestInputMissing;
}

fn valuesEqualForCustody(
    allocator: std.mem.Allocator,
    left: std.json.Value,
    right: std.json.Value,
) !bool {
    if (left == .string and right == .string and
        isDigest(left.string) and isDigest(right.string))
    {
        return timingSafeDigestEqual(left.string, right.string);
    }
    const left_canonical =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            left,
        );
    defer allocator.free(left_canonical);
    const right_canonical =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            right,
        );
    defer allocator.free(right_canonical);
    return std.mem.eql(u8, left_canonical, right_canonical);
}

fn stateSourceValue(
    plan: *const Plan,
    state: *const ReplayState,
    source: storage.StateValueSource,
) !std.json.Value {
    const reducer_plan = if (plan.state_reducer_plan) |*value|
        value
    else
        return error.EventStateReducerMissing;
    const root = state.state_reducer_state.get(
        reducer_plan,
        source.register,
    ) orelse return error.EventStateRegisterMissing;
    return definition_core.json_pointer.lookup(
        root,
        source.pointer,
    ) orelse return error.EventStateValueMissing;
}

fn scalarText(
    value: definition_core.scalar.Value,
) ?[]const u8 {
    return switch (value) {
        .string,
        .digest,
        .timestamp,
        .safe_identifier,
        .relative_path,
        => |text| text,
        .integer, .boolean => null,
    };
}

fn findGeneratedOutput(
    outputs: []const GeneratedOutput,
    name: []const u8,
) ?*const GeneratedOutput {
    var low: usize = 0;
    var high = outputs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, outputs[mid].name, name)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return &outputs[mid],
        }
    }
    return null;
}

fn findEventBodyField(
    fields: []const storage.EventBodyField,
    name: []const u8,
) ?*const storage.EventBodyField {
    var low: usize = 0;
    var high = fields.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, fields[mid].field, name)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return &fields[mid],
        }
    }
    return null;
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(
            _: void,
            left: []const u8,
            right: []const u8,
        ) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

fn isDigest(text: []const u8) bool {
    definition_core.json.digest(text) catch return false;
    return true;
}

fn timingSafeDigestEqual(left: []const u8, right: []const u8) bool {
    const left_bytes = digestBytes(left) catch return false;
    const right_bytes = digestBytes(right) catch return false;
    return std.crypto.timing_safe.eql([32]u8, left_bytes, right_bytes);
}

fn digestBytes(text: []const u8) ![32]u8 {
    try definition_core.json.digest(text);
    var bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, text["sha256:".len..]);
    return bytes;
}

fn validateRequestKeys(
    allocator: std.mem.Allocator,
    request: std.json.ObjectMap,
    materialization: *const storage.EventMaterialization,
) !void {
    var expected: usize = 1 + materialization.request_literals.len;
    for (materialization.fields) |field| switch (field.source) {
        .input_field => expected += 1,
        else => {},
    };
    if (request.count() != expected) return error.EventRequestKeysMismatch;
    if (!request.contains(materialization.body_input_field)) {
        return error.EventBodyInputMissing;
    }
    for (materialization.fields) |field| switch (field.source) {
        .input_field => |input_field| {
            if (!request.contains(input_field)) {
                return error.EventRequestFieldMissing;
            }
        },
        else => {},
    };
    for (materialization.request_literals) |literal| {
        const actual = request.get(literal.field) orelse
            return error.EventRequestFieldMissing;
        const canonical =
            try definition_core.canonical_json.canonicalJsonAlloc(
                allocator,
                actual,
            );
        defer allocator.free(canonical);
        if (!std.mem.eql(u8, canonical, literal.literal)) {
            return error.EventRequestLiteralMismatch;
        }
    }
}

fn writePreviousDigest(
    writer: *std.Io.Writer,
    plan: *const Plan,
    state: *const ReplayState,
) !void {
    if (state.previousDigest()) |digest| {
        return definition_core.canonical_json.writeCanonicalString(
            writer,
            digest,
        );
    }
    switch (plan.genesis) {
        .null => try writer.writeAll("null"),
        .digest => |digest| {
            try definition_core.canonical_json.writeCanonicalString(
                writer,
                digest,
            );
        },
    }
}

fn writeMaterializedField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    source: storage.EventFieldSource,
    request: std.json.ObjectMap,
    sequence: u64,
    unix_seconds: i64,
) !void {
    switch (source) {
        .input_field => |input_field| {
            const value = request.get(input_field) orelse
                return error.EventRequestFieldMissing;
            try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                writer,
                value,
            );
        },
        .literal => |literal| try writer.writeAll(literal),
        .sequence_text_prefix => |prefix| {
            const value = try std.fmt.allocPrint(
                allocator,
                "{s}{d}",
                .{ prefix, sequence },
            );
            defer allocator.free(value);
            try definition_core.canonical_json.writeCanonicalString(
                writer,
                value,
            );
        },
        .unix_seconds => try writer.print("{d}", .{unix_seconds}),
    }
}

fn setRule(slot: *?definition.Rule, rule: definition.Rule) !void {
    if (slot.* != null) return error.DuplicateEventProtocolRule;
    slot.* = rule;
}

fn compileEnvelope(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rule: definition.Rule,
) !Envelope {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = parsed.value.object;
    try definition_core.json.requireExactKeys(object, &.{
        "op",
        "input",
        "keys",
        "sequence",
        "kind",
        "previous_digest",
        "body",
        "body_digest",
        "event_digest",
        "partition_bindings",
    });
    try definition_core.json.requireFields(object, &.{
        "op",
        "input",
        "keys",
        "sequence",
        "kind",
        "previous_digest",
        "body",
        "body_digest",
        "event_digest",
    });
    try requireOperator(object, .event_envelope);
    const input_index = findInput(
        definition_plan.inputs,
        try definition_core.json.requiredString(object, "input"),
    ) orelse return error.UnknownProtocolInput;
    if (definition_plan.inputs[input_index].codec != .json) {
        return error.ProtocolInputMustBeJson;
    }
    const keys = try parseStringSet(
        allocator,
        try definition_core.json.field(object, "keys"),
        64,
    );
    errdefer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }
    var field_keys: [6][]u8 = undefined;
    var initialized: usize = 0;
    errdefer for (field_keys[0..initialized]) |key| allocator.free(key);
    inline for (.{
        "sequence",
        "kind",
        "previous_digest",
        "body",
        "body_digest",
        "event_digest",
    }, 0..) |name, index| {
        field_keys[index] = try rootKeyFromPointer(
            allocator,
            try definition_core.json.requiredString(object, name),
        );
        initialized += 1;
        if (!containsSorted(keys, field_keys[index])) {
            return error.EventEnvelopeFieldNotDeclared;
        }
        for (field_keys[0..index]) |prior| {
            if (std.mem.eql(u8, prior, field_keys[index])) {
                return error.DuplicateEventEnvelopeField;
            }
        }
    }
    const partition_bindings = if (object.get("partition_bindings")) |raw|
        try compilePartitionBindings(
            allocator,
            definition_plan,
            raw,
        )
    else
        try allocator.alloc(PartitionBinding, 0);
    errdefer {
        for (partition_bindings) |*binding| binding.deinit(allocator);
        allocator.free(partition_bindings);
    }
    return .{
        .input_index = @intCast(input_index),
        .keys = keys,
        .sequence_key = field_keys[0],
        .kind_key = field_keys[1],
        .previous_digest_key = field_keys[2],
        .body_key = field_keys[3],
        .body_digest_key = field_keys[4],
        .event_digest_key = field_keys[5],
        .partition_bindings = partition_bindings,
    };
}

fn compilePartitionBindings(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) ![]PartitionBinding {
    const values = try definition_core.json.array(raw);
    if (values.items.len > 32) {
        return error.TooManyProtocolPartitionBindings;
    }
    const bindings = try allocator.alloc(
        PartitionBinding,
        values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (bindings[0..initialized]) |*binding| {
            binding.deinit(allocator);
        }
        allocator.free(bindings);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "parameter", "event_value" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "parameter", "event_value" },
        );
        const parameter = try definition_core.json.requiredString(
            object,
            "parameter",
        );
        try definition_core.json.safeIdentifier(parameter, 128);
        const declaration =
            definition_plan.parameter_declarations.find(parameter) orelse
            return error.UnknownProtocolPartitionParameter;
        bindings[index] = .{
            .parameter = try allocator.dupe(u8, parameter),
            .kind = declaration.kind,
            .event_value = try definition_core.json_pointer.compile(
                allocator,
                try definition_core.json.requiredString(
                    object,
                    "event_value",
                ),
            ),
        };
        initialized += 1;
    }
    std.mem.sort(PartitionBinding, bindings, {}, struct {
        fn lessThan(
            _: void,
            left: PartitionBinding,
            right: PartitionBinding,
        ) bool {
            return std.mem.lessThan(
                u8,
                left.parameter,
                right.parameter,
            );
        }
    }.lessThan);
    for (bindings[1..], 1..) |binding, index| {
        if (std.mem.eql(
            u8,
            bindings[index - 1].parameter,
            binding.parameter,
        )) return error.DuplicateProtocolPartitionParameter;
    }
    return bindings;
}

fn compileSequence(
    allocator: std.mem.Allocator,
    rule: definition.Rule,
) !u64 {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = parsed.value.object;
    try definition_core.json.requireExactKeys(object, &.{ "op", "start" });
    try definition_core.json.requireFields(object, &.{ "op", "start" });
    try requireOperator(object, .sequence);
    const start = try definition_core.json.unsigned(
        try definition_core.json.field(object, "start"),
    );
    if (start > std.math.maxInt(i64)) {
        return error.InvalidEventSequenceStart;
    }
    return start;
}

fn compileGenesis(
    allocator: std.mem.Allocator,
    rule: definition.Rule,
) !Genesis {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = parsed.value.object;
    try definition_core.json.requireExactKeys(object, &.{ "op", "genesis" });
    try definition_core.json.requireFields(object, &.{ "op", "genesis" });
    try requireOperator(object, .previous_digest);
    return switch (try definition_core.json.field(object, "genesis")) {
        .null => .null,
        .string => |value| blk: {
            try definition_core.json.digest(value);
            break :blk .{ .digest = try allocator.dupe(u8, value) };
        },
        else => error.InvalidProtocolGenesis,
    };
}

fn compileMarkerRule(
    allocator: std.mem.Allocator,
    rule: definition.Rule,
    expected: definition.Operator,
) !void {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = parsed.value.object;
    try definition_core.json.requireExactKeys(object, &.{"op"});
    try definition_core.json.requireFields(object, &.{"op"});
    try requireOperator(object, expected);
}

fn compileEventKinds(
    allocator: std.mem.Allocator,
    rule: definition.Rule,
) ![][]u8 {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = parsed.value.object;
    try definition_core.json.requireExactKeys(object, &.{ "op", "values" });
    try definition_core.json.requireFields(object, &.{ "op", "values" });
    try requireOperator(object, .event_kinds);
    return parseStringSet(
        allocator,
        try definition_core.json.field(object, "values"),
        256,
    );
}

fn parseRule(
    allocator: std.mem.Allocator,
    rule: definition.Rule,
) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        rule.canonical_config,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    if (parsed.value != .object) {
        var mutable = parsed;
        mutable.deinit();
        return error.ExpectedObject;
    }
    return parsed;
}

fn requireOperator(
    object: std.json.ObjectMap,
    expected: definition.Operator,
) !void {
    const actual = try definition.Operator.parse(
        try definition_core.json.requiredString(object, "op"),
    );
    if (actual != expected) return error.EventProtocolOperatorMismatch;
}

fn rootKeyFromPointer(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    var pointer = try definition_core.json_pointer.compile(
        allocator,
        raw,
    );
    defer pointer.deinit(allocator);
    if (pointer.segments.len != 1 or pointer.segments[0].len == 0) {
        return error.EventEnvelopePointerMustNameRootField;
    }
    return allocator.dupe(u8, pointer.segments[0]);
}

fn parseStringSet(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    max_count: usize,
) ![][]u8 {
    const items = try definition_core.json.array(value);
    if (items.items.len == 0 or items.items.len > max_count) {
        return error.InvalidProtocolStringSet;
    }
    const out = try allocator.alloc([]u8, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items.items, 0..) |item, index| {
        const text = try definition_core.json.string(item);
        try definition_core.json.safeIdentifier(text, 256);
        out[index] = try allocator.dupe(u8, text);
        initialized += 1;
    }
    std.mem.sort([]u8, out, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for (out[1..], 1..) |item, index| {
        if (std.mem.eql(u8, out[index - 1], item)) {
            return error.DuplicateProtocolString;
        }
    }
    return out;
}

fn encodeStringSet(
    items: []const []u8,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(items.len);
    for (items) |item| try encoder.writeBytes(item);
}

fn decodeStringSet(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    max_count: usize,
) ![][]u8 {
    const count = try decoder.readCount(max_count);
    if (count == 0) return error.InvalidProtocolStringSet;
    const out = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (out, 0..) |*item, index| {
        item.* = try decoder.readBytesAlloc(allocator, 256);
        initialized += 1;
        try definition_core.json.safeIdentifier(item.*, 256);
        if (index != 0 and
            std.mem.order(u8, out[index - 1], item.*) != .lt)
        {
            return error.CacheProtocolStringsNotSorted;
        }
    }
    return out;
}

fn decodePartitionBindings(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]PartitionBinding {
    const count = try decoder.readCount(32);
    const bindings = try allocator.alloc(PartitionBinding, count);
    var initialized: usize = 0;
    errdefer {
        for (bindings[0..initialized]) |*binding| {
            binding.deinit(allocator);
        }
        allocator.free(bindings);
    }
    for (bindings, 0..) |*binding, index| {
        const parameter = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(parameter);
        try definition_core.json.safeIdentifier(parameter, 128);
        if (index != 0 and
            std.mem.order(
                u8,
                bindings[index - 1].parameter,
                parameter,
            ) != .lt)
        {
            return error.CacheProtocolPartitionBindingsNotSorted;
        }
        const kind = try decoder.readEnum(definition_core.scalar.Kind);
        const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw_pointer);
        binding.* = .{
            .parameter = parameter,
            .kind = kind,
            .event_value = try definition_core.json_pointer.compile(
                allocator,
                raw_pointer,
            ),
        };
        initialized += 1;
    }
    return bindings;
}

fn deinitStringSet(
    allocator: std.mem.Allocator,
    items: [][]u8,
) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn validatePlan(plan: *const Plan) !void {
    if (plan.envelope.keys.len == 0 or plan.envelope.keys.len > 64 or
        plan.event_kinds.len == 0 or plan.event_kinds.len > 256 or
        plan.sequence_start > std.math.maxInt(i64) or
        plan.max_records == 0 or plan.max_records > 10_000_000)
    {
        return error.InvalidProtocolPlan;
    }
    try validateSortedStringSet(plan.envelope.keys);
    try validateSortedStringSet(plan.event_kinds);
    if (plan.envelope.partition_bindings.len > 32) {
        return error.InvalidProtocolPartitionBindings;
    }
    for (plan.envelope.partition_bindings, 0..) |binding, index| {
        try definition_core.json.safeIdentifier(binding.parameter, 128);
        if (index != 0 and
            std.mem.order(
                u8,
                plan.envelope.partition_bindings[index - 1].parameter,
                binding.parameter,
            ) != .lt)
        {
            return error.InvalidProtocolPartitionBindings;
        }
    }
    const fields = [_][]const u8{
        plan.envelope.sequence_key,
        plan.envelope.kind_key,
        plan.envelope.previous_digest_key,
        plan.envelope.body_key,
        plan.envelope.body_digest_key,
        plan.envelope.event_digest_key,
    };
    for (fields, 0..) |field, index| {
        try definition_core.json.safeIdentifier(field, 256);
        if (!containsSorted(plan.envelope.keys, field)) {
            return error.EventEnvelopeFieldNotDeclared;
        }
        for (fields[0..index]) |prior| {
            if (std.mem.eql(u8, prior, field)) {
                return error.DuplicateEventEnvelopeField;
            }
        }
    }
    switch (plan.genesis) {
        .null => {},
        .digest => |digest| try definition_core.json.digest(digest),
    }
    if (plan.reducer_plan) |*compiled| try reducer.validatePlan(compiled);
    if (plan.reducer_plan != null and plan.state_reducer_plan != null) {
        return error.MultipleProtocolReducers;
    }
}

fn validatePartitionBindingsAgainstDefinition(
    bindings: []const PartitionBinding,
    definition_plan: *const definition.Plan,
) !void {
    for (bindings) |binding| {
        const declaration =
            definition_plan.parameter_declarations.find(
                binding.parameter,
            ) orelse return error.CacheProtocolPartitionBindingMismatch;
        if (declaration.kind != binding.kind) {
            return error.CacheProtocolPartitionBindingMismatch;
        }
    }
}

fn compileTargetSlot(
    storage_plan: *const storage.Plan,
    input_index: u8,
) !u16 {
    var target_slot_index: ?u16 = null;
    for (storage_plan.operations) |operation| {
        for (operation.effects) |effect| {
            if (effect.input_index != input_index) continue;
            const slot = storage_plan.slots[effect.slot_index];
            if (slot.kind != .event_log) {
                return error.ProtocolInputRequiresEventLogSlot;
            }
            switch (effect.kind) {
                .compare_append, .bind_existing => {},
                .create_new, .compare_replace => {
                    return error.ProtocolStoreMustBeAppendOnly;
                },
            }
            if (target_slot_index) |prior| {
                if (prior != effect.slot_index) {
                    return error.ProtocolInputHasMultipleSlots;
                }
            } else {
                target_slot_index = effect.slot_index;
            }
        }
    }
    const target = target_slot_index orelse
        return error.ProtocolInputHasNoStorageEffect;
    for (storage_plan.operations) |operation| {
        for (operation.effects) |effect| {
            if (effect.slot_index != target) continue;
            switch (effect.kind) {
                .compare_append, .bind_existing => {},
                .create_new, .compare_replace => {
                    return error.ProtocolStoreMustBeAppendOnly;
                },
            }
            if (effect.input_index != input_index and effect.event == null) {
                return error.ProtocolSlotHasUnmaterializedMixedInputs;
            }
        }
    }
    if (target >= storage_plan.slots.len) {
        return error.ProtocolTargetSlotInvalid;
    }
    return target;
}

fn validateStorageMaterializations(
    plan: *const Plan,
    storage_plan: *const storage.Plan,
) !void {
    var materialized_effects: usize = 0;
    var plain_effects: usize = 0;
    for (storage_plan.operations) |operation| {
        for (operation.effects) |effect| {
            if (effect.slot_index != plan.target_slot_index) continue;
            if (effect.event) |event| {
                materialized_effects += 1;
                try validateEventMaterialization(plan, &event);
            } else {
                plain_effects += 1;
            }
        }
    }
    if (materialized_effects != 0 and plain_effects != 0) {
        return error.MixedEventMaterializationModes;
    }
}

fn validateEventMaterialization(
    plan: *const Plan,
    event: *const storage.EventMaterialization,
) !void {
    const automatic = [_][]const u8{
        plan.envelope.sequence_key,
        plan.envelope.previous_digest_key,
        plan.envelope.body_key,
        plan.envelope.body_digest_key,
        plan.envelope.event_digest_key,
    };
    if (event.fields.len + automatic.len != plan.envelope.keys.len) {
        return error.EventMaterializationFieldCoverageMismatch;
    }
    for (automatic) |name| {
        if (findEventField(event.fields, name) != null) {
            return error.EventMaterializationOverridesAutomaticField;
        }
    }
    for (plan.envelope.keys) |name| {
        var is_automatic = false;
        for (automatic) |automatic_name| {
            if (std.mem.eql(u8, name, automatic_name)) {
                is_automatic = true;
                break;
            }
        }
        if (!is_automatic and findEventField(event.fields, name) == null) {
            return error.EventMaterializationFieldCoverageMismatch;
        }
    }
    if (findEventField(event.fields, plan.envelope.kind_key) == null) {
        return error.EventMaterializationKindMissing;
    }
    for (event.body_fields) |field| switch (field.source) {
        .generated_sha256 => {},
        .parameter_sha256 => |source| {
            try validateStateSource(plan, source.expected_state);
        },
        .state_value => |source| try validateStateSource(plan, source),
        .request_input => |input_name| {
            var matches: usize = 0;
            for (event.fields) |event_field| switch (event_field.source) {
                .input_field => |candidate| {
                    matches += @intFromBool(std.mem.eql(
                        u8,
                        candidate,
                        input_name,
                    ));
                },
                else => {},
            };
            if (matches != 1) return error.EventBodyRequestInputMissing;
        },
        .literal_mapping => {},
    };
}

fn validateStateSource(
    plan: *const Plan,
    source: storage.StateValueSource,
) !void {
    const reducer_plan = if (plan.state_reducer_plan) |*value|
        value
    else
        return error.EventStateReducerMissing;
    if (!state_reducer.hasRegister(reducer_plan, source.register)) {
        return error.EventStateRegisterUnknown;
    }
}

fn findEventField(
    fields: []const storage.EventField,
    name: []const u8,
) ?*const storage.EventField {
    var low: usize = 0;
    var high = fields.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, fields[mid].field, name)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return &fields[mid],
        }
    }
    return null;
}

fn validateSortedStringSet(items: []const []u8) !void {
    for (items, 0..) |item, index| {
        try definition_core.json.safeIdentifier(item, 256);
        if (index != 0 and
            std.mem.order(u8, items[index - 1], item) != .lt)
        {
            return error.CacheProtocolStringsNotSorted;
        }
    }
}

fn validateEnvelopeKeys(
    object: std.json.ObjectMap,
    expected: []const []u8,
) !void {
    if (object.count() != expected.len) return error.EventEnvelopeKeysMismatch;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!containsSorted(expected, entry.key_ptr.*)) {
            return error.EventEnvelopeKeysMismatch;
        }
    }
}

fn validatePreviousDigest(
    plan: *const Plan,
    state: *const ReplayState,
    value: std.json.Value,
) !void {
    if (state.has_previous_digest) {
        const claimed = try definition_core.json.string(value);
        try definition_core.json.digest(claimed);
        if (!std.mem.eql(
            u8,
            claimed,
            state.previous_digest[0..],
        )) return error.EventPreviousDigestMismatch;
        return;
    }
    switch (plan.genesis) {
        .null => if (value != .null) return error.EventGenesisMismatch,
        .digest => |expected| {
            const claimed = try definition_core.json.string(value);
            try definition_core.json.digest(claimed);
            if (!std.mem.eql(u8, claimed, expected)) {
                return error.EventGenesisMismatch;
            }
        },
    }
}

fn containsSorted(items: []const []u8, needle: []const u8) bool {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, items[mid], needle)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return true,
        }
    }
    return false;
}

fn findInput(
    inputs: []const definition.Input,
    name: []const u8,
) ?usize {
    for (inputs, 0..) |input, index| {
        if (std.mem.eql(u8, input.name, name)) return index;
    }
    return null;
}

fn operatorBit(operator: definition.Operator) u128 {
    return @as(u128, 1) << @intFromEnum(operator);
}

fn eventAlloc(
    allocator: std.mem.Allocator,
    sequence: u64,
    kind: []const u8,
    previous: ?[]const u8,
    body: []const u8,
) ![]u8 {
    const body_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            body,
        );
    defer allocator.free(body_digest);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"body\":");
    try output.writer.writeAll(body);
    try output.writer.writeAll(",\"body_digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        body_digest,
    );
    try output.writer.writeAll(",\"event_digest\":\"\",\"kind\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        kind,
    );
    try output.writer.writeAll(",\"previous_digest\":");
    if (previous) |digest| {
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            digest,
        );
    } else {
        try output.writer.writeAll("null");
    }
    try output.writer.print(",\"sequence\":{d}}}", .{sequence});
    return definition_core.canonical_json.finalizeFingerprintAlloc(
        allocator,
        output.written(),
        "event_digest",
    );
}

test "compiled event protocol validates exact chained envelopes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/protocol","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","compare-and-append","event-digest","event-envelope","event-kinds","previous-digest","replay","sequence"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"event-envelope","input":"event","keys":["body","body_digest","event_digest","kind","previous_digest","sequence"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest"}]},"constraints":[{"op":"sequence","start":1},{"op":"previous-digest","genesis":null},{"op":"body-digest"},{"op":"event-digest"},{"op":"event-kinds","values":["created","updated"]}],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"event"}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":2,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "protocol.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "protocol.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var storage_plan = try storage.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer storage_plan.deinit(std.testing.allocator);
    var plan = (try compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
    )).?;
    defer plan.deinit(std.testing.allocator);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(&plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try validateCachePlan(&cached, &definition_plan, &storage_plan);
    try std.testing.expectEqualStrings(
        plan.envelope.event_digest_key,
        cached.envelope.event_digest_key,
    );
    try std.testing.expectEqualStrings(
        plan.event_kinds[1],
        cached.event_kinds[1],
    );
    var state = ReplayState.init(&plan);
    defer state.deinit(std.testing.allocator);
    const first = try eventAlloc(
        std.testing.allocator,
        1,
        "created",
        null,
        "{\"id\":\"item-1\",\"status\":\"open\"}",
    );
    defer std.testing.allocator.free(first);
    try apply(std.testing.allocator, &plan, &state, first);
    try std.testing.expectEqual(@as(usize, 1), state.records);
    try std.testing.expectError(
        error.EventSequenceMismatch,
        apply(std.testing.allocator, &plan, &state, first),
    );
    const second = try eventAlloc(
        std.testing.allocator,
        2,
        "updated",
        state.previousDigest(),
        "{\"id\":\"item-1\",\"status\":\"closed\"}",
    );
    defer std.testing.allocator.free(second);
    try apply(std.testing.allocator, &plan, &state, second);
    try std.testing.expectEqual(@as(usize, 2), state.records);
    const third = try eventAlloc(
        std.testing.allocator,
        3,
        "updated",
        state.previousDigest(),
        "{\"id\":\"item-1\",\"status\":\"archived\"}",
    );
    defer std.testing.allocator.free(third);
    try std.testing.expectError(
        error.ProtocolRecordBoundsExceeded,
        apply(std.testing.allocator, &plan, &state, third),
    );
}

test "retained reducer validates events against compiled current state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/retained-protocol","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","compare-and-append","cross-input-equal","event-digest","event-envelope","event-kinds","previous-digest","reducer","replay","sequence"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"event-envelope","input":"event","keys":["body","body_digest","event_digest","kind","previous_digest","sequence"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest"}]},"constraints":[{"op":"sequence","start":1},{"op":"previous-digest","genesis":null},{"op":"body-digest"},{"op":"event-digest"},{"op":"event-kinds","values":["created","updated"]},{"op":"reducer","mode":"retained","event_kind":"/kind","registers":[{"name":"current","max_bytes":4096}],"admissions":[{"on":"created","requires":[],"forbids":["current"],"rules":[],"actions":[{"op":"set","register":"current","input":"event","path":"/body"}]},{"on":"updated","requires":["current"],"forbids":[],"rules":[{"op":"cross-input-equal","input":"event","left_input":"event","left":"/body/id","right_input":"current","right":"/id"}],"actions":[{"op":"set","register":"current","input":"event","path":"/body"}]}]}],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/retained.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"event"}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "protocol.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "protocol.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var storage_plan = try storage.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer storage_plan.deinit(std.testing.allocator);
    var plan = (try compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
    )).?;
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.reducer_plan == null);
    try std.testing.expect(plan.state_reducer_plan != null);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        256 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(&plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try validateCachePlan(&cached, &definition_plan, &storage_plan);

    var state = ReplayState.init(&cached);
    defer state.deinit(std.testing.allocator);
    const first = try eventAlloc(
        std.testing.allocator,
        1,
        "created",
        null,
        "{\"id\":\"item-1\",\"status\":\"open\"}",
    );
    defer std.testing.allocator.free(first);
    try apply(std.testing.allocator, &cached, &state, first);
    const current = state.state_reducer_state.get(
        &cached.state_reducer_plan.?,
        "current",
    ).?;
    var status_pointer = try definition_core.json_pointer.compile(
        std.testing.allocator,
        "/status",
    );
    defer status_pointer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "open",
        definition_core.json_pointer.lookup(
            current,
            status_pointer,
        ).?.string,
    );
    const second = try eventAlloc(
        std.testing.allocator,
        2,
        "updated",
        state.previousDigest(),
        "{\"id\":\"item-1\",\"status\":\"closed\"}",
    );
    defer std.testing.allocator.free(second);
    try apply(std.testing.allocator, &cached, &state, second);
    const stale = try eventAlloc(
        std.testing.allocator,
        3,
        "updated",
        state.previousDigest(),
        "{\"id\":\"item-2\",\"status\":\"closed\"}",
    );
    defer std.testing.allocator.free(stale);
    try std.testing.expectError(
        error.ProtocolAdmissionRejected,
        apply(std.testing.allocator, &cached, &state, stale),
    );
    try std.testing.expectEqual(@as(usize, 2), state.records);
}

test "event materialization reconstructs validated request literals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{
        \\  "schema":"ledger-artifact-definition/v1",
        \\  "id":"example/request-literals",
        \\  "owner":"example",
        \\  "requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","compare-and-append","enum","event-digest","event-envelope","event-kinds","exact-object","path-format","previous-digest","replay","sequence"]},
        \\  "parameters":{"stream":{"type":"safe_identifier","required":true}},
        \\  "inputs":{
        \\    "alternate":{"codec":"json","max_bytes":4096},
        \\    "request":{"codec":"json","max_bytes":4096}
        \\  },
        \\  "canonicalization":{},
        \\  "shape":{"rules":[
        \\    {"op":"exact-object","input":"alternate","path":"","keys":["body","kind","schema","stream_id"]},
        \\    {"op":"enum","input":"alternate","path":"/schema","values":["example-alternate/v1"]},
        \\    {"op":"exact-object","input":"request","path":"","keys":["body","kind","schema","stream_id"]},
        \\    {"op":"enum","input":"request","path":"/schema","values":["example-request/v1"]},
        \\    {"op":"event-envelope","input":"request","keys":["body","body_digest","event_digest","kind","previous_digest","schema","sequence","stream_id"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest","partition_bindings":[{"parameter":"stream","event_value":"/stream_id"}]}
        \\  ]},
        \\  "constraints":[
        \\    {"op":"sequence","start":1},
        \\    {"op":"previous-digest","genesis":null},
        \\    {"op":"body-digest"},
        \\    {"op":"event-digest"},
        \\    {"op":"event-kinds","values":["created"]}
        \\  ],
        \\  "identity":{},
        \\  "storage":{"kind":"event-log","slots":{"events":{"path":"example/{stream}/request-literals.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},
        \\  "operations":{
        \\    "append":{"effects":[{"op":"compare-and-append","slot":"events","input":"request","event":{
        \\      "body_input_field":"body",
        \\      "fields":[
        \\        {"field":"kind","input_field":"kind"},
        \\        {"field":"schema","literal":"example-event/v1"},
        \\        {"field":"stream_id","input_field":"stream_id"}
        \\      ],
        \\      "request_literals":[{"field":"schema","literal":"example-request/v1"}],
        \\      "body_fields":[
        \\        {"field":"schema","literal_mapping":{"request":"example-body-request/v1","stored":"example-body-event/v1"}},
        \\        {"field":"stream_id","request_input":"stream_id"}
        \\      ]
        \\    }}]},
        \\    "append-alternate":{"effects":[{"op":"compare-and-append","slot":"events","input":"alternate","event":{
        \\      "body_input_field":"body",
        \\      "fields":[
        \\        {"field":"kind","input_field":"kind"},
        \\        {"field":"schema","literal":"example-event/v1"},
        \\        {"field":"stream_id","input_field":"stream_id"}
        \\      ],
        \\      "request_literals":[{"field":"schema","literal":"example-alternate/v1"}]
        \\    }}]}
        \\  },
        \\  "projections":{},
        \\  "bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}
        \\}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "protocol.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "protocol.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var storage_plan = try storage.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer storage_plan.deinit(std.testing.allocator);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        256 * 1024,
    );
    defer encoder.deinit();
    try storage.encodeCache(&storage_plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached_storage = try storage.decodeCache(
        std.testing.allocator,
        &decoder,
    );
    defer cached_storage.deinit(std.testing.allocator);
    try decoder.finish();
    try storage.validateCachePlan(&cached_storage, &definition_plan);
    var plan = (try compile(
        std.testing.allocator,
        &definition_plan,
        &cached_storage,
    )).?;
    defer plan.deinit(std.testing.allocator);
    const operation = cached_storage.findOperation("append").?;
    const materialization = &operation.effects[0].event.?;
    try std.testing.expectEqual(
        @as(usize, 1),
        materialization.request_literals.len,
    );

    var state = ReplayState.init(&plan);
    defer state.deinit(std.testing.allocator);
    var request = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"schema\":\"example-request/v1\",\"kind\":\"created\",\"stream_id\":\"stream-1\",\"body\":{\"id\":\"item-1\",\"schema\":\"example-body-request/v1\",\"stream_id\":\"stream-1\"}}",
        .{ .allocate = .alloc_always },
    );
    defer request.deinit();
    const event = try materializeEventAlloc(
        std.testing.allocator,
        &plan,
        &state,
        materialization,
        request.value,
        7,
    );
    defer std.testing.allocator.free(event);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            event,
            "\"schema\":\"example-event/v1\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            event,
            "\"body\":{\"id\":\"item-1\",\"schema\":\"example-body-event/v1\"}",
        ) != null,
    );
    var parsed_event = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        event,
        .{ .allocate = .alloc_always },
    );
    defer parsed_event.deinit();
    const reconstructed = try reconstructInputAlloc(
        std.testing.allocator,
        &plan,
        &state,
        materialization,
        parsed_event.value,
    );
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqualStrings(
        "{\"body\":{\"id\":\"item-1\",\"schema\":\"example-body-request/v1\",\"stream_id\":\"stream-1\"},\"kind\":\"created\",\"schema\":\"example-request/v1\",\"stream_id\":\"stream-1\"}",
        reconstructed,
    );
    var tampered_event = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"body\":{\"id\":\"item-1\",\"schema\":\"example-body-wrong/v1\"},\"body_digest\":\"\",\"event_digest\":\"\",\"kind\":\"created\",\"previous_digest\":null,\"schema\":\"example-event/v1\",\"sequence\":1,\"stream_id\":\"stream-1\"}",
        .{ .allocate = .alloc_always },
    );
    defer tampered_event.deinit();
    try std.testing.expectError(
        error.EventLiteralMismatch,
        reconstructInputAlloc(
            std.testing.allocator,
            &plan,
            &state,
            materialization,
            tampered_event.value,
        ),
    );
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "stream-1" }},
    );
    defer parameters.deinit(std.testing.allocator);
    try applyBound(
        std.testing.allocator,
        &plan,
        &state,
        event,
        &parameters,
    );
    var wrong_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "stream-2" }},
    );
    defer wrong_parameters.deinit(std.testing.allocator);
    var wrong_state = ReplayState.init(&plan);
    defer wrong_state.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.EventPartitionValueMismatch,
        applyBound(
            std.testing.allocator,
            &plan,
            &wrong_state,
            event,
            &wrong_parameters,
        ),
    );
    try std.testing.expectError(
        error.ProtocolPartitionParametersMissing,
        apply(
            std.testing.allocator,
            &plan,
            &wrong_state,
            event,
        ),
    );

    var invalid_request = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"schema\":\"wrong/v1\",\"kind\":\"created\",\"stream_id\":\"stream-1\",\"body\":{\"id\":\"item-1\"}}",
        .{ .allocate = .alloc_always },
    );
    defer invalid_request.deinit();
    try std.testing.expectError(
        error.EventRequestLiteralMismatch,
        materializeEventAlloc(
            std.testing.allocator,
            &plan,
            &state,
            materialization,
            invalid_request.value,
            7,
        ),
    );
    var mismatched_body_input = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"schema\":\"example-request/v1\",\"kind\":\"created\",\"stream_id\":\"stream-1\",\"body\":{\"id\":\"item-1\",\"schema\":\"example-body-request/v1\",\"stream_id\":\"stream-2\"}}",
        .{ .allocate = .alloc_always },
    );
    defer mismatched_body_input.deinit();
    try std.testing.expectError(
        error.EventBodyRequestInputMismatch,
        materializeEventAlloc(
            std.testing.allocator,
            &plan,
            &state,
            materialization,
            mismatched_body_input.value,
            7,
        ),
    );
}

test "event protocol rejects unknown kinds and broken digest links" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/protocol-errors","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","compare-and-append","event-digest","event-envelope","event-kinds","previous-digest","replay","sequence"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"event-envelope","input":"event","keys":["body","body_digest","event_digest","kind","previous_digest","sequence"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest"}]},"constraints":[{"op":"sequence","start":0},{"op":"previous-digest","genesis":null},{"op":"body-digest"},{"op":"event-digest"},{"op":"event-kinds","values":["accepted"]}],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/errors.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"event"}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "protocol.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "protocol.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var storage_plan = try storage.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer storage_plan.deinit(std.testing.allocator);
    var plan = (try compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
    )).?;
    defer plan.deinit(std.testing.allocator);

    var unknown_state = ReplayState.init(&plan);
    defer unknown_state.deinit(std.testing.allocator);
    const unknown = try eventAlloc(
        std.testing.allocator,
        0,
        "rejected",
        null,
        "{\"id\":\"item-1\"}",
    );
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(
        error.UnknownEventKind,
        apply(std.testing.allocator, &plan, &unknown_state, unknown),
    );

    var linked_state = ReplayState.init(&plan);
    defer linked_state.deinit(std.testing.allocator);
    const first = try eventAlloc(
        std.testing.allocator,
        0,
        "accepted",
        null,
        "{\"id\":\"item-1\"}",
    );
    defer std.testing.allocator.free(first);
    try apply(std.testing.allocator, &plan, &linked_state, first);
    const broken = try eventAlloc(
        std.testing.allocator,
        1,
        "accepted",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "{\"id\":\"item-1\"}",
    );
    defer std.testing.allocator.free(broken);
    try std.testing.expectError(
        error.EventPreviousDigestMismatch,
        apply(std.testing.allocator, &plan, &linked_state, broken),
    );
}
