const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const physical = @import("physical.zig");

pub const ColumnKind = enum {
    string,
    integer,
    float,
    boolean,
    json,
};

pub const Column = struct {
    name: []u8,
    kind: ColumnKind,
    nullable: bool,

    fn deinit(self: *Column, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Schema = struct {
    columns: []Column,

    fn deinit(self: *Schema, allocator: std.mem.Allocator) void {
        for (self.columns) |*column| column.deinit(allocator);
        allocator.free(self.columns);
        self.* = undefined;
    }

    pub fn find(self: *const Schema, name: []const u8) ?u16 {
        for (self.columns, 0..) |column, index| {
            if (std.mem.eql(u8, column.name, name)) return @intCast(index);
        }
        return null;
    }
};

pub const SourceRef = union(enum) {
    stage: u16,
    external: u16,
};

pub const Scan = struct {
    relation: physical.Relation,
    field_indices: []u16,

    fn deinit(self: *Scan, allocator: std.mem.Allocator) void {
        allocator.free(self.field_indices);
        self.* = undefined;
    }
};

pub const PredicateOperator = enum {
    exact,
    not_equal,
    contains,
    prefix,
    suffix,

    fn parse(raw: []const u8) !PredicateOperator {
        if (std.mem.eql(u8, raw, "exact") or
            std.mem.eql(u8, raw, "eq"))
        {
            return .exact;
        }
        if (std.mem.eql(u8, raw, "not-equal") or
            std.mem.eql(u8, raw, "ne"))
        {
            return .not_equal;
        }
        if (std.mem.eql(u8, raw, "contains")) return .contains;
        if (std.mem.eql(u8, raw, "prefix")) return .prefix;
        if (std.mem.eql(u8, raw, "suffix")) return .suffix;
        return error.UnsupportedFilterPredicate;
    }

    fn requiresString(self: PredicateOperator) bool {
        return switch (self) {
            .contains, .prefix, .suffix => true,
            .exact, .not_equal => false,
        };
    }
};

pub const Constant = union(enum) {
    string: []u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null,

    fn deinit(self: *Constant, allocator: std.mem.Allocator) void {
        if (self.* == .string) allocator.free(self.string);
        self.* = undefined;
    }
};

pub const Operand = union(enum) {
    parameter: u16,
    constant: Constant,

    fn deinit(self: *Operand, allocator: std.mem.Allocator) void {
        if (self.* == .constant) self.constant.deinit(allocator);
        self.* = undefined;
    }
};

pub const Predicate = struct {
    field_index: u16,
    operator: PredicateOperator,
    operand: Operand,
    case_insensitive: bool,

    fn deinit(self: *Predicate, allocator: std.mem.Allocator) void {
        self.operand.deinit(allocator);
        self.* = undefined;
    }
};

pub const Filter = struct {
    predicates: []Predicate,

    fn deinit(self: *Filter, allocator: std.mem.Allocator) void {
        for (self.predicates) |*predicate| predicate.deinit(allocator);
        allocator.free(self.predicates);
        self.* = undefined;
    }
};

pub const Project = struct {
    input_field_indices: []u16,

    fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        allocator.free(self.input_field_indices);
        self.* = undefined;
    }
};

pub const Limit = union(enum) {
    fixed: usize,
    parameter: u16,
};

pub const Operation = union(enum) {
    scan: Scan,
    filter: Filter,
    project: Project,
    alias,
    limit: Limit,

    fn deinit(self: *Operation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scan => |*value| value.deinit(allocator),
            .filter => |*value| value.deinit(allocator),
            .project => |*value| value.deinit(allocator),
            .alias, .limit => {},
        }
        self.* = undefined;
    }
};

pub const Stage = struct {
    name: []u8,
    source: ?SourceRef,
    operation: Operation,
    schema: Schema,

    fn deinit(self: *Stage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.operation.deinit(allocator);
        self.schema.deinit(allocator);
        self.* = undefined;
    }
};

pub const Projection = struct {
    definition_index: u16,
    stage_index: u16,
    field_indices: []u16,

    fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.field_indices);
        self.* = undefined;
    }
};

