const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const validation = @import("validation.zig");
const checkpoint = @import("checkpoint.zig");
const relation = @import("relation.zig");

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

const Guard = struct {
    event_kind: []u8,
    on: []u8,
    validation_plan: validation.Plan,

    fn deinit(self: *Guard, allocator: std.mem.Allocator) void {
        allocator.free(self.event_kind);
        allocator.free(self.on);
        self.validation_plan.deinit(allocator);
        self.* = undefined;
    }
};

pub const Plan = struct {
    states: [][]u8,
    transitions: []Transition,
    guards: []Guard,
    key: definition_core.json_pointer.Pointer,
    on: definition_core.json_pointer.Pointer,
    event_kind: ?definition_core.json_pointer.Pointer,
    retain_once: ?definition_core.json_pointer.Pointer,
    retain_latest: ?definition_core.json_pointer.Pointer,
    assert_from: ?definition_core.json_pointer.Pointer,
    assert_to: ?definition_core.json_pointer.Pointer,
    assertion_presence: AssertionPresence,
    max_entries: usize,
    max_retained_value_bytes: usize,
    max_retained_total_bytes: usize,
    relation_plan: ?relation.Plan = null,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        deinitStringSet(allocator, self.states);
        for (self.transitions) |*transition| transition.deinit(allocator);
        allocator.free(self.transitions);
        for (self.guards) |*guard| guard.deinit(allocator);
        allocator.free(self.guards);
        self.key.deinit(allocator);
        self.on.deinit(allocator);
        if (self.event_kind) |*pointer| pointer.deinit(allocator);
        if (self.retain_once) |*pointer| pointer.deinit(allocator);
        if (self.retain_latest) |*pointer| pointer.deinit(allocator);
        if (self.assert_from) |*pointer| pointer.deinit(allocator);
        if (self.assert_to) |*pointer| pointer.deinit(allocator);
        if (self.relation_plan) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub fn checkpointUpperBound(plan: *const Plan) !usize {
    const per_entry_bytes = 8 + max_text_bytes +
        8 + max_text_bytes + 1 + 8 + 8;
    const entry_bytes = std.math.mul(
        usize,
        plan.max_entries,
        per_entry_bytes,
    ) catch return error.CheckpointCapacityOverflow;
    const framed_bytes = std.math.add(
        usize,
        8,
        entry_bytes,
    ) catch return error.CheckpointCapacityOverflow;
    return std.math.add(
        usize,
        framed_bytes,
        plan.max_retained_total_bytes,
    ) catch error.CheckpointCapacityOverflow;
}

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

pub const EntryView = struct {
    key: []const u8,
    state: []const u8,
    retained: ?[]const u8,
    event_count: usize,
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

    pub fn validateCheckpoint(
        self: *const State,
        allocator: std.mem.Allocator,
        plan: *const Plan,
    ) !void {
        try validateRelationState(allocator, plan, self, null);
        if (self.entries.count() > plan.max_entries or
            self.retained_bytes > plan.max_retained_total_bytes)
        {
            return error.ReducerStateBoundsExceeded;
        }
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| {
            if (!containsSorted(plan.states, entry.state())) {
                return error.UnknownReducerState;
            }
            if (entry.retained) |value| {
                if (value.len > plan.max_retained_value_bytes) {
                    return error.ReducerRetainedValueBoundsExceeded;
                }
            }
        }
    }

    pub fn encodeCheckpoint(
        self: *State,
        allocator: std.mem.Allocator,
        encoder: *checkpoint.Encoder,
    ) !void {
        const views = try self.sortedViewsAlloc(allocator);
        defer allocator.free(views);
        try encoder.writeU64(@intCast(views.len));
        for (views) |entry| {
            try encoder.writeBytes(entry.key);
            try encoder.writeBytes(entry.state);
            try encoder.writeOptionalBytes(entry.retained);
            try encoder.writeU64(@intCast(entry.event_count));
        }
    }

    pub fn decodeCheckpoint(
        allocator: std.mem.Allocator,
        decoder: *checkpoint.Decoder,
        plan: ?*const Plan,
    ) !State {
        var result: State = .{};
        errdefer result.deinit(allocator);
        const maximum = if (plan) |value| value.max_entries else 0;
        const entry_count = try decoder.readCountBoundedByRemaining(
            maximum,
            8 + 1 + 8 + 1 + 8,
        );
        try result.entries.ensureTotalCapacity(
            allocator,
            @intCast(entry_count),
        );
        var previous_key: ?[]const u8 = null;
        for (0..entry_count) |_| {
            const key = try decoder.readBytes(max_text_bytes);
            if (key.len == 0 or
                (previous_key != null and
                    std.mem.order(u8, previous_key.?, key) != .lt))
            {
                return error.InvalidReducerCheckpoint;
            }
            const state_text = try decoder.readBytes(max_text_bytes);
            const retained_source = try decoder.readOptionalBytes(
                checkpoint.max_checkpoint_bytes,
            );
            const event_count = try decoder.readUsize();
            if (event_count == 0) return error.InvalidReducerCheckpoint;
            var retained: ?[]u8 = null;
            if (retained_source) |source| {
                const next = std.math.add(
                    usize,
                    result.retained_bytes,
                    source.len,
                ) catch return error.ReducerRetainedBytesBoundsExceeded;
                if (next > checkpoint.max_checkpoint_bytes) {
                    return error.ReducerRetainedBytesBoundsExceeded;
                }
                retained = try allocator.dupe(u8, source);
                result.retained_bytes = next;
            }
            errdefer if (retained) |value| allocator.free(value);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
            if (result.entries.contains(digest)) {
                return error.ReducerKeyDigestCollision;
            }
            result.entries.putAssumeCapacityNoClobber(
                digest,
                Entry.init(key, state_text, retained),
            );
            retained = null;
            result.entries.getPtr(digest).?.event_count = event_count;
            previous_key = key;
        }
        return result;
    }

    pub fn nextMonotonicSuffix(
        self: *const State,
        prefix: []const u8,
    ) !usize {
        var maximum: usize = 0;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| {
            const key = entry.key();
            if (!std.mem.startsWith(u8, key, prefix) or
                key.len == prefix.len)
            {
                continue;
            }
            const suffix = std.fmt.parseInt(
                usize,
                key[prefix.len..],
                10,
            ) catch continue;
            if (suffix > maximum) maximum = suffix;
        }
        return std.math.add(usize, maximum, 1) catch
            error.MonotonicIdentityOverflow;
    }

    pub fn get(self: *const State, key: []const u8) ?EntryView {
        var key_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &key_digest, .{});
        const entry = self.entries.getPtr(key_digest) orelse return null;
        if (!std.mem.eql(u8, entry.key(), key)) return null;
        return .{
            .key = entry.key(),
            .state = entry.state(),
            .retained = entry.retained,
            .event_count = entry.event_count,
        };
    }

    pub fn sortedViewsAlloc(
        self: *State,
        allocator: std.mem.Allocator,
    ) ![]EntryView {
        const views = try allocator.alloc(EntryView, self.entries.count());
        var iterator = self.entries.valueIterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) {
            views[index] = .{
                .key = entry.key(),
                .state = entry.state(),
                .retained = entry.retained,
                .event_count = entry.event_count,
            };
        }
        std.sort.heap(EntryView, views, {}, entryViewLessThan);
        return views;
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
        const fields = try projectionFields(
            &field_storage,
            key_field,
            state_field,
            retained_field,
            event_count_field,
        );
        const values = try self.sortedViewsAlloc(allocator);
        defer allocator.free(values);
        const emitted = @min(limit, values.len);
        try output.writer.writeByte('[');
        for (values[0..emitted], 0..) |entry, row_index| {
            if (row_index != 0) try output.writer.writeByte(',');
            try writeProjectionRow(&output.writer, fields, entry);
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

fn projectionFields(
    storage_fields: *[4]ProjectionField,
    key_field: []const u8,
    state_field: []const u8,
    retained_field: ?[]const u8,
    event_count_field: ?[]const u8,
) ![]ProjectionField {
    var count: usize = 0;
    storage_fields[count] = .{ .name = key_field, .kind = .key };
    count += 1;
    storage_fields[count] = .{ .name = state_field, .kind = .state };
    count += 1;
    if (retained_field) |name| {
        storage_fields[count] = .{ .name = name, .kind = .retained };
        count += 1;
    }
    if (event_count_field) |name| {
        storage_fields[count] = .{ .name = name, .kind = .event_count };
        count += 1;
    }
    const fields = storage_fields[0..count];
    std.sort.heap(ProjectionField, fields, {}, projectionFieldLessThan);
    for (fields, 0..) |field, index| {
        try definition_core.json.safeIdentifier(field.name, 128);
        if (index != 0 and
            std.mem.eql(u8, fields[index - 1].name, field.name))
        {
            return error.ReducerProjectionFieldsConflict;
        }
    }
    return fields;
}

fn writeProjectionRow(
    writer: *std.Io.Writer,
    fields: []const ProjectionField,
    entry: EntryView,
) !void {
    try writer.writeByte('{');
    for (fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try writeFieldName(writer, field.name);
        switch (field.kind) {
            .key => try definition_core.canonical_json.writeCanonicalString(
                writer,
                entry.key,
            ),
            .state => try definition_core.canonical_json.writeCanonicalString(
                writer,
                entry.state,
            ),
            .retained => try writer.writeAll(
                entry.retained orelse return error.ReducerRetainedValueMissing,
            ),
            .event_count => try writer.print("{d}", .{entry.event_count}),
        }
    }
    try writer.writeByte('}');
}

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: ?*const definition.Plan,
    table_rule: definition.Rule,
    reducer_rule: definition.Rule,
    bounds: definition.Bounds,
) !Plan {
    const max_entries = bounds.max_reducer_states;
    if (max_entries == 0 or max_entries > max_states) {
        return error.InvalidReducerStateBound;
    }
    var table = try compileTransitionConfig(allocator, table_rule);
    errdefer table.deinit(allocator);
    var reducer = try compileReducerConfig(
        allocator,
        definition_plan,
        reducer_rule,
    );
    errdefer reducer.deinit(allocator);
    const result: Plan = .{
        .states = table.states,
        .transitions = table.transitions,
        .guards = reducer.guards,
        .key = reducer.key,
        .on = reducer.on,
        .event_kind = reducer.event_kind,
        .retain_once = reducer.retain_once,
        .retain_latest = reducer.retain_latest,
        .assert_from = reducer.assert_from,
        .assert_to = reducer.assert_to,
        .assertion_presence = reducer.assertion_presence,
        .max_entries = max_entries,
        .max_retained_value_bytes = bounds.max_input_bytes,
        .max_retained_total_bytes = bounds.max_store_bytes,
        .relation_plan = reducer.relation_plan,
    };
    try validatePlan(&result);
    return result;
}

const TransitionConfig = struct {
    states: [][]u8,
    transitions: []Transition,

    fn deinit(self: *TransitionConfig, allocator: std.mem.Allocator) void {
        deinitStringSet(allocator, self.states);
        for (self.transitions) |*transition| transition.deinit(allocator);
        allocator.free(self.transitions);
        self.* = undefined;
    }
};

fn compileTransitionConfig(
    allocator: std.mem.Allocator,
    table_rule: definition.Rule,
) !TransitionConfig {
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
    return .{ .states = states, .transitions = transitions };
}

const ReducerConfig = struct {
    key: definition_core.json_pointer.Pointer,
    on: definition_core.json_pointer.Pointer,
    event_kind: ?definition_core.json_pointer.Pointer,
    retain_once: ?definition_core.json_pointer.Pointer,
    retain_latest: ?definition_core.json_pointer.Pointer,
    assert_from: ?definition_core.json_pointer.Pointer,
    assert_to: ?definition_core.json_pointer.Pointer,
    assertion_presence: AssertionPresence,
    guards: []Guard,
    relation_plan: ?relation.Plan,

    fn deinit(self: *ReducerConfig, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        self.on.deinit(allocator);
        if (self.event_kind) |*pointer| pointer.deinit(allocator);
        if (self.retain_once) |*pointer| pointer.deinit(allocator);
        if (self.retain_latest) |*pointer| pointer.deinit(allocator);
        if (self.assert_from) |*pointer| pointer.deinit(allocator);
        if (self.assert_to) |*pointer| pointer.deinit(allocator);
        for (self.guards) |*guard| guard.deinit(allocator);
        allocator.free(self.guards);
        if (self.relation_plan) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

fn compileReducerConfig(
    allocator: std.mem.Allocator,
    definition_plan: ?*const definition.Plan,
    reducer_rule: definition.Rule,
) !ReducerConfig {
    var reducer_parsed = try parseRule(allocator, reducer_rule);
    defer reducer_parsed.deinit();
    const reducer = reducer_parsed.value.object;
    try validateReducerConfigObject(reducer);
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
    var retain_latest = try compileOptionalPointer(
        allocator,
        reducer,
        "retain_latest",
    );
    errdefer if (retain_latest) |*pointer| pointer.deinit(allocator);
    if (retain_once != null and retain_latest != null) {
        return error.ConflictingReducerRetention;
    }
    var assert_from = try compileOptionalPointer(allocator, reducer, "from");
    errdefer if (assert_from) |*pointer| pointer.deinit(allocator);
    var assert_to = try compileOptionalPointer(allocator, reducer, "to");
    errdefer if (assert_to) |*pointer| pointer.deinit(allocator);
    const guards = if (reducer.get("guards") != null)
        try compileGuards(
            allocator,
            definition_plan orelse
                return error.ReducerGuardsRequireDefinitionPlan,
            reducer,
        )
    else
        try allocator.alloc(Guard, 0);
    errdefer {
        for (guards) |*guard| guard.deinit(allocator);
        allocator.free(guards);
    }
    var relation_plan = if (reducer.get("relation")) |value|
        try relation.compile(allocator, value)
    else
        null;
    errdefer if (relation_plan) |*value| value.deinit(allocator);
    return .{
        .relation_plan = relation_plan,
        .key = key,
        .on = on,
        .event_kind = event_kind,
        .retain_once = retain_once,
        .retain_latest = retain_latest,
        .assert_from = assert_from,
        .assert_to = assert_to,
        .assertion_presence = try compileAssertionPresence(reducer),
        .guards = guards,
    };
}

fn validateReducerConfigObject(reducer: std.json.ObjectMap) !void {
    try definition_core.json.requireExactKeys(
        reducer,
        &.{
            "op",
            "key",
            "on",
            "event_kind",
            "retain_once",
            "retain_latest",
            "from",
            "to",
            "assertion_presence",
            "guards",
            "relation",
        },
    );
    try definition_core.json.requireFields(reducer, &.{ "op", "key", "on" });
}

fn compileGuards(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    reducer: std.json.ObjectMap,
) ![]Guard {
    const raw = reducer.get("guards") orelse return allocator.alloc(Guard, 0);
    const values = try definition_core.json.array(raw);
    if (values.items.len > max_transitions) {
        return error.InvalidReducerGuardCount;
    }
    const guards = try allocator.alloc(Guard, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (guards[0..initialized]) |*guard| guard.deinit(allocator);
        allocator.free(guards);
    }
    for (values.items) |value| {
        guards[initialized] = try compileGuard(
            allocator,
            definition_plan,
            try definition_core.json.object(value),
        );
        initialized += 1;
    }
    std.sort.heap(Guard, guards, {}, guardLessThan);
    for (guards[1..], 1..) |guard, index| {
        if (!guardLessThan({}, guards[index - 1], guard)) {
            return error.DuplicateReducerGuard;
        }
    }
    return guards;
}

fn compileGuard(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !Guard {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "event_kind", "on", "rules" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "event_kind", "on", "rules" },
    );
    const event_kind_text =
        try definition_core.json.requiredString(object, "event_kind");
    try validateIdentifier(event_kind_text);
    const event_kind = try allocator.dupe(u8, event_kind_text);
    errdefer allocator.free(event_kind);
    const on_text = try definition_core.json.requiredString(object, "on");
    try validateIdentifier(on_text);
    const on = try allocator.dupe(u8, on_text);
    errdefer allocator.free(on);
    const inputs = try guardInputsAlloc(
        allocator,
        definition_plan.bounds.max_input_bytes,
    );
    defer deinitGuardInputs(allocator, inputs);
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
    return .{
        .event_kind = event_kind,
        .on = on,
        .validation_plan = validation_plan,
    };
}

fn guardInputsAlloc(
    allocator: std.mem.Allocator,
    max_bytes: usize,
) ![]definition.Input {
    const inputs = try allocator.alloc(definition.Input, 2);
    var initialized: usize = 0;
    errdefer {
        for (inputs[0..initialized]) |*input| input.deinit(allocator);
        allocator.free(inputs);
    }
    const names = [_][]const u8{ "event", "retained" };
    for (names) |name| {
        inputs[initialized] = .{
            .name = try allocator.dupe(u8, name),
            .codec = .json,
            .required = true,
            .max_bytes = max_bytes,
        };
        initialized += 1;
    }
    return inputs;
}

fn deinitGuardInputs(
    allocator: std.mem.Allocator,
    inputs: []definition.Input,
) void {
    for (inputs) |*input| input.deinit(allocator);
    allocator.free(inputs);
}

fn guardLessThan(_: void, left: Guard, right: Guard) bool {
    const event_order = std.mem.order(u8, left.event_kind, right.event_kind);
    if (event_order != .eq) return event_order == .lt;
    return std.mem.lessThan(u8, left.on, right.on);
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(6);
    try encodeStringSet(plan.states, encoder);
    try encoder.writeCount(plan.transitions.len);
    for (plan.transitions) |transition| {
        try encoder.writeOptionalBytes(transition.from);
        try encoder.writeBytes(transition.on);
        try encoder.writeBytes(transition.to);
    }
    try encoder.writeCount(plan.guards.len);
    for (plan.guards) |guard| {
        try encoder.writeBytes(guard.event_kind);
        try encoder.writeBytes(guard.on);
        try validation.encodeCache(&guard.validation_plan, encoder);
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
    try encoder.writeOptionalBytes(if (plan.retain_latest) |pointer|
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
    try encoder.writeOptionalBytes(if (plan.relation_plan) |value| value.raw else null);
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 6) {
        return error.LedgerReducerCacheVersionMismatch;
    }
    const states = try decodeStringSet(allocator, decoder, max_states);
    errdefer deinitStringSet(allocator, states);
    const transitions = try decodeTransitions(allocator, decoder);
    errdefer deinitTransitions(allocator, transitions);
    const guards = try decodeGuards(allocator, decoder);
    errdefer deinitGuards(allocator, guards);
    var key = try decodePointer(allocator, decoder);
    errdefer key.deinit(allocator);
    var on = try decodePointer(allocator, decoder);
    errdefer on.deinit(allocator);
    var event_kind = try decodeOptionalPointer(allocator, decoder);
    errdefer if (event_kind) |*pointer| pointer.deinit(allocator);
    var retain_once = try decodeOptionalPointer(allocator, decoder);
    errdefer if (retain_once) |*pointer| pointer.deinit(allocator);
    var retain_latest = try decodeOptionalPointer(allocator, decoder);
    errdefer if (retain_latest) |*pointer| pointer.deinit(allocator);
    var assert_from = try decodeOptionalPointer(allocator, decoder);
    errdefer if (assert_from) |*pointer| pointer.deinit(allocator);
    var assert_to = try decodeOptionalPointer(allocator, decoder);
    errdefer if (assert_to) |*pointer| pointer.deinit(allocator);
    var result: Plan = .{
        .states = states,
        .transitions = transitions,
        .guards = guards,
        .key = key,
        .on = on,
        .event_kind = event_kind,
        .retain_once = retain_once,
        .retain_latest = retain_latest,
        .assert_from = assert_from,
        .assert_to = assert_to,
        .assertion_presence = try decoder.readEnum(AssertionPresence),
        .max_entries = try decoder.readUsize(),
        .max_retained_value_bytes = try decoder.readUsize(),
        .max_retained_total_bytes = try decoder.readUsize(),
    };
    const relation_raw = try decoder.readOptionalBytesAlloc(allocator, relation.max_config_bytes);
    defer if (relation_raw) |raw| allocator.free(raw);
    if (relation_raw) |raw| result.relation_plan = try relation.compileBytes(allocator, raw);
    errdefer if (result.relation_plan) |*value| value.deinit(allocator);
    try validatePlan(&result);
    return result;
}

fn decodeTransitions(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]Transition {
    const count = try decoder.readCount(max_transitions);
    if (count == 0) return error.InvalidTransitionTable;
    const transitions = try allocator.alloc(Transition, count);
    var initialized: usize = 0;
    errdefer {
        for (transitions[0..initialized]) |*transition| {
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
        initialized += 1;
    }
    return transitions;
}

fn deinitTransitions(
    allocator: std.mem.Allocator,
    transitions: []Transition,
) void {
    for (transitions) |*transition| transition.deinit(allocator);
    allocator.free(transitions);
}

fn decodeGuards(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]Guard {
    const count = try decoder.readCount(max_transitions);
    const guards = try allocator.alloc(Guard, count);
    var initialized: usize = 0;
    errdefer {
        for (guards[0..initialized]) |*guard| guard.deinit(allocator);
        allocator.free(guards);
    }
    for (guards) |*guard| {
        guard.* = .{
            .event_kind = try decoder.readBytesAlloc(
                allocator,
                max_text_bytes,
            ),
            .on = undefined,
            .validation_plan = undefined,
        };
        errdefer allocator.free(guard.event_kind);
        guard.on = try decoder.readBytesAlloc(allocator, max_text_bytes);
        errdefer allocator.free(guard.on);
        guard.validation_plan = try validation.decodeCache(allocator, decoder);
        initialized += 1;
    }
    return guards;
}

fn deinitGuards(allocator: std.mem.Allocator, guards: []Guard) void {
    for (guards) |*guard| guard.deinit(allocator);
    allocator.free(guards);
}

pub fn apply(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *State,
    event: std.json.Value,
) !void {
    const context = try resolveReducerTransition(plan, state, event);
    try validateTransitionAssertions(plan, event, context);
    try validateTransitionGuard(allocator, plan, event, context);
    var retained_value = try retainedValueAlloc(
        allocator,
        plan,
        context.prior,
        event,
    );
    defer if (retained_value) |value| allocator.free(value);
    try validateReducerCapacity(plan, state, context.prior, retained_value);
    try validateRelationState(allocator, plan, state, .{
        .key = context.key,
        .state = context.transition.to,
        .retained = retained_value orelse if (context.prior) |prior| prior.retained else null,
    });
    try commitReducerTransition(
        allocator,
        state,
        context,
        &retained_value,
    );
}

fn validateTransitionGuard(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    event: std.json.Value,
    context: ReducerTransition,
) !void {
    if (plan.guards.len == 0) return;
    const event_kind_pointer = plan.event_kind orelse
        return error.ReducerGuardRequiresEventKind;
    const event_kind_value = definition_core.json_pointer.lookup(
        event,
        event_kind_pointer,
    ) orelse return error.ReducerEventKindMissing;
    const event_kind = try boundedIdentifier(
        event_kind_value,
        error.InvalidReducerEventKind,
    );
    const guard = findGuard(
        plan.guards,
        event_kind,
        context.transition.on,
    ) orelse return;
    const prior = context.prior orelse
        return error.ReducerGuardRetainedValueMissing;
    const retained = prior.retained orelse
        return error.ReducerGuardRetainedValueMissing;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        retained,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    );
    defer parsed.deinit();
    const values = &.{
        validation.InputValue{ .name = "event", .value = event },
        validation.InputValue{
            .name = "retained",
            .value = parsed.value,
        },
    };
    var execution = try validation.executeValues(
        allocator,
        &guard.validation_plan,
        values,
    );
    defer execution.deinit();
    if (!execution.isValid()) return error.ReducerTransitionGuardRejected;
}

fn findGuard(
    guards: []const Guard,
    event_kind: []const u8,
    on: []const u8,
) ?*const Guard {
    var low: usize = 0;
    var high = guards.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = &guards[middle];
        const event_order = std.mem.order(
            u8,
            event_kind,
            candidate.event_kind,
        );
        const order = if (event_order == .eq)
            std.mem.order(u8, on, candidate.on)
        else
            event_order;
        switch (order) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return candidate,
        }
    }
    return null;
}

const ReducerTransition = struct {
    key: []const u8,
    key_digest: [32]u8,
    prior: ?Entry,
    transition: *const Transition,
};

fn resolveReducerTransition(
    plan: *const Plan,
    state: *const State,
    event: std.json.Value,
) !ReducerTransition {
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
    return .{
        .key = key,
        .key_digest = key_digest,
        .prior = prior,
        .transition = transition,
    };
}

fn validateTransitionAssertions(
    plan: *const Plan,
    event: std.json.Value,
    context: ReducerTransition,
) !void {
    const prior_state = if (context.prior) |entry| entry.state() else null;
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
            context.transition.to,
            error.ReducerToAssertionMissing,
            error.ReducerToAssertionMismatch,
        );
    }
}

