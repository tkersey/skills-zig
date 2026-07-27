const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const validation = @import("validation.zig");

const max_registers: usize = 1024;
const max_sets: usize = 1024;
const max_admissions: usize = 4096;
const max_actions: usize = 1024;
const max_stable_pointers: usize = 64;

const Register = struct {
    name: []u8,
    max_bytes: usize,

    fn deinit(self: *Register, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

const Source = union(enum) {
    event,
    register: u16,
};

const RetainedSet = struct {
    name: []u8,
    max_entries: usize,
    max_key_bytes: usize,
    max_bytes: usize,

    fn deinit(self: *RetainedSet, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

const SetPresence = enum {
    absent,
    present,
};

const SetGuardMode = enum {
    scalar,
    each,
};

const SetGuard = struct {
    set: u16,
    source: Source,
    pointer: definition_core.json_pointer.Pointer,
    presence: SetPresence,
    mode: SetGuardMode,

    fn deinit(self: *SetGuard, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

const SetAction = struct {
    target: u16,
    source: Source,
    pointer: definition_core.json_pointer.Pointer,

    fn deinit(self: *SetAction, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

const InsertAction = struct {
    target: u16,
    source: Source,
    pointer: definition_core.json_pointer.Pointer,

    fn deinit(self: *InsertAction, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

const UpsertAction = struct {
    target: u16,
    source: Source,
    collection: definition_core.json_pointer.Pointer,
    key: definition_core.json_pointer.Pointer,
    source_ref: definition_core.json_pointer.Pointer,
    predecessor_refs: definition_core.json_pointer.Pointer,
    stable: []definition_core.json_pointer.Pointer,
    max_entries: usize,
    max_key_bytes: usize,

    fn deinit(self: *UpsertAction, allocator: std.mem.Allocator) void {
        self.collection.deinit(allocator);
        self.key.deinit(allocator);
        self.source_ref.deinit(allocator);
        self.predecessor_refs.deinit(allocator);
        for (self.stable) |*pointer| pointer.deinit(allocator);
        allocator.free(self.stable);
        self.* = undefined;
    }
};

const Action = union(enum) {
    set: SetAction,
    clear: u16,
    insert: InsertAction,
    upsert: UpsertAction,

    fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .set => |*set| set.deinit(allocator),
            .insert => |*insert| insert.deinit(allocator),
            .upsert => |*upsert| upsert.deinit(allocator),
            .clear => {},
        }
        self.* = undefined;
    }
};

const Admission = struct {
    on: []u8,
    required: []u16,
    forbidden: []u16,
    set_guards: []SetGuard,
    validation_plan: validation.Plan,
    actions: []Action,

    fn deinit(self: *Admission, allocator: std.mem.Allocator) void {
        allocator.free(self.on);
        allocator.free(self.required);
        allocator.free(self.forbidden);
        for (self.set_guards) |*guard| guard.deinit(allocator);
        allocator.free(self.set_guards);
        self.validation_plan.deinit(allocator);
        for (self.actions) |*action| action.deinit(allocator);
        allocator.free(self.actions);
        self.* = undefined;
    }
};

pub const Plan = struct {
    event_kind: definition_core.json_pointer.Pointer,
    registers: []Register,
    sets: []RetainedSet,
    admissions: []Admission,
    layout_digest: [32]u8,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.event_kind.deinit(allocator);
        for (self.registers) |*register| register.deinit(allocator);
        allocator.free(self.registers);
        for (self.sets) |*set| set.deinit(allocator);
        allocator.free(self.sets);
        for (self.admissions) |*admission| admission.deinit(allocator);
        allocator.free(self.admissions);
        self.* = undefined;
    }
};

const OwnedValue = struct {
    bytes: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.parsed.deinit();
        self.* = undefined;
    }
};

const RetainedSetState = struct {
    entries: std.AutoHashMapUnmanaged([32]u8, []u8) = .empty,
    bytes: usize = 0,

    fn deinit(self: *RetainedSetState, allocator: std.mem.Allocator) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |key| allocator.free(key.*);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    fn contains(self: *const RetainedSetState, key: []const u8) !bool {
        const digest = retainedKeyDigest(key);
        const stored = self.entries.get(digest) orelse return false;
        if (!std.mem.eql(u8, stored, key)) {
            return error.RetainedSetDigestCollision;
        }
        return true;
    }

    fn insertAssumeCapacity(
        self: *RetainedSetState,
        key: []u8,
    ) void {
        const digest = retainedKeyDigest(key);
        self.entries.putAssumeCapacityNoClobber(digest, key);
        self.bytes += key.len;
    }
};

const NamedRegisterState = struct {
    name: []u8,
    value: ?OwnedValue = null,

    fn deinit(self: *NamedRegisterState, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.value) |*owned| owned.deinit(allocator);
        self.* = undefined;
    }
};

const NamedSetState = struct {
    name: []u8,
    value: RetainedSetState = .{},

    fn deinit(self: *NamedSetState, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const State = struct {
    registers: std.ArrayListUnmanaged(NamedRegisterState) = .empty,
    sets: std.ArrayListUnmanaged(NamedSetState) = .empty,
    register_map: []u16 = &.{},
    set_map: []u16 = &.{},
    active_layout_digest: [32]u8 = undefined,
    has_active_layout: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.registers.items) |*register| register.deinit(allocator);
        self.registers.deinit(allocator);
        for (self.sets.items) |*set| set.deinit(allocator);
        self.sets.deinit(allocator);
        if (self.register_map.len != 0) allocator.free(self.register_map);
        if (self.set_map.len != 0) allocator.free(self.set_map);
        self.* = undefined;
    }

    pub fn get(
        self: *const State,
        plan: *const Plan,
        name: []const u8,
    ) ?std.json.Value {
        const index = registerIndex(plan, name) orelse return null;
        return getByIndex(self, plan, index);
    }
};

pub fn hasRegister(plan: *const Plan, name: []const u8) bool {
    return findRegister(plan.registers, name) != null;
}

pub fn registerIndex(plan: *const Plan, name: []const u8) ?u16 {
    const index = findRegister(plan.registers, name) orelse return null;
    return std.math.cast(u16, index);
}

pub fn registerCount(plan: *const Plan) usize {
    return plan.registers.len;
}

pub fn getByIndex(
    state: *const State,
    plan: *const Plan,
    index: u16,
) ?std.json.Value {
    const plan_index: usize = index;
    if (plan_index >= plan.registers.len or
        plan_index >= state.register_map.len)
    {
        return null;
    }
    return if (registerStateConst(state, plan_index).value) |owned|
        owned.parsed.value
    else
        null;
}

pub fn isRetainedRule(
    allocator: std.mem.Allocator,
    rule: definition.Rule,
) !bool {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    const raw_mode = object.get("mode") orelse return false;
    return std.mem.eql(
        u8,
        try definition_core.json.string(raw_mode),
        "retained",
    );
}

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rule: definition.Rule,
    event_max_bytes: usize,
) !Plan {
    var parsed = try parseRule(allocator, rule);
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "mode", "event_kind", "registers", "sets", "admissions" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "op", "mode", "event_kind", "registers", "admissions" },
    );
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "op"),
        "reducer",
    ) or !std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "mode"),
        "retained",
    )) return error.RetainedReducerModeMismatch;
    var event_kind = try definition_core.json_pointer.compile(
        allocator,
        try definition_core.json.requiredString(object, "event_kind"),
    );
    errdefer event_kind.deinit(allocator);
    const registers = try compileRegisters(
        allocator,
        try definition_core.json.field(object, "registers"),
        definition_plan.bounds.max_reducer_states,
        definition_plan.bounds.max_store_bytes,
    );
    errdefer deinitRegisters(allocator, registers);
    const sets = if (object.get("sets")) |raw_sets|
        try compileSets(
            allocator,
            raw_sets,
            definition_plan.bounds.max_reducer_states,
            definition_plan.bounds.max_records,
            definition_plan.bounds.max_store_bytes,
        )
    else
        try allocator.alloc(RetainedSet, 0);
    errdefer deinitSets(allocator, sets);
    const admissions = try compileAdmissions(
        allocator,
        definition_plan,
        registers,
        sets,
        try definition_core.json.field(object, "admissions"),
        event_max_bytes,
    );
    errdefer deinitAdmissions(allocator, admissions);
    const result: Plan = .{
        .event_kind = event_kind,
        .registers = registers,
        .sets = sets,
        .admissions = admissions,
        .layout_digest = retainedLayoutDigest(registers, sets),
    };
    try validatePlan(&result, definition_plan, event_max_bytes);
    return result;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(3);
    try encoder.writeBytes(plan.event_kind.raw);
    try encoder.writeCount(plan.registers.len);
    for (plan.registers) |register| {
        try encoder.writeBytes(register.name);
        try encoder.writeUsize(register.max_bytes);
    }
    try encoder.writeCount(plan.sets.len);
    for (plan.sets) |set| {
        try encoder.writeBytes(set.name);
        try encoder.writeUsize(set.max_entries);
        try encoder.writeUsize(set.max_key_bytes);
        try encoder.writeUsize(set.max_bytes);
    }
    try encoder.writeCount(plan.admissions.len);
    for (plan.admissions) |admission| {
        try encoder.writeBytes(admission.on);
        try encodeIndexes(admission.required, encoder);
        try encodeIndexes(admission.forbidden, encoder);
        try encoder.writeCount(admission.set_guards.len);
        for (admission.set_guards) |guard| {
            try encoder.writeU16(guard.set);
            try encodeSource(guard.source, encoder);
            try encoder.writeBytes(guard.pointer.raw);
            try encoder.writeEnum(guard.presence);
            try encoder.writeEnum(guard.mode);
        }
        try validation.encodeCache(&admission.validation_plan, encoder);
        try encoder.writeCount(admission.actions.len);
        for (admission.actions) |action| switch (action) {
            .set => |set| {
                try encoder.writeByte(0);
                try encoder.writeU16(set.target);
                switch (set.source) {
                    .event => try encoder.writeByte(0),
                    .register => |index| {
                        try encoder.writeByte(1);
                        try encoder.writeU16(index);
                    },
                }
                try encoder.writeBytes(set.pointer.raw);
            },
            .clear => |target| {
                try encoder.writeByte(1);
                try encoder.writeU16(target);
            },
            .insert => |insert| {
                try encoder.writeByte(2);
                try encoder.writeU16(insert.target);
                try encodeSource(insert.source, encoder);
                try encoder.writeBytes(insert.pointer.raw);
            },
            .upsert => |upsert| {
                try encoder.writeByte(3);
                try encoder.writeU16(upsert.target);
                try encodeSource(upsert.source, encoder);
                try encoder.writeBytes(upsert.collection.raw);
                try encoder.writeBytes(upsert.key.raw);
                try encoder.writeBytes(upsert.source_ref.raw);
                try encoder.writeBytes(upsert.predecessor_refs.raw);
                try encoder.writeCount(upsert.stable.len);
                for (upsert.stable) |pointer| {
                    try encoder.writeBytes(pointer.raw);
                }
                try encoder.writeUsize(upsert.max_entries);
                try encoder.writeUsize(upsert.max_key_bytes);
            },
        };
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 3) {
        return error.LedgerStateReducerCacheVersionMismatch;
    }
    const raw_event_kind = try decoder.readBytesAlloc(allocator, 1024);
    defer allocator.free(raw_event_kind);
    var event_kind = try definition_core.json_pointer.compile(
        allocator,
        raw_event_kind,
    );
    errdefer event_kind.deinit(allocator);
    const register_count = try decoder.readCount(max_registers);
    if (register_count == 0) return error.InvalidRetainedRegisterCount;
    const registers = try allocator.alloc(Register, register_count);
    var registers_initialized: usize = 0;
    errdefer {
        for (registers[0..registers_initialized]) |*register| {
            register.deinit(allocator);
        }
        allocator.free(registers);
    }
    for (registers) |*register| {
        register.* = .{
            .name = try decoder.readBytesAlloc(allocator, 128),
            .max_bytes = try decoder.readUsize(),
        };
        registers_initialized += 1;
    }
    const set_count = try decoder.readCount(max_sets);
    const sets = try allocator.alloc(RetainedSet, set_count);
    var sets_initialized: usize = 0;
    errdefer {
        for (sets[0..sets_initialized]) |*set| set.deinit(allocator);
        allocator.free(sets);
    }
    for (sets) |*set| {
        var name: ?[]u8 = try decoder.readBytesAlloc(allocator, 128);
        errdefer if (name) |owned| allocator.free(owned);
        const max_entries = try decoder.readUsize();
        const max_key_bytes = try decoder.readUsize();
        const max_bytes = try decoder.readUsize();
        set.* = .{
            .name = name.?,
            .max_entries = max_entries,
            .max_key_bytes = max_key_bytes,
            .max_bytes = max_bytes,
        };
        name = null;
        sets_initialized += 1;
    }
    const admission_count = try decoder.readCount(max_admissions);
    if (admission_count == 0) return error.InvalidRetainedAdmissionCount;
    const admissions = try allocator.alloc(Admission, admission_count);
    var admissions_initialized: usize = 0;
    errdefer {
        for (admissions[0..admissions_initialized]) |*admission| {
            admission.deinit(allocator);
        }
        allocator.free(admissions);
    }
    for (admissions) |*admission| {
        const on = try decoder.readBytesAlloc(allocator, 256);
        errdefer allocator.free(on);
        const required = try decodeIndexes(
            allocator,
            decoder,
            register_count,
        );
        errdefer allocator.free(required);
        const forbidden = try decodeIndexes(
            allocator,
            decoder,
            register_count,
        );
        errdefer allocator.free(forbidden);
        const set_guards = try decodeSetGuards(
            allocator,
            decoder,
            register_count,
            set_count,
        );
        errdefer deinitSetGuards(allocator, set_guards);
        var validation_plan = try validation.decodeCache(
            allocator,
            decoder,
        );
        errdefer validation_plan.deinit(allocator);
        const action_count = try decoder.readCount(max_actions);
        const actions = try allocator.alloc(Action, action_count);
        var actions_initialized: usize = 0;
        errdefer {
            for (actions[0..actions_initialized]) |*action| {
                action.deinit(allocator);
            }
            allocator.free(actions);
        }
        for (actions) |*action| {
            action.* = switch (try decoder.readByte()) {
                0 => set: {
                    const target = try decoder.readU16();
                    const source: Source = switch (try decoder.readByte()) {
                        0 => .event,
                        1 => .{ .register = try decoder.readU16() },
                        else => return error.CacheStateActionSourceInvalid,
                    };
                    const raw_pointer = try decoder.readBytesAlloc(
                        allocator,
                        1024,
                    );
                    defer allocator.free(raw_pointer);
                    break :set .{ .set = .{
                        .target = target,
                        .source = source,
                        .pointer = try definition_core.json_pointer.compile(
                            allocator,
                            raw_pointer,
                        ),
                    } };
                },
                1 => .{ .clear = try decoder.readU16() },
                2 => .{ .insert = .{
                    .target = try decoder.readU16(),
                    .source = try decodeSource(decoder, register_count),
                    .pointer = try decodePointer(allocator, decoder),
                } },
                3 => upsert: {
                    const target = try decoder.readU16();
                    const source = try decodeSource(decoder, register_count);
                    var collection: ?definition_core.json_pointer.Pointer =
                        try decodePointer(allocator, decoder);
                    errdefer if (collection) |*owned| owned.deinit(allocator);
                    var key: ?definition_core.json_pointer.Pointer =
                        try decodePointer(allocator, decoder);
                    errdefer if (key) |*owned| owned.deinit(allocator);
                    var source_ref: ?definition_core.json_pointer.Pointer =
                        try decodePointer(allocator, decoder);
                    errdefer if (source_ref) |*owned| owned.deinit(allocator);
                    var predecessor_refs: ?definition_core.json_pointer.Pointer =
                        try decodePointer(allocator, decoder);
                    errdefer if (predecessor_refs) |*owned| {
                        owned.deinit(allocator);
                    };
                    const stable_count = try decoder.readCount(
                        max_stable_pointers,
                    );
                    const stable = try allocator.alloc(
                        definition_core.json_pointer.Pointer,
                        stable_count,
                    );
                    var stable_initialized: usize = 0;
                    errdefer {
                        for (stable[0..stable_initialized]) |*pointer| {
                            pointer.deinit(allocator);
                        }
                        allocator.free(stable);
                    }
                    for (stable) |*pointer| {
                        pointer.* = try decodePointer(allocator, decoder);
                        stable_initialized += 1;
                    }
                    const max_entries = try decoder.readUsize();
                    const max_key_bytes = try decoder.readUsize();
                    const result: Action = .{ .upsert = .{
                        .target = target,
                        .source = source,
                        .collection = collection.?,
                        .key = key.?,
                        .source_ref = source_ref.?,
                        .predecessor_refs = predecessor_refs.?,
                        .stable = stable,
                        .max_entries = max_entries,
                        .max_key_bytes = max_key_bytes,
                    } };
                    collection = null;
                    key = null;
                    source_ref = null;
                    predecessor_refs = null;
                    break :upsert result;
                },
                else => return error.CacheStateActionInvalid,
            };
            actions_initialized += 1;
        }
        admission.* = .{
            .on = on,
            .required = required,
            .forbidden = forbidden,
            .set_guards = set_guards,
            .validation_plan = validation_plan,
            .actions = actions,
        };
        admissions_initialized += 1;
    }
    return .{
        .event_kind = event_kind,
        .registers = registers,
        .sets = sets,
        .admissions = admissions,
        .layout_digest = retainedLayoutDigest(registers, sets),
    };
}