pub const Plan = struct {
    stages: []Stage,
    projections: []Projection,
    max_rows: usize,
    max_output_bytes: usize,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.stages) |*stage| stage.deinit(allocator);
        allocator.free(self.stages);
        for (self.projections) |*projection| projection.deinit(allocator);
        allocator.free(self.projections);
        self.* = undefined;
    }

    pub fn findStage(self: *const Plan, name: []const u8) ?u16 {
        for (self.stages, 0..) |stage, index| {
            if (std.mem.eql(u8, stage.name, name)) return @intCast(index);
        }
        return null;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !Plan {
    var stages: std.ArrayList(Stage) = .empty;
    errdefer {
        for (stages.items) |*stage| stage.deinit(allocator);
        stages.deinit(allocator);
    }
    for (definition_plan.steps) |source| {
        var stage = try compileStage(
            allocator,
            definition_plan,
            stages.items,
            source,
        );
        errdefer stage.deinit(allocator);
        try stages.append(allocator, stage);
    }
    const stage_slice = try stages.toOwnedSlice(allocator);
    errdefer {
        for (stage_slice) |*stage| stage.deinit(allocator);
        allocator.free(stage_slice);
    }
    const projections = try compileProjections(
        allocator,
        definition_plan,
        stage_slice,
    );
    return .{
        .stages = stage_slice,
        .projections = projections,
        .max_rows = definition_plan.bounds.max_rows,
        .max_output_bytes = definition_plan.bounds.max_output_bytes,
    };
}

fn compileStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
) !Stage {
    const output_name = source.output_name orelse
        return error.PipelineStageOutputMissing;
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
    var operation: Operation = undefined;
    var schema: Schema = undefined;
    var source_ref: ?SourceRef = null;
    switch (source.operator) {
        .scan => {
            const relation = try physical.Relation.parse(
                try definition_core.json.requiredString(object, "relation"),
            );
            const requirement = findRelation(
                definition_plan.relations,
                relation,
            ) orelse return error.UndeclaredPhysicalRelation;
            const field_indices = try allocator.dupe(
                u16,
                requirement.fields,
            );
            errdefer allocator.free(field_indices);
            schema = try schemaFromPhysical(
                allocator,
                relation,
                field_indices,
            );
            operation = .{ .scan = .{
                .relation = relation,
                .field_indices = field_indices,
            } };
        },
        .filter => {
            source_ref = try resolveSource(
                definition_plan,
                prior_stages,
                source.input_names[0],
            );
            schema = try cloneSourceSchema(
                allocator,
                definition_plan,
                prior_stages,
                source_ref.?,
            );
            errdefer schema.deinit(allocator);
            const predicates = try compilePredicates(
                allocator,
                definition_plan,
                &schema,
                try definition_core.json.array(
                    try definition_core.json.field(object, "where"),
                ),
            );
            errdefer {
                for (predicates) |*predicate| predicate.deinit(allocator);
                allocator.free(predicates);
            }
            operation = .{ .filter = .{ .predicates = predicates } };
        },
        .project => {
            source_ref = try resolveSource(
                definition_plan,
                prior_stages,
                source.input_names[0],
            );
            var input_schema = try cloneSourceSchema(
                allocator,
                definition_plan,
                prior_stages,
                source_ref.?,
            );
            defer input_schema.deinit(allocator);
            const field_indices = try compileFieldSelection(
                allocator,
                &input_schema,
                try definition_core.json.array(
                    try definition_core.json.field(object, "fields"),
                ),
            );
            errdefer allocator.free(field_indices);
            schema = try projectSchema(
                allocator,
                &input_schema,
                field_indices,
            );
            operation = .{ .project = .{
                .input_field_indices = field_indices,
            } };
        },
        .named_relation, .result_projection => {
            source_ref = try resolveSource(
                definition_plan,
                prior_stages,
                source.input_names[0],
            );
            schema = try cloneSourceSchema(
                allocator,
                definition_plan,
                prior_stages,
                source_ref.?,
            );
            operation = .alias;
        },
        .limit => {
            source_ref = try resolveSource(
                definition_plan,
                prior_stages,
                source.input_names[0],
            );
            operation = .{ .limit = try compileLimit(
                definition_plan,
                object,
            ) };
            schema = try cloneSourceSchema(
                allocator,
                definition_plan,
                prior_stages,
                source_ref.?,
            );
        },
        else => return error.ObservationOperatorPlanNotCompiled,
    }
    errdefer operation.deinit(allocator);
    errdefer schema.deinit(allocator);
    return .{
        .name = try allocator.dupe(u8, output_name),
        .source = source_ref,
        .operation = operation,
        .schema = schema,
    };
}

