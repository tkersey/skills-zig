const std = @import("std");
const definition_core = @import("definition_core");

const max_depth: usize = 8;
const max_nodes: usize = 256;
const max_collection_items: usize = 64;
const max_pointer_bytes: usize = 1024;
const max_field_name_bytes: usize = 128;

const Pointer = struct {
    pointer: definition_core.json_pointer.Pointer,
    fallback_pointer: ?definition_core.json_pointer.Pointer,
    fallback: ?[]u8,

    fn deinit(self: *Pointer, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        if (self.fallback_pointer) |*pointer| pointer.deinit(allocator);
        if (self.fallback) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

const Fragment = union(enum) {
    literal: []u8,
    pointer: definition_core.json_pointer.Pointer,

    fn deinit(self: *Fragment, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .literal => |text| allocator.free(text),
            .pointer => |*pointer| pointer.deinit(allocator),
        }
        self.* = undefined;
    }
};

const Concat = struct {
    fragments: []Fragment,
    max_bytes: usize,

    fn deinit(self: *Concat, allocator: std.mem.Allocator) void {
        for (self.fragments) |*fragment| fragment.deinit(allocator);
        allocator.free(self.fragments);
        self.* = undefined;
    }
};

const ChoiceCase = struct {
    equals: []u8,
    value: Value,

    fn deinit(self: *ChoiceCase, allocator: std.mem.Allocator) void {
        if (self.equals.len > 0) allocator.free(self.equals);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

const Choice = struct {
    pointer: definition_core.json_pointer.Pointer,
    cases: []ChoiceCase,
    fallback: *Value,

    fn deinit(self: *Choice, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        for (self.cases) |*case| case.deinit(allocator);
        allocator.free(self.cases);
        self.fallback.deinit(allocator);
        allocator.destroy(self.fallback);
        self.* = undefined;
    }
};

const Field = struct {
    name: []u8,
    value: Value,

    fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Value = union(enum) {
    literal: []u8,
    pointer: Pointer,
    concat: Concat,
    object: []Field,
    array: []Value,
    choice: Choice,
    pending,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .literal => |bytes| allocator.free(bytes),
            .pointer => |*pointer| pointer.deinit(allocator),
            .concat => |*concat| concat.deinit(allocator),
            .object => |fields| {
                for (fields) |*field| field.deinit(allocator);
                allocator.free(fields);
            },
            .array => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .choice => |*choice| choice.deinit(allocator),
            .pending => {},
        }
        self.* = undefined;
    }
};

const CompileState = struct {
    nodes: usize = 0,
    max_output_bytes: usize,

    fn enter(self: *CompileState, depth: usize) !void {
        if (depth > max_depth) return error.ProjectionValueDepthExceeded;
        self.nodes = std.math.add(usize, self.nodes, 1) catch
            return error.ProjectionValueNodesExceeded;
        if (self.nodes > max_nodes) {
            return error.ProjectionValueNodesExceeded;
        }
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    max_output_bytes: usize,
) !Value {
    var state: CompileState = .{ .max_output_bytes = max_output_bytes };
    var result: Value = .pending;
    errdefer result.deinit(allocator);
    var tasks: [max_nodes]CompileTask = undefined;
    var task_count: usize = 0;
    try pushCompileTask(
        &tasks,
        &task_count,
        .{ .source = source, .target = &result, .depth = 0 },
    );
    while (task_count > 0) {
        task_count -= 1;
        const task = tasks[task_count];
        try state.enter(task.depth);
        try compileOne(allocator, task, &state, &tasks, &task_count);
    }
    return result;
}

const CompileTask = struct {
    source: std.json.Value,
    target: *Value,
    depth: usize,
};

fn pushCompileTask(
    tasks: *[max_nodes]CompileTask,
    count: *usize,
    task: CompileTask,
) !void {
    if (count.* == tasks.len) return error.ProjectionValueNodesExceeded;
    tasks[count.*] = task;
    count.* += 1;
}

const SourceKind = enum {
    literal,
    pointer,
    concat,
    object,
    array,
    choice,
};

fn sourceKind(object: std.json.ObjectMap) !SourceKind {
    const kinds = [_]struct { name: []const u8, kind: SourceKind }{
        .{ .name = "literal", .kind = .literal },
        .{ .name = "path", .kind = .pointer },
        .{ .name = "concat", .kind = .concat },
        .{ .name = "object", .kind = .object },
        .{ .name = "array", .kind = .array },
        .{ .name = "switch", .kind = .choice },
    };
    var selected: ?SourceKind = null;
    for (kinds) |candidate| {
        if (!object.contains(candidate.name)) continue;
        if (selected != null) return error.InvalidProjectionValueSource;
        selected = candidate.kind;
    }
    return selected orelse error.InvalidProjectionValueSource;
}

fn compileOne(
    allocator: std.mem.Allocator,
    task: CompileTask,
    state: *CompileState,
    tasks: *[max_nodes]CompileTask,
    task_count: *usize,
) !void {
    const object = try definition_core.json.object(task.source);
    switch (try sourceKind(object)) {
        .literal => try compileLiteral(allocator, object, state, task.target),
        .pointer => try compilePointer(allocator, object, state, task.target),
        .concat => try compileConcat(
            allocator,
            object,
            state,
            task.depth,
            task.target,
        ),
        .object => try compileObject(
            allocator,
            object,
            task,
            tasks,
            task_count,
        ),
        .array => try compileArray(allocator, object, task, tasks, task_count),
        .choice => try compileChoice(allocator, object, task, tasks, task_count),
    }
}

fn compileLiteral(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    state: *const CompileState,
    target: *Value,
) !void {
    try definition_core.json.requireExactKeys(object, &.{"literal"});
    const bytes = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        object.get("literal").?,
    );
    errdefer allocator.free(bytes);
    if (bytes.len > state.max_output_bytes) {
        return error.ProjectionValueLiteralBoundsExceeded;
    }
    target.* = .{ .literal = bytes };
}

fn compilePointer(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    state: *const CompileState,
    target: *Value,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "default", "fallback_path", "path" },
    );
    const raw = try definition_core.json.string(object.get("path").?);
    if (raw.len > max_pointer_bytes) {
        return error.ProjectionValuePointerBoundsExceeded;
    }
    var pointer = try definition_core.json_pointer.compile(allocator, raw);
    errdefer pointer.deinit(allocator);
    var fallback_pointer = if (object.get("fallback_path")) |value|
        try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(value),
        )
    else
        null;
    errdefer if (fallback_pointer) |*compiled| compiled.deinit(allocator);
    const fallback = if (object.get("default")) |value|
        try definition_core.canonical_json.canonicalJsonAlloc(allocator, value)
    else
        null;
    errdefer if (fallback) |bytes| allocator.free(bytes);
    if (fallback) |bytes| {
        if (bytes.len > state.max_output_bytes) {
            return error.ProjectionValueLiteralBoundsExceeded;
        }
    }
    target.* = .{ .pointer = .{
        .pointer = pointer,
        .fallback_pointer = fallback_pointer,
        .fallback = fallback,
    } };
}

