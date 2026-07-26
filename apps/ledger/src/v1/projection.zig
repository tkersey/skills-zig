const std = @import("std");
const definition_core = @import("definition_core");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const replay = @import("replay.zig");
const storage = @import("storage.zig");

const Scalar = union(enum) {
    string: []u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null,

    fn deinit(self: *Scalar, allocator: std.mem.Allocator) void {
        if (self.* == .string) allocator.free(self.string);
        self.* = undefined;
    }
};

const Operand = union(enum) {
    constant: Scalar,
    parameter: []u8,

    fn deinit(self: *Operand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .constant => |*value| value.deinit(allocator),
            .parameter => |name| allocator.free(name),
        }
        self.* = undefined;
    }
};

const Predicate = struct {
    pointer: definition_core.json_pointer.Pointer,
    operand: Operand,

    fn deinit(self: *Predicate, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        self.operand.deinit(allocator);
        self.* = undefined;
    }
};

const Field = struct {
    name: []u8,
    pointer: definition_core.json_pointer.Pointer,

    fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

const Limit = union(enum) {
    fixed: usize,
    parameter: []u8,

    fn deinit(self: *Limit, allocator: std.mem.Allocator) void {
        if (self.* == .parameter) allocator.free(self.parameter);
        self.* = undefined;
    }
};

pub const Projection = struct {
    name: []u8,
    slot_index: u16,
    predicates: []Predicate,
    fields: []Field,
    latest: ?definition_core.json_pointer.Pointer,
    limit: ?Limit,

    fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.predicates) |*predicate| predicate.deinit(allocator);
        allocator.free(self.predicates);
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        if (self.latest) |*pointer| pointer.deinit(allocator);
        if (self.limit) |*limit| limit.deinit(allocator);
        self.* = undefined;
    }
};

pub const Plan = struct {
    projections: []Projection,
    max_records: usize,
    max_output_bytes: usize,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.projections) |*projection| projection.deinit(allocator);
        allocator.free(self.projections);
        self.* = undefined;
    }

    pub fn find(self: *const Plan, name: []const u8) ?*const Projection {
        var low: usize = 0;
        var high = self.projections.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.projections[mid].name, name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return &self.projections[mid],
            }
        }
        return null;
    }
};

pub const Stats = struct {
    records_scanned: usize,
    records_matched: usize,
    records_emitted: usize,
};

