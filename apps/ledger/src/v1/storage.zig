const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const document = @import("document.zig");

pub const SlotKind = enum {
    document,
    event_log,

    fn parse(text: []const u8) !SlotKind {
        if (std.mem.eql(u8, text, "document")) return .document;
        if (std.mem.eql(u8, text, "event-log")) return .event_log;
        return error.UnsupportedSlotKind;
    }
};

const PathSegmentKind = enum {
    literal,
    parameter,
};

const PathSegment = struct {
    kind: PathSegmentKind,
    text: []u8,

    fn deinit(self: *PathSegment, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Slot = struct {
    name: []u8,
    relative_path: []u8,
    path_segments: []PathSegment,
    kind: SlotKind,
    codec: definition.Codec,
    max_bytes: usize,

    fn deinit(self: *Slot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.relative_path);
        for (self.path_segments) |*segment| segment.deinit(allocator);
        allocator.free(self.path_segments);
        self.* = undefined;
    }
};

pub const ResolvedSlot = struct {
    name: []const u8,
    relative_path: []const u8,
    owned_path: ?[]u8,
    kind: SlotKind,
    codec: definition.Codec,
    max_bytes: usize,

    fn deinit(self: *ResolvedSlot, allocator: std.mem.Allocator) void {
        if (self.owned_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const EffectKind = enum {
    create_new,
    compare_append,
    compare_replace,
    bind_existing,

    fn fromOperator(operator: definition.Operator) !EffectKind {
        return switch (operator) {
            .create_new => .create_new,
            .compare_append => .compare_append,
            .compare_replace => .compare_replace,
            .bind_existing => .bind_existing,
            else => error.UnsupportedStorageEffect,
        };
    }
};

pub const EventFieldSource = union(enum) {
    input_field: []u8,
    literal: []u8,
    sequence_text_prefix: []u8,
    unix_seconds,
    derived: []u8,

    fn deinit(self: *EventFieldSource, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .input_field => |value| allocator.free(value),
            .literal => |value| allocator.free(value),
            .sequence_text_prefix => |value| allocator.free(value),
            .unix_seconds => {},
            .derived => |value| allocator.free(value),
        }
        self.* = undefined;
    }
};

pub const EventField = struct {
    field: []u8,
    source: EventFieldSource,

    fn deinit(self: *EventField, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

pub const EventMaterializationMode = enum {
    chained,
    plain,

    fn parse(text: []const u8) !EventMaterializationMode {
        if (std.mem.eql(u8, text, "chained")) return .chained;
        if (std.mem.eql(u8, text, "plain")) return .plain;
        return error.UnsupportedEventMaterializationMode;
    }
};

pub const RequestLiteral = struct {
    field: []u8,
    literal: []u8,

    fn deinit(self: *RequestLiteral, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        allocator.free(self.literal);
        self.* = undefined;
    }
};

pub const SecureTokenGeneration = struct {
    name: []u8,
    prefix: []u8,
    byte_count: u8,

    fn deinit(self: *SecureTokenGeneration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.prefix);
        self.* = undefined;
    }
};

pub const EventTimestampFormat = enum {
    rfc3339_seconds,

    fn parse(text: []const u8) !EventTimestampFormat {
        if (std.mem.eql(u8, text, "rfc3339-seconds")) {
            return .rfc3339_seconds;
        }
        return error.UnsupportedEventTimestampFormat;
    }
};

pub const EventDigestEncoding = enum {
    hex,
    digest,

    fn parse(text: []const u8) !EventDigestEncoding {
        if (std.mem.eql(u8, text, "hex")) return .hex;
        if (std.mem.eql(u8, text, "digest")) return .digest;
        return error.UnsupportedEventDigestEncoding;
    }
};

pub const EventInputTextTransform = enum {
    none,
    ascii_lower,

    fn parse(text: []const u8) !EventInputTextTransform {
        if (std.mem.eql(u8, text, "none")) return .none;
        if (std.mem.eql(u8, text, "ascii-lower")) return .ascii_lower;
        return error.UnsupportedEventInputTextTransform;
    }
};

pub const EventInputTextFragment = struct {
    pointer: definition_core.json_pointer.Pointer,
    transform: EventInputTextTransform,

    fn deinit(
        self: *EventInputTextFragment,
        allocator: std.mem.Allocator,
    ) void {
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

pub const EventDerivedTransform = enum {
    none,
    compact_utc,

    fn parse(text: []const u8) !EventDerivedTransform {
        if (std.mem.eql(u8, text, "none")) return .none;
        if (std.mem.eql(u8, text, "compact-utc")) return .compact_utc;
        return error.UnsupportedEventDerivedTransform;
    }
};

pub const EventDerivedReference = struct {
    name: []u8,
    prefix_bytes: ?u16,
    transform: EventDerivedTransform,

    fn deinit(
        self: *EventDerivedReference,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const EventDerivationFragment = union(enum) {
    literal: []u8,
    input_text: EventInputTextFragment,
    input_json: definition_core.json_pointer.Pointer,
    canonical_input: definition_core.json_pointer.Pointer,
    derived: EventDerivedReference,

    fn deinit(
        self: *EventDerivationFragment,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .literal => |value| allocator.free(value),
            .input_text => |*source| source.deinit(allocator),
            .input_json, .canonical_input => |*pointer| {
                pointer.deinit(allocator);
            },
            .derived => |*reference| reference.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const EventDigestDerivation = struct {
    encoding: EventDigestEncoding,
    fragments: []EventDerivationFragment,
    max_bytes: usize,
    prefix_bytes: ?u16,

    fn deinit(
        self: *EventDigestDerivation,
        allocator: std.mem.Allocator,
    ) void {
        deinitEventDerivationFragments(allocator, self.fragments);
        self.* = undefined;
    }
};

pub const EventConcatDerivation = struct {
    fragments: []EventDerivationFragment,
    max_bytes: usize,

    fn deinit(
        self: *EventConcatDerivation,
        allocator: std.mem.Allocator,
    ) void {
        deinitEventDerivationFragments(allocator, self.fragments);
        self.* = undefined;
    }
};

pub const EventMonotonicIdentityDerivation = struct {
    prefix: []u8,
    width: u8,

    fn deinit(
        self: *EventMonotonicIdentityDerivation,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.prefix);
        self.* = undefined;
    }
};

pub const EventDerivationSource = union(enum) {
    input_text: definition_core.json_pointer.Pointer,
    utc_timestamp: EventTimestampFormat,
    sha1: EventDigestDerivation,
    sha256: EventDigestDerivation,
    concat: EventConcatDerivation,
    monotonic_identity: EventMonotonicIdentityDerivation,

    fn deinit(
        self: *EventDerivationSource,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .input_text => |*pointer| pointer.deinit(allocator),
            .utc_timestamp => {},
            .sha1, .sha256 => |*config| config.deinit(allocator),
            .concat => |*config| config.deinit(allocator),
            .monotonic_identity => |*config| config.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const EventDerivation = struct {
    name: []u8,
    source: EventDerivationSource,

    fn deinit(self: *EventDerivation, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

pub const EventIdempotency = struct {
    derived: []u8,
    bypass_parameter: ?[]u8,

    fn deinit(self: *EventIdempotency, allocator: std.mem.Allocator) void {
        allocator.free(self.derived);
        if (self.bypass_parameter) |name| allocator.free(name);
        self.* = undefined;
    }
};

pub const EventObjectOrder = struct {
    pointer: definition_core.json_pointer.Pointer,
    fields: [][]u8,

    fn deinit(self: *EventObjectOrder, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        deinitNames(allocator, self.fields);
        self.* = undefined;
    }
};

pub const StateValueSource = struct {
    register: []u8,
    pointer: definition_core.json_pointer.Pointer,

    fn deinit(self: *StateValueSource, allocator: std.mem.Allocator) void {
        allocator.free(self.register);
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

pub const ParameterSha256Source = struct {
    parameter: []u8,
    expected_state: StateValueSource,

    fn deinit(self: *ParameterSha256Source, allocator: std.mem.Allocator) void {
        allocator.free(self.parameter);
        self.expected_state.deinit(allocator);
        self.* = undefined;
    }
};

pub const LiteralMappingSource = struct {
    request_literal: []u8,
    stored_literal: []u8,

    fn deinit(self: *LiteralMappingSource, allocator: std.mem.Allocator) void {
        allocator.free(self.request_literal);
        allocator.free(self.stored_literal);
        self.* = undefined;
    }
};

pub const EventBodyFieldSource = union(enum) {
    generated_sha256: []u8,
    parameter_sha256: ParameterSha256Source,
    state_value: StateValueSource,
    request_input: []u8,
    literal_mapping: LiteralMappingSource,
    derived: []u8,

    fn deinit(self: *EventBodyFieldSource, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .generated_sha256 => |name| allocator.free(name),
            .parameter_sha256 => |*source| source.deinit(allocator),
            .state_value => |*source| source.deinit(allocator),
            .request_input => |name| allocator.free(name),
            .literal_mapping => |*source| source.deinit(allocator),
            .derived => |name| allocator.free(name),
        }
        self.* = undefined;
    }
};

pub const EventBodyField = struct {
    field: []u8,
    source: EventBodyFieldSource,

    fn deinit(self: *EventBodyField, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

pub const EventMaterialization = struct {
    mode: EventMaterializationMode,
    body_input_field: []u8,
    field_order: [][]u8,
    body_order: [][]u8,
    object_orders: []EventObjectOrder,
    escape_non_ascii: bool,
    fields: []EventField,
    request_literals: []RequestLiteral,
    generate: []SecureTokenGeneration,
    derive: []EventDerivation,
    idempotency: ?EventIdempotency,
    body_fields: []EventBodyField,
    forbidden_parameters: [][]u8,

    fn deinit(self: *EventMaterialization, allocator: std.mem.Allocator) void {
        allocator.free(self.body_input_field);
        deinitNames(allocator, self.field_order);
        deinitNames(allocator, self.body_order);
        for (self.object_orders) |*order| order.deinit(allocator);
        allocator.free(self.object_orders);
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        for (self.request_literals) |*literal| literal.deinit(allocator);
        allocator.free(self.request_literals);
        for (self.generate) |*item| item.deinit(allocator);
        allocator.free(self.generate);
        for (self.derive) |*item| item.deinit(allocator);
        allocator.free(self.derive);
        if (self.idempotency) |*item| item.deinit(allocator);
        for (self.body_fields) |*field| field.deinit(allocator);
        allocator.free(self.body_fields);
        for (self.forbidden_parameters) |name| allocator.free(name);
        allocator.free(self.forbidden_parameters);
        self.* = undefined;
    }
};

pub const Effect = struct {
    kind: EffectKind,
    slot_index: u16,
    input_index: u8,
    expected_revision_parameter: ?[]u8,
    idempotency_parameter: ?[]u8,
    parameter_bindings: []ParameterBinding,
    event: ?EventMaterialization,
    document: ?document.Plan,

    fn deinit(self: *Effect, allocator: std.mem.Allocator) void {
        if (self.expected_revision_parameter) |name| allocator.free(name);
        if (self.idempotency_parameter) |name| allocator.free(name);
        for (self.parameter_bindings) |*binding| {
            binding.deinit(allocator);
        }
        allocator.free(self.parameter_bindings);
        if (self.event) |*event| event.deinit(allocator);
        if (self.document) |*plan| plan.deinit(allocator);
        self.* = undefined;
    }
};

pub const ParameterBinding = struct {
    parameter: []u8,
    input_pointer: definition_core.json_pointer.Pointer,

    fn deinit(
        self: *ParameterBinding,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.parameter);
        self.input_pointer.deinit(allocator);
        self.* = undefined;
    }
};

pub const Operation = struct {
    name: []u8,
    atomic: bool,
    effects: []Effect,

    fn deinit(self: *Operation, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.effects) |*effect| effect.deinit(allocator);
        allocator.free(self.effects);
        self.* = undefined;
    }
};

pub const Plan = struct {
    storage_kind: definition.StorageKind,
    slots: []Slot,
    operations: []Operation,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.slots) |*slot| slot.deinit(allocator);
        allocator.free(self.slots);
        for (self.operations) |*operation| operation.deinit(allocator);
        allocator.free(self.operations);
        self.* = undefined;
    }

    pub fn findSlot(self: *const Plan, name: []const u8) ?usize {
        var low: usize = 0;
        var high = self.slots.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.slots[mid].name, name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    pub fn findOperation(self: *const Plan, name: []const u8) ?*const Operation {
        var low: usize = 0;
        var high = self.operations.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.operations[mid].name, name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return &self.operations[mid],
            }
        }
        return null;
    }
};

pub const ResolvedPlan = struct {
    storage_kind: definition.StorageKind,
    slot_buffer: [64]ResolvedSlot,
    slot_count: usize,
    operations: []const Operation,

    pub fn deinit(self: *ResolvedPlan, allocator: std.mem.Allocator) void {
        for (self.slot_buffer[0..self.slot_count]) |*item| {
            item.deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn slot(self: *const ResolvedPlan, index: usize) ResolvedSlot {
        return self.slot_buffer[index];
    }

    pub fn slotSlice(self: *const ResolvedPlan) []const ResolvedSlot {
        return self.slot_buffer[0..self.slot_count];
    }

    pub fn findOperation(
        self: *const ResolvedPlan,
        name: []const u8,
    ) ?*const Operation {
        var low: usize = 0;
        var high = self.operations.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.operations[mid].name, name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return &self.operations[mid],
            }
        }
        return null;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !Plan {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        definition_plan.storage_json,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    const storage_object = try definition_core.json.object(parsed.value);
    const slots = try compileSlots(
        allocator,
        definition_plan,
        storage_object,
    );
    errdefer deinitSlots(allocator, slots);
    const operations = try compileOperations(allocator, definition_plan, slots);
    return .{
        .storage_kind = definition_plan.storage_kind,
        .slots = slots,
        .operations = operations,
    };
}

pub fn resolve(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    parameters: *const definition_core.parameters.Bindings,
) !ResolvedPlan {
    return resolveWithGenerated(allocator, plan, parameters, &.{});
}

pub fn resolveWithGenerated(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    parameters: *const definition_core.parameters.Bindings,
    generated: []const document.Value,
) !ResolvedPlan {
    var resolved: ResolvedPlan = .{
        .storage_kind = plan.storage_kind,
        .slot_buffer = undefined,
        .slot_count = 0,
        .operations = plan.operations,
    };
    errdefer resolved.deinit(allocator);
    for (plan.slots, 0..) |slot, index| {
        const owned_path = if (pathIsParameterized(slot.path_segments))
            try resolvePathAlloc(
                allocator,
                slot.path_segments,
                parameters,
                generated,
            )
        else
            null;
        errdefer if (owned_path) |path| allocator.free(path);
        resolved.slot_buffer[index] = .{
            .name = slot.name,
            .relative_path = owned_path orelse slot.relative_path,
            .owned_path = owned_path,
            .kind = slot.kind,
            .codec = slot.codec,
            .max_bytes = slot.max_bytes,
        };
        resolved.slot_count += 1;
    }
    const slots = resolved.slotSlice();
    for (slots, 0..) |left, index| {
        for (slots[index + 1 ..]) |right| {
            if (std.ascii.eqlIgnoreCase(
                left.relative_path,
                right.relative_path,
            )) return error.StoragePathCaseAmbiguity;
        }
    }
    return resolved;
}

pub fn pathTemplateMatches(slot: Slot, actual_path: []const u8) bool {
    validateLogicalSlotPath(actual_path) catch return false;
    var components = std.mem.splitScalar(u8, actual_path, '/');
    for (slot.path_segments) |segment| {
        const component = components.next() orelse return false;
        switch (segment.kind) {
            .literal => if (!std.mem.eql(u8, segment.text, component)) {
                return false;
            },
            .parameter => {
                definition_core.json.safeIdentifier(component, 128) catch
                    return false;
                if (std.mem.indexOfScalar(u8, component, '/') != null) {
                    return false;
                }
            },
        }
    }
    return components.next() == null;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(13);
    try encoder.writeEnum(plan.storage_kind);
    try encodeCacheSlots(plan.slots, encoder);
    try encodeCacheOperations(plan.operations, encoder);
}

fn encodeCacheSlots(
    slots: []const Slot,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(slots.len);
    for (slots) |slot| {
        try encoder.writeBytes(slot.name);
        try encoder.writeBytes(slot.relative_path);
        try encoder.writeCount(slot.path_segments.len);
        for (slot.path_segments) |segment| {
            try encoder.writeEnum(segment.kind);
            try encoder.writeBytes(segment.text);
        }
        try encoder.writeEnum(slot.kind);
        try encoder.writeEnum(slot.codec);
        try encoder.writeUsize(slot.max_bytes);
    }
}

fn encodeCacheOperations(
    operations: []const Operation,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(operations.len);
    for (operations) |operation| {
        try encoder.writeBytes(operation.name);
        try encoder.writeBool(operation.atomic);
        try encoder.writeCount(operation.effects.len);
        for (operation.effects) |effect| {
            try encodeCacheEffect(effect, encoder);
        }
    }
}

fn encodeCacheEffect(
    effect: Effect,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeEnum(effect.kind);
    try encoder.writeU16(effect.slot_index);
    try encoder.writeByte(effect.input_index);
    try encoder.writeOptionalBytes(effect.expected_revision_parameter);
    try encoder.writeOptionalBytes(effect.idempotency_parameter);
    try encoder.writeCount(effect.parameter_bindings.len);
    for (effect.parameter_bindings) |binding| {
        try encoder.writeBytes(binding.parameter);
        try encoder.writeBytes(binding.input_pointer.raw);
    }
    try encoder.writeBool(effect.event != null);
    if (effect.event) |event| {
        try encodeEventMaterialization(event, encoder);
    }
    try encoder.writeBool(effect.document != null);
    if (effect.document) |document_plan| {
        try document.encodeCache(&document_plan, encoder);
    }
}

fn encodeEventMaterialization(
    event: EventMaterialization,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeEnum(event.mode);
    try encoder.writeBytes(event.body_input_field);
    try encodeNames(event.field_order, encoder);
    try encodeNames(event.body_order, encoder);
    try encoder.writeCount(event.object_orders.len);
    for (event.object_orders) |order| {
        try encoder.writeBytes(order.pointer.raw);
        try encodeNames(order.fields, encoder);
    }
    try encoder.writeBool(event.escape_non_ascii);
    try encodeEventFields(event.fields, encoder);
    try encoder.writeCount(event.request_literals.len);
    for (event.request_literals) |literal| {
        try encoder.writeBytes(literal.field);
        try encoder.writeBytes(literal.literal);
    }
    try encoder.writeCount(event.generate.len);
    for (event.generate) |item| {
        try encoder.writeBytes(item.name);
        try encoder.writeBytes(item.prefix);
        try encoder.writeByte(item.byte_count);
    }
    try encodeEventDerivations(event.derive, encoder);
    try encoder.writeBool(event.idempotency != null);
    if (event.idempotency) |idempotency| {
        try encoder.writeBytes(idempotency.derived);
        try encoder.writeOptionalBytes(idempotency.bypass_parameter);
    }
    try encodeEventBodyFields(event.body_fields, encoder);
    try encodeNames(event.forbidden_parameters, encoder);
}

fn encodeEventFields(
    fields: []const EventField,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(fields.len);
    for (fields) |field| {
        try encoder.writeBytes(field.field);
        try encoder.writeEnum(std.meta.activeTag(field.source));
        switch (field.source) {
            .input_field => |value| try encoder.writeBytes(value),
            .literal => |value| try encoder.writeBytes(value),
            .sequence_text_prefix => |value| try encoder.writeBytes(value),
            .unix_seconds => {},
            .derived => |value| try encoder.writeBytes(value),
        }
    }
}

fn encodeEventBodyFields(
    fields: []const EventBodyField,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(fields.len);
    for (fields) |field| {
        try encoder.writeBytes(field.field);
        try encoder.writeEnum(std.meta.activeTag(field.source));
        switch (field.source) {
            .generated_sha256 => |name| try encoder.writeBytes(name),
            .parameter_sha256 => |source| {
                try encoder.writeBytes(source.parameter);
                try encodeStateValueSource(source.expected_state, encoder);
            },
            .state_value => |source| {
                try encodeStateValueSource(source, encoder);
            },
            .request_input => |name| try encoder.writeBytes(name),
            .literal_mapping => |source| {
                try encoder.writeBytes(source.request_literal);
                try encoder.writeBytes(source.stored_literal);
            },
            .derived => |name| try encoder.writeBytes(name),
        }
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 13) {
        return error.LedgerStorageCacheVersionMismatch;
    }
    const storage_kind = try decoder.readEnum(definition.StorageKind);
    const slots = try decodeCacheSlots(allocator, decoder);
    errdefer deinitSlots(allocator, slots);
    const operations = try decodeCacheOperations(
        allocator,
        decoder,
        slots,
    );
    errdefer {
        for (operations) |*operation| operation.deinit(allocator);
        allocator.free(operations);
    }
    if (storage_kind == .pure) {
        if (slots.len != 0 or operations.len != 0) {
            return error.CachePureStorageHasEffects;
        }
    } else if (slots.len == 0) {
        return error.InvalidStorageSlotCount;
    }
    return .{
        .storage_kind = storage_kind,
        .slots = slots,
        .operations = operations,
    };
}

fn encodeStateValueSource(
    source: StateValueSource,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeBytes(source.register);
    try encoder.writeBytes(source.pointer.raw);
}

fn encodeNames(
    names: []const []u8,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(names.len);
    for (names) |name| try encoder.writeBytes(name);
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    if (plan.storage_kind != definition_plan.storage_kind) {
        return error.CacheStoragePlanMismatch;
    }
    try validateCacheSlots(plan.slots, definition_plan);
    for (plan.operations) |operation| {
        for (operation.effects) |effect| {
            try validateCacheEffect(
                plan.slots,
                effect,
                definition_plan,
            );
        }
    }
}

fn validateCacheSlots(
    slots: []const Slot,
    definition_plan: *const definition.Plan,
) !void {
    for (slots) |slot| {
        if (slot.max_bytes > definition_plan.bounds.max_store_bytes) {
            return error.CacheStoragePlanMismatch;
        }
        for (slot.path_segments) |segment| switch (segment.kind) {
            .literal => {},
            .parameter => {
                if (!definition_plan.requires(.path_format)) {
                    return error.CacheStoragePlanMismatch;
                }
                const declaration =
                    definition_plan.parameter_declarations.find(
                        segment.text,
                    ) orelse return error.CacheStoragePlanMismatch;
                if (declaration.kind != .safe_identifier) {
                    return error.CacheStoragePlanMismatch;
                }
            },
        };
    }
}

fn validateCacheEffect(
    slots: []const Slot,
    effect: Effect,
    definition_plan: *const definition.Plan,
) !void {
    if (effect.input_index >= definition_plan.inputs.len) {
        return error.CacheStoragePlanMismatch;
    }
    const slot = slots[effect.slot_index];
    const input = definition_plan.inputs[effect.input_index];
    const required_operator: definition.Operator = switch (effect.kind) {
        .create_new => .create_new,
        .compare_append => .compare_append,
        .compare_replace => .compare_replace,
        .bind_existing => .bind_existing,
    };
    if (!definition_plan.requires(required_operator)) {
        return error.CacheStoragePlanMismatch;
    }
    try validateCacheEffectCodec(effect, slot, input);
    if (effect.parameter_bindings.len != 0 and
        (slot.kind != .document or input.codec != .json))
    {
        return error.CacheStoragePlanMismatch;
    }
    try validateCacheEffectParameters(effect, definition_plan);
    if (effect.event) |*event| {
        try validateCacheEvent(effect, event, definition_plan);
    }
    if (effect.document) |*document_plan| {
        try validateCacheDocument(
            effect,
            slot,
            document_plan,
            definition_plan,
        );
    }
}

fn validateCacheEffectCodec(
    effect: Effect,
    slot: Slot,
    input: definition.Input,
) !void {
    const event_log_append = effect.kind == .compare_append or
        (effect.kind == .bind_existing and slot.kind == .event_log);
    if (event_log_append and input.codec != .json) {
        return error.CacheStoragePlanMismatch;
    }
    if (!event_log_append and
        effect.document == null and
        input.codec != slot.codec)
    {
        return error.CacheStoragePlanMismatch;
    }
}

fn validateCacheEffectParameters(
    effect: Effect,
    definition_plan: *const definition.Plan,
) !void {
    if (effect.expected_revision_parameter) |name| {
        const declaration =
            definition_plan.parameter_declarations.find(name) orelse
            return error.CacheStoragePlanMismatch;
        if (declaration.kind != .digest) {
            return error.CacheStoragePlanMismatch;
        }
    }
    if (effect.idempotency_parameter) |name| {
        const declaration =
            definition_plan.parameter_declarations.find(name) orelse
            return error.CacheStoragePlanMismatch;
        if (!definition_plan.requires(.idempotency_key) or
            declaration.kind != .safe_identifier)
        {
            return error.CacheStoragePlanMismatch;
        }
    }
    if (effect.parameter_bindings.len != 0 and
        !definition_plan.requires(.path_format))
    {
        return error.CacheStoragePlanMismatch;
    }
    try validateParameterBindings(effect.parameter_bindings);
    for (effect.parameter_bindings) |binding| {
        const declaration =
            definition_plan.parameter_declarations.find(
                binding.parameter,
            ) orelse return error.CacheStoragePlanMismatch;
        switch (declaration.kind) {
            .string,
            .digest,
            .timestamp,
            .safe_identifier,
            .relative_path,
            => {},
            .integer, .boolean => return error.CacheStoragePlanMismatch,
        }
    }
}

fn validateCacheEvent(
    effect: Effect,
    event: *const EventMaterialization,
    definition_plan: *const definition.Plan,
) !void {
    if (effect.kind != .compare_append and
        effect.kind != .bind_existing)
    {
        return error.CacheStoragePlanMismatch;
    }
    try validateCachedEventMaterialization(event);
    validateEventMaterializationAgainstDefinition(
        event,
        definition_plan,
    ) catch return error.CacheStoragePlanMismatch;
    if (effect.idempotency_parameter != null and
        event.idempotency != null)
    {
        return error.CacheStoragePlanMismatch;
    }
}

fn validateCacheDocument(
    effect: Effect,
    slot: Slot,
    document_plan: *const document.Plan,
    definition_plan: *const definition.Plan,
) !void {
    if (slot.kind != .document or slot.codec != .text or
        (effect.kind != .create_new and
            effect.kind != .compare_replace) or
        effect.event != null)
    {
        return error.CacheStoragePlanMismatch;
    }
    switch (document_plan.mode) {
        .template => if (effect.kind != .create_new) {
            return error.CacheStoragePlanMismatch;
        },
        .edit => if (effect.kind != .compare_replace) {
            return error.CacheStoragePlanMismatch;
        },
    }
    try document.validateCachePlan(document_plan, definition_plan);
    if (document_plan.identity) |identity| {
        if (!slotPathUsesParameter(
            slot,
            document.pathOutputName(identity),
        )) {
            return error.CacheStoragePlanMismatch;
        }
    }
}

fn decodeCacheSlots(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]Slot {
    const count = try decoder.readCount(64);
    const slots = try allocator.alloc(Slot, count);
    var initialized: usize = 0;
    errdefer {
        for (slots[0..initialized]) |*slot| slot.deinit(allocator);
        allocator.free(slots);
    }
    for (slots, 0..) |*slot, index| {
        var decoded = try decodeCacheSlot(
            allocator,
            decoder,
            slots[0..index],
        );
        errdefer decoded.deinit(allocator);
        if (index != 0 and
            std.mem.order(
                u8,
                slots[index - 1].name,
                decoded.name,
            ) != .lt)
        {
            return error.CacheStorageSlotsNotSorted;
        }
        slot.* = decoded;
        initialized += 1;
    }
    return slots;
}

fn decodeCacheSlot(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    prior_slots: []const Slot,
) !Slot {
    const name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    const relative_path = try decoder.readBytesAlloc(allocator, 4096);
    errdefer allocator.free(relative_path);
    const path_segments = try decodeCachePathSegments(allocator, decoder);
    errdefer {
        for (path_segments) |*segment| segment.deinit(allocator);
        allocator.free(path_segments);
    }
    try validateEncodedPathTemplate(
        allocator,
        relative_path,
        path_segments,
    );
    const kind = try decoder.readEnum(SlotKind);
    const codec = try decoder.readEnum(definition.Codec);
    try validateDecodedSlotCodec(kind, codec);
    const max_bytes = try decoder.readUsize();
    if (max_bytes == 0 or max_bytes > 4 * 1024 * 1024 * 1024) {
        return error.StorageSlotBoundsExceeded;
    }
    for (prior_slots) |prior| {
        if (std.ascii.eqlIgnoreCase(
            prior.relative_path,
            relative_path,
        )) return error.StoragePathCaseAmbiguity;
    }
    return .{
        .name = name,
        .relative_path = relative_path,
        .path_segments = path_segments,
        .kind = kind,
        .codec = codec,
        .max_bytes = max_bytes,
    };
}

fn decodeCachePathSegments(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]PathSegment {
    const count = try decoder.readCount(128);
    if (count == 0) return error.InvalidStoragePathTemplate;
    const segments = try allocator.alloc(PathSegment, count);
    var initialized: usize = 0;
    errdefer {
        for (segments[0..initialized]) |*segment| {
            segment.deinit(allocator);
        }
        allocator.free(segments);
    }
    for (segments) |*segment| {
        const kind = try decoder.readEnum(PathSegmentKind);
        const text = try decoder.readBytesAlloc(
            allocator,
            if (kind == .parameter) 128 else 4096,
        );
        errdefer allocator.free(text);
        try validatePathSegment(kind, text);
        segment.* = .{ .kind = kind, .text = text };
        initialized += 1;
    }
    return segments;
}

fn validateDecodedSlotCodec(
    kind: SlotKind,
    codec: definition.Codec,
) !void {
    if (kind == .event_log and codec != .jsonl) {
        return error.EventLogSlotRequiresJsonl;
    }
    if (kind == .document and codec == .jsonl) {
        return error.JsonlSlotRequiresEventLog;
    }
}

fn decodeCacheOperations(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    slots: []const Slot,
) ![]Operation {
    const count = try decoder.readCount(128);
    const operations = try allocator.alloc(Operation, count);
    var initialized: usize = 0;
    errdefer {
        for (operations[0..initialized]) |*operation| {
            operation.deinit(allocator);
        }
        allocator.free(operations);
    }
    for (operations, 0..) |*operation, index| {
        var decoded = try decodeCacheOperation(
            allocator,
            decoder,
            slots,
        );
        errdefer decoded.deinit(allocator);
        if (index != 0 and
            std.mem.order(
                u8,
                operations[index - 1].name,
                decoded.name,
            ) != .lt)
        {
            return error.CacheStorageOperationsNotSorted;
        }
        operation.* = decoded;
        initialized += 1;
    }
    return operations;
}

fn decodeCacheOperation(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    slots: []const Slot,
) !Operation {
    const name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    const atomic = try decoder.readBool();
    const effects = try decodeCacheEffects(allocator, decoder, slots);
    errdefer {
        for (effects) |*effect| effect.deinit(allocator);
        allocator.free(effects);
    }
    try validateCachedOperation(effects, atomic);
    return .{
        .name = name,
        .atomic = atomic,
        .effects = effects,
    };
}

fn decodeCacheEffects(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    slots: []const Slot,
) ![]Effect {
    const count = try decoder.readCount(64);
    if (count == 0) return error.InvalidOperationEffectCount;
    const effects = try allocator.alloc(Effect, count);
    var initialized: usize = 0;
    errdefer {
        for (effects[0..initialized]) |*effect| effect.deinit(allocator);
        allocator.free(effects);
    }
    for (effects) |*effect| {
        effect.* = try decodeCacheEffect(allocator, decoder, slots);
        initialized += 1;
    }
    return effects;
}

fn decodeCacheEffect(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    slots: []const Slot,
) !Effect {
    const kind = try decoder.readEnum(EffectKind);
    const slot_index = try decoder.readU16();
    if (slot_index >= slots.len) return error.CacheStorageIndexInvalid;
    const input_index = try decoder.readByte();
    const expected_revision_parameter =
        try decoder.readOptionalBytesAlloc(allocator, 128);
    errdefer if (expected_revision_parameter) |value| allocator.free(value);
    if (expected_revision_parameter) |value| {
        try definition_core.json.safeIdentifier(value, 128);
    }
    const idempotency_parameter =
        try decoder.readOptionalBytesAlloc(allocator, 128);
    errdefer if (idempotency_parameter) |value| allocator.free(value);
    if (idempotency_parameter) |value| {
        try definition_core.json.safeIdentifier(value, 128);
    }
    const parameter_bindings = try decodeParameterBindings(
        allocator,
        decoder,
    );
    errdefer deinitParameterBindings(allocator, parameter_bindings);
    var event = if (try decoder.readBool())
        try decodeEventMaterialization(allocator, decoder)
    else
        null;
    errdefer if (event) |*value| value.deinit(allocator);
    var document_plan = if (try decoder.readBool())
        try document.decodeCache(allocator, decoder)
    else
        null;
    errdefer if (document_plan) |*value| value.deinit(allocator);
    try validateDecodedEffect(
        kind,
        slots[slot_index],
        expected_revision_parameter,
        idempotency_parameter,
        parameter_bindings,
        event,
        document_plan,
    );
    const result: Effect = .{
        .kind = kind,
        .slot_index = slot_index,
        .input_index = input_index,
        .expected_revision_parameter = expected_revision_parameter,
        .idempotency_parameter = idempotency_parameter,
        .parameter_bindings = parameter_bindings,
        .event = event,
        .document = document_plan,
    };
    event = null;
    document_plan = null;
    return result;
}

fn validateDecodedEffect(
    kind: EffectKind,
    slot: Slot,
    expected_revision_parameter: ?[]const u8,
    idempotency_parameter: ?[]const u8,
    parameter_bindings: []const ParameterBinding,
    event: ?EventMaterialization,
    document_plan: ?document.Plan,
) !void {
    if (kind == .bind_existing and
        (expected_revision_parameter != null or
            idempotency_parameter != null))
    {
        return error.BindingEffectHasAdmissionParameter;
    }
    if (event != null and kind != .compare_append and
        kind != .bind_existing)
    {
        return error.EventMaterializationRequiresAppend;
    }
    if (idempotency_parameter != null and
        event != null and event.?.idempotency != null)
    {
        return error.DuplicateIdempotencySource;
    }
    if (document_plan != null and event != null) {
        return error.DuplicateEffectMaterialization;
    }
    try validateParameterBindings(parameter_bindings);
    if (parameter_bindings.len != 0 and slot.kind != .document) {
        return error.EffectParameterBindingsRequireJsonDocument;
    }
    if (document_plan) |value| {
        if (slot.kind != .document or slot.codec != .text) {
            return error.DocumentMaterializationRequiresTextSlot;
        }
        switch (value.mode) {
            .template => if (kind != .create_new) {
                return error.TemplateMaterializationRequiresCreate;
            },
            .edit => if (kind != .compare_replace) {
                return error.EditMaterializationRequiresReplace;
            },
        }
    }
}

fn decodeParameterBindings(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]ParameterBinding {
    const count = try decoder.readCount(64);
    const bindings = try allocator.alloc(ParameterBinding, count);
    var initialized: usize = 0;
    errdefer {
        for (bindings[0..initialized]) |*binding| {
            binding.deinit(allocator);
        }
        allocator.free(bindings);
    }
    for (bindings) |*binding| {
        const parameter = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(parameter);
        try definition_core.json.safeIdentifier(parameter, 128);
        const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw_pointer);
        binding.* = .{
            .parameter = parameter,
            .input_pointer = try definition_core.json_pointer.compile(
                allocator,
                raw_pointer,
            ),
        };
        initialized += 1;
    }
    try validateParameterBindings(bindings);
    return bindings;
}

fn deinitParameterBindings(
    allocator: std.mem.Allocator,
    bindings: []ParameterBinding,
) void {
    for (bindings) |*binding| binding.deinit(allocator);
    allocator.free(bindings);
}

fn validateParameterBindings(
    bindings: []const ParameterBinding,
) !void {
    for (bindings, 0..) |binding, index| {
        try definition_core.json.safeIdentifier(binding.parameter, 128);
        if (binding.input_pointer.raw.len > 1024) {
            return error.InvalidEffectParameterBinding;
        }
        if (index != 0 and
            std.mem.order(
                u8,
                bindings[index - 1].parameter,
                binding.parameter,
            ) != .lt)
        {
            return error.EffectParameterBindingsNotSorted;
        }
    }
}

fn decodeEventMaterialization(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EventMaterialization {
    const mode = try decoder.readEnum(EventMaterializationMode);
    const body_input_field = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(body_input_field);
    try definition_core.json.safeIdentifier(body_input_field, 128);
    const field_order = try decodeDeclaredOrder(
        allocator,
        decoder,
        65,
    );
    errdefer deinitNames(allocator, field_order);
    const body_order = try decodeDeclaredOrder(
        allocator,
        decoder,
        64,
    );
    errdefer deinitNames(allocator, body_order);
    const object_orders = try decodeEventObjectOrders(allocator, decoder);
    errdefer deinitEventObjectOrders(allocator, object_orders);
    const escape_non_ascii = try decoder.readBool();
    const fields = try decodeEventFields(allocator, decoder);
    errdefer {
        for (fields) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    var extensions = try decodeEventExtensions(allocator, decoder);
    errdefer extensions.deinit(allocator);
    const result: EventMaterialization = .{
        .mode = mode,
        .body_input_field = body_input_field,
        .field_order = field_order,
        .body_order = body_order,
        .object_orders = object_orders,
        .escape_non_ascii = escape_non_ascii,
        .fields = fields,
        .request_literals = extensions.request_literals,
        .generate = extensions.generate,
        .derive = extensions.derive,
        .idempotency = extensions.idempotency,
        .body_fields = extensions.body_fields,
        .forbidden_parameters = extensions.forbidden_parameters,
    };
    try validateEventMaterialization(allocator, &result);
    return result;
}

fn decodeEventFields(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]EventField {
    const count = try decoder.readCount(64);
    if (count == 0) return error.InvalidEventMaterializationFields;
    const fields = try allocator.alloc(EventField, count);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (fields, 0..) |*field, index| {
        var decoded = try decodeEventField(allocator, decoder);
        errdefer decoded.deinit(allocator);
        if (index != 0 and
            std.mem.order(
                u8,
                fields[index - 1].field,
                decoded.field,
            ) != .lt)
        {
            return error.EventMaterializationFieldsNotSorted;
        }
        field.* = decoded;
        initialized += 1;
    }
    return fields;
}

fn decodeEventField(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EventField {
    const name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    const source_tag = try decoder.readEnum(
        std.meta.Tag(EventFieldSource),
    );
    var source: ?EventFieldSource = try decodeEventFieldSource(
        allocator,
        decoder,
        source_tag,
    );
    errdefer if (source) |*value| value.deinit(allocator);
    try validateDecodedEventFieldSource(allocator, source.?);
    const result: EventField = .{ .field = name, .source = source.? };
    source = null;
    return result;
}

fn decodeEventFieldSource(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    tag: std.meta.Tag(EventFieldSource),
) !EventFieldSource {
    if (tag == .unix_seconds) return .unix_seconds;
    const max_bytes: usize = if (tag == .literal) 4096 else 128;
    const value = try decoder.readBytesAlloc(allocator, max_bytes);
    return switch (tag) {
        .input_field => .{ .input_field = value },
        .literal => .{ .literal = value },
        .sequence_text_prefix => .{ .sequence_text_prefix = value },
        .derived => .{ .derived = value },
        .unix_seconds => unreachable,
    };
}

fn validateDecodedEventFieldSource(
    allocator: std.mem.Allocator,
    source: EventFieldSource,
) !void {
    switch (source) {
        .input_field, .derived => |value| {
            try definition_core.json.safeIdentifier(value, 128);
        },
        .literal => |value| try validateCanonicalScalar(allocator, value),
        .sequence_text_prefix => |value| {
            if (!std.unicode.utf8ValidateSlice(value) or value.len > 128) {
                return error.InvalidEventSequencePrefix;
            }
        },
        .unix_seconds => {},
    }
}

const EventExtensions = struct {
    request_literals: []RequestLiteral,
    generate: []SecureTokenGeneration,
    derive: []EventDerivation,
    idempotency: ?EventIdempotency,
    body_fields: []EventBodyField,
    forbidden_parameters: [][]u8,

    fn deinit(
        self: *EventExtensions,
        allocator: std.mem.Allocator,
    ) void {
        deinitRequestLiterals(allocator, self.request_literals);
        deinitSecureTokenGenerations(allocator, self.generate);
        deinitEventDerivations(allocator, self.derive);
        if (self.idempotency) |*item| item.deinit(allocator);
        deinitEventBodyFields(allocator, self.body_fields);
        deinitNames(allocator, self.forbidden_parameters);
        self.* = undefined;
    }
};

fn decodeEventExtensions(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EventExtensions {
    const request_literals = try decodeRequestLiterals(allocator, decoder);
    errdefer deinitRequestLiterals(allocator, request_literals);
    const generate = try decodeSecureTokenGenerations(allocator, decoder);
    errdefer deinitSecureTokenGenerations(allocator, generate);
    const derive = try decodeEventDerivations(allocator, decoder, generate);
    errdefer deinitEventDerivations(allocator, derive);
    var idempotency = try decodeEventIdempotency(allocator, decoder);
    errdefer if (idempotency) |*item| item.deinit(allocator);
    const body_fields = try decodeEventBodyFields(allocator, decoder);
    errdefer deinitEventBodyFields(allocator, body_fields);
    const forbidden_parameters = try decodeSortedNames(
        allocator,
        decoder,
        64,
    );
    errdefer deinitNames(allocator, forbidden_parameters);
    return .{
        .request_literals = request_literals,
        .generate = generate,
        .derive = derive,
        .idempotency = idempotency,
        .body_fields = body_fields,
        .forbidden_parameters = forbidden_parameters,
    };
}

fn decodeEventIdempotency(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?EventIdempotency {
    if (!try decoder.readBool()) return null;
    var result: EventIdempotency = .{
        .derived = try decoder.readBytesAlloc(allocator, 128),
        .bypass_parameter = null,
    };
    errdefer result.deinit(allocator);
    try definition_core.json.safeIdentifier(result.derived, 128);
    result.bypass_parameter = try decoder.readOptionalBytesAlloc(
        allocator,
        128,
    );
    if (result.bypass_parameter) |name| {
        try definition_core.json.safeIdentifier(name, 128);
    }
    return result;
}

fn decodeSecureTokenGenerations(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]SecureTokenGeneration {
    const count = try decoder.readCount(16);
    const items = try allocator.alloc(SecureTokenGeneration, count);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (items, 0..) |*item, index| {
        var name: ?[]u8 = try decoder.readBytesAlloc(allocator, 128);
        errdefer if (name) |value| allocator.free(value);
        var prefix: ?[]u8 = try decoder.readBytesAlloc(allocator, 64);
        errdefer if (prefix) |value| allocator.free(value);
        const byte_count = try decoder.readByte();
        const candidate: SecureTokenGeneration = .{
            .name = name.?,
            .prefix = prefix.?,
            .byte_count = byte_count,
        };
        try validateSecureTokenGeneration(&candidate);
        if (index != 0 and
            std.mem.order(
                u8,
                items[index - 1].name,
                candidate.name,
            ) != .lt)
        {
            return error.EventGenerationsNotSorted;
        }
        item.* = candidate;
        name = null;
        prefix = null;
        initialized += 1;
    }
    return items;
}

fn encodeEventDerivations(
    items: []const EventDerivation,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(items.len);
    for (items) |item| {
        try encoder.writeBytes(item.name);
        try encoder.writeEnum(std.meta.activeTag(item.source));
        switch (item.source) {
            .input_text => |pointer| try encoder.writeBytes(pointer.raw),
            .utc_timestamp => |format| try encoder.writeEnum(format),
            .sha1, .sha256 => |config| {
                try encoder.writeEnum(config.encoding);
                try encoder.writeUsize(config.max_bytes);
                try encoder.writeBool(config.prefix_bytes != null);
                if (config.prefix_bytes) |count| {
                    try encoder.writeU16(count);
                }
                try encodeEventDerivationFragments(
                    config.fragments,
                    encoder,
                );
            },
            .concat => |config| {
                try encoder.writeUsize(config.max_bytes);
                try encodeEventDerivationFragments(
                    config.fragments,
                    encoder,
                );
            },
            .monotonic_identity => |config| {
                try encoder.writeBytes(config.prefix);
                try encoder.writeByte(config.width);
            },
        }
    }
}

fn encodeEventDerivationFragments(
    fragments: []const EventDerivationFragment,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(fragments.len);
    for (fragments) |fragment| {
        try encoder.writeEnum(std.meta.activeTag(fragment));
        switch (fragment) {
            .literal => |value| try encoder.writeBytes(value),
            .input_text => |source| {
                try encoder.writeBytes(source.pointer.raw);
                try encoder.writeEnum(source.transform);
            },
            .input_json, .canonical_input => |pointer| {
                try encoder.writeBytes(pointer.raw);
            },
            .derived => |reference| {
                try encoder.writeBytes(reference.name);
                try encoder.writeBool(reference.prefix_bytes != null);
                if (reference.prefix_bytes) |count| {
                    try encoder.writeU16(count);
                }
                try encoder.writeEnum(reference.transform);
            },
        }
    }
}

fn decodeEventDerivations(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    generate: []const SecureTokenGeneration,
) ![]EventDerivation {
    const count = try decoder.readCount(16);
    const items = try allocator.alloc(EventDerivation, count);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (items, 0..) |*item, index| {
        var candidate = try decodeEventDerivation(allocator, decoder);
        errdefer candidate.deinit(allocator);
        try validateDecodedEventDerivation(
            &candidate,
            generate,
            items[0..index],
        );
        item.* = candidate;
        initialized += 1;
    }
    return items;
}

fn decodeEventDerivation(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EventDerivation {
    const name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    var source = try decodeEventDerivationSource(allocator, decoder);
    errdefer source.deinit(allocator);
    const result: EventDerivation = .{ .name = name, .source = source };
    try validateEventDerivation(&result);
    return result;
}

fn decodeEventDerivationSource(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EventDerivationSource {
    return switch (try decoder.readEnum(
        std.meta.Tag(EventDerivationSource),
    )) {
        .input_text => .{ .input_text = try decodeEventPointer(
            allocator,
            decoder,
        ) },
        .utc_timestamp => .{ .utc_timestamp = try decoder.readEnum(
            EventTimestampFormat,
        ) },
        .sha1 => .{ .sha1 = try decodeEventDigestDerivation(
            allocator,
            decoder,
        ) },
        .sha256 => .{ .sha256 = try decodeEventDigestDerivation(
            allocator,
            decoder,
        ) },
        .concat => .{ .concat = .{
            .max_bytes = try decoder.readUsize(),
            .fragments = try decodeEventDerivationFragments(
                allocator,
                decoder,
            ),
        } },
        .monotonic_identity => .{ .monotonic_identity = .{
            .prefix = try decoder.readBytesAlloc(allocator, 64),
            .width = try decoder.readByte(),
        } },
    };
}

fn decodeEventDigestDerivation(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EventDigestDerivation {
    return .{
        .encoding = try decoder.readEnum(EventDigestEncoding),
        .max_bytes = try decoder.readUsize(),
        .prefix_bytes = if (try decoder.readBool())
            try decoder.readU16()
        else
            null,
        .fragments = try decodeEventDerivationFragments(
            allocator,
            decoder,
        ),
    };
}

fn validateDecodedEventDerivation(
    candidate: *const EventDerivation,
    generate: []const SecureTokenGeneration,
    prior: []const EventDerivation,
) !void {
    for (generate) |generated| {
        if (std.mem.eql(u8, generated.name, candidate.name)) {
            return error.DuplicateEventGeneration;
        }
    }
    for (prior) |item| {
        if (std.mem.eql(u8, item.name, candidate.name)) {
            return error.DuplicateEventGeneration;
        }
    }
    try validateEventDerivationReferences(candidate, prior);
}

fn decodeEventPointer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !definition_core.json_pointer.Pointer {
    const text = try decoder.readBytesAlloc(allocator, 1024);
    defer allocator.free(text);
    return compileEventPointer(allocator, text);
}

fn decodeEventDerivationFragments(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]EventDerivationFragment {
    const count = try decoder.readCount(64);
    if (count == 0) return error.InvalidEventDerivationFragments;
    const fragments = try allocator.alloc(EventDerivationFragment, count);
    var initialized: usize = 0;
    errdefer {
        for (fragments[0..initialized]) |*fragment| {
            fragment.deinit(allocator);
        }
        allocator.free(fragments);
    }
    for (fragments) |*fragment| {
        fragment.* = switch (try decoder.readEnum(
            std.meta.Tag(EventDerivationFragment),
        )) {
            .literal => .{ .literal = try decoder.readBytesAlloc(
                allocator,
                4096,
            ) },
            .input_text => input_text: {
                var pointer = try decodeEventPointer(
                    allocator,
                    decoder,
                );
                errdefer pointer.deinit(allocator);
                break :input_text .{ .input_text = .{
                    .pointer = pointer,
                    .transform = try decoder.readEnum(
                        EventInputTextTransform,
                    ),
                } };
            },
            .input_json => .{ .input_json = try decodeEventPointer(
                allocator,
                decoder,
            ) },
            .canonical_input => .{ .canonical_input = try decodeEventPointer(allocator, decoder) },
            .derived => blk: {
                const name = try decoder.readBytesAlloc(allocator, 128);
                errdefer allocator.free(name);
                try definition_core.json.safeIdentifier(name, 128);
                const prefix_bytes = if (try decoder.readBool())
                    try decoder.readU16()
                else
                    null;
                break :blk .{ .derived = .{
                    .name = name,
                    .prefix_bytes = prefix_bytes,
                    .transform = try decoder.readEnum(
                        EventDerivedTransform,
                    ),
                } };
            },
        };
        initialized += 1;
    }
    try validateEventDerivationFragments(fragments);
    return fragments;
}

fn decodeEventBodyFields(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]EventBodyField {
    const count = try decoder.readCount(64);
    const fields = try allocator.alloc(EventBodyField, count);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (fields, 0..) |*field, index| {
        var name: ?[]u8 = try decoder.readBytesAlloc(allocator, 128);
        errdefer if (name) |value| allocator.free(value);
        const source_tag = try decoder.readEnum(
            std.meta.Tag(EventBodyFieldSource),
        );
        var source: ?EventBodyFieldSource =
            try decodeEventBodyFieldSource(
                allocator,
                decoder,
                source_tag,
            );
        errdefer if (source) |*value| value.deinit(allocator);
        const candidate: EventBodyField = .{
            .field = name.?,
            .source = source.?,
        };
        try validateEventBodyField(&candidate);
        if (index != 0 and
            std.mem.order(
                u8,
                fields[index - 1].field,
                candidate.field,
            ) != .lt)
        {
            return error.EventBodyFieldsNotSorted;
        }
        field.* = candidate;
        name = null;
        source = null;
        initialized += 1;
    }
    return fields;
}

fn decodeEventBodyFieldSource(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    tag: std.meta.Tag(EventBodyFieldSource),
) !EventBodyFieldSource {
    return switch (tag) {
        .generated_sha256 => .{ .generated_sha256 = try decoder.readBytesAlloc(allocator, 128) },
        .parameter_sha256 => blk: {
            const value = try decodeParameterSha256Source(
                allocator,
                decoder,
            );
            break :blk .{ .parameter_sha256 = value };
        },
        .state_value => .{ .state_value = try decodeStateValueSource(allocator, decoder) },
        .request_input => .{ .request_input = try decoder.readBytesAlloc(allocator, 128) },
        .literal_mapping => blk: {
            const value = try decodeLiteralMappingSource(
                allocator,
                decoder,
            );
            break :blk .{ .literal_mapping = value };
        },
        .derived => .{ .derived = try decoder.readBytesAlloc(allocator, 128) },
    };
}

fn decodeLiteralMappingSource(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !LiteralMappingSource {
    const request_literal = try decoder.readBytesAlloc(allocator, 4096);
    errdefer allocator.free(request_literal);
    const stored_literal = try decoder.readBytesAlloc(allocator, 4096);
    errdefer allocator.free(stored_literal);
    try validateCanonicalScalar(allocator, request_literal);
    try validateCanonicalScalar(allocator, stored_literal);
    return .{
        .request_literal = request_literal,
        .stored_literal = stored_literal,
    };
}

fn decodeParameterSha256Source(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !ParameterSha256Source {
    const parameter = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(parameter);
    return .{
        .parameter = parameter,
        .expected_state = try decodeStateValueSource(
            allocator,
            decoder,
        ),
    };
}

fn decodeStateValueSource(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !StateValueSource {
    const register = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(register);
    const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
    defer allocator.free(raw_pointer);
    return .{
        .register = register,
        .pointer = try definition_core.json_pointer.compile(
            allocator,
            raw_pointer,
        ),
    };
}

fn decodeSortedNames(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    max_count: usize,
) ![][]u8 {
    const count = try decoder.readCount(max_count);
    const names = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (names, 0..) |*name, index| {
        name.* = try decoder.readBytesAlloc(allocator, 128);
        initialized += 1;
        try definition_core.json.safeIdentifier(name.*, 128);
        if (index != 0 and
            std.mem.order(u8, names[index - 1], name.*) != .lt)
        {
            return error.EventParameterNamesNotSorted;
        }
    }
    return names;
}

fn decodeDeclaredOrder(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    max_count: usize,
) ![][]u8 {
    const count = try decoder.readCount(max_count);
    const names = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (names, 0..) |*name, index| {
        name.* = try decoder.readBytesAlloc(allocator, 128);
        initialized += 1;
        try definition_core.json.safeIdentifier(name.*, 128);
        for (names[0..index]) |prior| {
            if (std.mem.eql(u8, prior, name.*)) {
                return error.DuplicateEventLayoutField;
            }
        }
    }
    return names;
}

fn decodeEventObjectOrders(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]EventObjectOrder {
    const count = try decoder.readCount(16);
    const orders = try allocator.alloc(EventObjectOrder, count);
    var initialized: usize = 0;
    errdefer {
        for (orders[0..initialized]) |*order| order.deinit(allocator);
        allocator.free(orders);
    }
    for (orders, 0..) |*order, index| {
        const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw_pointer);
        const pointer = try definition_core.json_pointer.compile(
            allocator,
            raw_pointer,
        );
        errdefer {
            var owned = pointer;
            owned.deinit(allocator);
        }
        if (pointer.segments.len == 0) {
            return error.InvalidEventObjectOrderPath;
        }
        const fields = try decodeDeclaredOrder(allocator, decoder, 64);
        errdefer deinitNames(allocator, fields);
        if (fields.len == 0) return error.InvalidEventObjectOrderFields;
        if (index != 0 and
            std.mem.order(
                u8,
                orders[index - 1].pointer.raw,
                pointer.raw,
            ) != .lt)
        {
            return error.EventObjectOrdersNotSorted;
        }
        order.* = .{ .pointer = pointer, .fields = fields };
        initialized += 1;
    }
    return orders;
}

fn validateCachedOperation(effects: []const Effect, atomic: bool) !void {
    if (!atomic and effects.len > 1) return error.MultiEffectOperationMustBeAtomic;
    var binding_effects: usize = 0;
    for (effects, 0..) |left, index| {
        if (left.kind == .bind_existing) binding_effects += 1;
        for (effects[index + 1 ..]) |right| {
            if (left.slot_index == right.slot_index) {
                return error.DuplicateOperationSlot;
            }
        }
    }
    if (binding_effects != 0 and binding_effects != effects.len) {
        return error.BindingOperationCannotMixEffects;
    }
    try validateGeneratedOutputNames(effects);
}

fn compileSlots(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) ![]Slot {
    if (definition_plan.storage_kind == .pure) {
        try definition_core.json.requireExactKeys(object, &.{"kind"});
        return allocator.alloc(Slot, 0);
    }
    try definition_core.json.requireExactKeys(object, &.{ "kind", "slots" });
    try definition_core.json.requireFields(object, &.{ "kind", "slots" });
    const slot_map = try definition_core.json.object(
        try definition_core.json.field(object, "slots"),
    );
    if (slot_map.count() == 0 or slot_map.count() > 64) {
        return error.InvalidStorageSlotCount;
    }
    var slots: std.ArrayList(Slot) = .empty;
    errdefer {
        for (slots.items) |*slot| slot.deinit(allocator);
        slots.deinit(allocator);
    }
    var iterator = slot_map.iterator();
    while (iterator.next()) |entry| {
        const slot = try compileSlot(
            allocator,
            definition_plan,
            entry.key_ptr.*,
            entry.value_ptr.*,
        );
        errdefer {
            var owned = slot;
            owned.deinit(allocator);
        }
        try slots.append(allocator, slot);
    }
    std.sort.heap(Slot, slots.items, {}, struct {
        fn lessThan(_: void, left: Slot, right: Slot) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    try validateSlotPathAmbiguity(slots.items);
    return slots.toOwnedSlice(allocator);
}

fn compileSlot(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    name: []const u8,
    raw: std.json.Value,
) !Slot {
    try definition_core.json.safeIdentifier(name, 128);
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "path", "kind", "codec", "max_bytes" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "path", "codec", "max_bytes" },
    );
    const relative_path = try definition_core.json.requiredString(
        object,
        "path",
    );
    const path_segments = try compilePathSegments(
        allocator,
        definition_plan,
        relative_path,
    );
    errdefer deinitPathSegments(allocator, path_segments);
    const codec = try definition.Codec.parse(
        try definition_core.json.requiredString(object, "codec"),
    );
    const kind: SlotKind = if (object.get("kind")) |value|
        try SlotKind.parse(try definition_core.json.string(value))
    else if (codec == .jsonl)
        .event_log
    else
        .document;
    try validateDecodedSlotCodec(kind, codec);
    const max_bytes = try definition_core.json.unsigned(
        try definition_core.json.field(object, "max_bytes"),
    );
    if (max_bytes == 0 or max_bytes > 4 * 1024 * 1024 * 1024) {
        return error.StorageSlotBoundsExceeded;
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_path = try allocator.dupe(u8, relative_path);
    errdefer allocator.free(owned_path);
    return .{
        .name = owned_name,
        .relative_path = owned_path,
        .path_segments = path_segments,
        .kind = kind,
        .codec = codec,
        .max_bytes = max_bytes,
    };
}

fn validateSlotPathAmbiguity(slots: []const Slot) !void {
    for (slots, 0..) |left, index| {
        for (slots[index + 1 ..]) |right| {
            if (std.ascii.eqlIgnoreCase(
                left.relative_path,
                right.relative_path,
            )) return error.StoragePathCaseAmbiguity;
        }
    }
}

fn compileOperations(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    slots: []const Slot,
) ![]Operation {
    if (definition_plan.storage_kind == .pure) {
        if (definition_plan.operations.len != 0) return error.PureStorageHasOperations;
        return allocator.alloc(Operation, 0);
    }
    var operations: std.ArrayList(Operation) = .empty;
    errdefer {
        for (operations.items) |*operation| operation.deinit(allocator);
        operations.deinit(allocator);
    }
    for (definition_plan.operations) |source| {
        const operation = try compileOperation(
            allocator,
            definition_plan,
            slots,
            source,
        );
        errdefer {
            var owned = operation;
            owned.deinit(allocator);
        }
        try operations.append(allocator, operation);
    }
    return operations.toOwnedSlice(allocator);
}

fn compileOperation(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    slots: []const Slot,
    source: definition.NamedPlan,
) !Operation {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source.canonical_config,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "effects" },
    );
    const atomic = try compileOperationAtomic(definition_plan, object);
    const effects = try compileOperationEffects(
        allocator,
        definition_plan,
        slots,
        object,
    );
    errdefer {
        for (effects) |*effect| effect.deinit(allocator);
        allocator.free(effects);
    }
    try validateCachedOperation(effects, atomic);
    return .{
        .name = try allocator.dupe(u8, source.name),
        .atomic = atomic,
        .effects = effects,
    };
}

fn compileOperationAtomic(
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !bool {
    const raw = object.get("op") orelse return false;
    const operator = try definition.Operator.parse(
        try definition_core.json.string(raw),
    );
    if (operator != .atomic_transaction) {
        return error.UnsupportedOperationRoot;
    }
    if (!definition_plan.requires(operator)) {
        return error.UndeclaredArtifactOperator;
    }
    return true;
}

fn compileOperationEffects(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    slots: []const Slot,
    object: std.json.ObjectMap,
) ![]Effect {
    const raw = object.get("effects") orelse
        return error.MissingOperationEffects;
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidOperationEffectCount;
    }
    const effects = try allocator.alloc(Effect, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (effects[0..initialized]) |*effect| effect.deinit(allocator);
        allocator.free(effects);
    }
    for (values.items, 0..) |value, index| {
        effects[index] = try compileEffect(
            allocator,
            definition_plan,
            slots,
            value,
        );
        initialized += 1;
    }
    return effects;
}

fn validateGeneratedOutputNames(effects: []const Effect) !void {
    var names: [4096][]const u8 = undefined;
    var count: usize = 0;
    for (effects) |effect| {
        if (effect.event) |event| {
            for (event.generate) |generated| {
                try appendGeneratedOutputName(&names, &count, generated.name);
            }
            for (event.derive) |derived| {
                try appendGeneratedOutputName(&names, &count, derived.name);
            }
        }
        if (effect.document) |document_plan| {
            if (document_plan.identity) |identity| {
                try appendGeneratedOutputName(&names, &count, identity.name);
                try appendGeneratedOutputName(
                    &names,
                    &count,
                    identity.timestamp_name,
                );
                if (identity.path_name) |path_name| {
                    try appendGeneratedOutputName(&names, &count, path_name);
                }
            }
        }
    }
}

fn appendGeneratedOutputName(
    names: *[4096][]const u8,
    count: *usize,
    name: []const u8,
) !void {
    for (names[0..count.*]) |prior| {
        if (std.mem.eql(u8, prior, name)) {
            return error.DuplicateGeneratedOutput;
        }
    }
    if (count.* >= names.len) return error.GeneratedOutputCountExceeded;
    names[count.*] = name;
    count.* += 1;
}

const EffectTarget = struct {
    kind: EffectKind,
    slot_index: usize,
    input_index: usize,
};

fn compileEffect(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    slots: []const Slot,
    raw: std.json.Value,
) !Effect {
    const object = try definition_core.json.object(raw);
    try validateEffectObject(object);
    const target = try compileEffectTarget(definition_plan, slots, object);
    const expected_revision_parameter = try optionalParameterName(
        allocator,
        definition_plan,
        object,
        "expected_revision_param",
    );
    errdefer if (expected_revision_parameter) |name| allocator.free(name);
    const idempotency_parameter = try optionalParameterName(
        allocator,
        definition_plan,
        object,
        "idempotency_param",
    );
    errdefer if (idempotency_parameter) |name| allocator.free(name);
    const parameter_bindings = try compileParameterBindings(
        allocator,
        definition_plan,
        object,
    );
    errdefer deinitParameterBindings(allocator, parameter_bindings);
    var event = try compileEffectEvent(
        allocator,
        definition_plan,
        object,
    );
    errdefer if (event) |*value| value.deinit(allocator);
    var document_plan = try compileEffectDocument(
        allocator,
        definition_plan,
        slots[target.slot_index],
        target.kind,
        object,
    );
    errdefer if (document_plan) |*value| value.deinit(allocator);
    try validateCompiledEffectSources(
        target.kind,
        expected_revision_parameter,
        idempotency_parameter,
        parameter_bindings,
        event,
        document_plan,
    );
    if (parameter_bindings.len != 0 and
        (slots[target.slot_index].kind != .document or
            definition_plan.inputs[target.input_index].codec != .json))
    {
        return error.EffectParameterBindingsRequireJsonDocument;
    }
    return .{
        .kind = target.kind,
        .slot_index = @intCast(target.slot_index),
        .input_index = @intCast(target.input_index),
        .expected_revision_parameter = expected_revision_parameter,
        .idempotency_parameter = idempotency_parameter,
        .parameter_bindings = parameter_bindings,
        .event = event,
        .document = document_plan,
    };
}

fn validateEffectObject(object: std.json.ObjectMap) !void {
    try definition_core.json.requireExactKeys(object, &.{
        "op",
        "slot",
        "input",
        "expected_revision_param",
        "idempotency_param",
        "parameter_bindings",
        "event",
        "event_from_operation",
        "document",
    });
    try definition_core.json.requireFields(object, &.{ "op", "slot", "input" });
}

fn compileEffectTarget(
    definition_plan: *const definition.Plan,
    slots: []const Slot,
    object: std.json.ObjectMap,
) !EffectTarget {
    const operator = try definition.Operator.parse(
        try definition_core.json.requiredString(object, "op"),
    );
    if (!definition_plan.requires(operator)) return error.UndeclaredArtifactOperator;
    const kind = try EffectKind.fromOperator(operator);
    const slot_index = findSlot(slots, try definition_core.json.requiredString(
        object,
        "slot",
    )) orelse return error.UnknownStorageSlot;
    const input_index = findInput(
        definition_plan.inputs,
        try definition_core.json.requiredString(object, "input"),
    ) orelse return error.UnknownOperationInput;
    if (kind == .compare_append and slots[slot_index].kind != .event_log) {
        return error.AppendRequiresEventLogSlot;
    }
    const input_codec = definition_plan.inputs[input_index].codec;
    const event_log_append = kind == .compare_append or
        (kind == .bind_existing and slots[slot_index].kind == .event_log);
    if (event_log_append and input_codec != .json) {
        return error.AppendInputMustBeJson;
    }
    if (kind != .compare_append and object.get("document") == null and
        !(kind == .bind_existing and slots[slot_index].kind == .event_log) and
        input_codec != slots[slot_index].codec)
    {
        return error.StorageInputCodecMismatch;
    }
    return .{
        .kind = kind,
        .slot_index = slot_index,
        .input_index = input_index,
    };
}

fn compileEffectEvent(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !?EventMaterialization {
    if (object.get("event") != null and
        object.get("event_from_operation") != null)
    {
        return error.DuplicateEventMaterializationSource;
    }
    if (object.get("event")) |raw_event| {
        return @as(?EventMaterialization, try compileEventMaterialization(
            allocator,
            definition_plan,
            raw_event,
        ));
    }
    if (object.get("event_from_operation")) |raw_operation| {
        return @as(
            ?EventMaterialization,
            try compileReferencedEventMaterialization(
                allocator,
                definition_plan,
                try definition_core.json.string(raw_operation),
                try definition_core.json.requiredString(object, "slot"),
                try definition_core.json.requiredString(object, "input"),
            ),
        );
    }
    return null;
}

fn compileEffectDocument(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    slot: Slot,
    kind: EffectKind,
    object: std.json.ObjectMap,
) !?document.Plan {
    const raw = object.get("document") orelse return null;
    var document_plan = try document.compile(
        allocator,
        definition_plan,
        raw,
    );
    errdefer document_plan.deinit(allocator);
    if (slot.kind != .document or slot.codec != .text) {
        return error.DocumentMaterializationRequiresTextSlot;
    }
    switch (document_plan.mode) {
        .template => if (kind != .create_new) {
            return error.TemplateMaterializationRequiresCreate;
        },
        .edit => if (kind != .compare_replace) {
            return error.EditMaterializationRequiresReplace;
        },
    }
    if (document_plan.identity) |identity| {
        if (!slotPathUsesParameter(
            slot,
            document.pathOutputName(identity),
        )) return error.GeneratedIdentityMustAddressSlot;
    }
    return document_plan;
}

fn validateCompiledEffectSources(
    kind: EffectKind,
    expected_revision_parameter: ?[]const u8,
    idempotency_parameter: ?[]const u8,
    parameter_bindings: []const ParameterBinding,
    event: ?EventMaterialization,
    document_plan: ?document.Plan,
) !void {
    if (kind == .bind_existing and
        (expected_revision_parameter != null or
            idempotency_parameter != null))
    {
        return error.BindingEffectHasAdmissionParameter;
    }
    if (event != null and kind != .compare_append and
        kind != .bind_existing)
    {
        return error.EventMaterializationRequiresAppend;
    }
    if (idempotency_parameter != null and
        event != null and event.?.idempotency != null)
    {
        return error.DuplicateIdempotencySource;
    }
    if (document_plan != null and event != null) {
        return error.DuplicateEffectMaterialization;
    }
    try validateParameterBindings(parameter_bindings);
}

fn slotPathUsesParameter(slot: Slot, name: []const u8) bool {
    for (slot.path_segments) |segment| {
        if (segment.kind == .parameter and
            std.mem.eql(u8, segment.text, name))
        {
            return true;
        }
    }
    return false;
}

fn compileReferencedEventMaterialization(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    operation_name: []const u8,
    slot_name: []const u8,
    input_name: []const u8,
) !EventMaterialization {
    try definition_core.json.safeIdentifier(operation_name, 128);
    const source = for (definition_plan.operations) |candidate| {
        if (std.mem.eql(u8, candidate.name, operation_name)) {
            break candidate;
        }
    } else return error.EventMaterializationOperationMissing;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source.canonical_config,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    const operation = try definition_core.json.object(parsed.value);
    const effects = try definition_core.json.array(
        try definition_core.json.field(operation, "effects"),
    );
    var matched: ?std.json.Value = null;
    for (effects.items) |raw_effect| {
        const effect = try definition_core.json.object(raw_effect);
        const candidate_slot =
            try definition_core.json.requiredString(effect, "slot");
        const candidate_input =
            try definition_core.json.requiredString(effect, "input");
        if (!std.mem.eql(u8, candidate_slot, slot_name) or
            !std.mem.eql(u8, candidate_input, input_name))
        {
            continue;
        }
        if (matched != null) {
            return error.EventMaterializationReferenceAmbiguous;
        }
        matched = effect.get("event") orelse
            return error.EventMaterializationReferenceMustBeDirect;
        if (effect.get("event_from_operation") != null) {
            return error.EventMaterializationReferenceMustBeDirect;
        }
    }
    return compileEventMaterialization(
        allocator,
        definition_plan,
        matched orelse return error.EventMaterializationEffectMissing,
    );
}

const EventMaterializationLayout = struct {
    mode: EventMaterializationMode,
    body_input_field: []u8,
    field_order: [][]u8,
    body_order: [][]u8,
    object_orders: []EventObjectOrder,
    escape_non_ascii: bool,
    fields: []EventField,

    fn deinit(
        self: *EventMaterializationLayout,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.body_input_field);
        deinitNames(allocator, self.field_order);
        deinitNames(allocator, self.body_order);
        deinitEventObjectOrders(allocator, self.object_orders);
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

fn compileEventMaterialization(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) !EventMaterialization {
    if (!definition_plan.requires(.event_materialization)) {
        return error.UndeclaredArtifactOperator;
    }
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{
            "mode",
            "body_input_field",
            "field_order",
            "body_order",
            "object_orders",
            "escape_non_ascii",
            "fields",
            "request_literals",
            "generate",
            "derive",
            "idempotency",
            "body_fields",
            "forbidden_parameters",
        },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "mode", "body_input_field", "fields" },
    );
    var layout = try compileEventMaterializationLayout(allocator, object);
    errdefer layout.deinit(allocator);
    var extensions = try compileEventExtensions(
        allocator,
        definition_plan,
        object,
    );
    errdefer extensions.deinit(allocator);
    const result: EventMaterialization = .{
        .mode = layout.mode,
        .body_input_field = layout.body_input_field,
        .field_order = layout.field_order,
        .body_order = layout.body_order,
        .object_orders = layout.object_orders,
        .escape_non_ascii = layout.escape_non_ascii,
        .fields = layout.fields,
        .request_literals = extensions.request_literals,
        .generate = extensions.generate,
        .derive = extensions.derive,
        .idempotency = extensions.idempotency,
        .body_fields = extensions.body_fields,
        .forbidden_parameters = extensions.forbidden_parameters,
    };
    try validateEventMaterialization(allocator, &result);
    try validateEventMaterializationAgainstDefinition(
        &result,
        definition_plan,
    );
    return result;
}

fn compileEventMaterializationLayout(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !EventMaterializationLayout {
    const mode = try EventMaterializationMode.parse(
        try definition_core.json.requiredString(object, "mode"),
    );
    const body_input_field = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(
            object,
            "body_input_field",
        ),
    );
    errdefer allocator.free(body_input_field);
    try definition_core.json.safeIdentifier(body_input_field, 128);
    const field_order = if (object.get("field_order")) |raw_order|
        try compileDeclaredOrder(allocator, raw_order, 65)
    else
        try allocator.alloc([]u8, 0);
    errdefer deinitNames(allocator, field_order);
    const body_order = if (object.get("body_order")) |raw_order|
        try compileDeclaredOrder(allocator, raw_order, 64)
    else
        try allocator.alloc([]u8, 0);
    errdefer deinitNames(allocator, body_order);
    const object_orders = if (object.get("object_orders")) |raw_orders|
        try compileEventObjectOrders(allocator, raw_orders)
    else
        try allocator.alloc(EventObjectOrder, 0);
    errdefer deinitEventObjectOrders(allocator, object_orders);
    const escape_non_ascii = if (object.get("escape_non_ascii")) |raw_value|
        try definition_core.json.boolean(raw_value)
    else
        false;
    const fields = try compileEventFields(allocator, object);
    return .{
        .mode = mode,
        .body_input_field = body_input_field,
        .field_order = field_order,
        .body_order = body_order,
        .object_orders = object_orders,
        .escape_non_ascii = escape_non_ascii,
        .fields = fields,
    };
}

fn compileEventFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![]EventField {
    const raw_fields = try definition_core.json.array(
        try definition_core.json.field(object, "fields"),
    );
    if (raw_fields.items.len == 0 or raw_fields.items.len > 64) {
        return error.InvalidEventMaterializationFields;
    }
    const fields = try allocator.alloc(EventField, raw_fields.items.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (raw_fields.items, 0..) |raw_field, index| {
        fields[index] = try compileEventField(allocator, raw_field);
        initialized += 1;
    }
    std.sort.heap(EventField, fields, {}, struct {
        fn lessThan(_: void, left: EventField, right: EventField) bool {
            return std.mem.lessThan(u8, left.field, right.field);
        }
    }.lessThan);
    return fields;
}

fn compileEventExtensions(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !EventExtensions {
    const request_literals = if (object.get("request_literals")) |raw_literals|
        try compileRequestLiterals(allocator, raw_literals)
    else
        try allocator.alloc(RequestLiteral, 0);
    errdefer deinitRequestLiterals(allocator, request_literals);
    const generate = if (object.get("generate")) |raw_generate|
        try compileSecureTokenGenerations(
            allocator,
            definition_plan,
            raw_generate,
        )
    else
        try allocator.alloc(SecureTokenGeneration, 0);
    errdefer deinitSecureTokenGenerations(allocator, generate);
    const derive = if (object.get("derive")) |raw_derive|
        try compileEventDerivations(
            allocator,
            definition_plan,
            raw_derive,
            generate,
        )
    else
        try allocator.alloc(EventDerivation, 0);
    errdefer deinitEventDerivations(allocator, derive);
    var idempotency = if (object.get("idempotency")) |raw_idempotency|
        try compileEventIdempotency(
            allocator,
            definition_plan,
            raw_idempotency,
            derive,
        )
    else
        null;
    errdefer if (idempotency) |*item| item.deinit(allocator);
    const body_fields = if (object.get("body_fields")) |raw_body_fields|
        try compileEventBodyFields(
            allocator,
            definition_plan,
            raw_body_fields,
        )
    else
        try allocator.alloc(EventBodyField, 0);
    errdefer deinitEventBodyFields(allocator, body_fields);
    const forbidden_parameters =
        if (object.get("forbidden_parameters")) |raw_parameters|
            try compileParameterNames(
                allocator,
                definition_plan,
                raw_parameters,
            )
        else
            try allocator.alloc([]u8, 0);
    errdefer deinitNames(allocator, forbidden_parameters);
    return .{
        .request_literals = request_literals,
        .generate = generate,
        .derive = derive,
        .idempotency = idempotency,
        .body_fields = body_fields,
        .forbidden_parameters = forbidden_parameters,
    };
}

fn compileDeclaredOrder(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    max_count: usize,
) ![][]u8 {
    const values = try definition_core.json.array(raw);
    if (values.items.len > max_count) {
        return error.EventMaterializationLayoutBoundsExceeded;
    }
    const names = try allocator.alloc([]u8, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (values.items, 0..) |value, index| {
        const name = try definition_core.json.string(value);
        try definition_core.json.safeIdentifier(name, 128);
        for (names[0..index]) |prior| {
            if (std.mem.eql(u8, prior, name)) {
                return error.DuplicateEventLayoutField;
            }
        }
        names[index] = try allocator.dupe(u8, name);
        initialized += 1;
    }
    return names;
}

fn compileEventObjectOrders(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) ![]EventObjectOrder {
    const values = try definition_core.json.array(raw);
    if (values.items.len > 16) {
        return error.InvalidEventMaterializationBounds;
    }
    const orders = try allocator.alloc(EventObjectOrder, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (orders[0..initialized]) |*order| order.deinit(allocator);
        allocator.free(orders);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "path", "fields" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "path", "fields" },
        );
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.requiredString(object, "path"),
        );
        errdefer pointer.deinit(allocator);
        if (pointer.segments.len == 0) {
            return error.InvalidEventObjectOrderPath;
        }
        const fields = try compileDeclaredOrder(
            allocator,
            try definition_core.json.field(object, "fields"),
            64,
        );
        errdefer deinitNames(allocator, fields);
        if (fields.len == 0) return error.InvalidEventObjectOrderFields;
        orders[index] = .{ .pointer = pointer, .fields = fields };
        initialized += 1;
    }
    std.sort.heap(EventObjectOrder, orders, {}, struct {
        fn lessThan(
            _: void,
            left: EventObjectOrder,
            right: EventObjectOrder,
        ) bool {
            return std.mem.lessThan(u8, left.pointer.raw, right.pointer.raw);
        }
    }.lessThan);
    for (orders[1..], 1..) |order, index| {
        if (std.mem.eql(
            u8,
            orders[index - 1].pointer.raw,
            order.pointer.raw,
        )) return error.DuplicateEventObjectOrder;
    }
    return orders;
}

fn compileSecureTokenGenerations(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) ![]SecureTokenGeneration {
    if (!definition_plan.requires(.secure_token)) {
        return error.UndeclaredArtifactOperator;
    }
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > 16) {
        return error.InvalidEventGenerationCount;
    }
    const items = try allocator.alloc(
        SecureTokenGeneration,
        values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (values.items, 0..) |value, index| {
        items[index] = try compileSecureTokenGeneration(
            allocator,
            value,
        );
        initialized += 1;
    }
    std.sort.heap(
        SecureTokenGeneration,
        items,
        {},
        struct {
            fn lessThan(
                _: void,
                left: SecureTokenGeneration,
                right: SecureTokenGeneration,
            ) bool {
                return std.mem.lessThan(u8, left.name, right.name);
            }
        }.lessThan,
    );
    try validateUniqueSecureTokenGenerations(items);
    return items;
}

fn compileSecureTokenGeneration(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !SecureTokenGeneration {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "name", "op", "prefix", "bytes" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "name", "op", "prefix", "bytes" },
    );
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "op"),
        "secure-token",
    )) return error.UnsupportedEventGeneration;
    const byte_count = try definition_core.json.unsigned(
        try definition_core.json.field(object, "bytes"),
    );
    if (byte_count > std.math.maxInt(u8)) {
        return error.SecureTokenByteCountInvalid;
    }
    const name = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "name"),
    );
    errdefer allocator.free(name);
    const prefix = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "prefix"),
    );
    errdefer allocator.free(prefix);
    const result: SecureTokenGeneration = .{
        .name = name,
        .prefix = prefix,
        .byte_count = @intCast(byte_count),
    };
    try validateSecureTokenGeneration(&result);
    return result;
}

fn validateUniqueSecureTokenGenerations(
    items: []const SecureTokenGeneration,
) !void {
    for (items[1..], 1..) |item, index| {
        if (std.mem.eql(u8, items[index - 1].name, item.name)) {
            return error.DuplicateEventGeneration;
        }
    }
}

fn compileEventDerivations(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
    generate: []const SecureTokenGeneration,
) ![]EventDerivation {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > 16) {
        return error.InvalidEventDerivationCount;
    }
    const items = try allocator.alloc(EventDerivation, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (values.items, 0..) |value, index| {
        items[index] = try compileEventDerivation(
            allocator,
            definition_plan,
            value,
        );
        initialized += 1;
        for (generate) |generated| {
            if (std.mem.eql(u8, generated.name, items[index].name)) {
                return error.DuplicateEventGeneration;
            }
        }
        for (items[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, items[index].name)) {
                return error.DuplicateEventGeneration;
            }
        }
        try validateEventDerivationReferences(
            &items[index],
            items[0..index],
        );
    }
    return items;
}

fn compileEventIdempotency(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
    derivations: []const EventDerivation,
) !EventIdempotency {
    if (!definition_plan.requires(.idempotency_key)) {
        return error.UndeclaredArtifactOperator;
    }
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "derived", "bypass_param" },
    );
    try definition_core.json.requireFields(object, &.{"derived"});
    const derived = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "derived"),
    );
    errdefer allocator.free(derived);
    try definition_core.json.safeIdentifier(derived, 128);
    const item = findEventDerivation(derivations, derived) orelse
        return error.EventIdempotencyDerivationMissing;
    switch (item.source) {
        .sha1, .sha256 => |digest| {
            if (digest.encoding != .hex) {
                return error.EventIdempotencyDerivationNotSafeIdentifier;
            }
            for (digest.fragments) |fragment| switch (fragment) {
                .derived => {
                    return error.EventIdempotencyDerivationNotInputBound;
                },
                else => {},
            };
        },
        else => return error.EventIdempotencyDerivationNotDigest,
    }
    const bypass_parameter = if (object.get("bypass_param")) |value| blk: {
        const name = try definition_core.json.string(value);
        const declaration =
            definition_plan.parameter_declarations.find(name) orelse
            return error.UnknownOperationParameter;
        if (declaration.kind != .boolean) {
            return error.EventIdempotencyBypassMustBeBoolean;
        }
        break :blk try allocator.dupe(u8, name);
    } else null;
    return .{
        .derived = derived,
        .bypass_parameter = bypass_parameter,
    };
}

fn compileEventDerivation(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) !EventDerivation {
    const object = try definition_core.json.object(raw);
    const op = try definition_core.json.requiredString(object, "op");
    const name = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "name"),
    );
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    var source = try compileEventDerivationSource(
        allocator,
        definition_plan,
        object,
        op,
    );
    errdefer source.deinit(allocator);
    return .{ .name = name, .source = source };
}

fn compileEventDerivationSource(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
    op: []const u8,
) !EventDerivationSource {
    if (std.mem.eql(u8, op, "input-text")) {
        return .{ .input_text = try compileInputTextDerivation(
            allocator,
            object,
        ) };
    }
    if (std.mem.eql(u8, op, "utc-timestamp")) {
        if (!definition_plan.requires(.timestamp)) {
            return error.UndeclaredArtifactOperator;
        }
        return .{ .utc_timestamp = try compileTimestampDerivation(object) };
    }
    if (std.mem.eql(u8, op, "sha1")) {
        if (!definition_plan.requires(.sha1)) {
            return error.UndeclaredArtifactOperator;
        }
        return .{ .sha1 = try compileEventDigestDerivation(
            allocator,
            object,
        ) };
    }
    if (std.mem.eql(u8, op, "sha256")) {
        if (!definition_plan.requires(.sha256)) {
            return error.UndeclaredArtifactOperator;
        }
        return .{ .sha256 = try compileEventDigestDerivation(
            allocator,
            object,
        ) };
    }
    if (std.mem.eql(u8, op, "concat")) {
        if (!definition_plan.requires(.composite_identity)) {
            return error.UndeclaredArtifactOperator;
        }
        return .{ .concat = try compileConcatDerivation(allocator, object) };
    }
    if (std.mem.eql(u8, op, "monotonic-identity")) {
        if (!definition_plan.requires(.monotonic_identity) or
            !definition_plan.requires(.reducer))
        {
            return error.UndeclaredArtifactOperator;
        }
        return .{ .monotonic_identity = try compileMonotonicIdentityDerivation(allocator, object) };
    }
    return error.UnsupportedEventDerivation;
}

fn compileInputTextDerivation(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !definition_core.json_pointer.Pointer {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "name", "op", "pointer" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "name", "op", "pointer" },
    );
    return compileEventPointer(
        allocator,
        try definition_core.json.requiredString(object, "pointer"),
    );
}

fn compileTimestampDerivation(
    object: std.json.ObjectMap,
) !EventTimestampFormat {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "name", "op", "format" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "name", "op", "format" },
    );
    return EventTimestampFormat.parse(
        try definition_core.json.requiredString(object, "format"),
    );
}

fn compileConcatDerivation(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !EventConcatDerivation {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "name", "op", "fragments", "max_bytes" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "name", "op", "fragments", "max_bytes" },
    );
    const fragments = try compileEventDerivationFragments(
        allocator,
        try definition_core.json.field(object, "fragments"),
    );
    errdefer deinitEventDerivationFragments(allocator, fragments);
    return .{
        .fragments = fragments,
        .max_bytes = try compileEventDerivationBound(object),
    };
}

fn compileMonotonicIdentityDerivation(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !EventMonotonicIdentityDerivation {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "name", "op", "prefix", "width" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "name", "op", "prefix", "width" },
    );
    const width = try definition_core.json.unsigned(object.get("width").?);
    const bounded_width = std.math.cast(u8, width) orelse
        return error.InvalidEventMonotonicIdentity;
    return .{
        .prefix = try allocator.dupe(
            u8,
            try definition_core.json.requiredString(object, "prefix"),
        ),
        .width = bounded_width,
    };
}

fn compileEventDigestDerivation(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !EventDigestDerivation {
    try definition_core.json.requireExactKeys(
        object,
        &.{
            "name",
            "op",
            "encoding",
            "fragments",
            "max_bytes",
            "prefix_bytes",
        },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "name", "op", "encoding", "fragments", "max_bytes" },
    );
    const encoding = try EventDigestEncoding.parse(
        try definition_core.json.requiredString(object, "encoding"),
    );
    const prefix_bytes = if (object.get("prefix_bytes")) |raw| prefix: {
        if (encoding != .hex) return error.InvalidEventDigestPrefix;
        const count = try definition_core.json.unsigned(raw);
        if (count == 0 or count > 64) {
            return error.InvalidEventDigestPrefix;
        }
        break :prefix @as(u16, @intCast(count));
    } else null;
    const fragments = try compileEventDerivationFragments(
        allocator,
        try definition_core.json.field(object, "fragments"),
    );
    errdefer deinitEventDerivationFragments(allocator, fragments);
    return .{
        .encoding = encoding,
        .fragments = fragments,
        .max_bytes = try compileEventDerivationBound(object),
        .prefix_bytes = prefix_bytes,
    };
}

fn compileEventDerivationBound(object: std.json.ObjectMap) !usize {
    const max_bytes = try definition_core.json.unsigned(
        try definition_core.json.field(object, "max_bytes"),
    );
    if (max_bytes == 0 or max_bytes > 16 * 1024 * 1024) {
        return error.InvalidEventDerivationBound;
    }
    return max_bytes;
}

fn compileEventPointer(
    allocator: std.mem.Allocator,
    text: []const u8,
) !definition_core.json_pointer.Pointer {
    if (text.len == 0 or text.len > 1024 or
        !std.unicode.utf8ValidateSlice(text))
    {
        return error.InvalidJsonPointer;
    }
    return definition_core.json_pointer.compile(allocator, text);
}

fn compileEventDerivationFragments(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) ![]EventDerivationFragment {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidEventDerivationFragments;
    }
    const fragments = try allocator.alloc(
        EventDerivationFragment,
        values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (fragments[0..initialized]) |*fragment| {
            fragment.deinit(allocator);
        }
        allocator.free(fragments);
    }
    for (values.items, 0..) |value, index| {
        fragments[index] = try compileEventDerivationFragment(
            allocator,
            value,
        );
        initialized += 1;
    }
    return fragments;
}