fn compileConcat(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    state: *CompileState,
    depth: usize,
    target: *Value,
) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "concat", "max_bytes" },
    );
    const max_bytes = try definition_core.json.unsigned(
        try definition_core.json.field(object, "max_bytes"),
    );
    if (max_bytes == 0 or max_bytes > state.max_output_bytes) {
        return error.ProjectionValueConcatBoundsInvalid;
    }
    const raw = try definition_core.json.array(object.get("concat").?);
    if (raw.items.len == 0 or raw.items.len > max_collection_items) {
        return error.ProjectionValueFragmentsInvalid;
    }
    const fragments = try allocator.alloc(Fragment, raw.items.len);
    var initialized: usize = 0;
    errdefer {
        for (fragments[0..initialized]) |*fragment| fragment.deinit(allocator);
        allocator.free(fragments);
    }
    for (raw.items) |source| {
        try state.enter(depth + 1);
        fragments[initialized] = try compileFragment(
            allocator,
            source,
            max_bytes,
        );
        initialized += 1;
    }
    target.* = .{ .concat = .{
        .fragments = fragments,
        .max_bytes = max_bytes,
    } };
}

fn compileFragment(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    max_bytes: usize,
) !Fragment {
    const object = try definition_core.json.object(source);
    const literal = object.get("literal");
    const path = object.get("path");
    if ((literal == null) == (path == null)) {
        return error.InvalidProjectionValueFragment;
    }
    if (literal) |value| {
        try definition_core.json.requireExactKeys(object, &.{"literal"});
        const text = try definition_core.json.string(value);
        if (!std.unicode.utf8ValidateSlice(text)) {
            return error.InvalidProjectionValueFragment;
        }
        if (text.len > max_bytes) {
            return error.ProjectionValueConcatBoundsExceeded;
        }
        return .{ .literal = try allocator.dupe(u8, text) };
    }
    try definition_core.json.requireExactKeys(object, &.{"path"});
    const raw = try definition_core.json.string(path.?);
    if (raw.len > max_pointer_bytes) {
        return error.ProjectionValuePointerBoundsExceeded;
    }
    return .{
        .pointer = try definition_core.json_pointer.compile(allocator, raw),
    };
}

