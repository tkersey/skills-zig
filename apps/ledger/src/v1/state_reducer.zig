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
    try validateRetainedRuleHeader(object);
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

fn validateRetainedRuleHeader(object: std.json.ObjectMap) !void {
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "op"),
        "reducer",
    ) or !std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "mode"),
        "retained",
    )) return error.RetainedReducerModeMismatch;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(3);
    try encoder.writeBytes(plan.event_kind.raw);
    try encodeRegisters(plan.registers, encoder);
    try encodeSets(plan.sets, encoder);
    try encoder.writeCount(plan.admissions.len);
    for (plan.admissions) |admission| {
        try encodeAdmission(admission, encoder);
    }
}

fn encodeRegisters(
    registers: []const Register,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(registers.len);
    for (registers) |register| {
        try encoder.writeBytes(register.name);
        try encoder.writeUsize(register.max_bytes);
    }
}

fn encodeSets(
    sets: []const RetainedSet,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(sets.len);
    for (sets) |set| {
        try encoder.writeBytes(set.name);
        try encoder.writeUsize(set.max_entries);
        try encoder.writeUsize(set.max_key_bytes);
        try encoder.writeUsize(set.max_bytes);
    }
}

fn encodeAdmission(
    admission: Admission,
    encoder: *definition_core.cache.Encoder,
) !void {
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
    for (admission.actions) |action| try encodeAction(action, encoder);
}

fn encodeAction(
    action: Action,
    encoder: *definition_core.cache.Encoder,
) !void {
    switch (action) {
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
        .upsert => |upsert| try encodeUpsertAction(upsert, encoder),
    }
}

fn encodeUpsertAction(
    upsert: UpsertAction,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeByte(3);
    try encoder.writeU16(upsert.target);
    try encodeSource(upsert.source, encoder);
    try encoder.writeBytes(upsert.collection.raw);
    try encoder.writeBytes(upsert.key.raw);
    try encoder.writeBytes(upsert.source_ref.raw);
    try encoder.writeBytes(upsert.predecessor_refs.raw);
    try encoder.writeCount(upsert.stable.len);
    for (upsert.stable) |pointer| try encoder.writeBytes(pointer.raw);
    try encoder.writeUsize(upsert.max_entries);
    try encoder.writeUsize(upsert.max_key_bytes);
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
    const registers = try decodeRegisters(allocator, decoder);
    errdefer deinitRegisters(allocator, registers);
    const sets = try decodeSets(allocator, decoder);
    errdefer deinitSets(allocator, sets);
    const admissions = try decodeAdmissions(
        allocator,
        decoder,
        registers.len,
        sets.len,
    );
    errdefer deinitAdmissions(allocator, admissions);
    return .{
        .event_kind = event_kind,
        .registers = registers,
        .sets = sets,
        .admissions = admissions,
        .layout_digest = retainedLayoutDigest(registers, sets),
    };
}

fn decodeRegisters(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]Register {
    const count = try decoder.readCount(max_registers);
    if (count == 0) return error.InvalidRetainedRegisterCount;
    const registers = try allocator.alloc(Register, count);
    var initialized: usize = 0;
    errdefer {
        for (registers[0..initialized]) |*register| register.deinit(allocator);
        allocator.free(registers);
    }
    for (registers) |*register| {
        register.* = .{
            .name = try decoder.readBytesAlloc(allocator, 128),
            .max_bytes = try decoder.readUsize(),
        };
        initialized += 1;
    }
    return registers;
}

fn decodeSets(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]RetainedSet {
    const count = try decoder.readCount(max_sets);
    const sets = try allocator.alloc(RetainedSet, count);
    var initialized: usize = 0;
    errdefer {
        for (sets[0..initialized]) |*set| set.deinit(allocator);
        allocator.free(sets);
    }
    for (sets) |*set| {
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        set.* = .{
            .name = name,
            .max_entries = try decoder.readUsize(),
            .max_key_bytes = try decoder.readUsize(),
            .max_bytes = try decoder.readUsize(),
        };
        initialized += 1;
    }
    return sets;
}