pub const Result = struct {
    definition_id: []u8,
    definition_digest: [71]u8,
    projection: []u8,
    logical_ref: []u8,
    revision: []u8,
    payload: []u8,
    stats: Stats,
    limitations: [][]u8,
    authority_granted: bool = false,
    storage_mutated: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.definition_id);
        allocator.free(self.projection);
        allocator.free(self.logical_ref);
        allocator.free(self.revision);
        allocator.free(self.payload);
        for (self.limitations) |limitation| allocator.free(limitation);
        allocator.free(self.limitations);
        self.* = undefined;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
) !Plan {
    var projections: std.ArrayList(Projection) = .empty;
    errdefer {
        for (projections.items) |*projection| projection.deinit(allocator);
        projections.deinit(allocator);
    }
    for (definition_plan.projections) |source| {
        var compiled = try compileProjection(
            allocator,
            definition_plan,
            storage_plan,
            source,
        );
        errdefer compiled.deinit(allocator);
        try projections.append(allocator, compiled);
    }
    return .{
        .projections = try projections.toOwnedSlice(allocator),
        .max_records = definition_plan.bounds.max_records,
        .max_output_bytes = definition_plan.bounds.max_output_bytes,
    };
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(1);
    try encoder.writeCount(plan.projections.len);
    for (plan.projections) |projection| {
        try encoder.writeBytes(projection.name);
        try encoder.writeU16(projection.slot_index);
        try encoder.writeCount(projection.predicates.len);
        for (projection.predicates) |predicate| {
            try encoder.writeBytes(predicate.pointer.raw);
            switch (predicate.operand) {
                .constant => |value| {
                    try encoder.writeByte(0);
                    try encodeCacheScalar(encoder, value);
                },
                .parameter => |name| {
                    try encoder.writeByte(1);
                    try encoder.writeBytes(name);
                },
            }
        }
        try encoder.writeCount(projection.fields.len);
        for (projection.fields) |field| {
            try encoder.writeBytes(field.name);
            try encoder.writeBytes(field.pointer.raw);
        }
        try encoder.writeBool(projection.latest != null);
        if (projection.latest) |pointer| try encoder.writeBytes(pointer.raw);
        if (projection.limit) |limit| {
            switch (limit) {
                .fixed => |count| {
                    try encoder.writeByte(1);
                    try encoder.writeUsize(count);
                },
                .parameter => |name| {
                    try encoder.writeByte(2);
                    try encoder.writeBytes(name);
                },
            }
        } else {
            try encoder.writeByte(0);
        }
    }
    try encoder.writeUsize(plan.max_records);
    try encoder.writeUsize(plan.max_output_bytes);
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 1) {
        return error.LedgerProjectionCacheVersionMismatch;
    }
    const count = try decoder.readCount(128);
    const projections = try allocator.alloc(Projection, count);
    var initialized: usize = 0;
    errdefer {
        for (projections[0..initialized]) |*projection| {
            projection.deinit(allocator);
        }
        allocator.free(projections);
    }
    for (projections, 0..) |*projection, index| {
        projection.* = try decodeCacheProjection(allocator, decoder);
        initialized += 1;
        if (index != 0 and std.mem.order(
            u8,
            projections[index - 1].name,
            projection.name,
        ) != .lt) return error.CacheProjectionsNotSorted;
    }
    const max_records = try decoder.readUsize();
    const max_output_bytes = try decoder.readUsize();
    if (max_records == 0 or max_records > 10_000_000 or
        max_output_bytes == 0 or max_output_bytes > 256 * 1024 * 1024)
    {
        return error.CacheProjectionBoundsInvalid;
    }
    for (projections) |projection| {
        if (projection.limit) |limit| switch (limit) {
            .fixed => |fixed| if (fixed == 0 or fixed > max_records) {
                return error.InvalidProjectionLimit;
            },
            .parameter => {},
        };
    }
    return .{
        .projections = projections,
        .max_records = max_records,
        .max_output_bytes = max_output_bytes,
    };
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
) !void {
    if (plan.max_records != definition_plan.bounds.max_records or
        plan.max_output_bytes != definition_plan.bounds.max_output_bytes)
    {
        return error.CacheProjectionPlanMismatch;
    }
    for (plan.projections) |projection| {
        if (projection.slot_index >= storage_plan.slots.len) {
            return error.CacheProjectionPlanMismatch;
        }
        for (projection.predicates) |predicate| {
            if (predicate.operand == .parameter and
                definition_plan.parameter_declarations.find(
                    predicate.operand.parameter,
                ) == null)
            {
                return error.CacheProjectionPlanMismatch;
            }
        }
        if (projection.limit) |limit| switch (limit) {
            .fixed => {},
            .parameter => |name| {
                const declaration =
                    definition_plan.parameter_declarations.find(name) orelse
                    return error.CacheProjectionPlanMismatch;
                if (declaration.kind != .integer) {
                    return error.CacheProjectionPlanMismatch;
                }
            },
        };
    }
}

fn decodeCacheProjection(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Projection {
    const name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    const slot_index = try decoder.readU16();
    const predicate_count = try decoder.readCount(64);
    const predicates = try allocator.alloc(Predicate, predicate_count);
    var predicate_initialized: usize = 0;
    errdefer {
        for (predicates[0..predicate_initialized]) |*predicate| {
            predicate.deinit(allocator);
        }
        allocator.free(predicates);
    }
    for (predicates) |*predicate| {
        const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw_pointer);
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            raw_pointer,
        );
        errdefer pointer.deinit(allocator);
        var operand: Operand = switch (try decoder.readByte()) {
            0 => .{ .constant = try decodeCacheScalar(allocator, decoder) },
            1 => .{ .parameter = try decoder.readBytesAlloc(
                allocator,
                128,
            ) },
            else => return error.CacheProjectionOperandInvalid,
        };
        errdefer operand.deinit(allocator);
        if (operand == .parameter) {
            try definition_core.json.safeIdentifier(operand.parameter, 128);
        }
        predicate.* = .{
            .pointer = pointer,
            .operand = operand,
        };
        predicate_initialized += 1;
    }
    const field_count = try decoder.readCount(256);
    const fields = try allocator.alloc(Field, field_count);
    var field_initialized: usize = 0;
    errdefer {
        for (fields[0..field_initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (fields, 0..) |*field, index| {
        const field_name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(field_name);
        try definition_core.json.safeIdentifier(field_name, 128);
        if (index != 0 and
            std.mem.order(u8, fields[index - 1].name, field_name) != .lt)
        {
            return error.CacheProjectionFieldsNotSorted;
        }
        const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw_pointer);
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            raw_pointer,
        );
        errdefer pointer.deinit(allocator);
        field.* = .{ .name = field_name, .pointer = pointer };
        field_initialized += 1;
    }
    var latest: ?definition_core.json_pointer.Pointer = null;
    errdefer if (latest) |*pointer| pointer.deinit(allocator);
    if (try decoder.readBool()) {
        const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw_pointer);
        latest = try definition_core.json_pointer.compile(
            allocator,
            raw_pointer,
        );
    }
    var limit: ?Limit = switch (try decoder.readByte()) {
        0 => null,
        1 => .{ .fixed = try decoder.readUsize() },
        2 => .{ .parameter = try decoder.readBytesAlloc(allocator, 128) },
        else => return error.CacheProjectionLimitInvalid,
    };
    errdefer if (limit) |*value| value.deinit(allocator);
    if (limit != null and limit.? == .parameter) {
        try definition_core.json.safeIdentifier(limit.?.parameter, 128);
    }
    return .{
        .name = name,
        .slot_index = slot_index,
        .predicates = predicates,
        .fields = fields,
        .latest = latest,
        .limit = limit,
    };
}