fn compileEventDerivationFragment(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !EventDerivationFragment {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{
            "literal",
            "input_text",
            "input_json",
            "canonical_input",
            "derived",
            "prefix_bytes",
            "transform",
        },
    );
    if (eventDerivationFragmentSourceCount(object) != 1) {
        return error.InvalidEventDerivationFragment;
    }
    if (object.get("literal")) |value| {
        return compileLiteralDerivationFragment(allocator, object, value);
    }
    if (object.get("input_text")) |value| {
        return compileInputTextDerivationFragment(
            allocator,
            object,
            value,
        );
    }
    if (object.get("input_json")) |value| {
        try validatePlainDerivationFragment(object);
        return .{ .input_json = try compileEventPointer(
            allocator,
            try definition_core.json.string(value),
        ) };
    }
    if (object.get("canonical_input")) |value| {
        try validatePlainDerivationFragment(object);
        return .{ .canonical_input = try compileEventPointer(
            allocator,
            try definition_core.json.string(value),
        ) };
    }
    return .{ .derived = try compileDerivedReference(
        allocator,
        object,
    ) };
}

fn eventDerivationFragmentSourceCount(
    object: std.json.ObjectMap,
) usize {
    var source_count: usize = 0;
    source_count += @intFromBool(object.get("literal") != null);
    source_count += @intFromBool(object.get("input_text") != null);
    source_count += @intFromBool(object.get("input_json") != null);
    source_count += @intFromBool(object.get("canonical_input") != null);
    source_count += @intFromBool(object.get("derived") != null);
    return source_count;
}