pub fn validatePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    event_max_bytes: usize,
) !void {
    if (!definition_plan.requires(.reducer) or
        plan.registers.len + plan.sets.len == 0 or
        plan.registers.len + plan.sets.len >
            definition_plan.bounds.max_reducer_states or
        plan.registers.len > max_registers or
        plan.sets.len > max_sets or
        plan.admissions.len == 0 or plan.admissions.len > max_admissions)
    {
        return error.InvalidRetainedReducerPlan;
    }
    for (plan.registers, 0..) |register, index| {
        try definition_core.json.safeIdentifier(register.name, 128);
        if (std.mem.eql(u8, register.name, "event") or
            register.max_bytes == 0 or
            register.max_bytes > definition_plan.bounds.max_store_bytes or
            (index != 0 and
                std.mem.order(
                    u8,
                    plan.registers[index - 1].name,
                    register.name,
                ) != .lt))
        {
            return error.InvalidRetainedReducerPlan;
        }
    }
    var retained_set_bytes: usize = 0;
    for (plan.sets, 0..) |set, index| {
        try definition_core.json.safeIdentifier(set.name, 128);
        retained_set_bytes = std.math.add(
            usize,
            retained_set_bytes,
            set.max_bytes,
        ) catch return error.InvalidRetainedReducerPlan;
        if (std.mem.eql(u8, set.name, "event") or
            findRegister(plan.registers, set.name) != null or
            set.max_entries == 0 or
            set.max_entries > definition_plan.bounds.max_records or
            set.max_key_bytes == 0 or
            set.max_key_bytes > set.max_bytes or
            set.max_bytes > definition_plan.bounds.max_store_bytes or
            (index != 0 and
                std.mem.order(
                    u8,
                    plan.sets[index - 1].name,
                    set.name,
                ) != .lt))
        {
            return error.InvalidRetainedReducerPlan;
        }
    }
    if (retained_set_bytes > definition_plan.bounds.max_store_bytes) {
        return error.InvalidRetainedReducerPlan;
    }
    for (plan.admissions, 0..) |admission, index| {
        try definition_core.json.safeIdentifier(admission.on, 256);
        try validateIndexes(admission.required, plan.registers.len);
        try validateIndexes(admission.forbidden, plan.registers.len);
        if (setsIntersect(admission.required, admission.forbidden)) {
            return error.ConflictingRetainedAdmissionState;
        }
        for (admission.set_guards, 0..) |guard, guard_index| {
            if (guard.set >= plan.sets.len) {
                return error.InvalidRetainedSetGuard;
            }
            try validateSource(
                guard.source,
                plan.registers.len,
                admission.required,
            );
            if (guard.pointer.raw.len > 1024) {
                return error.InvalidRetainedSetGuard;
            }
            for (admission.set_guards[0..guard_index]) |prior| {
                if (prior.set == guard.set and
                    sourceEqual(prior.source, guard.source) and
                    std.mem.eql(
                        u8,
                        prior.pointer.raw,
                        guard.pointer.raw,
                    ))
                {
                    if (prior.presence != guard.presence or
                        prior.mode != guard.mode)
                    {
                        return error.ConflictingRetainedSetGuard;
                    }
                    return error.DuplicateRetainedSetGuard;
                }
            }
        }
        try validation.validateEmbeddedCachePlan(
            &admission.validation_plan,
            definition_plan,
        );
        try validateAdmissionInputs(
            plan,
            &admission,
            event_max_bytes,
        );
        for (admission.actions, 0..) |action, action_index| {
            switch (action) {
                .set => |set| {
                    if (set.target >= plan.registers.len) {
                        return error.InvalidRetainedActionTarget;
                    }
                    if (set.source == .register and
                        set.source.register >= plan.registers.len)
                    {
                        return error.InvalidRetainedActionSource;
                    }
                    if (set.source == .register and
                        !containsIndex(
                            admission.required,
                            set.source.register,
                        ))
                    {
                        return error.RetainedActionSourceNotRequired;
                    }
                },
                .clear => |target| {
                    if (target >= plan.registers.len) {
                        return error.InvalidRetainedActionTarget;
                    }
                },
                .insert => |insert| {
                    if (insert.target >= plan.sets.len) {
                        return error.InvalidRetainedActionTarget;
                    }
                    try validateSource(
                        insert.source,
                        plan.registers.len,
                        admission.required,
                    );
                    if (insert.pointer.raw.len > 1024) {
                        return error.InvalidRetainedActionSource;
                    }
                },
                .upsert => |upsert| {
                    if (upsert.target >= plan.registers.len or
                        !containsIndex(admission.required, upsert.target))
                    {
                        return error.InvalidRetainedActionTarget;
                    }
                    try validateSource(
                        upsert.source,
                        plan.registers.len,
                        admission.required,
                    );
                    if (upsert.collection.raw.len > 1024 or
                        upsert.key.raw.len > 1024 or
                        upsert.source_ref.raw.len > 1024 or
                        upsert.predecessor_refs.raw.len > 1024 or
                        upsert.stable.len > max_stable_pointers or
                        upsert.max_entries == 0 or
                        upsert.max_entries >
                            definition_plan.bounds.max_records or
                        upsert.max_key_bytes == 0 or
                        upsert.max_key_bytes >
                            plan.registers[upsert.target].max_bytes)
                    {
                        return error.InvalidRetainedUpsertAction;
                    }
                    for (upsert.stable, 0..) |pointer, pointer_index| {
                        if (pointer.raw.len > 1024) {
                            return error.InvalidRetainedUpsertAction;
                        }
                        for (upsert.stable[0..pointer_index]) |prior| {
                            if (std.mem.eql(u8, prior.raw, pointer.raw)) {
                                return error.InvalidRetainedUpsertAction;
                            }
                        }
                    }
                },
            }
            for (admission.actions[0..action_index]) |prior| {
                if (actionsConflict(prior, action)) {
                    return error.DuplicateRetainedActionTarget;
                }
            }
        }
        for (plan.admissions[0..index]) |prior| {
            if (std.mem.eql(u8, prior.on, admission.on) and
                admissionsOverlap(prior, admission))
            {
                return error.AmbiguousRetainedAdmission;
            }
        }
    }
}