fn compilePredicates(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    schema: *const Schema,
    values: std.json.Array,
) ![]Predicate {
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidFilterPredicateCount;
    }
    const predicates = try allocator.alloc(Predicate, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (predicates[0..initialized]) |*predicate| {
            predicate.deinit(allocator);
        }
        allocator.free(predicates);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "field", "op", "param", "value", "case_insensitive" },
        );
        try definition_core.json.requireFields(object, &.{ "field", "op" });
        const field_index = schema.find(
            try definition_core.json.requiredString(object, "field"),
        ) orelse return error.UnknownFilterField;
        const operator = try PredicateOperator.parse(
            try definition_core.json.requiredString(object, "op"),
        );
        const parameter = object.get("param");
        const constant = object.get("value");
        if ((parameter != null) == (constant != null)) {
            return error.FilterOperandMustBeExact;
        }
        var operand: Operand = if (parameter) |raw|
            .{ .parameter = try parameterIndex(
                &definition_plan.parameter_declarations,
                try definition_core.json.string(raw),
            ) }
        else
            .{ .constant = try constantFromJson(allocator, constant.?) };
        errdefer operand.deinit(allocator);
        const case_insensitive = if (object.get("case_insensitive")) |raw|
            try definition_core.json.boolean(raw)
        else
            false;
        try validatePredicateTypes(
            definition_plan,
            schema.columns[field_index],
            operator,
            operand,
            case_insensitive,
        );
        predicates[index] = .{
            .field_index = field_index,
            .operator = operator,
            .operand = operand,
            .case_insensitive = case_insensitive,
        };
        initialized += 1;
    }
    return predicates;
}

fn compileFieldSelection(
    allocator: std.mem.Allocator,
    schema: *const Schema,
    values: std.json.Array,
) ![]u16 {
    if (values.items.len == 0 or values.items.len > 256) {
        return error.InvalidProjectionFieldCount;
    }
    const indices = try allocator.alloc(u16, values.items.len);
    errdefer allocator.free(indices);
    for (values.items, 0..) |value, index| {
        const field_index = schema.find(
            try definition_core.json.string(value),
        ) orelse return error.UnknownProjectionField;
        for (indices[0..index]) |prior| if (prior == field_index) {
            return error.DuplicateProjectionField;
        };
        indices[index] = field_index;
    }
    return indices;
}

fn compileLimit(
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !Limit {
    const value = try definition_core.json.field(object, "limit");
    return switch (value) {
        .integer => |count| if (count > 0 and
            std.math.cast(usize, count) != null and
            @as(usize, @intCast(count)) <= definition_plan.bounds.max_rows)
            .{ .fixed = @intCast(count) }
        else
            error.InvalidObservationLimit,
        .string => |name| parameter: {
            const index = try parameterIndex(
                &definition_plan.parameter_declarations,
                name,
            );
            if (definition_plan.parameter_declarations.items[index].kind !=
                .integer)
            {
                return error.ObservationLimitParameterMustBeInteger;
            }
            break :parameter .{ .parameter = index };
        },
        else => error.InvalidObservationLimit,
    };
}

fn compileProjections(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    stages: []const Stage,
) ![]Projection {
    const projections = try allocator.alloc(
        Projection,
        definition_plan.projections.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (projections[0..initialized]) |*projection| {
            projection.deinit(allocator);
        }
        allocator.free(projections);
    }
    for (definition_plan.projections, 0..) |source, index| {
        const stage_index = findStageIndex(
            stages,
            source.relation,
        ) orelse return error.UnknownProjectionRelation;
        const schema = &stages[stage_index].schema;
        const fields = try allocator.alloc(u16, source.fields.len);
        errdefer allocator.free(fields);
        for (source.fields, 0..) |field, field_index| {
            fields[field_index] = schema.find(field) orelse
                return error.UnknownProjectionField;
            for (fields[0..field_index]) |prior| {
                if (prior == fields[field_index]) {
                    return error.DuplicateProjectionField;
                }
            }
        }
        projections[index] = .{
            .definition_index = @intCast(index),
            .stage_index = stage_index,
            .field_indices = fields,
        };
        initialized += 1;
    }
    return projections;
}

fn schemaFromPhysical(
    allocator: std.mem.Allocator,
    relation: physical.Relation,
    field_indices: []const u16,
) !Schema {
    const fields = relation.fields();
    const columns = try allocator.alloc(Column, field_indices.len);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |*column| column.deinit(allocator);
        allocator.free(columns);
    }
    for (field_indices, 0..) |field_index, index| {
        if (field_index >= fields.len) return error.PhysicalFieldIndexInvalid;
        const field = fields[field_index];
        columns[index] = .{
            .name = try allocator.dupe(u8, field.name),
            .kind = physicalKind(field.kind),
            .nullable = field.nullable,
        };
        initialized += 1;
    }
    return .{ .columns = columns };
}