fn encodeCacheScalar(
    encoder: *definition_core.cache.Encoder,
    value: Scalar,
) !void {
    switch (value) {
        .string => |text| {
            try encoder.writeByte(0);
            try encoder.writeBytes(text);
        },
        .integer => |number| {
            try encoder.writeByte(1);
            try encoder.writeI64(number);
        },
        .float => |number| {
            try encoder.writeByte(2);
            try encoder.writeF64(number);
        },
        .boolean => |flag| {
            try encoder.writeByte(3);
            try encoder.writeBool(flag);
        },
        .null => try encoder.writeByte(4),
    }
}

fn decodeCacheScalar(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Scalar {
    return switch (try decoder.readByte()) {
        0 => .{ .string = try decoder.readBytesAlloc(
            allocator,
            4 * 1024 * 1024,
        ) },
        1 => .{ .integer = try decoder.readI64() },
        2 => blk: {
            const number = try decoder.readF64();
            if (!std.math.isFinite(number)) return error.CacheNumberInvalid;
            break :blk .{ .float = number };
        },
        3 => .{ .boolean = try decoder.readBool() },
        4 => .null,
        else => error.CacheProjectionScalarInvalid,
    };
}

fn compileProjection(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    source: definition.NamedPlan,
) !Projection {
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
    try definition_core.json.requireExactKeys(object, &.{ "slot", "pipeline" });
    try definition_core.json.requireFields(object, &.{ "slot", "pipeline" });
    const slot_index = storage_plan.findSlot(
        try definition_core.json.requiredString(object, "slot"),
    ) orelse return error.UnknownProjectionSlot;
    const steps = try definition_core.json.array(
        try definition_core.json.field(object, "pipeline"),
    );
    if (steps.items.len == 0 or steps.items.len > 64) {
        return error.InvalidProjectionPipeline;
    }
    var predicates: std.ArrayList(Predicate) = .empty;
    errdefer {
        for (predicates.items) |*predicate| predicate.deinit(allocator);
        predicates.deinit(allocator);
    }
    var fields: []Field = try allocator.alloc(Field, 0);
    errdefer {
        for (fields) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    var latest: ?definition_core.json_pointer.Pointer = null;
    errdefer if (latest) |*pointer| pointer.deinit(allocator);
    var limit: ?Limit = null;
    errdefer if (limit) |*value| value.deinit(allocator);
    var selection_seen = false;
    for (steps.items) |step_value| {
        const step = try definition_core.json.object(step_value);
        const operator = try definition.Operator.parse(
            try definition_core.json.requiredString(step, "op"),
        );
        if (!definition_plan.requires(operator)) {
            return error.UndeclaredArtifactOperator;
        }
        switch (operator) {
            .filter, .id_lookup => {
                if (selection_seen or latest != null or limit != null) {
                    return error.InvalidProjectionOperatorOrder;
                }
                var predicate = try compilePredicate(
                    allocator,
                    definition_plan,
                    operator,
                    step,
                );
                errdefer predicate.deinit(allocator);
                try predicates.append(allocator, predicate);
            },
            .latest => {
                if (selection_seen or latest != null or limit != null) {
                    return error.InvalidProjectionOperatorOrder;
                }
                try definition_core.json.requireExactKeys(
                    step,
                    &.{ "op", "path" },
                );
                latest = try definition_core.json_pointer.compile(
                    allocator,
                    try definition_core.json.requiredString(step, "path"),
                );
            },
            .select => {
                if (selection_seen or limit != null) {
                    return error.InvalidProjectionOperatorOrder;
                }
                fields = try compileFields(
                    allocator,
                    try definition_core.json.object(
                        try definition_core.json.field(step, "fields"),
                    ),
                    step,
                );
                selection_seen = true;
            },
            .limit => {
                if (limit != null) return error.DuplicateProjectionLimit;
                limit = try compileLimit(allocator, definition_plan, step);
            },
            .@"export" => {
                try definition_core.json.requireExactKeys(step, &.{"op"});
            },
            else => return error.UnsupportedProjectionOperator,
        }
    }
    return .{
        .name = try allocator.dupe(u8, source.name),
        .slot_index = @intCast(slot_index),
        .predicates = try predicates.toOwnedSlice(allocator),
        .fields = fields,
        .latest = latest,
        .limit = limit,
    };
}

fn compilePredicate(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    operator: definition.Operator,
    object: std.json.ObjectMap,
) !Predicate {
    const pointer = try definition_core.json_pointer.compile(
        allocator,
        try definition_core.json.requiredString(object, "path"),
    );
    errdefer {
        var owned = pointer;
        owned.deinit(allocator);
    }
    const operand: Operand = switch (operator) {
        .filter => blk: {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "path", "equals", "param" },
            );
            const fixed = object.get("equals");
            const parameter = object.get("param");
            if ((fixed == null) == (parameter == null)) {
                return error.InvalidProjectionPredicate;
            }
            if (fixed) |value| {
                break :blk .{
                    .constant = try scalarFromJsonAlloc(allocator, value),
                };
            }
            const name = try definition_core.json.string(parameter.?);
            if (definition_plan.parameter_declarations.find(name) == null) {
                return error.UnknownProjectionParameter;
            }
            break :blk .{ .parameter = try allocator.dupe(u8, name) };
        },
        .id_lookup => blk: {
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "path", "param" },
            );
            const name = try definition_core.json.requiredString(
                object,
                "param",
            );
            if (definition_plan.parameter_declarations.find(name) == null) {
                return error.UnknownProjectionParameter;
            }
            break :blk .{ .parameter = try allocator.dupe(u8, name) };
        },
        else => unreachable,
    };
    return .{
        .pointer = pointer,
        .operand = operand,
    };
}