fn compileObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    task: CompileTask,
    tasks: *[max_nodes]CompileTask,
    task_count: *usize,
) !void {
    try definition_core.json.requireExactKeys(object, &.{"object"});
    const raw = try definition_core.json.array(object.get("object").?);
    if (raw.items.len == 0 or raw.items.len > max_collection_items) {
        return error.ProjectionValueFieldsInvalid;
    }
    const fields = try allocator.alloc(Field, raw.items.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (raw.items) |source| {
        const field = try definition_core.json.object(source);
        try definition_core.json.requireExactKeys(field, &.{ "name", "value" });
        try definition_core.json.requireFields(field, &.{ "name", "value" });
        const name = try definition_core.json.requiredString(field, "name");
        if (name.len == 0 or name.len > max_field_name_bytes) {
            return error.ProjectionValueFieldNameInvalid;
        }
        for (fields[0..initialized]) |prior| {
            if (std.mem.eql(u8, prior.name, name)) {
                return error.ProjectionValueFieldsNotUnique;
            }
        }
        fields[initialized] = .{
            .name = try allocator.dupe(u8, name),
            .value = .pending,
        };
        initialized += 1;
    }
    var index = raw.items.len;
    while (index > 0) {
        index -= 1;
        const field = try definition_core.json.object(raw.items[index]);
        try pushCompileTask(tasks, task_count, .{
            .source = try definition_core.json.field(field, "value"),
            .target = &fields[index].value,
            .depth = task.depth + 1,
        });
    }
    task.target.* = .{ .object = fields };
}

fn compileArray(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    task: CompileTask,
    tasks: *[max_nodes]CompileTask,
    task_count: *usize,
) !void {
    try definition_core.json.requireExactKeys(object, &.{"array"});
    const raw = try definition_core.json.array(object.get("array").?);
    if (raw.items.len > max_collection_items) {
        return error.ProjectionValueItemsInvalid;
    }
    const items = try allocator.alloc(Value, raw.items.len);
    for (items) |*item| item.* = .pending;
    errdefer {
        for (items) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    var index = raw.items.len;
    while (index > 0) {
        index -= 1;
        try pushCompileTask(tasks, task_count, .{
            .source = raw.items[index],
            .target = &items[index],
            .depth = task.depth + 1,
        });
    }
    task.target.* = .{ .array = items };
}

fn compileChoice(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    task: CompileTask,
    tasks: *[max_nodes]CompileTask,
    task_count: *usize,
) !void {
    try definition_core.json.requireExactKeys(object, &.{"switch"});
    const choice_object = try definition_core.json.object(
        object.get("switch").?,
    );
    try definition_core.json.requireExactKeys(
        choice_object,
        &.{ "path", "cases", "default" },
    );
    try definition_core.json.requireFields(
        choice_object,
        &.{ "path", "cases", "default" },
    );
    var pointer = try definition_core.json_pointer.compile(
        allocator,
        try definition_core.json.requiredString(choice_object, "path"),
    );
    errdefer pointer.deinit(allocator);
    const cases = try compileChoiceCases(allocator, choice_object);
    errdefer {
        for (cases) |*case| case.deinit(allocator);
        allocator.free(cases);
    }
    const fallback = try allocator.create(Value);
    errdefer allocator.destroy(fallback);
    fallback.* = .pending;
    errdefer fallback.deinit(allocator);
    try scheduleCompileChoice(
        choice_object,
        task,
        cases,
        fallback,
        tasks,
        task_count,
    );
    task.target.* = .{ .choice = .{
        .pointer = pointer,
        .cases = cases,
        .fallback = fallback,
    } };
}

fn compileChoiceCases(
    allocator: std.mem.Allocator,
    choice_object: std.json.ObjectMap,
) ![]ChoiceCase {
    const raw_cases = try definition_core.json.array(
        try definition_core.json.field(choice_object, "cases"),
    );
    if (raw_cases.items.len == 0 or
        raw_cases.items.len > max_collection_items)
    {
        return error.ProjectionValueChoiceCasesInvalid;
    }
    const cases = try allocator.alloc(ChoiceCase, raw_cases.items.len);
    var cases_initialized: usize = 0;
    errdefer {
        for (cases[0..cases_initialized]) |*case| {
            case.deinit(allocator);
        }
        allocator.free(cases);
    }
    for (raw_cases.items) |raw_case| {
        const case_object = try definition_core.json.object(raw_case);
        try definition_core.json.requireExactKeys(
            case_object,
            &.{ "equals", "value" },
        );
        try definition_core.json.requireFields(
            case_object,
            &.{ "equals", "value" },
        );
        const equals = try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            try definition_core.json.field(case_object, "equals"),
        );
        errdefer allocator.free(equals);
        for (cases[0..cases_initialized]) |prior| {
            if (std.mem.eql(u8, prior.equals, equals)) {
                return error.ProjectionValueChoiceCasesNotUnique;
            }
        }
        cases[cases_initialized] = .{
            .equals = equals,
            .value = .pending,
        };
        cases_initialized += 1;
    }
    return cases;
}

fn scheduleCompileChoice(
    choice_object: std.json.ObjectMap,
    task: CompileTask,
    cases: []ChoiceCase,
    fallback: *Value,
    tasks: *[max_nodes]CompileTask,
    task_count: *usize,
) !void {
    try pushCompileTask(tasks, task_count, .{
        .source = try definition_core.json.field(choice_object, "default"),
        .target = fallback,
        .depth = task.depth + 1,
    });
    const raw_cases = try definition_core.json.array(
        try definition_core.json.field(choice_object, "cases"),
    );
    var index = cases.len;
    while (index > 0) {
        index -= 1;
        const case_object = try definition_core.json.object(
            raw_cases.items[index],
        );
        try pushCompileTask(tasks, task_count, .{
            .source = try definition_core.json.field(case_object, "value"),
            .target = &cases[index].value,
            .depth = task.depth + 1,
        });
    }
}

pub fn encodeCache(
    value: Value,
    encoder: *definition_core.cache.Encoder,
) !void {
    var tasks: [max_nodes * 2 + 1]EncodeTask = undefined;
    var task_count: usize = 0;
    try pushEncodeTask(&tasks, &task_count, .{ .value = value });
    var nodes: usize = 0;
    while (task_count > 0) {
        task_count -= 1;
        switch (tasks[task_count]) {
            .bytes => |bytes| try encoder.writeBytes(bytes),
            .value => |current| {
                nodes += 1;
                if (nodes > max_nodes) {
                    return error.ProjectionValueNodesExceeded;
                }
                try encodeOne(current, encoder, &tasks, &task_count);
            },
        }
    }
}

const EncodeTask = union(enum) {
    value: Value,
    bytes: []const u8,
};

fn pushEncodeTask(
    tasks: *[max_nodes * 2 + 1]EncodeTask,
    count: *usize,
    task: EncodeTask,
) !void {
    if (count.* == tasks.len) return error.ProjectionValueNodesExceeded;
    tasks[count.*] = task;
    count.* += 1;
}

fn encodeOne(
    value: Value,
    encoder: *definition_core.cache.Encoder,
    tasks: *[max_nodes * 2 + 1]EncodeTask,
    task_count: *usize,
) !void {
    switch (value) {
        .literal => |bytes| {
            try encoder.writeByte(0);
            try encoder.writeBytes(bytes);
        },
        .pointer => |pointer| {
            try encoder.writeByte(1);
            try encoder.writeBytes(pointer.pointer.raw);
            try encoder.writeOptionalBytes(
                if (pointer.fallback_pointer) |fallback|
                    fallback.raw
                else
                    null,
            );
            try encoder.writeOptionalBytes(pointer.fallback);
        },
        .concat => |concat| try encodeConcat(concat, encoder),
        .object => |fields| try encodeObject(
            fields,
            encoder,
            tasks,
            task_count,
        ),
        .array => |items| try encodeArray(items, encoder, tasks, task_count),
        .choice => |choice| try encodeChoice(
            choice,
            encoder,
            tasks,
            task_count,
        ),
        .pending => return error.ProjectionValuePending,
    }
}

fn encodeConcat(
    concat: Concat,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeByte(2);
    try encoder.writeUsize(concat.max_bytes);
    try encoder.writeCount(concat.fragments.len);
    for (concat.fragments) |fragment| switch (fragment) {
        .literal => |text| {
            try encoder.writeByte(0);
            try encoder.writeBytes(text);
        },
        .pointer => |pointer| {
            try encoder.writeByte(1);
            try encoder.writeBytes(pointer.raw);
        },
    };
}

fn encodeObject(
    fields: []const Field,
    encoder: *definition_core.cache.Encoder,
    tasks: *[max_nodes * 2 + 1]EncodeTask,
    task_count: *usize,
) !void {
    try encoder.writeByte(3);
    try encoder.writeCount(fields.len);
    var index = fields.len;
    while (index > 0) {
        index -= 1;
        try pushEncodeTask(
            tasks,
            task_count,
            .{ .value = fields[index].value },
        );
        try pushEncodeTask(
            tasks,
            task_count,
            .{ .bytes = fields[index].name },
        );
    }
}

fn encodeArray(
    items: []const Value,
    encoder: *definition_core.cache.Encoder,
    tasks: *[max_nodes * 2 + 1]EncodeTask,
    task_count: *usize,
) !void {
    try encoder.writeByte(4);
    try encoder.writeCount(items.len);
    var index = items.len;
    while (index > 0) {
        index -= 1;
        try pushEncodeTask(tasks, task_count, .{ .value = items[index] });
    }
}

fn encodeChoice(
    choice: Choice,
    encoder: *definition_core.cache.Encoder,
    tasks: *[max_nodes * 2 + 1]EncodeTask,
    task_count: *usize,
) !void {
    try encoder.writeByte(5);
    try encoder.writeBytes(choice.pointer.raw);
    try encoder.writeCount(choice.cases.len);
    try pushEncodeTask(tasks, task_count, .{ .value = choice.fallback.* });
    var index = choice.cases.len;
    while (index > 0) {
        index -= 1;
        try pushEncodeTask(
            tasks,
            task_count,
            .{ .value = choice.cases[index].value },
        );
        try pushEncodeTask(
            tasks,
            task_count,
            .{ .bytes = choice.cases[index].equals },
        );
    }
}

const DecodeState = struct {
    nodes: usize = 0,
    max_output_bytes: usize,

    fn enter(self: *DecodeState, depth: usize) !void {
        if (depth > max_depth) {
            return error.CacheProjectionValueDepthExceeded;
        }
        self.nodes = std.math.add(usize, self.nodes, 1) catch
            return error.CacheProjectionValueNodesExceeded;
        if (self.nodes > max_nodes) {
            return error.CacheProjectionValueNodesExceeded;
        }
    }
};

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    max_output_bytes: usize,
) !Value {
    var state: DecodeState = .{ .max_output_bytes = max_output_bytes };
    var result: Value = .pending;
    errdefer result.deinit(allocator);
    var tasks: [max_nodes * 2 + 1]DecodeTask = undefined;
    var task_count: usize = 0;
    try pushDecodeTask(
        &tasks,
        &task_count,
        .{ .value = .{ .target = &result, .depth = 0 } },
    );
    while (task_count > 0) {
        task_count -= 1;
        switch (tasks[task_count]) {
            .value => |task| {
                try state.enter(task.depth);
                try decodeOne(
                    allocator,
                    decoder,
                    &state,
                    task,
                    &tasks,
                    &task_count,
                );
            },
            .object_field => |task| try decodeObjectField(
                allocator,
                decoder,
                task,
                &tasks,
                &task_count,
            ),
            .choice_case => |task| try decodeChoiceCase(
                allocator,
                decoder,
                &state,
                task,
                &tasks,
                &task_count,
            ),
        }
    }
    return result;
}