pub fn validateEventKinds(
    plan: *const Plan,
    event_kinds: []const []u8,
) !void {
    for (plan.admissions) |admission| {
        if (!containsString(event_kinds, admission.on)) {
            return error.UnknownRetainedAdmissionEventKind;
        }
    }
}

pub fn apply(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *State,
    event: std.json.Value,
) !void {
    try ensureState(allocator, plan, state);
    const kind_value = definition_core.json_pointer.lookup(
        event,
        plan.event_kind,
    ) orelse return error.RetainedEventKindMissing;
    const kind = try definition_core.json.string(kind_value);
    var selected: ?*const Admission = null;
    for (plan.admissions) |*admission| {
        if (!std.mem.eql(u8, admission.on, kind)) continue;
        if (!try preconditionsHold(plan, state, event, admission)) continue;
        if (selected != null) return error.AmbiguousRetainedAdmission;
        selected = admission;
    }
    const admission = selected orelse return error.IllegalRetainedTransition;
    const values = try allocator.alloc(
        validation.InputValue,
        1 + presentCount(plan, state),
    );
    defer allocator.free(values);
    values[0] = .{ .name = "event", .value = event };
    var value_index: usize = 1;
    for (plan.registers, 0..) |register, register_index| {
        if (registerState(state, register_index).value) |owned| {
            values[value_index] = .{
                .name = register.name,
                .value = owned.parsed.value,
            };
            value_index += 1;
        }
    }
    var execution = try validation.executeValues(
        allocator,
        &admission.validation_plan,
        values,
    );
    defer execution.deinit();
    if (!execution.isValid()) return error.ProtocolAdmissionRejected;
    try applyActionsAtomically(
        allocator,
        plan,
        state,
        event,
        admission.actions,
    );
}

fn compileRegisters(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    max_states: usize,
    max_store_bytes: usize,
) ![]Register {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or
        values.items.len > max_states or
        values.items.len > max_registers)
    {
        return error.InvalidRetainedRegisterCount;
    }
    const registers = try allocator.alloc(Register, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (registers[0..initialized]) |*register| {
            register.deinit(allocator);
        }
        allocator.free(registers);
    }
    for (values.items) |value| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "name", "max_bytes" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "name", "max_bytes" },
        );
        const name = try definition_core.json.requiredString(object, "name");
        try definition_core.json.safeIdentifier(name, 128);
        if (std.mem.eql(u8, name, "event")) {
            return error.ReservedRetainedRegisterName;
        }
        const max_bytes = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_bytes"),
        );
        if (max_bytes == 0 or max_bytes > max_store_bytes) {
            return error.RetainedRegisterBoundsExceeded;
        }
        registers[initialized] = .{
            .name = try allocator.dupe(u8, name),
            .max_bytes = max_bytes,
        };
        initialized += 1;
    }
    std.sort.heap(Register, registers, {}, struct {
        fn lessThan(_: void, left: Register, right: Register) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    for (registers[1..], 1..) |register, index| {
        if (std.mem.eql(u8, registers[index - 1].name, register.name)) {
            return error.DuplicateRetainedRegister;
        }
    }
    return registers;
}

fn compileSets(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    max_set_count: usize,
    max_entries: usize,
    max_store_bytes: usize,
) ![]RetainedSet {
    const values = try definition_core.json.array(raw);
    if (values.items.len > max_set_count or values.items.len > max_sets) {
        return error.InvalidRetainedSetCount;
    }
    const sets = try allocator.alloc(RetainedSet, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (sets[0..initialized]) |*set| set.deinit(allocator);
        allocator.free(sets);
    }
    for (values.items) |value| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "name", "max_entries", "max_key_bytes", "max_bytes" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "name", "max_entries", "max_key_bytes", "max_bytes" },
        );
        const name = try definition_core.json.requiredString(object, "name");
        try definition_core.json.safeIdentifier(name, 128);
        if (std.mem.eql(u8, name, "event")) {
            return error.ReservedRetainedSetName;
        }
        const entry_bound = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_entries"),
        );
        const key_bound = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_key_bytes"),
        );
        const byte_bound = try definition_core.json.unsigned(
            try definition_core.json.field(object, "max_bytes"),
        );
        if (entry_bound == 0 or entry_bound > max_entries or
            key_bound == 0 or key_bound > max_store_bytes or
            byte_bound == 0 or byte_bound > max_store_bytes or
            key_bound > byte_bound)
        {
            return error.RetainedSetBoundsExceeded;
        }
        sets[initialized] = .{
            .name = try allocator.dupe(u8, name),
            .max_entries = entry_bound,
            .max_key_bytes = key_bound,
            .max_bytes = byte_bound,
        };
        initialized += 1;
    }
    std.sort.heap(RetainedSet, sets, {}, struct {
        fn lessThan(
            _: void,
            left: RetainedSet,
            right: RetainedSet,
        ) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    if (sets.len > 1) {
        for (sets[1..], 1..) |set, index| {
            if (std.mem.eql(u8, sets[index - 1].name, set.name)) {
                return error.DuplicateRetainedSet;
            }
        }
    }
    return sets;
}

fn compileAdmissions(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    registers: []const Register,
    sets: []const RetainedSet,
    raw: std.json.Value,
    event_max_bytes: usize,
) ![]Admission {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > max_admissions) {
        return error.InvalidRetainedAdmissionCount;
    }
    const admissions = try allocator.alloc(Admission, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (admissions[0..initialized]) |*admission| {
            admission.deinit(allocator);
        }
        allocator.free(admissions);
    }
    for (values.items) |value| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{
                "on",
                "requires",
                "forbids",
                "set_guards",
                "rules",
                "actions",
            },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "on", "requires", "forbids", "rules", "actions" },
        );
        const on = try definition_core.json.requiredString(object, "on");
        try definition_core.json.safeIdentifier(on, 256);
        const required = try compileRegisterSet(
            allocator,
            registers,
            try definition_core.json.field(object, "requires"),
        );
        errdefer allocator.free(required);
        const forbidden = try compileRegisterSet(
            allocator,
            registers,
            try definition_core.json.field(object, "forbids"),
        );
        errdefer allocator.free(forbidden);
        if (setsIntersect(required, forbidden)) {
            return error.ConflictingRetainedAdmissionState;
        }
        const set_guards = if (object.get("set_guards")) |raw_guards|
            try compileSetGuards(
                allocator,
                registers,
                sets,
                required,
                raw_guards,
            )
        else
            try allocator.alloc(SetGuard, 0);
        errdefer deinitSetGuards(allocator, set_guards);
        const inputs = try admissionInputsAlloc(
            allocator,
            event_max_bytes,
            registers,
            required,
        );
        defer deinitInputs(allocator, inputs);
        var validation_plan = try validation.compileEmbedded(
            allocator,
            definition_plan,
            inputs,
            try definition_core.json.field(object, "rules"),
            definition_plan.bounds.max_input_bytes,
            definition_plan.bounds.max_records,
            definition_plan.bounds.max_diagnostics,
        );
        errdefer validation_plan.deinit(allocator);
        const actions = try compileActions(
            allocator,
            registers,
            sets,
            required,
            try definition_core.json.field(object, "actions"),
            definition_plan.bounds.max_records,
        );
        errdefer {
            for (actions) |*action| action.deinit(allocator);
            allocator.free(actions);
        }
        admissions[initialized] = .{
            .on = try allocator.dupe(u8, on),
            .required = required,
            .forbidden = forbidden,
            .set_guards = set_guards,
            .validation_plan = validation_plan,
            .actions = actions,
        };
        initialized += 1;
    }
    return admissions;
}

fn compileSetGuards(
    allocator: std.mem.Allocator,
    registers: []const Register,
    sets: []const RetainedSet,
    required: []const u16,
    raw: std.json.Value,
) ![]SetGuard {
    const values = try definition_core.json.array(raw);
    if (values.items.len > max_actions) return error.TooManyRetainedSetGuards;
    const guards = try allocator.alloc(SetGuard, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (guards[0..initialized]) |*guard| guard.deinit(allocator);
        allocator.free(guards);
    }
    for (values.items) |value| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "set", "input", "path", "presence", "mode" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "set", "input", "path", "presence" },
        );
        const set_index = findSet(
            sets,
            try definition_core.json.requiredString(object, "set"),
        ) orelse return error.UnknownRetainedSet;
        const source = try compileSource(
            registers,
            required,
            try definition_core.json.requiredString(object, "input"),
        );
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.requiredString(object, "path"),
        );
        errdefer pointer.deinit(allocator);
        const presence = std.meta.stringToEnum(
            SetPresence,
            try definition_core.json.requiredString(object, "presence"),
        ) orelse return error.InvalidRetainedSetPresence;
        const mode = if (object.get("mode")) |raw_mode|
            std.meta.stringToEnum(
                SetGuardMode,
                try definition_core.json.string(raw_mode),
            ) orelse return error.InvalidRetainedSetGuardMode
        else
            .scalar;
        const candidate: SetGuard = .{
            .set = @intCast(set_index),
            .source = source,
            .pointer = pointer,
            .presence = presence,
            .mode = mode,
        };
        for (guards[0..initialized]) |prior| {
            if (prior.set == candidate.set and
                sourceEqual(prior.source, candidate.source) and
                std.mem.eql(
                    u8,
                    prior.pointer.raw,
                    candidate.pointer.raw,
                ))
            {
                if (prior.presence != candidate.presence or
                    prior.mode != candidate.mode)
                {
                    return error.ConflictingRetainedSetGuard;
                }
                return error.DuplicateRetainedSetGuard;
            }
        }
        guards[initialized] = candidate;
        initialized += 1;
    }
    return guards;
}