fn validatePlainDerivationFragment(object: std.json.ObjectMap) !void {
    if (object.get("prefix_bytes") != null or
        object.get("transform") != null)
    {
        return error.InvalidEventDerivationFragment;
    }
}

fn compileLiteralDerivationFragment(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    value: std.json.Value,
) !EventDerivationFragment {
    try validatePlainDerivationFragment(object);
    const literal = try allocator.dupe(
        u8,
        try definition_core.json.string(value),
    );
    errdefer allocator.free(literal);
    if (literal.len > 4096 or !std.unicode.utf8ValidateSlice(literal)) {
        return error.InvalidEventDerivationLiteral;
    }
    return .{ .literal = literal };
}

fn compileInputTextDerivationFragment(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    value: std.json.Value,
) !EventDerivationFragment {
    if (object.get("prefix_bytes") != null) {
        return error.InvalidEventDerivationFragment;
    }
    var pointer = try compileEventPointer(
        allocator,
        try definition_core.json.string(value),
    );
    errdefer pointer.deinit(allocator);
    const transform = if (object.get("transform")) |raw_transform|
        try EventInputTextTransform.parse(
            try definition_core.json.string(raw_transform),
        )
    else
        .none;
    return .{ .input_text = .{
        .pointer = pointer,
        .transform = transform,
    } };
}

