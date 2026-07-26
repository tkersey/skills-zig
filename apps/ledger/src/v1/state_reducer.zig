const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const validation = @import("validation.zig");

const max_registers: usize = 1024;
const max_admissions: usize = 4096;
const max_actions: usize = 1024;

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

const SetAction = struct {
    target: u16,
    source: Source,
    pointer: definition_core.json_pointer.Pointer,

    fn deinit(self: *SetAction, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

const Action = union(enum) {
    set: SetAction,
    clear: u16,

    fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        if (self.* == .set) self.set.deinit(allocator);
        self.* = undefined;
    }
};

const Admission = struct {
    on: []u8,
    required: []u16,
    forbidden: []u16,
    validation_plan: validation.Plan,
    actions: []Action,

    fn deinit(self: *Admission, allocator: std.mem.Allocator) void {
        allocator.free(self.on);
        allocator.free(self.required);
        allocator.free(self.forbidden);
        self.validation_plan.deinit(allocator);
        for (self.actions) |*action| action.deinit(allocator);
        allocator.free(self.actions);
        self.* = undefined;
    }
};

pub const Plan = struct {
    event_kind: definition_core.json_pointer.Pointer,
    registers: []Register,
    admissions: []Admission,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.event_kind.deinit(allocator);
        for (self.registers) |*register| register.deinit(allocator);
        allocator.free(self.registers);
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

pub const State = struct {
    values: []?OwnedValue = &.{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.values) |*value| {
            if (value.*) |*owned| owned.deinit(allocator);
        }
        if (self.values.len != 0) allocator.free(self.values);
        self.* = undefined;
    }

    pub fn get(
        self: *const State,
        plan: *const Plan,
        name: []const u8,
    ) ?std.json.Value {
        const index = findRegister(plan.registers, name) orelse return null;
        return if (self.values.len == plan.registers.len and
            self.values[index] != null)
            self.values[index].?.parsed.value
        else
            null;
    }
};

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
        &.{ "op", "mode", "event_kind", "registers", "admissions" },
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
    const admissions = try compileAdmissions(
        allocator,
        definition_plan,
        registers,
        try definition_core.json.field(object, "admissions"),
        event_max_bytes,
    );
    errdefer deinitAdmissions(allocator, admissions);
    const result: Plan = .{
        .event_kind = event_kind,
        .registers = registers,
        .admissions = admissions,
    };
    try validatePlan(&result, definition_plan, event_max_bytes);
    return result;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(1);
    try encoder.writeBytes(plan.event_kind.raw);
    try encoder.writeCount(plan.registers.len);
    for (plan.registers) |register| {
        try encoder.writeBytes(register.name);
        try encoder.writeUsize(register.max_bytes);
    }
    try encoder.writeCount(plan.admissions.len);
    for (plan.admissions) |admission| {
        try encoder.writeBytes(admission.on);
        try encodeIndexes(admission.required, encoder);
        try encodeIndexes(admission.forbidden, encoder);
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
        };
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 1) {
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
                else => return error.CacheStateActionInvalid,
            };
            actions_initialized += 1;
        }
        admission.* = .{
            .on = on,
            .required = required,
            .forbidden = forbidden,
            .validation_plan = validation_plan,
            .actions = actions,
        };
        admissions_initialized += 1;
    }
    return .{
        .event_kind = event_kind,
        .registers = registers,
        .admissions = admissions,
    };
}