const DecodeValueTask = struct {
    target: *Value,
    depth: usize,
};

const DecodeObjectFieldTask = struct {
    fields: []Field,
    index: usize,
    depth: usize,
};

const DecodeChoiceCaseTask = struct {
    cases: []ChoiceCase,
    index: usize,
    depth: usize,
};

const DecodeTask = union(enum) {
    value: DecodeValueTask,
    object_field: DecodeObjectFieldTask,
    choice_case: DecodeChoiceCaseTask,
};

fn pushDecodeTask(
    tasks: *[max_nodes * 2 + 1]DecodeTask,
    count: *usize,
    task: DecodeTask,
) !void {
    if (count.* == tasks.len) {
        return error.CacheProjectionValueNodesExceeded;
    }
    tasks[count.*] = task;
    count.* += 1;
}

fn decodeOne(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    state: *DecodeState,
    task: DecodeValueTask,
    tasks: *[max_nodes * 2 + 1]DecodeTask,
    task_count: *usize,
) !void {
    switch (try decoder.readByte()) {
        0 => try decodeLiteral(allocator, decoder, state, task.target),
        1 => try decodePointer(allocator, decoder, state, task.target),
        2 => try decodeConcat(
            allocator,
            decoder,
            state,
            task.depth,
            task.target,
        ),
        3 => try decodeObject(allocator, decoder, task, tasks, task_count),
        4 => try decodeArray(allocator, decoder, task, tasks, task_count),
        5 => try decodeChoice(allocator, decoder, task, tasks, task_count),
        else => return error.CacheProjectionValueTagInvalid,
    }
}