fn compileDerivedReference(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !EventDerivedReference {
    const name = try allocator.dupe(
        u8,
        try definition_core.json.string(object.get("derived").?),
    );
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    const prefix_bytes = if (object.get("prefix_bytes")) |value| blk: {
        const count = try definition_core.json.unsigned(value);
        if (count == 0 or count > 4096) {
            return error.InvalidEventDerivedPrefix;
        }
        break :blk @as(u16, @intCast(count));
    } else null;
    const transform = if (object.get("transform")) |value|
        try EventDerivedTransform.parse(
            try definition_core.json.string(value),
        )
    else
        .none;
    return .{
        .name = name,
        .prefix_bytes = prefix_bytes,
        .transform = transform,
    };
}

fn validateEventDerivationReferences(
    item: *const EventDerivation,
    prior: []const EventDerivation,
) !void {
    const fragments = switch (item.source) {
        .sha1, .sha256 => |config| config.fragments,
        .concat => |config| config.fragments,
        .input_text, .utc_timestamp, .monotonic_identity => return,
    };
    for (fragments) |fragment| switch (fragment) {
        .derived => |reference| {
            var found = false;
            for (prior) |candidate| {
                if (std.mem.eql(u8, candidate.name, reference.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.EventDerivationDependencyMissing;
        },
        else => {},
    };
}

fn compileEventBodyFields(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) ![]EventBodyField {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidEventBodyFieldCount;
    }
    const fields = try allocator.alloc(EventBodyField, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (values.items, 0..) |value, index| {
        fields[index] = try compileEventBodyField(
            allocator,
            definition_plan,
            value,
        );
        initialized += 1;
    }
    std.sort.heap(EventBodyField, fields, {}, struct {
        fn lessThan(
            _: void,
            left: EventBodyField,
            right: EventBodyField,
        ) bool {
            return std.mem.lessThan(u8, left.field, right.field);
        }
    }.lessThan);
    for (fields[1..], 1..) |field, index| {
        if (std.mem.eql(u8, fields[index - 1].field, field.field)) {
            return error.DuplicateEventBodyField;
        }
    }
    return fields;
}

fn compileEventBodyField(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) !EventBodyField {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(object, &.{
        "field",
        "generated_sha256",
        "literal_mapping",
        "parameter_sha256",
        "request_input",
        "state_value",
        "derived",
    });
    try definition_core.json.requireFields(object, &.{"field"});
    const field = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "field"),
    );
    errdefer allocator.free(field);
    if (eventBodyFieldSourceCount(object) != 1) {
        return error.InvalidEventBodyFieldSource;
    }
    var source = try compileEventBodyFieldSource(
        allocator,
        definition_plan,
        object,
    );
    errdefer source.deinit(allocator);
    const result: EventBodyField = .{
        .field = field,
        .source = source,
    };
    try validateEventBodyField(&result);
    return result;
}

fn eventBodyFieldSourceCount(object: std.json.ObjectMap) usize {
    var source_count: usize = 0;
    source_count += @intFromBool(object.get("generated_sha256") != null);
    source_count += @intFromBool(object.get("literal_mapping") != null);
    source_count += @intFromBool(object.get("parameter_sha256") != null);
    source_count += @intFromBool(object.get("request_input") != null);
    source_count += @intFromBool(object.get("state_value") != null);
    source_count += @intFromBool(object.get("derived") != null);
    return source_count;
}

fn compileEventBodyFieldSource(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !EventBodyFieldSource {
    if (object.get("generated_sha256")) |value| {
        if (!definition_plan.requires(.sha256)) {
            return error.UndeclaredArtifactOperator;
        }
        return .{ .generated_sha256 = try allocator.dupe(
            u8,
            try definition_core.json.string(value),
        ) };
    }
    if (object.get("parameter_sha256")) |value| {
        if (!definition_plan.requires(.sha256)) {
            return error.UndeclaredArtifactOperator;
        }
        return .{ .parameter_sha256 = try compileParameterSha256Source(
            allocator,
            definition_plan,
            value,
        ) };
    }
    if (object.get("request_input")) |value| {
        return .{ .request_input = try allocator.dupe(
            u8,
            try definition_core.json.string(value),
        ) };
    }
    if (object.get("derived")) |value| {
        return .{ .derived = try allocator.dupe(
            u8,
            try definition_core.json.string(value),
        ) };
    }
    if (object.get("literal_mapping")) |value| {
        return .{ .literal_mapping = try compileLiteralMappingSource(allocator, value) };
    }
    if (!definition_plan.requires(.reducer)) {
        return error.UndeclaredArtifactOperator;
    }
    return .{ .state_value = try compileStateValueSource(
        allocator,
        object.get("state_value").?,
    ) };
}

fn compileParameterSha256Source(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) !ParameterSha256Source {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "parameter", "expected_state" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "parameter", "expected_state" },
    );
    const parameter = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "parameter"),
    );
    errdefer allocator.free(parameter);
    const declaration =
        definition_plan.parameter_declarations.find(parameter) orelse
        return error.UnknownOperationParameter;
    if (declaration.kind == .integer or declaration.kind == .boolean) {
        return error.EventHashParameterMustBeText;
    }
    return .{
        .parameter = parameter,
        .expected_state = try compileStateValueSource(
            allocator,
            try definition_core.json.field(object, "expected_state"),
        ),
    };
}