fn compileActions(
    allocator: std.mem.Allocator,
    registers: []const Register,
    sets: []const RetainedSet,
    required: []const u16,
    raw: std.json.Value,
    max_records: usize,
) ![]Action {
    const values = try definition_core.json.array(raw);
    if (values.items.len > max_actions) return error.TooManyRetainedActions;
    const actions = try allocator.alloc(Action, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (actions[0..initialized]) |*action| action.deinit(allocator);
        allocator.free(actions);
    }
    const seen_targets = try allocator.alloc(bool, registers.len);
    defer allocator.free(seen_targets);
    @memset(seen_targets, false);
    const seen_set_targets = try allocator.alloc(bool, sets.len);
    defer allocator.free(seen_set_targets);
    @memset(seen_set_targets, false);
    for (values.items) |value| {
        const object = try definition_core.json.object(value);
        const operator = try definition_core.json.requiredString(object, "op");
        if (std.mem.eql(u8, operator, "set")) {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "register", "input", "path" },
            );
            try definition_core.json.requireFields(
                object,
                &.{ "op", "register", "input", "path" },
            );
            const target = findRegister(
                registers,
                try definition_core.json.requiredString(object, "register"),
            ) orelse return error.UnknownRetainedRegister;
            if (seen_targets[target]) {
                return error.DuplicateRetainedActionTarget;
            }
            seen_targets[target] = true;
            const input = try definition_core.json.requiredString(
                object,
                "input",
            );
            const source: Source = if (std.mem.eql(u8, input, "event"))
                .event
            else
                .{ .register = @intCast(findRegister(
                    registers,
                    input,
                ) orelse return error.UnknownRetainedRegister) };
            actions[initialized] = .{ .set = .{
                .target = @intCast(target),
                .source = source,
                .pointer = try definition_core.json_pointer.compile(
                    allocator,
                    try definition_core.json.string(
                        try definition_core.json.field(object, "path"),
                    ),
                ),
            } };
        } else if (std.mem.eql(u8, operator, "clear")) {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "register" },
            );
            try definition_core.json.requireFields(
                object,
                &.{ "op", "register" },
            );
            const target = findRegister(
                registers,
                try definition_core.json.requiredString(
                    object,
                    "register",
                ),
            ) orelse return error.UnknownRetainedRegister;
            if (seen_targets[target]) {
                return error.DuplicateRetainedActionTarget;
            }
            seen_targets[target] = true;
            actions[initialized] = .{ .clear = @intCast(target) };
        } else if (std.mem.eql(u8, operator, "insert")) {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "set", "input", "path" },
            );
            try definition_core.json.requireFields(
                object,
                &.{ "op", "set", "input", "path" },
            );
            const target = findSet(
                sets,
                try definition_core.json.requiredString(object, "set"),
            ) orelse return error.UnknownRetainedSet;
            if (seen_set_targets[target]) {
                return error.DuplicateRetainedActionTarget;
            }
            seen_set_targets[target] = true;
            const source = try compileSource(
                registers,
                required,
                try definition_core.json.requiredString(object, "input"),
            );
            actions[initialized] = .{ .insert = .{
                .target = @intCast(target),
                .source = source,
                .pointer = try definition_core.json_pointer.compile(
                    allocator,
                    try definition_core.json.requiredString(object, "path"),
                ),
            } };
        } else if (std.mem.eql(u8, operator, "upsert")) {
            try definition_core.json.requireExactKeys(
                object,
                &.{
                    "op",
                    "register",
                    "input",
                    "path",
                    "key",
                    "source_ref",
                    "predecessor_refs",
                    "stable",
                    "max_entries",
                    "max_key_bytes",
                },
            );
            try definition_core.json.requireFields(
                object,
                &.{
                    "op",
                    "register",
                    "input",
                    "path",
                    "key",
                    "source_ref",
                    "predecessor_refs",
                    "stable",
                    "max_entries",
                    "max_key_bytes",
                },
            );
            const target = findRegister(
                registers,
                try definition_core.json.requiredString(
                    object,
                    "register",
                ),
            ) orelse return error.UnknownRetainedRegister;
            if (seen_targets[target]) {
                return error.DuplicateRetainedActionTarget;
            }
            if (!containsIndex(required, @intCast(target))) {
                return error.RetainedActionTargetNotRequired;
            }
            seen_targets[target] = true;
            const source = try compileSource(
                registers,
                required,
                try definition_core.json.requiredString(object, "input"),
            );
            const entry_bound = try definition_core.json.unsigned(
                try definition_core.json.field(object, "max_entries"),
            );
            const key_bound = try definition_core.json.unsigned(
                try definition_core.json.field(object, "max_key_bytes"),
            );
            if (entry_bound == 0 or entry_bound > max_records or
                key_bound == 0 or key_bound > registers[target].max_bytes)
            {
                return error.RetainedUpsertBoundsExceeded;
            }
            var collection = try definition_core.json_pointer.compile(
                allocator,
                try definition_core.json.requiredString(object, "path"),
            );
            errdefer collection.deinit(allocator);
            var key = try definition_core.json_pointer.compile(
                allocator,
                try definition_core.json.requiredString(object, "key"),
            );
            errdefer key.deinit(allocator);
            var source_ref = try definition_core.json_pointer.compile(
                allocator,
                try definition_core.json.requiredString(object, "source_ref"),
            );
            errdefer source_ref.deinit(allocator);
            var predecessor_refs =
                try definition_core.json_pointer.compile(
                    allocator,
                    try definition_core.json.requiredString(
                        object,
                        "predecessor_refs",
                    ),
                );
            errdefer predecessor_refs.deinit(allocator);
            const stable = try compilePointerList(
                allocator,
                try definition_core.json.field(object, "stable"),
                max_stable_pointers,
            );
            errdefer deinitPointers(allocator, stable);
            actions[initialized] = .{ .upsert = .{
                .target = @intCast(target),
                .source = source,
                .collection = collection,
                .key = key,
                .source_ref = source_ref,
                .predecessor_refs = predecessor_refs,
                .stable = stable,
                .max_entries = entry_bound,
                .max_key_bytes = key_bound,
            } };
        } else return error.UnsupportedRetainedAction;
        initialized += 1;
    }
    return actions;
}

fn compileSource(
    registers: []const Register,
    required: []const u16,
    input: []const u8,
) !Source {
    if (std.mem.eql(u8, input, "event")) return .event;
    const index = findRegister(registers, input) orelse
        return error.UnknownRetainedRegister;
    if (!containsIndex(required, @intCast(index))) {
        return error.RetainedActionSourceNotRequired;
    }
    return .{ .register = @intCast(index) };
}

fn compilePointerList(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    maximum: usize,
) ![]definition_core.json_pointer.Pointer {
    const values = try definition_core.json.array(raw);
    if (values.items.len > maximum) {
        return error.TooManyRetainedActionPointers;
    }
    const pointers = try allocator.alloc(
        definition_core.json_pointer.Pointer,
        values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (pointers[0..initialized]) |*pointer| pointer.deinit(allocator);
        allocator.free(pointers);
    }
    for (values.items) |value| {
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(value),
        );
        errdefer pointer.deinit(allocator);
        for (pointers[0..initialized]) |prior| {
            if (std.mem.eql(u8, prior.raw, pointer.raw)) {
                return error.DuplicateRetainedActionPointer;
            }
        }
        pointers[initialized] = pointer;
        initialized += 1;
    }
    return pointers;
}

fn deinitPointers(
    allocator: std.mem.Allocator,
    pointers: []definition_core.json_pointer.Pointer,
) void {
    for (pointers) |*pointer| pointer.deinit(allocator);
    allocator.free(pointers);
}