fn compileFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    step: std.json.ObjectMap,
) ![]Field {
    try definition_core.json.requireExactKeys(step, &.{ "op", "fields" });
    if (object.count() == 0 or object.count() > 256) {
        return error.InvalidProjectionFields;
    }
    var fields: std.ArrayList(Field) = .empty;
    errdefer {
        for (fields.items) |*field| field.deinit(allocator);
        fields.deinit(allocator);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(entry.value_ptr.*),
        );
        errdefer pointer.deinit(allocator);
        try fields.append(allocator, .{ .name = name, .pointer = pointer });
    }
    std.mem.sort(Field, fields.items, {}, struct {
        fn lessThan(_: void, left: Field, right: Field) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return fields.toOwnedSlice(allocator);
}

fn compileLimit(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !Limit {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "count", "param" },
    );
    const fixed = object.get("count");
    const parameter = object.get("param");
    if ((fixed == null) == (parameter == null)) {
        return error.InvalidProjectionLimit;
    }
    if (fixed) |value| {
        const count = try definition_core.json.unsigned(value);
        if (count == 0 or count > definition_plan.bounds.max_records) {
            return error.InvalidProjectionLimit;
        }
        return .{ .fixed = count };
    }
    const name = try definition_core.json.string(parameter.?);
    const declaration = definition_plan.parameter_declarations.find(name) orelse
        return error.UnknownProjectionParameter;
    if (declaration.kind != .integer) {
        return error.ProjectionLimitParameterMustBeInteger;
    }
    return .{ .parameter = try allocator.dupe(u8, name) };
}

