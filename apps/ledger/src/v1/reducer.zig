const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");

const max_text_bytes = 256;
const max_states = 65_536;
const max_transitions = 65_536;

const AssertionPresence = enum {
    required,
    when_present,
};

const Transition = struct {
    from: ?[]u8,
    on: []u8,
    to: []u8,

    fn deinit(self: *Transition, allocator: std.mem.Allocator) void {
        if (self.from) |value| allocator.free(value);
        allocator.free(self.on);
        allocator.free(self.to);
        self.* = undefined;
    }
};

pub const Plan = struct {
    states: [][]u8,
    transitions: []Transition,
    key: definition_core.json_pointer.Pointer,
    on: definition_core.json_pointer.Pointer,
    event_kind: ?definition_core.json_pointer.Pointer,
    retain_once: ?definition_core.json_pointer.Pointer,
    assert_from: ?definition_core.json_pointer.Pointer,
    assert_to: ?definition_core.json_pointer.Pointer,
    assertion_presence: AssertionPresence,
    max_entries: usize,
    max_retained_value_bytes: usize,
    max_retained_total_bytes: usize,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        deinitStringSet(allocator, self.states);
        for (self.transitions) |*transition| transition.deinit(allocator);
        allocator.free(self.transitions);
        self.key.deinit(allocator);
        self.on.deinit(allocator);
        if (self.event_kind) |*pointer| pointer.deinit(allocator);
        if (self.retain_once) |*pointer| pointer.deinit(allocator);
        if (self.assert_from) |*pointer| pointer.deinit(allocator);
        if (self.assert_to) |*pointer| pointer.deinit(allocator);
        self.* = undefined;
    }
};

const Entry = struct {
    key_bytes: [max_text_bytes]u8 = undefined,
    key_len: u16,
    state_bytes: [max_text_bytes]u8 = undefined,
    state_len: u16,
    retained: ?[]u8,
    event_count: usize,

    fn init(
        raw_key: []const u8,
        state_text: []const u8,
        retained: ?[]u8,
    ) Entry {
        var result: Entry = .{
            .key_len = @intCast(raw_key.len),
            .state_len = @intCast(state_text.len),
            .retained = retained,
            .event_count = 1,
        };
        @memcpy(result.key_bytes[0..raw_key.len], raw_key);
        @memcpy(result.state_bytes[0..state_text.len], state_text);
        return result;
    }

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.retained) |value| allocator.free(value);
        self.* = undefined;
    }

    fn key(self: *const Entry) []const u8 {
        return self.key_bytes[0..self.key_len];
    }

    pub fn state(self: *const Entry) []const u8 {
        return self.state_bytes[0..self.state_len];
    }

    fn setState(self: *Entry, value: []const u8) void {
        self.state_len = @intCast(value.len);
        @memcpy(self.state_bytes[0..value.len], value);
    }
};

const ProjectionFieldKind = enum {
    key,
    state,
    retained,
    event_count,
};

const ProjectionField = struct {
    name: []const u8,
    kind: ProjectionFieldKind,
};