fn compileLiteralMappingSource(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !LiteralMappingSource {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "request", "stored" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "request", "stored" },
    );
    const request_literal =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            try definition_core.json.field(object, "request"),
        );
    errdefer allocator.free(request_literal);
    const stored_literal =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            try definition_core.json.field(object, "stored"),
        );
    errdefer allocator.free(stored_literal);
    try validateCanonicalScalar(allocator, request_literal);
    try validateCanonicalScalar(allocator, stored_literal);
    return .{
        .request_literal = request_literal,
        .stored_literal = stored_literal,
    };
}

fn compileStateValueSource(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !StateValueSource {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "register", "path" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "register", "path" },
    );
    const register = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "register"),
    );
    errdefer allocator.free(register);
    return .{
        .register = register,
        .pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.requiredString(object, "path"),
        ),
    };
}

fn compileParameterNames(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) ![][]u8 {
    const values = try definition_core.json.array(raw);
    if (values.items.len > 64) return error.EventParameterCountInvalid;
    const names = try allocator.alloc([]u8, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (values.items, 0..) |value, index| {
        const name = try definition_core.json.string(value);
        if (definition_plan.parameter_declarations.find(name) == null) {
            return error.UnknownOperationParameter;
        }
        names[index] = try allocator.dupe(u8, name);
        initialized += 1;
    }
    std.sort.heap([]u8, names, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    if (names.len > 1) {
        for (names[1..], 1..) |name, index| {
            if (std.mem.eql(u8, names[index - 1], name)) {
                return error.DuplicateEventParameter;
            }
        }
    }
    return names;
}

fn compileEventField(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !EventField {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(object, &.{
        "field",
        "input_field",
        "literal",
        "sequence_text_prefix",
        "unix_seconds",
        "derived",
    });
    try definition_core.json.requireFields(object, &.{"field"});
    const field = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "field"),
    );
    errdefer allocator.free(field);
    try definition_core.json.safeIdentifier(field, 128);
    if (eventFieldSourceCount(object) != 1) {
        return error.InvalidEventFieldSource;
    }
    var source = try compileEventFieldSource(allocator, object);
    errdefer source.deinit(allocator);
    try validateDecodedEventFieldSource(allocator, source);
    return .{ .field = field, .source = source };
}

fn eventFieldSourceCount(object: std.json.ObjectMap) usize {
    var source_count: usize = 0;
    source_count += @intFromBool(object.get("input_field") != null);
    source_count += @intFromBool(object.get("literal") != null);
    source_count += @intFromBool(object.get("sequence_text_prefix") != null);
    source_count += @intFromBool(object.get("unix_seconds") != null);
    source_count += @intFromBool(object.get("derived") != null);
    return source_count;
}

fn compileEventFieldSource(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !EventFieldSource {
    if (object.get("input_field")) |value| {
        return .{ .input_field = try allocator.dupe(
            u8,
            try definition_core.json.string(value),
        ) };
    }
    if (object.get("literal")) |value| {
        return .{ .literal = try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            value,
        ) };
    }
    if (object.get("sequence_text_prefix")) |value| {
        return .{ .sequence_text_prefix = try allocator.dupe(
            u8,
            try definition_core.json.string(value),
        ) };
    }
    if (object.get("derived")) |value| {
        return .{ .derived = try allocator.dupe(
            u8,
            try definition_core.json.string(value),
        ) };
    }
    if (try definition_core.json.boolean(
        object.get("unix_seconds").?,
    )) return .unix_seconds;
    return error.InvalidEventUnixSecondsSource;
}

fn compileRequestLiterals(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) ![]RequestLiteral {
    const values = try definition_core.json.array(raw);
    if (values.items.len > 64) {
        return error.InvalidEventRequestLiteralCount;
    }
    const literals = try allocator.alloc(RequestLiteral, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (literals[0..initialized]) |*literal| {
            literal.deinit(allocator);
        }
        allocator.free(literals);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "field", "literal" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "field", "literal" },
        );
        const field = try allocator.dupe(
            u8,
            try definition_core.json.requiredString(object, "field"),
        );
        errdefer allocator.free(field);
        try definition_core.json.safeIdentifier(field, 128);
        const literal =
            try definition_core.canonical_json.canonicalJsonAlloc(
                allocator,
                try definition_core.json.field(object, "literal"),
            );
        errdefer allocator.free(literal);
        if (literal.len > 4096) return error.EventLiteralTooLarge;
        try validateCanonicalScalar(allocator, literal);
        literals[index] = .{ .field = field, .literal = literal };
        initialized += 1;
    }
    std.sort.heap(RequestLiteral, literals, {}, struct {
        fn lessThan(
            _: void,
            left: RequestLiteral,
            right: RequestLiteral,
        ) bool {
            return std.mem.lessThan(u8, left.field, right.field);
        }
    }.lessThan);
    return literals;
}

