const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const reducer = @import("reducer.zig");
const state_reducer = @import("state_reducer.zig");
const storage = @import("storage.zig");
const checkpoint = @import("checkpoint.zig");
const segmented_event_log = @import("segmented_event_log.zig");

const max_event_kinds: usize = 256;
const replay_checkpoint_base_bytes: usize =
    8 + checkpoint_schema.len +
    8 + 71 +
    8 +
    1 + 8 + 71 +
    8 +
    max_event_kinds * 8 +
    8;

const chained_required_operator_mask =
    operatorBit(.event_envelope) |
    operatorBit(.sequence) |
    operatorBit(.previous_digest) |
    operatorBit(.body_digest) |
    operatorBit(.event_digest) |
    operatorBit(.event_kinds) |
    operatorBit(.replay);

const plain_required_operator_mask =
    operatorBit(.append_only_log) |
    operatorBit(.event_kinds) |
    operatorBit(.reducer) |
    operatorBit(.replay);

const chained_only_operator_mask =
    operatorBit(.event_envelope) |
    operatorBit(.sequence) |
    operatorBit(.previous_digest) |
    operatorBit(.body_digest) |
    operatorBit(.event_digest);

const protocol_operator_mask =
    chained_required_operator_mask |
    plain_required_operator_mask |
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

pub const Mode = enum {
    chained,
    plain,
};

pub const Plan = struct {
    mode: Mode,
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
    kind_counts: [max_event_kinds]usize =
        [_]usize{0} ** max_event_kinds,
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

    pub fn headDigest(
        self: *const ReplayState,
        plan: *const Plan,
    ) ?[]const u8 {
        if (plan.mode == .plain) return null;
        if (self.previousDigest()) |digest| return digest;
        return switch (plan.genesis) {
            .null => null,
            .digest => |digest| digest,
        };
    }

    pub fn eventKindCount(
        self: *const ReplayState,
        plan: *const Plan,
        index: usize,
    ) ?usize {
        if (index >= plan.event_kinds.len) return null;
        return self.kind_counts[index];
    }
};

pub const DecodedCheckpoint = struct {
    definition_digest: []u8,
    state: ReplayState,

    pub fn deinit(
        self: *DecodedCheckpoint,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.definition_digest);
        self.state.deinit(allocator);
        self.* = undefined;
    }
};

const checkpoint_schema = "ledger-replay-checkpoint/v1";

pub fn encodeCheckpointAlloc(
    allocator: std.mem.Allocator,
    state: *ReplayState,
    definition_digest: []const u8,
) ![]u8 {
    try definition_core.json.digest(definition_digest);
    var encoder = checkpoint.Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.writeBytes(checkpoint_schema);
    try encoder.writeBytes(definition_digest);
    try encoder.writeU64(state.next_sequence);
    try encoder.writeOptionalBytes(state.previousDigest());
    try encoder.writeU64(max_event_kinds);
    for (state.kind_counts) |count| {
        try encoder.writeU64(@intCast(count));
    }
    try encoder.writeU64(@intCast(state.records));
    try state.reducer_state.encodeCheckpoint(allocator, &encoder);
    try state.state_reducer_state.encodeCheckpoint(allocator, &encoder);
    return encoder.toOwnedSlice();
}

pub fn activateCheckpoint(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
) !void {
    if (plan.state_reducer_plan) |*state_plan| {
        try state_reducer.activateCheckpoint(
            allocator,
            state_plan,
            &state.state_reducer_state,
        );
    }
}

pub fn decodeCheckpoint(
    allocator: std.mem.Allocator,
    current_plan: ?*const Plan,
    bytes: []const u8,
) !DecodedCheckpoint {
    var decoder = try checkpoint.Decoder.init(bytes);
    const schema = try decoder.readBytes(checkpoint_schema.len);
    if (!std.mem.eql(u8, schema, checkpoint_schema)) {
        return error.UnsupportedReplayCheckpoint;
    }
    const digest_source = try decoder.readBytes(71);
    definition_core.json.digest(digest_source) catch
        return error.InvalidReplayCheckpoint;
    const definition_digest = try allocator.dupe(u8, digest_source);
    errdefer allocator.free(definition_digest);
    var state = if (current_plan) |plan|
        ReplayState.init(plan)
    else
        ReplayState{ .next_sequence = 0 };
    errdefer state.deinit(allocator);
    state.next_sequence = try decoder.readU64();
    if (try decoder.readOptionalBytes(71)) |digest| {
        definition_core.json.digest(digest) catch
            return error.InvalidReplayCheckpoint;
        @memcpy(&state.previous_digest, digest);
        state.has_previous_digest = true;
    }
    if (try decoder.readCount(max_event_kinds) != max_event_kinds) {
        return error.InvalidReplayCheckpoint;
    }
    var kind_total: usize = 0;
    for (&state.kind_counts) |*count| {
        count.* = try decoder.readUsize();
        kind_total = std.math.add(usize, kind_total, count.*) catch
            return error.InvalidReplayCheckpoint;
    }
    state.records = try decoder.readUsize();
    if (kind_total != state.records) return error.InvalidReplayCheckpoint;
    state.reducer_state = try reducer.State.decodeCheckpoint(
        allocator,
        &decoder,
    );
    state.state_reducer_state = try state_reducer.State.decodeCheckpoint(
        allocator,
        &decoder,
    );
    try decoder.finish();
    if (current_plan) |plan| try activateCheckpoint(allocator, plan, &state);
    return .{
        .definition_digest = definition_digest,
        .state = state,
    };
}

test "checkpoint lifetime counters exceed collection bounds" {
    const allocator = std.testing.allocator;
    var state = ReplayState{ .next_sequence = 10_000_002 };
    defer state.deinit(allocator);
    state.kind_counts[0] = checkpoint.max_collection_items + 1;
    state.records = checkpoint.max_collection_items + 1;
    const digest =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const encoded = try encodeCheckpointAlloc(allocator, &state, digest);
    defer allocator.free(encoded);
    var decoded = try decodeCheckpoint(allocator, null, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(state.records, decoded.state.records);
    try std.testing.expectEqual(
        state.kind_counts[0],
        decoded.state.kind_counts[0],
    );
}

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
    append_only_log: ?definition.Rule = null,
    envelope: ?definition.Rule = null,
    sequence: ?definition.Rule = null,
    previous_digest: ?definition.Rule = null,
    body_digest: ?definition.Rule = null,
    event_digest: ?definition.Rule = null,
    event_kinds: ?definition.Rule = null,
    transition_table: ?definition.Rule = null,
    reducer: ?definition.Rule = null,
};

fn collectProtocolRules(
    definition_plan: *const definition.Plan,
) !ProtocolRules {
    var rules: ProtocolRules = .{};
    for (definition_plan.rules) |rule| switch (rule.operator) {
        .append_only_log => try setRule(&rules.append_only_log, rule),
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
    return rules;
}

fn validateChainedRules(
    definition_plan: *const definition.Plan,
    rules: ProtocolRules,
) !void {
    if ((definition_plan.operator_mask & chained_required_operator_mask) !=
        chained_required_operator_mask)
    {
        return error.IncompleteEventProtocolOperators;
    }
    if (rules.envelope == null or rules.sequence == null or
        rules.previous_digest == null or rules.body_digest == null or
        rules.event_digest == null or rules.event_kinds == null)
    {
        return error.IncompleteEventProtocolRules;
    }
}

fn compileChainedMarkers(
    allocator: std.mem.Allocator,
    rules: ProtocolRules,
) !void {
    try compileMarkerRule(allocator, rules.body_digest.?, .body_digest);
    try compileMarkerRule(allocator, rules.event_digest.?, .event_digest);
}

const ReducerPlans = struct {
    keyed: ?reducer.Plan = null,
    retained: ?state_reducer.Plan = null,

    fn deinit(self: *ReducerPlans, allocator: std.mem.Allocator) void {
        if (self.keyed) |*plan| plan.deinit(allocator);
        if (self.retained) |*plan| plan.deinit(allocator);
        self.* = undefined;
    }
};

fn compileReducerPlans(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rules: ProtocolRules,
    event_kinds: []const []u8,
    mode: Mode,
) !ReducerPlans {
    const reducer_rule = rules.reducer orelse {
        if (rules.transition_table != null or
            definition_plan.requires(.transition_table) or
            definition_plan.requires(.reducer))
        {
            return error.IncompleteReducerRules;
        }
        return .{};
    };
    if (!definition_plan.requires(.reducer)) {
        return error.UndeclaredReducerRule;
    }
    if (try state_reducer.isRetainedRule(allocator, reducer_rule)) {
        return compileRetainedReducer(
            allocator,
            definition_plan,
            rules,
            reducer_rule,
            event_kinds,
        );
    }
    if (!definition_plan.requires(.transition_table) or
        rules.transition_table == null)
    {
        return error.IncompleteReducerRules;
    }
    var keyed = try reducer.compile(
        allocator,
        definition_plan,
        rules.transition_table.?,
        reducer_rule,
        definition_plan.bounds,
    );
    errdefer keyed.deinit(allocator);
    try reducer.validateEventKinds(&keyed, event_kinds);
    if (mode == .plain and keyed.event_kind == null) {
        return error.PlainKeyedReducerRequiresEventKind;
    }
    if (mode == .chained and keyed.event_kind != null) {
        return error.ChainedProtocolRejectsReducerEventKind;
    }
    return .{ .keyed = keyed };
}

fn compileRetainedReducer(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rules: ProtocolRules,
    reducer_rule: definition.Rule,
    event_kinds: []const []u8,
) !ReducerPlans {
    if (definition_plan.requires(.transition_table) or
        rules.transition_table != null)
    {
        return error.RetainedReducerRejectsTransitionTable;
    }
    var retained = try state_reducer.compile(
        allocator,
        definition_plan,
        reducer_rule,
        definition_plan.bounds.max_input_bytes,
    );
    errdefer retained.deinit(allocator);
    try state_reducer.validateEventKinds(&retained, event_kinds);
    return .{ .retained = retained };
}

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
) !?Plan {
    const present_mask = definition_plan.operator_mask & protocol_operator_mask;
    if (present_mask == 0) {
        try validateSegmentedSupport(
            definition_plan,
            storage_plan,
            null,
        );
        return null;
    }
    if (definition_plan.storage_kind != .event_log) {
        return error.ProtocolRequiresEventLogStorage;
    }
    const rules = try collectProtocolRules(definition_plan);
    if (rules.append_only_log != null or
        definition_plan.requires(.append_only_log))
    {
        return try compilePlain(allocator, definition_plan, storage_plan, rules);
    }
    try validateChainedRules(definition_plan, rules);
    var envelope = try compileEnvelope(
        allocator,
        definition_plan,
        rules.envelope.?,
    );
    errdefer envelope.deinit(allocator);
    const sequence_start = try compileSequence(allocator, rules.sequence.?);
    var genesis = try compileGenesis(
        allocator,
        rules.previous_digest.?,
    );
    errdefer genesis.deinit(allocator);
    try compileChainedMarkers(allocator, rules);
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
    var reducers = try compileReducerPlans(
        allocator,
        definition_plan,
        rules,
        event_kinds,
        .chained,
    );
    errdefer reducers.deinit(allocator);
    const result: Plan = .{
        .mode = .chained,
        .envelope = envelope,
        .sequence_start = sequence_start,
        .genesis = genesis,
        .event_kinds = event_kinds,
        .max_records = definition_plan.bounds.max_records,
        .target_slot_index = target_slot_index,
        .reducer_plan = reducers.keyed,
        .state_reducer_plan = reducers.retained,
    };
    try validateStorageMaterializations(&result, storage_plan);
    try validateSegmentedSupport(
        definition_plan,
        storage_plan,
        &result,
    );
    return result;
}

fn compilePlain(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    rules: ProtocolRules,
) !Plan {
    if ((definition_plan.operator_mask & plain_required_operator_mask) !=
        plain_required_operator_mask)
    {
        return error.IncompleteEventProtocolOperators;
    }
    if ((definition_plan.operator_mask & chained_only_operator_mask) != 0 or
        rules.envelope != null or
        rules.sequence != null or
        rules.previous_digest != null or
        rules.body_digest != null or
        rules.event_digest != null)
    {
        return error.MixedEventProtocolModes;
    }
    const append_rule = rules.append_only_log orelse
        return error.IncompleteEventProtocolRules;
    const event_kinds_rule = rules.event_kinds orelse
        return error.IncompleteEventProtocolRules;
    if (rules.reducer == null) return error.IncompleteReducerRules;
    var envelope = try compilePlainEnvelope(
        allocator,
        definition_plan,
        append_rule,
    );
    errdefer envelope.deinit(allocator);
    const event_kinds = try compileEventKinds(
        allocator,
        event_kinds_rule,
    );
    errdefer deinitStringSet(allocator, event_kinds);
    var reducers = try compileReducerPlans(
        allocator,
        definition_plan,
        rules,
        event_kinds,
        .plain,
    );
    errdefer reducers.deinit(allocator);
    const target_slot_index = try compileTargetSlot(
        storage_plan,
        envelope.input_index,
    );
    const result: Plan = .{
        .mode = .plain,
        .envelope = envelope,
        .sequence_start = 0,
        .genesis = .null,
        .event_kinds = event_kinds,
        .max_records = definition_plan.bounds.max_records,
        .target_slot_index = target_slot_index,
        .reducer_plan = reducers.keyed,
        .state_reducer_plan = reducers.retained,
    };
    try validatePlan(&result);
    try validateStorageMaterializations(&result, storage_plan);
    try validateSegmentedSupport(
        definition_plan,
        storage_plan,
        &result,
    );
    return result;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(7);
    try encoder.writeEnum(plan.mode);
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
    if (try decoder.readU16() != 7) {
        return error.LedgerProtocolCacheVersionMismatch;
    }
    const mode = try decoder.readEnum(Mode);
    var envelope = try decodeCacheEnvelope(allocator, decoder, mode);
    var envelope_owned = true;
    errdefer if (envelope_owned) envelope.deinit(allocator);
    const sequence_start = try decoder.readU64();
    var genesis = try decodeCacheGenesis(allocator, decoder);
    var genesis_owned = true;
    errdefer if (genesis_owned) genesis.deinit(allocator);
    const event_kinds = try decodeStringSet(
        allocator,
        decoder,
        256,
        false,
    );
    var event_kinds_owned = true;
    errdefer if (event_kinds_owned) {
        deinitStringSet(allocator, event_kinds);
    };
    const max_records = try decoder.readUsize();
    const target_slot_index = try decoder.readU16();
    var reducers = try decodeCacheReducers(allocator, decoder);
    var reducers_owned = true;
    errdefer if (reducers_owned) reducers.deinit(allocator);
    var plan: Plan = .{
        .mode = mode,
        .envelope = envelope,
        .sequence_start = sequence_start,
        .genesis = genesis,
        .event_kinds = event_kinds,
        .max_records = max_records,
        .target_slot_index = target_slot_index,
        .reducer_plan = reducers.keyed,
        .state_reducer_plan = reducers.retained,
    };
    envelope_owned = false;
    genesis_owned = false;
    event_kinds_owned = false;
    reducers_owned = false;
    errdefer plan.deinit(allocator);
    try validatePlan(&plan);
    return plan;
}