pub fn validatePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    event_max_bytes: usize,
) !void {
    if (!definition_plan.requires(.reducer) or
        plan.registers.len == 0 or
        plan.registers.len > definition_plan.bounds.max_reducer_states or
        plan.registers.len > max_registers or
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
    for (plan.admissions, 0..) |admission, index| {
        try definition_core.json.safeIdentifier(admission.on, 256);
        try validateIndexes(admission.required, plan.registers.len);
        try validateIndexes(admission.forbidden, plan.registers.len);
        if (setsIntersect(admission.required, admission.forbidden)) {
            return error.ConflictingRetainedAdmissionState;
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
            }
            const target = actionTarget(action);
            for (admission.actions[0..action_index]) |prior| {
                if (actionTarget(prior) == target) {
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
        if (!std.mem.eql(u8, admission.on, kind) or
            !preconditionsHold(state, admission))
        {
            continue;
        }
        if (selected != null) return error.AmbiguousRetainedAdmission;
        selected = admission;
    }
    const admission = selected orelse return error.IllegalRetainedTransition;
    const values = try allocator.alloc(
        validation.InputValue,
        1 + presentCount(state),
    );
    defer allocator.free(values);
    values[0] = .{ .name = "event", .value = event };
    var value_index: usize = 1;
    for (plan.registers, 0..) |register, register_index| {
        if (state.values[register_index]) |owned| {
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
    std.mem.sort(Register, registers, {}, struct {
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

fn compileAdmissions(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    registers: []const Register,
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
            &.{ "on", "requires", "forbids", "rules", "actions" },
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
            try definition_core.json.field(object, "actions"),
        );
        errdefer {
            for (actions) |*action| action.deinit(allocator);
            allocator.free(actions);
        }
        admissions[initialized] = .{
            .on = try allocator.dupe(u8, on),
            .required = required,
            .forbidden = forbidden,
            .validation_plan = validation_plan,
            .actions = actions,
        };
        initialized += 1;
    }
    return admissions;
}

fn compileActions(
    allocator: std.mem.Allocator,
    registers: []const Register,
    raw: std.json.Value,
) ![]Action {
    const values = try definition_core.json.array(raw);
    if (values.items.len > max_actions) return error.TooManyRetainedActions;
    const actions = try allocator.alloc(Action, values.items.len);
    const seen_targets = try allocator.alloc(bool, registers.len);
    defer allocator.free(seen_targets);
    @memset(seen_targets, false);
    var initialized: usize = 0;
    errdefer {
        for (actions[0..initialized]) |*action| action.deinit(allocator);
        allocator.free(actions);
    }
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
                    try definition_core.json.requiredString(object, "path"),
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
        } else return error.UnsupportedRetainedAction;
        initialized += 1;
    }
    return actions;
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
    std.mem.sort(definition.Input, inputs, {}, struct {
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
    std.mem.sort(u16, indexes, {}, std.sort.asc(u16));
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
    errdefer for (prepared) |*value| {
        if (value.*) |*owned| owned.deinit(allocator);
    };
    for (actions, 0..) |action, index| switch (action) {
        .clear => {},
        .set => |set| {
            const root = switch (set.source) {
                .event => event,
                .register => |source| if (state.values[source]) |owned|
                    owned.parsed.value
                else
                    return error.RetainedActionSourceMissing,
            };
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
    };
    for (actions, 0..) |action, index| {
        const target = switch (action) {
            .set => |set| set.target,
            .clear => |value| value,
        };
        if (state.values[target]) |*prior| prior.deinit(allocator);
        state.values[target] = prepared[index];
        prepared[index] = null;
    }
}

fn preconditionsHold(state: *const State, admission: *const Admission) bool {
    for (admission.required) |index| {
        if (state.values[index] == null) return false;
    }
    for (admission.forbidden) |index| {
        if (state.values[index] != null) return false;
    }
    return true;
}

fn ensureState(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *State,
) !void {
    if (state.values.len == plan.registers.len) return;
    if (state.values.len != 0) return error.RetainedStatePlanMismatch;
    state.values = try allocator.alloc(?OwnedValue, plan.registers.len);
    @memset(state.values, null);
}

fn presentCount(state: *const State) usize {
    var result: usize = 0;
    for (state.values) |value| result += @intFromBool(value != null);
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
    return !setsIntersect(left.required, right.forbidden) and
        !setsIntersect(right.required, left.forbidden);
}

fn actionTarget(action: Action) u16 {
    return switch (action) {
        .set => |set| set.target,
        .clear => |target| target,
    };
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