fn retainedValueAlloc(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    prior: ?Entry,
    event: std.json.Value,
) !?[]u8 {
    const pointer = plan.retain_once orelse
        plan.retain_latest orelse return null;
    const value = definition_core.json_pointer.lookup(event, pointer) orelse {
        if (prior == null) return error.ReducerRetainedValueMissing;
        return null;
    };
    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        value,
    );
    errdefer allocator.free(canonical);
    if (canonical.len > plan.max_retained_value_bytes) {
        return error.ReducerRetainedValueBoundsExceeded;
    }
    if (prior) |entry| {
        const retained = entry.retained orelse
            return error.ReducerRetainedValueMissing;
        if (plan.retain_once != null and
            !std.mem.eql(u8, retained, canonical))
        {
            return error.ReducerRetainedValueChanged;
        }
        if (std.mem.eql(u8, retained, canonical)) {
            allocator.free(canonical);
            return null;
        }
    }
    return canonical;
}

fn validateReducerCapacity(
    plan: *const Plan,
    state: *const State,
    prior: ?Entry,
    retained_value: ?[]const u8,
) !void {
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
        if (retained_value) |value| {
            const retained = entry.retained orelse
                return error.ReducerRetainedValueMissing;
            const without_prior = state.retained_bytes -| retained.len;
            if (without_prior >
                plan.max_retained_total_bytes -| value.len)
            {
                return error.ReducerRetainedTotalBoundsExceeded;
            }
        }
        if (entry.event_count == std.math.maxInt(usize)) {
            return error.ReducerEventCountOverflow;
        }
    }
}