fn decodeCacheEnvelope(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    mode: Mode,
) !Envelope {
    const input_index = try decoder.readU16();
    const keys = try decodeStringSet(
        allocator,
        decoder,
        64,
        mode == .plain,
    );
    errdefer deinitStringSet(allocator, keys);
    const field_keys = try decodeCacheEnvelopeFields(
        allocator,
        decoder,
        mode,
    );
    errdefer for (field_keys) |key| allocator.free(key);
    const partition_bindings = try decodePartitionBindings(
        allocator,
        decoder,
    );
    errdefer {
        for (partition_bindings) |*binding| binding.deinit(allocator);
        allocator.free(partition_bindings);
    }
    return .{
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
    };
}

fn decodeCacheEnvelopeFields(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    mode: Mode,
) ![6][]u8 {
    var fields: [6][]u8 = undefined;
    var initialized: usize = 0;
    errdefer for (fields[0..initialized]) |key| allocator.free(key);
    for (&fields) |*field| {
        field.* = try decoder.readBytesAlloc(allocator, 256);
        initialized += 1;
        if (mode == .plain) {
            if (field.*.len != 0) {
                return error.CachePlainProtocolEnvelopeInvalid;
            }
        } else {
            try definition_core.json.safeIdentifier(field.*, 256);
        }
    }
    return fields;
}

fn decodeCacheGenesis(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Genesis {
    const raw = try decoder.readOptionalBytesAlloc(allocator, 71);
    const digest = raw orelse return .null;
    errdefer allocator.free(digest);
    try definition_core.json.digest(digest);
    return .{ .digest = digest };
}

fn decodeCacheReducers(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !ReducerPlans {
    var plans: ReducerPlans = .{};
    errdefer plans.deinit(allocator);
    if (try decoder.readBool()) {
        plans.keyed = try reducer.decodeCache(allocator, decoder);
    }
    if (try decoder.readBool()) {
        plans.retained = try state_reducer.decodeCache(allocator, decoder);
    }
    return plans;
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
    const expected_operator_mask = switch (plan.mode) {
        .chained => chained_required_operator_mask,
        .plain => plain_required_operator_mask,
    };
    try validatePlan(plan);
    if (plan.envelope.input_index >= definition_plan.inputs.len or
        definition_plan.inputs[plan.envelope.input_index].codec != .json or
        plan.max_records != definition_plan.bounds.max_records or
        definition_plan.storage_kind != .event_log or
        (definition_plan.operator_mask & expected_operator_mask) !=
            expected_operator_mask or
        (plan.mode == .plain and
            (definition_plan.operator_mask & chained_only_operator_mask) != 0) or
        (plan.mode == .chained and
            definition_plan.requires(.append_only_log)) or
        (legacy_reducer and retained_reducer) or
        reducer_declared != (legacy_reducer or retained_reducer) or
        transition_declared != legacy_reducer or
        (plan.mode == .plain and
            (legacy_reducer == retained_reducer or
                (legacy_reducer and
                    plan.reducer_plan.?.event_kind == null))))
    {
        return error.CacheProtocolPlanMismatch;
    }
    if (plan.reducer_plan) |*compiled| {
        if (compiled.max_entries !=
            definition_plan.bounds.max_reducer_states or
            compiled.max_retained_value_bytes !=
                definition_plan.bounds.max_input_bytes or
            compiled.max_retained_total_bytes !=
                definition_plan.bounds.max_store_bytes)
        {
            return error.CacheProtocolPlanMismatch;
        }
        try reducer.validateCachePlan(compiled, definition_plan);
        try reducer.validateEventKinds(compiled, plan.event_kinds);
    }
    if (plan.state_reducer_plan) |*compiled| {
        try state_reducer.validatePlan(
            compiled,
            definition_plan,
            definition_plan.bounds.max_input_bytes,
        );
        try state_reducer.validateEventKinds(compiled, plan.event_kinds);
    }
    if (plan.mode == .chained) {
        try validatePartitionBindingsAgainstDefinition(
            plan.envelope.partition_bindings,
            definition_plan,
        );
    }
    const expected_slot = try compileTargetSlot(
        storage_plan,
        plan.envelope.input_index,
    );
    if (plan.target_slot_index != expected_slot) {
        return error.CacheProtocolPlanMismatch;
    }
    try validateStorageMaterializations(plan, storage_plan);
    try validateSegmentedSupport(
        definition_plan,
        storage_plan,
        plan,
    );
}

pub fn validateSegmentedSupport(
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const Plan,
) !void {
    var segmented_slots: usize = 0;
    for (storage_plan.slots) |slot| {
        if (slot.layout == .segmented) segmented_slots += 1;
    }
    if (segmented_slots == 0) return;
    const event_plan = event_protocol orelse
        return error.SegmentedLayoutRequiresProtocol;
    if (segmented_slots != 1 or
        storage_plan.slots[event_plan.target_slot_index].layout != .segmented)
    {
        return error.SegmentedLayoutProtocolTargetMismatch;
    }
    for (storage_plan.operations) |operation| {
        var segmented_effects: usize = 0;
        for (operation.effects) |effect| {
            if (storage_plan.slots[effect.slot_index].layout != .segmented) {
                continue;
            }
            segmented_effects += 1;
            if (effect.kind.isBinding()) continue;
            if (definition_plan.inputs[effect.input_index].max_bytes >
                segmented_event_log.event_max_bytes)
            {
                return error.SegmentedEventInputBoundsExceeded;
            }
            if (effect.kind != .compare_append or
                effect.idempotency_parameter != null or
                (effect.event != null and
                    effect.event.?.idempotency != null))
            {
                return error.UnsupportedSegmentedEffect;
            }
        }
        if (segmented_effects != 0 and operation.effects.len != 1) {
            return error.UnsupportedSegmentedMultiEffectOperation;
        }
    }
    try validateSegmentedCheckpointCapacity(event_plan);
}

fn validateSegmentedCheckpointCapacity(plan: *const Plan) !void {
    var maximum = replay_checkpoint_base_bytes + 8 + 16;
    if (plan.reducer_plan) |*reducer_plan| {
        maximum = try replaceEmptyCheckpointBound(
            maximum,
            8,
            try reducer.checkpointUpperBound(reducer_plan),
        );
    }
    if (plan.state_reducer_plan) |*state_plan| {
        maximum = try replaceEmptyCheckpointBound(
            maximum,
            16,
            try state_reducer.checkpointUpperBound(state_plan),
        );
    }
    if (maximum > checkpoint.max_checkpoint_bytes) {
        return error.SegmentedCheckpointCapacityExceeded;
    }
}

fn replaceEmptyCheckpointBound(
    current: usize,
    empty: usize,
    populated: usize,
) !usize {
    const without_empty = std.math.sub(usize, current, empty) catch
        return error.CheckpointCapacityOverflow;
    return std.math.add(usize, without_empty, populated) catch
        error.CheckpointCapacityOverflow;
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
        .replay,
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
        .replay,
    );
}

pub fn admitBound(
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
        .current,
    );
}

const ApplyMode = enum {
    replay,
    current,
};

fn applyWithParameters(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event_bytes: []const u8,
    parameters: ?*const definition_core.parameters.Bindings,
    mode: ApplyMode,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event_bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    );
    defer parsed.deinit();
    return applyValueWithParameters(
        allocator,
        plan,
        state,
        parsed.value,
        parameters,
        mode,
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
        .replay,
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
        .replay,
    );
}

pub fn admitValueBound(
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
        .current,
    );
}

fn applyValueWithParameters(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event: std.json.Value,
    parameters: ?*const definition_core.parameters.Bindings,
    mode: ApplyMode,
) !void {
    if (state.records >= plan.max_records) {
        return error.ProtocolRecordBoundsExceeded;
    }
    if (plan.mode == .plain) {
        return applyPlainValue(allocator, plan, state, event, mode);
    }
    return applyChainedValue(
        allocator,
        plan,
        state,
        event,
        parameters,
        mode,
    );
}

fn applyPlainValue(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event: std.json.Value,
    mode: ApplyMode,
) !void {
    const event_kind_pointer =
        if (plan.state_reducer_plan) |*compiled|
            compiled.event_kind
        else if (plan.reducer_plan) |*compiled|
            compiled.event_kind orelse
                return error.PlainKeyedReducerRequiresEventKind
        else
            return error.PlainProtocolRequiresReducer;
    const kind = try definition_core.json.string(
        definition_core.json_pointer.lookup(
            event,
            event_kind_pointer,
        ) orelse return error.EventEnvelopeFieldMissing,
    );
    const kind_index = findSortedIndex(plan.event_kinds, kind) orelse
        return error.UnknownEventKind;
    try applyReducers(allocator, plan, state, event, mode);
    state.kind_counts[kind_index] += 1;
    state.records += 1;
}

fn applyChainedValue(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event: std.json.Value,
    parameters: ?*const definition_core.parameters.Bindings,
    mode: ApplyMode,
) !void {
    const object = try definition_core.json.object(event);
    try validateEnvelopeKeys(object, plan.envelope.keys);
    try validatePartitionValues(
        plan.envelope.partition_bindings,
        event,
        parameters,
    );

    try validateChainedSequence(plan, state, object);
    const kind = try definition_core.json.string(
        object.get(plan.envelope.kind_key) orelse
            return error.EventEnvelopeFieldMissing,
    );
    const kind_index = findSortedIndex(plan.event_kinds, kind) orelse
        return error.UnknownEventKind;
    const claimed_previous = object.get(
        plan.envelope.previous_digest_key,
    ) orelse return error.EventEnvelopeFieldMissing;
    try validatePreviousDigest(plan, state, claimed_previous);
    const body = object.get(plan.envelope.body_key) orelse
        return error.EventEnvelopeFieldMissing;
    try validateChainedBodyDigest(allocator, plan, object, body);
    const claimed_event_digest = try validateChainedEventDigest(
        allocator,
        plan,
        object,
        event,
    );
    if (state.next_sequence == std.math.maxInt(u64)) {
        return error.EventSequenceOverflow;
    }
    try applyReducers(allocator, plan, state, event, mode);
    @memcpy(&state.previous_digest, claimed_event_digest);
    state.has_previous_digest = true;
    state.kind_counts[kind_index] += 1;
    state.next_sequence += 1;
    state.records += 1;
}

fn applyReducers(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *ReplayState,
    event: std.json.Value,
    mode: ApplyMode,
) !void {
    if (plan.reducer_plan) |*compiled| {
        try reducer.apply(
            allocator,
            compiled,
            &state.reducer_state,
            event,
        );
    }
    if (plan.state_reducer_plan) |*compiled| {
        switch (mode) {
            .replay => try state_reducer.apply(
                allocator,
                compiled,
                &state.state_reducer_state,
                event,
            ),
            .current => try state_reducer.admit(
                allocator,
                compiled,
                &state.state_reducer_state,
                event,
            ),
        }
    }
    if (plan.reducer_plan == null and plan.state_reducer_plan == null and
        plan.mode == .plain)
    {
        return error.PlainProtocolRequiresReducer;
    }
}

fn validateChainedSequence(
    plan: *const Plan,
    state: *const ReplayState,
    object: std.json.ObjectMap,
) !void {
    const value = object.get(plan.envelope.sequence_key) orelse
        return error.EventEnvelopeFieldMissing;
    const number = definition_core.json.integer(value) catch
        return error.InvalidEventSequence;
    const sequence = std.math.cast(u64, number) orelse
        return error.InvalidEventSequence;
    if (sequence != state.next_sequence) {
        return error.EventSequenceMismatch;
    }
}

fn validateChainedBodyDigest(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    object: std.json.ObjectMap,
    body: std.json.Value,
) !void {
    const claimed = try definition_core.json.string(
        object.get(plan.envelope.body_digest_key) orelse
            return error.EventEnvelopeFieldMissing,
    );
    try definition_core.json.digest(claimed);
    const computed = try definition_core.canonical_json.digestValueAlloc(
        allocator,
        body,
    );
    defer allocator.free(computed);
    if (!std.mem.eql(u8, claimed, computed)) {
        return error.EventBodyDigestMismatch;
    }
}

fn validateChainedEventDigest(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    object: std.json.ObjectMap,
    event: std.json.Value,
) ![]const u8 {
    const claimed = try definition_core.json.string(
        object.get(plan.envelope.event_digest_key) orelse
            return error.EventEnvelopeFieldMissing,
    );
    try definition_core.json.digest(claimed);
    const computed =
        try definition_core.canonical_json.fingerprintObjectOmittingAlloc(
            allocator,
            event,
            plan.envelope.event_digest_key,
        );
    defer allocator.free(computed);
    if (!std.mem.eql(u8, claimed, computed)) {
        return error.EventDigestMismatch;
    }
    return claimed;
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
            .integer => |expected| integer: {
                const actual_integer = definition_core.json.integer(actual) catch
                    break :integer false;
                break :integer actual_integer == expected;
            },
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
    if (plan.mode != .chained or materialization.mode != .chained) {
        return error.EventMaterializationModeMismatch;
    }
    if (unix_seconds < 0) return error.InvalidEventUnixTimestamp;
    try validateEventMaterialization(plan, materialization);
    const prepared = try prepareMaterializedEvent(
        allocator,
        plan,
        materialization,
        state,
        request,
        parameters,
        unix_seconds,
        io,
        null,
    );
    defer allocator.free(prepared.body);
    errdefer deinitGeneratedOutputs(allocator, prepared.generated_outputs);
    const body_digest =
        try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            prepared.body,
        );
    defer allocator.free(body_digest);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeChainedMaterializedEvent(
        allocator,
        &output.writer,
        plan,
        state,
        materialization,
        prepared,
        body_digest,
        unix_seconds,
    );
    return .{
        .content = try definition_core.canonical_json.finalizeFingerprintAlloc(
            allocator,
            output.written(),
            plan.envelope.event_digest_key,
        ),
        .generated_outputs = prepared.generated_outputs,
    };
}

pub fn materializePlainEvent(
    allocator: std.mem.Allocator,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    parameters: ?*const definition_core.parameters.Bindings,
    unix_seconds: i64,
    io: std.Io,
) !MaterializedEvent {
    if (materialization.mode != .plain) {
        return error.EventMaterializationModeMismatch;
    }
    if (unix_seconds < 0) return error.InvalidEventUnixTimestamp;
    const prepared = try prepareMaterializedEvent(
        allocator,
        null,
        materialization,
        state,
        request,
        parameters,
        unix_seconds,
        io,
        if (materialization.body_order.len == 0)
            null
        else
            materialization.body_order,
    );
    defer allocator.free(prepared.body);
    errdefer deinitGeneratedOutputs(allocator, prepared.generated_outputs);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writePlainMaterializedEvent(
        allocator,
        &output.writer,
        materialization,
        prepared,
        unix_seconds,
    );
    return .{
        .content = try output.toOwnedSlice(),
        .generated_outputs = prepared.generated_outputs,
    };
}

