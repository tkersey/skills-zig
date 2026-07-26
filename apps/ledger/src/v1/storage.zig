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

pub const Slot = struct {
    name: []u8,
    relative_path: []u8,
    kind: SlotKind,
    codec: definition.Codec,
    max_bytes: usize,

    fn deinit(self: *Slot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.relative_path);
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

pub const Effect = struct {
    kind: EffectKind,
    slot_index: u16,
    input_index: u8,
    expected_revision_parameter: ?[]u8,
    idempotency_parameter: ?[]u8,

    fn deinit(self: *Effect, allocator: std.mem.Allocator) void {
        if (self.expected_revision_parameter) |name| allocator.free(name);
        if (self.idempotency_parameter) |name| allocator.free(name);
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
        definition_plan.storage_kind,
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

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(1);
    try encoder.writeEnum(plan.storage_kind);
    try encoder.writeCount(plan.slots.len);
    for (plan.slots) |slot| {
        try encoder.writeBytes(slot.name);
        try encoder.writeBytes(slot.relative_path);
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
        }
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 1) {
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
        try validateLogicalSlotPath(relative_path);
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
            if (kind == .bind_existing and
                (expected_revision_parameter != null or
                    idempotency_parameter != null))
            {
                return error.BindingEffectHasAdmissionParameter;
            }
            effect.* = .{
                .kind = kind,
                .slot_index = slot_index,
                .input_index = input_index,
                .expected_revision_parameter = expected_revision_parameter,
                .idempotency_parameter = idempotency_parameter,
            };
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
    storage_kind: definition.StorageKind,
    object: std.json.ObjectMap,
) ![]Slot {
    if (storage_kind == .pure) {
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
        const relative_path = try definition_core.json.requiredString(slot, "path");
        try validateLogicalSlotPath(relative_path);
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
    return .{
        .kind = kind,
        .slot_index = @intCast(slot_index),
        .input_index = @intCast(input_index),
        .expected_revision_parameter = expected_revision_parameter,
        .idempotency_parameter = idempotency_parameter,
    };
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
}

test "storage compiler rejects reserved paths and implicit multi effects" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"event-log\",\"slots\":{\"events\":{\"path\":\".definitions/events.jsonl\",\"codec\":\"jsonl\",\"max_bytes\":1024}}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.ReservedStoragePath,
        compileSlots(std.testing.allocator, .event_log, parsed.value.object),
    );
}