pub const State = struct {
    entries: std.AutoHashMapUnmanaged([32]u8, Entry) = .empty,
    retained_bytes: usize = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    pub fn count(self: *const State) usize {
        return self.entries.count();
    }

    pub fn writeCanonicalRows(
        self: *State,
        allocator: std.mem.Allocator,
        output: *std.Io.Writer.Allocating,
        key_field: []const u8,
        state_field: []const u8,
        retained_field: ?[]const u8,
        event_count_field: ?[]const u8,
        limit: usize,
        max_output_bytes: usize,
    ) !usize {
        var field_storage: [4]ProjectionField = undefined;
        var field_count: usize = 0;
        field_storage[field_count] = .{ .name = key_field, .kind = .key };
        field_count += 1;
        field_storage[field_count] = .{
            .name = state_field,
            .kind = .state,
        };
        field_count += 1;
        if (retained_field) |name| {
            field_storage[field_count] = .{
                .name = name,
                .kind = .retained,
            };
            field_count += 1;
        }
        if (event_count_field) |name| {
            field_storage[field_count] = .{
                .name = name,
                .kind = .event_count,
            };
            field_count += 1;
        }
        const fields = field_storage[0..field_count];
        std.mem.sort(ProjectionField, fields, {}, projectionFieldLessThan);
        for (fields, 0..) |field, field_index| {
            try definition_core.json.safeIdentifier(field.name, 128);
            if (field_index != 0 and std.mem.eql(
                u8,
                fields[field_index - 1].name,
                field.name,
            )) {
                return error.ReducerProjectionFieldsConflict;
            }
        }
        const values = try allocator.alloc(*const Entry, self.entries.count());
        defer allocator.free(values);
        var iterator = self.entries.valueIterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) {
            values[index] = entry;
        }
        std.mem.sort(*const Entry, values, {}, entryLessThan);
        const emitted = @min(limit, values.len);
        try output.writer.writeByte('[');
        for (values[0..emitted], 0..) |entry, row_index| {
            if (row_index != 0) try output.writer.writeByte(',');
            try output.writer.writeByte('{');
            for (fields, 0..) |field, field_index| {
                if (field_index != 0) try output.writer.writeByte(',');
                try writeFieldName(&output.writer, field.name);
                switch (field.kind) {
                    .key => try definition_core.canonical_json
                        .writeCanonicalString(
                        &output.writer,
                        entry.key(),
                    ),
                    .state => try definition_core.canonical_json
                        .writeCanonicalString(
                        &output.writer,
                        entry.state(),
                    ),
                    .retained => try output.writer.writeAll(
                        entry.retained orelse
                            return error.ReducerRetainedValueMissing,
                    ),
                    .event_count => try output.writer.print(
                        "{d}",
                        .{entry.event_count},
                    ),
                }
            }
            try output.writer.writeByte('}');
            if (output.written().len > max_output_bytes) {
                return error.ReducerProjectionOutputBoundsExceeded;
            }
        }
        try output.writer.writeByte(']');
        if (output.written().len > max_output_bytes) {
            return error.ReducerProjectionOutputBoundsExceeded;
        }
        return emitted;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    table_rule: definition.Rule,
    reducer_rule: definition.Rule,
    bounds: definition.Bounds,
) !Plan {
    const max_entries = bounds.max_reducer_states;
    if (max_entries == 0 or max_entries > max_states) {
        return error.InvalidReducerStateBound;
    }
    var table_parsed = try parseRule(allocator, table_rule);
    defer table_parsed.deinit();
    const table = table_parsed.value.object;
    try definition_core.json.requireExactKeys(
        table,
        &.{ "op", "states", "transitions" },
    );
    try definition_core.json.requireFields(
        table,
        &.{ "op", "states", "transitions" },
    );
    try requireOperator(table, .transition_table);
    const states = try parseStringSet(
        allocator,
        try definition_core.json.field(table, "states"),
        max_states,
    );
    errdefer deinitStringSet(allocator, states);
    const transitions = try compileTransitions(
        allocator,
        try definition_core.json.field(table, "transitions"),
        states,
    );
    errdefer {
        for (transitions) |*transition| transition.deinit(allocator);
        allocator.free(transitions);
    }

    var reducer_parsed = try parseRule(allocator, reducer_rule);
    defer reducer_parsed.deinit();
    const reducer = reducer_parsed.value.object;
    try definition_core.json.requireExactKeys(
        reducer,
        &.{
            "op",
            "key",
            "on",
            "event_kind",
            "retain_once",
            "from",
            "to",
            "assertion_presence",
        },
    );
    try definition_core.json.requireFields(reducer, &.{ "op", "key", "on" });
    try requireOperator(reducer, .reducer);
    var key = try compilePointer(
        allocator,
        try definition_core.json.requiredString(reducer, "key"),
    );
    errdefer key.deinit(allocator);
    var on = try compilePointer(
        allocator,
        try definition_core.json.requiredString(reducer, "on"),
    );
    errdefer on.deinit(allocator);
    var event_kind = try compileOptionalPointer(
        allocator,
        reducer,
        "event_kind",
    );
    errdefer if (event_kind) |*pointer| pointer.deinit(allocator);
    var retain_once = try compileOptionalPointer(
        allocator,
        reducer,
        "retain_once",
    );
    errdefer if (retain_once) |*pointer| pointer.deinit(allocator);
    var assert_from = try compileOptionalPointer(allocator, reducer, "from");
    errdefer if (assert_from) |*pointer| pointer.deinit(allocator);
    var assert_to = try compileOptionalPointer(allocator, reducer, "to");
    errdefer if (assert_to) |*pointer| pointer.deinit(allocator);
    const assertion_presence = try compileAssertionPresence(reducer);
    const result: Plan = .{
        .states = states,
        .transitions = transitions,
        .key = key,
        .on = on,
        .event_kind = event_kind,
        .retain_once = retain_once,
        .assert_from = assert_from,
        .assert_to = assert_to,
        .assertion_presence = assertion_presence,
        .max_entries = max_entries,
        .max_retained_value_bytes = bounds.max_input_bytes,
        .max_retained_total_bytes = bounds.max_store_bytes,
    };
    try validatePlan(&result);
    return result;
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(3);
    try encodeStringSet(plan.states, encoder);
    try encoder.writeCount(plan.transitions.len);
    for (plan.transitions) |transition| {
        try encoder.writeOptionalBytes(transition.from);
        try encoder.writeBytes(transition.on);
        try encoder.writeBytes(transition.to);
    }
    try encoder.writeBytes(plan.key.raw);
    try encoder.writeBytes(plan.on.raw);
    try encoder.writeOptionalBytes(if (plan.event_kind) |pointer|
        pointer.raw
    else
        null);
    try encoder.writeOptionalBytes(if (plan.retain_once) |pointer|
        pointer.raw
    else
        null);
    try encoder.writeOptionalBytes(if (plan.assert_from) |pointer|
        pointer.raw
    else
        null);
    try encoder.writeOptionalBytes(if (plan.assert_to) |pointer|
        pointer.raw
    else
        null);
    try encoder.writeEnum(plan.assertion_presence);
    try encoder.writeUsize(plan.max_entries);
    try encoder.writeUsize(plan.max_retained_value_bytes);
    try encoder.writeUsize(plan.max_retained_total_bytes);
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 3) {
        return error.LedgerReducerCacheVersionMismatch;
    }
    const states = try decodeStringSet(allocator, decoder, max_states);
    errdefer deinitStringSet(allocator, states);
    const transition_count = try decoder.readCount(max_transitions);
    if (transition_count == 0) return error.InvalidTransitionTable;
    const transitions = try allocator.alloc(Transition, transition_count);
    var transition_initialized: usize = 0;
    errdefer {
        for (transitions[0..transition_initialized]) |*transition| {
            transition.deinit(allocator);
        }
        allocator.free(transitions);
    }
    for (transitions) |*transition| {
        transition.* = .{
            .from = try decoder.readOptionalBytesAlloc(
                allocator,
                max_text_bytes,
            ),
            .on = undefined,
            .to = undefined,
        };
        errdefer if (transition.from) |value| allocator.free(value);
        transition.on = try decoder.readBytesAlloc(allocator, max_text_bytes);
        errdefer allocator.free(transition.on);
        transition.to = try decoder.readBytesAlloc(allocator, max_text_bytes);
        transition_initialized += 1;
    }
    var key = try decodePointer(allocator, decoder);
    errdefer key.deinit(allocator);
    var on = try decodePointer(allocator, decoder);
    errdefer on.deinit(allocator);
    var event_kind = try decodeOptionalPointer(allocator, decoder);
    errdefer if (event_kind) |*pointer| pointer.deinit(allocator);
    var retain_once = try decodeOptionalPointer(allocator, decoder);
    errdefer if (retain_once) |*pointer| pointer.deinit(allocator);
    var assert_from = try decodeOptionalPointer(allocator, decoder);
    errdefer if (assert_from) |*pointer| pointer.deinit(allocator);
    var assert_to = try decodeOptionalPointer(allocator, decoder);
    errdefer if (assert_to) |*pointer| pointer.deinit(allocator);
    const result: Plan = .{
        .states = states,
        .transitions = transitions,
        .key = key,
        .on = on,
        .event_kind = event_kind,
        .retain_once = retain_once,
        .assert_from = assert_from,
        .assert_to = assert_to,
        .assertion_presence = try decoder.readEnum(AssertionPresence),
        .max_entries = try decoder.readUsize(),
        .max_retained_value_bytes = try decoder.readUsize(),
        .max_retained_total_bytes = try decoder.readUsize(),
    };
    try validatePlan(&result);
    return result;
}