const PreparedMaterializedEvent = struct {
    request_object: std.json.ObjectMap,
    body: []u8,
    generated_outputs: []GeneratedOutput,
};

fn prepareMaterializedEvent(
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    materialization: *const storage.EventMaterialization,
    state: ?*const ReplayState,
    request: std.json.Value,
    parameters: ?*const definition_core.parameters.Bindings,
    unix_seconds: i64,
    io: std.Io,
    body_order: ?[]const []u8,
) !PreparedMaterializedEvent {
    try validateForbiddenParameters(materialization, parameters);
    const request_object = try definition_core.json.object(request);
    try validateRequestKeys(allocator, request_object, materialization);
    const body = request_object.get(
        materialization.body_input_field,
    ) orelse return error.EventBodyInputMissing;
    const generated_outputs = try generateOutputsAlloc(
        allocator,
        materialization,
        materialization.generate,
        materialization.derive,
        state,
        request,
        unix_seconds,
        io,
    );
    errdefer deinitGeneratedOutputs(allocator, generated_outputs);
    return .{
        .request_object = request_object,
        .body = try materializedBodyAlloc(
            allocator,
            plan,
            state,
            materialization,
            request_object,
            body,
            generated_outputs,
            parameters,
            body_order,
        ),
        .generated_outputs = generated_outputs,
    };
}

fn writeChainedMaterializedEvent(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    plan: *const Plan,
    state: *const ReplayState,
    materialization: *const storage.EventMaterialization,
    prepared: PreparedMaterializedEvent,
    body_digest: []const u8,
    unix_seconds: i64,
) !void {
    try writer.writeByte('{');
    for (plan.envelope.keys, 0..) |key, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(writer, key);
        try writer.writeByte(':');
        if (std.mem.eql(u8, key, plan.envelope.sequence_key)) {
            try writer.print("{d}", .{state.next_sequence});
        } else if (std.mem.eql(u8, key, plan.envelope.previous_digest_key)) {
            try writePreviousDigest(writer, plan, state);
        } else if (std.mem.eql(u8, key, plan.envelope.body_key)) {
            try writer.writeAll(prepared.body);
        } else if (std.mem.eql(u8, key, plan.envelope.body_digest_key)) {
            try definition_core.canonical_json.writeCanonicalString(
                writer,
                body_digest,
            );
        } else if (std.mem.eql(u8, key, plan.envelope.event_digest_key)) {
            try writer.writeAll("\"\"");
        } else {
            try writeChainedMaterializedField(
                allocator,
                writer,
                materialization,
                prepared,
                key,
                state.next_sequence,
                unix_seconds,
            );
        }
    }
    try writer.writeByte('}');
}

fn writeChainedMaterializedField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    prepared: PreparedMaterializedEvent,
    key: []const u8,
    sequence: u64,
    unix_seconds: i64,
) !void {
    const field = findEventField(materialization.fields, key) orelse
        return error.EventMaterializationFieldCoverageMismatch;
    try writeMaterializedField(
        allocator,
        writer,
        materialization,
        field.source,
        prepared.request_object,
        sequence,
        unix_seconds,
        prepared.generated_outputs,
    );
}

fn writePlainMaterializedEvent(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    prepared: PreparedMaterializedEvent,
    unix_seconds: i64,
) !void {
    try writer.writeByte('{');
    for (materialization.field_order, 0..) |key, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(writer, key);
        try writer.writeByte(':');
        if (std.mem.eql(u8, key, materialization.body_input_field)) {
            try writer.writeAll(prepared.body);
        } else {
            try writeChainedMaterializedField(
                allocator,
                writer,
                materialization,
                prepared,
                key,
                0,
                unix_seconds,
            );
        }
    }
    try writer.writeByte('}');
}

pub fn derivePlainIdempotencyKeyAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
) !?[]u8 {
    if (materialization.mode != .plain) {
        return error.EventMaterializationModeMismatch;
    }
    const idempotency = materialization.idempotency orelse return null;
    const derivation = findEventDerivationLinear(
        materialization.derive,
        idempotency.derived,
    ) orelse return error.EventIdempotencyDerivationMissing;
    const value = try deriveEventValueAlloc(
        allocator,
        materialization,
        derivation.*,
        null,
        request,
        0,
        &.{},
    );
    errdefer allocator.free(value);
    try definition_core.json.safeIdentifier(value, 128);
    return value;
}

pub fn storedPlainDerivedValue(
    materialization: *const storage.EventMaterialization,
    event: std.json.Value,
    name: []const u8,
) !?[]const u8 {
    if (materialization.mode != .plain) {
        return error.EventMaterializationModeMismatch;
    }
    const event_object = try definition_core.json.object(event);
    const body_value = event_object.get(
        materialization.body_input_field,
    ) orelse return error.EventEnvelopeFieldMissing;
    const body = switch (body_value) {
        .object => |object| object,
        else => null,
    };
    return storedEventDerivedValue(
        materialization,
        event_object,
        body,
        name,
    );
}

pub fn canonicalPlainStoredEventAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    event: std.json.Value,
) ![]u8 {
    if (materialization.mode != .plain) {
        return error.EventMaterializationModeMismatch;
    }
    const object = try definition_core.json.object(event);
    if (object.count() != materialization.field_order.len) {
        return error.EventMaterializationFieldCoverageMismatch;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    for (materialization.field_order, 0..) |key, index| {
        const value = object.get(key) orelse
            return error.EventEnvelopeFieldMissing;
        if (index != 0) try output.writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            key,
        );
        try output.writer.writeByte(':');
        if (std.mem.eql(
            u8,
            key,
            materialization.body_input_field,
        )) {
            const body = try canonicalPlainStoredBodyAlloc(
                allocator,
                materialization,
                value,
            );
            defer allocator.free(body);
            try output.writer.writeAll(body);
        } else {
            var path = EventJsonPath{};
            try path.push(key);
            try writeEventJsonValue(
                allocator,
                &output.writer,
                materialization,
                value,
                &path,
            );
        }
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub fn reconstructInputAlloc(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const ReplayState,
    materialization: *const storage.EventMaterialization,
    event: std.json.Value,
) ![]u8 {
    if (plan.mode != .chained or materialization.mode != .chained) {
        return error.EventMaterializationModeMismatch;
    }
    try validateEventMaterialization(plan, materialization);
    const event_object = try definition_core.json.object(event);
    try validateEnvelopeKeys(event_object, plan.envelope.keys);
    const reconstructed = try reconstructInputWithLayoutAlloc(
        allocator,
        plan,
        state,
        materialization,
        event_object,
        plan.envelope.body_key,
    );
    errdefer allocator.free(reconstructed);
    try validateStoredEventDerivations(
        allocator,
        state,
        materialization,
        event_object,
        plan.envelope.body_key,
        reconstructed,
    );
    return reconstructed;
}

pub fn reconstructPlainInputAlloc(
    allocator: std.mem.Allocator,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    event: std.json.Value,
) ![]u8 {
    if (materialization.mode != .plain) {
        return error.EventMaterializationModeMismatch;
    }
    const event_object = try definition_core.json.object(event);
    const reconstructed = try reconstructInputWithLayoutAlloc(
        allocator,
        null,
        null,
        materialization,
        event_object,
        materialization.body_input_field,
    );
    errdefer allocator.free(reconstructed);
    try validateStoredEventDerivations(
        allocator,
        state,
        materialization,
        event_object,
        materialization.body_input_field,
        reconstructed,
    );
    return reconstructed;
}

fn validateStoredEventDerivations(
    allocator: std.mem.Allocator,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    event: std.json.ObjectMap,
    body_key: []const u8,
    reconstructed: []const u8,
) !void {
    if (materialization.derive.len == 0) return;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        reconstructed,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    const body_value = event.get(body_key) orelse
        return error.EventEnvelopeFieldMissing;
    const body = switch (body_value) {
        .object => |object| object,
        else => null,
    };
    const outputs = try allocator.alloc(
        GeneratedOutput,
        materialization.derive.len,
    );
    var initialized: usize = 0;
    defer {
        for (outputs[0..initialized]) |*output| output.deinit(allocator);
        allocator.free(outputs);
    }
    for (materialization.derive) |item| {
        outputs[initialized] = try validateStoredEventDerivation(
            allocator,
            state,
            materialization,
            event,
            body,
            item,
            parsed.value,
            outputs[0..initialized],
        );
        initialized += 1;
    }
}

fn validateStoredEventDerivation(
    allocator: std.mem.Allocator,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    event: std.json.ObjectMap,
    body: ?std.json.ObjectMap,
    item: storage.EventDerivation,
    reconstructed: std.json.Value,
    outputs: []const GeneratedOutput,
) !GeneratedOutput {
    const stored = try storedEventDerivedValue(
        materialization,
        event,
        body,
        item.name,
    );
    const expected = switch (item.source) {
        .utc_timestamp => |format| try storedTimestampAlloc(
            allocator,
            stored,
            format,
        ),
        else => try deriveEventValueAlloc(
            allocator,
            materialization,
            item,
            state,
            reconstructed,
            0,
            outputs,
        ),
    };
    errdefer {
        @memset(expected, 0);
        allocator.free(expected);
    }
    if (stored) |actual| {
        if (!std.mem.eql(u8, expected, actual)) {
            return error.EventDerivedValueMismatch;
        }
    }
    const name = try allocator.dupe(u8, item.name);
    return .{ .name = name, .value = expected };
}

fn storedTimestampAlloc(
    allocator: std.mem.Allocator,
    stored: ?[]const u8,
    format: storage.EventTimestampFormat,
) ![]u8 {
    const text = stored orelse return error.EventDerivedOutputMissing;
    try validateStoredEventTimestamp(allocator, text, format);
    return allocator.dupe(u8, text);
}

fn storedEventDerivedValue(
    materialization: *const storage.EventMaterialization,
    event: std.json.ObjectMap,
    body: ?std.json.ObjectMap,
    name: []const u8,
) !?[]const u8 {
    var found: ?[]const u8 = null;
    for (materialization.fields) |field| switch (field.source) {
        .derived => |candidate| {
            if (!std.mem.eql(u8, candidate, name)) continue;
            const value = event.get(field.field) orelse
                return error.EventEnvelopeFieldMissing;
            const text = try definition_core.json.string(value);
            if (found) |prior| {
                if (!std.mem.eql(u8, prior, text)) {
                    return error.EventDerivedValueMismatch;
                }
            } else {
                found = text;
            }
        },
        else => {},
    };
    const body_object = if (materialization.body_fields.len == 0)
        null
    else
        body orelse return error.ExpectedObject;
    for (materialization.body_fields) |field| switch (field.source) {
        .derived => |candidate| {
            if (!std.mem.eql(u8, candidate, name)) continue;
            const value = body_object.?.get(field.field) orelse
                return error.EventBodyFieldMissing;
            const text = try definition_core.json.string(value);
            if (found) |prior| {
                if (!std.mem.eql(u8, prior, text)) {
                    return error.EventDerivedValueMismatch;
                }
            } else {
                found = text;
            }
        },
        else => {},
    };
    return found;
}

fn validateStoredEventTimestamp(
    allocator: std.mem.Allocator,
    value: []const u8,
    format: storage.EventTimestampFormat,
) !void {
    switch (format) {
        .rfc3339_seconds => {
            const compact = try compactUtcTimestampAlloc(
                allocator,
                value,
            );
            defer allocator.free(compact);
        },
    }
}

fn reconstructInputWithLayoutAlloc(
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    event_object: std.json.ObjectMap,
    body_key: []const u8,
) ![]u8 {
    const reconstructed_body = try reconstructedBodyAlloc(
        allocator,
        plan,
        state,
        materialization,
        event_object,
        event_object.get(body_key) orelse
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
    var mappings: [129]ReconstructedMapping = undefined;
    const count = try collectReconstructedMappings(
        allocator,
        state,
        materialization,
        event_object,
        parsed_body.value,
        &mappings,
    );
    sortReconstructedMappings(mappings[0..count]);
    try validateReconstructedMappings(mappings[0..count]);
    return writeReconstructedMappingsAlloc(
        allocator,
        materialization,
        mappings[0..count],
    );
}

const ReconstructedMapping = struct {
    key: []const u8,
    value: union(enum) {
        json: std.json.Value,
        literal: []const u8,
    },
};

fn collectReconstructedMappings(
    allocator: std.mem.Allocator,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    event_object: std.json.ObjectMap,
    reconstructed_body: std.json.Value,
    mappings: *[129]ReconstructedMapping,
) !usize {
    var count: usize = 0;
    mappings[count] = .{
        .key = materialization.body_input_field,
        .value = .{ .json = reconstructed_body },
    };
    count += 1;
    for (materialization.fields) |field| {
        const value = event_object.get(field.field) orelse
            return error.EventEnvelopeFieldMissing;
        try collectReconstructedField(
            allocator,
            state,
            field.source,
            value,
            mappings,
            &count,
        );
    }
    for (materialization.request_literals) |literal| {
        if (count >= mappings.len) return error.EventInputFieldBoundsExceeded;
        mappings[count] = .{
            .key = literal.field,
            .value = .{ .literal = literal.literal },
        };
        count += 1;
    }
    return count;
}

fn collectReconstructedField(
    allocator: std.mem.Allocator,
    state: ?*const ReplayState,
    source: storage.EventFieldSource,
    value: std.json.Value,
    mappings: *[129]ReconstructedMapping,
    count: *usize,
) !void {
    switch (source) {
        .input_field => |input_field| {
            if (count.* >= mappings.len) {
                return error.EventInputFieldBoundsExceeded;
            }
            mappings[count.*] = .{
                .key = input_field,
                .value = .{ .json = value },
            };
            count.* += 1;
        },
        .literal => |literal| try validateReconstructedLiteral(
            allocator,
            value,
            literal,
        ),
        .sequence_text_prefix => |prefix| try validateSequenceText(
            allocator,
            state,
            value,
            prefix,
        ),
        .unix_seconds => {
            const timestamp = definition_core.json.integer(value) catch
                return error.InvalidEventUnixTimestamp;
            if (timestamp < 0) return error.InvalidEventUnixTimestamp;
        },
        .derived => {
            if (value != .string) return error.EventDerivedValueInvalid;
        },
    }
}

fn validateReconstructedLiteral(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    literal: []const u8,
) !void {
    const canonical =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            value,
        );
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, literal)) {
        return error.EventLiteralMismatch;
    }
}

fn validateSequenceText(
    allocator: std.mem.Allocator,
    state: ?*const ReplayState,
    value: std.json.Value,
    prefix: []const u8,
) !void {
    const replay_state = state orelse
        return error.PlainEventRequiresProtocolState;
    const actual = try definition_core.json.string(value);
    const expected = try std.fmt.allocPrint(
        allocator,
        "{s}{d}",
        .{ prefix, replay_state.next_sequence },
    );
    defer allocator.free(expected);
    if (!std.mem.eql(u8, actual, expected)) {
        return error.EventSequenceTextMismatch;
    }
}