fn decodeAdmissions(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    register_count: usize,
    set_count: usize,
) ![]Admission {
    const count = try decoder.readCount(max_admissions);
    if (count == 0) return error.InvalidRetainedAdmissionCount;
    const admissions = try allocator.alloc(Admission, count);
    var initialized: usize = 0;
    errdefer {
        for (admissions[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(admissions);
    }
    for (admissions) |*admission| {
        admission.* = try decodeAdmission(
            allocator,
            decoder,
            register_count,
            set_count,
        );
        initialized += 1;
    }
    return admissions;
}

fn decodeAdmission(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    register_count: usize,
    set_count: usize,
) !Admission {
    const on = try decoder.readBytesAlloc(allocator, 256);
    errdefer allocator.free(on);
    const required = try decodeIndexes(allocator, decoder, register_count);
    errdefer allocator.free(required);
    const forbidden = try decodeIndexes(allocator, decoder, register_count);
    errdefer allocator.free(forbidden);
    const set_guards = try decodeSetGuards(
        allocator,
        decoder,
        register_count,
        set_count,
    );
    errdefer deinitSetGuards(allocator, set_guards);
    var validation_plan = try validation.decodeCache(allocator, decoder);
    errdefer validation_plan.deinit(allocator);
    const actions = try decodeActions(allocator, decoder, register_count);
    errdefer {
        for (actions) |*action| action.deinit(allocator);
        allocator.free(actions);
    }
    return .{
        .on = on,
        .required = required,
        .forbidden = forbidden,
        .set_guards = set_guards,
        .validation_plan = validation_plan,
        .actions = actions,
    };
}

fn decodeActions(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    register_count: usize,
) ![]Action {
    const count = try decoder.readCount(max_actions);
    const actions = try allocator.alloc(Action, count);
    var initialized: usize = 0;
    errdefer {
        for (actions[0..initialized]) |*action| action.deinit(allocator);
        allocator.free(actions);
    }
    for (actions) |*action| {
        action.* = try decodeAction(allocator, decoder, register_count);
        initialized += 1;
    }
    return actions;
}

fn decodeAction(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    register_count: usize,
) !Action {
    return switch (try decoder.readByte()) {
        0 => .{ .set = try decodeSetAction(
            allocator,
            decoder,
            register_count,
        ) },
        1 => .{ .clear = try decoder.readU16() },
        2 => .{ .insert = .{
            .target = try decoder.readU16(),
            .source = try decodeSource(decoder, register_count),
            .pointer = try decodePointer(allocator, decoder),
        } },
        3 => .{ .upsert = try decodeUpsertAction(
            allocator,
            decoder,
            register_count,
        ) },
        else => error.CacheStateActionInvalid,
    };
}

fn decodeSetAction(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    _: usize,
) !SetAction {
    const target = try decoder.readU16();
    const source: Source = switch (try decoder.readByte()) {
        0 => .event,
        1 => .{ .register = try decoder.readU16() },
        else => return error.CacheStateActionSourceInvalid,
    };
    return .{
        .target = target,
        .source = source,
        .pointer = try decodePointer(allocator, decoder),
    };
}

fn decodeUpsertAction(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    register_count: usize,
) !UpsertAction {
    const target = try decoder.readU16();
    const source = try decodeSource(decoder, register_count);
    var collection = try decodePointer(allocator, decoder);
    errdefer collection.deinit(allocator);
    var key = try decodePointer(allocator, decoder);
    errdefer key.deinit(allocator);
    var source_ref = try decodePointer(allocator, decoder);
    errdefer source_ref.deinit(allocator);
    var predecessors = try decodePointer(allocator, decoder);
    errdefer predecessors.deinit(allocator);
    const stable = try decodeStablePointers(allocator, decoder);
    errdefer deinitPointers(allocator, stable);
    return .{
        .target = target,
        .source = source,
        .collection = collection,
        .key = key,
        .source_ref = source_ref,
        .predecessor_refs = predecessors,
        .stable = stable,
        .max_entries = try decoder.readUsize(),
        .max_key_bytes = try decoder.readUsize(),
    };
}

fn decodeStablePointers(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]definition_core.json_pointer.Pointer {
    const count = try decoder.readCount(max_stable_pointers);
    const pointers = try allocator.alloc(
        definition_core.json_pointer.Pointer,
        count,
    );
    var initialized: usize = 0;
    errdefer {
        for (pointers[0..initialized]) |*pointer| pointer.deinit(allocator);
        allocator.free(pointers);
    }
    for (pointers) |*pointer| {
        pointer.* = try decodePointer(allocator, decoder);
        initialized += 1;
    }
    return pointers;
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
    try validateRegisterPlans(plan, definition_plan);
    try validateSetPlans(plan, definition_plan);
    for (plan.admissions, 0..) |*admission, index| {
        try validateAdmissionPlan(
            plan,
            definition_plan,
            admission,
            index,
            event_max_bytes,
        );
    }
}

fn validateRegisterPlans(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
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
}

fn validateSetPlans(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
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
}

fn validateAdmissionPlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    admission: *const Admission,
    index: usize,
    event_max_bytes: usize,
) !void {
    try definition_core.json.safeIdentifier(admission.on, 256);
    try validateIndexes(admission.required, plan.registers.len);
    try validateIndexes(admission.forbidden, plan.registers.len);
    if (setsIntersect(admission.required, admission.forbidden)) {
        return error.ConflictingRetainedAdmissionState;
    }
    try validateSetGuards(plan, admission);
    try validation.validateEmbeddedCachePlan(
        &admission.validation_plan,
        definition_plan,
    );
    try validateAdmissionInputs(plan, admission, event_max_bytes);
    try validateActions(plan, definition_plan, admission);
    for (plan.admissions[0..index]) |prior| {
        if (std.mem.eql(u8, prior.on, admission.on) and
            admissionsOverlap(prior, admission.*))
        {
            return error.AmbiguousRetainedAdmission;
        }
    }
}

fn validateSetGuards(
    plan: *const Plan,
    admission: *const Admission,
) !void {
    for (admission.set_guards, 0..) |guard, index| {
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
        for (admission.set_guards[0..index]) |prior| {
            if (prior.set != guard.set or
                !sourceEqual(prior.source, guard.source) or
                !std.mem.eql(u8, prior.pointer.raw, guard.pointer.raw))
            {
                continue;
            }
            if (prior.presence != guard.presence or prior.mode != guard.mode) {
                return error.ConflictingRetainedSetGuard;
            }
            return error.DuplicateRetainedSetGuard;
        }
    }
}

fn validateActions(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    admission: *const Admission,
) !void {
    for (admission.actions, 0..) |action, index| {
        try validateAction(plan, definition_plan, admission, action);
        for (admission.actions[0..index]) |prior| {
            if (actionsConflict(prior, action)) {
                return error.DuplicateRetainedActionTarget;
            }
        }
    }
}

fn validateAction(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    admission: *const Admission,
    action: Action,
) !void {
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
                !containsIndex(admission.required, set.source.register))
            {
                return error.RetainedActionSourceNotRequired;
            }
        },
        .clear => |target| if (target >= plan.registers.len) {
            return error.InvalidRetainedActionTarget;
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
        .upsert => |upsert| try validateUpsertAction(
            plan,
            definition_plan,
            admission,
            upsert,
        ),
    }
}

fn validateUpsertAction(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    admission: *const Admission,
    upsert: UpsertAction,
) !void {
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
        upsert.max_entries > definition_plan.bounds.max_records or
        upsert.max_key_bytes == 0 or
        upsert.max_key_bytes > plan.registers[upsert.target].max_bytes)
    {
        return error.InvalidRetainedUpsertAction;
    }
    for (upsert.stable, 0..) |pointer, index| {
        if (pointer.raw.len > 1024) {
            return error.InvalidRetainedUpsertAction;
        }
        for (upsert.stable[0..index]) |prior| {
            if (std.mem.eql(u8, prior.raw, pointer.raw)) {
                return error.InvalidRetainedUpsertAction;
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
        sets[initialized] = try compileSet(
            allocator,
            try definition_core.json.object(value),
            max_entries,
            max_store_bytes,
        );
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

fn compileSet(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    max_entries: usize,
    max_store_bytes: usize,
) !RetainedSet {
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
    return .{
        .name = try allocator.dupe(u8, name),
        .max_entries = entry_bound,
        .max_key_bytes = key_bound,
        .max_bytes = byte_bound,
    };
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
        admissions[initialized] = try compileAdmission(
            allocator,
            definition_plan,
            registers,
            sets,
            try definition_core.json.object(value),
            event_max_bytes,
        );
        initialized += 1;
    }
    return admissions;
}

fn compileAdmission(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    registers: []const Register,
    sets: []const RetainedSet,
    object: std.json.ObjectMap,
    event_max_bytes: usize,
) !Admission {
    const on = try validateAdmissionObject(object);
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
    const guards = try compileOptionalSetGuards(
        allocator,
        registers,
        sets,
        required,
        object,
    );
    errdefer deinitSetGuards(allocator, guards);
    var validator = try compileAdmissionValidator(
        allocator,
        definition_plan,
        registers,
        required,
        object,
        event_max_bytes,
    );
    errdefer validator.deinit(allocator);
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
    return .{
        .on = try allocator.dupe(u8, on),
        .required = required,
        .forbidden = forbidden,
        .set_guards = guards,
        .validation_plan = validator,
        .actions = actions,
    };
}

fn validateAdmissionObject(object: std.json.ObjectMap) ![]const u8 {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "on", "requires", "forbids", "set_guards", "rules", "actions" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "on", "requires", "forbids", "rules", "actions" },
    );
    const on = try definition_core.json.requiredString(object, "on");
    try definition_core.json.safeIdentifier(on, 256);
    return on;
}

fn compileOptionalSetGuards(
    allocator: std.mem.Allocator,
    registers: []const Register,
    sets: []const RetainedSet,
    required: []const u16,
    object: std.json.ObjectMap,
) ![]SetGuard {
    const raw = object.get("set_guards") orelse
        return allocator.alloc(SetGuard, 0);
    return compileSetGuards(allocator, registers, sets, required, raw);
}