pub fn execute(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    plan: *const Plan,
    projection_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    const compiled = plan.find(projection_name) orelse
        return error.UnknownProjection;
    const slot = storage_plan.slots[compiled.slot_index];
    var snapshot = try custody.readSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
    );
    defer snapshot.deinit(allocator);
    _ = try replay.validateSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
        &snapshot,
    );
    const effective_limit = try resolveLimit(
        compiled.limit,
        parameters,
        plan.max_records,
    );
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    switch (slot.codec) {
        .json => try executeDocument(
            allocator,
            compiled,
            snapshot.content,
            parameters,
            effective_limit,
            &output.writer,
            &stats,
        ),
        .jsonl => try executeJsonl(
            allocator,
            compiled,
            snapshot.content,
            parameters,
            effective_limit,
            plan.max_records,
            &output.writer,
            &stats,
        ),
        .text => return error.TextProjectionNotCompiled,
    }
    if (output.written().len > plan.max_output_bytes) {
        return error.ProjectionOutputBoundsExceeded;
    }
    const payload = try output.toOwnedSlice();
    errdefer allocator.free(payload);
    const limitations = try allocator.alloc([]u8, 0);
    errdefer allocator.free(limitations);
    const definition_id = try allocator.dupe(u8, definition_plan.id);
    errdefer allocator.free(definition_id);
    const projection = try allocator.dupe(u8, projection_name);
    errdefer allocator.free(projection);
    const logical_ref = try allocator.dupe(u8, slot.relative_path);
    errdefer allocator.free(logical_ref);
    const revision = try allocator.dupe(u8, snapshot.revision);
    errdefer allocator.free(revision);
    return .{
        .definition_id = definition_id,
        .definition_digest = definition_plan.closure_digest,
        .projection = projection,
        .logical_ref = logical_ref,
        .revision = revision,
        .payload = payload,
        .stats = stats,
        .limitations = limitations,
    };
}

fn executeDocument(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    limit: usize,
    writer: *std.Io.Writer,
    stats: *Stats,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
    stats.records_scanned = 1;
    if (limit == 0 or !matches(projection, parsed.value, parameters)) {
        try writer.writeAll("null");
        return;
    }
    stats.records_matched = 1;
    stats.records_emitted = 1;
    try writeProjectedValue(allocator, writer, projection, parsed.value);
}

fn executeJsonl(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    limit: usize,
    max_records: usize,
    writer: *std.Io.Writer,
    stats: *Stats,
) !void {
    var latest_value: ?[]u8 = null;
    defer if (latest_value) |value| allocator.free(value);
    var latest_key: ?Scalar = null;
    defer if (latest_key) |*key| key.deinit(allocator);
    try writer.writeByte('[');
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        stats.records_scanned += 1;
        if (stats.records_scanned > max_records) {
            return error.ProjectionRecordBoundsExceeded;
        }
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        if (!matches(projection, parsed.value, parameters)) continue;
        stats.records_matched += 1;
        if (projection.latest) |pointer| {
            const raw_key = definition_core.json_pointer.lookup(
                parsed.value,
                pointer,
            ) orelse continue;
            var key = try scalarFromJsonAlloc(allocator, raw_key);
            var key_owned = true;
            defer if (key_owned) key.deinit(allocator);
            if (latest_key == null or
                (try compareScalars(key, latest_key.?)) == .gt)
            {
                if (latest_key) |*prior| prior.deinit(allocator);
                latest_key = key;
                key_owned = false;
                if (latest_value) |prior| allocator.free(prior);
                latest_value = try projectedValueAlloc(
                    allocator,
                    projection,
                    parsed.value,
                );
            }
            continue;
        }
        if (stats.records_emitted == limit) break;
        if (stats.records_emitted != 0) try writer.writeByte(',');
        try writeProjectedValue(allocator, writer, projection, parsed.value);
        stats.records_emitted += 1;
    }
    if (latest_value) |value| {
        try writer.writeAll(value);
        stats.records_emitted = 1;
    }
    try writer.writeByte(']');
}

fn matches(
    projection: *const Projection,
    value: std.json.Value,
    parameters: *const definition_core.parameters.Bindings,
) bool {
    for (projection.predicates) |predicate| {
        const actual = definition_core.json_pointer.lookup(
            value,
            predicate.pointer,
        ) orelse return false;
        const expected = switch (predicate.operand) {
            .constant => |constant| constant,
            .parameter => |name| scalarFromBinding(parameters, name) orelse
                return false,
        };
        if (!scalarEqualsJson(expected, actual)) return false;
    }
    return true;
}