fn sortReconstructedMappings(mappings: []ReconstructedMapping) void {
    std.sort.heap(ReconstructedMapping, mappings, {}, struct {
        fn lessThan(
            _: void,
            left: ReconstructedMapping,
            right: ReconstructedMapping,
        ) bool {
            return std.mem.lessThan(u8, left.key, right.key);
        }
    }.lessThan);
}

fn validateReconstructedMappings(
    mappings: []const ReconstructedMapping,
) !void {
    for (mappings[1..], 1..) |mapping, index| {
        if (std.mem.eql(u8, mappings[index - 1].key, mapping.key)) {
            return error.DuplicateEventInputField;
        }
    }
}

fn writeReconstructedMappingsAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    mappings: []const ReconstructedMapping,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    for (mappings, 0..) |mapping, index| {
        if (index != 0) try output.writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            mapping.key,
        );
        try output.writer.writeByte(':');
        switch (mapping.value) {
            .json => |value| {
                var path = EventJsonPath{};
                try writeEventJsonValue(
                    allocator,
                    &output.writer,
                    materialization,
                    value,
                    &path,
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
    materialization: *const storage.EventMaterialization,
    definitions: []const storage.SecureTokenGeneration,
    derivations: []const storage.EventDerivation,
    state: ?*const ReplayState,
    request: std.json.Value,
    unix_seconds: i64,
    io: std.Io,
) ![]GeneratedOutput {
    const count = std.math.add(
        usize,
        definitions.len,
        derivations.len,
    ) catch return error.EventGeneratedOutputCountExceeded;
    const outputs = try allocator.alloc(GeneratedOutput, count);
    var initialized: usize = 0;
    errdefer {
        for (outputs[0..initialized]) |*output| output.deinit(allocator);
        allocator.free(outputs);
    }
    for (definitions, 0..) |item, index| {
        outputs[index] = try generateSecureOutputAlloc(
            allocator,
            item,
            io,
        );
        initialized += 1;
    }
    for (derivations) |item| {
        const value = try deriveEventValueAlloc(
            allocator,
            materialization,
            item,
            state,
            request,
            unix_seconds,
            outputs[0..initialized],
        );
        errdefer {
            @memset(value, 0);
            allocator.free(value);
        }
        outputs[initialized] = .{
            .name = try allocator.dupe(u8, item.name),
            .value = value,
        };
        initialized += 1;
    }
    std.sort.heap(GeneratedOutput, outputs, {}, struct {
        fn lessThan(
            _: void,
            left: GeneratedOutput,
            right: GeneratedOutput,
        ) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return outputs;
}

fn generateSecureOutputAlloc(
    allocator: std.mem.Allocator,
    item: storage.SecureTokenGeneration,
    io: std.Io,
) !GeneratedOutput {
    var random: [64]u8 = undefined;
    defer @memset(&random, 0);
    try std.Io.randomSecure(io, random[0..item.byte_count]);
    const value_len = std.math.add(
        usize,
        item.prefix.len,
        2 * @as(usize, item.byte_count),
    ) catch return error.SecureTokenOutputTooLarge;
    const value = try allocator.alloc(u8, value_len);
    errdefer {
        @memset(value, 0);
        allocator.free(value);
    }
    @memcpy(value[0..item.prefix.len], item.prefix);
    const hex = "0123456789abcdef";
    for (random[0..item.byte_count], 0..) |byte, byte_index| {
        const offset = item.prefix.len + byte_index * 2;
        value[offset] = hex[byte >> 4];
        value[offset + 1] = hex[byte & 0x0f];
    }
    return .{
        .name = try allocator.dupe(u8, item.name),
        .value = value,
    };
}

fn deriveEventValueAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    item: storage.EventDerivation,
    state: ?*const ReplayState,
    request: std.json.Value,
    unix_seconds: i64,
    prior: []const GeneratedOutput,
) ![]u8 {
    return switch (item.source) {
        .input_text => |pointer| blk: {
            const value = definition_core.json_pointer.lookup(
                request,
                pointer,
            ) orelse return error.EventDerivationInputMissing;
            const text = try definition_core.json.string(value);
            break :blk try allocator.dupe(u8, text);
        },
        .utc_timestamp => |format| formatEventTimestampAlloc(
            allocator,
            unix_seconds,
            format,
        ),
        .sha1 => |config| deriveEventSha1Alloc(
            allocator,
            materialization,
            request,
            prior,
            config,
        ),
        .sha256 => |config| deriveEventSha256Alloc(
            allocator,
            materialization,
            request,
            prior,
            config,
        ),
        .concat => |config| deriveEventConcatAlloc(
            allocator,
            materialization,
            request,
            prior,
            config,
        ),
        .monotonic_identity => |config| deriveMonotonicIdentityAlloc(
            allocator,
            state orelse return error.EventProtocolStateMissing,
            config,
        ),
    };
}

fn deriveMonotonicIdentityAlloc(
    allocator: std.mem.Allocator,
    state: *const ReplayState,
    config: storage.EventMonotonicIdentityDerivation,
) ![]u8 {
    const suffix = try state.reducer_state.nextMonotonicSuffix(
        config.prefix,
    );
    var digits_buffer: [32]u8 = undefined;
    const digits = try std.fmt.bufPrint(&digits_buffer, "{d}", .{suffix});
    const width = @max(@as(usize, config.width), digits.len);
    const result = try allocator.alloc(u8, config.prefix.len + width);
    @memcpy(result[0..config.prefix.len], config.prefix);
    @memset(
        result[config.prefix.len .. config.prefix.len + width - digits.len],
        '0',
    );
    @memcpy(result[result.len - digits.len ..], digits);
    return result;
}

fn deriveEventSha1Alloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    prior: []const GeneratedOutput,
    config: storage.EventDigestDerivation,
) ![]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var total_bytes: usize = 0;
    for (config.fragments) |fragment| {
        const bytes = try eventDerivationFragmentAlloc(
            allocator,
            materialization,
            request,
            prior,
            fragment,
        );
        defer allocator.free(bytes);
        total_bytes = std.math.add(
            usize,
            total_bytes,
            bytes.len,
        ) catch return error.EventDerivationBytesExceeded;
        if (total_bytes > config.max_bytes) {
            return error.EventDerivationBytesExceeded;
        }
        hasher.update(bytes);
    }
    var raw: [20]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    const encoded = switch (config.encoding) {
        .hex => try allocator.dupe(u8, &hex),
        .digest => try std.fmt.allocPrint(allocator, "sha1:{s}", .{hex}),
    };
    return truncateEventDigestAlloc(allocator, encoded, config.prefix_bytes);
}

fn deriveEventSha256Alloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    prior: []const GeneratedOutput,
    config: storage.EventDigestDerivation,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total_bytes: usize = 0;
    for (config.fragments) |fragment| {
        const bytes = try eventDerivationFragmentAlloc(
            allocator,
            materialization,
            request,
            prior,
            fragment,
        );
        defer allocator.free(bytes);
        total_bytes = std.math.add(
            usize,
            total_bytes,
            bytes.len,
        ) catch return error.EventDerivationBytesExceeded;
        if (total_bytes > config.max_bytes) {
            return error.EventDerivationBytesExceeded;
        }
        hasher.update(bytes);
    }
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    const encoded = switch (config.encoding) {
        .hex => try allocator.dupe(u8, &hex),
        .digest => try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex}),
    };
    return truncateEventDigestAlloc(allocator, encoded, config.prefix_bytes);
}

fn truncateEventDigestAlloc(
    allocator: std.mem.Allocator,
    encoded: []u8,
    prefix_bytes: ?u16,
) ![]u8 {
    const count = prefix_bytes orelse return encoded;
    const count_usize: usize = count;
    errdefer allocator.free(encoded);
    if (count_usize > encoded.len) return error.EventDerivedPrefixInvalid;
    const prefix = try allocator.dupe(u8, encoded[0..count_usize]);
    allocator.free(encoded);
    return prefix;
}

fn deriveEventConcatAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    prior: []const GeneratedOutput,
    config: storage.EventConcatDerivation,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (config.fragments) |fragment| {
        const bytes = try eventDerivationFragmentAlloc(
            allocator,
            materialization,
            request,
            prior,
            fragment,
        );
        defer allocator.free(bytes);
        const next = std.math.add(
            usize,
            output.written().len,
            bytes.len,
        ) catch return error.EventDerivationBytesExceeded;
        if (next > config.max_bytes) {
            return error.EventDerivationBytesExceeded;
        }
        try output.writer.writeAll(bytes);
    }
    return output.toOwnedSlice();
}

fn eventDerivationFragmentAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    prior: []const GeneratedOutput,
    fragment: storage.EventDerivationFragment,
) ![]u8 {
    return switch (fragment) {
        .literal => |value| allocator.dupe(u8, value),
        .input_text => |source| eventInputTextAlloc(
            allocator,
            request,
            source,
        ),
        .input_json => |pointer| eventInputJsonAlloc(
            allocator,
            materialization,
            request,
            pointer,
        ),
        .canonical_input => |pointer| blk: {
            const value = definition_core.json_pointer.lookup(
                request,
                pointer,
            ) orelse return error.EventDerivationInputMissing;
            break :blk try definition_core.canonical_json.canonicalJsonAlloc(
                allocator,
                value,
            );
        },
        .derived => |reference| eventDerivedFragmentAlloc(
            allocator,
            prior,
            reference,
        ),
    };
}

fn eventInputTextAlloc(
    allocator: std.mem.Allocator,
    request: std.json.Value,
    source: storage.EventInputTextFragment,
) ![]u8 {
    const value = definition_core.json_pointer.lookup(
        request,
        source.pointer,
    ) orelse return error.EventDerivationInputMissing;
    const text = try definition_core.json.string(value);
    if (source.transform == .none) return allocator.dupe(u8, text);
    const lowered = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, index| {
        lowered[index] = std.ascii.toLower(byte);
    }
    return lowered;
}

fn eventInputJsonAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    request: std.json.Value,
    pointer: definition_core.json_pointer.Pointer,
) ![]u8 {
    const value = definition_core.json_pointer.lookup(
        request,
        pointer,
    ) orelse return error.EventDerivationInputMissing;
    if (materialization.body_order.len != 0 and
        pointer.segments.len == 1 and
        std.mem.eql(
            u8,
            pointer.segments[0],
            materialization.body_input_field,
        ))
    {
        return orderedInputBodyAlloc(allocator, materialization, value);
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn eventDerivedFragmentAlloc(
    allocator: std.mem.Allocator,
    prior: []const GeneratedOutput,
    reference: storage.EventDerivedReference,
) ![]u8 {
    const output = findGeneratedOutputLinear(
        prior,
        reference.name,
    ) orelse return error.EventDerivedOutputMissing;
    const transformed = switch (reference.transform) {
        .none => try allocator.dupe(u8, output.value),
        .compact_utc => try compactUtcTimestampAlloc(
            allocator,
            output.value,
        ),
    };
    errdefer allocator.free(transformed);
    const count = reference.prefix_bytes orelse return transformed;
    if (count > transformed.len or
        !std.unicode.utf8ValidateSlice(transformed[0..count]))
    {
        return error.EventDerivedPrefixInvalid;
    }
    const prefix = try allocator.dupe(u8, transformed[0..count]);
    allocator.free(transformed);
    return prefix;
}

fn orderedInputBodyAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    value: std.json.Value,
) ![]u8 {
    const object = try definition_core.json.object(value);
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!containsDeclaredName(
            materialization.body_order,
            entry.key_ptr.*,
        )) return error.EventBodyFieldCoverageMismatch;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    var written: usize = 0;
    for (materialization.body_order) |key| {
        const selected = object.get(key) orelse continue;
        if (written != 0) try output.writer.writeByte(',');
        try writeEventJsonString(
            &output.writer,
            key,
            materialization.escape_non_ascii,
        );
        try output.writer.writeByte(':');
        var path = EventJsonPath{};
        try path.push(key);
        try writeEventJsonValue(
            allocator,
            &output.writer,
            materialization,
            selected,
            &path,
        );
        written += 1;
    }
    if (written != object.count()) {
        return error.EventBodyFieldCoverageMismatch;
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn formatEventTimestampAlloc(
    allocator: std.mem.Allocator,
    unix_seconds: i64,
    format: storage.EventTimestampFormat,
) ![]u8 {
    if (unix_seconds < 0) return error.InvalidEventUnixTimestamp;
    const seconds_per_day: i64 = 86_400;
    const days = @divFloor(unix_seconds, seconds_per_day);
    const seconds_of_day = unix_seconds - days * seconds_per_day;
    const civil = civilDateFromUnixDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;
    return switch (format) {
        .rfc3339_seconds => std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{
                @as(u32, @intCast(civil.year)),
                @as(u32, @intCast(civil.month)),
                @as(u32, @intCast(civil.day)),
                @as(u32, @intCast(hour)),
                @as(u32, @intCast(minute)),
                @as(u32, @intCast(second)),
            },
        ),
    };
}

const EventCivilDate = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilDateFromUnixDays(days_since_epoch: i64) EventCivilDate {
    const shifted = days_since_epoch + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) +
            @divFloor(day_of_era, 36_524) -
            @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) -
            @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year -
        @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    year += @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

fn compactUtcTimestampAlloc(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]u8 {
    if (value.len != 20 or
        value[4] != '-' or
        value[7] != '-' or
        value[10] != 'T' or
        value[13] != ':' or
        value[16] != ':' or
        value[19] != 'Z')
    {
        return error.EventTimestampTransformInvalid;
    }
    const digit_indexes = [_]usize{
        0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18,
    };
    for (digit_indexes) |index| {
        if (!std.ascii.isDigit(value[index])) {
            return error.EventTimestampTransformInvalid;
        }
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch
        return error.EventTimestampTransformInvalid;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch
        return error.EventTimestampTransformInvalid;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch
        return error.EventTimestampTransformInvalid;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch
        return error.EventTimestampTransformInvalid;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch
        return error.EventTimestampTransformInvalid;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch
        return error.EventTimestampTransformInvalid;
    if (year == 0 or
        month == 0 or
        month > 12 or
        day == 0 or
        day > daysInEventMonth(year, month) or
        hour > 23 or
        minute > 59 or
        second > 59)
    {
        return error.EventTimestampTransformInvalid;
    }
    const compact = try allocator.alloc(u8, 16);
    @memcpy(compact[0..4], value[0..4]);
    @memcpy(compact[4..6], value[5..7]);
    @memcpy(compact[6..8], value[8..10]);
    compact[8] = 'T';
    @memcpy(compact[9..11], value[11..13]);
    @memcpy(compact[11..13], value[14..16]);
    @memcpy(compact[13..15], value[17..19]);
    compact[15] = 'Z';
    return compact;
}

fn daysInEventMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0))
            29
        else
            28,
        else => 0,
    };
}

