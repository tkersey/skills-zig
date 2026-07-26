const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const reducer = @import("reducer.zig");
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

const Envelope = struct {
    input_index: u8,
    keys: [][]u8,
    sequence_key: []u8,
    kind_key: []u8,
    previous_digest_key: []u8,
    body_key: []u8,
    body_digest_key: []u8,
    event_digest_key: []u8,

    fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        for (self.keys) |key| allocator.free(key);
        allocator.free(self.keys);
        allocator.free(self.sequence_key);
        allocator.free(self.kind_key);
        allocator.free(self.previous_digest_key);
        allocator.free(self.body_key);
        allocator.free(self.body_digest_key);
        allocator.free(self.event_digest_key);
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

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.envelope.deinit(allocator);
        self.genesis.deinit(allocator);
        for (self.event_kinds) |kind| allocator.free(kind);
        allocator.free(self.event_kinds);
        if (self.reducer_plan) |*plan| plan.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReplayState = struct {
    next_sequence: u64,
    previous_digest: [71]u8 = undefined,
    has_previous_digest: bool = false,
    records: usize = 0,
    reducer_state: reducer.State = .{},

    pub fn init(plan: *const Plan) ReplayState {
        return .{ .next_sequence = plan.sequence_start };
    }

    pub fn deinit(self: *ReplayState, allocator: std.mem.Allocator) void {
        self.reducer_state.deinit(allocator);
        self.* = undefined;
    }

    pub fn previousDigest(self: *const ReplayState) ?[]const u8 {
        return if (self.has_previous_digest)
            self.previous_digest[0..]
        else
            null;
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
    if (definition_plan.requires(.transition_table) !=
        definition_plan.requires(.reducer))
    {
        return error.IncompleteReducerOperators;
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
    if (definition_plan.requires(.transition_table)) {
        if (rules.transition_table == null or rules.reducer == null) {
            return error.IncompleteReducerRules;
        }
        reducer_plan = try reducer.compile(
            allocator,
            rules.transition_table.?,
            rules.reducer.?,
            definition_plan.bounds.max_reducer_states,
        );
    } else if (rules.transition_table != null or rules.reducer != null) {
        return error.UndeclaredReducerRule;
    }
    const result: Plan = .{
        .envelope = envelope,
        .sequence_start = sequence_start,
        .genesis = genesis,
        .event_kinds = event_kinds,
        .max_records = definition_plan.bounds.max_records,
        .target_slot_index = target_slot_index,
        .reducer_plan = reducer_plan,
    };
    try validateStorageMaterializations(&result, storage_plan);
    return result;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(2);
    try encoder.writeU16(plan.envelope.input_index);
    try encodeStringSet(plan.envelope.keys, encoder);
    try encoder.writeBytes(plan.envelope.sequence_key);
    try encoder.writeBytes(plan.envelope.kind_key);
    try encoder.writeBytes(plan.envelope.previous_digest_key);
    try encoder.writeBytes(plan.envelope.body_key);
    try encoder.writeBytes(plan.envelope.body_digest_key);
    try encoder.writeBytes(plan.envelope.event_digest_key);
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
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 2) {
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
        const max_records = try decoder.readUsize();
        const target_slot_index = try decoder.readU16();
        if (try decoder.readBool()) {
            reducer_plan = try reducer.decodeCache(allocator, decoder);
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
            },
            .sequence_start = sequence_start,
            .genesis = genesis,
            .event_kinds = event_kinds,
            .max_records = max_records,
            .target_slot_index = target_slot_index,
            .reducer_plan = reducer_plan,
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
    const reducer_required = definition_plan.requires(.transition_table) and
        definition_plan.requires(.reducer);
    if (definition_plan.requires(.transition_table) !=
        definition_plan.requires(.reducer))
    {
        return error.CacheProtocolPlanMismatch;
    }
    try validatePlan(plan);
    if (plan.envelope.input_index >= definition_plan.inputs.len or
        definition_plan.inputs[plan.envelope.input_index].codec != .json or
        plan.max_records != definition_plan.bounds.max_records or
        definition_plan.storage_kind != .event_log or
        (definition_plan.operator_mask & required_operator_mask) !=
            required_operator_mask or
        (plan.reducer_plan != null) != reducer_required)
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
    return applyValue(allocator, plan, state, parsed.value);
}

pub fn applyValue(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event: std.json.Value,
) !void {
    if (state.records >= plan.max_records) {
        return error.ProtocolRecordBoundsExceeded;
    }
    const object = try definition_core.json.object(event);
    try validateEnvelopeKeys(object, plan.envelope.keys);

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
    @memcpy(&state.previous_digest, claimed_event_digest);
    state.has_previous_digest = true;
    state.next_sequence += 1;
    state.records += 1;
}

pub fn materializeEventAlloc(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const ReplayState,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    unix_seconds: i64,
) ![]u8 {
    if (unix_seconds < 0) return error.InvalidEventUnixTimestamp;
    try validateEventMaterialization(plan, materialization);
    const request_object = try definition_core.json.object(request);
    try validateRequestKeys(request_object, materialization);
    const body = request_object.get(
        materialization.body_input_field,
    ) orelse return error.EventBodyInputMissing;
    const body_digest =
        try definition_core.canonical_json.digestValueAlloc(
            allocator,
            body,
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
            try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                &output.writer,
                body,
            );
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
    return definition_core.canonical_json.finalizeFingerprintAlloc(
        allocator,
        output.written(),
        plan.envelope.event_digest_key,
    );
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
        value: std.json.Value,
    };
    var mappings: [65]Mapping = undefined;
    var count: usize = 0;
    mappings[count] = .{
        .key = materialization.body_input_field,
        .value = event_object.get(plan.envelope.body_key) orelse
            return error.EventEnvelopeFieldMissing,
    };
    count += 1;
    for (materialization.fields) |field| {
        const value = event_object.get(field.field) orelse
            return error.EventEnvelopeFieldMissing;
        switch (field.source) {
            .input_field => |input_field| {
                mappings[count] = .{ .key = input_field, .value = value };
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
        try definition_core.canonical_json.writeCanonicalJson(
            allocator,
            &output.writer,
            mapping.value,
        );
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn validateRequestKeys(
    request: std.json.ObjectMap,
    materialization: *const storage.EventMaterialization,
) !void {
    var expected: usize = 1;
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
    return .{
        .input_index = @intCast(input_index),
        .keys = keys,
        .sequence_key = field_keys[0],
        .kind_key = field_keys[1],
        .previous_digest_key = field_keys[2],
        .body_key = field_keys[3],
        .body_digest_key = field_keys[4],
        .event_digest_key = field_keys[5],
    };
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
            if (effect.slot_index == target and
                effect.input_index != input_index)
            {
                return error.ProtocolSlotHasMixedInputs;
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