fn admissionInputsAlloc(
    allocator: std.mem.Allocator,
    max_bytes: usize,
    registers: []const Register,
    required: []const u16,
) ![]definition.Input {
    const inputs = try allocator.alloc(definition.Input, registers.len + 1);
    var initialized: usize = 0;
    errdefer {
        for (inputs[0..initialized]) |*input| input.deinit(allocator);
        allocator.free(inputs);
    }
    inputs[0] = .{
        .name = try allocator.dupe(u8, "event"),
        .codec = .json,
        .required = true,
        .max_bytes = max_bytes,
    };
    initialized += 1;
    for (registers, 0..) |register, index| {
        inputs[initialized] = .{
            .name = try allocator.dupe(u8, register.name),
            .codec = .json,
            .required = containsIndex(required, @intCast(index)),
            .max_bytes = register.max_bytes,
        };
        initialized += 1;
    }
    std.sort.heap(definition.Input, inputs, {}, struct {
        fn lessThan(
            _: void,
            left: definition.Input,
            right: definition.Input,
        ) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return inputs;
}

fn compileRegisterSet(
    allocator: std.mem.Allocator,
    registers: []const Register,
    raw: std.json.Value,
) ![]u16 {
    const values = try definition_core.json.array(raw);
    if (values.items.len > registers.len) {
        return error.InvalidRetainedRegisterSet;
    }
    const indexes = try allocator.alloc(u16, values.items.len);
    errdefer allocator.free(indexes);
    for (values.items, 0..) |value, index| {
        indexes[index] = @intCast(findRegister(
            registers,
            try definition_core.json.string(value),
        ) orelse return error.UnknownRetainedRegister);
    }
    std.sort.heap(u16, indexes, {}, std.sort.asc(u16));
    if (indexes.len > 1) {
        for (indexes[1..], 1..) |item, index| {
            if (indexes[index - 1] == item) {
                return error.DuplicateRetainedRegisterReference;
            }
        }
    }
    return indexes;
}

fn applyActionsAtomically(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *State,
    event: std.json.Value,
    actions: []const Action,
) !void {
    const prepared = try allocator.alloc(?OwnedValue, actions.len);
    defer allocator.free(prepared);
    @memset(prepared, null);
    const prepared_keys = try allocator.alloc(?[]u8, actions.len);
    defer allocator.free(prepared_keys);
    @memset(prepared_keys, null);
    errdefer for (prepared) |*value| {
        if (value.*) |*owned| owned.deinit(allocator);
    };
    errdefer for (prepared_keys) |key| {
        if (key) |owned| allocator.free(owned);
    };
    for (actions, 0..) |action, index| switch (action) {
        .clear => {},
        .set => |set| {
            const root = try sourceValue(plan, state, set.source, event);
            const value = definition_core.json_pointer.lookup(
                root,
                set.pointer,
            ) orelse return error.RetainedActionValueMissing;
            const canonical =
                try definition_core.canonical_json.canonicalJsonAlloc(
                    allocator,
                    value,
                );
            errdefer allocator.free(canonical);
            if (canonical.len > plan.registers[set.target].max_bytes) {
                return error.RetainedRegisterBoundsExceeded;
            }
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                canonical,
                .{
                    .allocate = .alloc_always,
                    .duplicate_field_behavior = .@"error",
                },
            );
            errdefer parsed.deinit();
            prepared[index] = .{
                .bytes = canonical,
                .parsed = parsed,
            };
        },
        .insert => |insert| {
            const root = try sourceValue(plan, state, insert.source, event);
            const value = definition_core.json_pointer.lookup(
                root,
                insert.pointer,
            ) orelse return error.RetainedActionValueMissing;
            const key = try definition_core.json.string(value);
            const set_plan = plan.sets[insert.target];
            const set_state = &setState(state, insert.target).value;
            if (key.len > set_plan.max_key_bytes or
                set_state.entries.count() >= set_plan.max_entries or
                set_state.bytes > set_plan.max_bytes -| key.len)
            {
                return error.RetainedSetBoundsExceeded;
            }
            if (try set_state.contains(key)) {
                return error.RetainedSetDuplicateKey;
            }
            prepared_keys[index] = try allocator.dupe(u8, key);
        },
        .upsert => |upsert| {
            prepared[index] = try prepareUpsert(
                allocator,
                plan,
                state,
                event,
                upsert,
            );
        },
    };
    for (actions) |action| switch (action) {
        .insert => |insert| {
            try setState(state, insert.target).value.entries.ensureUnusedCapacity(
                allocator,
                1,
            );
        },
        .set, .clear, .upsert => {},
    };
    for (actions, 0..) |action, index| {
        switch (action) {
            .set => |set| {
                const target = registerState(state, set.target);
                if (target.value) |*prior| {
                    prior.deinit(allocator);
                }
                target.value = prepared[index];
                prepared[index] = null;
            },
            .clear => |target| {
                const target_state = registerState(state, target);
                if (target_state.value) |*prior| prior.deinit(allocator);
                target_state.value = null;
            },
            .insert => |insert| {
                setState(state, insert.target).value.insertAssumeCapacity(
                    prepared_keys[index].?,
                );
                prepared_keys[index] = null;
            },
            .upsert => |upsert| {
                const target = registerState(state, upsert.target);
                if (target.value) |*prior| prior.deinit(allocator);
                target.value = prepared[index];
                prepared[index] = null;
            },
        }
    }
}

const ExistingUpsertEntry = struct {
    key: []const u8,
    occurrences: i64,
    source: []const u8,
    value: std.json.Value,
    replacement: ?std.json.Value = null,
};

const NewUpsertEntry = struct {
    key: []const u8,
    value: std.json.Value,
};

fn prepareUpsert(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const State,
    event: std.json.Value,
    action: UpsertAction,
) !OwnedValue {
    const current = registerStateConst(state, action.target).value orelse
        return error.RetainedUpsertTargetMissing;
    const existing_values = switch (current.parsed.value) {
        .array => |array| array.items,
        else => return error.RetainedUpsertStateInvalid,
    };
    if (existing_values.len > action.max_entries) {
        return error.RetainedUpsertBoundsExceeded;
    }

    const root = try sourceValue(plan, state, action.source, event);
    const incoming_values = switch (definition_core.json_pointer.lookup(
        root,
        action.collection,
    ) orelse return error.RetainedUpsertSourceMissing) {
        .array => |array| array.items,
        else => return error.RetainedUpsertSourceInvalid,
    };
    if (incoming_values.len > action.max_entries) {
        return error.RetainedUpsertBoundsExceeded;
    }
    const source_ref = try boundedUpsertString(
        definition_core.json_pointer.lookup(
            root,
            action.source_ref,
        ) orelse return error.RetainedUpsertSourceMissing,
        action.max_key_bytes,
    );
    const predecessor_values = switch (definition_core.json_pointer.lookup(
        root,
        action.predecessor_refs,
    ) orelse return error.RetainedUpsertSourceMissing) {
        .array => |array| array.items,
        else => return error.RetainedUpsertSourceInvalid,
    };
    if (predecessor_values.len > action.max_entries) {
        return error.RetainedUpsertBoundsExceeded;
    }
    var predecessor_index: std.AutoHashMapUnmanaged([32]u8, []const u8) = .empty;
    defer predecessor_index.deinit(allocator);
    for (predecessor_values) |predecessor| {
        const predecessor_ref = try boundedUpsertString(
            predecessor,
            action.max_key_bytes,
        );
        const result = try predecessor_index.getOrPut(
            allocator,
            retainedKeyDigest(predecessor_ref),
        );
        if (result.found_existing and
            !std.mem.eql(u8, result.value_ptr.*, predecessor_ref))
        {
            return error.RetainedUpsertDigestCollision;
        }
        result.value_ptr.* = predecessor_ref;
    }

    const existing = try allocator.alloc(
        ExistingUpsertEntry,
        existing_values.len,
    );
    defer allocator.free(existing);
    var existing_index: std.AutoHashMapUnmanaged([32]u8, usize) = .empty;
    defer existing_index.deinit(allocator);
    for (existing_values, 0..) |raw_entry, index| {
        const object = definition_core.json.object(raw_entry) catch
            return error.RetainedUpsertStateInvalid;
        definition_core.json.requireExactKeys(
            object,
            &.{ "key", "occurrences", "source", "value" },
        ) catch return error.RetainedUpsertStateInvalid;
        definition_core.json.requireFields(
            object,
            &.{ "key", "occurrences", "source", "value" },
        ) catch return error.RetainedUpsertStateInvalid;
        const key = boundedUpsertString(
            object.get("key").?,
            action.max_key_bytes,
        ) catch return error.RetainedUpsertStateInvalid;
        const occurrences = switch (object.get("occurrences").?) {
            .integer => |number| number,
            else => return error.RetainedUpsertStateInvalid,
        };
        if (occurrences <= 0) return error.RetainedUpsertStateInvalid;
        const source = boundedUpsertString(
            object.get("source").?,
            action.max_key_bytes,
        ) catch return error.RetainedUpsertStateInvalid;
        const retained_value = object.get("value").?;
        const retained_key = definition_core.json_pointer.lookup(
            retained_value,
            action.key,
        ) orelse return error.RetainedUpsertStateInvalid;
        const retained_key_string = boundedUpsertString(
            retained_key,
            action.max_key_bytes,
        ) catch return error.RetainedUpsertStateInvalid;
        if (!std.mem.eql(u8, key, retained_key_string)) {
            return error.RetainedUpsertStateInvalid;
        }
        existing[index] = .{
            .key = key,
            .occurrences = occurrences,
            .source = source,
            .value = retained_value,
        };
        const digest = retainedKeyDigest(key);
        const result = try existing_index.getOrPut(allocator, digest);
        if (result.found_existing) {
            if (!std.mem.eql(u8, existing[result.value_ptr.*].key, key)) {
                return error.RetainedUpsertDigestCollision;
            }
            return error.RetainedUpsertStateInvalid;
        }
        result.value_ptr.* = index;
    }

    var source_keys: std.AutoHashMapUnmanaged([32]u8, []const u8) = .empty;
    defer source_keys.deinit(allocator);
    var new_entries: std.ArrayList(NewUpsertEntry) = .empty;
    defer new_entries.deinit(allocator);
    for (incoming_values) |incoming| {
        const raw_key = definition_core.json_pointer.lookup(
            incoming,
            action.key,
        ) orelse return error.RetainedUpsertKeyMissing;
        const key = try boundedUpsertString(
            raw_key,
            action.max_key_bytes,
        );
        const digest = retainedKeyDigest(key);
        const source_result = try source_keys.getOrPut(allocator, digest);
        if (source_result.found_existing) {
            if (!std.mem.eql(u8, source_result.value_ptr.*, key)) {
                return error.RetainedUpsertDigestCollision;
            }
            return error.RetainedUpsertDuplicateKey;
        }
        source_result.value_ptr.* = key;

        if (existing_index.get(digest)) |existing_position| {
            const prior = &existing[existing_position];
            if (!std.mem.eql(u8, prior.key, key)) {
                return error.RetainedUpsertDigestCollision;
            }
            const predecessor = predecessor_index.get(
                retainedKeyDigest(prior.source),
            ) orelse return error.RetainedUpsertPredecessorMissing;
            if (!std.mem.eql(u8, predecessor, prior.source)) {
                return error.RetainedUpsertDigestCollision;
            }
            for (action.stable) |pointer| {
                const prior_value = definition_core.json_pointer.lookup(
                    prior.value,
                    pointer,
                ) orelse return error.RetainedUpsertStableValueMissing;
                const next_value = definition_core.json_pointer.lookup(
                    incoming,
                    pointer,
                ) orelse return error.RetainedUpsertStableValueMissing;
                if (!validation.valuesEqual(prior_value, next_value)) {
                    return error.RetainedUpsertStableValueChanged;
                }
            }
            if (prior.occurrences == std.math.maxInt(i64)) {
                return error.RetainedUpsertOccurrenceOverflow;
            }
            prior.replacement = incoming;
        } else {
            if (existing.len + new_entries.items.len >= action.max_entries) {
                return error.RetainedUpsertBoundsExceeded;
            }
            try new_entries.append(allocator, .{
                .key = key,
                .value = incoming,
            });
        }
    }

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var emitted: usize = 0;
    for (existing) |entry| {
        if (emitted != 0) try output.writer.writeByte(',');
        try writeUpsertEntry(
            allocator,
            &output.writer,
            entry.key,
            if (entry.replacement != null)
                entry.occurrences + 1
            else
                entry.occurrences,
            if (entry.replacement != null) source_ref else entry.source,
            entry.replacement orelse entry.value,
        );
        emitted += 1;
    }
    for (new_entries.items) |entry| {
        if (emitted != 0) try output.writer.writeByte(',');
        try writeUpsertEntry(
            allocator,
            &output.writer,
            entry.key,
            1,
            source_ref,
            entry.value,
        );
        emitted += 1;
    }
    try output.writer.writeByte(']');
    const canonical = try output.toOwnedSlice();
    errdefer allocator.free(canonical);
    if (canonical.len > plan.registers[action.target].max_bytes) {
        return error.RetainedRegisterBoundsExceeded;
    }
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        canonical,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    errdefer parsed.deinit();
    return .{
        .bytes = canonical,
        .parsed = parsed,
    };
}

fn boundedUpsertString(
    value: std.json.Value,
    max_bytes: usize,
) ![]const u8 {
    const text = switch (value) {
        .string => |string| string,
        else => return error.RetainedUpsertStringExpected,
    };
    if (text.len > max_bytes) return error.RetainedUpsertBoundsExceeded;
    return text;
}

fn writeUpsertEntry(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    occurrences: i64,
    source: []const u8,
    value: std.json.Value,
) !void {
    try writer.writeAll("{\"key\":");
    try definition_core.canonical_json.writeCanonicalJson(
        allocator,
        writer,
        .{ .string = key },
    );
    try writer.print(",\"occurrences\":{d},\"source\":", .{occurrences});
    try definition_core.canonical_json.writeCanonicalJson(
        allocator,
        writer,
        .{ .string = source },
    );
    try writer.writeAll(",\"value\":");
    try definition_core.canonical_json.writeCanonicalJson(
        allocator,
        writer,
        value,
    );
    try writer.writeByte('}');
}

fn preconditionsHold(
    plan: *const Plan,
    state: *const State,
    event: std.json.Value,
    admission: *const Admission,
) !bool {
    for (admission.required) |index| {
        if (registerStateConst(state, index).value == null) return false;
    }
    for (admission.forbidden) |index| {
        if (registerStateConst(state, index).value != null) return false;
    }
    for (admission.set_guards) |guard| {
        const root = try sourceValue(plan, state, guard.source, event);
        const value = definition_core.json_pointer.lookup(
            root,
            guard.pointer,
        ) orelse return error.RetainedSetGuardValueMissing;
        switch (guard.mode) {
            .scalar => if (!try retainedSetGuardMatches(
                plan,
                state,
                guard,
                value,
            )) return false,
            .each => {
                const items = switch (value) {
                    .array => |array| array.items,
                    else => return error.RetainedSetGuardArrayExpected,
                };
                if (items.len > plan.sets[guard.set].max_entries) {
                    return error.RetainedSetBoundsExceeded;
                }
                for (items) |item| {
                    if (!try retainedSetGuardMatches(
                        plan,
                        state,
                        guard,
                        item,
                    )) return false;
                }
            },
        }
    }
    return true;
}

fn retainedSetGuardMatches(
    plan: *const Plan,
    state: *const State,
    guard: SetGuard,
    value: std.json.Value,
) !bool {
    const key = try definition_core.json.string(value);
    if (key.len > plan.sets[guard.set].max_key_bytes) {
        return error.RetainedSetKeyBoundsExceeded;
    }
    const present = try setStateConst(state, guard.set).value.contains(key);
    return present == (guard.presence == .present);
}

fn ensureState(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *State,
) !void {
    if (state.has_active_layout and std.mem.eql(
        u8,
        &state.active_layout_digest,
        &plan.layout_digest,
    )) return;
    const register_map = try allocator.alloc(u16, plan.registers.len);
    errdefer allocator.free(register_map);
    const set_map = try allocator.alloc(u16, plan.sets.len);
    errdefer allocator.free(set_map);
    var missing_registers: std.ArrayList([]u8) = .empty;
    defer {
        for (missing_registers.items) |name| {
            if (name.len != 0) allocator.free(name);
        }
        missing_registers.deinit(allocator);
    }
    var missing_sets: std.ArrayList([]u8) = .empty;
    defer {
        for (missing_sets.items) |name| {
            if (name.len != 0) allocator.free(name);
        }
        missing_sets.deinit(allocator);
    }
    for (plan.registers, 0..) |register, index| {
        if (findNamedRegister(state.registers.items, register.name)) |found| {
            if (state.registers.items[found].value) |owned| {
                if (owned.bytes.len > register.max_bytes) {
                    return error.RetainedRegisterBoundsExceeded;
                }
            }
            register_map[index] = @intCast(found);
            continue;
        }
        if (findNamedSet(state.sets.items, register.name) != null) {
            return error.RetainedStateKindMismatch;
        }
        if (state.registers.items.len + missing_registers.items.len >=
            max_registers)
        {
            return error.RetainedStateCarrierBoundsExceeded;
        }
        register_map[index] = @intCast(
            state.registers.items.len + missing_registers.items.len,
        );
        const owned_name = try allocator.dupe(u8, register.name);
        errdefer allocator.free(owned_name);
        try missing_registers.append(allocator, owned_name);
    }
    for (plan.sets, 0..) |set, index| {
        if (findNamedSet(state.sets.items, set.name)) |found| {
            const existing = &state.sets.items[found].value;
            if (existing.entries.count() > set.max_entries or
                existing.bytes > set.max_bytes)
            {
                return error.RetainedSetBoundsExceeded;
            }
            var iterator = existing.entries.valueIterator();
            while (iterator.next()) |key| {
                if (key.*.len > set.max_key_bytes) {
                    return error.RetainedSetKeyBoundsExceeded;
                }
            }
            set_map[index] = @intCast(found);
            continue;
        }
        if (findNamedRegister(state.registers.items, set.name) != null) {
            return error.RetainedStateKindMismatch;
        }
        if (state.sets.items.len + missing_sets.items.len >= max_sets) {
            return error.RetainedStateCarrierBoundsExceeded;
        }
        set_map[index] = @intCast(
            state.sets.items.len + missing_sets.items.len,
        );
        const owned_name = try allocator.dupe(u8, set.name);
        errdefer allocator.free(owned_name);
        try missing_sets.append(allocator, owned_name);
    }
    try state.registers.ensureUnusedCapacity(
        allocator,
        missing_registers.items.len,
    );
    try state.sets.ensureUnusedCapacity(
        allocator,
        missing_sets.items.len,
    );
    for (missing_registers.items) |*name| {
        state.registers.appendAssumeCapacity(.{ .name = name.* });
        name.* = &.{};
    }
    for (missing_sets.items) |*name| {
        state.sets.appendAssumeCapacity(.{ .name = name.* });
        name.* = &.{};
    }
    if (state.register_map.len != 0) allocator.free(state.register_map);
    if (state.set_map.len != 0) allocator.free(state.set_map);
    state.register_map = register_map;
    state.set_map = set_map;
    state.active_layout_digest = plan.layout_digest;
    state.has_active_layout = true;
}

fn presentCount(plan: *const Plan, state: *const State) usize {
    var result: usize = 0;
    for (plan.registers, 0..) |_, index| {
        result += @intFromBool(registerStateConst(state, index).value != null);
    }
    return result;
}

fn validateAdmissionInputs(
    plan: *const Plan,
    admission: *const Admission,
    event_max_bytes: usize,
) !void {
    if (admission.validation_plan.inputs.len != plan.registers.len + 1) {
        return error.CacheRetainedAdmissionInputsMismatch;
    }
    for (admission.validation_plan.inputs) |input| {
        if (std.mem.eql(u8, input.name, "event")) {
            if (!input.required or input.codec != .json or
                input.max_bytes != event_max_bytes)
            {
                return error.CacheRetainedAdmissionInputsMismatch;
            }
            continue;
        }
        const index = findRegister(plan.registers, input.name) orelse
            return error.CacheRetainedAdmissionInputsMismatch;
        if (input.required !=
            containsIndex(admission.required, @intCast(index)) or
            input.max_bytes != plan.registers[index].max_bytes)
        {
            return error.CacheRetainedAdmissionInputsMismatch;
        }
    }
}

fn admissionsOverlap(left: Admission, right: Admission) bool {
    if (setsIntersect(left.required, right.forbidden) or
        setsIntersect(right.required, left.forbidden)) return false;
    for (left.set_guards) |left_guard| {
        for (right.set_guards) |right_guard| {
            if (left_guard.set == right_guard.set and
                sourceEqual(left_guard.source, right_guard.source) and
                std.mem.eql(
                    u8,
                    left_guard.pointer.raw,
                    right_guard.pointer.raw,
                ) and left_guard.mode == right_guard.mode and
                left_guard.presence != right_guard.presence)
            {
                return false;
            }
        }
    }
    return true;
}

fn actionsConflict(left: Action, right: Action) bool {
    return switch (left) {
        .set => |left_set| switch (right) {
            .set => |right_set| left_set.target == right_set.target,
            .clear => |right_target| left_set.target == right_target,
            .upsert => |right_upsert| left_set.target == right_upsert.target,
            .insert => false,
        },
        .clear => |left_target| switch (right) {
            .set => |right_set| left_target == right_set.target,
            .clear => |right_target| left_target == right_target,
            .upsert => |right_upsert| left_target == right_upsert.target,
            .insert => false,
        },
        .insert => |left_insert| switch (right) {
            .insert => |right_insert| left_insert.target == right_insert.target,
            .set, .clear, .upsert => false,
        },
        .upsert => |left_upsert| switch (right) {
            .set => |right_set| left_upsert.target == right_set.target,
            .clear => |right_target| left_upsert.target == right_target,
            .upsert => |right_upsert| left_upsert.target == right_upsert.target,
            .insert => false,
        },
    };
}

fn validateSource(
    source: Source,
    register_count: usize,
    required: []const u16,
) !void {
    switch (source) {
        .event => {},
        .register => |index| {
            if (index >= register_count) {
                return error.InvalidRetainedActionSource;
            }
            if (!containsIndex(required, index)) {
                return error.RetainedActionSourceNotRequired;
            }
        },
    }
}

fn sourceValue(
    plan: *const Plan,
    state: *const State,
    source: Source,
    event: std.json.Value,
) !std.json.Value {
    _ = plan;
    return switch (source) {
        .event => event,
        .register => |index| if (registerStateConst(state, index).value) |owned|
            owned.parsed.value
        else
            error.RetainedActionSourceMissing,
    };
}

fn sourceEqual(left: Source, right: Source) bool {
    return switch (left) {
        .event => right == .event,
        .register => |left_index| right == .register and
            left_index == right.register,
    };
}

fn retainedKeyDigest(key: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    return digest;
}

fn retainedLayoutDigest(
    registers: []const Register,
    sets: []const RetainedSet,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("ledger-retained-state-layout/v1\x00");
    hashUsize(&hasher, registers.len);
    for (registers) |register| {
        hasher.update("register\x00");
        hashBytes(&hasher, register.name);
        hashUsize(&hasher, register.max_bytes);
    }
    hashUsize(&hasher, sets.len);
    for (sets) |set| {
        hasher.update("set\x00");
        hashBytes(&hasher, set.name);
        hashUsize(&hasher, set.max_entries);
        hashUsize(&hasher, set.max_key_bytes);
        hashUsize(&hasher, set.max_bytes);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashBytes(
    hasher: *std.crypto.hash.sha2.Sha256,
    bytes: []const u8,
) void {
    hashUsize(hasher, bytes.len);
    hasher.update(bytes);
}

fn hashUsize(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: usize,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .big);
    hasher.update(&bytes);
}

fn registerState(
    state: *State,
    plan_index: usize,
) *NamedRegisterState {
    return &state.registers.items[state.register_map[plan_index]];
}

fn registerStateConst(
    state: *const State,
    plan_index: usize,
) *const NamedRegisterState {
    return &state.registers.items[state.register_map[plan_index]];
}

fn setState(
    state: *State,
    plan_index: usize,
) *NamedSetState {
    return &state.sets.items[state.set_map[plan_index]];
}

fn setStateConst(
    state: *const State,
    plan_index: usize,
) *const NamedSetState {
    return &state.sets.items[state.set_map[plan_index]];
}

fn validateIndexes(indexes: []const u16, register_count: usize) !void {
    for (indexes, 0..) |index, position| {
        if (index >= register_count or
            (position != 0 and indexes[position - 1] >= index))
        {
            return error.CacheRetainedRegisterSetInvalid;
        }
    }
}

fn encodeIndexes(
    indexes: []const u16,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(indexes.len);
    for (indexes) |index| try encoder.writeU16(index);
}

fn encodeSource(
    source: Source,
    encoder: *definition_core.cache.Encoder,
) !void {
    switch (source) {
        .event => try encoder.writeByte(0),
        .register => |index| {
            try encoder.writeByte(1);
            try encoder.writeU16(index);
        },
    }
}

fn decodeSource(
    decoder: *definition_core.cache.Decoder,
    register_count: usize,
) !Source {
    return switch (try decoder.readByte()) {
        0 => .event,
        1 => register: {
            const index = try decoder.readU16();
            if (index >= register_count) {
                return error.CacheStateActionSourceInvalid;
            }
            break :register .{ .register = index };
        },
        else => error.CacheStateActionSourceInvalid,
    };
}

fn decodePointer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !definition_core.json_pointer.Pointer {
    const raw = try decoder.readBytesAlloc(allocator, 1024);
    defer allocator.free(raw);
    return definition_core.json_pointer.compile(allocator, raw);
}

fn decodeSetGuards(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    register_count: usize,
    set_count: usize,
) ![]SetGuard {
    const count = try decoder.readCount(max_actions);
    const guards = try allocator.alloc(SetGuard, count);
    var initialized: usize = 0;
    errdefer {
        for (guards[0..initialized]) |*guard| guard.deinit(allocator);
        allocator.free(guards);
    }
    for (guards) |*guard| {
        const set_index = try decoder.readU16();
        if (set_index >= set_count) return error.CacheRetainedSetInvalid;
        const source = try decodeSource(decoder, register_count);
        var pointer: ?definition_core.json_pointer.Pointer =
            try decodePointer(allocator, decoder);
        errdefer if (pointer) |*owned| owned.deinit(allocator);
        const presence = try decoder.readEnum(SetPresence);
        const mode = try decoder.readEnum(SetGuardMode);
        guard.* = .{
            .set = set_index,
            .source = source,
            .pointer = pointer.?,
            .presence = presence,
            .mode = mode,
        };
        pointer = null;
        initialized += 1;
    }
    return guards;
}

fn decodeIndexes(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    register_count: usize,
) ![]u16 {
    const count = try decoder.readCount(register_count);
    const indexes = try allocator.alloc(u16, count);
    errdefer allocator.free(indexes);
    for (indexes) |*index| index.* = try decoder.readU16();
    try validateIndexes(indexes, register_count);
    return indexes;
}

fn containsIndex(indexes: []const u16, needle: u16) bool {
    return std.sort.binarySearch(
        u16,
        indexes,
        needle,
        struct {
            fn compare(value: u16, item: u16) std.math.Order {
                return std.math.order(value, item);
            }
        }.compare,
    ) != null;
}

fn setsIntersect(left: []const u16, right: []const u16) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        if (left[left_index] == right[right_index]) return true;
        if (left[left_index] < right[right_index]) {
            left_index += 1;
        } else {
            right_index += 1;
        }
    }
    return false;
}