fn deinitGeneratedOutputs(
    allocator: std.mem.Allocator,
    outputs: []GeneratedOutput,
) void {
    for (outputs) |*output| output.deinit(allocator);
    allocator.free(outputs);
}

const EventJsonPath = struct {
    segments: [32][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *EventJsonPath, segment: []const u8) !void {
        if (self.len == self.segments.len) {
            return error.EventObjectOrderDepthExceeded;
        }
        self.segments[self.len] = segment;
        self.len += 1;
    }

    fn pop(self: *EventJsonPath) void {
        std.debug.assert(self.len != 0);
        self.len -= 1;
    }

    fn slice(self: *const EventJsonPath) []const []const u8 {
        return self.segments[0..self.len];
    }
};

const EventJsonArrayFrame = struct {
    items: []const std.json.Value,
    next_index: usize = 0,
};

const EventJsonObjectFrame = struct {
    object: std.json.ObjectMap,
    keys: [][]const u8,
    next_index: usize = 0,
};

const EventJsonFrame = union(enum) {
    value: std.json.Value,
    array: EventJsonArrayFrame,
    object: EventJsonObjectFrame,
    pop_path,
};

const max_event_json_frames: usize = 512;

fn writeEventJsonValue(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    value: std.json.Value,
    path: *EventJsonPath,
) !void {
    var frame_storage: [max_event_json_frames]EventJsonFrame = undefined;
    const frames = frame_storage[0..];
    var frame_count: usize = 1;
    frames[0] = .{ .value = value };
    errdefer deinitEventJsonFrames(allocator, frames[0..frame_count]);
    while (frame_count != 0) {
        switch (frames[frame_count - 1]) {
            .value => try advanceEventJsonValue(
                allocator,
                writer,
                materialization,
                path,
                frames,
                &frame_count,
            ),
            .array => try advanceEventJsonArray(
                writer,
                frames,
                &frame_count,
            ),
            .object => try advanceEventJsonObject(
                allocator,
                writer,
                materialization,
                path,
                frames,
                &frame_count,
            ),
            .pop_path => {
                path.pop();
                frame_count -= 1;
            },
        }
    }
}

fn advanceEventJsonValue(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    path: *const EventJsonPath,
    frames: []EventJsonFrame,
    frame_count: *usize,
) !void {
    const frame = &frames[frame_count.* - 1];
    switch (frame.value) {
        .null => try writer.writeAll("null"),
        .bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .integer => |number| try writer.print("{d}", .{number}),
        .float => |number| {
            try definition_core.canonical_json.writeCanonicalFloat(
                writer,
                number,
            );
        },
        .number_string => |number| try definition_core.exact_number.writeCanonical(
            writer,
            number,
        ),
        .string => |text| try writeEventJsonString(
            writer,
            text,
            materialization.escape_non_ascii,
        ),
        .array => |items| {
            try writer.writeByte('[');
            frame.* = .{ .array = .{ .items = items.items } };
            return;
        },
        .object => |object| {
            const keys = try eventObjectKeysAtPathAlloc(
                allocator,
                materialization,
                object,
                path,
            );
            errdefer allocator.free(keys);
            try writer.writeByte('{');
            frame.* = .{ .object = .{
                .object = object,
                .keys = keys,
            } };
            return;
        },
    }
    frame_count.* -= 1;
}

fn advanceEventJsonArray(
    writer: *std.Io.Writer,
    frames: []EventJsonFrame,
    frame_count: *usize,
) !void {
    const frame = &frames[frame_count.* - 1].array;
    if (frame.next_index == frame.items.len) {
        try writer.writeByte(']');
        frame_count.* -= 1;
        return;
    }
    if (frame.next_index != 0) try writer.writeByte(',');
    try ensureEventJsonFrameCapacity(frame_count.*, 1);
    const value = frame.items[frame.next_index];
    frame.next_index += 1;
    frames[frame_count.*] = .{ .value = value };
    frame_count.* += 1;
}

fn advanceEventJsonObject(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    path: *EventJsonPath,
    frames: []EventJsonFrame,
    frame_count: *usize,
) !void {
    const frame = &frames[frame_count.* - 1].object;
    if (frame.next_index == frame.keys.len) {
        try writer.writeByte('}');
        allocator.free(frame.keys);
        frame_count.* -= 1;
        return;
    }
    if (frame.next_index != 0) try writer.writeByte(',');
    try ensureEventJsonFrameCapacity(frame_count.*, 2);
    const key = frame.keys[frame.next_index];
    try writeEventJsonString(
        writer,
        key,
        materialization.escape_non_ascii,
    );
    try writer.writeByte(':');
    try path.push(key);
    frame.next_index += 1;
    frames[frame_count.*] = .pop_path;
    frames[frame_count.* + 1] = .{
        .value = frame.object.get(key).?,
    };
    frame_count.* += 2;
}

fn ensureEventJsonFrameCapacity(
    frame_count: usize,
    additional: usize,
) !void {
    const required = std.math.add(
        usize,
        frame_count,
        additional,
    ) catch return error.EventJsonDepthExceeded;
    if (required > max_event_json_frames) {
        return error.EventJsonDepthExceeded;
    }
}

fn deinitEventJsonFrames(
    allocator: std.mem.Allocator,
    frames: []EventJsonFrame,
) void {
    for (frames) |frame| switch (frame) {
        .object => |object| allocator.free(object.keys),
        else => {},
    };
}

fn eventObjectKeysAtPathAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    object: std.json.ObjectMap,
    path: *const EventJsonPath,
) ![][]const u8 {
    const declared = findEventObjectOrder(
        materialization.object_orders,
        path.slice(),
    );
    const keys = try allocator.alloc([]const u8, object.count());
    errdefer allocator.free(keys);
    var key_count: usize = 0;
    if (declared) |order| {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            if (!containsDeclaredName(
                order.fields,
                entry.key_ptr.*,
            )) return error.EventObjectFieldCoverageMismatch;
        }
        for (order.fields) |field| {
            if (object.get(field) != null) {
                keys[key_count] = field;
                key_count += 1;
            }
        }
    } else {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            keys[key_count] = entry.key_ptr.*;
            key_count += 1;
        }
    }
    std.debug.assert(key_count == keys.len);
    return keys;
}

fn findEventObjectOrder(
    orders: []const storage.EventObjectOrder,
    path: []const []const u8,
) ?*const storage.EventObjectOrder {
    for (orders) |*order| {
        if (order.pointer.segments.len != path.len) continue;
        var matches = true;
        for (path, 0..) |segment, index| {
            if (!std.mem.eql(
                u8,
                segment,
                order.pointer.segments[index],
            )) {
                matches = false;
                break;
            }
        }
        if (matches) return order;
    }
    return null;
}

fn writeEventJsonString(
    writer: *std.Io.Writer,
    text: []const u8,
    escape_non_ascii: bool,
) !void {
    if (!escape_non_ascii) {
        return definition_core.canonical_json.writeCanonicalString(
            writer,
            text,
        );
    }
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\x08' => try writer.writeAll("\\b"),
                '\x0c' => try writer.writeAll("\\f"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => if (byte < 0x20)
                    try writer.print("\\u00{X:0>2}", .{byte})
                else
                    try writer.writeByte(byte),
            }
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.print("\\u00{X:0>2}", .{byte});
            index += 1;
            continue;
        };
        if (index + sequence_len > text.len) {
            try writer.print("\\u00{X:0>2}", .{byte});
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(
            text[index .. index + sequence_len],
        ) catch {
            try writer.print("\\u00{X:0>2}", .{byte});
            index += 1;
            continue;
        };
        index += sequence_len;
        if (codepoint <= 0xFFFF) {
            try writer.print("\\u{X:0>4}", .{codepoint});
            continue;
        }
        const scalar = codepoint - 0x1_0000;
        const high: u32 = 0xD800 + @as(u32, @intCast(scalar >> 10));
        const low: u32 = 0xDC00 +
            @as(u32, @intCast(scalar & 0x3FF));
        try writer.print(
            "\\u{X:0>4}\\u{X:0>4}",
            .{ high, low },
        );
    }
    try writer.writeByte('"');
}

fn materializedBodyAlloc(
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    request: std.json.ObjectMap,
    body: std.json.Value,
    generated_outputs: []const GeneratedOutput,
    parameters: ?*const definition_core.parameters.Bindings,
    declared_order: ?[]const []u8,
) ![]u8 {
    if (materialization.body_fields.len == 0 and declared_order == null and
        materialization.object_orders.len == 0 and
        !materialization.escape_non_ascii)
    {
        return definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            body,
        );
    }
    const object = try definition_core.json.object(body);
    try validateMaterializedBodyFields(
        allocator,
        materialization,
        request,
        object,
    );
    if (declared_order) |order| {
        return materializedBodyInDeclaredOrderAlloc(
            allocator,
            plan,
            state,
            materialization,
            object,
            generated_outputs,
            parameters,
            order,
        );
    }
    return materializedBodySortedAlloc(
        allocator,
        plan,
        state,
        materialization,
        object,
        generated_outputs,
        parameters,
    );
}

fn validateMaterializedBodyFields(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    request: std.json.ObjectMap,
    object: std.json.ObjectMap,
) !void {
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
            .generated_sha256,
            .parameter_sha256,
            .state_value,
            .derived,
            => {
                if (actual != null) return error.EventBodyFieldCollision;
            },
        }
    }
}

fn materializedBodySortedAlloc(
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    object: std.json.ObjectMap,
    generated_outputs: []const GeneratedOutput,
    parameters: ?*const definition_core.parameters.Bindings,
) ![]u8 {
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
    return writeMaterializedBodySortedAlloc(
        allocator,
        plan,
        state,
        materialization,
        object,
        generated_outputs,
        parameters,
        keys.items,
    );
}

fn writeMaterializedBodySortedAlloc(
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    object: std.json.ObjectMap,
    generated_outputs: []const GeneratedOutput,
    parameters: ?*const definition_core.parameters.Bindings,
    keys: []const []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    var key_index: usize = 0;
    var field_index: usize = 0;
    var written: usize = 0;
    while (key_index < keys.len or
        field_index < materialization.body_fields.len)
    {
        while (field_index < materialization.body_fields.len and
            materialization.body_fields[field_index].source == .request_input)
        {
            field_index += 1;
        }
        if (key_index == keys.len and
            field_index == materialization.body_fields.len) break;
        const use_field = field_index < materialization.body_fields.len and
            (key_index == keys.len or
                std.mem.order(
                    u8,
                    materialization.body_fields[field_index].field,
                    keys[key_index],
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
                materialization,
                plan,
                state,
                field.source,
                generated_outputs,
                parameters,
            );
            field_index += 1;
        } else {
            try writeExistingMaterializedBodyField(
                allocator,
                &output.writer,
                materialization,
                object,
                keys[key_index],
            );
            key_index += 1;
        }
        written += 1;
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn writeExistingMaterializedBodyField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    object: std.json.ObjectMap,
    key: []const u8,
) !void {
    try definition_core.canonical_json.writeCanonicalString(writer, key);
    try writer.writeByte(':');
    var path = EventJsonPath{};
    try path.push(key);
    try writeEventJsonValue(
        allocator,
        writer,
        materialization,
        object.get(key).?,
        &path,
    );
}

fn materializedBodyInDeclaredOrderAlloc(
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    object: std.json.ObjectMap,
    generated_outputs: []const GeneratedOutput,
    parameters: ?*const definition_core.parameters.Bindings,
    order: []const []u8,
) ![]u8 {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!containsDeclaredName(order, entry.key_ptr.*)) {
            return error.EventBodyFieldCoverageMismatch;
        }
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    var written: usize = 0;
    for (order) |key| {
        if (findEventBodyField(
            materialization.body_fields,
            key,
        )) |field| {
            if (field.source == .request_input) continue;
            if (written != 0) try output.writer.writeByte(',');
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                key,
            );
            try output.writer.writeByte(':');
            try writeMaterializedBodyField(
                allocator,
                &output.writer,
                materialization,
                plan,
                state,
                field.source,
                generated_outputs,
                parameters,
            );
            written += 1;
        } else if (object.get(key)) |value| {
            if (written != 0) try output.writer.writeByte(',');
            try definition_core.canonical_json.writeCanonicalString(
                &output.writer,
                key,
            );
            try output.writer.writeByte(':');
            var path = EventJsonPath{};
            try path.push(key);
            try writeEventJsonValue(
                allocator,
                &output.writer,
                materialization,
                value,
                &path,
            );
            written += 1;
        }
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn canonicalPlainStoredBodyAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    body: std.json.Value,
) ![]u8 {
    if (materialization.body_order.len == 0) {
        return definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            body,
        );
    }
    const object = try definition_core.json.object(body);
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!containsDeclaredName(
            materialization.body_order,
            entry.key_ptr.*,
        )) return error.EventBodyFieldCoverageMismatch;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    var written: usize = 0;
    for (materialization.body_order) |key| {
        const value = object.get(key) orelse continue;
        if (written != 0) try output.writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            key,
        );
        try output.writer.writeByte(':');
        var path = EventJsonPath{};
        try path.push(key);
        try writeEventJsonValue(
            allocator,
            &output.writer,
            materialization,
            value,
            &path,
        );
        written += 1;
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn containsDeclaredName(
    names: []const []u8,
    expected: []const u8,
) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

fn writeMaterializedBodyField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    source: storage.EventBodyFieldSource,
    generated_outputs: []const GeneratedOutput,
    parameters: ?*const definition_core.parameters.Bindings,
) !void {
    switch (source) {
        .generated_sha256 => |name| try writeGeneratedBodyDigest(
            allocator,
            writer,
            materialization,
            generated_outputs,
            name,
        ),
        .parameter_sha256 => |config| try writeParameterBodyDigest(
            allocator,
            writer,
            materialization,
            plan,
            state,
            parameters,
            config,
        ),
        .state_value => |config| try writeStateBodyValue(
            allocator,
            writer,
            materialization,
            plan,
            state,
            config,
        ),
        .literal_mapping => |mapping| {
            try writer.writeAll(mapping.stored_literal);
        },
        .derived => |name| {
            const generated = findGeneratedOutput(
                generated_outputs,
                name,
            ) orelse return error.EventDerivedOutputMissing;
            try writeEventJsonString(
                writer,
                generated.value,
                materialization.escape_non_ascii,
            );
        },
        .request_input => unreachable,
    }
}

fn writeGeneratedBodyDigest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    generated_outputs: []const GeneratedOutput,
    name: []const u8,
) !void {
    const generated = findGeneratedOutput(
        generated_outputs,
        name,
    ) orelse return error.EventGeneratedOutputMissing;
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        generated.value,
    );
    defer allocator.free(digest);
    try writeEventJsonString(
        writer,
        digest,
        materialization.escape_non_ascii,
    );
}