fn schemaFromExternal(
    allocator: std.mem.Allocator,
    input: definition.ExternalInput,
) !Schema {
    const columns = try allocator.alloc(Column, input.fields.len);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |*column| column.deinit(allocator);
        allocator.free(columns);
    }
    for (input.fields, 0..) |field, index| {
        columns[index] = .{
            .name = try allocator.dupe(u8, field.name),
            .kind = externalKind(field.kind),
            .nullable = field.nullable,
        };
        initialized += 1;
    }
    return .{ .columns = columns };
}

fn cloneSchema(
    allocator: std.mem.Allocator,
    source: *const Schema,
) !Schema {
    const columns = try allocator.alloc(Column, source.columns.len);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |*column| column.deinit(allocator);
        allocator.free(columns);
    }
    for (source.columns, 0..) |column, index| {
        columns[index] = .{
            .name = try allocator.dupe(u8, column.name),
            .kind = column.kind,
            .nullable = column.nullable,
        };
        initialized += 1;
    }
    return .{ .columns = columns };
}

fn projectSchema(
    allocator: std.mem.Allocator,
    source: *const Schema,
    indices: []const u16,
) !Schema {
    const columns = try allocator.alloc(Column, indices.len);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |*column| column.deinit(allocator);
        allocator.free(columns);
    }
    for (indices, 0..) |source_index, index| {
        if (source_index >= source.columns.len) {
            return error.ProjectionFieldIndexInvalid;
        }
        const column = source.columns[source_index];
        columns[index] = .{
            .name = try allocator.dupe(u8, column.name),
            .kind = column.kind,
            .nullable = column.nullable,
        };
        initialized += 1;
    }
    return .{ .columns = columns };
}

fn resolveSource(
    definition_plan: *const definition.Plan,
    stages: []const Stage,
    name: []const u8,
) !SourceRef {
    if (findStageIndex(stages, name)) |index| {
        return .{ .stage = index };
    }
    for (definition_plan.inputs, 0..) |input, index| {
        if (std.mem.eql(u8, input.name, name)) {
            return .{ .external = @intCast(index) };
        }
    }
    if (physical.Relation.parse(name)) |_| {
        return error.PhysicalRelationRequiresScan;
    } else |_| {}
    return error.UnknownPipelineInput;
}

fn cloneSourceSchema(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    stages: []const Stage,
    source: SourceRef,
) !Schema {
    return switch (source) {
        .stage => |index| cloneSchema(allocator, &stages[index].schema),
        .external => |index| schemaFromExternal(
            allocator,
            definition_plan.inputs[index],
        ),
    };
}

fn findRelation(
    relations: []const definition.RelationRequirement,
    relation: physical.Relation,
) ?*const definition.RelationRequirement {
    for (relations) |*requirement| {
        if (requirement.relation == relation) return requirement;
    }
    return null;
}

fn findStageIndex(stages: []const Stage, name: []const u8) ?u16 {
    for (stages, 0..) |stage, index| {
        if (std.mem.eql(u8, stage.name, name)) return @intCast(index);
    }
    return null;
}

fn parameterIndex(
    declarations: *const definition_core.parameters.Declarations,
    name: []const u8,
) !u16 {
    for (declarations.items, 0..) |declaration, index| {
        if (std.mem.eql(u8, declaration.name, name)) return @intCast(index);
    }
    return error.UnknownObservationParameter;
}

fn constantFromJson(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !Constant {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .integer => |number| .{ .integer = number },
        .float => |number| if (std.math.isFinite(number))
            .{ .float = number }
        else
            error.InvalidFilterConstant,
        .bool => |flag| .{ .boolean = flag },
        .null => .null,
        .number_string, .array, .object => error.InvalidFilterConstant,
    };
}