fn findRegister(registers: []const Register, name: []const u8) ?usize {
    var low: usize = 0;
    var high = registers.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, registers[middle].name, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn findSet(sets: []const RetainedSet, name: []const u8) ?usize {
    var low: usize = 0;
    var high = sets.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, sets[middle].name, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn findNamedRegister(
    registers: []const NamedRegisterState,
    name: []const u8,
) ?usize {
    for (registers, 0..) |register, index| {
        if (std.mem.eql(u8, register.name, name)) return index;
    }
    return null;
}

fn findNamedSet(
    sets: []const NamedSetState,
    name: []const u8,
) ?usize {
    for (sets, 0..) |set, index| {
        if (std.mem.eql(u8, set.name, name)) return index;
    }
    return null;
}

fn containsString(values: []const []u8, needle: []const u8) bool {
    var low: usize = 0;
    var high = values.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, values[middle], needle)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return true,
        }
    }
    return false;
}

fn parseRule(
    allocator: std.mem.Allocator,
    rule: definition.Rule,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        rule.canonical_config,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
}

fn deinitRegisters(
    allocator: std.mem.Allocator,
    registers: []Register,
) void {
    for (registers) |*register| register.deinit(allocator);
    allocator.free(registers);
}

fn deinitSets(
    allocator: std.mem.Allocator,
    sets: []RetainedSet,
) void {
    for (sets) |*set| set.deinit(allocator);
    allocator.free(sets);
}