fn writeParameterBodyDigest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    parameters: ?*const definition_core.parameters.Bindings,
    config: storage.ParameterSha256Source,
) !void {
    const bound = parameters orelse return error.EventParametersMissing;
    const parameter = bound.find(config.parameter) orelse
        return error.EventParameterMissing;
    const text = scalarText(parameter.value) orelse
        return error.EventParameterMustBeText;
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        text,
    );
    defer allocator.free(digest);
    const expected = try stateSourceValue(
        plan orelse return error.PlainEventRequiresProtocolState,
        state orelse return error.PlainEventRequiresProtocolState,
        config.expected_state,
    );
    if (expected != .string or
        !timingSafeDigestEqual(digest, expected.string))
    {
        return error.EventCapabilityMismatch;
    }
    try writeEventJsonString(
        writer,
        digest,
        materialization.escape_non_ascii,
    );
}

fn writeStateBodyValue(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    materialization: *const storage.EventMaterialization,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    config: storage.StateValueSource,
) !void {
    const value = try stateSourceValue(
        plan orelse return error.PlainEventRequiresProtocolState,
        state orelse return error.PlainEventRequiresProtocolState,
        config,
    );
    var path = EventJsonPath{};
    try writeEventJsonValue(
        allocator,
        writer,
        materialization,
        value,
        &path,
    );
}

const ReconstructedBodyValue = union(enum) {
    json: std.json.Value,
    literal: []const u8,
};

const ReconstructedBodyMapping = struct {
    key: []const u8,
    value: ReconstructedBodyValue,
};

fn reconstructedBodyAlloc(
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    state: ?*const ReplayState,
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
    try validateReconstructedBodyFields(
        allocator,
        plan,
        state,
        materialization,
        object,
    );
    var mappings: std.ArrayList(ReconstructedBodyMapping) = .empty;
    defer mappings.deinit(allocator);
    try appendStoredBodyMappings(
        allocator,
        &mappings,
        materialization,
        object,
    );
    try appendDerivedBodyMappings(
        allocator,
        &mappings,
        materialization,
        event,
    );
    return writeReconstructedBodyAlloc(
        allocator,
        materialization,
        mappings.items,
    );
}

fn validateReconstructedBodyFields(
    allocator: std.mem.Allocator,
    plan: ?*const Plan,
    state: ?*const ReplayState,
    materialization: *const storage.EventMaterialization,
    object: std.json.ObjectMap,
) !void {
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
}

fn appendStoredBodyMappings(
    allocator: std.mem.Allocator,
    mappings: *std.ArrayList(ReconstructedBodyMapping),
    materialization: *const storage.EventMaterialization,
    object: std.json.ObjectMap,
) !void {
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
}

fn appendDerivedBodyMappings(
    allocator: std.mem.Allocator,
    mappings: *std.ArrayList(ReconstructedBodyMapping),
    materialization: *const storage.EventMaterialization,
    event: std.json.ObjectMap,
) !void {
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
        .generated_sha256,
        .parameter_sha256,
        .state_value,
        .derived,
        => {},
    };
}