fn compileAdmissionValidator(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    registers: []const Register,
    required: []const u16,
    object: std.json.ObjectMap,
    event_max_bytes: usize,
) !validation.Plan {
    const inputs = try admissionInputsAlloc(
        allocator,
        event_max_bytes,
        registers,
        required,
    );
    defer deinitInputs(allocator, inputs);
    return validation.compileEmbedded(
        allocator,
        definition_plan,
        inputs,
        try definition_core.json.field(object, "rules"),
        definition_plan.bounds.max_input_bytes,
        definition_plan.bounds.max_records,
        definition_plan.bounds.max_diagnostics,
    );
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
        const candidate = try compileSetGuard(
            allocator,
            registers,
            sets,
            required,
            try definition_core.json.object(value),
        );
        errdefer {
            var owned = candidate;
            owned.deinit(allocator);
        }
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

fn compileSetGuard(
    allocator: std.mem.Allocator,
    registers: []const Register,
    sets: []const RetainedSet,
    required: []const u16,
    object: std.json.ObjectMap,
) !SetGuard {
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
    return .{
        .set = @intCast(set_index),
        .source = source,
        .pointer = pointer,
        .presence = presence,
        .mode = mode,
    };
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
        actions[initialized] = try compileAction(
            allocator,
            registers,
            sets,
            required,
            object,
            max_records,
            seen_targets,
            seen_set_targets,
        );
        initialized += 1;
    }
    return actions;
}

fn compileAction(
    allocator: std.mem.Allocator,
    registers: []const Register,
    sets: []const RetainedSet,
    required: []const u16,
    object: std.json.ObjectMap,
    max_records: usize,
    seen_registers: []bool,
    seen_sets: []bool,
) !Action {
    const operator = try definition_core.json.requiredString(object, "op");
    if (std.mem.eql(u8, operator, "set")) {
        return .{ .set = try compileSetAction(
            allocator,
            registers,
            object,
            seen_registers,
        ) };
    }
    if (std.mem.eql(u8, operator, "clear")) {
        return .{ .clear = try compileClearAction(
            registers,
            object,
            seen_registers,
        ) };
    }
    if (std.mem.eql(u8, operator, "insert")) {
        return .{ .insert = try compileInsertAction(
            allocator,
            registers,
            sets,
            required,
            object,
            seen_sets,
        ) };
    }
    if (std.mem.eql(u8, operator, "upsert")) {
        return .{ .upsert = try compileUpsertAction(
            allocator,
            registers,
            required,
            object,
            max_records,
            seen_registers,
        ) };
    }
    return error.UnsupportedRetainedAction;
}

fn compileSetAction(
    allocator: std.mem.Allocator,
    registers: []const Register,
    object: std.json.ObjectMap,
    seen: []bool,
) !SetAction {
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
    try claimActionTarget(seen, target);
    const input = try definition_core.json.requiredString(object, "input");
    const source: Source = if (std.mem.eql(u8, input, "event"))
        .event
    else
        .{ .register = @intCast(findRegister(registers, input) orelse
            return error.UnknownRetainedRegister) };
    return .{
        .target = @intCast(target),
        .source = source,
        .pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(
                try definition_core.json.field(object, "path"),
            ),
        ),
    };
}

fn compileClearAction(
    registers: []const Register,
    object: std.json.ObjectMap,
    seen: []bool,
) !u16 {
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
        try definition_core.json.requiredString(object, "register"),
    ) orelse return error.UnknownRetainedRegister;
    try claimActionTarget(seen, target);
    return @intCast(target);
}

fn compileInsertAction(
    allocator: std.mem.Allocator,
    registers: []const Register,
    sets: []const RetainedSet,
    required: []const u16,
    object: std.json.ObjectMap,
    seen: []bool,
) !InsertAction {
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
    try claimActionTarget(seen, target);
    return .{
        .target = @intCast(target),
        .source = try compileSource(
            registers,
            required,
            try definition_core.json.requiredString(object, "input"),
        ),
        .pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.requiredString(object, "path"),
        ),
    };
}

fn claimActionTarget(seen: []bool, target: usize) !void {
    if (seen[target]) return error.DuplicateRetainedActionTarget;
    seen[target] = true;
}

const UpsertPointers = struct {
    collection: definition_core.json_pointer.Pointer,
    key: definition_core.json_pointer.Pointer,
    source_ref: definition_core.json_pointer.Pointer,
    predecessor_refs: definition_core.json_pointer.Pointer,
    stable: []definition_core.json_pointer.Pointer,

    fn deinit(self: *UpsertPointers, allocator: std.mem.Allocator) void {
        self.collection.deinit(allocator);
        self.key.deinit(allocator);
        self.source_ref.deinit(allocator);
        self.predecessor_refs.deinit(allocator);
        deinitPointers(allocator, self.stable);
        self.* = undefined;
    }
};

fn compileUpsertAction(
    allocator: std.mem.Allocator,
    registers: []const Register,
    required: []const u16,
    object: std.json.ObjectMap,
    max_records: usize,
    seen: []bool,
) !UpsertAction {
    try requireUpsertFields(object);
    const target = findRegister(
        registers,
        try definition_core.json.requiredString(object, "register"),
    ) orelse return error.UnknownRetainedRegister;
    if (seen[target]) return error.DuplicateRetainedActionTarget;
    if (!containsIndex(required, @intCast(target))) {
        return error.RetainedActionTargetNotRequired;
    }
    seen[target] = true;
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
    var pointers = try compileUpsertPointers(allocator, object);
    errdefer pointers.deinit(allocator);
    return .{
        .target = @intCast(target),
        .source = source,
        .collection = pointers.collection,
        .key = pointers.key,
        .source_ref = pointers.source_ref,
        .predecessor_refs = pointers.predecessor_refs,
        .stable = pointers.stable,
        .max_entries = entry_bound,
        .max_key_bytes = key_bound,
    };
}

fn requireUpsertFields(object: std.json.ObjectMap) !void {
    const fields = &.{
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
    };
    try definition_core.json.requireExactKeys(object, fields);
    try definition_core.json.requireFields(object, fields);
}