fn deinitSetGuards(
    allocator: std.mem.Allocator,
    guards: []SetGuard,
) void {
    for (guards) |*guard| guard.deinit(allocator);
    allocator.free(guards);
}

fn deinitAdmissions(
    allocator: std.mem.Allocator,
    admissions: []Admission,
) void {
    for (admissions) |*admission| admission.deinit(allocator);
    allocator.free(admissions);
}

fn deinitInputs(
    allocator: std.mem.Allocator,
    inputs: []definition.Input,
) void {
    for (inputs) |*input| input.deinit(allocator);
    allocator.free(inputs);
}

fn compileForAllocationFailure(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rule: definition.Rule,
    event_max_bytes: usize,
) !void {
    var plan = compile(
        allocator,
        definition_plan,
        rule,
        event_max_bytes,
    ) catch |err| switch (err) {
        error.InvalidDefinitionJson,
        error.WriteFailed,
        => return error.OutOfMemory,
        else => return err,
    };
    defer plan.deinit(allocator);
}

fn decodeForAllocationFailure(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !void {
    var decoder = definition_core.cache.Decoder.init(payload);
    var plan = decodeCache(allocator, &decoder) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer plan.deinit(allocator);
    try decoder.finish();
}

fn applyEvolutionForAllocationFailure(
    allocator: std.mem.Allocator,
    first: *const Plan,
    second: *const Plan,
    created: std.json.Value,
    updated: std.json.Value,
) !void {
    var state: State = .{};
    defer state.deinit(allocator);
    apply(allocator, first, &state, created) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    apply(allocator, second, &state, updated) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
}

fn applyUpsertForAllocationFailure(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    created: std.json.Value,
    first: std.json.Value,
    second: std.json.Value,
) !void {
    var state: State = .{};
    defer state.deinit(allocator);
    for ([_]std.json.Value{ created, first, second }) |event| {
        apply(allocator, plan, &state, event) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
    }
}

test "retained reducer cache binds event bounds and actions commit atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "definition.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/retained-state","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["reducer"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":[{"op":"reducer","mode":"retained","event_kind":"/kind","registers":[{"name":"current","max_bytes":4096},{"name":"shadow","max_bytes":4096}],"admissions":[{"on":"created","requires":[],"forbids":["current"],"rules":[],"actions":[{"op":"set","register":"current","input":"event","path":"/body"}]},{"on":"updated","requires":["current"],"forbids":[],"rules":[],"actions":[{"op":"set","register":"current","input":"event","path":"/body"},{"op":"set","register":"shadow","input":"event","path":"/body/missing"}]}]}],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":8192,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
        ,
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
    const reducer_rule = for (definition_plan.rules) |rule| {
        if (rule.operator == .reducer) break rule;
    } else return error.TestReducerRuleMissing;
    var plan = try compile(
        std.testing.allocator,
        &definition_plan,
        reducer_rule,
        4096,
    );
    defer plan.deinit(std.testing.allocator);
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
    try validatePlan(&cached, &definition_plan, 4096);
    for (cached.admissions[0].validation_plan.inputs) |*input| {
        if (std.mem.eql(u8, input.name, "event")) {
            input.max_bytes = 2048;
            break;
        }
    }
    try std.testing.expectError(
        error.CacheRetainedAdmissionInputsMismatch,
        validatePlan(&cached, &definition_plan, 4096),
    );
    for (cached.admissions[0].validation_plan.inputs) |*input| {
        if (std.mem.eql(u8, input.name, "event")) {
            input.max_bytes = 4096;
            break;
        }
    }

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var created = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"created\",\"body\":{\"id\":\"item-1\",\"status\":\"open\"}}",
        .{ .allocate = .alloc_always },
    );
    defer created.deinit();
    try apply(std.testing.allocator, &cached, &state, created.value);
    var updated = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"item-1\",\"status\":\"closed\"}}",
        .{ .allocate = .alloc_always },
    );
    defer updated.deinit();
    try std.testing.expectError(
        error.RetainedActionValueMissing,
        apply(std.testing.allocator, &cached, &state, updated.value),
    );
    var status_pointer = try definition_core.json_pointer.compile(
        std.testing.allocator,
        "/status",
    );
    defer status_pointer.deinit(std.testing.allocator);
    const current = state.get(&cached, "current").?;
    try std.testing.expectEqualStrings(
        "open",
        definition_core.json_pointer.lookup(
            current,
            status_pointer,
        ).?.string,
    );
    try std.testing.expect(state.get(&cached, "shadow") == null);
}