fn writeReconstructedBodyAlloc(
    allocator: std.mem.Allocator,
    materialization: *const storage.EventMaterialization,
    mappings: []const ReconstructedBodyMapping,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    for (mappings, 0..) |mapping, index| {
        if (index != 0) try output.writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            &output.writer,
            mapping.key,
        );
        try output.writer.writeByte(':');
        switch (mapping.value) {
            .json => |value| {
                var path = EventJsonPath{};
                try path.push(mapping.key);
                try writeEventJsonValue(
                    allocator,
                    &output.writer,
                    materialization,
                    value,
                    &path,
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
    plan: ?*const Plan,
    state: ?*const ReplayState,
    source: storage.EventBodyFieldSource,
    actual: std.json.Value,
) !void {
    switch (source) {
        .generated_sha256 => {
            if (actual != .string) return error.EventBodyDigestInvalid;
            try definition_core.json.digest(actual.string);
        },
        .parameter_sha256 => |config| {
            const protocol_plan = plan orelse
                return error.PlainEventRequiresProtocolState;
            const protocol_state = state orelse
                return error.PlainEventRequiresProtocolState;
            const expected = try stateSourceValue(
                protocol_plan,
                protocol_state,
                config.expected_state,
            );
            if (!try valuesEqualForCustody(
                allocator,
                actual,
                expected,
            )) return error.EventCapabilityMismatch;
        },
        .state_value => |config| {
            const protocol_plan = plan orelse
                return error.PlainEventRequiresProtocolState;
            const protocol_state = state orelse
                return error.PlainEventRequiresProtocolState;
            const expected = try stateSourceValue(
                protocol_plan,
                protocol_state,
                config,
            );
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
        .derived => {
            if (actual != .string) return error.EventDerivedValueInvalid;
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

fn findGeneratedOutputLinear(
    outputs: []const GeneratedOutput,
    name: []const u8,
) ?*const GeneratedOutput {
    for (outputs) |*output| {
        if (std.mem.eql(u8, output.name, name)) return output;
    }
    return null;
}

fn findEventDerivationLinear(
    items: []const storage.EventDerivation,
    name: []const u8,
) ?*const storage.EventDerivation {
    for (items) |*item| {
        if (std.mem.eql(u8, item.name, name)) return item;
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
    std.sort.heap([]const u8, items, {}, struct {
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
    materialization: *const storage.EventMaterialization,
    source: storage.EventFieldSource,
    request: std.json.ObjectMap,
    sequence: u64,
    unix_seconds: i64,
    generated_outputs: []const GeneratedOutput,
) !void {
    switch (source) {
        .input_field => |input_field| {
            const value = request.get(input_field) orelse
                return error.EventRequestFieldMissing;
            var path = EventJsonPath{};
            try writeEventJsonValue(
                allocator,
                writer,
                materialization,
                value,
                &path,
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
            try writeEventJsonString(
                writer,
                value,
                materialization.escape_non_ascii,
            );
        },
        .unix_seconds => try writer.print("{d}", .{unix_seconds}),
        .derived => |name| {
            const generated = findGeneratedOutput(
                generated_outputs,
                name,
            ) orelse return error.EventDerivedOutputMissing;
            try writeEventJsonString(
                writer,
                generated.value,
                materialization.escape_non_ascii,
            );
        },
    }
}

fn setRule(slot: *?definition.Rule, rule: definition.Rule) !void {
    if (slot.* != null) return error.DuplicateEventProtocolRule;
    slot.* = rule;
}

fn compilePlainEnvelope(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rule: definition.Rule,
) !Envelope {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = parsed.value.object;
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "input" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "op", "input" },
    );
    try requireOperator(object, .append_only_log);
    const input_index = findInput(
        definition_plan.inputs,
        try definition_core.json.requiredString(object, "input"),
    ) orelse return error.UnknownProtocolInput;
    if (definition_plan.inputs[input_index].codec != .json) {
        return error.ProtocolInputMustBeJson;
    }
    const keys = try allocator.alloc([]u8, 0);
    errdefer allocator.free(keys);
    var field_keys: [6][]u8 = undefined;
    var initialized: usize = 0;
    errdefer for (field_keys[0..initialized]) |key| allocator.free(key);
    for (&field_keys) |*key| {
        key.* = try allocator.alloc(u8, 0);
        initialized += 1;
    }
    const partition_bindings = try allocator.alloc(PartitionBinding, 0);
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

fn compileEnvelope(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rule: definition.Rule,
) !Envelope {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = parsed.value.object;
    try validateEnvelopeDefinition(object);
    const input_index = try compileProtocolInputIndex(
        definition_plan,
        object,
    );
    const keys = try parseStringSet(
        allocator,
        try definition_core.json.field(object, "keys"),
        64,
    );
    errdefer deinitStringSet(allocator, keys);
    const field_keys = try compileEnvelopeFieldKeys(
        allocator,
        object,
        keys,
    );
    errdefer deinitEnvelopeFieldKeys(allocator, field_keys);
    const partition_bindings = if (object.get("partition_bindings")) |raw|
        try compilePartitionBindings(allocator, definition_plan, raw)
    else
        try allocator.alloc(PartitionBinding, 0);
    errdefer {
        for (partition_bindings) |*binding| binding.deinit(allocator);
        allocator.free(partition_bindings);
    }
    return .{
        .input_index = input_index,
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

fn validateEnvelopeDefinition(object: std.json.ObjectMap) !void {
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
}

fn compileProtocolInputIndex(
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !u8 {
    const input_index = findInput(
        definition_plan.inputs,
        try definition_core.json.requiredString(object, "input"),
    ) orelse return error.UnknownProtocolInput;
    if (definition_plan.inputs[input_index].codec != .json) {
        return error.ProtocolInputMustBeJson;
    }
    return @intCast(input_index);
}

const envelope_field_names = [_][]const u8{
    "sequence",
    "kind",
    "previous_digest",
    "body",
    "body_digest",
    "event_digest",
};

fn compileEnvelopeFieldKeys(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    keys: []const []u8,
) ![envelope_field_names.len][]u8 {
    var field_keys: [6][]u8 = undefined;
    var initialized: usize = 0;
    errdefer for (field_keys[0..initialized]) |key| allocator.free(key);
    inline for (envelope_field_names, 0..) |name, index| {
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
    return field_keys;
}

fn deinitEnvelopeFieldKeys(
    allocator: std.mem.Allocator,
    field_keys: [envelope_field_names.len][]u8,
) void {
    for (field_keys) |key| allocator.free(key);
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
        bindings[index] = try compilePartitionBinding(
            allocator,
            definition_plan,
            value,
        );
        initialized += 1;
    }
    std.sort.heap(PartitionBinding, bindings, {}, struct {
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
    try validatePartitionBindingOrder(bindings);
    return bindings;
}

fn compilePartitionBinding(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    value: std.json.Value,
) !PartitionBinding {
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
    const owned_parameter = try allocator.dupe(u8, parameter);
    errdefer allocator.free(owned_parameter);
    return .{
        .parameter = owned_parameter,
        .kind = declaration.kind,
        .event_value = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.requiredString(object, "event_value"),
        ),
    };
}

fn validatePartitionBindingOrder(bindings: []const PartitionBinding) !void {
    for (bindings[1..], 1..) |binding, index| {
        if (std.mem.eql(
            u8,
            bindings[index - 1].parameter,
            binding.parameter,
        )) return error.DuplicateProtocolPartitionParameter;
    }
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
    std.sort.heap([]u8, out, {}, struct {
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
    allow_empty: bool,
) ![][]u8 {
    const count = try decoder.readCount(max_count);
    if (count == 0 and !allow_empty) return error.InvalidProtocolStringSet;
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
    if (plan.event_kinds.len == 0 or plan.event_kinds.len > 256 or
        plan.max_records == 0 or plan.max_records > 10_000_000)
    {
        return error.InvalidProtocolPlan;
    }
    try validateSortedStringSet(plan.event_kinds);
    switch (plan.mode) {
        .plain => try validatePlainPlan(plan),
        .chained => try validateChainedPlan(plan),
    }
    if (plan.reducer_plan) |*compiled| try reducer.validatePlan(compiled);
    if (plan.reducer_plan != null and plan.state_reducer_plan != null) {
        return error.MultipleProtocolReducers;
    }
}

fn validatePlainPlan(plan: *const Plan) !void {
    if (plan.envelope.keys.len != 0 or
        plan.envelope.partition_bindings.len != 0 or
        plan.envelope.sequence_key.len != 0 or
        plan.envelope.kind_key.len != 0 or
        plan.envelope.previous_digest_key.len != 0 or
        plan.envelope.body_key.len != 0 or
        plan.envelope.body_digest_key.len != 0 or
        plan.envelope.event_digest_key.len != 0 or
        plan.sequence_start != 0 or
        plan.genesis != .null or
        (plan.reducer_plan == null) == (plan.state_reducer_plan == null) or
        (plan.reducer_plan != null and
            plan.reducer_plan.?.event_kind == null))
    {
        return error.InvalidPlainProtocolPlan;
    }
}

fn validateChainedPlan(plan: *const Plan) !void {
    if (plan.envelope.keys.len == 0 or
        plan.envelope.keys.len > 64 or
        plan.sequence_start > std.math.maxInt(i64))
    {
        return error.InvalidProtocolPlan;
    }
    try validateSortedStringSet(plan.envelope.keys);
    try validateChainedPartitionBindings(
        plan.envelope.partition_bindings,
    );
    try validateChainedEnvelopeFields(&plan.envelope);
    switch (plan.genesis) {
        .null => {},
        .digest => |digest| try definition_core.json.digest(digest),
    }
}

fn validateChainedPartitionBindings(
    bindings: []const PartitionBinding,
) !void {
    if (bindings.len > 32) {
        return error.InvalidProtocolPartitionBindings;
    }
    for (bindings, 0..) |binding, index| {
        try definition_core.json.safeIdentifier(binding.parameter, 128);
        if (index != 0 and
            std.mem.order(
                u8,
                bindings[index - 1].parameter,
                binding.parameter,
            ) != .lt)
        {
            return error.InvalidProtocolPartitionBindings;
        }
    }
}

fn validateChainedEnvelopeFields(envelope: *const Envelope) !void {
    const fields = [_][]const u8{
        envelope.sequence_key,
        envelope.kind_key,
        envelope.previous_digest_key,
        envelope.body_key,
        envelope.body_digest_key,
        envelope.event_digest_key,
    };
    for (fields, 0..) |field, index| {
        try definition_core.json.safeIdentifier(field, 256);
        if (!containsSorted(envelope.keys, field)) {
            return error.EventEnvelopeFieldNotDeclared;
        }
        for (fields[0..index]) |prior| {
            if (std.mem.eql(u8, prior, field)) {
                return error.DuplicateEventEnvelopeField;
            }
        }
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
                .compare_append, .bind_existing, .rebind_existing => {},
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
                .compare_append, .bind_existing, .rebind_existing => {},
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
                const expected_mode: storage.EventMaterializationMode =
                    switch (plan.mode) {
                        .chained => .chained,
                        .plain => .plain,
                    };
                if (event.mode != expected_mode) {
                    return error.EventMaterializationModeMismatch;
                }
                materialized_effects += 1;
                if (plan.mode == .chained) {
                    try validateEventMaterialization(plan, &event);
                }
            } else {
                plain_effects += 1;
            }
        }
    }
    if (plan.mode == .chained and
        materialized_effects != 0 and
        plain_effects != 0)
    {
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
        .derived => {},
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
    return findSortedIndex(items, needle) != null;
}

fn findSortedIndex(
    items: []const []u8,
    needle: []const u8,
) ?usize {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, items[mid], needle)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return mid,
        }
    }
    return null;
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

const protocol_test_schema =
    "\"schema\":\"ledger-artifact-definition/v1\",";
const protocol_test_owner = "\"owner\":\"example\",";
const protocol_test_event_input =
    "\"parameters\":{},\"inputs\":{\"event\":{\"codec\":\"json\"," ++
    "\"max_bytes\":4096}},\"canonicalization\":{},";
const protocol_test_envelope_shape =
    "\"shape\":{\"documents\":{\"event\":{\"event_envelope\":{" ++
    "\"keys\":[\"body\",\"body_digest\",\"event_digest\",\"kind\"," ++
    "\"previous_digest\",\"sequence\"],\"sequence\":\"/sequence\"," ++
    "\"kind\":\"/kind\",\"previous_digest\":\"/previous_digest\"," ++
    "\"body\":\"/body\",\"body_digest\":\"/body_digest\"," ++
    "\"event_digest\":\"/event_digest\"}}}},";
const protocol_test_append_operation =
    "\"operations\":{\"append\":{\"effects\":[{\"op\":\"compare-and-append\"," ++
    "\"slot\":\"events\",\"input\":\"event\"}]}},";
const protocol_test_bounds_2 =
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":65536," ++
    "\"max_records\":2,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":4}}";
const protocol_test_bounds_4 =
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":65536," ++
    "\"max_records\":4,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":4}}";

const chained_protocol_definition =
    "{" ++ protocol_test_schema ++
    "\"id\":\"example/protocol\"," ++ protocol_test_owner ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"body-digest\",\"compare-and-append\",\"event-digest\"," ++
    "\"event-envelope\",\"event-kinds\",\"previous-digest\",\"replay\"," ++
    "\"sequence\"]}," ++ protocol_test_event_input ++
    protocol_test_envelope_shape ++
    "\"constraints\":{\"event_log\":{\"start\":1,\"genesis\":null," ++
    "\"kinds\":[\"created\",\"updated\"]}},\"identity\":{}," ++
    "\"storage\":{\"kind\":\"event-log\",\"slots\":{\"events\":{" ++
    "\"path\":\"example/events.jsonl\",\"kind\":\"event-log\"," ++
    "\"codec\":\"jsonl\",\"max_bytes\":65536}}}," ++
    protocol_test_append_operation ++ "\"projections\":{}," ++
    protocol_test_bounds_2;

const retained_protocol_definition =
    "{" ++ protocol_test_schema ++
    "\"id\":\"example/retained-protocol\"," ++ protocol_test_owner ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"body-digest\",\"compare-and-append\",\"cross-input-equal\"," ++
    "\"event-digest\",\"event-envelope\",\"event-kinds\"," ++
    "\"previous-digest\",\"reducer\",\"replay\",\"sequence\"]}," ++
    protocol_test_event_input ++ protocol_test_envelope_shape ++
    "\"constraints\":{\"event_log\":{\"start\":1,\"genesis\":null," ++
    "\"kinds\":[\"created\",\"updated\"]},\"state\":{\"mode\":\"retained\"," ++
    "\"event_kind\":\"/kind\",\"registers\":{\"current\":4096},\"sets\":{}," ++
    "\"admissions\":[{\"on\":\"created\",\"forbids\":[\"current\"]," ++
    "\"actions\":[[\"set\",\"current\",\"event#/body\"]]}," ++
    "{\"on\":\"updated\",\"requires\":[\"current\"],\"laws\":[[" ++
    "\"cross-input-equal\",\"event#/body/id\",\"current#/id\"]]," ++
    "\"actions\":[[\"set\",\"current\",\"event#/body\"]]}]}}," ++
    "\"identity\":{}," ++
    "\"storage\":{\"kind\":\"event-log\",\"slots\":{\"events\":{" ++
    "\"path\":\"example/retained.jsonl\",\"kind\":\"event-log\"," ++
    "\"codec\":\"jsonl\",\"max_bytes\":65536}}}," ++
    protocol_test_append_operation ++ "\"projections\":{}," ++
    protocol_test_bounds_4;

const guarded_keyed_protocol_definition =
    "{" ++ protocol_test_schema ++
    "\"id\":\"example/guarded-keyed-protocol\"," ++ protocol_test_owner ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"append-only-log\",\"compare-and-append\",\"cross-input-equal\"," ++
    "\"event-kinds\",\"reducer\",\"replay\",\"transition-table\"]}," ++
    protocol_test_event_input ++
    "\"shape\":{\"documents\":{\"event\":{}}}," ++
    "\"constraints\":{\"laws\":[[\"append-only-log\",{" ++
    "\"input\":\"event\"}],[\"event-kinds\",{\"values\":[" ++
    "\"capture\",\"status\"]}],[\"transition-table\",{\"states\":[" ++
    "\"closed\",\"open\"],\"transitions\":[{\"from\":null," ++
    "\"on\":\"open\",\"to\":\"open\"},{\"from\":\"open\"," ++
    "\"on\":\"closed\",\"to\":\"closed\"}]}],[\"reducer\",{" ++
    "\"key\":\"/id\",\"on\":\"/status\",\"event_kind\":\"/kind\"," ++
    "\"retain_once\":\"/record\",\"guards\":[{\"event_kind\":\"status\"," ++
    "\"on\":\"closed\",\"rules\":[[\"cross-input-equal\",{" ++
    "\"input\":\"event\",\"left_input\":\"event\",\"left\":\"/claim\"," ++
    "\"right_input\":\"retained\",\"right\":\"/id\"}]]}]}]]}," ++
    "\"identity\":{},\"storage\":{\"kind\":\"event-log\",\"slots\":{" ++
    "\"events\":{\"path\":\"example/guarded.jsonl\",\"kind\":\"event-log\"," ++
    "\"codec\":\"jsonl\",\"max_bytes\":65536}}}," ++
    protocol_test_append_operation ++ "\"projections\":{}," ++
    protocol_test_bounds_4;

const invalid_protocol_definition =
    "{" ++ protocol_test_schema ++
    "\"id\":\"example/protocol-errors\"," ++ protocol_test_owner ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"body-digest\",\"compare-and-append\",\"event-digest\"," ++
    "\"event-envelope\",\"event-kinds\",\"previous-digest\",\"replay\"," ++
    "\"sequence\"]}," ++ protocol_test_event_input ++
    protocol_test_envelope_shape ++
    "\"constraints\":{\"event_log\":{\"start\":0,\"genesis\":null," ++
    "\"kinds\":[\"accepted\"]}},\"identity\":{}," ++
    "\"storage\":{\"kind\":\"event-log\",\"slots\":{\"events\":{" ++
    "\"path\":\"example/errors.jsonl\",\"kind\":\"event-log\"," ++
    "\"codec\":\"jsonl\",\"max_bytes\":65536}}}," ++
    protocol_test_append_operation ++ "\"projections\":{}," ++
    protocol_test_bounds_4;

const request_literals_definition =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/request-literals","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","compare-and-append","enum","event-digest","event-envelope","event-kinds","event-materialization","exact-object","path-format","previous-digest","replay","sequence"]},"parameters":{"stream":{"type":"safe_identifier","required":true}},"inputs":{"alternate":{"codec":"json","max_bytes":4096},"request":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"alternate":{"object":"exact","fields":{"body":{},"kind":{},"schema":{"enum":["example-alternate/v1"]},"stream_id":{}}},"request":{"object":"exact","fields":{"body":{},"kind":{},"schema":{"enum":["example-request/v1"]},"stream_id":{}},"event_envelope":{"keys":["body","body_digest","event_digest","kind","previous_digest","schema","sequence","stream_id"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest","partition_bindings":[{"parameter":"stream","event_value":"/stream_id"}]}}}},"constraints":{"laws":[["sequence",{"start":1}],["previous-digest",{"genesis":null}],["body-digest"],["event-digest"],["event-kinds",{"values":["created"]}]]},"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/{stream}/request-literals.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"request","event":{"mode":"chained","body_input_field":"body","fields":[{"field":"kind","input_field":"kind"},{"field":"schema","literal":"example-event/v1"},{"field":"stream_id","input_field":"stream_id"}],"request_literals":[{"field":"schema","literal":"example-request/v1"}],"body_fields":[{"field":"schema","literal_mapping":{"request":"example-body-request/v1","stored":"example-body-event/v1"}},{"field":"stream_id","request_input":"stream_id"}]}}]},"append-alternate":{"effects":[{"op":"compare-and-append","slot":"events","input":"alternate","event":{"mode":"chained","body_input_field":"body","fields":[{"field":"kind","input_field":"kind"},{"field":"schema","literal":"example-event/v1"},{"field":"stream_id","input_field":"stream_id"}],"request_literals":[{"field":"schema","literal":"example-alternate/v1"}]}}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
;

const plain_derivation_definition =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/derived-events","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["compare-and-append","composite-identity","event-materialization","exact-object","sha256","timestamp"]},"parameters":{},"inputs":{"submission":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"documents":{"submission":{"object":"exact","fields":{"logical_kind":{},"note":{"object":"exact","fields":{"operation":{},"summary":{},"details":{"object":"exact","fields":{"z":{},"a":{}}}}},"physical_kind":{}}}}},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/derived-events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{"capture":{"effects":[{"op":"compare-and-append","slot":"events","input":"submission","event":{"mode":"plain","body_input_field":"note","field_order":["v","source","event","record_id","captured_at","kind","logical_kind","operation","note"],"body_order":["id","captured_at","logical_kind","kind","operation","summary","details","fingerprint"],"fields":[{"field":"v","literal":1},{"field":"source","literal":"example"},{"field":"event","literal":"example.capture"},{"field":"record_id","derived":"record_id"},{"field":"captured_at","derived":"captured_at"},{"field":"kind","input_field":"physical_kind"},{"field":"logical_kind","input_field":"logical_kind"},{"field":"operation","derived":"operation"}],"derive":[{"name":"physical_kind","op":"input-text","pointer":"/physical_kind"},{"name":"logical_kind","op":"input-text","pointer":"/logical_kind"},{"name":"operation","op":"input-text","pointer":"/note/operation"},{"name":"captured_at","op":"utc-timestamp","format":"rfc3339-seconds"},{"name":"fingerprint","op":"sha256","encoding":"hex","fragments":[{"literal":"example\n"},{"input_text":"/physical_kind"},{"literal":"\n"},{"input_text":"/logical_kind"},{"literal":"\n"},{"input_json":"/note"}],"max_bytes":4096},{"name":"record_id","op":"concat","fragments":[{"literal":"EVT-"},{"derived":"captured_at","transform":"compact-utc"},{"literal":"-"},{"derived":"fingerprint","prefix_bytes":16}],"max_bytes":64}],"body_fields":[{"field":"id","derived":"record_id"},{"field":"captured_at","derived":"captured_at"},{"field":"logical_kind","derived":"logical_kind"},{"field":"kind","derived":"physical_kind"},{"field":"fingerprint","derived":"fingerprint"}]}}]}},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const request_literal_input =
    "{\"schema\":\"example-request/v1\",\"kind\":\"created\"," ++
    "\"stream_id\":\"stream-1\",\"body\":{\"id\":\"item-1\"," ++
    "\"schema\":\"example-body-request/v1\",\"stream_id\":\"stream-1\"}}";
const request_literal_reconstructed =
    "{\"body\":{\"id\":\"item-1\",\"schema\":\"example-body-request/v1\"," ++
    "\"stream_id\":\"stream-1\"},\"kind\":\"created\"," ++
    "\"schema\":\"example-request/v1\",\"stream_id\":\"stream-1\"}";
const request_literal_tampered_event =
    "{\"body\":{\"id\":\"item-1\",\"schema\":\"example-body-wrong/v1\"}," ++
    "\"body_digest\":\"\",\"event_digest\":\"\",\"kind\":\"created\"," ++
    "\"previous_digest\":null,\"schema\":\"example-event/v1\"," ++
    "\"sequence\":1,\"stream_id\":\"stream-1\"}";
const request_literal_invalid_input =
    "{\"schema\":\"wrong/v1\",\"kind\":\"created\"," ++
    "\"stream_id\":\"stream-1\",\"body\":{\"id\":\"item-1\"}}";
const request_literal_mismatched_body =
    "{\"schema\":\"example-request/v1\",\"kind\":\"created\"," ++
    "\"stream_id\":\"stream-1\",\"body\":{\"id\":\"item-1\"," ++
    "\"schema\":\"example-body-request/v1\",\"stream_id\":\"stream-2\"}}";

const plain_derivation_request =
    "{\"logical_kind\":\"assertion\",\"note\":{\"details\":{" ++
    "\"z\":\"last\",\"a\":\"first\"},\"operation\":\"create\"," ++
    "\"summary\":\"hello\"},\"physical_kind\":\"stored-assertion\"}";
const plain_derivation_normalized_request =
    "{\"logical_kind\":\"assertion\",\"note\":{\"operation\":\"create\"," ++
    "\"summary\":\"hello\",\"details\":{\"z\":\"last\",\"a\":\"first\"}}," ++
    "\"physical_kind\":\"stored-assertion\"}";
const plain_derivation_fingerprint =
    "05ca5d4775e018b752104bc965b93536d64e7344522b63298785b985e423b21f";
const plain_derivation_event =
    "{\"v\":1,\"source\":\"example\",\"event\":\"example.capture\"," ++
    "\"record_id\":\"EVT-20260630T123456Z-05ca5d4775e018b7\"," ++
    "\"captured_at\":\"2026-06-30T12:34:56Z\"," ++
    "\"kind\":\"stored-assertion\",\"logical_kind\":\"assertion\"," ++
    "\"operation\":\"create\",\"note\":{" ++
    "\"id\":\"EVT-20260630T123456Z-05ca5d4775e018b7\"," ++
    "\"captured_at\":\"2026-06-30T12:34:56Z\"," ++
    "\"logical_kind\":\"assertion\",\"kind\":\"stored-assertion\"," ++
    "\"operation\":\"create\",\"summary\":\"hello\"," ++
    "\"details\":{\"z\":\"last\",\"a\":\"first\"}," ++
    "\"fingerprint\":\"" ++ plain_derivation_fingerprint ++ "\"}}";

const ProtocolTestPlans = struct {
    tmp: std.testing.TmpDir,
    closure: definition_core.closure.Closure,
    definition_plan: definition.Plan,
    storage_plan: storage.Plan,
    plan: ?Plan,

    fn init(source: []const u8) !ProtocolTestPlans {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "protocol.json",
            .data = source,
        });
        var closure = try definition_core.closure.loadFromDir(
            std.testing.allocator,
            &tmp.dir,
            "protocol.json",
            .{},
        );
        errdefer closure.deinit(std.testing.allocator);
        var definition_plan = try definition.compile(
            std.testing.allocator,
            &closure,
            "protocol.json",
        );
        errdefer definition_plan.deinit(std.testing.allocator);
        var storage_plan = try storage.compile(
            std.testing.allocator,
            &definition_plan,
        );
        errdefer storage_plan.deinit(std.testing.allocator);
        var plan = try compile(
            std.testing.allocator,
            &definition_plan,
            &storage_plan,
        );
        errdefer if (plan) |*compiled| {
            compiled.deinit(std.testing.allocator);
        };
        return .{
            .tmp = tmp,
            .closure = closure,
            .definition_plan = definition_plan,
            .storage_plan = storage_plan,
            .plan = plan,
        };
    }

    fn deinit(self: *ProtocolTestPlans) void {
        if (self.plan) |*plan| plan.deinit(std.testing.allocator);
        self.storage_plan.deinit(std.testing.allocator);
        self.definition_plan.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn protocol(self: *const ProtocolTestPlans) *const Plan {
        return &self.plan.?;
    }

    fn cacheProtocol(self: *const ProtocolTestPlans) !Plan {
        const plan = self.protocol();
        var encoder = definition_core.cache.Encoder.init(
            std.testing.allocator,
            256 * 1024,
        );
        defer encoder.deinit();
        try encodeCache(plan, &encoder);
        const payload = try encoder.toOwnedSlice();
        defer std.testing.allocator.free(payload);
        var decoder = definition_core.cache.Decoder.init(payload);
        var cached = try decodeCache(std.testing.allocator, &decoder);
        errdefer cached.deinit(std.testing.allocator);
        try decoder.finish();
        try validateCachePlan(
            &cached,
            &self.definition_plan,
            &self.storage_plan,
        );
        return cached;
    }

    fn cacheStorage(self: *const ProtocolTestPlans) !storage.Plan {
        var encoder = definition_core.cache.Encoder.init(
            std.testing.allocator,
            256 * 1024,
        );
        defer encoder.deinit();
        try storage.encodeCache(&self.storage_plan, &encoder);
        const payload = try encoder.toOwnedSlice();
        defer std.testing.allocator.free(payload);
        var decoder = definition_core.cache.Decoder.init(payload);
        var cached = try storage.decodeCache(
            std.testing.allocator,
            &decoder,
        );
        errdefer cached.deinit(std.testing.allocator);
        try decoder.finish();
        try storage.validateCachePlan(&cached, &self.definition_plan);
        return cached;
    }
};

test "compiled event protocol validates exact chained envelopes" {
    var plans = try ProtocolTestPlans.init(chained_protocol_definition);
    defer plans.deinit();
    const plan = plans.protocol();
    var cached = try plans.cacheProtocol();
    defer cached.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        plan.envelope.event_digest_key,
        cached.envelope.event_digest_key,
    );
    try std.testing.expectEqualStrings(
        plan.event_kinds[1],
        cached.event_kinds[1],
    );
    var state = ReplayState.init(plan);
    defer state.deinit(std.testing.allocator);
    const first = try eventAlloc(
        std.testing.allocator,
        1,
        "created",
        null,
        "{\"id\":\"item-1\",\"status\":\"open\"}",
    );
    defer std.testing.allocator.free(first);
    try apply(std.testing.allocator, plan, &state, first);
    try std.testing.expectEqual(@as(usize, 1), state.records);
    try std.testing.expectError(
        error.EventSequenceMismatch,
        apply(std.testing.allocator, plan, &state, first),
    );
    const second = try eventAlloc(
        std.testing.allocator,
        2,
        "updated",
        state.previousDigest(),
        "{\"id\":\"item-1\",\"status\":\"closed\"}",
    );
    defer std.testing.allocator.free(second);
    try apply(std.testing.allocator, plan, &state, second);
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
        apply(std.testing.allocator, plan, &state, third),
    );
}

test "retained reducer validates events against compiled current state" {
    var plans = try ProtocolTestPlans.init(retained_protocol_definition);
    defer plans.deinit();
    const plan = plans.protocol();
    try std.testing.expect(plan.reducer_plan == null);
    try std.testing.expect(plan.state_reducer_plan != null);
    var cached = try plans.cacheProtocol();
    defer cached.deinit(std.testing.allocator);

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

test "checkpoint restore preserves retained replay state" {
    var plans = try ProtocolTestPlans.init(retained_protocol_definition);
    defer plans.deinit();
    var plan = try plans.cacheProtocol();
    defer plan.deinit(std.testing.allocator);
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
    const definition_digest =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const encoded = try encodeCheckpointAlloc(
        std.testing.allocator,
        &state,
        definition_digest,
    );
    defer std.testing.allocator.free(encoded);
    var restored = try decodeCheckpoint(
        std.testing.allocator,
        &plan,
        encoded,
    );
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        definition_digest,
        restored.definition_digest,
    );
    try std.testing.expectEqual(state.records, restored.state.records);
    try std.testing.expectEqualStrings(
        state.previousDigest().?,
        restored.state.previousDigest().?,
    );
    const current = restored.state.state_reducer_state.get(
        &plan.state_reducer_plan.?,
        "current",
    ).?;
    var status = try definition_core.json_pointer.compile(
        std.testing.allocator,
        "/status",
    );
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "open",
        definition_core.json_pointer.lookup(current, status).?.string,
    );
    const second = try eventAlloc(
        std.testing.allocator,
        2,
        "updated",
        restored.state.previousDigest(),
        "{\"id\":\"item-1\",\"status\":\"closed\"}",
    );
    defer std.testing.allocator.free(second);
    try apply(std.testing.allocator, &plan, &state, second);
    try apply(std.testing.allocator, &plan, &restored.state, second);
    try std.testing.expectEqualStrings(
        state.previousDigest().?,
        restored.state.previousDigest().?,
    );
    try std.testing.expectEqual(state.records, restored.state.records);
}