fn compileUpsertPointers(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !UpsertPointers {
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
    var predecessors = try definition_core.json_pointer.compile(
        allocator,
        try definition_core.json.requiredString(object, "predecessor_refs"),
    );
    errdefer predecessors.deinit(allocator);
    const stable = try compilePointerList(
        allocator,
        try definition_core.json.field(object, "stable"),
        max_stable_pointers,
    );
    errdefer deinitPointers(allocator, stable);
    return .{
        .collection = collection,
        .key = key,
        .source_ref = source_ref,
        .predecessor_refs = predecessors,
        .stable = stable,
    };
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
    var prepared = try PreparedActions.init(allocator, actions.len);
    defer prepared.deinit(allocator);
    for (actions, 0..) |action, index| switch (action) {
        .clear => {},
        .set => |set| prepared.values[index] = try prepareSet(
            allocator,
            plan,
            state,
            event,
            set,
        ),
        .insert => |insert| prepared.keys[index] = try prepareInsert(
            allocator,
            plan,
            state,
            event,
            insert,
        ),
        .upsert => |upsert| {
            prepared.values[index] = try prepareUpsert(
                allocator,
                plan,
                state,
                event,
                upsert,
            );
        },
    };
    try reserveSetActions(allocator, state, actions);
    commitActions(allocator, state, actions, &prepared);
}

const PreparedActions = struct {
    values: []?OwnedValue,
    keys: []?[]u8,

    fn init(
        allocator: std.mem.Allocator,
        count: usize,
    ) !PreparedActions {
        const values = try allocator.alloc(?OwnedValue, count);
        errdefer allocator.free(values);
        @memset(values, null);
        const keys = try allocator.alloc(?[]u8, count);
        errdefer allocator.free(keys);
        @memset(keys, null);
        return .{ .values = values, .keys = keys };
    }

    fn deinit(self: *PreparedActions, allocator: std.mem.Allocator) void {
        for (self.values) |*value| {
            if (value.*) |*owned| owned.deinit(allocator);
        }
        for (self.keys) |key| {
            if (key) |owned| allocator.free(owned);
        }
        allocator.free(self.values);
        allocator.free(self.keys);
        self.* = undefined;
    }
};

fn prepareSet(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const State,
    event: std.json.Value,
    action: SetAction,
) !OwnedValue {
    const root = try sourceValue(plan, state, action.source, event);
    const value = definition_core.json_pointer.lookup(
        root,
        action.pointer,
    ) orelse return error.RetainedActionValueMissing;
    const canonical =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            value,
        );
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
            .parse_numbers = false,
        },
    );
    errdefer parsed.deinit();
    return .{ .bytes = canonical, .parsed = parsed };
}

fn prepareInsert(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const State,
    event: std.json.Value,
    action: InsertAction,
) ![]u8 {
    const root = try sourceValue(plan, state, action.source, event);
    const value = definition_core.json_pointer.lookup(
        root,
        action.pointer,
    ) orelse return error.RetainedActionValueMissing;
    const key = try definition_core.json.string(value);
    const set_plan = plan.sets[action.target];
    const set_state = &setStateConst(state, action.target).value;
    if (key.len > set_plan.max_key_bytes or
        set_state.entries.count() >= set_plan.max_entries or
        set_state.bytes > set_plan.max_bytes -| key.len)
    {
        return error.RetainedSetBoundsExceeded;
    }
    if (try set_state.contains(key)) return error.RetainedSetDuplicateKey;
    return allocator.dupe(u8, key);
}

fn reserveSetActions(
    allocator: std.mem.Allocator,
    state: *State,
    actions: []const Action,
) !void {
    for (actions) |action| switch (action) {
        .insert => |insert| {
            try setState(state, insert.target).value.entries.ensureUnusedCapacity(
                allocator,
                1,
            );
        },
        .set, .clear, .upsert => {},
    };
}

fn commitActions(
    allocator: std.mem.Allocator,
    state: *State,
    actions: []const Action,
    prepared: *PreparedActions,
) void {
    for (actions, 0..) |action, index| {
        switch (action) {
            .set => |set| {
                const target = registerState(state, set.target);
                if (target.value) |*prior| {
                    prior.deinit(allocator);
                }
                target.value = prepared.values[index];
                prepared.values[index] = null;
            },
            .clear => |target| {
                const target_state = registerState(state, target);
                if (target_state.value) |*prior| prior.deinit(allocator);
                target_state.value = null;
            },
            .insert => |insert| {
                setState(state, insert.target).value.insertAssumeCapacity(
                    prepared.keys[index].?,
                );
                prepared.keys[index] = null;
            },
            .upsert => |upsert| {
                const target = registerState(state, upsert.target);
                if (target.value) |*prior| prior.deinit(allocator);
                target.value = prepared.values[index];
                prepared.values[index] = null;
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
    const existing_values = try resolveExistingUpsertValues(state, action);
    const root = try sourceValue(plan, state, action.source, event);
    const inputs = try resolveUpsertInputs(root, action, existing_values);
    var predecessors: std.AutoHashMapUnmanaged([32]u8, []const u8) = .empty;
    defer predecessors.deinit(allocator);
    try indexPredecessors(
        allocator,
        &predecessors,
        inputs.predecessors,
        action.max_key_bytes,
    );
    var existing = try ExistingUpsertIndex.init(
        allocator,
        inputs.existing,
        action,
    );
    defer existing.deinit(allocator);
    var source_keys: std.AutoHashMapUnmanaged([32]u8, []const u8) = .empty;
    defer source_keys.deinit(allocator);
    var new_entries: std.ArrayList(NewUpsertEntry) = .empty;
    defer new_entries.deinit(allocator);
    try mergeIncomingEntries(
        allocator,
        action,
        inputs.incoming,
        &predecessors,
        &existing,
        &source_keys,
        &new_entries,
    );
    return materializeUpsert(
        allocator,
        plan.registers[action.target].max_bytes,
        inputs.source_ref,
        existing.entries,
        new_entries.items,
    );
}

fn resolveExistingUpsertValues(
    state: *const State,
    action: UpsertAction,
) ![]const std.json.Value {
    const current = registerStateConst(state, action.target).value orelse
        return error.RetainedUpsertTargetMissing;
    const existing = try upsertArray(
        current.parsed.value,
        error.RetainedUpsertStateInvalid,
    );
    if (existing.len > action.max_entries) {
        return error.RetainedUpsertBoundsExceeded;
    }
    return existing;
}

const UpsertInputs = struct {
    existing: []const std.json.Value,
    incoming: []const std.json.Value,
    predecessors: []const std.json.Value,
    source_ref: []const u8,
};

fn resolveUpsertInputs(
    root: std.json.Value,
    action: UpsertAction,
    existing: []const std.json.Value,
) !UpsertInputs {
    const incoming_value = definition_core.json_pointer.lookup(
        root,
        action.collection,
    ) orelse return error.RetainedUpsertSourceMissing;
    const incoming = try upsertArray(
        incoming_value,
        error.RetainedUpsertSourceInvalid,
    );
    if (incoming.len > action.max_entries) {
        return error.RetainedUpsertBoundsExceeded;
    }
    const source_ref = try boundedUpsertString(
        definition_core.json_pointer.lookup(
            root,
            action.source_ref,
        ) orelse return error.RetainedUpsertSourceMissing,
        action.max_key_bytes,
    );
    const predecessor_value = definition_core.json_pointer.lookup(
        root,
        action.predecessor_refs,
    ) orelse return error.RetainedUpsertSourceMissing;
    const predecessors = try upsertArray(
        predecessor_value,
        error.RetainedUpsertSourceInvalid,
    );
    if (predecessors.len > action.max_entries) {
        return error.RetainedUpsertBoundsExceeded;
    }
    return .{
        .existing = existing,
        .incoming = incoming,
        .predecessors = predecessors,
        .source_ref = source_ref,
    };
}

fn upsertArray(
    value: std.json.Value,
    failure: anyerror,
) ![]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => failure,
    };
}

fn indexPredecessors(
    allocator: std.mem.Allocator,
    index: *std.AutoHashMapUnmanaged([32]u8, []const u8),
    values: []const std.json.Value,
    max_key_bytes: usize,
) !void {
    for (values) |value| {
        const reference = try boundedUpsertString(value, max_key_bytes);
        const result = try index.getOrPut(
            allocator,
            retainedKeyDigest(reference),
        );
        if (result.found_existing and
            !std.mem.eql(u8, result.value_ptr.*, reference))
        {
            return error.RetainedUpsertDigestCollision;
        }
        result.value_ptr.* = reference;
    }
}

const ExistingUpsertIndex = struct {
    entries: []ExistingUpsertEntry,
    positions: std.AutoHashMapUnmanaged([32]u8, usize),

    fn init(
        allocator: std.mem.Allocator,
        values: []const std.json.Value,
        action: UpsertAction,
    ) !ExistingUpsertIndex {
        const entries = try allocator.alloc(ExistingUpsertEntry, values.len);
        errdefer allocator.free(entries);
        var positions: std.AutoHashMapUnmanaged([32]u8, usize) = .empty;
        errdefer positions.deinit(allocator);
        for (values, 0..) |value, index| {
            entries[index] = try parseExistingUpsertEntry(value, action);
            const result = try positions.getOrPut(
                allocator,
                retainedKeyDigest(entries[index].key),
            );
            if (result.found_existing) {
                if (!std.mem.eql(
                    u8,
                    entries[result.value_ptr.*].key,
                    entries[index].key,
                )) return error.RetainedUpsertDigestCollision;
                return error.RetainedUpsertStateInvalid;
            }
            result.value_ptr.* = index;
        }
        return .{ .entries = entries, .positions = positions };
    }

    fn deinit(
        self: *ExistingUpsertIndex,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.entries);
        self.positions.deinit(allocator);
        self.* = undefined;
    }
};