pub fn apply(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *State,
    event: std.json.Value,
) !void {
    const key_value = definition_core.json_pointer.lookup(
        event,
        plan.key,
    ) orelse return error.ReducerKeyMissing;
    const key = try boundedText(key_value, error.InvalidReducerKey);
    var key_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &key_digest, .{});
    const prior = state.entries.get(key_digest);
    if (prior) |entry| {
        if (!std.mem.eql(u8, entry.key(), key)) {
            return error.ReducerKeyDigestCollision;
        }
    }
    const prior_state = if (prior) |entry| entry.state() else null;
    const on_value = definition_core.json_pointer.lookup(
        event,
        plan.on,
    ) orelse return error.ReducerTransitionMissing;
    const on = try boundedIdentifier(
        on_value,
        error.InvalidReducerTransition,
    );
    const transition = findTransition(plan.transitions, prior_state, on) orelse
        return error.IllegalReducerTransition;
    if (plan.assert_from) |pointer| {
        try validateStateAssertion(
            event,
            pointer,
            plan.assertion_presence,
            prior_state,
            error.ReducerFromAssertionMissing,
            error.ReducerFromAssertionMismatch,
        );
    }
    if (plan.assert_to) |pointer| {
        try validateStateAssertion(
            event,
            pointer,
            plan.assertion_presence,
            transition.to,
            error.ReducerToAssertionMissing,
            error.ReducerToAssertionMismatch,
        );
    }
    var retained_value: ?[]u8 = null;
    defer if (retained_value) |value| allocator.free(value);
    if (plan.retain_once) |pointer| {
        if (definition_core.json_pointer.lookup(event, pointer)) |value| {
            const canonical =
                try definition_core.canonical_json.canonicalJsonAlloc(
                    allocator,
                    value,
                );
            var canonical_owned: ?[]u8 = canonical;
            defer if (canonical_owned) |owned| allocator.free(owned);
            if (canonical.len > plan.max_retained_value_bytes) {
                return error.ReducerRetainedValueBoundsExceeded;
            }
            if (prior) |entry| {
                const retained = entry.retained orelse
                    return error.ReducerRetainedValueMissing;
                if (!std.mem.eql(u8, retained, canonical)) {
                    return error.ReducerRetainedValueChanged;
                }
            } else {
                retained_value = canonical;
                canonical_owned = null;
            }
        } else if (prior == null) {
            return error.ReducerRetainedValueMissing;
        }
    }
    if (prior == null and state.entries.count() >= plan.max_entries) {
        return error.ReducerStateBoundsExceeded;
    }
    if (prior == null and retained_value != null and
        state.retained_bytes >
            plan.max_retained_total_bytes -| retained_value.?.len)
    {
        return error.ReducerRetainedTotalBoundsExceeded;
    }
    if (prior) |entry| {
        if (entry.event_count == std.math.maxInt(usize)) {
            return error.ReducerEventCountOverflow;
        }
    }
    const result = try state.entries.getOrPut(allocator, key_digest);
    if (result.found_existing) {
        if (!std.mem.eql(u8, result.value_ptr.key(), key)) {
            return error.ReducerKeyDigestCollision;
        }
        result.value_ptr.setState(transition.to);
        result.value_ptr.event_count += 1;
    } else {
        result.value_ptr.* = Entry.init(
            key,
            transition.to,
            retained_value,
        );
        if (retained_value) |value| state.retained_bytes += value.len;
        retained_value = null;
    }
}