fn decodeRequestLiterals(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]RequestLiteral {
    const count = try decoder.readCount(64);
    const literals = try allocator.alloc(RequestLiteral, count);
    var initialized: usize = 0;
    errdefer {
        for (literals[0..initialized]) |*literal| {
            literal.deinit(allocator);
        }
        allocator.free(literals);
    }
    for (literals, 0..) |*literal, index| {
        const field = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(field);
        try definition_core.json.safeIdentifier(field, 128);
        if (index != 0 and
            std.mem.order(
                u8,
                literals[index - 1].field,
                field,
            ) != .lt)
        {
            return error.EventRequestLiteralsNotSorted;
        }
        const value = try decoder.readBytesAlloc(allocator, 4096);
        errdefer allocator.free(value);
        try validateCanonicalScalar(allocator, value);
        literal.* = .{ .field = field, .literal = value };
        initialized += 1;
    }
    return literals;
}

fn validateCanonicalScalar(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    switch (parsed.value) {
        .null, .bool, .integer, .float, .string => {},
        .array, .object, .number_string => {
            return error.EventLiteralMustBeScalar;
        },
    }
    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        parsed.value,
    );
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) {
        return error.EventLiteralNotCanonical;
    }
}

fn validateEventMaterialization(
    allocator: std.mem.Allocator,
    event: *const EventMaterialization,
) !void {
    try definition_core.json.safeIdentifier(event.body_input_field, 128);
    if (event.fields.len == 0 or event.fields.len > 64) {
        return error.InvalidEventMaterializationFields;
    }
    for (event.fields, 0..) |field, index| {
        try definition_core.json.safeIdentifier(field.field, 128);
        if (std.mem.eql(u8, field.field, event.body_input_field)) {
            return error.EventInputFieldCollision;
        }
        if (index != 0 and
            std.mem.order(u8, event.fields[index - 1].field, field.field) != .lt)
        {
            return error.EventMaterializationFieldsNotSorted;
        }
        switch (field.source) {
            .input_field => |value| {
                try definition_core.json.safeIdentifier(value, 128);
                if (std.mem.eql(u8, value, event.body_input_field)) {
                    return error.EventInputFieldCollision;
                }
                for (event.fields[0..index]) |prior| switch (prior.source) {
                    .input_field => |prior_value| {
                        if (std.mem.eql(u8, prior_value, value)) {
                            return error.DuplicateEventInputField;
                        }
                    },
                    else => {},
                };
            },
            .literal => |value| try validateCanonicalScalar(allocator, value),
            .sequence_text_prefix => |value| {
                if (!std.unicode.utf8ValidateSlice(value) or value.len > 128) {
                    return error.InvalidEventSequencePrefix;
                }
            },
            .unix_seconds => {},
            .derived => |value| {
                try definition_core.json.safeIdentifier(value, 128);
            },
        }
    }
    try validateRequestLiterals(
        event,
        error.EventInputFieldCollision,
        error.DuplicateEventInputField,
        error.EventRequestLiteralsNotSorted,
        error.EventLiteralTooLarge,
    );
    try validateEventMaterializationExtensions(event);
    try validateEventMaterializationLayout(event);
}

fn validateCachedEventMaterialization(
    event: *const EventMaterialization,
) !void {
    try definition_core.json.safeIdentifier(event.body_input_field, 128);
    if (event.fields.len == 0 or event.fields.len > 64) {
        return error.CacheStoragePlanMismatch;
    }
    for (event.fields, 0..) |field, index| {
        try definition_core.json.safeIdentifier(field.field, 128);
        if (std.mem.eql(u8, field.field, event.body_input_field) or
            (index != 0 and
                std.mem.order(
                    u8,
                    event.fields[index - 1].field,
                    field.field,
                ) != .lt))
        {
            return error.CacheStoragePlanMismatch;
        }
        switch (field.source) {
            .input_field => |value| {
                try definition_core.json.safeIdentifier(value, 128);
                if (std.mem.eql(u8, value, event.body_input_field)) {
                    return error.CacheStoragePlanMismatch;
                }
                for (event.fields[0..index]) |prior| switch (prior.source) {
                    .input_field => |prior_value| {
                        if (std.mem.eql(u8, prior_value, value)) {
                            return error.CacheStoragePlanMismatch;
                        }
                    },
                    else => {},
                };
            },
            .literal => |value| {
                if (value.len == 0 or value.len > 4096) {
                    return error.CacheStoragePlanMismatch;
                }
            },
            .sequence_text_prefix => |value| {
                if (!std.unicode.utf8ValidateSlice(value) or value.len > 128) {
                    return error.CacheStoragePlanMismatch;
                }
            },
            .unix_seconds => {},
            .derived => |value| {
                try definition_core.json.safeIdentifier(value, 128);
            },
        }
    }
    try validateRequestLiterals(
        event,
        error.CacheStoragePlanMismatch,
        error.CacheStoragePlanMismatch,
        error.CacheStoragePlanMismatch,
        error.CacheStoragePlanMismatch,
    );
    validateEventMaterializationExtensions(event) catch
        return error.CacheStoragePlanMismatch;
    validateEventMaterializationLayout(event) catch
        return error.CacheStoragePlanMismatch;
}

fn validateEventMaterializationLayout(
    event: *const EventMaterialization,
) !void {
    switch (event.mode) {
        .chained => {
            if (event.field_order.len != 0 or event.body_order.len != 0) {
                return error.ChainedEventHasDeclaredLayout;
            }
        },
        .plain => {
            if (event.field_order.len != event.fields.len + 1) {
                return error.EventMaterializationFieldCoverageMismatch;
            }
            var body_count: usize = 0;
            for (event.field_order) |name| {
                if (std.mem.eql(u8, name, event.body_input_field)) {
                    body_count += 1;
                } else if (findEventFieldLinear(event.fields, name) == null) {
                    return error.EventMaterializationFieldCoverageMismatch;
                }
            }
            if (body_count != 1) {
                return error.EventMaterializationFieldCoverageMismatch;
            }
            for (event.fields) |field| {
                if (!containsName(event.field_order, field.field)) {
                    return error.EventMaterializationFieldCoverageMismatch;
                }
                if (field.source == .sequence_text_prefix) {
                    return error.PlainEventRequiresProtocolState;
                }
            }
            for (event.body_fields) |field| {
                if (!containsName(event.body_order, field.field)) {
                    return error.EventBodyFieldCoverageMismatch;
                }
                switch (field.source) {
                    .parameter_sha256, .state_value => {
                        return error.PlainEventRequiresProtocolState;
                    },
                    .generated_sha256,
                    .request_input,
                    .literal_mapping,
                    .derived,
                    => {},
                }
            }
        },
    }
}

fn containsName(names: []const []u8, expected: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

fn findEventFieldLinear(
    fields: []const EventField,
    name: []const u8,
) ?*const EventField {
    for (fields) |*field| {
        if (std.mem.eql(u8, field.field, name)) return field;
    }
    return null;
}

fn validateEventMaterializationExtensions(
    event: *const EventMaterialization,
) !void {
    if (event.generate.len > 16 or event.derive.len > 16 or
        event.object_orders.len > 16 or
        event.body_fields.len > 64 or
        event.forbidden_parameters.len > 64)
    {
        return error.InvalidEventMaterializationBounds;
    }
    try validateEventObjectOrders(event.object_orders);
    try validateEventGenerations(event.generate);
    try validateEventDerivations(event.generate, event.derive);
    if (event.idempotency) |*idempotency| {
        try validateEventIdempotency(event, idempotency);
    }
    try validateEventBodyFields(event.body_fields);
    try validateForbiddenEventParameters(event.forbidden_parameters);
}

fn validateEventObjectOrders(
    orders: []const EventObjectOrder,
) !void {
    for (orders, 0..) |*order, index| {
        if (order.pointer.segments.len == 0 or order.fields.len == 0 or
            order.fields.len > 64)
        {
            return error.InvalidEventObjectOrder;
        }
        for (order.fields, 0..) |field, field_index| {
            try definition_core.json.safeIdentifier(field, 128);
            for (order.fields[0..field_index]) |prior| {
                if (std.mem.eql(u8, prior, field)) {
                    return error.DuplicateEventLayoutField;
                }
            }
        }
        if (index != 0 and
            std.mem.order(
                u8,
                orders[index - 1].pointer.raw,
                order.pointer.raw,
            ) != .lt)
        {
            return error.EventObjectOrdersNotSorted;
        }
    }
}

fn validateEventGenerations(
    generate: []const SecureTokenGeneration,
) !void {
    for (generate, 0..) |*item, index| {
        try validateSecureTokenGeneration(item);
        if (index != 0 and
            std.mem.order(
                u8,
                generate[index - 1].name,
                item.name,
            ) != .lt)
        {
            return error.EventGenerationsNotSorted;
        }
    }
}

fn validateEventDerivations(
    generate: []const SecureTokenGeneration,
    derive: []const EventDerivation,
) !void {
    for (derive, 0..) |*item, index| {
        try validateEventDerivation(item);
        for (generate) |generated| {
            if (std.mem.eql(u8, generated.name, item.name)) {
                return error.DuplicateEventGeneration;
            }
        }
        for (derive[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, item.name)) {
                return error.DuplicateEventGeneration;
            }
        }
        try validateEventDerivationReferences(item, derive[0..index]);
    }
}