fn parseExistingUpsertEntry(
    value: std.json.Value,
    action: UpsertAction,
) !ExistingUpsertEntry {
    const object = definition_core.json.object(value) catch
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
    const selected = boundedUpsertString(
        retained_key,
        action.max_key_bytes,
    ) catch return error.RetainedUpsertStateInvalid;
    if (!std.mem.eql(u8, key, selected)) {
        return error.RetainedUpsertStateInvalid;
    }
    return .{
        .key = key,
        .occurrences = occurrences,
        .source = source,
        .value = retained_value,
    };
}

fn mergeIncomingEntries(
    allocator: std.mem.Allocator,
    action: UpsertAction,
    incoming: []const std.json.Value,
    predecessors: *const std.AutoHashMapUnmanaged([32]u8, []const u8),
    existing: *ExistingUpsertIndex,
    source_keys: *std.AutoHashMapUnmanaged([32]u8, []const u8),
    new_entries: *std.ArrayList(NewUpsertEntry),
) !void {
    for (incoming) |value| {
        try mergeIncomingEntry(
            allocator,
            action,
            value,
            predecessors,
            existing,
            source_keys,
            new_entries,
        );
    }
}

fn mergeIncomingEntry(
    allocator: std.mem.Allocator,
    action: UpsertAction,
    incoming: std.json.Value,
    predecessors: *const std.AutoHashMapUnmanaged([32]u8, []const u8),
    existing: *ExistingUpsertIndex,
    source_keys: *std.AutoHashMapUnmanaged([32]u8, []const u8),
    new_entries: *std.ArrayList(NewUpsertEntry),
) !void {
    const raw_key = definition_core.json_pointer.lookup(
        incoming,
        action.key,
    ) orelse return error.RetainedUpsertKeyMissing;
    const key = try boundedUpsertString(raw_key, action.max_key_bytes);
    const digest = retainedKeyDigest(key);
    const result = try source_keys.getOrPut(allocator, digest);
    if (result.found_existing) {
        if (!std.mem.eql(u8, result.value_ptr.*, key)) {
            return error.RetainedUpsertDigestCollision;
        }
        return error.RetainedUpsertDuplicateKey;
    }
    result.value_ptr.* = key;
    if (existing.positions.get(digest)) |position| {
        return replaceExistingUpsert(
            action,
            incoming,
            key,
            predecessors,
            &existing.entries[position],
        );
    }
    if (existing.entries.len + new_entries.items.len >= action.max_entries) {
        return error.RetainedUpsertBoundsExceeded;
    }
    try new_entries.append(allocator, .{ .key = key, .value = incoming });
}

fn replaceExistingUpsert(
    action: UpsertAction,
    incoming: std.json.Value,
    key: []const u8,
    predecessors: *const std.AutoHashMapUnmanaged([32]u8, []const u8),
    prior: *ExistingUpsertEntry,
) !void {
    if (!std.mem.eql(u8, prior.key, key)) {
        return error.RetainedUpsertDigestCollision;
    }
    const predecessor = predecessors.get(
        retainedKeyDigest(prior.source),
    ) orelse return error.RetainedUpsertPredecessorMissing;
    if (!std.mem.eql(u8, predecessor, prior.source)) {
        return error.RetainedUpsertDigestCollision;
    }
    for (action.stable) |pointer| {
        const old = definition_core.json_pointer.lookup(
            prior.value,
            pointer,
        ) orelse return error.RetainedUpsertStableValueMissing;
        const new = definition_core.json_pointer.lookup(
            incoming,
            pointer,
        ) orelse return error.RetainedUpsertStableValueMissing;
        if (!validation.valuesEqual(old, new)) {
            return error.RetainedUpsertStableValueChanged;
        }
    }
    if (prior.occurrences == std.math.maxInt(i64)) {
        return error.RetainedUpsertOccurrenceOverflow;
    }
    prior.replacement = incoming;
}