fn compileTransitions(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    states: []const []u8,
) ![]Transition {
    const items = try definition_core.json.array(value);
    if (items.items.len == 0 or items.items.len > max_transitions) {
        return error.InvalidTransitionTable;
    }
    const transitions = try allocator.alloc(Transition, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (transitions[0..initialized]) |*transition| {
            transition.deinit(allocator);
        }
        allocator.free(transitions);
    }
    for (items.items) |item| {
        const object = try definition_core.json.object(item);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "from", "on", "to" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "from", "on", "to" },
        );
        const raw_from = try definition_core.json.field(object, "from");
        const from: ?[]u8 = switch (raw_from) {
            .null => null,
            .string => |text| blk: {
                try validateIdentifier(text);
                if (!containsSorted(states, text)) {
                    return error.UnknownReducerState;
                }
                break :blk try allocator.dupe(u8, text);
            },
            else => return error.InvalidTransitionState,
        };
        errdefer if (from) |text| allocator.free(text);
        const on_text = try definition_core.json.requiredString(object, "on");
        try validateIdentifier(on_text);
        const on = try allocator.dupe(u8, on_text);
        errdefer allocator.free(on);
        const to_text = try definition_core.json.requiredString(object, "to");
        try validateIdentifier(to_text);
        if (!containsSorted(states, to_text)) {
            return error.UnknownReducerState;
        }
        const to = try allocator.dupe(u8, to_text);
        transitions[initialized] = .{ .from = from, .on = on, .to = to };
        initialized += 1;
    }
    std.mem.sort(Transition, transitions, {}, transitionLessThan);
    for (transitions[1..], 1..) |transition, index| {
        const prior = transitions[index - 1];
        if (optionalTextOrder(prior.from, transition.from) == .eq and
            std.mem.eql(u8, prior.on, transition.on))
        {
            return error.DuplicateReducerTransition;
        }
    }
    return transitions;
}