fn writeProjectedValue(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    projection: *const Projection,
    value: std.json.Value,
) !void {
    if (projection.fields.len == 0) {
        try definition_core.canonical_json.writeCanonicalJson(
            allocator,
            writer,
            value,
        );
        return;
    }
    try writer.writeByte('{');
    for (projection.fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            field.name,
        );
        try writer.writeByte(':');
        const selected = definition_core.json_pointer.lookup(
            value,
            field.pointer,
        ) orelse return error.ProjectionFieldMissing;
        try definition_core.canonical_json.writeCanonicalJson(
            allocator,
            writer,
            selected,
        );
    }
    try writer.writeByte('}');
}

fn projectedValueAlloc(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    value: std.json.Value,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeProjectedValue(allocator, &output.writer, projection, value);
    return output.toOwnedSlice();
}

fn scalarFromJsonAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !Scalar {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        .bool => |flag| .{ .boolean = flag },
        .null => .null,
        else => error.ProjectionScalarRequired,
    };
}

fn scalarFromBinding(
    bindings: *const definition_core.parameters.Bindings,
    name: []const u8,
) ?Scalar {
    for (bindings.items) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return switch (binding.value) {
            .string => |text| .{ .string = @constCast(text) },
            .integer => |number| .{ .integer = number },
            .boolean => |flag| .{ .boolean = flag },
            .digest,
            .timestamp,
            .safe_identifier,
            .relative_path,
            => |text| .{ .string = @constCast(text) },
        };
    }
    return null;
}

fn scalarEqualsJson(expected: Scalar, actual: std.json.Value) bool {
    return switch (expected) {
        .string => |text| actual == .string and
            std.mem.eql(u8, text, actual.string),
        .integer => |number| actual == .integer and actual.integer == number,
        .float => |number| actual == .float and actual.float == number,
        .boolean => |flag| actual == .bool and actual.bool == flag,
        .null => actual == .null,
    };
}

fn compareScalars(left: Scalar, right: Scalar) !std.math.Order {
    return switch (left) {
        .string => |value| switch (right) {
            .string => |other| std.mem.order(u8, value, other),
            else => error.ProjectionOrderingTypeMismatch,
        },
        .integer => |value| switch (right) {
            .integer => |other| std.math.order(value, other),
            else => error.ProjectionOrderingTypeMismatch,
        },
        .float => |value| switch (right) {
            .float => |other| std.math.order(value, other),
            else => error.ProjectionOrderingTypeMismatch,
        },
        else => error.ProjectionOrderingTypeMismatch,
    };
}

fn resolveLimit(
    maybe_limit: ?Limit,
    parameters: *const definition_core.parameters.Bindings,
    max_records: usize,
) !usize {
    const limit = maybe_limit orelse return max_records;
    const value: usize = switch (limit) {
        .fixed => |count| count,
        .parameter => |name| blk: {
            for (parameters.items) |binding| {
                if (!std.mem.eql(u8, binding.name, name)) continue;
                break :blk switch (binding.value) {
                    .integer => |number| if (number > 0)
                        @intCast(number)
                    else
                        return error.InvalidProjectionLimit,
                    else => return error.ProjectionLimitParameterMustBeInteger,
                };
            }
            return error.MissingParameter;
        },
    };
    if (value == 0 or value > max_records) return error.InvalidProjectionLimit;
    return value;
}

test "projection plan round trips through the bounded cache codec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/projection","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["filter","latest","limit","select"]},"parameters":{"kind":{"type":"string","required":false}},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{},"projections":{"recent":{"slot":"events","pipeline":[{"op":"filter","path":"/kind","param":"kind"},{"op":"select","fields":{"kind":"/kind","value":"/value"}},{"op":"limit","count":10}]}},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":100,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":16}}
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
    var storage_plan = try storage.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer storage_plan.deinit(std.testing.allocator);
    var plan = try compile(
        std.testing.allocator,
        &definition_plan,
        &storage_plan,
    );
    defer plan.deinit(std.testing.allocator);
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
    try std.testing.expectEqual(plan.projections.len, cached.projections.len);
    try std.testing.expectEqualStrings(
        plan.projections[0].name,
        cached.projections[0].name,
    );
    try std.testing.expectEqual(
        plan.projections[0].predicates.len,
        cached.projections[0].predicates.len,
    );
    try std.testing.expectEqual(
        plan.projections[0].fields.len,
        cached.projections[0].fields.len,
    );
}