fn validateEventBodyFields(fields: []const EventBodyField) !void {
    for (fields, 0..) |*field, index| {
        try validateEventBodyField(field);
        if (index != 0 and
            std.mem.order(
                u8,
                fields[index - 1].field,
                field.field,
            ) != .lt)
        {
            return error.EventBodyFieldsNotSorted;
        }
    }
}

fn validateForbiddenEventParameters(names: []const []u8) !void {
    for (names, 0..) |name, index| {
        try definition_core.json.safeIdentifier(name, 128);
        if (index != 0 and
            std.mem.order(u8, names[index - 1], name) != .lt)
        {
            return error.EventParameterNamesNotSorted;
        }
    }
}

fn validateEventMaterializationAgainstDefinition(
    event: *const EventMaterialization,
    definition_plan: *const definition.Plan,
) !void {
    if (!definition_plan.requires(.event_materialization)) {
        return error.UndeclaredArtifactOperator;
    }
    if (event.generate.len != 0 and
        !definition_plan.requires(.secure_token))
    {
        return error.UndeclaredArtifactOperator;
    }
    try validateEventIdempotencyDefinition(event, definition_plan);
    try validateEventDerivationOperators(event.derive, definition_plan);
    try validateEventDerivedFields(event.fields, event.derive);
    try validateEventBodyFieldDefinitions(
        event,
        definition_plan,
    );
    for (event.forbidden_parameters) |name| {
        if (definition_plan.parameter_declarations.find(name) == null) {
            return error.EventForbiddenParameterMissing;
        }
    }
}

fn validateEventIdempotencyDefinition(
    event: *const EventMaterialization,
    definition_plan: *const definition.Plan,
) !void {
    if (event.idempotency) |idempotency| {
        if (!definition_plan.requires(.idempotency_key)) {
            return error.UndeclaredArtifactOperator;
        }
        if (idempotency.bypass_parameter) |name| {
            const declaration =
                definition_plan.parameter_declarations.find(name) orelse
                return error.EventIdempotencyBypassParameterMissing;
            if (declaration.kind != .boolean) {
                return error.EventIdempotencyBypassMustBeBoolean;
            }
        }
    }
}

fn validateEventDerivationOperators(
    derivations: []const EventDerivation,
    definition_plan: *const definition.Plan,
) !void {
    for (derivations) |item| switch (item.source) {
        .input_text => {},
        .utc_timestamp => {
            if (!definition_plan.requires(.timestamp)) {
                return error.UndeclaredArtifactOperator;
            }
        },
        .sha1 => {
            if (!definition_plan.requires(.sha1)) {
                return error.UndeclaredArtifactOperator;
            }
        },
        .sha256 => {
            if (!definition_plan.requires(.sha256)) {
                return error.UndeclaredArtifactOperator;
            }
        },
        .concat => {
            if (!definition_plan.requires(.composite_identity)) {
                return error.UndeclaredArtifactOperator;
            }
        },
        .monotonic_identity => {
            if (!definition_plan.requires(.monotonic_identity) or
                !definition_plan.requires(.reducer))
            {
                return error.UndeclaredArtifactOperator;
            }
        },
    };
}

fn validateEventDerivedFields(
    fields: []const EventField,
    derivations: []const EventDerivation,
) !void {
    for (fields) |field| switch (field.source) {
        .derived => |name| {
            if (findEventDerivation(derivations, name) == null) {
                return error.EventDerivationDependencyMissing;
            }
        },
        else => {},
    };
}

fn validateEventBodyFieldDefinitions(
    event: *const EventMaterialization,
    definition_plan: *const definition.Plan,
) !void {
    for (event.body_fields) |field| switch (field.source) {
        .generated_sha256 => |name| {
            if (!definition_plan.requires(.sha256) or
                findSecureTokenGeneration(event.generate, name) == null)
            {
                return error.EventBodyGenerationMissing;
            }
        },
        .parameter_sha256 => |source| {
            const declaration =
                definition_plan.parameter_declarations.find(
                    source.parameter,
                ) orelse return error.EventBodyParameterMissing;
            if (!definition_plan.requires(.sha256) or
                declaration.kind == .integer or
                declaration.kind == .boolean)
            {
                return error.EventBodyParameterMissing;
            }
        },
        .state_value => {
            if (!definition_plan.requires(.reducer)) {
                return error.UndeclaredArtifactOperator;
            }
        },
        .derived => |name| {
            if (findEventDerivation(event.derive, name) == null) {
                return error.EventDerivationDependencyMissing;
            }
        },
        .request_input, .literal_mapping => {},
    };
}

fn validateEventIdempotency(
    event: *const EventMaterialization,
    idempotency: *const EventIdempotency,
) !void {
    if (event.mode != .plain) {
        return error.EventIdempotencyRequiresPlainMaterialization;
    }
    try definition_core.json.safeIdentifier(idempotency.derived, 128);
    const item = findEventDerivation(
        event.derive,
        idempotency.derived,
    ) orelse return error.EventIdempotencyDerivationMissing;
    switch (item.source) {
        .sha1, .sha256 => |digest| {
            if (digest.encoding != .hex) {
                return error.EventIdempotencyDerivationNotSafeIdentifier;
            }
            for (digest.fragments) |fragment| {
                switch (fragment) {
                    .derived => {
                        return error.EventIdempotencyDerivationNotInputBound;
                    },
                    else => {},
                }
            }
        },
        else => return error.EventIdempotencyDerivationNotDigest,
    }
    if (idempotency.bypass_parameter) |name| {
        try definition_core.json.safeIdentifier(name, 128);
    }
}

fn validateSecureTokenGeneration(
    item: *const SecureTokenGeneration,
) !void {
    try definition_core.json.safeIdentifier(item.name, 128);
    if (!std.unicode.utf8ValidateSlice(item.prefix) or
        item.prefix.len > 64 or
        std.mem.indexOfScalar(u8, item.prefix, 0) != null or
        item.byte_count < 16 or
        item.byte_count > 64)
    {
        return error.SecureTokenGenerationInvalid;
    }
    for (item.prefix) |byte| {
        if (byte < 0x21 or byte > 0x7e) {
            return error.SecureTokenPrefixInvalid;
        }
    }
}

fn validateEventDerivation(item: *const EventDerivation) !void {
    try definition_core.json.safeIdentifier(item.name, 128);
    switch (item.source) {
        .input_text => |pointer| {
            if (pointer.raw.len == 0 or pointer.raw.len > 1024) {
                return error.InvalidJsonPointer;
            }
        },
        .utc_timestamp => {},
        .sha1 => |config| try validateEventDigestDerivation(config, 40),
        .sha256 => |config| try validateEventDigestDerivation(config, 64),
        .concat => |config| {
            if (config.fragments.len == 0 or config.fragments.len > 64 or
                config.max_bytes == 0 or
                config.max_bytes > 16 * 1024 * 1024)
            {
                return error.InvalidEventDerivation;
            }
            try validateEventDerivationFragments(config.fragments);
        },
        .monotonic_identity => |config| {
            if (config.prefix.len == 0 or config.prefix.len > 64 or
                config.width == 0 or config.width > 18 or
                !std.unicode.utf8ValidateSlice(config.prefix) or
                std.mem.indexOfScalar(u8, config.prefix, 0) != null)
            {
                return error.InvalidEventMonotonicIdentity;
            }
        },
    }
}

fn validateEventDigestDerivation(
    config: EventDigestDerivation,
    maximum_hex_bytes: u16,
) !void {
    if (config.fragments.len == 0 or config.fragments.len > 64 or
        config.max_bytes == 0 or
        config.max_bytes > 16 * 1024 * 1024)
    {
        return error.InvalidEventDerivation;
    }
    if (config.prefix_bytes) |count| {
        if (config.encoding != .hex or count == 0 or
            count > maximum_hex_bytes)
        {
            return error.InvalidEventDigestPrefix;
        }
    }
    try validateEventDerivationFragments(config.fragments);
}

fn validateEventDerivationFragments(
    fragments: []const EventDerivationFragment,
) !void {
    for (fragments) |fragment| switch (fragment) {
        .literal => |value| {
            if (value.len > 4096 or !std.unicode.utf8ValidateSlice(value)) {
                return error.InvalidEventDerivationLiteral;
            }
        },
        .input_text => |source| {
            if (source.pointer.raw.len == 0 or
                source.pointer.raw.len > 1024)
            {
                return error.InvalidJsonPointer;
            }
        },
        .input_json, .canonical_input => |pointer| {
            if (pointer.raw.len == 0 or pointer.raw.len > 1024) {
                return error.InvalidJsonPointer;
            }
        },
        .derived => |reference| {
            try definition_core.json.safeIdentifier(reference.name, 128);
            if (reference.prefix_bytes) |count| {
                if (count == 0 or count > 4096) {
                    return error.InvalidEventDerivedPrefix;
                }
            }
        },
    };
}

fn validateEventBodyField(field: *const EventBodyField) !void {
    try definition_core.json.safeIdentifier(field.field, 128);
    switch (field.source) {
        .generated_sha256 => |name| {
            try definition_core.json.safeIdentifier(name, 128);
        },
        .parameter_sha256 => |source| {
            try definition_core.json.safeIdentifier(source.parameter, 128);
            try validateStateValueSource(&source.expected_state);
        },
        .state_value => |source| try validateStateValueSource(&source),
        .request_input => |name| {
            try definition_core.json.safeIdentifier(name, 128);
        },
        .literal_mapping => |source| {
            if (source.request_literal.len == 0 or
                source.request_literal.len > 4096 or
                source.stored_literal.len == 0 or
                source.stored_literal.len > 4096)
            {
                return error.EventLiteralTooLarge;
            }
            if (!std.unicode.utf8ValidateSlice(source.request_literal) or
                !std.unicode.utf8ValidateSlice(source.stored_literal))
            {
                return error.EventLiteralNotCanonical;
            }
        },
        .derived => |name| {
            try definition_core.json.safeIdentifier(name, 128);
        },
    }
}

fn validateStateValueSource(source: *const StateValueSource) !void {
    try definition_core.json.safeIdentifier(source.register, 128);
    if (source.pointer.raw.len > 1024) {
        return error.EventStatePointerTooLarge;
    }
}

fn findSecureTokenGeneration(
    items: []const SecureTokenGeneration,
    name: []const u8,
) ?*const SecureTokenGeneration {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, items[mid].name, name)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return &items[mid],
        }
    }
    return null;
}

fn findEventDerivation(
    items: []const EventDerivation,
    name: []const u8,
) ?*const EventDerivation {
    for (items) |*item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn validateRequestLiterals(
    event: *const EventMaterialization,
    collision_error: anyerror,
    duplicate_error: anyerror,
    order_error: anyerror,
    bounds_error: anyerror,
) !void {
    if (event.request_literals.len > 64) return bounds_error;
    for (event.request_literals, 0..) |literal, index| {
        try definition_core.json.safeIdentifier(literal.field, 128);
        if (literal.literal.len == 0 or literal.literal.len > 4096) {
            return bounds_error;
        }
        if (std.mem.eql(
            u8,
            literal.field,
            event.body_input_field,
        )) return collision_error;
        if (index != 0 and
            std.mem.order(
                u8,
                event.request_literals[index - 1].field,
                literal.field,
            ) != .lt)
        {
            return order_error;
        }
        for (event.fields) |field| switch (field.source) {
            .input_field => |input_field| {
                if (std.mem.eql(u8, literal.field, input_field)) {
                    return duplicate_error;
                }
            },
            else => {},
        };
    }
}

fn deinitRequestLiterals(
    allocator: std.mem.Allocator,
    literals: []RequestLiteral,
) void {
    for (literals) |*literal| literal.deinit(allocator);
    allocator.free(literals);
}

fn deinitSecureTokenGenerations(
    allocator: std.mem.Allocator,
    items: []SecureTokenGeneration,
) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitEventDerivations(
    allocator: std.mem.Allocator,
    items: []EventDerivation,
) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitEventDerivationFragments(
    allocator: std.mem.Allocator,
    fragments: []EventDerivationFragment,
) void {
    for (fragments) |*fragment| fragment.deinit(allocator);
    allocator.free(fragments);
}

fn deinitEventBodyFields(
    allocator: std.mem.Allocator,
    fields: []EventBodyField,
) void {
    for (fields) |*field| field.deinit(allocator);
    allocator.free(fields);
}

fn deinitEventObjectOrders(
    allocator: std.mem.Allocator,
    orders: []EventObjectOrder,
) void {
    for (orders) |*order| order.deinit(allocator);
    allocator.free(orders);
}

fn deinitNames(
    allocator: std.mem.Allocator,
    names: [][]u8,
) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn optionalParameterName(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
    field: []const u8,
) !?[]u8 {
    const raw = object.get(field) orelse return null;
    const name = try definition_core.json.string(raw);
    const declaration = definition_plan.parameter_declarations.find(name) orelse
        return error.UnknownOperationParameter;
    if (std.mem.eql(u8, field, "expected_revision_param") and
        declaration.kind != .digest)
    {
        return error.ExpectedRevisionParameterMustBeDigest;
    }
    if (std.mem.eql(u8, field, "idempotency_param")) {
        if (!definition_plan.requires(.idempotency_key)) {
            return error.UndeclaredArtifactOperator;
        }
        if (declaration.kind != .safe_identifier) {
            return error.IdempotencyParameterMustBeSafeIdentifier;
        }
    }
    return try allocator.dupe(u8, name);
}

fn compileParameterBindings(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) ![]ParameterBinding {
    const raw = object.get("parameter_bindings") orelse
        return allocator.alloc(ParameterBinding, 0);
    if (!definition_plan.requires(.path_format)) {
        return error.UndeclaredArtifactOperator;
    }
    const values = try definition_core.json.array(raw);
    if (values.items.len > 64) {
        return error.TooManyEffectParameterBindings;
    }
    const bindings = try allocator.alloc(ParameterBinding, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (bindings[0..initialized]) |*binding| {
            binding.deinit(allocator);
        }
        allocator.free(bindings);
    }
    for (values.items) |value| {
        bindings[initialized] = try compileParameterBinding(
            allocator,
            definition_plan,
            try definition_core.json.object(value),
        );
        initialized += 1;
    }
    std.sort.heap(ParameterBinding, bindings, {}, parameterBindingLessThan);
    try validateParameterBindings(bindings);
    return bindings;
}

fn compileParameterBinding(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    binding: std.json.ObjectMap,
) !ParameterBinding {
    try definition_core.json.requireExactKeys(
        binding,
        &.{ "parameter", "path" },
    );
    try definition_core.json.requireFields(
        binding,
        &.{ "parameter", "path" },
    );
    const parameter_name =
        try definition_core.json.requiredString(binding, "parameter");
    const declaration =
        definition_plan.parameter_declarations.find(parameter_name) orelse
        return error.UnknownOperationParameter;
    switch (declaration.kind) {
        .string,
        .digest,
        .timestamp,
        .safe_identifier,
        .relative_path,
        => {},
        .integer, .boolean => {
            return error.EffectParameterBindingRequiresText;
        },
    }
    const parameter = try allocator.dupe(u8, parameter_name);
    errdefer allocator.free(parameter);
    return .{
        .parameter = parameter,
        .input_pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.requiredString(binding, "path"),
        ),
    };
}

fn parameterBindingLessThan(
    _: void,
    left: ParameterBinding,
    right: ParameterBinding,
) bool {
    return std.mem.lessThan(u8, left.parameter, right.parameter);
}

fn compilePathSegments(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    path: []const u8,
) ![]PathSegment {
    try validateStoragePathTemplateText(path);
    var segments: std.ArrayList(PathSegment) = .empty;
    errdefer {
        for (segments.items) |*segment| segment.deinit(allocator);
        segments.deinit(allocator);
    }
    var dynamic = false;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |component| {
        if (segments.items.len >= 128) {
            return error.StoragePathSegmentBoundsExceeded;
        }
        if (component.len == 0) return error.InvalidStoragePathTemplate;
        const segment = try compilePathSegment(
            allocator,
            definition_plan,
            component,
        );
        errdefer {
            var owned = segment;
            owned.deinit(allocator);
        }
        dynamic = dynamic or segment.kind == .parameter;
        try segments.append(allocator, segment);
    }
    if (dynamic and !definition_plan.requires(.path_format)) {
        return error.UndeclaredArtifactOperator;
    }
    if (!dynamic) try validateLogicalSlotPath(path);
    const owned = try segments.toOwnedSlice(allocator);
    errdefer deinitPathSegments(allocator, owned);
    try validateEncodedPathTemplate(allocator, path, owned);
    return owned;
}

fn validateStoragePathTemplateText(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or
        std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, 0) != null or
        std.mem.indexOfScalar(u8, path, '\\') != null or
        path[path.len - 1] == '/')
    {
        return error.InvalidStoragePathTemplate;
    }
}

fn compilePathSegment(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    component: []const u8,
) !PathSegment {
    const parameterized = component.len >= 3 and
        component[0] == '{' and
        component[component.len - 1] == '}';
    if (!parameterized) {
        if (std.mem.indexOfScalar(u8, component, '{') != null or
            std.mem.indexOfScalar(u8, component, '}') != null)
        {
            return error.InvalidStoragePathTemplate;
        }
        try validateLiteralPathSegment(component);
        return .{
            .kind = .literal,
            .text = try allocator.dupe(u8, component),
        };
    }
    const name = component[1 .. component.len - 1];
    try definition_core.json.safeIdentifier(name, 128);
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return error.InvalidStoragePathParameter;
    }
    const declaration =
        definition_plan.parameter_declarations.find(name) orelse
        return error.UnknownStoragePathParameter;
    if (declaration.kind != .safe_identifier) {
        return error.StoragePathParameterMustBeSafeIdentifier;
    }
    return .{
        .kind = .parameter,
        .text = try allocator.dupe(u8, name),
    };
}