fn decodeLiteral(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    state: *const DecodeState,
    target: *Value,
) !void {
    const bytes = try decoder.readBytesAlloc(
        allocator,
        state.max_output_bytes,
    );
    errdefer allocator.free(bytes);
    try validateCanonicalJson(allocator, bytes);
    target.* = .{ .literal = bytes };
}

fn decodePointer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    state: *const DecodeState,
    target: *Value,
) !void {
    const raw = try decoder.readBytesAlloc(allocator, max_pointer_bytes);
    defer allocator.free(raw);
    var pointer = try definition_core.json_pointer.compile(allocator, raw);
    errdefer pointer.deinit(allocator);
    const fallback_raw = try decoder.readOptionalBytesAlloc(
        allocator,
        max_pointer_bytes,
    );
    defer if (fallback_raw) |bytes| allocator.free(bytes);
    var fallback_pointer = if (fallback_raw) |bytes|
        try definition_core.json_pointer.compile(allocator, bytes)
    else
        null;
    errdefer if (fallback_pointer) |*compiled| compiled.deinit(allocator);
    const fallback = try decoder.readOptionalBytesAlloc(
        allocator,
        state.max_output_bytes,
    );
    errdefer if (fallback) |bytes| allocator.free(bytes);
    if (fallback) |bytes| try validateCanonicalJson(allocator, bytes);
    target.* = .{ .pointer = .{
        .pointer = pointer,
        .fallback_pointer = fallback_pointer,
        .fallback = fallback,
    } };
}