fn validatePredicateTypes(
    definition_plan: *const definition.Plan,
    column: Column,
    operator: PredicateOperator,
    operand: Operand,
    case_insensitive: bool,
) !void {
    if ((operator.requiresString() or case_insensitive) and
        column.kind != .string)
    {
        return error.FilterPredicateTypeMismatch;
    }
    const operand_kind: ColumnKind = switch (operand) {
        .constant => |constant| switch (constant) {
            .string => .string,
            .integer => .integer,
            .float => .float,
            .boolean => .boolean,
            .null => return if (column.nullable and
                !operator.requiresString() and
                !case_insensitive)
                {}
            else
                error.FilterPredicateTypeMismatch,
        },
        .parameter => |index| parameterColumnKind(
            definition_plan.parameter_declarations.items[index].kind,
        ),
    };
    if (column.kind == .float and operand_kind == .integer) return;
    if (column.kind != operand_kind) {
        return error.FilterPredicateTypeMismatch;
    }
}

fn physicalKind(kind: physical.ScalarKind) ColumnKind {
    return switch (kind) {
        .string => .string,
        .integer => .integer,
        .boolean => .boolean,
        .json => .json,
    };
}

fn externalKind(kind: definition.ExternalScalarKind) ColumnKind {
    return switch (kind) {
        .string => .string,
        .integer => .integer,
        .float => .float,
        .boolean => .boolean,
        .json => .json,
    };
}

fn parameterColumnKind(kind: definition_core.scalar.Kind) ColumnKind {
    return switch (kind) {
        .integer => .integer,
        .boolean => .boolean,
        .string,
        .digest,
        .timestamp,
        .safe_identifier,
        .relative_path,
        => .string,
    };
}

fn compileForAllocationFailure(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !void {
    var compiled = try compile(allocator, definition_plan);
    defer compiled.deinit(allocator);
}

test "observation steps compile field names and parameters to native indices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/messages","requires":{"abi":"seq-observation-abi/v1","operators":["scan","filter","project","limit"]},"parameters":{"needle":{"type":"string","required":true}},"selectors":["path"],"relations":[{"name":"messages","fields":["session_id","role","text"]}],"inputs":[],"pipeline":[{"op":"scan","relation":"messages","as":"source"},{"op":"filter","input":"source","as":"matched","where":[{"field":"text","op":"contains","param":"needle"}]},{"op":"project","input":"matched","as":"rows","fields":["session_id","role","text"]},{"op":"limit","input":"rows","as":"bounded","limit":5}],"projections":{"rows":{"relation":"bounded","schema":"example-message-rows/v1","fields":["session_id","role","text"],"renderers":["json"]}},"bounds":{"max_rows":100,"max_output_bytes":4096,"max_fold_states":8}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "observation.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "observation.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), plan.stages.len);
    try std.testing.expectEqual(
        physical.Relation.messages,
        plan.stages[0].operation.scan.relation,
    );
    try std.testing.expectEqual(@as(u16, 2), plan.stages[1].operation.filter.predicates[0].field_index);
    try std.testing.expectEqual(
        @as(u16, 0),
        plan.stages[1].operation.filter.predicates[0].operand.parameter,
    );
    try std.testing.expectEqual(@as(usize, 3), plan.stages[2].schema.columns.len);
    try std.testing.expectEqual(@as(usize, 5), plan.stages[3].operation.limit.fixed);
    try std.testing.expectEqual(@as(usize, 1), plan.projections.len);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{&definition_plan},
    );
}

test "external relations compile to the same typed native stage schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/external","requires":{"abi":"seq-observation-abi/v1","operators":["filter","project"]},"parameters":{},"selectors":[],"relations":[],"inputs":[{"name":"facts","schema":"example-facts/v1","fields":[{"name":"id","type":"string","nullable":false},{"name":"score","type":"integer","nullable":false}],"max_rows":10,"max_bytes":4096}],"pipeline":[{"op":"filter","input":"facts","as":"matched","where":[{"field":"score","op":"exact","value":1}]},{"op":"project","input":"matched","as":"rows","fields":["id"]}],"projections":{"rows":{"relation":"rows","schema":"example-rows/v1","fields":["id"],"renderers":["json"]}},"bounds":{"max_rows":10,"max_output_bytes":4096,"max_fold_states":2}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "observation.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "observation.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        @as(u16, 0),
        plan.stages[0].source.?.external,
    );
    try std.testing.expectEqual(
        ColumnKind.integer,
        plan.stages[0].schema.columns[1].kind,
    );
    try std.testing.expectEqualStrings(
        "id",
        plan.stages[1].schema.columns[0].name,
    );
}
