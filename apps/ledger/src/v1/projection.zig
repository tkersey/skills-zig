const std = @import("std");
const definition_core = @import("definition_core");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const protocol = @import("protocol.zig");
const replay = @import("replay.zig");
const state_reducer = @import("state_reducer.zig");
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

const SortedRow = struct {
    payload: []u8,
    keys: []Scalar,
    record_index: usize,

    fn deinit(self: *SortedRow, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        for (self.keys) |*key| key.deinit(allocator);
        allocator.free(self.keys);
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

const SortOrder = enum {
    ascending,
    descending,
};

const SortSource = union(enum) {
    pointer: definition_core.json_pointer.Pointer,
    record_order,
    relevance_score,
};

const SortKey = struct {
    source: SortSource,
    order: SortOrder,

    fn deinit(self: *SortKey, allocator: std.mem.Allocator) void {
        if (self.source == .pointer) {
            self.source.pointer.deinit(allocator);
        }
        self.* = undefined;
    }
};

const RelevanceMode = enum {
    literal,
    tokens,
};

const Relevance = struct {
    paths: []definition_core.json_pointer.Pointer,
    parameter: []u8,
    mode: RelevanceMode,
    score_field: ?[]u8,

    fn deinit(self: *Relevance, allocator: std.mem.Allocator) void {
        for (self.paths) |*path| path.deinit(allocator);
        allocator.free(self.paths);
        allocator.free(self.parameter);
        if (self.score_field) |field| allocator.free(field);
        self.* = undefined;
    }
};

const KeyedFold = struct {
    key_field: []u8,
    state_field: []u8,

    fn deinit(self: *KeyedFold, allocator: std.mem.Allocator) void {
        allocator.free(self.key_field);
        allocator.free(self.state_field);
        self.* = undefined;
    }
};

const RetainedMeta = enum {
    record_count,
    head_digest,
    event_kind_counts,
};

const RetainedRegister = struct {
    index: u16,
    pointer: definition_core.json_pointer.Pointer,
    count: bool,

    fn deinit(
        self: *RetainedRegister,
        allocator: std.mem.Allocator,
    ) void {
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

const RetainedSource = union(enum) {
    register: RetainedRegister,
    meta: RetainedMeta,

    fn deinit(self: *RetainedSource, allocator: std.mem.Allocator) void {
        if (self.* == .register) self.register.deinit(allocator);
        self.* = undefined;
    }
};

const RetainedField = struct {
    name: []u8,
    source: RetainedSource,

    fn deinit(self: *RetainedField, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

const RetainedFold = struct {
    fields: []RetainedField,

    fn deinit(self: *RetainedFold, allocator: std.mem.Allocator) void {
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

const Fold = union(enum) {
    keyed: KeyedFold,
    retained: RetainedFold,

    fn deinit(self: *Fold, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .keyed => |*fold| fold.deinit(allocator),
            .retained => |*fold| fold.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const Projection = struct {
    name: []u8,
    slot_index: u16,
    predicates: []Predicate,
    fields: []Field,
    preserve_field_order: bool,
    raw: bool,
    single: bool,
    require_match: bool,
    sort_keys: []SortKey,
    relevance: ?Relevance,
    latest: ?definition_core.json_pointer.Pointer,
    limit: ?Limit,
    fold: ?Fold,

    fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.predicates) |*predicate| predicate.deinit(allocator);
        allocator.free(self.predicates);
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        for (self.sort_keys) |*key| key.deinit(allocator);
        allocator.free(self.sort_keys);
        if (self.relevance) |*relevance| relevance.deinit(allocator);
        if (self.latest) |*pointer| pointer.deinit(allocator);
        if (self.limit) |*limit| limit.deinit(allocator);
        if (self.fold) |*fold| fold.deinit(allocator);
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
    event_protocol: ?*const protocol.Plan,
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
            event_protocol,
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
    try encoder.writeU16(6);
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
        try encoder.writeBool(projection.preserve_field_order);
        try encoder.writeBool(projection.raw);
        try encoder.writeBool(projection.single);
        try encoder.writeBool(projection.require_match);
        try encoder.writeCount(projection.sort_keys.len);
        for (projection.sort_keys) |key| {
            switch (key.source) {
                .pointer => |pointer| {
                    try encoder.writeByte(0);
                    try encoder.writeBytes(pointer.raw);
                },
                .record_order => try encoder.writeByte(1),
                .relevance_score => try encoder.writeByte(2),
            }
            try encoder.writeEnum(key.order);
        }
        try encoder.writeBool(projection.relevance != null);
        if (projection.relevance) |relevance| {
            try encoder.writeCount(relevance.paths.len);
            for (relevance.paths) |path| {
                try encoder.writeBytes(path.raw);
            }
            try encoder.writeBytes(relevance.parameter);
            try encoder.writeEnum(relevance.mode);
            try encoder.writeBool(relevance.score_field != null);
            if (relevance.score_field) |field| {
                try encoder.writeBytes(field);
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
        try encoder.writeBool(projection.fold != null);
        if (projection.fold) |fold| {
            switch (fold) {
                .keyed => |keyed| {
                    try encoder.writeByte(0);
                    try encoder.writeBytes(keyed.key_field);
                    try encoder.writeBytes(keyed.state_field);
                },
                .retained => |retained| {
                    try encoder.writeByte(1);
                    try encoder.writeCount(retained.fields.len);
                    for (retained.fields) |field| {
                        try encoder.writeBytes(field.name);
                        switch (field.source) {
                            .register => |register| {
                                try encoder.writeByte(0);
                                try encoder.writeU16(register.index);
                                try encoder.writeBytes(
                                    register.pointer.raw,
                                );
                                try encoder.writeBool(register.count);
                            },
                            .meta => |meta| {
                                try encoder.writeByte(1);
                                try encoder.writeEnum(meta);
                            },
                        }
                    }
                },
            }
        }
    }
    try encoder.writeUsize(plan.max_records);
    try encoder.writeUsize(plan.max_output_bytes);
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 6) {
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
    event_protocol: ?*const protocol.Plan,
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
        if (projection.fold) |fold| {
            if (projection.predicates.len != 0 or
                projection.fields.len != 0 or
                projection.latest != null or
                !definition_plan.requires(.fold) or
                event_protocol == null or
                event_protocol.?.target_slot_index != projection.slot_index)
            {
                return error.CacheProjectionPlanMismatch;
            }
            switch (fold) {
                .keyed => |keyed| {
                    if (event_protocol.?.reducer_plan == null or
                        std.mem.eql(
                            u8,
                            keyed.key_field,
                            keyed.state_field,
                        ))
                    {
                        return error.CacheProjectionPlanMismatch;
                    }
                    try definition_core.json.safeIdentifier(
                        keyed.key_field,
                        128,
                    );
                    try definition_core.json.safeIdentifier(
                        keyed.state_field,
                        128,
                    );
                },
                .retained => |retained| {
                    const retained_plan =
                        if (event_protocol.?.state_reducer_plan) |*value|
                            value
                        else
                            return error.CacheProjectionPlanMismatch;
                    if (projection.limit != null or
                        retained.fields.len == 0 or
                        retained.fields.len > 256)
                    {
                        return error.CacheProjectionPlanMismatch;
                    }
                    for (retained.fields, 0..) |field, index| {
                        try definition_core.json.safeIdentifier(
                            field.name,
                            128,
                        );
                        if (index != 0 and std.mem.order(
                            u8,
                            retained.fields[index - 1].name,
                            field.name,
                        ) != .lt) {
                            return error.CacheProjectionFieldsNotSorted;
                        }
                        switch (field.source) {
                            .register => |register| {
                                if (register.index >=
                                    state_reducer.registerCount(
                                        retained_plan,
                                    ))
                                {
                                    return error.CacheProjectionPlanMismatch;
                                }
                            },
                            .meta => {},
                        }
                    }
                },
            }
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
        if (projection.single and projection.limit != null) {
            return error.CacheProjectionPlanMismatch;
        }
        if (projection.require_match and !projection.single) {
            return error.CacheProjectionPlanMismatch;
        }
        if (projection.single and projection.sort_keys.len != 0) {
            return error.CacheProjectionPlanMismatch;
        }
        if (projection.sort_keys.len != 0 and
            !definition_plan.requires(.sort))
        {
            return error.CacheProjectionPlanMismatch;
        }
        if (projection.relevance != null) {
            const relevance = projection.relevance.?;
            if (!definition_plan.requires(.relevance) or
                projection.sort_keys.len == 0 or
                definition_plan.parameter_declarations.find(
                    relevance.parameter,
                ) == null)
            {
                return error.CacheProjectionPlanMismatch;
            }
            const declaration = definition_plan.parameter_declarations.find(
                relevance.parameter,
            ).?;
            if (declaration.kind != .string or
                relevance.paths.len == 0 or
                relevance.paths.len > 64 or
                relevance.score_field != null and
                    projection.fields.len == 0 or
                projection.raw)
            {
                return error.CacheProjectionPlanMismatch;
            }
            if (relevance.score_field) |score_field| {
                for (projection.fields) |field| {
                    if (std.mem.eql(u8, score_field, field.name)) {
                        return error.CacheProjectionFieldsNotUnique;
                    }
                }
            }
        }
        for (projection.sort_keys) |key| {
            if (key.source == .relevance_score and
                projection.relevance == null)
            {
                return error.CacheProjectionPlanMismatch;
            }
        }
        if (projection.raw and projection.fields.len != 0) {
            return error.CacheProjectionPlanMismatch;
        }
        for (projection.fields, 0..) |field, index| {
            for (projection.fields[0..index]) |prior| {
                if (std.mem.eql(u8, prior.name, field.name)) {
                    return error.CacheProjectionFieldsNotUnique;
                }
            }
            if (!projection.preserve_field_order and index != 0 and
                std.mem.order(
                    u8,
                    projection.fields[index - 1].name,
                    field.name,
                ) != .lt)
            {
                return error.CacheProjectionFieldsNotSorted;
            }
        }
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
    const preserve_field_order = try decoder.readBool();
    const raw = try decoder.readBool();
    const single = try decoder.readBool();
    const require_match = try decoder.readBool();
    const sort_key_count = try decoder.readCount(8);
    const sort_keys = try allocator.alloc(SortKey, sort_key_count);
    var sort_keys_initialized: usize = 0;
    errdefer {
        for (sort_keys[0..sort_keys_initialized]) |*key| {
            key.deinit(allocator);
        }
        allocator.free(sort_keys);
    }
    for (sort_keys) |*key| {
        const source: SortSource = switch (try decoder.readByte()) {
            0 => pointer: {
                const raw_pointer = try decoder.readBytesAlloc(
                    allocator,
                    1024,
                );
                defer allocator.free(raw_pointer);
                break :pointer .{ .pointer =
                    try definition_core.json_pointer.compile(
                        allocator,
                        raw_pointer,
                    ) };
            },
            1 => .record_order,
            2 => .relevance_score,
            else => return error.CacheProjectionSortSourceInvalid,
        };
        key.* = .{
            .source = source,
            .order = try decoder.readEnum(SortOrder),
        };
        sort_keys_initialized += 1;
    }
    var relevance: ?Relevance = null;
    errdefer if (relevance) |*compiled| compiled.deinit(allocator);
    if (try decoder.readBool()) {
        const path_count = try decoder.readCount(64);
        if (path_count == 0) return error.CacheProjectionRelevanceInvalid;
        const paths = try allocator.alloc(
            definition_core.json_pointer.Pointer,
            path_count,
        );
        var paths_initialized: usize = 0;
        errdefer {
            for (paths[0..paths_initialized]) |*path| {
                path.deinit(allocator);
            }
            allocator.free(paths);
        }
        for (paths) |*path| {
            const raw_path = try decoder.readBytesAlloc(allocator, 1024);
            defer allocator.free(raw_path);
            path.* = try definition_core.json_pointer.compile(
                allocator,
                raw_path,
            );
            paths_initialized += 1;
        }
        const parameter = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(parameter);
        try definition_core.json.safeIdentifier(parameter, 128);
        const mode = try decoder.readEnum(RelevanceMode);
        const score_field = if (try decoder.readBool()) score: {
            const field = try decoder.readBytesAlloc(allocator, 128);
            errdefer allocator.free(field);
            try definition_core.json.safeIdentifier(field, 128);
            break :score field;
        } else null;
        relevance = .{
            .paths = paths,
            .parameter = parameter,
            .mode = mode,
            .score_field = score_field,
        };
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
        if (!preserve_field_order and index != 0 and
            std.mem.order(u8, fields[index - 1].name, field_name) != .lt)
        {
            return error.CacheProjectionFieldsNotSorted;
        }
        for (fields[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, field_name)) {
                return error.CacheProjectionFieldsNotUnique;
            }
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
    var fold: ?Fold = null;
    errdefer if (fold) |*compiled| compiled.deinit(allocator);
    if (try decoder.readBool()) {
        fold = switch (try decoder.readByte()) {
            0 => keyed: {
                const key_field =
                    try decoder.readBytesAlloc(allocator, 128);
                errdefer allocator.free(key_field);
                try definition_core.json.safeIdentifier(key_field, 128);
                const state_field =
                    try decoder.readBytesAlloc(allocator, 128);
                errdefer allocator.free(state_field);
                try definition_core.json.safeIdentifier(
                    state_field,
                    128,
                );
                if (std.mem.eql(u8, key_field, state_field)) {
                    return error.CacheProjectionFieldsConflict;
                }
                break :keyed .{ .keyed = .{
                    .key_field = key_field,
                    .state_field = state_field,
                } };
            },
            1 => retained: {
                const retained_count = try decoder.readCount(256);
                if (retained_count == 0) {
                    return error.CacheProjectionFieldsInvalid;
                }
                const retained_fields = try allocator.alloc(
                    RetainedField,
                    retained_count,
                );
                var retained_initialized: usize = 0;
                errdefer {
                    for (retained_fields[0..retained_initialized]) |*field| {
                        field.deinit(allocator);
                    }
                    allocator.free(retained_fields);
                }
                for (retained_fields, 0..) |*field, index| {
                    const field_name =
                        try decoder.readBytesAlloc(allocator, 128);
                    errdefer allocator.free(field_name);
                    try definition_core.json.safeIdentifier(
                        field_name,
                        128,
                    );
                    if (index != 0 and std.mem.order(
                        u8,
                        retained_fields[index - 1].name,
                        field_name,
                    ) != .lt) {
                        return error.CacheProjectionFieldsNotSorted;
                    }
                    var source: RetainedSource = switch (try decoder.readByte()) {
                        0 => register: {
                            const register_index =
                                try decoder.readU16();
                            const raw_pointer =
                                try decoder.readBytesAlloc(
                                    allocator,
                                    1024,
                                );
                            defer allocator.free(raw_pointer);
                            var pointer =
                                try definition_core.json_pointer.compile(
                                    allocator,
                                    raw_pointer,
                                );
                            errdefer pointer.deinit(allocator);
                            break :register .{ .register = .{
                                .index = register_index,
                                .pointer = pointer,
                                .count = try decoder.readBool(),
                            } };
                        },
                        1 => .{ .meta = try decoder.readEnum(
                            RetainedMeta,
                        ) },
                        else => return error.CacheProjectionSourceInvalid,
                    };
                    errdefer source.deinit(allocator);
                    field.* = .{
                        .name = field_name,
                        .source = source,
                    };
                    retained_initialized += 1;
                }
                break :retained .{ .retained = .{
                    .fields = retained_fields,
                } };
            },
            else => return error.CacheProjectionFoldInvalid,
        };
    }
    return .{
        .name = name,
        .slot_index = slot_index,
        .predicates = predicates,
        .fields = fields,
        .preserve_field_order = preserve_field_order,
        .raw = raw,
        .single = single,
        .require_match = require_match,
        .sort_keys = sort_keys,
        .relevance = relevance,
        .latest = latest,
        .limit = limit,
        .fold = fold,
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
    event_protocol: ?*const protocol.Plan,
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
    var sort_keys: []SortKey = try allocator.alloc(SortKey, 0);
    errdefer {
        for (sort_keys) |*key| key.deinit(allocator);
        allocator.free(sort_keys);
    }
    var relevance: ?Relevance = null;
    errdefer if (relevance) |*compiled| compiled.deinit(allocator);
    var latest: ?definition_core.json_pointer.Pointer = null;
    errdefer if (latest) |*pointer| pointer.deinit(allocator);
    var limit: ?Limit = null;
    errdefer if (limit) |*value| value.deinit(allocator);
    var fold: ?Fold = null;
    errdefer if (fold) |*compiled| compiled.deinit(allocator);
    var selection_seen = false;
    var preserve_field_order = false;
    var raw_export = false;
    var single = false;
    var require_match = false;
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
                if (selection_seen or latest != null or limit != null or
                    fold != null or sort_keys.len != 0 or relevance != null)
                {
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
                if (operator == .id_lookup) {
                    if (single) return error.DuplicateProjectionCardinality;
                    single = true;
                    require_match = if (step.get("required")) |value|
                        try definition_core.json.boolean(value)
                    else
                        false;
                }
            },
            .latest => {
                if (selection_seen or latest != null or limit != null or
                    fold != null or single or sort_keys.len != 0)
                {
                    return error.InvalidProjectionOperatorOrder;
                }
                try definition_core.json.requireExactKeys(
                    step,
                    &.{ "op", "path", "required" },
                );
                latest = try definition_core.json_pointer.compile(
                    allocator,
                    try definition_core.json.requiredString(step, "path"),
                );
                single = true;
                require_match = if (step.get("required")) |value|
                    try definition_core.json.boolean(value)
                else
                    false;
            },
            .select => {
                if (selection_seen or limit != null or fold != null) {
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
            .relevance => {
                if (selection_seen or latest != null or limit != null or
                    fold != null or single or sort_keys.len != 0 or
                    relevance != null)
                {
                    return error.InvalidProjectionOperatorOrder;
                }
                relevance = try compileRelevance(
                    allocator,
                    definition_plan,
                    step,
                );
            },
            .sort => {
                if (selection_seen or latest != null or limit != null or
                    fold != null or single or sort_keys.len != 0)
                {
                    return error.InvalidProjectionOperatorOrder;
                }
                sort_keys = try compileSortKeys(
                    allocator,
                    try definition_core.json.array(
                        try definition_core.json.field(step, "keys"),
                    ),
                    step,
                );
            },
            .fold => {
                if (selection_seen or predicates.items.len != 0 or
                    latest != null or limit != null or fold != null or
                    sort_keys.len != 0)
                {
                    return error.InvalidProjectionOperatorOrder;
                }
                if (event_protocol == null or
                    event_protocol.?.target_slot_index != slot_index)
                {
                    return error.FoldRequiresReducerSlot;
                }
                if (step.get("fields")) |fields_value| {
                    try definition_core.json.requireExactKeys(
                        step,
                        &.{ "op", "fields" },
                    );
                    const retained_plan =
                        if (event_protocol.?.state_reducer_plan) |*value|
                            value
                        else
                            return error.FoldRequiresRetainedReducer;
                    fold = .{ .retained = .{
                        .fields = try compileRetainedFields(
                            allocator,
                            retained_plan,
                            try definition_core.json.object(
                                fields_value,
                            ),
                        ),
                    } };
                } else {
                    if (event_protocol.?.reducer_plan == null) {
                        return error.FoldRequiresKeyedReducer;
                    }
                    try definition_core.json.requireExactKeys(
                        step,
                        &.{ "op", "key_field", "state_field" },
                    );
                    try definition_core.json.requireFields(
                        step,
                        &.{ "op", "key_field", "state_field" },
                    );
                    const key_field =
                        try definition_core.json.requiredString(
                            step,
                            "key_field",
                        );
                    const state_field =
                        try definition_core.json.requiredString(
                            step,
                            "state_field",
                        );
                    try definition_core.json.safeIdentifier(
                        key_field,
                        128,
                    );
                    try definition_core.json.safeIdentifier(
                        state_field,
                        128,
                    );
                    if (std.mem.eql(u8, key_field, state_field)) {
                        return error.ProjectionFieldsConflict;
                    }
                    fold = fold: {
                        const owned_key =
                            try allocator.dupe(u8, key_field);
                        errdefer allocator.free(owned_key);
                        const owned_state =
                            try allocator.dupe(u8, state_field);
                        break :fold .{ .keyed = .{
                            .key_field = owned_key,
                            .state_field = owned_state,
                        } };
                    };
                }
            },
            .limit => {
                if (limit != null or single) {
                    return error.InvalidProjectionOperatorOrder;
                }
                limit = try compileLimit(allocator, definition_plan, step);
            },
            .@"export" => {
                if (selection_seen or limit != null or fold != null) {
                    return error.InvalidProjectionOperatorOrder;
                }
                if (step.get("fields")) |field_values| {
                    try definition_core.json.requireExactKeys(
                        step,
                        &.{ "op", "fields" },
                    );
                    fields = try compileOrderedFields(
                        allocator,
                        try definition_core.json.array(field_values),
                        step,
                    );
                    preserve_field_order = true;
                } else {
                    try definition_core.json.requireExactKeys(
                        step,
                        &.{ "op", "raw" },
                    );
                    raw_export = if (step.get("raw")) |value|
                        try definition_core.json.boolean(value)
                    else
                        false;
                }
                selection_seen = true;
            },
            else => return error.UnsupportedProjectionOperator,
        }
    }
    if (fold != null and fold.? == .retained and limit != null) {
        return error.RetainedFoldRejectsLimit;
    }
    if (relevance != null) {
        if (sort_keys.len == 0 or raw_export) {
            return error.RelevanceRequiresSortedStructuredProjection;
        }
        if (relevance.?.score_field) |score_field| {
            if (fields.len == 0) {
                return error.RelevanceScoreRequiresProjectionFields;
            }
            for (fields) |field| {
                if (std.mem.eql(u8, score_field, field.name)) {
                    return error.ProjectionFieldsNotUnique;
                }
            }
        }
    }
    for (sort_keys) |key| {
        if (key.source == .relevance_score and relevance == null) {
            return error.RelevanceSortRequiresRelevanceOperator;
        }
    }
    return .{
        .name = try allocator.dupe(u8, source.name),
        .slot_index = @intCast(slot_index),
        .predicates = try predicates.toOwnedSlice(allocator),
        .fields = fields,
        .preserve_field_order = preserve_field_order,
        .raw = raw_export,
        .single = single,
        .require_match = require_match,
        .sort_keys = sort_keys,
        .relevance = relevance,
        .latest = latest,
        .limit = limit,
        .fold = fold,
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
                &.{ "op", "path", "param", "required" },
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

fn compileRelevance(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !Relevance {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "paths", "param", "mode", "score_field" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "op", "paths", "param", "mode" },
    );
    const path_values = try definition_core.json.array(
        try definition_core.json.field(object, "paths"),
    );
    if (path_values.items.len == 0 or path_values.items.len > 64) {
        return error.InvalidProjectionRelevancePaths;
    }
    const paths = try allocator.alloc(
        definition_core.json_pointer.Pointer,
        path_values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (paths[0..initialized]) |*path| path.deinit(allocator);
        allocator.free(paths);
    }
    for (path_values.items, 0..) |value, index| {
        paths[index] = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(value),
        );
        initialized += 1;
    }
    const raw_parameter = try definition_core.json.requiredString(
        object,
        "param",
    );
    const declaration = definition_plan.parameter_declarations.find(
        raw_parameter,
    ) orelse return error.UnknownProjectionParameter;
    if (declaration.kind != .string) {
        return error.ProjectionRelevanceParameterMustBeString;
    }
    const parameter = try allocator.dupe(u8, raw_parameter);
    errdefer allocator.free(parameter);
    const raw_mode = try definition_core.json.requiredString(object, "mode");
    const mode: RelevanceMode =
        if (std.mem.eql(u8, raw_mode, "literal"))
            .literal
        else if (std.mem.eql(u8, raw_mode, "tokens"))
            .tokens
        else
            return error.InvalidProjectionRelevanceMode;
    const score_field = if (object.get("score_field")) |value| field: {
        const raw_field = try definition_core.json.string(value);
        try definition_core.json.safeIdentifier(raw_field, 128);
        break :field try allocator.dupe(u8, raw_field);
    } else null;
    return .{
        .paths = paths,
        .parameter = parameter,
        .mode = mode,
        .score_field = score_field,
    };
}

fn compileSortKeys(
    allocator: std.mem.Allocator,
    values: std.json.Array,
    step: std.json.ObjectMap,
) ![]SortKey {
    try definition_core.json.requireExactKeys(step, &.{ "op", "keys" });
    if (values.items.len == 0 or values.items.len > 8) {
        return error.InvalidProjectionSortKeys;
    }
    const keys = try allocator.alloc(SortKey, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (keys[0..initialized]) |*key| key.deinit(allocator);
        allocator.free(keys);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "path", "meta", "order" },
        );
        const raw_path = object.get("path");
        const raw_meta = object.get("meta");
        if ((raw_path == null) == (raw_meta == null)) {
            return error.InvalidProjectionSortSource;
        }
        const source: SortSource = if (raw_path) |path|
            .{ .pointer = try definition_core.json_pointer.compile(
                allocator,
                try definition_core.json.string(path),
            ) }
        else meta: {
            const name = try definition_core.json.string(raw_meta.?);
            if (std.mem.eql(u8, name, "record-order")) {
                break :meta .record_order;
            }
            if (std.mem.eql(u8, name, "relevance-score")) {
                break :meta .relevance_score;
            }
            return error.InvalidProjectionSortSource;
        };
        errdefer if (source == .pointer) {
            var pointer = source.pointer;
            pointer.deinit(allocator);
        };
        const raw_order = try definition_core.json.requiredString(
            object,
            "order",
        );
        const order: SortOrder =
            if (std.mem.eql(u8, raw_order, "ascending"))
                .ascending
            else if (std.mem.eql(u8, raw_order, "descending"))
                .descending
            else
                return error.InvalidProjectionSortOrder;
        keys[index] = .{ .source = source, .order = order };
        initialized += 1;
    }
    return keys;
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

fn compileOrderedFields(
    allocator: std.mem.Allocator,
    values: std.json.Array,
    step: std.json.ObjectMap,
) ![]Field {
    try definition_core.json.requireExactKeys(step, &.{ "op", "fields" });
    if (values.items.len == 0 or values.items.len > 256) {
        return error.InvalidProjectionFields;
    }
    const fields = try allocator.alloc(Field, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "name", "path" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "name", "path" },
        );
        const raw_name = try definition_core.json.requiredString(
            object,
            "name",
        );
        try definition_core.json.safeIdentifier(raw_name, 128);
        for (fields[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, raw_name)) {
                return error.ProjectionFieldsNotUnique;
            }
        }
        const name = try allocator.dupe(u8, raw_name);
        errdefer allocator.free(name);
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.requiredString(object, "path"),
        );
        errdefer pointer.deinit(allocator);
        fields[index] = .{ .name = name, .pointer = pointer };
        initialized += 1;
    }
    return fields;
}

fn compileRetainedFields(
    allocator: std.mem.Allocator,
    retained_plan: *const state_reducer.Plan,
    object: std.json.ObjectMap,
) ![]RetainedField {
    if (object.count() == 0 or object.count() > 256) {
        return error.InvalidProjectionFields;
    }
    var fields: std.ArrayList(RetainedField) = .empty;
    errdefer {
        for (fields.items) |*field| field.deinit(allocator);
        fields.deinit(allocator);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const source_object = try definition_core.json.object(
            entry.value_ptr.*,
        );
        var source: RetainedSource = if (source_object.get("register") != null) register: {
            try definition_core.json.requireExactKeys(
                source_object,
                &.{ "register", "path", "count" },
            );
            try definition_core.json.requireFields(
                source_object,
                &.{"register"},
            );
            const register_name =
                try definition_core.json.requiredString(
                    source_object,
                    "register",
                );
            const register_index =
                state_reducer.registerIndex(
                    retained_plan,
                    register_name,
                ) orelse return error.UnknownProjectionRegister;
            const raw_path = if (source_object.get("path")) |raw|
                try definition_core.json.string(raw)
            else
                "";
            var pointer = try definition_core.json_pointer.compile(
                allocator,
                raw_path,
            );
            errdefer pointer.deinit(allocator);
            const count = if (source_object.get("count")) |raw|
                try definition_core.json.boolean(raw)
            else
                false;
            break :register .{ .register = .{
                .index = register_index,
                .pointer = pointer,
                .count = count,
            } };
        } else meta: {
            try definition_core.json.requireExactKeys(
                source_object,
                &.{"meta"},
            );
            try definition_core.json.requireFields(
                source_object,
                &.{"meta"},
            );
            break :meta .{ .meta = try parseRetainedMeta(
                try definition_core.json.requiredString(
                    source_object,
                    "meta",
                ),
            ) };
        };
        errdefer source.deinit(allocator);
        try fields.append(allocator, .{
            .name = name,
            .source = source,
        });
    }
    std.mem.sort(RetainedField, fields.items, {}, struct {
        fn lessThan(
            _: void,
            left: RetainedField,
            right: RetainedField,
        ) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return fields.toOwnedSlice(allocator);
}

fn parseRetainedMeta(raw: []const u8) !RetainedMeta {
    if (std.mem.eql(u8, raw, "record-count")) return .record_count;
    if (std.mem.eql(u8, raw, "head-digest")) return .head_digest;
    if (std.mem.eql(u8, raw, "event-kind-counts")) {
        return .event_kind_counts;
    }
    return error.UnknownProjectionMetadata;
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
    event_protocol: ?*const protocol.Plan,
    plan: *const Plan,
    projection_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    const compiled = plan.find(projection_name) orelse
        return error.UnknownProjection;
    var resolved_storage = try storage.resolve(
        allocator,
        storage_plan,
        parameters,
    );
    defer resolved_storage.deinit(allocator);
    const slot = resolved_storage.slot(compiled.slot_index);
    var snapshot = try custody.readSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
    );
    defer snapshot.deinit(allocator);
    var replay_stats = try replay.validateSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
        &snapshot,
        parameters,
        definition_plan.bounds.max_records,
        event_protocol != null and
            event_protocol.?.target_slot_index == compiled.slot_index,
    );
    defer replay_stats.deinit(allocator);
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
    if (compiled.fold) |fold| {
        const replay_state =
            if (replay_stats.protocol_state) |*protocol_state|
                protocol_state
            else
                return error.FoldReplayStateMissing;
        const event_plan = event_protocol orelse
            return error.FoldReplayPlanMissing;
        stats.records_scanned = replay_stats.records_validated;
        switch (fold) {
            .keyed => |keyed| {
                stats.records_matched =
                    replay_state.reducer_state.count();
                stats.records_emitted =
                    try replay_state.reducer_state.writeCanonicalRows(
                        allocator,
                        &output,
                        keyed.key_field,
                        keyed.state_field,
                        effective_limit,
                        plan.max_output_bytes,
                    );
            },
            .retained => |retained| {
                const retained_plan =
                    if (event_plan.state_reducer_plan) |*value|
                        value
                    else
                        return error.FoldRetainedPlanMissing;
                try writeRetainedProjection(
                    allocator,
                    &output.writer,
                    event_plan,
                    retained_plan,
                    replay_state,
                    retained.fields,
                );
                stats.records_matched = 1;
                stats.records_emitted = 1;
            },
        }
    } else {
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
            .jsonl => if (compiled.sort_keys.len == 0)
                try executeJsonl(
                    allocator,
                    compiled,
                    snapshot.content,
                    parameters,
                    effective_limit,
                    plan.max_records,
                    &output.writer,
                    &stats,
                )
            else
                try executeSortedJsonl(
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

fn writeRetainedProjection(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    event_plan: *const protocol.Plan,
    retained_plan: *const state_reducer.Plan,
    replay_state: *const protocol.ReplayState,
    fields: []const RetainedField,
) !void {
    try writer.writeByte('{');
    for (fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            field.name,
        );
        try writer.writeByte(':');
        switch (field.source) {
            .register => |register| {
                const root = state_reducer.getByIndex(
                    &replay_state.state_reducer_state,
                    retained_plan,
                    register.index,
                );
                const selected = if (root) |value|
                    definition_core.json_pointer.lookup(
                        value,
                        register.pointer,
                    )
                else
                    null;
                if (register.count) {
                    const count = if (selected) |value|
                        try retainedValueCount(value)
                    else
                        0;
                    try writer.print("{d}", .{count});
                } else if (selected) |value| {
                    try definition_core.canonical_json.writeCanonicalJson(
                        allocator,
                        writer,
                        value,
                    );
                } else {
                    try writer.writeAll("null");
                }
            },
            .meta => |meta| switch (meta) {
                .record_count => try writer.print(
                    "{d}",
                    .{replay_state.records},
                ),
                .head_digest => {
                    if (replay_state.headDigest(event_plan)) |digest| {
                        try definition_core.canonical_json
                            .writeCanonicalString(writer, digest);
                    } else {
                        try writer.writeAll("null");
                    }
                },
                .event_kind_counts => {
                    try writer.writeByte('{');
                    for (event_plan.event_kinds, 0..) |kind, kind_index| {
                        if (kind_index != 0) try writer.writeByte(',');
                        try definition_core.canonical_json
                            .writeCanonicalString(writer, kind);
                        try writer.writeByte(':');
                        try writer.print("{d}", .{
                            replay_state.eventKindCount(
                                event_plan,
                                kind_index,
                            ) orelse return error.EventKindCountMissing,
                        });
                    }
                    try writer.writeByte('}');
                },
            },
        }
    }
    try writer.writeByte('}');
}

fn retainedValueCount(value: std.json.Value) !usize {
    return switch (value) {
        .array => |items| items.items.len,
        .object => |items| items.count(),
        else => error.ProjectionCountRequiresCollection,
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
        if (projection.require_match) return error.ProjectionNotFound;
        try writer.writeAll("null");
        return;
    }
    stats.records_matched = 1;
    stats.records_emitted = 1;
    if (projection.raw) {
        try writer.writeAll(std.mem.trim(u8, bytes, " \t\r\n"));
    } else {
        try writeProjectedValue(allocator, writer, projection, parsed.value);
    }
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
    if (!projection.single) try writer.writeByte('[');
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
                latest_value = if (projection.raw)
                    try allocator.dupe(u8, line)
                else
                    try projectedValueAlloc(
                        allocator,
                        projection,
                        parsed.value,
                    );
            }
            continue;
        }
        if (projection.single) {
            if (projection.raw) {
                try writer.writeAll(line);
            } else {
                try writeProjectedValue(
                    allocator,
                    writer,
                    projection,
                    parsed.value,
                );
            }
            stats.records_emitted = 1;
            return;
        }
        if (stats.records_emitted == limit) break;
        if (stats.records_emitted != 0) try writer.writeByte(',');
        if (projection.raw) {
            try writer.writeAll(line);
        } else {
            try writeProjectedValue(
                allocator,
                writer,
                projection,
                parsed.value,
            );
        }
        stats.records_emitted += 1;
    }
    if (latest_value) |value| {
        try writer.writeAll(value);
        stats.records_emitted = 1;
    } else if (projection.single) {
        if (projection.require_match) return error.ProjectionNotFound;
        try writer.writeAll("null");
    }
    if (!projection.single) try writer.writeByte(']');
}

fn executeSortedJsonl(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    limit: usize,
    max_records: usize,
    writer: *std.Io.Writer,
    stats: *Stats,
) !void {
    if (projection.single or projection.latest != null) {
        return error.InvalidSortedProjectionCardinality;
    }
    var rows: std.ArrayList(SortedRow) = .empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    const query = if (projection.relevance) |relevance|
        try relevanceQueryLowerAlloc(allocator, relevance, parameters)
    else
        null;
    defer if (query) |owned| allocator.free(owned);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var record_index: usize = 0;
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
        if (!matches(projection, parsed.value, parameters)) {
            record_index += 1;
            continue;
        }
        const relevance_score = if (projection.relevance) |relevance|
            (try relevanceScoreAlloc(
                allocator,
                relevance,
                query.?,
                parsed.value,
            )) orelse {
                record_index += 1;
                continue;
            }
        else
            0;
        stats.records_matched += 1;
        const keys = try allocator.alloc(Scalar, projection.sort_keys.len);
        var initialized: usize = 0;
        errdefer {
            for (keys[0..initialized]) |*key| key.deinit(allocator);
            allocator.free(keys);
        }
        for (projection.sort_keys, 0..) |sort_key, key_index| {
            keys[key_index] = switch (sort_key.source) {
                .record_order => .{ .integer = @intCast(record_index) },
                .relevance_score => .{
                    .integer = @intCast(relevance_score),
                },
                .pointer => |pointer| key: {
                    const value = definition_core.json_pointer.lookup(
                        parsed.value,
                        pointer,
                    ) orelse return error.ProjectionSortFieldMissing;
                    const key = try scalarFromJsonAlloc(allocator, value);
                    switch (key) {
                        .string, .integer, .float => {},
                        else => {
                            var owned = key;
                            owned.deinit(allocator);
                            return error.ProjectionSortScalarRequired;
                        },
                    }
                    break :key key;
                },
            };
            initialized += 1;
            if (rows.items.len != 0 and
                std.meta.activeTag(rows.items[0].keys[key_index]) !=
                    std.meta.activeTag(keys[key_index]))
            {
                return error.ProjectionOrderingTypeMismatch;
            }
        }
        const payload = if (projection.raw)
            try allocator.dupe(u8, line)
        else if (projection.relevance) |relevance|
            try projectedValueWithScoreAlloc(
                allocator,
                projection,
                parsed.value,
                relevance.score_field,
                relevance_score,
            )
        else
            try projectedValueAlloc(allocator, projection, parsed.value);
        errdefer allocator.free(payload);
        try rows.append(allocator, .{
            .payload = payload,
            .keys = keys,
            .record_index = record_index,
        });
        record_index += 1;
    }
    std.mem.sort(
        SortedRow,
        rows.items,
        projection.sort_keys,
        lessSortedRow,
    );
    try writer.writeByte('[');
    const emitted = @min(limit, rows.items.len);
    for (rows.items[0..emitted], 0..) |row, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(row.payload);
    }
    try writer.writeByte(']');
    stats.records_emitted = emitted;
}

fn lessSortedRow(
    keys: []const SortKey,
    left: SortedRow,
    right: SortedRow,
) bool {
    for (keys, 0..) |key, index| {
        const order = compareSortScalars(left.keys[index], right.keys[index]);
        if (order == .eq) continue;
        return switch (key.order) {
            .ascending => order == .lt,
            .descending => order == .gt,
        };
    }
    return left.record_index < right.record_index;
}

fn compareSortScalars(left: Scalar, right: Scalar) std.math.Order {
    return switch (left) {
        .string => |value| std.mem.order(u8, value, right.string),
        .integer => |value| std.math.order(value, right.integer),
        .float => |value| std.math.order(value, right.float),
        else => unreachable,
    };
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

fn projectedValueWithScoreAlloc(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    value: std.json.Value,
    score_field: ?[]const u8,
    score: usize,
) ![]u8 {
    const field = score_field orelse
        return projectedValueAlloc(allocator, projection, value);
    const projected = try projectedValueAlloc(allocator, projection, value);
    defer allocator.free(projected);
    if (projected.len < 2 or projected[0] != '{' or
        projected[projected.len - 1] != '}')
    {
        return error.RelevanceScoreRequiresProjectionObject;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        field,
    );
    try output.writer.print(":{d}", .{score});
    if (projected.len > 2) {
        try output.writer.writeByte(',');
        try output.writer.writeAll(projected[1 .. projected.len - 1]);
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn relevanceQueryLowerAlloc(
    allocator: std.mem.Allocator,
    relevance: Relevance,
    parameters: *const definition_core.parameters.Bindings,
) ![]u8 {
    const binding = parameters.find(relevance.parameter) orelse
        return error.MissingParameter;
    const query = switch (binding.value) {
        .string => |text| text,
        else => return error.ProjectionRelevanceParameterMustBeString,
    };
    if (query.len == 0) return error.ProjectionQueryEmpty;
    const lower = try allocator.alloc(u8, query.len);
    for (query, 0..) |char, index| {
        lower[index] = asciiLower(char);
    }
    return lower;
}

fn relevanceScoreAlloc(
    allocator: std.mem.Allocator,
    relevance: Relevance,
    query_lower: []const u8,
    value: std.json.Value,
) !?usize {
    var search_text: std.Io.Writer.Allocating = .init(allocator);
    defer search_text.deinit();
    var emitted = false;
    for (relevance.paths) |path| {
        const selected = definition_core.json_pointer.lookup(
            value,
            path,
        ) orelse continue;
        if (emitted) try search_text.writer.writeByte(' ');
        switch (selected) {
            .string => |text| try search_text.writer.writeAll(text),
            else => try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                &search_text.writer,
                selected,
            ),
        }
        emitted = true;
    }
    const haystack = search_text.written();
    const score = lexicalRelevanceScore(query_lower, haystack);
    return switch (relevance.mode) {
        .literal => if (containsAsciiFold(haystack, query_lower))
            score
        else
            null,
        .tokens => if (score != 0) score else null,
    };
}

fn lexicalRelevanceScore(
    query_lower: []const u8,
    haystack: []const u8,
) usize {
    var score: usize = 0;
    var tokens = std.mem.tokenizeAny(
        u8,
        query_lower,
        " \t\r\n,.;:/()[]{}<>\"'`",
    );
    while (tokens.next()) |token| {
        if (token.len < 2) continue;
        if (containsAsciiFold(haystack, token)) score += 1;
    }
    return score;
}

fn containsAsciiFold(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (needle_lower.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle_lower.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle_lower, 0..) |expected, offset| {
            if (asciiLower(haystack[start + offset]) != expected) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn asciiLower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
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
        null,
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

test "exact lookup emits one definition-ordered or raw payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "protocol.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/exact-export","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["export","id-lookup","latest","limit","relevance","sort"]},"parameters":{"id":{"type":"string","required":false},"query":{"type":"string","required":false}},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":[],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":65536}}},"operations":{},"projections":{"latest":{"slot":"events","pipeline":[{"op":"latest","path":"/record/id"},{"op":"export","fields":[{"name":"operation","path":"/record/operation"},{"name":"authority","path":"/record/authority"}]}]},"ordered":{"slot":"events","pipeline":[{"op":"id-lookup","path":"/record/id","param":"id"},{"op":"export","fields":[{"name":"operation","path":"/record/operation"},{"name":"authority","path":"/record/authority"}]}]},"query":{"slot":"events","pipeline":[{"op":"relevance","paths":["/record/operation","/record/authority"],"param":"query","mode":"literal"},{"op":"sort","keys":[{"meta":"relevance-score","order":"descending"},{"meta":"record-order","order":"descending"}]},{"op":"export","fields":[{"name":"operation","path":"/record/operation"},{"name":"authority","path":"/record/authority"}]},{"op":"limit","count":10}]},"raw":{"slot":"events","pipeline":[{"op":"id-lookup","path":"/record/id","param":"id"},{"op":"export","raw":true}]},"recall":{"slot":"events","pipeline":[{"op":"relevance","paths":["/record/operation","/record/authority"],"param":"query","mode":"tokens","score_field":"score"},{"op":"sort","keys":[{"meta":"relevance-score","order":"descending"},{"meta":"record-order","order":"descending"}]},{"op":"export","fields":[{"name":"operation","path":"/record/operation"},{"name":"authority","path":"/record/authority"}]},{"op":"limit","count":10}]},"recent":{"slot":"events","pipeline":[{"op":"sort","keys":[{"meta":"record-order","order":"descending"}]},{"op":"export","fields":[{"name":"operation","path":"/record/operation"},{"name":"authority","path":"/record/authority"}]},{"op":"limit","count":2}]},"required":{"slot":"events","pipeline":[{"op":"id-lookup","path":"/record/id","param":"id","required":true},{"op":"export","raw":true}]}},"bounds":{"max_input_bytes":4096,"max_store_bytes":65536,"max_records":100,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":16}}
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
        null,
    );
    defer plan.deinit(std.testing.allocator);

    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(&plan, &encoder);
    const cache_payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(cache_payload);
    var decoder = definition_core.cache.Decoder.init(cache_payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    const ordered = cached.find("ordered").?;
    try std.testing.expect(ordered.single);
    try std.testing.expect(ordered.preserve_field_order);
    try std.testing.expect(!ordered.raw);
    try std.testing.expectEqualStrings("operation", ordered.fields[0].name);
    try std.testing.expectEqualStrings("authority", ordered.fields[1].name);
    const raw = cached.find("raw").?;
    try std.testing.expect(raw.single);
    try std.testing.expect(raw.raw);
    try std.testing.expectEqual(@as(usize, 0), raw.fields.len);

    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "id", .raw_value = "r1" }},
    );
    defer bindings.deinit(std.testing.allocator);
    const rows =
        "{\"v\":1,\"record\":{\"id\":\"r1\",\"authority\":\"a1\",\"operation\":\"o1\"}}\n" ++
        "{\"record\":{\"operation\":\"o2\",\"id\":\"r2\",\"authority\":\"a2\"},\"v\":1}\n";

    var ordered_output: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer ordered_output.deinit();
    var ordered_stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeJsonl(
        std.testing.allocator,
        ordered,
        rows,
        &bindings,
        100,
        100,
        &ordered_output.writer,
        &ordered_stats,
    );
    try std.testing.expectEqualStrings(
        "{\"operation\":\"o1\",\"authority\":\"a1\"}",
        ordered_output.written(),
    );
    try std.testing.expectEqual(@as(usize, 1), ordered_stats.records_scanned);
    try std.testing.expectEqual(@as(usize, 1), ordered_stats.records_emitted);

    var raw_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer raw_output.deinit();
    var raw_stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeJsonl(
        std.testing.allocator,
        raw,
        rows,
        &bindings,
        100,
        100,
        &raw_output.writer,
        &raw_stats,
    );
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"record\":{\"id\":\"r1\",\"authority\":\"a1\",\"operation\":\"o1\"}}",
        raw_output.written(),
    );

    const recent = cached.find("recent").?;
    try std.testing.expectEqual(@as(usize, 1), recent.sort_keys.len);
    try std.testing.expect(recent.sort_keys[0].source == .record_order);
    try std.testing.expectEqual(
        SortOrder.descending,
        recent.sort_keys[0].order,
    );
    var recent_output: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer recent_output.deinit();
    var recent_stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeSortedJsonl(
        std.testing.allocator,
        recent,
        rows,
        &bindings,
        2,
        100,
        &recent_output.writer,
        &recent_stats,
    );
    try std.testing.expectEqualStrings(
        "[{\"operation\":\"o2\",\"authority\":\"a2\"}," ++
            "{\"operation\":\"o1\",\"authority\":\"a1\"}]",
        recent_output.written(),
    );
    try std.testing.expectEqual(@as(usize, 2), recent_stats.records_scanned);
    try std.testing.expectEqual(@as(usize, 2), recent_stats.records_emitted);

    var query_bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "query", .raw_value = "O2 A2" }},
    );
    defer query_bindings.deinit(std.testing.allocator);
    const query_projection = cached.find("query").?;
    try std.testing.expect(query_projection.relevance != null);
    try std.testing.expectEqual(
        RelevanceMode.literal,
        query_projection.relevance.?.mode,
    );
    var query_output: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer query_output.deinit();
    var query_stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeSortedJsonl(
        std.testing.allocator,
        query_projection,
        rows,
        &query_bindings,
        10,
        100,
        &query_output.writer,
        &query_stats,
    );
    try std.testing.expectEqualStrings(
        "[{\"operation\":\"o2\",\"authority\":\"a2\"}]",
        query_output.written(),
    );
    try std.testing.expectEqual(@as(usize, 1), query_stats.records_matched);

    var recall_bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "query", .raw_value = "o1 a2" }},
    );
    defer recall_bindings.deinit(std.testing.allocator);
    const recall = cached.find("recall").?;
    try std.testing.expectEqualStrings(
        "score",
        recall.relevance.?.score_field.?,
    );
    var recall_output: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer recall_output.deinit();
    var recall_stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeSortedJsonl(
        std.testing.allocator,
        recall,
        rows,
        &recall_bindings,
        10,
        100,
        &recall_output.writer,
        &recall_stats,
    );
    try std.testing.expectEqualStrings(
        "[{\"score\":1,\"operation\":\"o2\",\"authority\":\"a2\"}," ++
            "{\"score\":1,\"operation\":\"o1\",\"authority\":\"a1\"}]",
        recall_output.written(),
    );
    try std.testing.expectEqual(@as(usize, 2), recall_stats.records_matched);

    const latest = cached.find("latest").?;
    try std.testing.expect(latest.single);
    var latest_output: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer latest_output.deinit();
    var latest_stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeJsonl(
        std.testing.allocator,
        latest,
        rows,
        &bindings,
        100,
        100,
        &latest_output.writer,
        &latest_stats,
    );
    try std.testing.expectEqualStrings(
        "{\"operation\":\"o2\",\"authority\":\"a2\"}",
        latest_output.written(),
    );
    try std.testing.expectEqual(@as(usize, 2), latest_stats.records_scanned);

    var missing_bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{.{ .name = "id", .raw_value = "missing" }},
    );
    defer missing_bindings.deinit(std.testing.allocator);
    const required = cached.find("required").?;
    try std.testing.expect(required.require_match);
    var missing_output: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer missing_output.deinit();
    var missing_stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try std.testing.expectError(
        error.ProjectionNotFound,
        executeJsonl(
            std.testing.allocator,
            required,
            rows,
            &missing_bindings,
            100,
            100,
            &missing_output.writer,
            &missing_stats,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), missing_stats.records_scanned);
}