pub fn validatePlan(plan: *const Plan) !void {
    if (plan.states.len == 0 or plan.states.len > max_states or
        plan.transitions.len == 0 or
        plan.transitions.len > max_transitions or
        plan.max_entries == 0 or plan.max_entries > max_states or
        plan.max_retained_value_bytes == 0 or
        plan.max_retained_total_bytes == 0 or
        plan.max_retained_value_bytes > plan.max_retained_total_bytes)
    {
        return error.InvalidReducerPlan;
    }
    try validateSortedStringSet(plan.states);
    for (plan.transitions, 0..) |transition, index| {
        if (transition.from) |from| {
            try validateIdentifier(from);
            if (!containsSorted(plan.states, from)) {
                return error.UnknownReducerState;
            }
        }
        try validateIdentifier(transition.on);
        try validateIdentifier(transition.to);
        if (!containsSorted(plan.states, transition.to)) {
            return error.UnknownReducerState;
        }
        if (index != 0 and
            !transitionLessThan({}, plan.transitions[index - 1], transition))
        {
            return error.CacheReducerTransitionsNotSorted;
        }
    }
    try validatePointer(plan.key);
    try validatePointer(plan.on);
    if (plan.event_kind) |pointer| try validatePointer(pointer);
    if (plan.retain_once) |pointer| try validatePointer(pointer);
    if (plan.assert_from) |pointer| try validatePointer(pointer);
    if (plan.assert_to) |pointer| try validatePointer(pointer);
    if (plan.assertion_presence == .when_present and
        plan.assert_from == null and plan.assert_to == null)
    {
        return error.RedundantReducerAssertionPresence;
    }
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
    if (actual != expected) return error.ReducerOperatorMismatch;
}

