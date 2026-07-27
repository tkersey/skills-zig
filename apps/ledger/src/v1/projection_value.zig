const std = @import("std");
const definition_core = @import("definition_core");

const max_depth: usize = 8;
const max_nodes: usize = 256;
const max_collection_items: usize = 64;
const max_pointer_bytes: usize = 1024;
const max_field_name_bytes: usize = 128;

const Pointer = struct {
    pointer: definition_core.json_pointer.Pointer,
    fallback: ?[]u8,

    fn deinit(self: *Pointer, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
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

const Field = struct {
    name: []u8,
    value: Value,

    fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
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
    return compileValue(allocator, source, &state, 0);
}

fn compileValue(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    state: *CompileState,
    depth: usize,
) !Value {
    try state.enter(depth);
    const object = try definition_core.json.object(source);
    const has_literal = object.contains("literal");
    const has_path = object.contains("path");
    const has_concat = object.contains("concat");
    const has_object = object.contains("object");
    const has_array = object.contains("array");
    const source_count =
        @as(usize, @intFromBool(has_literal)) +
        @as(usize, @intFromBool(has_path)) +
        @as(usize, @intFromBool(has_concat)) +
        @as(usize, @intFromBool(has_object)) +
        @as(usize, @intFromBool(has_array));
    if (source_count != 1) return error.InvalidProjectionValueSource;

    if (has_literal) {
        try definition_core.json.requireExactKeys(object, &.{"literal"});
        const bytes = try definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            object.get("literal").?,
        );
        errdefer allocator.free(bytes);
        if (bytes.len > state.max_output_bytes) {
            return error.ProjectionValueLiteralBoundsExceeded;
        }
        return .{ .literal = bytes };
    }
    if (has_path) {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "default", "path" },
        );
        const raw_pointer = try definition_core.json.string(
            object.get("path").?,
        );
        if (raw_pointer.len > max_pointer_bytes) {
            return error.ProjectionValuePointerBoundsExceeded;
        }
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            raw_pointer,
        );
        errdefer pointer.deinit(allocator);
        const fallback = if (object.get("default")) |value|
            try definition_core.canonical_json.canonicalJsonAlloc(
                allocator,
                value,
            )
        else
            null;
        errdefer if (fallback) |bytes| allocator.free(bytes);
        if (fallback) |bytes| {
            if (bytes.len > state.max_output_bytes) {
                return error.ProjectionValueLiteralBoundsExceeded;
            }
        }
        return .{ .pointer = .{
            .pointer = pointer,
            .fallback = fallback,
        } };
    }
    if (has_concat) {
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
        const raw_fragments = try definition_core.json.array(
            object.get("concat").?,
        );
        if (raw_fragments.items.len == 0 or
            raw_fragments.items.len > max_collection_items)
        {
            return error.ProjectionValueFragmentsInvalid;
        }
        const fragments = try allocator.alloc(
            Fragment,
            raw_fragments.items.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (fragments[0..initialized]) |*fragment| {
                fragment.deinit(allocator);
            }
            allocator.free(fragments);
        }
        for (raw_fragments.items) |raw_fragment| {
            try state.enter(depth + 1);
            const fragment = try definition_core.json.object(raw_fragment);
            const literal = fragment.get("literal");
            const path = fragment.get("path");
            if ((literal == null) == (path == null)) {
                return error.InvalidProjectionValueFragment;
            }
            if (literal) |value| {
                try definition_core.json.requireExactKeys(
                    fragment,
                    &.{"literal"},
                );
                const text = try definition_core.json.string(value);
                if (!std.unicode.utf8ValidateSlice(text)) {
                    return error.InvalidProjectionValueFragment;
                }
                if (text.len > max_bytes) {
                    return error.ProjectionValueConcatBoundsExceeded;
                }
                fragments[initialized] = .{
                    .literal = try allocator.dupe(u8, text),
                };
            } else {
                try definition_core.json.requireExactKeys(
                    fragment,
                    &.{"path"},
                );
                const raw_pointer = try definition_core.json.string(path.?);
                if (raw_pointer.len > max_pointer_bytes) {
                    return error.ProjectionValuePointerBoundsExceeded;
                }
                fragments[initialized] = .{
                    .pointer = try definition_core.json_pointer.compile(
                        allocator,
                        raw_pointer,
                    ),
                };
            }
            initialized += 1;
        }
        return .{ .concat = .{
            .fragments = fragments,
            .max_bytes = max_bytes,
        } };
    }
    if (has_object) {
        try definition_core.json.requireExactKeys(object, &.{"object"});
        const raw_fields = try definition_core.json.array(
            object.get("object").?,
        );
        if (raw_fields.items.len == 0 or
            raw_fields.items.len > max_collection_items)
        {
            return error.ProjectionValueFieldsInvalid;
        }
        const fields = try allocator.alloc(Field, raw_fields.items.len);
        var initialized: usize = 0;
        errdefer {
            for (fields[0..initialized]) |*field| field.deinit(allocator);
            allocator.free(fields);
        }
        for (raw_fields.items) |raw_field| {
            const field = try definition_core.json.object(raw_field);
            try definition_core.json.requireExactKeys(
                field,
                &.{ "name", "value" },
            );
            try definition_core.json.requireFields(
                field,
                &.{ "name", "value" },
            );
            const name = try definition_core.json.requiredString(
                field,
                "name",
            );
            if (name.len == 0 or name.len > max_field_name_bytes) {
                return error.ProjectionValueFieldNameInvalid;
            }
            for (fields[0..initialized]) |prior| {
                if (std.mem.eql(u8, prior.name, name)) {
                    return error.ProjectionValueFieldsNotUnique;
                }
            }
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            var compiled_value = try compileValue(
                allocator,
                try definition_core.json.field(field, "value"),
                state,
                depth + 1,
            );
            errdefer compiled_value.deinit(allocator);
            fields[initialized] = .{
                .name = owned_name,
                .value = compiled_value,
            };
            initialized += 1;
        }
        return .{ .object = fields };
    }

    try definition_core.json.requireExactKeys(object, &.{"array"});
    const raw_items = try definition_core.json.array(object.get("array").?);
    if (raw_items.items.len > max_collection_items) {
        return error.ProjectionValueItemsInvalid;
    }
    const items = try allocator.alloc(Value, raw_items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (raw_items.items) |raw_item| {
        items[initialized] = try compileValue(
            allocator,
            raw_item,
            state,
            depth + 1,
        );
        initialized += 1;
    }
    return .{ .array = items };
}