fn decodeConcat(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    state: *DecodeState,
    depth: usize,
    target: *Value,
) !void {
    const max_bytes = try decoder.readUsize();
    if (max_bytes == 0 or max_bytes > state.max_output_bytes) {
        return error.CacheProjectionValueConcatBoundsInvalid;
    }
    const count = try decoder.readCount(max_collection_items);
    if (count == 0) return error.CacheProjectionValueFragmentsInvalid;
    const fragments = try allocator.alloc(Fragment, count);
    var initialized: usize = 0;
    errdefer {
        for (fragments[0..initialized]) |*fragment| fragment.deinit(allocator);
        allocator.free(fragments);
    }
    for (fragments) |*fragment| {
        try state.enter(depth + 1);
        fragment.* = try decodeFragment(allocator, decoder, max_bytes);
        initialized += 1;
    }
    target.* = .{ .concat = .{
        .fragments = fragments,
        .max_bytes = max_bytes,
    } };
}

fn decodeFragment(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    max_bytes: usize,
) !Fragment {
    const fragment: Fragment = switch (try decoder.readByte()) {
        0 => .{ .literal = try decoder.readBytesAlloc(allocator, max_bytes) },
        1 => compiled: {
            const raw = try decoder.readBytesAlloc(
                allocator,
                max_pointer_bytes,
            );
            defer allocator.free(raw);
            break :compiled .{
                .pointer = try definition_core.json_pointer.compile(
                    allocator,
                    raw,
                ),
            };
        },
        else => return error.CacheProjectionValueFragmentInvalid,
    };
    errdefer {
        var owned = fragment;
        owned.deinit(allocator);
    }
    if (fragment == .literal and
        !std.unicode.utf8ValidateSlice(fragment.literal))
    {
        return error.CacheProjectionValueFragmentInvalid;
    }
    if (fragment == .literal and fragment.literal.len > max_bytes) {
        return error.CacheProjectionValueConcatBoundsInvalid;
    }
    return fragment;
}

fn decodeObject(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    task: DecodeValueTask,
    tasks: *[max_nodes * 2 + 1]DecodeTask,
    task_count: *usize,
) !void {
    const count = try decoder.readCount(max_collection_items);
    if (count == 0) return error.CacheProjectionValueFieldsInvalid;
    const fields = try allocator.alloc(Field, count);
    for (fields) |*field| field.* = .{ .name = &.{}, .value = .pending };
    errdefer {
        for (fields) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    var index = fields.len;
    while (index > 0) {
        index -= 1;
        try pushDecodeTask(tasks, task_count, .{
            .object_field = .{
                .fields = fields,
                .index = index,
                .depth = task.depth + 1,
            },
        });
    }
    task.target.* = .{ .object = fields };
}

fn decodeObjectField(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    task: DecodeObjectFieldTask,
    tasks: *[max_nodes * 2 + 1]DecodeTask,
    task_count: *usize,
) !void {
    const name = try decoder.readBytesAlloc(allocator, max_field_name_bytes);
    errdefer allocator.free(name);
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) {
        return error.CacheProjectionValueFieldNameInvalid;
    }
    for (task.fields[0..task.index]) |prior| {
        if (std.mem.eql(u8, prior.name, name)) {
            return error.CacheProjectionValueFieldsNotUnique;
        }
    }
    task.fields[task.index].name = name;
    try pushDecodeTask(tasks, task_count, .{
        .value = .{
            .target = &task.fields[task.index].value,
            .depth = task.depth,
        },
    });
}