fn compilePointer(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !definition_core.json_pointer.Pointer {
    if (raw.len > 1024) return error.ReducerPointerTooLong;
    return definition_core.json_pointer.compile(allocator, raw);
}

fn compileOptionalPointer(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) !?definition_core.json_pointer.Pointer {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    const pointer = try compilePointer(
        allocator,
        try definition_core.json.string(value),
    );
    return pointer;
}

fn compileAssertionPresence(
    object: std.json.ObjectMap,
) !AssertionPresence {
    const raw = object.get("assertion_presence") orelse return .required;
    const value = try definition_core.json.string(raw);
    if (std.mem.eql(u8, value, "required")) return .required;
    if (std.mem.eql(u8, value, "when-present")) return .when_present;
    return error.InvalidReducerAssertionPresence;
}

fn decodePointer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !definition_core.json_pointer.Pointer {
    const raw = try decoder.readBytesAlloc(allocator, 1024);
    defer allocator.free(raw);
    return try definition_core.json_pointer.compile(allocator, raw);
}

fn decodeOptionalPointer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?definition_core.json_pointer.Pointer {
    const raw = try decoder.readOptionalBytesAlloc(allocator, 1024) orelse
        return null;
    defer allocator.free(raw);
    const pointer = try definition_core.json_pointer.compile(allocator, raw);
    return pointer;
}

fn validatePointer(pointer: definition_core.json_pointer.Pointer) !void {
    if (pointer.raw.len > 1024) return error.ReducerPointerTooLong;
}

fn parseStringSet(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    max_count: usize,
) ![][]u8 {
    const items = try definition_core.json.array(value);
    if (items.items.len == 0 or items.items.len > max_count) {
        return error.InvalidReducerStringSet;
    }
    const out = try allocator.alloc([]u8, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items.items) |item| {
        const text = try definition_core.json.string(item);
        try validateIdentifier(text);
        out[initialized] = try allocator.dupe(u8, text);
        initialized += 1;
    }
    std.mem.sort([]u8, out, {}, stringLessThan);
    for (out[1..], 1..) |item, index| {
        if (std.mem.eql(u8, out[index - 1], item)) {
            return error.DuplicateReducerString;
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
    if (count == 0) return error.InvalidReducerStringSet;
    const out = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (out, 0..) |*item, index| {
        item.* = try decoder.readBytesAlloc(allocator, max_text_bytes);
        initialized += 1;
        try validateIdentifier(item.*);
        if (index != 0 and
            std.mem.order(u8, out[index - 1], item.*) != .lt)
        {
            return error.CacheReducerStringsNotSorted;
        }
    }
    return out;
}

fn deinitStringSet(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn validateSortedStringSet(items: []const []u8) !void {
    for (items, 0..) |item, index| {
        try validateIdentifier(item);
        if (index != 0 and
            std.mem.order(u8, items[index - 1], item) != .lt)
        {
            return error.CacheReducerStringsNotSorted;
        }
    }
}

fn validateIdentifier(value: []const u8) !void {
    try definition_core.json.safeIdentifier(value, max_text_bytes);
}

fn boundedText(value: std.json.Value, comptime failure: anyerror) ![]const u8 {
    const text = definition_core.json.string(value) catch return failure;
    if (text.len == 0 or text.len > max_text_bytes or
        !std.unicode.utf8ValidateSlice(text))
    {
        return failure;
    }
    return text;
}

fn boundedIdentifier(
    value: std.json.Value,
    comptime failure: anyerror,
) ![]const u8 {
    const text = try boundedText(value, failure);
    definition_core.json.safeIdentifier(text, max_text_bytes) catch
        return failure;
    return text;
}

fn stateAssertionMatches(
    expected: ?[]const u8,
    actual: std.json.Value,
) bool {
    const text = expected orelse return actual == .null;
    return actual == .string and std.mem.eql(u8, text, actual.string);
}

fn validateStateAssertion(
    event: std.json.Value,
    pointer: definition_core.json_pointer.Pointer,
    presence: AssertionPresence,
    expected: ?[]const u8,
    comptime missing: anyerror,
    comptime mismatch: anyerror,
) !void {
    const asserted = definition_core.json_pointer.lookup(event, pointer) orelse {
        if (presence == .when_present) return;
        return missing;
    };
    if (!stateAssertionMatches(expected, asserted)) return mismatch;
}

fn findTransition(
    transitions: []const Transition,
    from: ?[]const u8,
    on: []const u8,
) ?*const Transition {
    var low: usize = 0;
    var high = transitions.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const candidate = &transitions[mid];
        const order = transitionKeyOrder(
            candidate.from,
            candidate.on,
            from,
            on,
        );
        switch (order) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return candidate,
        }
    }
    return null;
}

fn transitionLessThan(_: void, left: Transition, right: Transition) bool {
    return transitionKeyOrder(left.from, left.on, right.from, right.on) == .lt;
}

fn transitionKeyOrder(
    left_from: ?[]const u8,
    left_on: []const u8,
    right_from: ?[]const u8,
    right_on: []const u8,
) std.math.Order {
    const from_order = optionalTextOrder(left_from, right_from);
    if (from_order != .eq) return from_order;
    return std.mem.order(u8, left_on, right_on);
}

fn optionalTextOrder(
    left: ?[]const u8,
    right: ?[]const u8,
) std.math.Order {
    if (left) |left_text| {
        const right_text = right orelse return .gt;
        return std.mem.order(u8, left_text, right_text);
    }
    return if (right == null) .eq else .lt;
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

fn stringLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn entryLessThan(_: void, left: *const Entry, right: *const Entry) bool {
    return std.mem.lessThan(u8, left.key(), right.key());
}

fn projectionFieldLessThan(
    _: void,
    left: ProjectionField,
    right: ProjectionField,
) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn writeFieldName(
    writer: *std.Io.Writer,
    name: []const u8,
) !void {
    try definition_core.canonical_json.writeCanonicalString(writer, name);
    try writer.writeByte(':');
}

fn testBounds(max_reducer_states: usize) definition.Bounds {
    return .{
        .max_input_bytes = 4096,
        .max_store_bytes = 8192,
        .max_records = 16,
        .max_output_bytes = 4096,
        .max_diagnostics = 8,
        .max_reducer_states = max_reducer_states,
    };
}

test "compiled reducer admits deterministic keyed transitions" {
    const table_rule: definition.Rule = .{
        .operator = .transition_table,
        .pointer_id = null,
        .canonical_config = @constCast(
            "{\"op\":\"transition-table\",\"states\":[\"closed\",\"open\"],\"transitions\":[{\"from\":null,\"on\":\"create\",\"to\":\"open\"},{\"from\":\"open\",\"on\":\"close\",\"to\":\"closed\"},{\"from\":\"closed\",\"on\":\"reopen\",\"to\":\"open\"}]}",
        ),
    };
    const reducer_rule: definition.Rule = .{
        .operator = .reducer,
        .pointer_id = null,
        .canonical_config = @constCast(
            "{\"op\":\"reducer\",\"key\":\"/id\",\"on\":\"/event\",\"from\":\"/from\",\"to\":\"/to\"}",
        ),
    };
    var plan = try compile(
        std.testing.allocator,
        table_rule,
        reducer_rule,
        testBounds(2),
    );
    defer plan.deinit(std.testing.allocator);
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var created = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"create\",\"from\":null,\"id\":\"item-1\",\"to\":\"open\"}",
        .{},
    );
    defer created.deinit();
    try apply(std.testing.allocator, &plan, &state, created.value);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    var wrong_to = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"close\",\"from\":\"open\",\"id\":\"item-1\",\"to\":\"open\"}",
        .{},
    );
    defer wrong_to.deinit();
    try std.testing.expectError(
        error.ReducerToAssertionMismatch,
        apply(std.testing.allocator, &plan, &state, wrong_to.value),
    );
    var closed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"close\",\"from\":\"open\",\"id\":\"item-1\",\"to\":\"closed\"}",
        .{},
    );
    defer closed.deinit();
    try apply(std.testing.allocator, &plan, &state, closed.value);
    var illegal = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"close\",\"from\":\"closed\",\"id\":\"item-1\",\"to\":\"closed\"}",
        .{},
    );
    defer illegal.deinit();
    try std.testing.expectError(
        error.IllegalReducerTransition,
        apply(std.testing.allocator, &plan, &state, illegal.value),
    );
    var second_key = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"create\",\"from\":null,\"id\":\"item-2\",\"to\":\"open\"}",
        .{},
    );
    defer second_key.deinit();
    try apply(std.testing.allocator, &plan, &state, second_key.value);
    var projection: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer projection.deinit();
    try std.testing.expectEqual(
        @as(usize, 2),
        try state.writeCanonicalRows(
            std.testing.allocator,
            &projection,
            "id",
            "status",
            null,
            null,
            2,
            4096,
        ),
    );
    try std.testing.expectEqualStrings(
        "[{\"id\":\"item-1\",\"status\":\"closed\"},{\"id\":\"item-2\",\"status\":\"open\"}]",
        projection.written(),
    );
    var third_key = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"create\",\"from\":null,\"id\":\"item-3\",\"to\":\"open\"}",
        .{},
    );
    defer third_key.deinit();
    var constrained_plan = try compile(
        std.testing.allocator,
        table_rule,
        reducer_rule,
        testBounds(1),
    );
    defer constrained_plan.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ReducerStateBoundsExceeded,
        apply(
            std.testing.allocator,
            &constrained_plan,
            &state,
            third_key.value,
        ),
    );
    try std.testing.expectError(
        error.ReducerStateBoundsExceeded,
        apply(std.testing.allocator, &plan, &state, third_key.value),
    );
}

