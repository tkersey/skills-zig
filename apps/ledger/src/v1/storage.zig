const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");

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

    fn deinit(self: *EventFieldSource, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .input_field => |value| allocator.free(value),
            .literal => |value| allocator.free(value),
            .sequence_text_prefix => |value| allocator.free(value),
            .unix_seconds => {},
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

pub const EventMaterialization = struct {
    body_input_field: []u8,
    fields: []EventField,

    fn deinit(self: *EventMaterialization, allocator: std.mem.Allocator) void {
        allocator.free(self.body_input_field);
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

pub const Effect = struct {
    kind: EffectKind,
    slot_index: u16,
    input_index: u8,
    expected_revision_parameter: ?[]u8,
    idempotency_parameter: ?[]u8,
    event: ?EventMaterialization,

    fn deinit(self: *Effect, allocator: std.mem.Allocator) void {
        if (self.expected_revision_parameter) |name| allocator.free(name);
        if (self.idempotency_parameter) |name| allocator.free(name);
        if (self.event) |*event| event.deinit(allocator);
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
    try encoder.writeU16(3);
    try encoder.writeEnum(plan.storage_kind);
    try encoder.writeCount(plan.slots.len);
    for (plan.slots) |slot| {
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
    try encoder.writeCount(plan.operations.len);
    for (plan.operations) |operation| {
        try encoder.writeBytes(operation.name);
        try encoder.writeBool(operation.atomic);
        try encoder.writeCount(operation.effects.len);
        for (operation.effects) |effect| {
            try encoder.writeEnum(effect.kind);
            try encoder.writeU16(effect.slot_index);
            try encoder.writeByte(effect.input_index);
            try encoder.writeOptionalBytes(
                effect.expected_revision_parameter,
            );
            try encoder.writeOptionalBytes(effect.idempotency_parameter);
            try encoder.writeBool(effect.event != null);
            if (effect.event) |event| {
                try encoder.writeBytes(event.body_input_field);
                try encoder.writeCount(event.fields.len);
                for (event.fields) |field| {
                    try encoder.writeBytes(field.field);
                    try encoder.writeEnum(std.meta.activeTag(field.source));
                    switch (field.source) {
                        .input_field => |value| try encoder.writeBytes(value),
                        .literal => |value| try encoder.writeBytes(value),
                        .sequence_text_prefix => |value| {
                            try encoder.writeBytes(value);
                        },
                        .unix_seconds => {},
                    }
                }
            }
        }
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 3) {
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

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    if (plan.storage_kind != definition_plan.storage_kind) {
        return error.CacheStoragePlanMismatch;
    }
    for (plan.slots) |slot| {
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
    for (plan.operations) |operation| {
        for (operation.effects) |effect| {
            if (effect.input_index >= definition_plan.inputs.len) {
                return error.CacheStoragePlanMismatch;
            }
            const slot = plan.slots[effect.slot_index];
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
            if ((effect.kind == .compare_append or
                (effect.kind == .bind_existing and
                    slot.kind == .event_log)) and
                input.codec != .json)
            {
                return error.CacheStoragePlanMismatch;
            }
            if (effect.kind != .compare_append and
                !(effect.kind == .bind_existing and
                    slot.kind == .event_log) and
                input.codec != slot.codec)
            {
                return error.CacheStoragePlanMismatch;
            }
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
            if (effect.event) |*event| {
                if (effect.kind != .compare_append and
                    effect.kind != .bind_existing)
                {
                    return error.CacheStoragePlanMismatch;
                }
                try validateCachedEventMaterialization(event);
            }
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
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try definition_core.json.safeIdentifier(name, 128);
        if (index != 0 and
            std.mem.order(u8, slots[index - 1].name, name) != .lt)
        {
            return error.CacheStorageSlotsNotSorted;
        }
        const relative_path = try decoder.readBytesAlloc(
            allocator,
            4096,
        );
        errdefer allocator.free(relative_path);
        const segment_count = try decoder.readCount(128);
        if (segment_count == 0) return error.InvalidStoragePathTemplate;
        const path_segments = try allocator.alloc(
            PathSegment,
            segment_count,
        );
        var segment_initialized: usize = 0;
        errdefer {
            for (path_segments[0..segment_initialized]) |*segment| {
                segment.deinit(allocator);
            }
            allocator.free(path_segments);
        }
        for (path_segments) |*segment| {
            const kind = try decoder.readEnum(PathSegmentKind);
            const text = try decoder.readBytesAlloc(
                allocator,
                if (kind == .parameter) 128 else 4096,
            );
            errdefer allocator.free(text);
            try validatePathSegment(kind, text);
            segment.* = .{ .kind = kind, .text = text };
            segment_initialized += 1;
        }
        try validateEncodedPathTemplate(
            allocator,
            relative_path,
            path_segments,
        );
        const kind = try decoder.readEnum(SlotKind);
        const codec = try decoder.readEnum(definition.Codec);
        if (kind == .event_log and codec != .jsonl) {
            return error.EventLogSlotRequiresJsonl;
        }
        if (kind == .document and codec == .jsonl) {
            return error.JsonlSlotRequiresEventLog;
        }
        const max_bytes = try decoder.readUsize();
        if (max_bytes == 0 or max_bytes > 4 * 1024 * 1024 * 1024) {
            return error.StorageSlotBoundsExceeded;
        }
        for (slots[0..index]) |prior| {
            if (std.ascii.eqlIgnoreCase(
                prior.relative_path,
                relative_path,
            )) return error.StoragePathCaseAmbiguity;
        }
        slot.* = .{
            .name = name,
            .relative_path = relative_path,
            .path_segments = path_segments,
            .kind = kind,
            .codec = codec,
            .max_bytes = max_bytes,
        };
        initialized += 1;
    }
    return slots;
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
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try definition_core.json.safeIdentifier(name, 128);
        if (index != 0 and
            std.mem.order(u8, operations[index - 1].name, name) != .lt)
        {
            return error.CacheStorageOperationsNotSorted;
        }
        const atomic = try decoder.readBool();
        const effect_count = try decoder.readCount(64);
        if (effect_count == 0) return error.InvalidOperationEffectCount;
        const effects = try allocator.alloc(Effect, effect_count);
        var effect_initialized: usize = 0;
        errdefer {
            for (effects[0..effect_initialized]) |*effect| {
                effect.deinit(allocator);
            }
            allocator.free(effects);
        }
        for (effects) |*effect| {
            const kind = try decoder.readEnum(EffectKind);
            const slot_index = try decoder.readU16();
            if (slot_index >= slots.len) return error.CacheStorageIndexInvalid;
            const input_index = try decoder.readByte();
            const expected_revision_parameter =
                try decoder.readOptionalBytesAlloc(allocator, 128);
            errdefer if (expected_revision_parameter) |value| {
                allocator.free(value);
            };
            if (expected_revision_parameter) |value| {
                try definition_core.json.safeIdentifier(value, 128);
            }
            const idempotency_parameter =
                try decoder.readOptionalBytesAlloc(allocator, 128);
            errdefer if (idempotency_parameter) |value| allocator.free(value);
            if (idempotency_parameter) |value| {
                try definition_core.json.safeIdentifier(value, 128);
            }
            var event = if (try decoder.readBool())
                try decodeEventMaterialization(allocator, decoder)
            else
                null;
            errdefer if (event) |*value| value.deinit(allocator);
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
            effect.* = .{
                .kind = kind,
                .slot_index = slot_index,
                .input_index = input_index,
                .expected_revision_parameter = expected_revision_parameter,
                .idempotency_parameter = idempotency_parameter,
                .event = event,
            };
            event = null;
            effect_initialized += 1;
        }
        try validateCachedOperation(effects, atomic);
        operation.* = .{
            .name = name,
            .atomic = atomic,
            .effects = effects,
        };
        initialized += 1;
    }
    return operations;
}

fn decodeEventMaterialization(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EventMaterialization {
    const body_input_field = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(body_input_field);
    try definition_core.json.safeIdentifier(body_input_field, 128);
    const field_count = try decoder.readCount(64);
    if (field_count == 0) return error.InvalidEventMaterializationFields;
    const fields = try allocator.alloc(EventField, field_count);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (fields, 0..) |*field, index| {
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try definition_core.json.safeIdentifier(name, 128);
        if (index != 0 and
            std.mem.order(u8, fields[index - 1].field, name) != .lt)
        {
            return error.EventMaterializationFieldsNotSorted;
        }
        const source_tag = try decoder.readEnum(
            std.meta.Tag(EventFieldSource),
        );
        var source: ?EventFieldSource = switch (source_tag) {
            .input_field => .{ .input_field = try decoder.readBytesAlloc(allocator, 128) },
            .literal => .{ .literal = try decoder.readBytesAlloc(allocator, 4096) },
            .sequence_text_prefix => .{ .sequence_text_prefix = try decoder.readBytesAlloc(allocator, 128) },
            .unix_seconds => .unix_seconds,
        };
        errdefer if (source) |*value| value.deinit(allocator);
        switch (source.?) {
            .input_field => |value| {
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
        field.* = .{ .field = name, .source = source.? };
        source = null;
        initialized += 1;
    }
    const result: EventMaterialization = .{
        .body_input_field = body_input_field,
        .fields = fields,
    };
    try validateEventMaterialization(allocator, &result);
    return result;
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
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        const slot = try definition_core.json.object(entry.value_ptr.*);
        try definition_core.json.requireExactKeys(slot, &.{
            "path",
            "kind",
            "codec",
            "max_bytes",
        });
        try definition_core.json.requireFields(slot, &.{
            "path",
            "codec",
            "max_bytes",
        });
        const relative_path = try definition_core.json.requiredString(
            slot,
            "path",
        );
        const path_segments = try compilePathSegments(
            allocator,
            definition_plan,
            relative_path,
        );
        errdefer deinitPathSegments(allocator, path_segments);
        const codec = try definition.Codec.parse(
            try definition_core.json.requiredString(slot, "codec"),
        );
        const kind: SlotKind = if (slot.get("kind")) |raw|
            try SlotKind.parse(try definition_core.json.string(raw))
        else if (codec == .jsonl)
            .event_log
        else
            .document;
        if (kind == .event_log and codec != .jsonl) {
            return error.EventLogSlotRequiresJsonl;
        }
        if (kind == .document and codec == .jsonl) {
            return error.JsonlSlotRequiresEventLog;
        }
        const max_bytes = try definition_core.json.unsigned(
            try definition_core.json.field(slot, "max_bytes"),
        );
        if (max_bytes == 0 or max_bytes > 4 * 1024 * 1024 * 1024) {
            return error.StorageSlotBoundsExceeded;
        }
        const owned_name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(owned_name);
        const owned_path = try allocator.dupe(u8, relative_path);
        errdefer allocator.free(owned_path);
        try slots.append(allocator, .{
            .name = owned_name,
            .relative_path = owned_path,
            .path_segments = path_segments,
            .kind = kind,
            .codec = codec,
            .max_bytes = max_bytes,
        });
    }
    std.mem.sort(Slot, slots.items, {}, struct {
        fn lessThan(_: void, left: Slot, right: Slot) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    for (slots.items, 0..) |left, index| {
        for (slots.items[index + 1 ..]) |right| {
            if (std.ascii.eqlIgnoreCase(left.relative_path, right.relative_path)) {
                return error.StoragePathCaseAmbiguity;
            }
        }
    }
    return slots.toOwnedSlice(allocator);
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
        try definition_core.json.requireExactKeys(object, &.{ "op", "effects" });
        const atomic = if (object.get("op")) |raw_operator| blk: {
            const operator = try definition.Operator.parse(
                try definition_core.json.string(raw_operator),
            );
            if (operator != .atomic_transaction) return error.UnsupportedOperationRoot;
            if (!definition_plan.requires(operator)) {
                return error.UndeclaredArtifactOperator;
            }
            break :blk true;
        } else false;
        const effects_value = object.get("effects") orelse return error.MissingOperationEffects;
        const effect_values = try definition_core.json.array(effects_value);
        if (effect_values.items.len == 0 or effect_values.items.len > 64) {
            return error.InvalidOperationEffectCount;
        }
        const effects = try allocator.alloc(Effect, effect_values.items.len);
        var initialized: usize = 0;
        errdefer {
            for (effects[0..initialized]) |*effect| effect.deinit(allocator);
            allocator.free(effects);
        }
        for (effect_values.items, 0..) |raw_effect, index| {
            effects[index] = try compileEffect(
                allocator,
                definition_plan,
                slots,
                raw_effect,
            );
            initialized += 1;
        }
        for (effects, 0..) |left, index| {
            for (effects[index + 1 ..]) |right| {
                if (left.slot_index == right.slot_index) {
                    return error.DuplicateOperationSlot;
                }
            }
        }
        var binding_effects: usize = 0;
        for (effects) |effect| if (effect.kind == .bind_existing) {
            binding_effects += 1;
        };
        if (binding_effects != 0 and binding_effects != effects.len) {
            return error.BindingOperationCannotMixEffects;
        }
        if (!atomic and effects.len > 1) return error.MultiEffectOperationMustBeAtomic;
        const owned_name = try allocator.dupe(u8, source.name);
        errdefer allocator.free(owned_name);
        try operations.append(allocator, .{
            .name = owned_name,
            .atomic = atomic,
            .effects = effects,
        });
    }
    return operations.toOwnedSlice(allocator);
}

fn compileEffect(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    slots: []const Slot,
    raw: std.json.Value,
) !Effect {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(object, &.{
        "op",
        "slot",
        "input",
        "expected_revision_param",
        "idempotency_param",
        "event",
    });
    try definition_core.json.requireFields(object, &.{ "op", "slot", "input" });
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
    if ((kind == .compare_append or
        (kind == .bind_existing and slots[slot_index].kind == .event_log)) and
        input_codec != .json)
    {
        return error.AppendInputMustBeJson;
    }
    if (kind != .compare_append and
        !(kind == .bind_existing and slots[slot_index].kind == .event_log) and
        input_codec != slots[slot_index].codec)
    {
        return error.StorageInputCodecMismatch;
    }
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
    if (kind == .bind_existing and
        (expected_revision_parameter != null or idempotency_parameter != null))
    {
        return error.BindingEffectHasAdmissionParameter;
    }
    var event = if (object.get("event")) |raw_event|
        try compileEventMaterialization(allocator, raw_event)
    else
        null;
    errdefer if (event) |*value| value.deinit(allocator);
    if (event != null and kind != .compare_append and kind != .bind_existing) {
        return error.EventMaterializationRequiresAppend;
    }
    return .{
        .kind = kind,
        .slot_index = @intCast(slot_index),
        .input_index = @intCast(input_index),
        .expected_revision_parameter = expected_revision_parameter,
        .idempotency_parameter = idempotency_parameter,
        .event = event,
    };
}

fn compileEventMaterialization(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !EventMaterialization {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "body_input_field", "fields" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "body_input_field", "fields" },
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
    std.mem.sort(EventField, fields, {}, struct {
        fn lessThan(_: void, left: EventField, right: EventField) bool {
            return std.mem.lessThan(u8, left.field, right.field);
        }
    }.lessThan);
    const result: EventMaterialization = .{
        .body_input_field = body_input_field,
        .fields = fields,
    };
    try validateEventMaterialization(allocator, &result);
    return result;
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
    });
    try definition_core.json.requireFields(object, &.{"field"});
    const field = try allocator.dupe(
        u8,
        try definition_core.json.requiredString(object, "field"),
    );
    errdefer allocator.free(field);
    try definition_core.json.safeIdentifier(field, 128);
    var source_count: usize = 0;
    source_count += @intFromBool(object.get("input_field") != null);
    source_count += @intFromBool(object.get("literal") != null);
    source_count += @intFromBool(object.get("sequence_text_prefix") != null);
    source_count += @intFromBool(object.get("unix_seconds") != null);
    if (source_count != 1) return error.InvalidEventFieldSource;
    var source: EventFieldSource = if (object.get("input_field")) |value|
        .{ .input_field = try allocator.dupe(
            u8,
            try definition_core.json.string(value),
        ) }
    else if (object.get("literal")) |value|
        .{ .literal = try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            value,
        ) }
    else if (object.get("sequence_text_prefix")) |value|
        .{ .sequence_text_prefix = try allocator.dupe(
            u8,
            try definition_core.json.string(value),
        ) }
    else if (try definition_core.json.boolean(
        object.get("unix_seconds").?,
    ))
        .unix_seconds
    else
        return error.InvalidEventUnixSecondsSource;
    errdefer source.deinit(allocator);
    switch (source) {
        .input_field => |value| {
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
    return .{ .field = field, .source = source };
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
        }
    }
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
        }
    }
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

fn compilePathSegments(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    path: []const u8,
) ![]PathSegment {
    if (path.len == 0 or path.len > 4096 or
        std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, 0) != null or
        std.mem.indexOfScalar(u8, path, '\\') != null or
        path[path.len - 1] == '/')
    {
        return error.InvalidStoragePathTemplate;
    }
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
        const kind: PathSegmentKind = if (component.len >= 3 and
            component[0] == '{' and
            component[component.len - 1] == '}')
        blk: {
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
            dynamic = true;
            break :blk .parameter;
        } else blk: {
            if (std.mem.indexOfScalar(u8, component, '{') != null or
                std.mem.indexOfScalar(u8, component, '}') != null)
            {
                return error.InvalidStoragePathTemplate;
            }
            try validateLiteralPathSegment(component);
            break :blk .literal;
        };
        const text = switch (kind) {
            .literal => component,
            .parameter => component[1 .. component.len - 1],
        };
        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);
        try segments.append(allocator, .{
            .kind = kind,
            .text = owned_text,
        });
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

fn resolvePathAlloc(
    allocator: std.mem.Allocator,
    segments: []const PathSegment,
    parameters: *const definition_core.parameters.Bindings,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (segments, 0..) |segment, index| {
        if (index != 0) try output.writer.writeByte('/');
        switch (segment.kind) {
            .literal => try output.writer.writeAll(segment.text),
            .parameter => {
                const value = pathParameter(parameters, segment.text) orelse
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
    name: []const u8,
) ?[]const u8 {
    for (parameters.items) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return switch (binding.value) {
            .safe_identifier => |value| value,
            else => null,
        };
    }
    return null;
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

test "storage compiler binds generic slots and atomic effects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/protocol","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["atomic-transaction","compare-and-append","create-new"]},"parameters":{"revision":{"type":"digest","required":false}},"inputs":{"event":{"codec":"json","max_bytes":4096},"document":{"codec":"json","max_bytes":4096}},"canonicalization":{"steps":[]},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536},"document":{"path":"example/document.json","kind":"document","codec":"json","max_bytes":4096}}},"operations":{"capture":{"op":"atomic-transaction","effects":[{"op":"create-new","slot":"document","input":"document"},{"op":"compare-and-append","slot":"events","input":"event","expected_revision_param":"revision"}]}},"projections":{},"bounds":{"max_input_bytes":8192,"max_store_bytes":65536,"max_records":100,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":16}}
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
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.slots.len);
    try std.testing.expectEqual(@as(usize, 1), plan.operations.len);
    try std.testing.expect(plan.operations[0].atomic);
    try std.testing.expectEqual(@as(usize, 2), plan.operations[0].effects.len);
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
    try std.testing.expectEqual(plan.storage_kind, cached.storage_kind);
    try std.testing.expectEqual(plan.slots.len, cached.slots.len);
    try std.testing.expectEqual(plan.operations.len, cached.operations.len);
    try std.testing.expectEqual(
        plan.operations[0].effects.len,
        cached.operations[0].effects.len,
    );
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer parameters.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var resolved = try resolve(
        failing.allocator(),
        &plan,
        &parameters,
    );
    defer resolved.deinit(failing.allocator());
}

test "storage path parameters compile once and resolve as safe components" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "parameterized.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/parameterized","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["path-format"]},"parameters":{"stream":{"type":"safe_identifier","required":true}},"inputs":{"event":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"{stream}/events.jsonl","codec":"jsonl","max_bytes":4096}}},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":4096,"max_records":10,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":4}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "parameterized.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "parameterized.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);
    var parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "tenant-1" }},
    );
    defer parameters.deinit(std.testing.allocator);
    var resolved = try resolve(
        std.testing.allocator,
        &plan,
        &parameters,
    );
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "tenant-1/events.jsonl",
        resolved.slot(0).relative_path,
    );
    try std.testing.expect(pathTemplateMatches(
        plan.slots[0],
        resolved.slot(0).relative_path,
    ));
    try std.testing.expect(!pathTemplateMatches(
        plan.slots[0],
        "tenant-1/other.jsonl",
    ));

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
    try validateCachePlan(&cached, &definition_plan);
    var cached_resolved = try resolve(
        std.testing.allocator,
        &cached,
        &parameters,
    );
    defer cached_resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        resolved.slot(0).relative_path,
        cached_resolved.slot(0).relative_path,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveForAllocationFailure,
        .{ &plan, &parameters },
    );

    var nested = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = "nested/value" }},
    );
    defer nested.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidStoragePathParameter,
        resolve(std.testing.allocator, &plan, &nested),
    );
    var reserved = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "stream", .raw_value = ".definitions" }},
    );
    defer reserved.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ReservedStoragePath,
        resolve(std.testing.allocator, &plan, &reserved),
    );
}

test "storage compiler rejects reserved paths and implicit multi effects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "reserved.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/reserved","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":[]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":1024}},"canonicalization":{},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":".definitions/events.jsonl","codec":"jsonl","max_bytes":1024}}},"operations":{},"projections":{},"bounds":{"max_input_bytes":1024,"max_store_bytes":1024,"max_records":10,"max_output_bytes":1024,"max_diagnostics":8,"max_reducer_states":4}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "reserved.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "reserved.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ReservedStoragePath,
        compile(std.testing.allocator, &definition_plan),
    );
}