test "keyed reducer guards validate transitions against retained values" {
    var plans = try ProtocolTestPlans.init(guarded_keyed_protocol_definition);
    defer plans.deinit();
    var cached = try plans.cacheProtocol();
    defer cached.deinit(std.testing.allocator);
    var state = ReplayState.init(&cached);
    defer state.deinit(std.testing.allocator);
    try apply(
        std.testing.allocator,
        &cached,
        &state,
        "{\"id\":\"item-1\",\"kind\":\"capture\"," ++
            "\"record\":{\"id\":\"expected\"},\"status\":\"open\"}",
    );
    const definition_digest =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const checkpoint_bytes = try encodeCheckpointAlloc(
        std.testing.allocator,
        &state,
        definition_digest,
    );
    defer std.testing.allocator.free(checkpoint_bytes);
    var restored = try decodeCheckpoint(
        std.testing.allocator,
        &cached,
        checkpoint_bytes,
    );
    defer restored.deinit(std.testing.allocator);
    try verifyGuardedCheckpointParity(
        &cached,
        &state,
        &restored.state,
        definition_digest,
    );
}

fn verifyGuardedCheckpointParity(
    plan: *const Plan,
    expected_state: *ReplayState,
    restored_state: *ReplayState,
    definition_digest: []const u8,
) !void {
    try std.testing.expectError(
        error.ReducerTransitionGuardRejected,
        apply(
            std.testing.allocator,
            plan,
            expected_state,
            "{\"claim\":\"wrong\",\"id\":\"item-1\"," ++
                "\"kind\":\"status\",\"status\":\"closed\"}",
        ),
    );
    try std.testing.expectError(
        error.ReducerTransitionGuardRejected,
        apply(
            std.testing.allocator,
            plan,
            restored_state,
            "{\"claim\":\"wrong\",\"id\":\"item-1\"," ++
                "\"kind\":\"status\",\"status\":\"closed\"}",
        ),
    );
    try apply(
        std.testing.allocator,
        plan,
        expected_state,
        "{\"claim\":\"expected\",\"id\":\"item-1\"," ++
            "\"kind\":\"status\",\"status\":\"closed\"}",
    );
    try apply(
        std.testing.allocator,
        plan,
        restored_state,
        "{\"claim\":\"expected\",\"id\":\"item-1\"," ++
            "\"kind\":\"status\",\"status\":\"closed\"}",
    );
    const expected = try encodeCheckpointAlloc(
        std.testing.allocator,
        expected_state,
        definition_digest,
    );
    defer std.testing.allocator.free(expected);
    const actual = try encodeCheckpointAlloc(
        std.testing.allocator,
        restored_state,
        definition_digest,
    );
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "event materialization reconstructs validated request literals" {
    var plans = try ProtocolTestPlans.init(request_literals_definition);
    defer plans.deinit();
    var cached_storage = try plans.cacheStorage();
    defer cached_storage.deinit(std.testing.allocator);
    var plan = (try compile(
        std.testing.allocator,
        &plans.definition_plan,
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
    const event = try verifyMaterializedRequestRoundTrip(
        &plan,
        &state,
        materialization,
    );
    defer std.testing.allocator.free(event);
    try verifyMaterializedPartitionBinding(
        &plans.definition_plan,
        &plan,
        &state,
        event,
    );
    try verifyMaterializedRequestRejections(
        &plan,
        &state,
        materialization,
    );
}

fn verifyMaterializedRequestRoundTrip(
    plan: *const Plan,
    state: *ReplayState,
    materialization: *const storage.EventMaterialization,
) ![]u8 {
    var request = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        request_literal_input,
        .{ .allocate = .alloc_always },
    );
    defer request.deinit();
    const event = try materializeEventAlloc(
        std.testing.allocator,
        plan,
        state,
        materialization,
        request.value,
        7,
    );
    errdefer std.testing.allocator.free(event);
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
    try verifyReconstructedRequestLiterals(
        plan,
        state,
        materialization,
        event,
    );
    return event;
}

fn verifyReconstructedRequestLiterals(
    plan: *const Plan,
    state: *ReplayState,
    materialization: *const storage.EventMaterialization,
    event: []const u8,
) !void {
    var parsed_event = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        event,
        .{ .allocate = .alloc_always },
    );
    defer parsed_event.deinit();
    const reconstructed = try reconstructInputAlloc(
        std.testing.allocator,
        plan,
        state,
        materialization,
        parsed_event.value,
    );
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqualStrings(
        request_literal_reconstructed,
        reconstructed,
    );
    var tampered_event = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        request_literal_tampered_event,
        .{ .allocate = .alloc_always },
    );
    defer tampered_event.deinit();
    try std.testing.expectError(
        error.EventLiteralMismatch,
        reconstructInputAlloc(
            std.testing.allocator,
            plan,
            state,
            materialization,
            tampered_event.value,
        ),
    );
}

fn verifyMaterializedPartitionBinding(
    definition_plan: *const definition.Plan,
    plan: *const Plan,
    state: *ReplayState,
    event: []const u8,
) !void {
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "stream-1" }},
    );
    defer parameters.deinit(std.testing.allocator);
    try applyBound(
        std.testing.allocator,
        plan,
        state,
        event,
        &parameters,
    );
    var wrong_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "stream-2" }},
    );
    defer wrong_parameters.deinit(std.testing.allocator);
    var wrong_state = ReplayState.init(plan);
    defer wrong_state.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.EventPartitionValueMismatch,
        applyBound(
            std.testing.allocator,
            plan,
            &wrong_state,
            event,
            &wrong_parameters,
        ),
    );
    try std.testing.expectError(
        error.ProtocolPartitionParametersMissing,
        apply(
            std.testing.allocator,
            plan,
            &wrong_state,
            event,
        ),
    );
}

fn verifyMaterializedRequestRejections(
    plan: *const Plan,
    state: *ReplayState,
    materialization: *const storage.EventMaterialization,
) !void {
    var invalid_request = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        request_literal_invalid_input,
        .{ .allocate = .alloc_always },
    );
    defer invalid_request.deinit();
    try std.testing.expectError(
        error.EventRequestLiteralMismatch,
        materializeEventAlloc(
            std.testing.allocator,
            plan,
            state,
            materialization,
            invalid_request.value,
            7,
        ),
    );
    var mismatched_body_input = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        request_literal_mismatched_body,
        .{ .allocate = .alloc_always },
    );
    defer mismatched_body_input.deinit();
    try std.testing.expectError(
        error.EventBodyRequestInputMismatch,
        materializeEventAlloc(
            std.testing.allocator,
            plan,
            state,
            materialization,
            mismatched_body_input.value,
            7,
        ),
    );
}

test "event protocol rejects unknown kinds and broken digest links" {
    var plans = try ProtocolTestPlans.init(invalid_protocol_definition);
    defer plans.deinit();
    const plan = plans.protocol();

    var unknown_state = ReplayState.init(plan);
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
        apply(std.testing.allocator, plan, &unknown_state, unknown),
    );

    var linked_state = ReplayState.init(plan);
    defer linked_state.deinit(std.testing.allocator);
    const first = try eventAlloc(
        std.testing.allocator,
        0,
        "accepted",
        null,
        "{\"id\":\"item-1\"}",
    );
    defer std.testing.allocator.free(first);
    try apply(std.testing.allocator, plan, &linked_state, first);
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
        apply(std.testing.allocator, plan, &linked_state, broken),
    );
}

test "plain event derivations preserve timestamp fingerprint and identity" {
    var plans = try ProtocolTestPlans.init(plain_derivation_definition);
    defer plans.deinit();
    var cached = try plans.cacheStorage();
    defer cached.deinit(std.testing.allocator);
    const materialization = &cached.operations[0].effects[0].event.?;
    var parsed_request = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        plain_derivation_request,
        .{ .allocate = .alloc_always },
    );
    defer parsed_request.deinit();
    var materialized = try materializePlainEvent(
        std.testing.allocator,
        null,
        materialization,
        parsed_request.value,
        null,
        1_782_822_896,
        std.testing.io,
    );
    defer materialized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        plain_derivation_event,
        materialized.content,
    );
    try std.testing.expectEqual(
        @as(usize, 6),
        materialized.generated_outputs.len,
    );
    var parsed_event = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        materialized.content,
        .{ .allocate = .alloc_always },
    );
    defer parsed_event.deinit();
    const reconstructed = try reconstructPlainInputAlloc(
        std.testing.allocator,
        null,
        materialization,
        parsed_event.value,
    );
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqualStrings(
        plain_derivation_normalized_request,
        reconstructed,
    );
    try verifyPlainDerivationTampering(
        materialization,
        materialized.content,
    );
}

fn verifyPlainDerivationTampering(
    materialization: *const storage.EventMaterialization,
    content: []const u8,
) !void {
    const tampered = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        content,
        plain_derivation_fingerprint,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    defer std.testing.allocator.free(tampered);
    var parsed_tampered = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        tampered,
        .{ .allocate = .alloc_always },
    );
    defer parsed_tampered.deinit();
    try std.testing.expectError(
        error.EventDerivedValueMismatch,
        reconstructPlainInputAlloc(
            std.testing.allocator,
            null,
            materialization,
            parsed_tampered.value,
        ),
    );
}

test "compact UTC timestamp rejects impossible calendar values" {
    const invalid = [_][]const u8{
        "0000-01-01T00:00:00Z",
        "2026-00-01T00:00:00Z",
        "2026-13-01T00:00:00Z",
        "2026-02-29T00:00:00Z",
        "2024-02-30T00:00:00Z",
        "2026-04-31T00:00:00Z",
        "2026-01-01T24:00:00Z",
        "2026-01-01T00:60:00Z",
        "2026-01-01T00:00:60Z",
    };
    for (invalid) |value| {
        try std.testing.expectError(
            error.EventTimestampTransformInvalid,
            compactUtcTimestampAlloc(std.testing.allocator, value),
        );
    }
    const leap = try compactUtcTimestampAlloc(
        std.testing.allocator,
        "2024-02-29T23:59:59Z",
    );
    defer std.testing.allocator.free(leap);
    try std.testing.expectEqualStrings("20240229T235959Z", leap);
}