fn materializeUpsert(
    allocator: std.mem.Allocator,
    max_bytes: usize,
    source_ref: []const u8,
    existing: []const ExistingUpsertEntry,
    new_entries: []const NewUpsertEntry,
) !OwnedValue {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try writeUpsertEntries(
        allocator,
        &output.writer,
        source_ref,
        existing,
        new_entries,
    );
    const canonical = try output.toOwnedSlice();
    errdefer allocator.free(canonical);
    if (canonical.len > max_bytes) {
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

fn writeUpsertEntries(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_ref: []const u8,
    existing: []const ExistingUpsertEntry,
    new_entries: []const NewUpsertEntry,
) !void {
    try writer.writeByte('[');
    var emitted: usize = 0;
    for (existing) |entry| {
        if (emitted != 0) try writer.writeByte(',');
        try writeUpsertEntry(
            allocator,
            writer,
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
    for (new_entries) |entry| {
        if (emitted != 0) try writer.writeByte(',');
        try writeUpsertEntry(
            allocator,
            writer,
            entry.key,
            1,
            source_ref,
            entry.value,
        );
        emitted += 1;
    }
    try writer.writeByte(']');
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
    try mapStateRegisters(
        allocator,
        plan,
        state,
        register_map,
        &missing_registers,
    );
    try mapStateSets(allocator, plan, state, set_map, &missing_sets);
    try installStateLayout(
        allocator,
        plan,
        state,
        register_map,
        set_map,
        &missing_registers,
        &missing_sets,
    );
}

fn mapStateRegisters(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const State,
    register_map: []u16,
    missing: *std.ArrayList([]u8),
) !void {
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
        if (state.registers.items.len + missing.items.len >= max_registers) {
            return error.RetainedStateCarrierBoundsExceeded;
        }
        register_map[index] = @intCast(
            state.registers.items.len + missing.items.len,
        );
        const owned_name = try allocator.dupe(u8, register.name);
        errdefer allocator.free(owned_name);
        try missing.append(allocator, owned_name);
    }
}

fn mapStateSets(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const State,
    set_map: []u16,
    missing: *std.ArrayList([]u8),
) !void {
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
        if (state.sets.items.len + missing.items.len >= max_sets) {
            return error.RetainedStateCarrierBoundsExceeded;
        }
        set_map[index] = @intCast(
            state.sets.items.len + missing.items.len,
        );
        const owned_name = try allocator.dupe(u8, set.name);
        errdefer allocator.free(owned_name);
        try missing.append(allocator, owned_name);
    }
}

fn installStateLayout(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *State,
    register_map: []u16,
    set_map: []u16,
    missing_registers: *std.ArrayList([]u8),
    missing_sets: *std.ArrayList([]u8),
) !void {
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

const TestPlan = struct {
    closure: definition_core.Closure,
    artifact: definition.Plan,
    reducer: Plan,
    cache_payload: []u8,

    fn init(source: []const u8) !TestPlan {
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
        errdefer closure.deinit(std.testing.allocator);
        var artifact = try definition.compile(
            std.testing.allocator,
            &closure,
            "definition.json",
        );
        errdefer artifact.deinit(std.testing.allocator);
        const reducer_rule = findTestReducerRule(&artifact);
        var compiled = try compile(
            std.testing.allocator,
            &artifact,
            reducer_rule,
            4096,
        );
        defer compiled.deinit(std.testing.allocator);
        var encoder = definition_core.cache.Encoder.init(
            std.testing.allocator,
            256 * 1024,
        );
        defer encoder.deinit();
        try encodeCache(&compiled, &encoder);
        const payload = try encoder.toOwnedSlice();
        errdefer std.testing.allocator.free(payload);
        var decoder = definition_core.cache.Decoder.init(payload);
        var reducer = try decodeCache(std.testing.allocator, &decoder);
        errdefer reducer.deinit(std.testing.allocator);
        try decoder.finish();
        try validatePlan(&reducer, &artifact, 4096);
        return .{
            .closure = closure,
            .artifact = artifact,
            .reducer = reducer,
            .cache_payload = payload,
        };
    }

    fn deinit(self: *TestPlan) void {
        std.testing.allocator.free(self.cache_payload);
        self.reducer.deinit(std.testing.allocator);
        self.artifact.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.* = undefined;
    }

    fn rule(self: *const TestPlan) definition.Rule {
        return findTestReducerRule(&self.artifact);
    }
};

fn findTestReducerRule(plan: *const definition.Plan) definition.Rule {
    return for (plan.rules) |rule| {
        if (rule.operator == .reducer) break rule;
    } else unreachable;
}

fn parseTestEvent(
    source: []const u8,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        source,
        .{ .allocate = .alloc_always },
    );
}

fn applyTestEvent(
    plan: *const Plan,
    state: *State,
    source: []const u8,
) !void {
    var event = try parseTestEvent(source);
    defer event.deinit();
    try apply(std.testing.allocator, plan, state, event.value);
}

fn expectTestEventError(
    expected: anyerror,
    plan: *const Plan,
    state: *State,
    source: []const u8,
) !void {
    var event = try parseTestEvent(source);
    defer event.deinit();
    try std.testing.expectError(
        expected,
        apply(std.testing.allocator, plan, state, event.value),
    );
}

fn expectRetainedStatus(
    plan: *const Plan,
    state: *const State,
    expected: []const u8,
) !void {
    var pointer = try definition_core.json_pointer.compile(
        std.testing.allocator,
        "/status",
    );
    defer pointer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        expected,
        definition_core.json_pointer.lookup(
            state.get(plan, "current").?,
            pointer,
        ).?.string,
    );
}

const retained_test_prefix =
    \\{
    \\  "schema":"ledger-artifact-definition/v1",
    \\  "id":"example/retained-test",
    \\  "owner":"example",
    \\  "requires":{
    \\    "abi":"ledger-artifact-abi/v1",
    \\    "operators":["reducer"]
    \\  },
    \\  "parameters":{},
    \\  "inputs":{"event":{"codec":"json","max_bytes":4096}},
    \\  "canonicalization":{},
    \\  "shape":{},
    \\  "constraints":{"laws":[
;

const retained_test_suffix =
    \\  ]},
    \\  "identity":{},
    \\  "storage":{"kind":"pure"},
    \\  "operations":{},
    \\  "projections":{},
    \\  "bounds":{
    \\    "max_input_bytes":4096,
    \\    "max_store_bytes":8192,
    \\    "max_records":4,
    \\    "max_output_bytes":4096,
    \\    "max_diagnostics":8,
    \\    "max_reducer_states":4
    \\  }
    \\}
;

const retained_upsert_suffix =
    \\  ]},
    \\  "identity":{},
    \\  "storage":{"kind":"pure"},
    \\  "operations":{},
    \\  "projections":{},
    \\  "bounds":{
    \\    "max_input_bytes":4096,
    \\    "max_store_bytes":4096,
    \\    "max_records":3,
    \\    "max_output_bytes":4096,
    \\    "max_diagnostics":8,
    \\    "max_reducer_states":1
    \\  }
    \\}
;

const retained_state_definition =
    retained_test_prefix ++
    \\    ["reducer",{
    \\      "mode":"retained",
    \\      "event_kind":"/kind",
    \\      "registers":[
    \\        {"name":"current","max_bytes":4096},
    \\        {"name":"shadow","max_bytes":4096}
    \\      ],
    \\      "admissions":[
    \\        {
    \\          "on":"created",
    \\          "requires":[],
    \\          "forbids":["current"],
    \\          "rules":[],
    \\          "actions":[
    \\            {
    \\              "op":"set",
    \\              "register":"current",
    \\              "input":"event",
    \\              "path":"/body"
    \\            }
    \\          ]
    \\        },
    \\        {
    \\          "on":"updated",
    \\          "requires":["current"],
    \\          "forbids":[],
    \\          "rules":[],
    \\          "actions":[
    \\            {
    \\              "op":"set",
    \\              "register":"current",
    \\              "input":"event",
    \\              "path":"/body"
    \\            },
    \\            {
    \\              "op":"set",
    \\              "register":"shadow",
    \\              "input":"event",
    \\              "path":"/body/missing"
    \\            }
    \\          ]
    \\        }
    \\      ]
    \\    }]
    ++ retained_test_suffix;