fn validateEncodedPathTemplate(
    allocator: std.mem.Allocator,
    expected: []const u8,
    segments: []const PathSegment,
) !void {
    if (segments.len == 0 or expected.len == 0 or expected.len > 4096 or
        std.fs.path.isAbsolute(expected) or
        std.mem.indexOfScalar(u8, expected, 0) != null or
        std.mem.indexOfScalar(u8, expected, '\\') != null)
    {
        return error.InvalidStoragePathTemplate;
    }
    if (segments[0].kind == .literal) {
        const first = segments[0].text;
        if (first[0] == '.' or
            std.ascii.eqlIgnoreCase(first, "transactions") or
            std.ascii.eqlIgnoreCase(first, "bindings"))
        {
            return error.ReservedStoragePath;
        }
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (segments, 0..) |segment, index| {
        if (index != 0) try output.writer.writeByte('/');
        switch (segment.kind) {
            .literal => try output.writer.writeAll(segment.text),
            .parameter => try output.writer.print(
                "{{{s}}}",
                .{segment.text},
            ),
        }
    }
    if (!std.mem.eql(u8, expected, output.written())) {
        return error.InvalidStoragePathTemplate;
    }
}

fn validatePathSegment(kind: PathSegmentKind, text: []const u8) !void {
    switch (kind) {
        .literal => try validateLiteralPathSegment(text),
        .parameter => {
            try definition_core.json.safeIdentifier(text, 128);
            if (std.mem.indexOfScalar(u8, text, '/') != null) {
                return error.InvalidStoragePathParameter;
            }
        },
    }
}

fn validateLiteralPathSegment(component: []const u8) !void {
    if (component.len == 0 or
        std.mem.eql(u8, component, ".") or
        std.mem.eql(u8, component, ".."))
    {
        return error.InvalidStoragePathTemplate;
    }
    for (component) |byte| if (byte < 0x20 or byte == 0x7f) {
        return error.InvalidStoragePathTemplate;
    };
}

fn pathIsParameterized(segments: []const PathSegment) bool {
    for (segments) |segment| {
        if (segment.kind == .parameter) return true;
    }
    return false;
}

pub fn slotIsParameterized(slot: Slot) bool {
    return pathIsParameterized(slot.path_segments);
}

fn resolvePathAlloc(
    allocator: std.mem.Allocator,
    segments: []const PathSegment,
    parameters: *const definition_core.parameters.Bindings,
    generated: []const document.Value,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (segments, 0..) |segment, index| {
        if (index != 0) try output.writer.writeByte('/');
        switch (segment.kind) {
            .literal => try output.writer.writeAll(segment.text),
            .parameter => {
                const value = pathParameter(
                    parameters,
                    generated,
                    segment.text,
                ) orelse
                    return error.MissingStoragePathParameter;
                if (std.mem.indexOfScalar(u8, value, '/') != null) {
                    return error.InvalidStoragePathParameter;
                }
                try validateLiteralPathSegment(value);
                try output.writer.writeAll(value);
            },
        }
    }
    if (output.written().len > 4096) {
        return error.StoragePathBoundsExceeded;
    }
    try validateLogicalSlotPath(output.written());
    return output.toOwnedSlice();
}

fn pathParameter(
    parameters: *const definition_core.parameters.Bindings,
    generated: []const document.Value,
    name: []const u8,
) ?[]const u8 {
    for (parameters.items) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return switch (binding.value) {
            .safe_identifier => |value| value,
            else => null,
        };
    }
    for (generated) |value| {
        if (std.mem.eql(u8, value.name, name)) return value.value;
    }
    return null;
}

pub fn resolveSlotPathAlloc(
    allocator: std.mem.Allocator,
    slot: Slot,
    parameters: *const definition_core.parameters.Bindings,
    generated: []const document.Value,
) ![]u8 {
    return resolvePathAlloc(
        allocator,
        slot.path_segments,
        parameters,
        generated,
    );
}

pub fn enumerateMatchingPathsAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    slot: Slot,
    max_paths: usize,
) ![][]u8 {
    if (!std.fs.path.isAbsolute(repo_root)) {
        return error.RepositoryRootNotAbsolute;
    }
    if (max_paths == 0) return error.StoragePathEnumerationBoundsExceeded;
    const ledger_root = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger" },
    );
    defer allocator.free(ledger_root);
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    try enumeratePathSegments(
        allocator,
        ledger_root,
        "",
        slot.path_segments,
        0,
        max_paths,
        &paths,
    );
    std.sort.heap([]u8, paths.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return paths.toOwnedSlice(allocator);
}

fn enumeratePathSegments(
    allocator: std.mem.Allocator,
    absolute_parent: []const u8,
    relative_parent: []const u8,
    segments: []const PathSegment,
    segment_index: usize,
    max_paths: usize,
    paths: *std.ArrayList([]u8),
) !void {
    if (segment_index >= segments.len) return;
    const frames = try allocator.alloc(
        PathEnumerationFrame,
        segments.len - segment_index,
    );
    defer allocator.free(frames);
    var frame_count: usize = 1;
    frames[0] = try initialPathEnumerationFrame(
        allocator,
        absolute_parent,
        relative_parent,
        segment_index,
    );
    errdefer deinitPathEnumerationFrames(
        allocator,
        frames[0..frame_count],
    );
    while (frame_count != 0) {
        const frame = &frames[frame_count - 1];
        switch (frame.state) {
            .ready => try advanceReadyPathEnumeration(
                allocator,
                frame,
                segments,
                max_paths,
                paths,
                &frame_count,
            ),
            .parameter => try advanceParameterPathEnumeration(
                allocator,
                frames,
                &frame_count,
                segments,
                max_paths,
                paths,
            ),
        }
    }
}

const PathEnumerationParameter = struct {
    directory: std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
};

const PathEnumerationState = union(enum) {
    ready,
    parameter: PathEnumerationParameter,
};

const PathEnumerationFrame = struct {
    absolute_parent: []u8,
    relative_parent: []u8,
    segment_index: usize,
    state: PathEnumerationState = .ready,

    fn deinit(
        self: *PathEnumerationFrame,
        allocator: std.mem.Allocator,
    ) void {
        if (self.state == .parameter) {
            self.state.parameter.directory.close(storageIo());
        }
        allocator.free(self.absolute_parent);
        allocator.free(self.relative_parent);
        self.* = undefined;
    }
};

fn storageIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn initialPathEnumerationFrame(
    allocator: std.mem.Allocator,
    absolute_parent: []const u8,
    relative_parent: []const u8,
    segment_index: usize,
) !PathEnumerationFrame {
    const absolute = try allocator.dupe(u8, absolute_parent);
    errdefer allocator.free(absolute);
    return .{
        .absolute_parent = absolute,
        .relative_parent = try allocator.dupe(u8, relative_parent),
        .segment_index = segment_index,
    };
}

fn advanceReadyPathEnumeration(
    allocator: std.mem.Allocator,
    frame: *PathEnumerationFrame,
    segments: []const PathSegment,
    max_paths: usize,
    paths: *std.ArrayList([]u8),
    frame_count: *usize,
) !void {
    const segment = segments[frame.segment_index];
    if (segment.kind == .parameter) {
        var directory = std.Io.Dir.openDirAbsolute(
            storageIo(),
            frame.absolute_parent,
            .{ .iterate = true, .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                frame.deinit(allocator);
                frame_count.* -= 1;
                return;
            },
            else => return err,
        };
        frame.state = .{ .parameter = .{
            .directory = directory,
            .iterator = directory.iterate(),
        } };
        return;
    }
    var child = try childPathEnumerationFrame(
        allocator,
        frame,
        segment.text,
    );
    errdefer child.deinit(allocator);
    const last = frame.segment_index + 1 == segments.len;
    frame.deinit(allocator);
    if (last) {
        frame_count.* -= 1;
        try appendLiteralEnumerationPath(
            allocator,
            &child,
            max_paths,
            paths,
        );
        child.deinit(allocator);
        return;
    }
    frame.* = child;
}

fn advanceParameterPathEnumeration(
    allocator: std.mem.Allocator,
    frames: []PathEnumerationFrame,
    frame_count: *usize,
    segments: []const PathSegment,
    max_paths: usize,
    paths: *std.ArrayList([]u8),
) !void {
    const frame = &frames[frame_count.* - 1];
    const parameter = &frame.state.parameter;
    while (try parameter.iterator.next(storageIo())) |entry| {
        definition_core.json.safeIdentifier(entry.name, 128) catch continue;
        if (std.mem.indexOfScalar(u8, entry.name, '/') != null) continue;
        const stat = parameter.directory.statFile(
            storageIo(),
            entry.name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkStorageSlot;
        const last = frame.segment_index + 1 == segments.len;
        if (last and stat.kind != .file) continue;
        if (!last and stat.kind != .directory) continue;
        var child = try childPathEnumerationFrame(
            allocator,
            frame,
            entry.name,
        );
        errdefer child.deinit(allocator);
        if (last) {
            try appendEnumeratedPath(
                allocator,
                paths,
                child.relative_parent,
                max_paths,
            );
            child.deinit(allocator);
            continue;
        }
        if (frame_count.* == frames.len) {
            return error.StoragePathSegmentBoundsExceeded;
        }
        frames[frame_count.*] = child;
        frame_count.* += 1;
        return;
    }
    frame.deinit(allocator);
    frame_count.* -= 1;
}

fn childPathEnumerationFrame(
    allocator: std.mem.Allocator,
    parent: *const PathEnumerationFrame,
    name: []const u8,
) !PathEnumerationFrame {
    const absolute = try std.fs.path.join(
        allocator,
        &.{ parent.absolute_parent, name },
    );
    errdefer allocator.free(absolute);
    const relative = if (parent.relative_parent.len == 0)
        try allocator.dupe(u8, name)
    else
        try std.fs.path.join(
            allocator,
            &.{ parent.relative_parent, name },
        );
    return .{
        .absolute_parent = absolute,
        .relative_parent = relative,
        .segment_index = parent.segment_index + 1,
    };
}

fn appendLiteralEnumerationPath(
    allocator: std.mem.Allocator,
    child: *const PathEnumerationFrame,
    max_paths: usize,
    paths: *std.ArrayList([]u8),
) !void {
    const stat = std.Io.Dir.cwd().statFile(
        storageIo(),
        child.absolute_parent,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkStorageSlot;
    if (stat.kind != .file) return;
    try appendEnumeratedPath(
        allocator,
        paths,
        child.relative_parent,
        max_paths,
    );
}

fn deinitPathEnumerationFrames(
    allocator: std.mem.Allocator,
    frames: []PathEnumerationFrame,
) void {
    for (frames) |*frame| frame.deinit(allocator);
}

fn appendEnumeratedPath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
    path: []const u8,
    max_paths: usize,
) !void {
    if (paths.items.len >= max_paths) {
        return error.StoragePathEnumerationBoundsExceeded;
    }
    try validateLogicalSlotPath(path);
    try paths.append(allocator, try allocator.dupe(u8, path));
}

fn validateLogicalSlotPath(path: []const u8) !void {
    try definition_core.json.repositoryRelativePath(path, false);
    const first_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const first = path[0..first_end];
    if (first[0] == '.' or std.ascii.eqlIgnoreCase(first, "transactions") or
        std.ascii.eqlIgnoreCase(first, "bindings"))
    {
        return error.ReservedStoragePath;
    }
}

fn deinitPathSegments(
    allocator: std.mem.Allocator,
    segments: []PathSegment,
) void {
    for (segments) |*segment| segment.deinit(allocator);
    allocator.free(segments);
}

fn findSlot(slots: []const Slot, name: []const u8) ?usize {
    for (slots, 0..) |slot, index| {
        if (std.mem.eql(u8, slot.name, name)) return index;
    }
    return null;
}

fn findInput(inputs: []const definition.Input, name: []const u8) ?usize {
    for (inputs, 0..) |input, index| {
        if (std.mem.eql(u8, input.name, name)) return index;
    }
    return null;
}

fn deinitSlots(allocator: std.mem.Allocator, slots: []Slot) void {
    for (slots) |*slot| slot.deinit(allocator);
    allocator.free(slots);
}

fn resolveForAllocationFailure(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    var resolved = resolve(allocator, plan, parameters) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer resolved.deinit(allocator);
}

const storage_protocol_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/protocol\",\"owner\":\"example\",\"requires\":{" ++
    "\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"atomic-transaction\",\"compare-and-append\",\"create-new\"]}," ++
    "\"parameters\":{\"revision\":{\"type\":\"digest\",\"required\":false}}," ++
    "\"inputs\":{\"event\":{\"codec\":\"json\",\"max_bytes\":4096}," ++
    "\"document\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[]},\"shape\":{},\"constraints\":{\"laws\":[]}," ++
    "\"identity\":{},\"storage\":{\"kind\":\"event-log\",\"slots\":{" ++
    "\"events\":{\"path\":\"example/events.jsonl\",\"kind\":\"event-log\"," ++
    "\"codec\":\"jsonl\",\"max_bytes\":65536},\"document\":{" ++
    "\"path\":\"example/document.json\",\"kind\":\"document\"," ++
    "\"codec\":\"json\",\"max_bytes\":4096}}},\"operations\":{\"capture\":{" ++
    "\"op\":\"atomic-transaction\",\"effects\":[{\"op\":\"create-new\"," ++
    "\"slot\":\"document\",\"input\":\"document\"},{" ++
    "\"op\":\"compare-and-append\",\"slot\":\"events\",\"input\":\"event\"," ++
    "\"expected_revision_param\":\"revision\"}]}},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":8192,\"max_store_bytes\":65536," ++
    "\"max_records\":100,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":16}}";

const storage_parameterized_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/parameterized\",\"owner\":\"example\",\"requires\":{" ++
    "\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[\"path-format\"]}," ++
    "\"parameters\":{\"stream\":{" ++
    "\"type\":\"safe_identifier\",\"required\":true}},\"inputs\":{" ++
    "\"event\":{\"codec\":\"json\",\"max_bytes\":1024}}," ++
    "\"canonicalization\":{},\"shape\":{},\"constraints\":{\"laws\":[]},\"identity\":{}," ++
    "\"storage\":{\"kind\":\"event-log\",\"slots\":{\"events\":{" ++
    "\"path\":\"{stream}/events.jsonl\",\"codec\":\"jsonl\"," ++
    "\"max_bytes\":4096}}},\"operations\":{},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":1024,\"max_store_bytes\":4096," ++
    "\"max_records\":10,\"max_output_bytes\":1024,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":4}}";

const storage_reserved_definition =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/reserved\",\"owner\":\"example\",\"requires\":{" ++
    "\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[]}," ++
    "\"parameters\":{},\"inputs\":{\"event\":{" ++
    "\"codec\":\"json\",\"max_bytes\":1024}},\"canonicalization\":{}," ++
    "\"shape\":{},\"constraints\":{\"laws\":[]},\"identity\":{}," ++
    "\"storage\":{\"kind\":\"event-log\",\"slots\":{\"events\":{" ++
    "\"path\":\".definitions/events.jsonl\",\"codec\":\"jsonl\"," ++
    "\"max_bytes\":1024}}},\"operations\":{},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":1024,\"max_store_bytes\":1024," ++
    "\"max_records\":10,\"max_output_bytes\":1024,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":4}}";

const StorageTestPlan = struct {
    tmp: std.testing.TmpDir,
    closure: definition_core.closure.Closure,
    definition_plan: definition.Plan,
    plan: Plan,

    fn init(source: []const u8) !StorageTestPlan {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "definition.json",
            .data = source,
        });
        var closure = try definition_core.closure.loadFromDir(
            std.testing.allocator,
            &tmp.dir,
            "definition.json",
            .{},
        );
        errdefer closure.deinit(std.testing.allocator);
        var definition_plan = try definition.compile(
            std.testing.allocator,
            &closure,
            "definition.json",
        );
        errdefer definition_plan.deinit(std.testing.allocator);
        return .{
            .tmp = tmp,
            .closure = closure,
            .definition_plan = definition_plan,
            .plan = try compile(std.testing.allocator, &definition_plan),
        };
    }

    fn deinit(self: *StorageTestPlan) void {
        self.plan.deinit(std.testing.allocator);
        self.definition_plan.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn expectStorageCacheRoundTrip(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    parameters: *const definition_core.parameters.Bindings,
    expected_path: []const u8,
) !void {
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try validateCachePlan(&cached, definition_plan);
    var resolved = try resolve(
        std.testing.allocator,
        &cached,
        parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        expected_path,
        resolved.slot(0).relative_path,
    );
}

fn expectStoragePathParameterRejections(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    var nested = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "nested/value" }},
    );
    defer nested.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidStoragePathParameter,
        resolve(std.testing.allocator, plan, &nested),
    );
    var reserved = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = ".definitions" }},
    );
    defer reserved.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ReservedStoragePath,
        resolve(std.testing.allocator, plan, &reserved),
    );
}

fn expectStorageCompileError(
    expected: anyerror,
    source: []const u8,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "definition.json",
        .data = source,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "definition.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "definition.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    try std.testing.expectError(
        expected,
        compile(std.testing.allocator, &definition_plan),
    );
}

test "storage compiler binds generic slots and atomic effects" {
    var test_plan = try StorageTestPlan.init(storage_protocol_definition);
    defer test_plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), test_plan.plan.slots.len);
    try std.testing.expectEqual(@as(usize, 1), test_plan.plan.operations.len);
    try std.testing.expect(test_plan.plan.operations[0].atomic);
    try std.testing.expectEqual(
        @as(usize, 2),
        test_plan.plan.operations[0].effects.len,
    );
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(&test_plan.plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try std.testing.expectEqual(
        test_plan.plan.storage_kind,
        cached.storage_kind,
    );
    try std.testing.expectEqual(test_plan.plan.slots.len, cached.slots.len);
    try std.testing.expectEqual(
        test_plan.plan.operations[0].effects.len,
        cached.operations[0].effects.len,
    );
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &test_plan.definition_plan.parameter_declarations,
        &.{},
    );
    defer parameters.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var resolved = try resolve(
        failing.allocator(),
        &test_plan.plan,
        &parameters,
    );
    defer resolved.deinit(failing.allocator());
}

test "storage path parameters compile once and resolve as safe components" {
    var test_plan = try StorageTestPlan.init(
        storage_parameterized_definition,
    );
    defer test_plan.deinit();
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &test_plan.definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "tenant-1" }},
    );
    defer parameters.deinit(std.testing.allocator);
    var resolved = try resolve(
        std.testing.allocator,
        &test_plan.plan,
        &parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "tenant-1/events.jsonl",
        resolved.slot(0).relative_path,
    );
    try std.testing.expect(pathTemplateMatches(
        test_plan.plan.slots[0],
        resolved.slot(0).relative_path,
    ));
    try std.testing.expect(!pathTemplateMatches(
        test_plan.plan.slots[0],
        "tenant-1/other.jsonl",
    ));
    try expectStorageCacheRoundTrip(
        &test_plan.plan,
        &test_plan.definition_plan,
        &parameters,
        resolved.slot(0).relative_path,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveForAllocationFailure,
        .{ &test_plan.plan, &parameters },
    );
    try expectStoragePathParameterRejections(
        &test_plan.plan,
        &test_plan.definition_plan,
    );
}

test "storage compiler rejects reserved paths and implicit multi effects" {
    try expectStorageCompileError(
        error.ReservedStoragePath,
        storage_reserved_definition,
    );
}