pub fn encodeCache(
    value: Value,
    encoder: *definition_core.cache.Encoder,
) !void {
    switch (value) {
        .literal => |bytes| {
            try encoder.writeByte(0);
            try encoder.writeBytes(bytes);
        },
        .pointer => |pointer| {
            try encoder.writeByte(1);
            try encoder.writeBytes(pointer.pointer.raw);
            try encoder.writeOptionalBytes(pointer.fallback);
        },
        .concat => |concat| {
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
        },
        .object => |fields| {
            try encoder.writeByte(3);
            try encoder.writeCount(fields.len);
            for (fields) |field| {
                try encoder.writeBytes(field.name);
                try encodeCache(field.value, encoder);
            }
        },
        .array => |items| {
            try encoder.writeByte(4);
            try encoder.writeCount(items.len);
            for (items) |item| try encodeCache(item, encoder);
        },
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
    return decodeValue(allocator, decoder, &state, 0);
}

fn decodeValue(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    state: *DecodeState,
    depth: usize,
) !Value {
    try state.enter(depth);
    return switch (try decoder.readByte()) {
        0 => literal: {
            const bytes = try decoder.readBytesAlloc(
                allocator,
                state.max_output_bytes,
            );
            errdefer allocator.free(bytes);
            try validateCanonicalJson(allocator, bytes);
            break :literal .{ .literal = bytes };
        },
        1 => pointer: {
            const raw = try decoder.readBytesAlloc(
                allocator,
                max_pointer_bytes,
            );
            defer allocator.free(raw);
            var compiled = try definition_core.json_pointer.compile(
                allocator,
                raw,
            );
            errdefer compiled.deinit(allocator);
            const fallback = try decoder.readOptionalBytesAlloc(
                allocator,
                state.max_output_bytes,
            );
            errdefer if (fallback) |bytes| allocator.free(bytes);
            if (fallback) |bytes| try validateCanonicalJson(allocator, bytes);
            break :pointer .{ .pointer = .{
                .pointer = compiled,
                .fallback = fallback,
            } };
        },
        2 => concat: {
            const max_bytes = try decoder.readUsize();
            if (max_bytes == 0 or max_bytes > state.max_output_bytes) {
                return error.CacheProjectionValueConcatBoundsInvalid;
            }
            const count = try decoder.readCount(max_collection_items);
            if (count == 0) {
                return error.CacheProjectionValueFragmentsInvalid;
            }
            const fragments = try allocator.alloc(Fragment, count);
            var initialized: usize = 0;
            errdefer {
                for (fragments[0..initialized]) |*fragment| {
                    fragment.deinit(allocator);
                }
                allocator.free(fragments);
            }
            for (fragments) |*fragment| {
                try state.enter(depth + 1);
                fragment.* = switch (try decoder.readByte()) {
                    0 => .{ .literal = try decoder.readBytesAlloc(
                        allocator,
                        max_bytes,
                    ) },
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
                initialized += 1;
                if (fragment.* == .literal and
                    !std.unicode.utf8ValidateSlice(fragment.literal))
                {
                    return error.CacheProjectionValueFragmentInvalid;
                }
                if (fragment.* == .literal and
                    fragment.literal.len > max_bytes)
                {
                    return error.CacheProjectionValueConcatBoundsInvalid;
                }
            }
            break :concat .{ .concat = .{
                .fragments = fragments,
                .max_bytes = max_bytes,
            } };
        },
        3 => object: {
            const count = try decoder.readCount(max_collection_items);
            if (count == 0) return error.CacheProjectionValueFieldsInvalid;
            const fields = try allocator.alloc(Field, count);
            var initialized: usize = 0;
            errdefer {
                for (fields[0..initialized]) |*field| {
                    field.deinit(allocator);
                }
                allocator.free(fields);
            }
            for (fields) |*field| {
                const name = try decoder.readBytesAlloc(
                    allocator,
                    max_field_name_bytes,
                );
                errdefer allocator.free(name);
                if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) {
                    return error.CacheProjectionValueFieldNameInvalid;
                }
                for (fields[0..initialized]) |prior| {
                    if (std.mem.eql(u8, prior.name, name)) {
                        return error.CacheProjectionValueFieldsNotUnique;
                    }
                }
                field.* = .{
                    .name = name,
                    .value = try decodeValue(
                        allocator,
                        decoder,
                        state,
                        depth + 1,
                    ),
                };
                initialized += 1;
            }
            break :object .{ .object = fields };
        },
        4 => array: {
            const count = try decoder.readCount(max_collection_items);
            const items = try allocator.alloc(Value, count);
            var initialized: usize = 0;
            errdefer {
                for (items[0..initialized]) |*item| item.deinit(allocator);
                allocator.free(items);
            }
            for (items) |*item| {
                item.* = try decodeValue(
                    allocator,
                    decoder,
                    state,
                    depth + 1,
                );
                initialized += 1;
            }
            break :array .{ .array = items };
        },
        else => error.CacheProjectionValueTagInvalid,
    };
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
    switch (plan) {
        .literal => |bytes| try writer.writeAll(bytes),
        .pointer => |pointer| {
            if (definition_core.json_pointer.lookup(
                source,
                pointer.pointer,
            )) |selected| {
                try definition_core.canonical_json.writeCanonicalJson(
                    allocator,
                    writer,
                    selected,
                );
            } else if (pointer.fallback) |fallback| {
                try writer.writeAll(fallback);
            } else {
                return error.ProjectionValuePathMissing;
            }
        },
        .concat => |concat| {
            var text: std.Io.Writer.Allocating = .init(allocator);
            defer text.deinit();
            for (concat.fragments) |fragment| {
                switch (fragment) {
                    .literal => |literal| {
                        try text.writer.writeAll(literal);
                    },
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
        },
        .object => |fields| {
            try writer.writeByte('{');
            for (fields, 0..) |field, index| {
                if (index != 0) try writer.writeByte(',');
                try definition_core.canonical_json.writeCanonicalString(
                    writer,
                    field.name,
                );
                try writer.writeByte(':');
                try write(allocator, writer, field.value, source);
            }
            try writer.writeByte('}');
        },
        .array => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try write(allocator, writer, item, source);
            }
            try writer.writeByte(']');
        },
    }
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