fn decodeArray(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    task: DecodeValueTask,
    tasks: *[max_nodes * 2 + 1]DecodeTask,
    task_count: *usize,
) !void {
    const count = try decoder.readCount(max_collection_items);
    const items = try allocator.alloc(Value, count);
    for (items) |*item| item.* = .pending;
    errdefer {
        for (items) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    var index = items.len;
    while (index > 0) {
        index -= 1;
        try pushDecodeTask(tasks, task_count, .{
            .value = .{
                .target = &items[index],
                .depth = task.depth + 1,
            },
        });
    }
    task.target.* = .{ .array = items };
}

fn decodeChoice(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    task: DecodeValueTask,
    tasks: *[max_nodes * 2 + 1]DecodeTask,
    task_count: *usize,
) !void {
    const raw = try decoder.readBytesAlloc(allocator, max_pointer_bytes);
    defer allocator.free(raw);
    var pointer = try definition_core.json_pointer.compile(allocator, raw);
    errdefer pointer.deinit(allocator);
    const count = try decoder.readCount(max_collection_items);
    if (count == 0) return error.CacheProjectionValueChoiceCasesInvalid;
    const cases = try allocator.alloc(ChoiceCase, count);
    for (cases) |*case| case.* = .{ .equals = &.{}, .value = .pending };
    errdefer {
        for (cases) |*case| case.deinit(allocator);
        allocator.free(cases);
    }
    const fallback = try allocator.create(Value);
    errdefer allocator.destroy(fallback);
    fallback.* = .pending;
    errdefer fallback.deinit(allocator);
    try pushDecodeTask(tasks, task_count, .{
        .value = .{ .target = fallback, .depth = task.depth + 1 },
    });
    var index = cases.len;
    while (index > 0) {
        index -= 1;
        try pushDecodeTask(tasks, task_count, .{
            .choice_case = .{
                .cases = cases,
                .index = index,
                .depth = task.depth + 1,
            },
        });
    }
    task.target.* = .{ .choice = .{
        .pointer = pointer,
        .cases = cases,
        .fallback = fallback,
    } };
}

fn decodeChoiceCase(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    state: *const DecodeState,
    task: DecodeChoiceCaseTask,
    tasks: *[max_nodes * 2 + 1]DecodeTask,
    task_count: *usize,
) !void {
    const equals = try decoder.readBytesAlloc(
        allocator,
        state.max_output_bytes,
    );
    errdefer allocator.free(equals);
    try validateCanonicalJson(allocator, equals);
    for (task.cases[0..task.index]) |prior| {
        if (std.mem.eql(u8, prior.equals, equals)) {
            return error.CacheProjectionValueChoiceCasesNotUnique;
        }
    }
    task.cases[task.index].equals = equals;
    try pushDecodeTask(tasks, task_count, .{
        .value = .{
            .target = &task.cases[task.index].value,
            .depth = task.depth,
        },
    });
}

fn validateCanonicalJson(
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
    const canonical =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            parsed.value,
        );
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) {
        return error.CacheProjectionValueLiteralNotCanonical;
    }
}

pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    plan: Value,
    source: std.json.Value,
) !void {
    var tasks: [max_nodes * 4 + 16]WriteTask = undefined;
    var task_count: usize = 0;
    try pushWriteTask(&tasks, &task_count, .{ .value = plan });
    var nodes: usize = 0;
    while (task_count > 0) {
        task_count -= 1;
        switch (tasks[task_count]) {
            .byte => |byte| try writer.writeByte(byte),
            .canonical_string => |text| {
                try definition_core.canonical_json.writeCanonicalString(
                    writer,
                    text,
                );
            },
            .value => |value| {
                nodes += 1;
                if (nodes > max_nodes) {
                    return error.ProjectionValueNodesExceeded;
                }
                try writeOne(
                    allocator,
                    writer,
                    value,
                    source,
                    &tasks,
                    &task_count,
                );
            },
        }
    }
}

const WriteTask = union(enum) {
    value: Value,
    byte: u8,
    canonical_string: []const u8,
};

fn pushWriteTask(
    tasks: *[max_nodes * 4 + 16]WriteTask,
    count: *usize,
    task: WriteTask,
) !void {
    if (count.* == tasks.len) return error.ProjectionValueNodesExceeded;
    tasks[count.*] = task;
    count.* += 1;
}

fn writeOne(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    plan: Value,
    source: std.json.Value,
    tasks: *[max_nodes * 4 + 16]WriteTask,
    task_count: *usize,
) !void {
    switch (plan) {
        .literal => |bytes| try writer.writeAll(bytes),
        .pointer => |pointer| try writePointer(
            allocator,
            writer,
            pointer,
            source,
        ),
        .concat => |concat| try writeConcat(allocator, writer, concat, source),
        .object => |fields| try scheduleObject(
            writer,
            fields,
            tasks,
            task_count,
        ),
        .array => |items| try scheduleArray(writer, items, tasks, task_count),
        .choice => |choice| try scheduleChoice(
            allocator,
            choice,
            source,
            tasks,
            task_count,
        ),
        .pending => return error.ProjectionValuePending,
    }
}

fn writePointer(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    pointer: Pointer,
    source: std.json.Value,
) !void {
    if (definition_core.json_pointer.lookup(
        source,
        pointer.pointer,
    )) |selected| {
        return definition_core.canonical_json.writeCanonicalJson(
            allocator,
            writer,
            selected,
        );
    }
    if (pointer.fallback_pointer) |fallback_pointer| {
        if (definition_core.json_pointer.lookup(
            source,
            fallback_pointer,
        )) |selected| {
            return definition_core.canonical_json.writeCanonicalJson(
                allocator,
                writer,
                selected,
            );
        }
    }
    if (pointer.fallback) |fallback| return writer.writeAll(fallback);
    return error.ProjectionValuePathMissing;
}

fn writeConcat(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    concat: Concat,
    source: std.json.Value,
) !void {
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (concat.fragments) |fragment| {
        switch (fragment) {
            .literal => |literal| try text.writer.writeAll(literal),
            .pointer => |pointer| {
                const selected = definition_core.json_pointer.lookup(
                    source,
                    pointer,
                ) orelse return error.ProjectionValuePathMissing;
                try text.writer.writeAll(
                    try definition_core.json.string(selected),
                );
            },
        }
        if (text.written().len > concat.max_bytes) {
            return error.ProjectionValueConcatBoundsExceeded;
        }
    }
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        text.written(),
    );
}