fn commitReducerTransition(
    allocator: std.mem.Allocator,
    state: *State,
    context: ReducerTransition,
    retained_value: *?[]u8,
) !void {
    const result = try state.entries.getOrPut(allocator, context.key_digest);
    if (result.found_existing) {
        if (!std.mem.eql(u8, result.value_ptr.key(), context.key)) {
            return error.ReducerKeyDigestCollision;
        }
        result.value_ptr.setState(context.transition.to);
        result.value_ptr.event_count += 1;
        if (retained_value.*) |value| {
            const prior = result.value_ptr.retained orelse
                return error.ReducerRetainedValueMissing;
            state.retained_bytes -= prior.len;
            allocator.free(prior);
            result.value_ptr.retained = value;
            state.retained_bytes += value.len;
            retained_value.* = null;
        }
    } else {
        result.value_ptr.* = Entry.init(
            context.key,
            context.transition.to,
            retained_value.*,
        );
        if (retained_value.*) |value| state.retained_bytes += value.len;
        retained_value.* = null;
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
    std.sort.heap(Transition, transitions, {}, transitionLessThan);
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

fn validateRelationState(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    state: *const State,
    successor: ?relation.Record,
) !void {
    const configured = if (plan.relation_plan) |*value| value else return;
    var records: std.ArrayList(relation.Record) = .empty;
    defer records.deinit(allocator);
    try records.ensureTotalCapacity(allocator, state.count() + @intFromBool(successor != null));
    var iterator = state.entries.valueIterator();
    while (iterator.next()) |entry| {
        if (successor) |candidate| {
            if (std.mem.eql(u8, entry.key(), candidate.key)) continue;
        }
        records.appendAssumeCapacity(.{
            .key = entry.key(),
            .state = entry.state(),
            .retained = entry.retained,
        });
    }
    if (successor) |candidate| records.appendAssumeCapacity(candidate);
    var index = try relation.Index.init(allocator, configured, records.items);
    defer index.deinit(allocator);
}

pub fn validatePlan(plan: *const Plan) !void {
    if (plan.relation_plan) |*configured| {
        if (plan.retain_once == null and plan.retain_latest == null) {
            return error.RelationRequiresRetention;
        }
        try configured.validate(plan.max_entries, plan.states);
    }
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
    for (plan.guards, 0..) |*guard, index| {
        try validateIdentifier(guard.event_kind);
        try validateIdentifier(guard.on);
        if (findTransitionOn(plan.transitions, guard.on) == null or
            (index != 0 and
                !guardLessThan({}, plan.guards[index - 1], guard.*)))
        {
            return error.InvalidReducerGuard;
        }
    }
    try validatePointer(plan.key);
    try validatePointer(plan.on);
    if (plan.event_kind) |pointer| try validatePointer(pointer);
    if (plan.retain_once) |pointer| try validatePointer(pointer);
    if (plan.retain_latest) |pointer| try validatePointer(pointer);
    if (plan.retain_once != null and plan.retain_latest != null) {
        return error.ConflictingReducerRetention;
    }
    if (plan.assert_from) |pointer| try validatePointer(pointer);
    if (plan.assert_to) |pointer| try validatePointer(pointer);
    if (plan.assertion_presence == .when_present and
        plan.assert_from == null and plan.assert_to == null)
    {
        return error.RedundantReducerAssertionPresence;
    }
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    try validatePlan(plan);
    for (plan.guards) |*guard| {
        try validation.validateEmbeddedCachePlan(
            &guard.validation_plan,
            definition_plan,
        );
        try validateGuardInputs(
            &guard.validation_plan,
            definition_plan.bounds.max_input_bytes,
        );
    }
}

pub fn validateEventKinds(
    plan: *const Plan,
    event_kinds: []const []u8,
) !void {
    for (plan.guards) |guard| {
        if (!containsSorted(event_kinds, guard.event_kind)) {
            return error.UnknownReducerGuardEventKind;
        }
    }
}

fn validateGuardInputs(
    validation_plan: *const validation.Plan,
    max_bytes: usize,
) !void {
    if (validation_plan.inputs.len != 2) {
        return error.CacheReducerGuardInputsMismatch;
    }
    for (validation_plan.inputs, 0..) |input, index| {
        const expected = if (index == 0) "event" else "retained";
        if (!std.mem.eql(u8, input.name, expected) or
            input.codec != .json or !input.required or
            input.max_bytes != max_bytes)
        {
            return error.CacheReducerGuardInputsMismatch;
        }
    }
}

fn findTransitionOn(
    transitions: []const Transition,
    on: []const u8,
) ?*const Transition {
    for (transitions) |*transition| {
        if (std.mem.eql(u8, transition.on, on)) return transition;
    }
    return null;
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
    std.sort.heap([]u8, out, {}, stringLessThan);
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

fn entryViewLessThan(_: void, left: EntryView, right: EntryView) bool {
    return std.mem.lessThan(u8, left.key, right.key);
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

const deterministic_table =
    "{\"op\":\"transition-table\",\"states\":[\"closed\",\"open\"]," ++
    "\"transitions\":[{\"from\":null,\"on\":\"create\",\"to\":\"open\"}," ++
    "{\"from\":\"open\",\"on\":\"close\",\"to\":\"closed\"}," ++
    "{\"from\":\"closed\",\"on\":\"reopen\",\"to\":\"open\"}]}";
const deterministic_reducer =
    "{\"op\":\"reducer\",\"key\":\"/id\",\"on\":\"/event\"," ++
    "\"from\":\"/from\",\"to\":\"/to\"}";
const assertion_table =
    "{\"op\":\"transition-table\",\"states\":[\"active\",\"closed\"]," ++
    "\"transitions\":[{\"from\":null,\"on\":\"active\",\"to\":\"active\"}," ++
    "{\"from\":\"active\",\"on\":\"closed\",\"to\":\"closed\"}]}";
const assertion_reducer =
    "{\"assertion_presence\":\"when-present\",\"event_kind\":\"/event\"," ++
    "\"from\":\"/from\",\"key\":\"/id\",\"on\":\"/status\"," ++
    "\"op\":\"reducer\",\"retain_once\":\"/record\",\"to\":\"/to\"}";
const replace_table =
    "{\"op\":\"transition-table\",\"states\":[\"active\",\"candidate\"]," ++
    "\"transitions\":[{\"from\":null,\"on\":\"candidate\",\"to\":\"candidate\"}," ++
    "{\"from\":\"candidate\",\"on\":\"active\",\"to\":\"active\"}]}";
const replace_reducer =
    "{\"event_kind\":\"/event\",\"key\":\"/id\",\"on\":\"/status\"," ++
    "\"op\":\"reducer\",\"retain_latest\":\"/record\"}";

fn testRule(operator: definition.Operator, config: []const u8) definition.Rule {
    return .{
        .operator = operator,
        .pointer_id = null,
        .canonical_config = @constCast(config),
    };
}

fn applyTestEvent(
    plan: *const Plan,
    state: *State,
    text: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        text,
        .{},
    );
    defer parsed.deinit();
    try apply(std.testing.allocator, plan, state, parsed.value);
}

fn expectTestEventError(
    expected: anyerror,
    plan: *const Plan,
    state: *State,
    text: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        text,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        expected,
        apply(std.testing.allocator, plan, state, parsed.value),
    );
}

fn exerciseDeterministicTransitions(plan: *const Plan, state: *State) !void {
    try applyTestEvent(
        plan,
        state,
        "{\"event\":\"create\",\"from\":null,\"id\":\"item-1\",\"to\":\"open\"}",
    );
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try expectTestEventError(
        error.ReducerToAssertionMismatch,
        plan,
        state,
        "{\"event\":\"close\",\"from\":\"open\"," ++
            "\"id\":\"item-1\",\"to\":\"open\"}",
    );
    try applyTestEvent(
        plan,
        state,
        "{\"event\":\"close\",\"from\":\"open\"," ++
            "\"id\":\"item-1\",\"to\":\"closed\"}",
    );
    try expectTestEventError(
        error.IllegalReducerTransition,
        plan,
        state,
        "{\"event\":\"close\",\"from\":\"closed\"," ++
            "\"id\":\"item-1\",\"to\":\"closed\"}",
    );
    try applyTestEvent(
        plan,
        state,
        "{\"event\":\"create\",\"from\":null,\"id\":\"item-2\",\"to\":\"open\"}",
    );
}

fn expectDeterministicProjection(state: *State) !void {
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
    try std.testing.expectEqual(
        @as(usize, 3),
        try state.nextMonotonicSuffix("item-"),
    );
}

fn expectReducerBounds(
    table_rule: definition.Rule,
    reducer_rule: definition.Rule,
    plan: *const Plan,
    state: *State,
) !void {
    var constrained_plan = try compile(
        std.testing.allocator,
        null,
        table_rule,
        reducer_rule,
        testBounds(1),
    );
    defer constrained_plan.deinit(std.testing.allocator);
    try expectTestEventError(
        error.ReducerStateBoundsExceeded,
        &constrained_plan,
        state,
        "{\"event\":\"create\",\"from\":null,\"id\":\"item-3\",\"to\":\"open\"}",
    );
    try expectTestEventError(
        error.ReducerStateBoundsExceeded,
        plan,
        state,
        "{\"event\":\"create\",\"from\":null,\"id\":\"item-3\",\"to\":\"open\"}",
    );
}

fn cacheRoundTripPlan(compiled: *const Plan) !Plan {
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        4096,
    );
    defer encoder.deinit();
    try encodeCache(compiled, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var plan = try decodeCache(std.testing.allocator, &decoder);
    errdefer plan.deinit(std.testing.allocator);
    try decoder.finish();
    return plan;
}

fn exerciseAssertionTransitions(plan: *const Plan, state: *State) !void {
    try applyTestEvent(
        plan,
        state,
        "{\"event\":\"capture\",\"id\":\"item-1\"," ++
            "\"record\":{\"value\":1},\"status\":\"active\"}",
    );
    try expectTestEventError(
        error.ReducerFromAssertionMismatch,
        plan,
        state,
        "{\"event\":\"status\",\"from\":\"closed\",\"id\":\"item-1\"," ++
            "\"status\":\"closed\",\"to\":\"closed\"}",
    );
    try applyTestEvent(
        plan,
        state,
        "{\"event\":\"status\",\"from\":\"active\",\"id\":\"item-1\"," ++
            "\"status\":\"closed\",\"to\":\"closed\"}",
    );
}

fn expectAssertionProjection(state: *State) !void {
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
        "[{\"event_count\":2,\"id\":\"item-1\"," ++
            "\"record\":{\"value\":1},\"status\":\"closed\"}]",
        projection.written(),
    );
}

test "compiled reducer admits deterministic keyed transitions" {
    const table_rule = testRule(.transition_table, deterministic_table);
    const reducer_rule = testRule(.reducer, deterministic_reducer);
    var plan = try compile(
        std.testing.allocator,
        null,
        table_rule,
        reducer_rule,
        testBounds(2),
    );
    defer plan.deinit(std.testing.allocator);
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try exerciseDeterministicTransitions(&plan, &state);
    try expectDeterministicProjection(&state);
    try expectReducerBounds(table_rule, reducer_rule, &plan, &state);
}

test "keyed reducer checks transition assertions when rows carry them" {
    const table_rule = testRule(.transition_table, assertion_table);
    const reducer_rule = testRule(.reducer, assertion_reducer);
    var compiled = try compile(
        std.testing.allocator,
        null,
        table_rule,
        reducer_rule,
        testBounds(2),
    );
    defer compiled.deinit(std.testing.allocator);
    var plan = try cacheRoundTripPlan(&compiled);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.event_kind != null);
    try std.testing.expect(plan.retain_once != null);
    try std.testing.expectEqual(
        AssertionPresence.when_present,
        plan.assertion_presence,
    );

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try exerciseAssertionTransitions(&plan, &state);
    try expectAssertionProjection(&state);
}

test "keyed reducer replaces retained state only when declared" {
    var compiled = try compile(
        std.testing.allocator,
        null,
        testRule(.transition_table, replace_table),
        testRule(.reducer, replace_reducer),
        testBounds(2),
    );
    defer compiled.deinit(std.testing.allocator);
    var plan = try cacheRoundTripPlan(&compiled);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.retain_latest != null);

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try applyTestEvent(
        &plan,
        &state,
        "{\"event\":\"capture\",\"id\":\"item-1\"," ++
            "\"record\":{\"value\":1},\"status\":\"candidate\"}",
    );
    try applyTestEvent(
        &plan,
        &state,
        "{\"event\":\"status\",\"id\":\"item-1\"," ++
            "\"record\":{\"value\":2},\"status\":\"active\"}",
    );
    const current = state.get("item-1").?;
    try std.testing.expectEqualStrings("active", current.state);
    try std.testing.expectEqualStrings(
        "{\"value\":2}",
        current.retained.?,
    );
}