test "retained sets reject duplicate and over-bound keys atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "definition.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/retained-sets","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["reducer"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":[{"op":"reducer","mode":"retained","event_kind":"/kind","registers":[{"name":"current","max_bytes":4096}],"sets":[{"name":"used_ids","max_entries":2,"max_key_bytes":8,"max_bytes":16}],"admissions":[{"on":"created","requires":[],"forbids":["current"],"set_guards":[{"set":"used_ids","input":"event","path":"/body/id","presence":"absent"}],"rules":[],"actions":[{"op":"set","register":"current","input":"event","path":"/body"},{"op":"insert","set":"used_ids","input":"event","path":"/body/id"}]},{"on":"updated","requires":["current"],"forbids":[],"set_guards":[{"set":"used_ids","input":"event","path":"/body/id","presence":"absent"},{"set":"used_ids","input":"event","path":"/body/predecessors","presence":"present","mode":"each"}],"rules":[],"actions":[{"op":"set","register":"current","input":"event","path":"/body"},{"op":"insert","set":"used_ids","input":"event","path":"/body/id"}]}]}],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":8192,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
        ,
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
    const reducer_rule = for (definition_plan.rules) |rule| {
        if (rule.operator == .reducer) break rule;
    } else return error.TestReducerRuleMissing;
    var plan = try compile(
        std.testing.allocator,
        &definition_plan,
        reducer_rule,
        4096,
    );
    defer plan.deinit(std.testing.allocator);
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
    try validatePlan(&cached, &definition_plan, 4096);
    try std.testing.expectEqual(@as(usize, 1), cached.sets.len);
    try std.testing.expectEqual(@as(usize, 2), cached.admissions[1].set_guards.len);

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var created = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"created\",\"body\":{\"id\":\"first\",\"status\":\"open\"}}",
        .{ .allocate = .alloc_always },
    );
    defer created.deinit();
    try apply(std.testing.allocator, &cached, &state, created.value);
    var updated = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"second\",\"predecessors\":[\"first\"],\"status\":\"closed\"}}",
        .{ .allocate = .alloc_always },
    );
    defer updated.deinit();
    try apply(std.testing.allocator, &cached, &state, updated.value);
    try std.testing.expectEqual(
        @as(usize, 2),
        state.sets.items[0].value.entries.count(),
    );
    var unknown_predecessor = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"third\",\"predecessors\":[\"unknown\"],\"status\":\"wrong\"}}",
        .{ .allocate = .alloc_always },
    );
    defer unknown_predecessor.deinit();
    try std.testing.expectError(
        error.IllegalRetainedTransition,
        apply(
            std.testing.allocator,
            &cached,
            &state,
            unknown_predecessor.value,
        ),
    );

    var duplicate = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"first\",\"predecessors\":[\"first\"],\"status\":\"wrong\"}}",
        .{ .allocate = .alloc_always },
    );
    defer duplicate.deinit();
    try std.testing.expectError(
        error.IllegalRetainedTransition,
        apply(std.testing.allocator, &cached, &state, duplicate.value),
    );
    var overflow = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"third\",\"predecessors\":[\"first\"],\"status\":\"wrong\"}}",
        .{ .allocate = .alloc_always },
    );
    defer overflow.deinit();
    try std.testing.expectError(
        error.RetainedSetBoundsExceeded,
        apply(std.testing.allocator, &cached, &state, overflow.value),
    );
    var oversized = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"too-large\",\"predecessors\":[\"first\"],\"status\":\"wrong\"}}",
        .{ .allocate = .alloc_always },
    );
    defer oversized.deinit();
    try std.testing.expectError(
        error.RetainedSetKeyBoundsExceeded,
        apply(std.testing.allocator, &cached, &state, oversized.value),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        state.sets.items[0].value.entries.count(),
    );
    var status_pointer = try definition_core.json_pointer.compile(
        std.testing.allocator,
        "/status",
    );
    defer status_pointer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "closed",
        definition_core.json_pointer.lookup(
            state.get(&cached, "current").?,
            status_pointer,
        ).?.string,
    );
}

test "retained keyed upserts preserve lineage and stable fields atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "definition.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/retained-upsert","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["reducer"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":[{"op":"reducer","mode":"retained","event_kind":"/kind","registers":[{"name":"items","max_bytes":4096}],"admissions":[{"on":"created","requires":[],"forbids":["items"],"rules":[],"actions":[{"op":"set","register":"items","input":"event","path":"/body/items"}]},{"on":"upserted","requires":["items"],"forbids":[],"rules":[],"actions":[{"op":"upsert","register":"items","input":"event","path":"/body/items","key":"/id","source_ref":"/body/set_id","predecessor_refs":"/body/predecessors","stable":["/owner"],"max_entries":3,"max_key_bytes":32}]}]}],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":3,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
        ,
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
    const reducer_rule = for (definition_plan.rules) |rule| {
        if (rule.operator == .reducer) break rule;
    } else return error.TestReducerRuleMissing;
    var plan = try compile(
        std.testing.allocator,
        &definition_plan,
        reducer_rule,
        4096,
    );
    defer plan.deinit(std.testing.allocator);
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
    try validatePlan(&cached, &definition_plan, 4096);
    try std.testing.expectEqual(
        @as(usize, 1),
        cached.admissions[1].actions.len,
    );
    try std.testing.expect(cached.admissions[1].actions[0] == .upsert);

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var created = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"created\",\"body\":{\"items\":[]}}",
        .{ .allocate = .alloc_always },
    );
    defer created.deinit();
    try apply(std.testing.allocator, &cached, &state, created.value);

    var first = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-1\",\"predecessors\":[],\"items\":[{\"id\":\"alpha\",\"owner\":\"owner-a\",\"status\":\"open\"}]}}",
        .{ .allocate = .alloc_always },
    );
    defer first.deinit();
    try apply(std.testing.allocator, &cached, &state, first.value);

    var second = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-2\",\"predecessors\":[\"set-1\"],\"items\":[{\"id\":\"alpha\",\"owner\":\"owner-a\",\"status\":\"closed\"},{\"id\":\"beta\",\"owner\":\"owner-b\",\"status\":\"open\"}]}}",
        .{ .allocate = .alloc_always },
    );
    defer second.deinit();
    try apply(std.testing.allocator, &cached, &state, second.value);
    const item_index = findRegister(cached.registers, "items").?;
    const items_state = registerStateConst(&state, item_index).value.?;
    try std.testing.expectEqualStrings(
        "[{\"key\":\"alpha\",\"occurrences\":2,\"source\":\"set-2\",\"value\":{\"id\":\"alpha\",\"owner\":\"owner-a\",\"status\":\"closed\"}},{\"key\":\"beta\",\"occurrences\":1,\"source\":\"set-2\",\"value\":{\"id\":\"beta\",\"owner\":\"owner-b\",\"status\":\"open\"}}]",
        items_state.bytes,
    );
    const before_invalid = try std.testing.allocator.dupe(
        u8,
        items_state.bytes,
    );
    defer std.testing.allocator.free(before_invalid);

    var unstable = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-3\",\"predecessors\":[\"set-2\"],\"items\":[{\"id\":\"alpha\",\"owner\":\"owner-c\",\"status\":\"wrong\"}]}}",
        .{ .allocate = .alloc_always },
    );
    defer unstable.deinit();
    try std.testing.expectError(
        error.RetainedUpsertStableValueChanged,
        apply(std.testing.allocator, &cached, &state, unstable.value),
    );
    try std.testing.expectEqualStrings(
        before_invalid,
        registerStateConst(&state, item_index).value.?.bytes,
    );

    var stale = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-3\",\"predecessors\":[\"set-1\"],\"items\":[{\"id\":\"alpha\",\"owner\":\"owner-a\",\"status\":\"wrong\"}]}}",
        .{ .allocate = .alloc_always },
    );
    defer stale.deinit();
    try std.testing.expectError(
        error.RetainedUpsertPredecessorMissing,
        apply(std.testing.allocator, &cached, &state, stale.value),
    );
    try std.testing.expectEqualStrings(
        before_invalid,
        registerStateConst(&state, item_index).value.?.bytes,
    );

    var duplicate = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-3\",\"predecessors\":[],\"items\":[{\"id\":\"gamma\",\"owner\":\"owner-c\",\"status\":\"open\"},{\"id\":\"gamma\",\"owner\":\"owner-c\",\"status\":\"closed\"}]}}",
        .{ .allocate = .alloc_always },
    );
    defer duplicate.deinit();
    try std.testing.expectError(
        error.RetainedUpsertDuplicateKey,
        apply(std.testing.allocator, &cached, &state, duplicate.value),
    );
    try std.testing.expectEqualStrings(
        before_invalid,
        registerStateConst(&state, item_index).value.?.bytes,
    );

    var overflow = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-3\",\"predecessors\":[],\"items\":[{\"id\":\"gamma\",\"owner\":\"owner-c\",\"status\":\"open\"},{\"id\":\"delta\",\"owner\":\"owner-d\",\"status\":\"open\"}]}}",
        .{ .allocate = .alloc_always },
    );
    defer overflow.deinit();
    try std.testing.expectError(
        error.RetainedUpsertBoundsExceeded,
        apply(std.testing.allocator, &cached, &state, overflow.value),
    );
    try std.testing.expectEqualStrings(
        before_invalid,
        registerStateConst(&state, item_index).value.?.bytes,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        applyUpsertForAllocationFailure,
        .{
            &cached,
            created.value,
            first.value,
            second.value,
        },
    );
}

test "retained state follows carrier names across definition plans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "first.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/state-evolution","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["reducer"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":[{"op":"reducer","mode":"retained","event_kind":"/kind","registers":[{"name":"current","max_bytes":4096}],"admissions":[{"on":"created","requires":[],"forbids":["current"],"rules":[],"actions":[{"op":"set","register":"current","input":"event","path":"/body"}]}]}],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":8192,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "second.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/state-evolution","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["reducer"]},"parameters":{},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":[{"op":"reducer","mode":"retained","event_kind":"/kind","registers":[{"name":"current","max_bytes":4096}],"sets":[{"name":"used_ids","max_entries":4,"max_key_bytes":16,"max_bytes":64}],"admissions":[{"on":"updated","requires":["current"],"forbids":[],"set_guards":[{"set":"used_ids","input":"event","path":"/body/id","presence":"absent"}],"rules":[],"actions":[{"op":"set","register":"current","input":"event","path":"/body"},{"op":"insert","set":"used_ids","input":"event","path":"/body/id"}]}]}],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":8192,"max_records":4,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":4}}
        ,
    });
    var first_closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "first.json",
        .{},
    );
    defer first_closure.deinit(std.testing.allocator);
    var first_definition = try definition.compile(
        std.testing.allocator,
        &first_closure,
        "first.json",
    );
    defer first_definition.deinit(std.testing.allocator);
    const first_rule = for (first_definition.rules) |rule| {
        if (rule.operator == .reducer) break rule;
    } else return error.TestReducerRuleMissing;
    var first_plan = try compile(
        std.testing.allocator,
        &first_definition,
        first_rule,
        4096,
    );
    defer first_plan.deinit(std.testing.allocator);

    var second_closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "second.json",
        .{},
    );
    defer second_closure.deinit(std.testing.allocator);
    var second_definition = try definition.compile(
        std.testing.allocator,
        &second_closure,
        "second.json",
    );
    defer second_definition.deinit(std.testing.allocator);
    const second_rule = for (second_definition.rules) |rule| {
        if (rule.operator == .reducer) break rule;
    } else return error.TestReducerRuleMissing;
    var second_plan = try compile(
        std.testing.allocator,
        &second_definition,
        second_rule,
        4096,
    );
    defer second_plan.deinit(std.testing.allocator);

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var created = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"created\",\"body\":{\"id\":\"item-1\",\"status\":\"open\"}}",
        .{ .allocate = .alloc_always },
    );
    defer created.deinit();
    try apply(std.testing.allocator, &first_plan, &state, created.value);
    var updated = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"item-2\",\"status\":\"closed\"}}",
        .{ .allocate = .alloc_always },
    );
    defer updated.deinit();
    try apply(std.testing.allocator, &second_plan, &state, updated.value);
    try std.testing.expectEqual(@as(usize, 1), state.registers.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.sets.items.len);
    try std.testing.expectError(
        error.IllegalRetainedTransition,
        apply(std.testing.allocator, &second_plan, &state, updated.value),
    );
    var status_pointer = try definition_core.json_pointer.compile(
        std.testing.allocator,
        "/status",
    );
    defer status_pointer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "closed",
        definition_core.json_pointer.lookup(
            state.get(&second_plan, "current").?,
            status_pointer,
        ).?.string,
    );

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{ &second_definition, second_rule, @as(usize, 4096) },
    );
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        256 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(&second_plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{payload},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        applyEvolutionForAllocationFailure,
        .{
            &first_plan,
            &second_plan,
            created.value,
            updated.value,
        },
    );
}