fn scheduleObject(
    writer: *std.Io.Writer,
    fields: []const Field,
    tasks: *[max_nodes * 4 + 16]WriteTask,
    task_count: *usize,
) !void {
    try writer.writeByte('{');
    try pushWriteTask(tasks, task_count, .{ .byte = '}' });
    var index = fields.len;
    while (index > 0) {
        index -= 1;
        try pushWriteTask(tasks, task_count, .{
            .value = fields[index].value,
        });
        try pushWriteTask(tasks, task_count, .{ .byte = ':' });
        try pushWriteTask(tasks, task_count, .{
            .canonical_string = fields[index].name,
        });
        if (index != 0) {
            try pushWriteTask(tasks, task_count, .{ .byte = ',' });
        }
    }
}

fn scheduleArray(
    writer: *std.Io.Writer,
    items: []const Value,
    tasks: *[max_nodes * 4 + 16]WriteTask,
    task_count: *usize,
) !void {
    try writer.writeByte('[');
    try pushWriteTask(tasks, task_count, .{ .byte = ']' });
    var index = items.len;
    while (index > 0) {
        index -= 1;
        try pushWriteTask(tasks, task_count, .{ .value = items[index] });
        if (index != 0) {
            try pushWriteTask(tasks, task_count, .{ .byte = ',' });
        }
    }
}

fn scheduleChoice(
    allocator: std.mem.Allocator,
    choice: Choice,
    source: std.json.Value,
    tasks: *[max_nodes * 4 + 16]WriteTask,
    task_count: *usize,
) !void {
    const selected = definition_core.json_pointer.lookup(
        source,
        choice.pointer,
    ) orelse return error.ProjectionValuePathMissing;
    const canonical =
        try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            selected,
        );
    defer allocator.free(canonical);
    for (choice.cases) |case| {
        if (!std.mem.eql(u8, case.equals, canonical)) continue;
        return pushWriteTask(tasks, task_count, .{ .value = case.value });
    }
    try pushWriteTask(tasks, task_count, .{ .value = choice.fallback.* });
}

test "bounded projection value compiles caches and writes one document" {
    const source_text =
        \\{"record":{"id":"lrn-1","repo":"owner/repo","related_ids":[]}}
    ;
    var source = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        source_text,
        .{},
    );
    defer source.deinit();
    const definition_text =
        \\{"object":[
        \\  {"name":"operation","value":{"literal":"assert"}},
        \\  {"name":"summary","value":{"concat":[
        \\    {"literal":"Admit "},{"path":"/record/id"},{"literal":"."}
        \\  ],"max_bytes":128}},
        \\  {"name":"scope","value":{"object":[
        \\    {"name":"repo","value":{"path":"/record/repo"}},
        \\    {"name":"paths","value":{"path":"/record/paths","default":[]}}
        \\  ]}},
        \\  {"name":"related_ids","value":{"path":"/record/related_ids"}}
        \\]}
    ;
    var definition = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        definition_text,
        .{},
    );
    defer definition.deinit();
    var plan = try compile(
        std.testing.allocator,
        definition.value,
        4096,
    );
    defer plan.deinit(std.testing.allocator);

    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        16 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(
        std.testing.allocator,
        &decoder,
        4096,
    );
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try write(
        std.testing.allocator,
        &output.writer,
        cached,
        source.value,
    );
    try std.testing.expectEqualStrings(
        "{\"operation\":\"assert\",\"summary\":\"Admit lrn-1.\"," ++
            "\"scope\":{\"repo\":\"owner/repo\",\"paths\":[]}," ++
            "\"related_ids\":[]}",
        output.written(),
    );
}

test "projection value fails closed on missing data and declared bounds" {
    var bounded_definition = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"concat":[{"literal":"too long"}],"max_bytes":3}
    ,
        .{},
    );
    defer bounded_definition.deinit();
    try std.testing.expectError(
        error.ProjectionValueConcatBoundsExceeded,
        compile(std.testing.allocator, bounded_definition.value, 4096),
    );

    var empty_field_definition = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"object":[{"name":"","value":{"literal":null}}]}
    ,
        .{},
    );
    defer empty_field_definition.deinit();
    try std.testing.expectError(
        error.InvalidString,
        compile(std.testing.allocator, empty_field_definition.value, 4096),
    );

    var missing_path_definition = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"path":"/missing"}
    ,
        .{},
    );
    defer missing_path_definition.deinit();
    var missing_path_plan = try compile(
        std.testing.allocator,
        missing_path_definition.value,
        4096,
    );
    defer missing_path_plan.deinit(std.testing.allocator);
    var empty_source = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{}",
        .{},
    );
    defer empty_source.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(
        error.ProjectionValuePathMissing,
        write(
            std.testing.allocator,
            &output.writer,
            missing_path_plan,
            empty_source.value,
        ),
    );
}