const retained_sets_definition =
    retained_test_prefix ++
    \\    ["reducer",{
    \\      "mode":"retained",
    \\      "event_kind":"/kind",
    \\      "registers":[{"name":"current","max_bytes":4096}],
    \\      "sets":[
    \\        {
    \\          "name":"used_ids",
    \\          "max_entries":2,
    \\          "max_key_bytes":8,
    \\          "max_bytes":16
    \\        }
    \\      ],
    \\      "admissions":[
    \\        {
    \\          "on":"created",
    \\          "requires":[],
    \\          "forbids":["current"],
    \\          "set_guards":[
    \\            {
    \\              "set":"used_ids",
    \\              "input":"event",
    \\              "path":"/body/id",
    \\              "presence":"absent"
    \\            }
    \\          ],
    \\          "rules":[],
    \\          "actions":[
    \\            {
    \\              "op":"set",
    \\              "register":"current",
    \\              "input":"event",
    \\              "path":"/body"
    \\            },
    \\            {
    \\              "op":"insert",
    \\              "set":"used_ids",
    \\              "input":"event",
    \\              "path":"/body/id"
    \\            }
    \\          ]
    \\        },
    \\        {
    \\          "on":"updated",
    \\          "requires":["current"],
    \\          "forbids":[],
    \\          "set_guards":[
    \\            {
    \\              "set":"used_ids",
    \\              "input":"event",
    \\              "path":"/body/id",
    \\              "presence":"absent"
    \\            },
    \\            {
    \\              "set":"used_ids",
    \\              "input":"event",
    \\              "path":"/body/predecessors",
    \\              "presence":"present",
    \\              "mode":"each"
    \\            }
    \\          ],
    \\          "rules":[],
    \\          "actions":[
    \\            {
    \\              "op":"set",
    \\              "register":"current",
    \\              "input":"event",
    \\              "path":"/body"
    \\            },
    \\            {
    \\              "op":"insert",
    \\              "set":"used_ids",
    \\              "input":"event",
    \\              "path":"/body/id"
    \\            }
    \\          ]
    \\        }
    \\      ]
    \\    }]
    ++ retained_test_suffix;

const retained_upsert_definition =
    retained_test_prefix ++
    \\    ["reducer",{
    \\      "mode":"retained",
    \\      "event_kind":"/kind",
    \\      "registers":[{"name":"items","max_bytes":4096}],
    \\      "admissions":[
    \\        {
    \\          "on":"created",
    \\          "requires":[],
    \\          "forbids":["items"],
    \\          "rules":[],
    \\          "actions":[
    \\            {
    \\              "op":"set",
    \\              "register":"items",
    \\              "input":"event",
    \\              "path":"/body/items"
    \\            }
    \\          ]
    \\        },
    \\        {
    \\          "on":"upserted",
    \\          "requires":["items"],
    \\          "forbids":[],
    \\          "rules":[],
    \\          "actions":[
    \\            {
    \\              "op":"upsert",
    \\              "register":"items",
    \\              "input":"event",
    \\              "path":"/body/items",
    \\              "key":"/id",
    \\              "source_ref":"/body/set_id",
    \\              "predecessor_refs":"/body/predecessors",
    \\              "stable":["/owner"],
    \\              "max_entries":3,
    \\              "max_key_bytes":32
    \\            }
    \\          ]
    \\        }
    \\      ]
    \\    }]
    ++ retained_upsert_suffix;

const retained_evolution_first =
    retained_test_prefix ++
    \\    ["reducer",{
    \\      "mode":"retained",
    \\      "event_kind":"/kind",
    \\      "registers":[{"name":"current","max_bytes":4096}],
    \\      "admissions":[
    \\        {
    \\          "on":"created",
    \\          "requires":[],
    \\          "forbids":["current"],
    \\          "rules":[],
    \\          "actions":[
    \\            {
    \\              "op":"set",
    \\              "register":"current",
    \\              "input":"event",
    \\              "path":"/body"
    \\            }
    \\          ]
    \\        }
    \\      ]
    \\    }]
    ++ retained_test_suffix;

const retained_evolution_second =
    retained_test_prefix ++
    \\    ["reducer",{
    \\      "mode":"retained",
    \\      "event_kind":"/kind",
    \\      "registers":[{"name":"current","max_bytes":4096}],
    \\      "sets":[
    \\        {
    \\          "name":"used_ids",
    \\          "max_entries":4,
    \\          "max_key_bytes":16,
    \\          "max_bytes":64
    \\        }
    \\      ],
    \\      "admissions":[
    \\        {
    \\          "on":"updated",
    \\          "requires":["current"],
    \\          "forbids":[],
    \\          "set_guards":[
    \\            {
    \\              "set":"used_ids",
    \\              "input":"event",
    \\              "path":"/body/id",
    \\              "presence":"absent"
    \\            }
    \\          ],
    \\          "rules":[],
    \\          "actions":[
    \\            {
    \\              "op":"set",
    \\              "register":"current",
    \\              "input":"event",
    \\              "path":"/body"
    \\            },
    \\            {
    \\              "op":"insert",
    \\              "set":"used_ids",
    \\              "input":"event",
    \\              "path":"/body/id"
    \\            }
    \\          ]
    \\        }
    \\      ]
    \\    }]
    ++ retained_test_suffix;

const upsert_created_event =
    "{\"kind\":\"created\",\"body\":{\"items\":[]}}";

const upsert_first_event =
    "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-1\"," ++
    "\"predecessors\":[],\"items\":[{\"id\":\"alpha\"," ++
    "\"owner\":\"owner-a\",\"status\":\"open\"}]}}";

const upsert_second_event =
    "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-2\"," ++
    "\"predecessors\":[\"set-1\"],\"items\":[{\"id\":\"alpha\"," ++
    "\"owner\":\"owner-a\",\"status\":\"closed\"},{\"id\":\"beta\"," ++
    "\"owner\":\"owner-b\",\"status\":\"open\"}]}}";

const expected_upsert_state =
    "[{\"key\":\"alpha\",\"occurrences\":2,\"source\":\"set-2\"," ++
    "\"value\":{\"id\":\"alpha\",\"owner\":\"owner-a\"," ++
    "\"status\":\"closed\"}},{\"key\":\"beta\",\"occurrences\":1," ++
    "\"source\":\"set-2\",\"value\":{\"id\":\"beta\"," ++
    "\"owner\":\"owner-b\",\"status\":\"open\"}}]";

fn expectUpsertFailure(
    expected: anyerror,
    plan: *const Plan,
    state: *State,
    item_index: usize,
    prior: []const u8,
    source: []const u8,
) !void {
    try expectTestEventError(expected, plan, state, source);
    try std.testing.expectEqualStrings(
        prior,
        registerStateConst(state, item_index).value.?.bytes,
    );
}

fn expectInvalidUpserts(
    plan: *const Plan,
    state: *State,
    item_index: usize,
    prior: []const u8,
) !void {
    try expectUpsertFailure(
        error.RetainedUpsertStableValueChanged,
        plan,
        state,
        item_index,
        prior,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-3\"," ++
            "\"predecessors\":[\"set-2\"],\"items\":[{\"id\":\"alpha\"," ++
            "\"owner\":\"owner-c\",\"status\":\"wrong\"}]}}",
    );
    try expectUpsertFailure(
        error.RetainedUpsertPredecessorMissing,
        plan,
        state,
        item_index,
        prior,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-3\"," ++
            "\"predecessors\":[\"set-1\"],\"items\":[{\"id\":\"alpha\"," ++
            "\"owner\":\"owner-a\",\"status\":\"wrong\"}]}}",
    );
    try expectDuplicateUpsertFailures(plan, state, item_index, prior);
}