test "keyed reducer checks transition assertions when rows carry them" {
    const table_rule: definition.Rule = .{
        .operator = .transition_table,
        .pointer_id = null,
        .canonical_config = @constCast(
            "{\"op\":\"transition-table\",\"states\":[\"active\",\"closed\"],\"transitions\":[{\"from\":null,\"on\":\"active\",\"to\":\"active\"},{\"from\":\"active\",\"on\":\"closed\",\"to\":\"closed\"}]}",
        ),
    };
    const reducer_rule: definition.Rule = .{
        .operator = .reducer,
        .pointer_id = null,
        .canonical_config = @constCast(
            "{\"assertion_presence\":\"when-present\",\"event_kind\":\"/event\",\"from\":\"/from\",\"key\":\"/id\",\"on\":\"/status\",\"op\":\"reducer\",\"retain_once\":\"/record\",\"to\":\"/to\"}",
        ),
    };
    var compiled = try compile(
        std.testing.allocator,
        table_rule,
        reducer_rule,
        testBounds(2),
    );
    defer compiled.deinit(std.testing.allocator);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        4096,
    );
    defer encoder.deinit();
    try encodeCache(&compiled, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var plan = try decodeCache(std.testing.allocator, &decoder);
    defer plan.deinit(std.testing.allocator);
    try decoder.finish();
    try std.testing.expect(plan.event_kind != null);
    try std.testing.expect(plan.retain_once != null);
    try std.testing.expectEqual(
        AssertionPresence.when_present,
        plan.assertion_presence,
    );

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var captured = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"capture\",\"id\":\"item-1\",\"record\":{\"value\":1},\"status\":\"active\"}",
        .{},
    );
    defer captured.deinit();
    try apply(std.testing.allocator, &plan, &state, captured.value);

    var wrong_from = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"status\",\"from\":\"closed\",\"id\":\"item-1\",\"status\":\"closed\",\"to\":\"closed\"}",
        .{},
    );
    defer wrong_from.deinit();
    try std.testing.expectError(
        error.ReducerFromAssertionMismatch,
        apply(std.testing.allocator, &plan, &state, wrong_from.value),
    );

    var closed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"event\":\"status\",\"from\":\"active\",\"id\":\"item-1\",\"status\":\"closed\",\"to\":\"closed\"}",
        .{},
    );
    defer closed.deinit();
    try apply(std.testing.allocator, &plan, &state, closed.value);
    var projection: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer projection.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try state.writeCanonicalRows(
            std.testing.allocator,
            &projection,
            "id",
            "status",
            "record",
            "event_count",
            2,
            4096,
        ),
    );
    try std.testing.expectEqualStrings(
        "[{\"event_count\":2,\"id\":\"item-1\",\"record\":{\"value\":1},\"status\":\"closed\"}]",
        projection.written(),
    );
}