fn expectDuplicateUpsertFailures(
    plan: *const Plan,
    state: *State,
    item_index: usize,
    prior: []const u8,
) !void {
    try expectUpsertFailure(
        error.RetainedUpsertDuplicateKey,
        plan,
        state,
        item_index,
        prior,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-3\"," ++
            "\"predecessors\":[],\"items\":[{\"id\":\"gamma\"," ++
            "\"owner\":\"owner-c\",\"status\":\"open\"},{\"id\":\"gamma\"," ++
            "\"owner\":\"owner-c\",\"status\":\"closed\"}]}}",
    );
    try expectUpsertFailure(
        error.RetainedUpsertBoundsExceeded,
        plan,
        state,
        item_index,
        prior,
        "{\"kind\":\"upserted\",\"body\":{\"set_id\":\"set-3\"," ++
            "\"predecessors\":[],\"items\":[{\"id\":\"gamma\"," ++
            "\"owner\":\"owner-c\",\"status\":\"open\"},{\"id\":\"delta\"," ++
            "\"owner\":\"owner-d\",\"status\":\"open\"}]}}",
    );
}

test "retained reducer cache binds event bounds and actions commit atomically" {
    var test_plan = try TestPlan.init(retained_state_definition);
    defer test_plan.deinit();
    for (test_plan.reducer.admissions[0].validation_plan.inputs) |*input| {
        if (std.mem.eql(u8, input.name, "event")) {
            input.max_bytes = 2048;
            break;
        }
    }
    try std.testing.expectError(
        error.CacheRetainedAdmissionInputsMismatch,
        validatePlan(&test_plan.reducer, &test_plan.artifact, 4096),
    );
    for (test_plan.reducer.admissions[0].validation_plan.inputs) |*input| {
        if (std.mem.eql(u8, input.name, "event")) {
            input.max_bytes = 4096;
            break;
        }
    }

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try applyTestEvent(
        &test_plan.reducer,
        &state,
        "{\"kind\":\"created\",\"body\":{\"id\":\"item-1\",\"status\":\"open\"}}",
    );
    try expectTestEventError(
        error.RetainedActionValueMissing,
        &test_plan.reducer,
        &state,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"item-1\",\"status\":\"closed\"}}",
    );
    try expectRetainedStatus(&test_plan.reducer, &state, "open");
    try std.testing.expect(
        state.get(&test_plan.reducer, "shadow") == null,
    );
}

test "retained sets reject duplicate and over-bound keys atomically" {
    var test_plan = try TestPlan.init(retained_sets_definition);
    defer test_plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), test_plan.reducer.sets.len);
    try std.testing.expectEqual(
        @as(usize, 2),
        test_plan.reducer.admissions[1].set_guards.len,
    );

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try applyTestEvent(
        &test_plan.reducer,
        &state,
        "{\"kind\":\"created\",\"body\":{\"id\":\"first\",\"status\":\"open\"}}",
    );
    try applyTestEvent(
        &test_plan.reducer,
        &state,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"second\"," ++
            "\"predecessors\":[\"first\"],\"status\":\"closed\"}}",
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        state.sets.items[0].value.entries.count(),
    );
    try expectTestEventError(
        error.IllegalRetainedTransition,
        &test_plan.reducer,
        &state,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"third\"," ++
            "\"predecessors\":[\"unknown\"],\"status\":\"wrong\"}}",
    );
    try expectTestEventError(
        error.IllegalRetainedTransition,
        &test_plan.reducer,
        &state,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"first\"," ++
            "\"predecessors\":[\"first\"],\"status\":\"wrong\"}}",
    );
    try expectTestEventError(
        error.RetainedSetBoundsExceeded,
        &test_plan.reducer,
        &state,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"third\"," ++
            "\"predecessors\":[\"first\"],\"status\":\"wrong\"}}",
    );
    try expectTestEventError(
        error.RetainedSetKeyBoundsExceeded,
        &test_plan.reducer,
        &state,
        "{\"kind\":\"updated\",\"body\":{\"id\":\"too-large\"," ++
            "\"predecessors\":[\"first\"],\"status\":\"wrong\"}}",
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        state.sets.items[0].value.entries.count(),
    );
    try expectRetainedStatus(&test_plan.reducer, &state, "closed");
}

test "retained keyed upserts preserve lineage and stable fields atomically" {
    var test_plan = try TestPlan.init(retained_upsert_definition);
    defer test_plan.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        test_plan.reducer.admissions[1].actions.len,
    );
    try std.testing.expect(
        test_plan.reducer.admissions[1].actions[0] == .upsert,
    );

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var created = try parseTestEvent(upsert_created_event);
    defer created.deinit();
    try apply(
        std.testing.allocator,
        &test_plan.reducer,
        &state,
        created.value,
    );
    var first = try parseTestEvent(upsert_first_event);
    defer first.deinit();
    try apply(std.testing.allocator, &test_plan.reducer, &state, first.value);
    var second = try parseTestEvent(upsert_second_event);
    defer second.deinit();
    try apply(std.testing.allocator, &test_plan.reducer, &state, second.value);
    const item_index = findRegister(test_plan.reducer.registers, "items").?;
    const items_state = registerStateConst(&state, item_index).value.?;
    try std.testing.expectEqualStrings(expected_upsert_state, items_state.bytes);
    const before_invalid = try std.testing.allocator.dupe(
        u8,
        items_state.bytes,
    );
    defer std.testing.allocator.free(before_invalid);
    try expectInvalidUpserts(
        &test_plan.reducer,
        &state,
        item_index,
        before_invalid,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        applyUpsertForAllocationFailure,
        .{
            &test_plan.reducer,
            created.value,
            first.value,
            second.value,
        },
    );
}

test "retained state follows carrier names across definition plans" {
    var first = try TestPlan.init(retained_evolution_first);
    defer first.deinit();
    var second = try TestPlan.init(retained_evolution_second);
    defer second.deinit();

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var created = try parseTestEvent(
        "{\"kind\":\"created\",\"body\":{\"id\":\"item-1\",\"status\":\"open\"}}",
    );
    defer created.deinit();
    try apply(std.testing.allocator, &first.reducer, &state, created.value);
    var updated = try parseTestEvent(
        "{\"kind\":\"updated\",\"body\":{\"id\":\"item-2\",\"status\":\"closed\"}}",
    );
    defer updated.deinit();
    try apply(std.testing.allocator, &second.reducer, &state, updated.value);
    try std.testing.expectEqual(@as(usize, 1), state.registers.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.sets.items.len);
    try std.testing.expectError(
        error.IllegalRetainedTransition,
        apply(std.testing.allocator, &second.reducer, &state, updated.value),
    );
    try expectRetainedStatus(&second.reducer, &state, "closed");
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{ &second.artifact, second.rule(), @as(usize, 4096) },
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{second.cache_payload},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        applyEvolutionForAllocationFailure,
        .{
            &first.reducer,
            &second.reducer,
            created.value,
            updated.value,
        },
    );
}
