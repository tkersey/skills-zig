const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const physical = @import("physical.zig");

pub fn supports(operator: definition.Operator) bool {
    return switch (operator) {
        .scan,
        .filter,
        .project,
        .aggregate,
        .limit,
        .sort,
        .top_k,
        .distinct,
        .named_relation,
        .result_projection,
        => true,
        else => false,
    };
}

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
    mode: FilterMode,
    predicates: []Predicate,

    fn deinit(self: *Filter, allocator: std.mem.Allocator) void {
        for (self.predicates) |*predicate| predicate.deinit(allocator);
        allocator.free(self.predicates);
        self.* = undefined;
    }
};

pub const FilterMode = enum {
    all,
    any,

    fn parse(raw: []const u8) !FilterMode {
        inline for (@typeInfo(FilterMode).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return error.InvalidFilterMode;
    }
};

pub const Project = struct {
    input_field_indices: []u16,

    fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        allocator.free(self.input_field_indices);
        self.* = undefined;
    }
};

pub const AggregateFunction = enum {
    count,
    sum,
    min,
    max,
    average,

    fn parse(raw: []const u8) !AggregateFunction {
        inline for (@typeInfo(AggregateFunction).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        if (std.mem.eql(u8, raw, "avg")) return .average;
        return error.UnsupportedObservationAggregate;
    }
};

pub const AggregateMetric = struct {
    function: AggregateFunction,
    field_index: ?u16,
};

pub const Aggregate = struct {
    metrics: []AggregateMetric,

    fn deinit(self: *Aggregate, allocator: std.mem.Allocator) void {
        allocator.free(self.metrics);
        self.* = undefined;
    }
};

pub const Limit = union(enum) {
    fixed: usize,
    parameter: u16,
};

pub const SortDirection = enum {
    ascending,
    descending,

    fn parse(raw: []const u8) !SortDirection {
        if (std.mem.eql(u8, raw, "asc")) return .ascending;
        if (std.mem.eql(u8, raw, "desc")) return .descending;
        return error.InvalidObservationSortDirection;
    }
};

pub const NullOrder = enum {
    first,
    last,

    fn parse(raw: []const u8) !NullOrder {
        if (std.mem.eql(u8, raw, "first")) return .first;
        if (std.mem.eql(u8, raw, "last")) return .last;
        return error.InvalidObservationNullOrder;
    }
};

pub const SortKey = struct {
    field_index: u16,
    direction: SortDirection,
    nulls: NullOrder,
};

pub const Sort = struct {
    keys: []SortKey,

    fn deinit(self: *Sort, allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
        self.* = undefined;
    }
};

pub const Distinct = struct {
    field_indices: []u16,

    fn deinit(self: *Distinct, allocator: std.mem.Allocator) void {
        allocator.free(self.field_indices);
        self.* = undefined;
    }
};

pub const TopK = struct {
    keys: []SortKey,
    limit: Limit,

    fn deinit(self: *TopK, allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
        self.* = undefined;
    }
};

pub const Operation = union(enum) {
    scan: Scan,
    filter: Filter,
    project: Project,
    aggregate: Aggregate,
    alias,
    limit: Limit,
    sort: Sort,
    top_k: TopK,
    distinct: Distinct,

    fn deinit(self: *Operation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scan => |*value| value.deinit(allocator),
            .filter => |*value| value.deinit(allocator),
            .project => |*value| value.deinit(allocator),
            .aggregate => |*value| value.deinit(allocator),
            .sort => |*value| value.deinit(allocator),
            .top_k => |*value| value.deinit(allocator),
            .distinct => |*value| value.deinit(allocator),
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
            .parse_numbers = false,
        },
    );
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    var body = try compileStageBody(
        allocator,
        definition_plan,
        prior_stages,
        source,
        object,
    );
    errdefer body.deinit(allocator);
    return .{
        .name = try allocator.dupe(u8, output_name),
        .source = body.source,
        .operation = body.operation,
        .schema = body.schema,
    };
}

fn compileStageBody(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    return switch (source.operator) {
        .scan => try compileScanStage(allocator, definition_plan, object),
        .filter => try compileFilterStage(
            allocator,
            definition_plan,
            prior_stages,
            source,
            object,
        ),
        .project => try compileProjectStage(
            allocator,
            definition_plan,
            prior_stages,
            source,
            object,
        ),
        .aggregate => try compileAggregateStage(
            allocator,
            definition_plan,
            prior_stages,
            source,
            object,
        ),
        else => try compilePassThroughStageBody(
            allocator,
            definition_plan,
            prior_stages,
            source,
            object,
        ),
    };
}

fn compilePassThroughStageBody(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    return switch (source.operator) {
        .named_relation,
        .result_projection,
        => try compileAliasStage(
            allocator,
            definition_plan,
            prior_stages,
            source,
        ),
        .limit => try compileLimitStage(
            allocator,
            definition_plan,
            prior_stages,
            source,
            object,
        ),
        .sort => try compileSortStage(
            allocator,
            definition_plan,
            prior_stages,
            source,
            object,
        ),
        .top_k => try compileTopKStage(
            allocator,
            definition_plan,
            prior_stages,
            source,
            object,
        ),
        .distinct => try compileDistinctStage(
            allocator,
            definition_plan,
            prior_stages,
            source,
            object,
        ),
        else => error.ObservationOperatorPlanNotCompiled,
    };
}

const StageBody = struct {
    source: ?SourceRef,
    operation: Operation,
    schema: Schema,

    fn deinit(self: *StageBody, allocator: std.mem.Allocator) void {
        self.operation.deinit(allocator);
        self.schema.deinit(allocator);
        self.* = undefined;
    }
};

const InputStage = struct {
    source: SourceRef,
    schema: Schema,

    fn deinit(self: *InputStage, allocator: std.mem.Allocator) void {
        self.schema.deinit(allocator);
        self.* = undefined;
    }
};

fn compileInputStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
) !InputStage {
    const source_ref = try resolveSource(
        definition_plan,
        prior_stages,
        source.input_names[0],
    );
    return .{
        .source = source_ref,
        .schema = try cloneSourceSchema(
            allocator,
            definition_plan,
            prior_stages,
            source_ref,
        ),
    };
}

fn compileScanStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !StageBody {
    const relation = try physical.Relation.parse(
        try definition_core.json.requiredString(object, "relation"),
    );
    const requirement = findRelation(
        definition_plan.relations,
        relation,
    ) orelse return error.UndeclaredPhysicalRelation;
    const field_indices = try allocator.dupe(u16, requirement.fields);
    errdefer allocator.free(field_indices);
    return .{
        .source = null,
        .operation = .{ .scan = .{
            .relation = relation,
            .field_indices = field_indices,
        } },
        .schema = try schemaFromPhysical(
            allocator,
            relation,
            field_indices,
        ),
    };
}

fn compileFilterStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    var input = try compileInputStage(
        allocator,
        definition_plan,
        prior_stages,
        source,
    );
    errdefer input.deinit(allocator);
    const predicates = try compilePredicates(
        allocator,
        definition_plan,
        &input.schema,
        try definition_core.json.array(
            try definition_core.json.field(object, "where"),
        ),
    );
    return .{
        .source = input.source,
        .operation = .{ .filter = .{
            .mode = if (object.get("where_mode")) |raw|
                try FilterMode.parse(try definition_core.json.string(raw))
            else
                .all,
            .predicates = predicates,
        } },
        .schema = input.schema,
    };
}

fn compileProjectStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    var input = try compileInputStage(
        allocator,
        definition_plan,
        prior_stages,
        source,
    );
    defer input.deinit(allocator);
    const field_indices = try compileFieldSelection(
        allocator,
        &input.schema,
        try definition_core.json.array(
            try definition_core.json.field(object, "fields"),
        ),
    );
    errdefer allocator.free(field_indices);
    return .{
        .source = input.source,
        .operation = .{ .project = .{
            .input_field_indices = field_indices,
        } },
        .schema = try projectSchema(
            allocator,
            &input.schema,
            field_indices,
        ),
    };
}

fn compileAggregateStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    var input = try compileInputStage(
        allocator,
        definition_plan,
        prior_stages,
        source,
    );
    defer input.deinit(allocator);
    const compiled = try compileAggregate(
        allocator,
        &input.schema,
        object,
    );
    return .{
        .source = input.source,
        .operation = .{ .aggregate = compiled.aggregate },
        .schema = compiled.schema,
    };
}

fn compileAliasStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
) !StageBody {
    const input = try compileInputStage(
        allocator,
        definition_plan,
        prior_stages,
        source,
    );
    return .{
        .source = input.source,
        .operation = .alias,
        .schema = input.schema,
    };
}

fn compileLimitStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    var input = try compileInputStage(
        allocator,
        definition_plan,
        prior_stages,
        source,
    );
    errdefer input.deinit(allocator);
    const limit = try compileLimit(definition_plan, object);
    return .{
        .source = input.source,
        .operation = .{ .limit = limit },
        .schema = input.schema,
    };
}

fn compileSortStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    var input = try compileInputStage(
        allocator,
        definition_plan,
        prior_stages,
        source,
    );
    errdefer input.deinit(allocator);
    return .{
        .source = input.source,
        .operation = .{ .sort = try compileSort(
            allocator,
            &input.schema,
            object,
        ) },
        .schema = input.schema,
    };
}

fn compileTopKStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    var input = try compileInputStage(
        allocator,
        definition_plan,
        prior_stages,
        source,
    );
    errdefer input.deinit(allocator);
    var sort = try compileSort(allocator, &input.schema, object);
    errdefer sort.deinit(allocator);
    const limit = try compileLimit(definition_plan, object);
    return .{
        .source = input.source,
        .operation = .{ .top_k = .{
            .keys = sort.keys,
            .limit = limit,
        } },
        .schema = input.schema,
    };
}

fn compileDistinctStage(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    prior_stages: []const Stage,
    source: definition.Step,
    object: std.json.ObjectMap,
) !StageBody {
    var input = try compileInputStage(
        allocator,
        definition_plan,
        prior_stages,
        source,
    );
    errdefer input.deinit(allocator);
    return .{
        .source = input.source,
        .operation = .{ .distinct = try compileDistinct(
            allocator,
            &input.schema,
            object,
        ) },
        .schema = input.schema,
    };
}

const AggregateCompilation = struct {
    aggregate: Aggregate,
    schema: Schema,

    fn deinit(self: *AggregateCompilation, allocator: std.mem.Allocator) void {
        self.aggregate.deinit(allocator);
        self.schema.deinit(allocator);
        self.* = undefined;
    }
};

fn compileAggregate(
    allocator: std.mem.Allocator,
    input_schema: *const Schema,
    object: std.json.ObjectMap,
) !AggregateCompilation {
    const values = try definition_core.json.array(
        try definition_core.json.field(object, "metrics"),
    );
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidObservationAggregateMetricCount;
    }
    const metrics = try allocator.alloc(AggregateMetric, values.items.len);
    errdefer allocator.free(metrics);
    const columns = try allocator.alloc(Column, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |*column| column.deinit(allocator);
        allocator.free(columns);
    }
    for (values.items, 0..) |value, index| {
        const compiled = try compileAggregateMetric(
            allocator,
            input_schema,
            columns[0..index],
            value,
        );
        metrics[index] = compiled.metric;
        columns[index] = compiled.column;
        initialized += 1;
    }
    return .{
        .aggregate = .{ .metrics = metrics },
        .schema = .{ .columns = columns },
    };
}

const AggregateMetricCompilation = struct {
    metric: AggregateMetric,
    column: Column,
};

fn compileAggregateMetric(
    allocator: std.mem.Allocator,
    input_schema: *const Schema,
    prior_columns: []const Column,
    value: std.json.Value,
) !AggregateMetricCompilation {
    const object = try definition_core.json.object(value);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "name", "op", "field" },
    );
    try definition_core.json.requireFields(object, &.{ "name", "op" });
    const name = try definition_core.json.requiredString(object, "name");
    try definition_core.json.safeIdentifier(name, 128);
    for (prior_columns) |prior| {
        if (std.mem.eql(u8, prior.name, name)) {
            return error.DuplicateObservationAggregateName;
        }
    }
    const function = try AggregateFunction.parse(
        try definition_core.json.requiredString(object, "op"),
    );
    const field_index = if (object.get("field")) |raw|
        input_schema.find(try definition_core.json.string(raw)) orelse
            return error.UnknownObservationAggregateField
    else
        null;
    if (function != .count and field_index == null) {
        return error.ObservationAggregateFieldRequired;
    }
    const input_kind = if (field_index) |field|
        input_schema.columns[field].kind
    else
        .integer;
    if (field_index != null and
        input_kind != .integer and
        input_kind != .float)
    {
        return error.ObservationAggregateFieldMustBeNumeric;
    }
    const output_kind: ColumnKind = switch (function) {
        .count => .integer,
        .average => .float,
        .sum, .min, .max => input_kind,
    };
    return .{
        .metric = .{ .function = function, .field_index = field_index },
        .column = .{
            .name = try allocator.dupe(u8, name),
            .kind = output_kind,
            .nullable = function == .average or
                function == .min or
                function == .max,
        },
    };
}

fn compileSort(
    allocator: std.mem.Allocator,
    schema: *const Schema,
    object: std.json.ObjectMap,
) !Sort {
    const values = try definition_core.json.array(
        try definition_core.json.field(object, "by"),
    );
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidObservationSortKeyCount;
    }
    const keys = try allocator.alloc(SortKey, values.items.len);
    errdefer allocator.free(keys);
    for (values.items, 0..) |value, index| {
        const key = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            key,
            &.{ "field", "direction", "nulls" },
        );
        try definition_core.json.requireFields(key, &.{"field"});
        const field_index = schema.find(
            try definition_core.json.requiredString(key, "field"),
        ) orelse return error.UnknownObservationSortField;
        for (keys[0..index]) |prior| {
            if (prior.field_index == field_index) {
                return error.DuplicateObservationSortField;
            }
        }
        keys[index] = .{
            .field_index = field_index,
            .direction = if (key.get("direction")) |raw|
                try SortDirection.parse(
                    try definition_core.json.string(raw),
                )
            else
                .ascending,
            .nulls = if (key.get("nulls")) |raw|
                try NullOrder.parse(try definition_core.json.string(raw))
            else
                .last,
        };
    }
    return .{ .keys = keys };
}

fn compileDistinct(
    allocator: std.mem.Allocator,
    schema: *const Schema,
    object: std.json.ObjectMap,
) !Distinct {
    const values = try definition_core.json.array(
        try definition_core.json.field(object, "keys"),
    );
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidObservationDistinctKeyCount;
    }
    const fields = try allocator.alloc(u16, values.items.len);
    errdefer allocator.free(fields);
    for (values.items, 0..) |value, index| {
        fields[index] = schema.find(
            try definition_core.json.string(value),
        ) orelse return error.UnknownObservationDistinctField;
        for (fields[0..index]) |prior| {
            if (prior == fields[index]) {
                return error.DuplicateObservationDistinctField;
            }
        }
    }
    return .{ .field_indices = fields };
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
        .integer, .number_string => fixed: {
            const count = definition_core.json.unsigned(value) catch
                return error.InvalidObservationLimit;
            if (count == 0 or count > definition_plan.bounds.max_rows) {
                return error.InvalidObservationLimit;
            }
            break :fixed .{ .fixed = count };
        },
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
        .number_string => |text| number: {
            const parsed = definition_core.exact_number.parse(text) orelse
                return error.InvalidFilterConstant;
            if (definition_core.exact_number.toI64(parsed)) |integer| {
                break :number .{ .integer = integer };
            }
            const float = std.fmt.parseFloat(f64, text) catch
                return error.InvalidFilterConstant;
            if (!std.math.isFinite(float) or
                !definition_core.exact_number.valuesEqual(
                    .{ .number_string = text },
                    .{ .float = float },
                ))
            {
                return error.InvalidFilterConstant;
            }
            break :number .{ .float = float };
        },
        .bool => |flag| .{ .boolean = flag },
        .null => .null,
        .array, .object => error.InvalidFilterConstant,
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
        column.kind != .string and column.kind != .json)
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
            {} else error.FilterPredicateTypeMismatch,
        },
        .parameter => |index| parameterColumnKind(
            definition_plan.parameter_declarations.items[index].kind,
        ),
    };
    if (column.kind == .json and operand_kind == .string and
        operator.requiresString())
    {
        return;
    }
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

pub fn encodeCache(
    native_plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(4);
    try encoder.writeCount(native_plan.stages.len);
    for (native_plan.stages) |stage| {
        try encoder.writeBytes(stage.name);
        try encoder.writeBool(stage.source != null);
        if (stage.source) |source| {
            try encoder.writeEnum(std.meta.activeTag(source));
            switch (source) {
                .stage => |index| try encoder.writeU16(index),
                .external => |index| try encoder.writeU16(index),
            }
        }
        try encodeSchema(&stage.schema, encoder);
        try encodeOperation(&stage.operation, encoder);
    }
    try encoder.writeCount(native_plan.projections.len);
    for (native_plan.projections) |projection| {
        try encoder.writeU16(projection.definition_index);
        try encoder.writeU16(projection.stage_index);
        try encoder.writeCount(projection.field_indices.len);
        for (projection.field_indices) |field| try encoder.writeU16(field);
    }
    try encoder.writeUsize(native_plan.max_rows);
    try encoder.writeUsize(native_plan.max_output_bytes);
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    definition_plan: *const definition.Plan,
) !Plan {
    if (try decoder.readU16() != 4) {
        return error.SeqNativePlanCacheVersionMismatch;
    }
    const stages = try decodeCacheStages(allocator, decoder);
    var stages_transferred = false;
    errdefer if (!stages_transferred) deinitStages(allocator, stages);
    const projections = try decodeCacheProjections(
        allocator,
        decoder,
        stages,
    );
    var projections_transferred = false;
    errdefer if (!projections_transferred) {
        deinitProjections(allocator, projections);
    };
    var result = Plan{
        .stages = stages,
        .projections = projections,
        .max_rows = try decoder.readUsize(),
        .max_output_bytes = try decoder.readUsize(),
    };
    stages_transferred = true;
    projections_transferred = true;
    errdefer result.deinit(allocator);
    try validateCachePlan(&result, definition_plan);
    return result;
}

fn decodeCacheStages(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]Stage {
    const stage_count = try decoder.readCount(256);
    if (stage_count == 0) return error.InvalidPipelineLength;
    const stages = try allocator.alloc(Stage, stage_count);
    var initialized: usize = 0;
    errdefer {
        for (stages[0..initialized]) |*stage| stage.deinit(allocator);
        allocator.free(stages);
    }
    for (stages, 0..) |*stage, index| {
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try definition_core.json.safeIdentifier(name, 128);
        for (stages[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, name)) {
                return error.DuplicatePipelineRelation;
            }
        }
        const source = if (try decoder.readBool())
            try decodeSource(decoder, index)
        else
            null;
        var schema = try decodeSchema(allocator, decoder);
        errdefer schema.deinit(allocator);
        var operation = try decodeOperation(
            allocator,
            decoder,
            &schema,
        );
        errdefer operation.deinit(allocator);
        stage.* = .{
            .name = name,
            .source = source,
            .operation = operation,
            .schema = schema,
        };
        initialized += 1;
    }
    return stages;
}

fn decodeCacheProjections(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    stages: []const Stage,
) ![]Projection {
    const projection_count = try decoder.readCount(64);
    if (projection_count == 0) return error.InvalidProjectionCount;
    const projections = try allocator.alloc(Projection, projection_count);
    var initialized: usize = 0;
    errdefer {
        for (projections[0..initialized]) |*projection| {
            projection.deinit(allocator);
        }
        allocator.free(projections);
    }
    for (projections) |*projection| {
        const definition_index = try decoder.readU16();
        const stage_index = try decoder.readU16();
        if (stage_index >= stages.len) {
            return error.CacheProjectionStageInvalid;
        }
        const field_count = try decoder.readCount(256);
        if (field_count == 0) return error.InvalidProjectionFieldCount;
        const fields = try allocator.alloc(u16, field_count);
        errdefer allocator.free(fields);
        for (fields, 0..) |*field, field_index| {
            field.* = try decoder.readU16();
            if (field.* >= stages[stage_index].schema.columns.len) {
                return error.CacheProjectionFieldInvalid;
            }
            for (fields[0..field_index]) |prior| {
                if (prior == field.*) {
                    return error.DuplicateProjectionField;
                }
            }
        }
        projection.* = .{
            .definition_index = definition_index,
            .stage_index = stage_index,
            .field_indices = fields,
        };
        initialized += 1;
    }
    return projections;
}

fn deinitStages(allocator: std.mem.Allocator, stages: []Stage) void {
    for (stages) |*stage| stage.deinit(allocator);
    allocator.free(stages);
}

fn deinitProjections(
    allocator: std.mem.Allocator,
    projections: []Projection,
) void {
    for (projections) |*projection| projection.deinit(allocator);
    allocator.free(projections);
}

pub fn validateCachePlan(
    native_plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    if (native_plan.stages.len != definition_plan.steps.len or
        native_plan.projections.len != definition_plan.projections.len or
        native_plan.max_rows != definition_plan.bounds.max_rows or
        native_plan.max_output_bytes != definition_plan.bounds.max_output_bytes)
    {
        return error.CacheObservationPlanShapeMismatch;
    }
    for (
        native_plan.stages,
        definition_plan.steps,
        0..,
    ) |stage, step, index| {
        try validateCacheStage(
            native_plan,
            definition_plan,
            stage,
            step,
            index,
        );
    }
    try validateCacheProjections(native_plan, definition_plan);
}

fn validateCacheStage(
    native_plan: *const Plan,
    definition_plan: *const definition.Plan,
    stage: Stage,
    step: definition.Step,
    index: usize,
) !void {
    const expected_name = step.output_name orelse
        return error.PipelineStageOutputMissing;
    if (!std.mem.eql(u8, stage.name, expected_name)) {
        return error.CacheObservationStageNameMismatch;
    }
    const expected_source = if (step.operator == .scan)
        null
    else
        try expectedSource(
            native_plan.stages[0..index],
            definition_plan.inputs,
            step.input_names[0],
        );
    if (!sourcesEqual(stage.source, expected_source)) {
        return error.CacheObservationSourceMismatch;
    }
    const source_schema = if (expected_source) |source|
        sourceSchema(
            native_plan.stages[0..index],
            definition_plan.inputs,
            source,
        )
    else
        null;
    switch (step.operator) {
        .scan => try validateCachedScan(definition_plan, stage),
        .filter => try validateCachedFilter(
            definition_plan,
            stage,
            source_schema.?,
        ),
        .project => try validateCachedProject(stage, source_schema.?),
        .aggregate => {
            const aggregate = switch (stage.operation) {
                .aggregate => |value| value,
                else => return error.CacheObservationOperationMismatch,
            };
            try validateAggregate(
                aggregate,
                &stage.schema,
                source_schema.?,
            );
        },
        .named_relation, .result_projection => {
            try validateCachedAlias(stage, source_schema.?);
        },
        .limit => try validateCachedLimit(
            native_plan,
            definition_plan,
            stage,
            source_schema.?,
        ),
        .sort => try validateCachedSort(stage, source_schema.?),
        .top_k => try validateCachedTopK(
            native_plan,
            definition_plan,
            stage,
            source_schema.?,
        ),
        .distinct => try validateCachedDistinct(stage, source_schema.?),
        else => return error.ObservationOperatorPlanNotCompiled,
    }
}

fn validateCachedScan(
    definition_plan: *const definition.Plan,
    stage: Stage,
) !void {
    const scan = switch (stage.operation) {
        .scan => |value| value,
        else => return error.CacheObservationOperationMismatch,
    };
    const requirement = findRelation(
        definition_plan.relations,
        scan.relation,
    ) orelse return error.UndeclaredPhysicalRelation;
    if (!std.mem.eql(u16, scan.field_indices, requirement.fields)) {
        return error.CachePhysicalFieldsMismatch;
    }
    try validatePhysicalSchema(
        &stage.schema,
        scan.relation,
        scan.field_indices,
    );
}

fn validateCachedFilter(
    definition_plan: *const definition.Plan,
    stage: Stage,
    source_schema: SourceSchema,
) !void {
    const filter = switch (stage.operation) {
        .filter => |value| value,
        else => return error.CacheObservationOperationMismatch,
    };
    try validateSameSchema(&stage.schema, source_schema);
    for (filter.predicates) |predicate| {
        if (predicate.field_index >= source_schema.columnCount()) {
            return error.CachePredicateFieldInvalid;
        }
        if (predicate.operand == .parameter and
            predicate.operand.parameter >=
                definition_plan.parameter_declarations.items.len)
        {
            return error.ObservationParameterIndexInvalid;
        }
        try validatePredicateTypes(
            definition_plan,
            source_schema.column(predicate.field_index),
            predicate.operator,
            predicate.operand,
            predicate.case_insensitive,
        );
    }
}

fn validateCachedProject(
    stage: Stage,
    source_schema: SourceSchema,
) !void {
    const project = switch (stage.operation) {
        .project => |value| value,
        else => return error.CacheObservationOperationMismatch,
    };
    if (project.input_field_indices.len != stage.schema.columns.len) {
        return error.CacheProjectionSchemaMismatch;
    }
    for (
        project.input_field_indices,
        stage.schema.columns,
    ) |field_index, column| {
        if (field_index >= source_schema.columnCount()) {
            return error.CacheProjectionFieldInvalid;
        }
        try validateColumn(column, source_schema.column(field_index));
    }
}

fn validateCachedAlias(stage: Stage, source_schema: SourceSchema) !void {
    if (stage.operation != .alias) {
        return error.CacheObservationOperationMismatch;
    }
    try validateSameSchema(&stage.schema, source_schema);
}

fn validateCachedLimit(
    native_plan: *const Plan,
    definition_plan: *const definition.Plan,
    stage: Stage,
    source_schema: SourceSchema,
) !void {
    const limit = switch (stage.operation) {
        .limit => |value| value,
        else => return error.CacheObservationOperationMismatch,
    };
    try validateSameSchema(&stage.schema, source_schema);
    try validateLimit(limit, definition_plan, native_plan.max_rows);
}

fn validateCachedSort(stage: Stage, source_schema: SourceSchema) !void {
    const sort = switch (stage.operation) {
        .sort => |value| value,
        else => return error.CacheObservationOperationMismatch,
    };
    try validateSameSchema(&stage.schema, source_schema);
    try validateSortKeys(sort.keys, source_schema);
}

fn validateCachedTopK(
    native_plan: *const Plan,
    definition_plan: *const definition.Plan,
    stage: Stage,
    source_schema: SourceSchema,
) !void {
    const top_k = switch (stage.operation) {
        .top_k => |value| value,
        else => return error.CacheObservationOperationMismatch,
    };
    try validateSameSchema(&stage.schema, source_schema);
    try validateSortKeys(top_k.keys, source_schema);
    try validateLimit(
        top_k.limit,
        definition_plan,
        native_plan.max_rows,
    );
}

fn validateCachedDistinct(
    stage: Stage,
    source_schema: SourceSchema,
) !void {
    const distinct = switch (stage.operation) {
        .distinct => |value| value,
        else => return error.CacheObservationOperationMismatch,
    };
    try validateSameSchema(&stage.schema, source_schema);
    if (distinct.field_indices.len == 0 or
        distinct.field_indices.len > 64)
    {
        return error.InvalidObservationDistinctKeyCount;
    }
    for (distinct.field_indices, 0..) |field_index, distinct_index| {
        if (field_index >= source_schema.columnCount()) {
            return error.CacheObservationDistinctFieldInvalid;
        }
        for (distinct.field_indices[0..distinct_index]) |prior| {
            if (prior == field_index) {
                return error.DuplicateObservationDistinctField;
            }
        }
    }
}

fn validateCacheProjections(
    native_plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    for (
        native_plan.projections,
        definition_plan.projections,
        0..,
    ) |projection, source, index| {
        if (projection.definition_index != index or
            projection.stage_index >= native_plan.stages.len or
            projection.field_indices.len != source.fields.len or
            !std.mem.eql(
                u8,
                native_plan.stages[projection.stage_index].name,
                source.relation,
            ))
        {
            return error.CacheObservationProjectionMismatch;
        }
        const schema =
            &native_plan.stages[projection.stage_index].schema;
        for (
            projection.field_indices,
            source.fields,
        ) |field_index, field_name| {
            if (field_index >= schema.columns.len or
                !std.mem.eql(
                    u8,
                    schema.columns[field_index].name,
                    field_name,
                ))
            {
                return error.CacheObservationProjectionMismatch;
            }
        }
    }
}

fn validateAggregate(
    aggregate: Aggregate,
    output_schema: *const Schema,
    input_schema: SourceSchema,
) !void {
    if (aggregate.metrics.len == 0 or
        aggregate.metrics.len > 64 or
        aggregate.metrics.len != output_schema.columns.len)
    {
        return error.InvalidObservationAggregateMetricCount;
    }
    for (
        aggregate.metrics,
        output_schema.columns,
    ) |metric, output_column| {
        if (metric.function != .count and metric.field_index == null) {
            return error.ObservationAggregateFieldRequired;
        }
        const input_kind: ColumnKind = if (metric.field_index) |field| kind: {
            if (field >= input_schema.columnCount()) {
                return error.CacheObservationAggregateFieldInvalid;
            }
            const kind = input_schema.column(field).kind;
            if (kind != .integer and kind != .float) {
                return error.ObservationAggregateFieldMustBeNumeric;
            }
            break :kind kind;
        } else .integer;
        const expected_kind: ColumnKind = switch (metric.function) {
            .count => .integer,
            .average => .float,
            .sum, .min, .max => input_kind,
        };
        const expected_nullable = metric.function == .average or
            metric.function == .min or
            metric.function == .max;
        if (output_column.kind != expected_kind or
            output_column.nullable != expected_nullable)
        {
            return error.CacheObservationAggregateSchemaMismatch;
        }
    }
}

fn validateSortKeys(
    keys: []const SortKey,
    source_schema: SourceSchema,
) !void {
    if (keys.len == 0 or keys.len > 64) {
        return error.InvalidObservationSortKeyCount;
    }
    for (keys, 0..) |key, key_index| {
        if (key.field_index >= source_schema.columnCount()) {
            return error.CacheObservationSortFieldInvalid;
        }
        for (keys[0..key_index]) |prior| {
            if (prior.field_index == key.field_index) {
                return error.DuplicateObservationSortField;
            }
        }
    }
}

fn validateLimit(
    limit: Limit,
    definition_plan: *const definition.Plan,
    max_rows: usize,
) !void {
    switch (limit) {
        .fixed => |count| if (count == 0 or count > max_rows) {
            return error.InvalidObservationLimit;
        },
        .parameter => |parameter| {
            if (parameter >=
                definition_plan.parameter_declarations.items.len or
                definition_plan.parameter_declarations
                    .items[parameter].kind != .integer)
            {
                return error.ObservationLimitParameterMustBeInteger;
            }
        },
    }
}

const SourceSchema = union(enum) {
    native: *const Schema,
    external: *const definition.ExternalInput,

    fn columnCount(self: SourceSchema) usize {
        return switch (self) {
            .native => |schema| schema.columns.len,
            .external => |input| input.fields.len,
        };
    }

    fn column(self: SourceSchema, index: usize) Column {
        return switch (self) {
            .native => |schema| schema.columns[index],
            .external => |input| .{
                .name = input.fields[index].name,
                .kind = externalKind(input.fields[index].kind),
                .nullable = input.fields[index].nullable,
            },
        };
    }
};

fn sourceSchema(
    stages: []const Stage,
    inputs: []const definition.ExternalInput,
    source: SourceRef,
) SourceSchema {
    return switch (source) {
        .stage => |index| .{ .native = &stages[index].schema },
        .external => |index| .{ .external = &inputs[index] },
    };
}

fn expectedSource(
    stages: []const Stage,
    inputs: []const definition.ExternalInput,
    name: []const u8,
) !SourceRef {
    if (findStageIndex(stages, name)) |index| {
        return .{ .stage = index };
    }
    for (inputs, 0..) |input, index| {
        if (std.mem.eql(u8, input.name, name)) {
            return .{ .external = @intCast(index) };
        }
    }
    return error.UnknownPipelineInput;
}

fn sourcesEqual(left: ?SourceRef, right: ?SourceRef) bool {
    if ((left == null) != (right == null)) return false;
    if (left == null) return true;
    return switch (left.?) {
        .stage => |index| right.? == .stage and
            right.?.stage == index,
        .external => |index| right.? == .external and
            right.?.external == index,
    };
}

fn validatePhysicalSchema(
    schema: *const Schema,
    relation: physical.Relation,
    field_indices: []const u16,
) !void {
    if (schema.columns.len != field_indices.len) {
        return error.CachePhysicalSchemaMismatch;
    }
    const fields = relation.fields();
    for (schema.columns, field_indices) |column, field_index| {
        if (field_index >= fields.len) {
            return error.PhysicalFieldIndexInvalid;
        }
        try validateColumn(column, .{
            .name = @constCast(fields[field_index].name),
            .kind = physicalKind(fields[field_index].kind),
            .nullable = fields[field_index].nullable,
        });
    }
}

fn validateSameSchema(
    schema: *const Schema,
    expected: SourceSchema,
) !void {
    if (schema.columns.len != expected.columnCount()) {
        return error.CacheObservationSchemaMismatch;
    }
    for (schema.columns, 0..) |column, index| {
        try validateColumn(column, expected.column(index));
    }
}

fn validateColumn(actual: Column, expected: Column) !void {
    if (!std.mem.eql(u8, actual.name, expected.name) or
        actual.kind != expected.kind or
        actual.nullable != expected.nullable)
    {
        return error.CacheObservationSchemaMismatch;
    }
}

fn encodeSchema(
    schema: *const Schema,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(schema.columns.len);
    for (schema.columns) |column| {
        try encoder.writeBytes(column.name);
        try encoder.writeEnum(column.kind);
        try encoder.writeBool(column.nullable);
    }
}

fn decodeSchema(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Schema {
    const count = try decoder.readCount(256);
    if (count == 0) return error.InvalidObservationSourceWidth;
    const columns = try allocator.alloc(Column, count);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |*column| column.deinit(allocator);
        allocator.free(columns);
    }
    for (columns, 0..) |*column, index| {
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try definition_core.json.safeIdentifier(name, 128);
        for (columns[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, name)) {
                return error.DuplicateObservationColumn;
            }
        }
        column.* = .{
            .name = name,
            .kind = try decoder.readEnum(ColumnKind),
            .nullable = try decoder.readBool(),
        };
        initialized += 1;
    }
    return .{ .columns = columns };
}

fn encodeOperation(
    operation: *const Operation,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeEnum(std.meta.activeTag(operation.*));
    switch (operation.*) {
        .scan => |scan| {
            try encoder.writeEnum(scan.relation);
            try encoder.writeCount(scan.field_indices.len);
            for (scan.field_indices) |field| try encoder.writeU16(field);
        },
        .filter => |filter| try encodeFilter(filter, encoder),
        .project => |project| {
            try encoder.writeCount(project.input_field_indices.len);
            for (project.input_field_indices) |field| {
                try encoder.writeU16(field);
            }
        },
        .aggregate => |aggregate| {
            try encoder.writeCount(aggregate.metrics.len);
            for (aggregate.metrics) |metric| {
                try encoder.writeEnum(metric.function);
                try encoder.writeBool(metric.field_index != null);
                if (metric.field_index) |field| try encoder.writeU16(field);
            }
        },
        .alias => {},
        .limit => |limit| {
            try encoder.writeEnum(std.meta.activeTag(limit));
            switch (limit) {
                .fixed => |count| try encoder.writeUsize(count),
                .parameter => |index| try encoder.writeU16(index),
            }
        },
        .sort => |sort| try encodeSortKeys(sort.keys, encoder),
        .top_k => |top_k| {
            try encodeSortKeys(top_k.keys, encoder);
            try encodeLimit(top_k.limit, encoder);
        },
        .distinct => |distinct| {
            try encoder.writeCount(distinct.field_indices.len);
            for (distinct.field_indices) |field_index| {
                try encoder.writeU16(field_index);
            }
        },
    }
}

fn encodeFilter(
    filter: Filter,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeEnum(filter.mode);
    try encoder.writeCount(filter.predicates.len);
    for (filter.predicates) |predicate| {
        try encoder.writeU16(predicate.field_index);
        try encoder.writeEnum(predicate.operator);
        try encoder.writeEnum(std.meta.activeTag(predicate.operand));
        switch (predicate.operand) {
            .parameter => |index| try encoder.writeU16(index),
            .constant => |constant| {
                try encoder.writeEnum(std.meta.activeTag(constant));
                switch (constant) {
                    .string => |text| try encoder.writeBytes(text),
                    .integer => |number| try encoder.writeI64(number),
                    .float => |number| try encoder.writeF64(number),
                    .boolean => |flag| try encoder.writeBool(flag),
                    .null => {},
                }
            },
        }
        try encoder.writeBool(predicate.case_insensitive);
    }
}

fn encodeSortKeys(
    keys: []const SortKey,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(keys.len);
    for (keys) |key| {
        try encoder.writeU16(key.field_index);
        try encoder.writeEnum(key.direction);
        try encoder.writeEnum(key.nulls);
    }
}

fn encodeLimit(
    limit: Limit,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeEnum(std.meta.activeTag(limit));
    switch (limit) {
        .fixed => |count| try encoder.writeUsize(count),
        .parameter => |index| try encoder.writeU16(index),
    }
}

fn decodeOperation(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    schema: *const Schema,
) !Operation {
    const tag = try decoder.readEnum(std.meta.Tag(Operation));
    return switch (tag) {
        .scan => .{ .scan = try decodeScan(allocator, decoder) },
        .filter => .{ .filter = try decodeFilter(
            allocator,
            decoder,
            schema,
        ) },
        .project => .{ .project = try decodeProject(allocator, decoder) },
        .aggregate => .{ .aggregate = try decodeAggregate(
            allocator,
            decoder,
            schema,
        ) },
        .alias => .alias,
        .limit => .{ .limit = try decodeLimit(decoder) },
        .sort => .{ .sort = try decodeSort(
            allocator,
            decoder,
            schema,
        ) },
        .top_k => .{ .top_k = try decodeTopK(
            allocator,
            decoder,
            schema,
        ) },
        .distinct => .{ .distinct = try decodeDistinct(
            allocator,
            decoder,
            schema,
        ) },
    };
}

fn decodeScan(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Scan {
    const relation = try decoder.readEnum(physical.Relation);
    const count = try decoder.readCount(relation.fields().len);
    if (count == 0) return error.EmptyPhysicalFieldSet;
    const fields = try allocator.alloc(u16, count);
    errdefer allocator.free(fields);
    for (fields, 0..) |*field, index| {
        field.* = try decoder.readU16();
        if (field.* >= relation.fields().len) {
            return error.PhysicalFieldIndexInvalid;
        }
        if (index != 0 and fields[index - 1] >= field.*) {
            return error.CachePhysicalFieldsNotSorted;
        }
    }
    return .{ .relation = relation, .field_indices = fields };
}

fn decodeFilter(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    schema: *const Schema,
) !Filter {
    const mode = try decoder.readEnum(FilterMode);
    const count = try decoder.readCount(64);
    if (count == 0) return error.InvalidFilterPredicateCount;
    const predicates = try allocator.alloc(Predicate, count);
    var initialized: usize = 0;
    errdefer {
        for (predicates[0..initialized]) |*predicate| {
            predicate.deinit(allocator);
        }
        allocator.free(predicates);
    }
    for (predicates) |*predicate| {
        const field_index = try decoder.readU16();
        if (field_index >= schema.columns.len) {
            return error.CachePredicateFieldInvalid;
        }
        const operator = try decoder.readEnum(PredicateOperator);
        var operand = try decodeOperand(allocator, decoder);
        errdefer operand.deinit(allocator);
        predicate.* = .{
            .field_index = field_index,
            .operator = operator,
            .operand = operand,
            .case_insensitive = try decoder.readBool(),
        };
        initialized += 1;
    }
    return .{ .mode = mode, .predicates = predicates };
}

fn decodeOperand(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Operand {
    return switch (try decoder.readEnum(std.meta.Tag(Operand))) {
        .parameter => .{ .parameter = try decoder.readU16() },
        .constant => .{ .constant = switch (try decoder.readEnum(
            std.meta.Tag(Constant),
        )) {
            .string => .{ .string = try decodeStringConstant(
                allocator,
                decoder,
            ) },
            .integer => .{ .integer = try decoder.readI64() },
            .float => float: {
                const value = try decoder.readF64();
                if (!std.math.isFinite(value)) {
                    return error.InvalidFilterConstant;
                }
                break :float .{ .float = value };
            },
            .boolean => .{ .boolean = try decoder.readBool() },
            .null => .null,
        } },
    };
}

fn decodeStringConstant(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]u8 {
    const value = try decoder.readBytesAlloc(
        allocator,
        4 * 1024 * 1024,
    );
    errdefer allocator.free(value);
    if (!std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidFilterConstant;
    }
    return value;
}

fn decodeProject(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Project {
    const count = try decoder.readCount(256);
    if (count == 0) return error.InvalidProjectionFieldCount;
    const fields = try allocator.alloc(u16, count);
    errdefer allocator.free(fields);
    for (fields, 0..) |*field, index| {
        field.* = try decoder.readU16();
        for (fields[0..index]) |prior| {
            if (prior == field.*) return error.DuplicateProjectionField;
        }
    }
    return .{ .input_field_indices = fields };
}

fn decodeAggregate(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    schema: *const Schema,
) !Aggregate {
    const count = try decoder.readCount(64);
    if (count == 0 or count != schema.columns.len) {
        return error.InvalidObservationAggregateMetricCount;
    }
    const metrics = try allocator.alloc(AggregateMetric, count);
    errdefer allocator.free(metrics);
    for (metrics) |*metric| {
        metric.* = .{
            .function = try decoder.readEnum(AggregateFunction),
            .field_index = if (try decoder.readBool())
                try decoder.readU16()
            else
                null,
        };
    }
    return .{ .metrics = metrics };
}

fn decodeLimit(
    decoder: *definition_core.cache.Decoder,
) !Limit {
    return switch (try decoder.readEnum(std.meta.Tag(Limit))) {
        .fixed => .{ .fixed = try decoder.readUsize() },
        .parameter => .{ .parameter = try decoder.readU16() },
    };
}

fn decodeSort(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    schema: *const Schema,
) !Sort {
    const count = try decoder.readCount(64);
    if (count == 0) return error.InvalidObservationSortKeyCount;
    const keys = try allocator.alloc(SortKey, count);
    errdefer allocator.free(keys);
    for (keys, 0..) |*key, index| {
        key.* = .{
            .field_index = try decoder.readU16(),
            .direction = try decoder.readEnum(SortDirection),
            .nulls = try decoder.readEnum(NullOrder),
        };
        if (key.field_index >= schema.columns.len) {
            return error.CacheObservationSortFieldInvalid;
        }
        for (keys[0..index]) |prior| {
            if (prior.field_index == key.field_index) {
                return error.DuplicateObservationSortField;
            }
        }
    }
    return .{ .keys = keys };
}

fn decodeTopK(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    schema: *const Schema,
) !TopK {
    var sort = try decodeSort(allocator, decoder, schema);
    errdefer sort.deinit(allocator);
    return .{
        .keys = sort.keys,
        .limit = try decodeLimit(decoder),
    };
}

fn decodeDistinct(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    schema: *const Schema,
) !Distinct {
    const count = try decoder.readCount(64);
    if (count == 0) return error.InvalidObservationDistinctKeyCount;
    const fields = try allocator.alloc(u16, count);
    errdefer allocator.free(fields);
    for (fields, 0..) |*field_index, index| {
        field_index.* = try decoder.readU16();
        if (field_index.* >= schema.columns.len) {
            return error.CacheObservationDistinctFieldInvalid;
        }
        for (fields[0..index]) |prior| {
            if (prior == field_index.*) {
                return error.DuplicateObservationDistinctField;
            }
        }
    }
    return .{ .field_indices = fields };
}

fn decodeSource(
    decoder: *definition_core.cache.Decoder,
    stage_index: usize,
) !SourceRef {
    return switch (try decoder.readEnum(std.meta.Tag(SourceRef))) {
        .stage => stage: {
            const index = try decoder.readU16();
            if (index >= stage_index) return error.CacheStageSourceInvalid;
            break :stage .{ .stage = index };
        },
        .external => .{ .external = try decoder.readU16() },
    };
}

fn compileForAllocationFailure(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !void {
    var compiled = try compile(allocator, definition_plan);
    defer compiled.deinit(allocator);
}

fn decodeCacheForAllocationFailure(
    allocator: std.mem.Allocator,
    payload: []const u8,
    definition_plan: *const definition.Plan,
) !void {
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(allocator, &decoder, definition_plan);
    defer cached.deinit(allocator);
    try decoder.finish();
}

const plan_filter_test_definition =
    \\{
    \\  "schema":"seq-observation-definition/v1",
    \\  "id":"example/messages",
    \\  "requires":{
    \\    "abi":"seq-observation-abi/v1",
    \\    "operators":["scan","filter","project","limit"]
    \\  },
    \\  "parameters":{"needle":{"type":"string","required":true}},
    \\  "selectors":["path"],
    \\  "relations":[{
    \\    "name":"messages","fields":["session_id","role","text"]
    \\  }],
    \\  "inputs":[],
    \\  "pipeline":[
    \\    {"op":"scan","relation":"messages","as":"source"},
    \\    {
    \\      "op":"filter","input":"source","as":"matched",
    \\      "where":[{"field":"text","op":"contains","param":"needle"}]
    \\    },
    \\    {
    \\      "op":"project","input":"matched","as":"rows",
    \\      "fields":["session_id","role","text"]
    \\    },
    \\    {"op":"limit","input":"rows","as":"bounded","limit":5}
    \\  ],
    \\  "projections":{"rows":{
    \\    "relation":"bounded","schema":"example-message-rows/v1",
    \\    "fields":["session_id","role","text"],"renderers":["json"]
    \\  }},
    \\  "bounds":{
    \\    "max_rows":100,"max_output_bytes":4096,"max_fold_states":8
    \\  }
    \\}
;

const external_test_definition =
    \\{
    \\  "schema":"seq-observation-definition/v1",
    \\  "id":"example/external",
    \\  "requires":{
    \\    "abi":"seq-observation-abi/v1",
    \\    "operators":["filter","project"]
    \\  },
    \\  "parameters":{},"selectors":[],"relations":[],
    \\  "inputs":[{
    \\    "name":"facts","schema":"example-facts/v1",
    \\    "fields":[
    \\      {"name":"id","type":"string","nullable":false},
    \\      {"name":"score","type":"integer","nullable":false}
    \\    ],
    \\    "max_rows":10,"max_bytes":4096
    \\  }],
    \\  "pipeline":[
    \\    {
    \\      "op":"filter","input":"facts","as":"matched",
    \\      "where":[{"field":"score","op":"exact","value":1}]
    \\    },
    \\    {
    \\      "op":"project","input":"matched","as":"rows","fields":["id"]
    \\    }
    \\  ],
    \\  "projections":{"rows":{
    \\    "relation":"rows","schema":"example-rows/v1",
    \\    "fields":["id"],"renderers":["json"]
    \\  }},
    \\  "bounds":{
    \\    "max_rows":10,"max_output_bytes":4096,"max_fold_states":2
    \\  }
    \\}
;

const order_test_definition =
    \\{
    \\  "schema":"seq-observation-definition/v1",
    \\  "id":"example/order",
    \\  "requires":{
    \\    "abi":"seq-observation-abi/v1",
    \\    "operators":["sort","distinct","top-k"]
    \\  },
    \\  "parameters":{},"selectors":[],"relations":[],
    \\  "inputs":[{
    \\    "name":"facts","schema":"example-facts/v1",
    \\    "fields":[
    \\      {"name":"id","type":"string","nullable":false},
    \\      {"name":"group","type":"string","nullable":false},
    \\      {"name":"score","type":"integer","nullable":true}
    \\    ],
    \\    "max_rows":10,"max_bytes":4096
    \\  }],
    \\  "pipeline":[
    \\    {
    \\      "op":"sort","input":"facts","as":"ranked",
    \\      "by":[
    \\        {
    \\          "field":"score","direction":"desc","nulls":"first"
    \\        },
    \\        {"field":"id"}
    \\      ]
    \\    },
    \\    {
    \\      "op":"distinct","input":"ranked","as":"unique",
    \\      "keys":["group"]
    \\    },
    \\    {
    \\      "op":"top-k","input":"unique","as":"rows",
    \\      "by":[{"field":"id"}],"limit":2
    \\    }
    \\  ],
    \\  "projections":{"rows":{
    \\    "relation":"rows","schema":"example-order/v1",
    \\    "fields":["id","group","score"],"renderers":["json"]
    \\  }},
    \\  "bounds":{
    \\    "max_rows":10,"max_output_bytes":4096,"max_fold_states":2
    \\  }
    \\}
;

fn expectPlanCacheRoundTrip(
    native_plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(native_plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(
        std.testing.allocator,
        &decoder,
        definition_plan,
    );
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try std.testing.expectEqual(
        native_plan.stages.len,
        cached.stages.len,
    );
    try std.testing.expectEqualSlices(
        u16,
        native_plan.stages[0].operation.scan.field_indices,
        cached.stages[0].operation.scan.field_indices,
    );
    const expected_field =
        native_plan.stages[1].operation.filter.predicates[0].field_index;
    try std.testing.expectEqual(
        expected_field,
        cached.stages[1].operation.filter.predicates[0].field_index,
    );
    const mismatched = try std.testing.allocator.dupe(u8, payload);
    defer std.testing.allocator.free(mismatched);
    mismatched[mismatched.len - 1] ^= 1;
    var mismatch_decoder = definition_core.cache.Decoder.init(mismatched);
    try std.testing.expectError(
        error.CacheObservationPlanShapeMismatch,
        decodeCache(
            std.testing.allocator,
            &mismatch_decoder,
            definition_plan,
        ),
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeCacheForAllocationFailure,
        .{ payload, definition_plan },
    );
}

fn expectOrderCacheRoundTrip(
    native_plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(native_plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(
        std.testing.allocator,
        &decoder,
        definition_plan,
    );
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try std.testing.expectEqual(
        native_plan.stages[0].operation.sort.keys[0],
        cached.stages[0].operation.sort.keys[0],
    );
    try std.testing.expectEqualSlices(
        u16,
        native_plan.stages[1].operation.distinct.field_indices,
        cached.stages[1].operation.distinct.field_indices,
    );
    try std.testing.expectEqual(
        native_plan.stages[2].operation.top_k.keys[0],
        cached.stages[2].operation.top_k.keys[0],
    );
}

test "observation steps compile field names and parameters to native indices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data = plan_filter_test_definition,
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
    try std.testing.expectEqual(
        @as(u16, 2),
        plan.stages[1].operation.filter.predicates[0].field_index,
    );
    try std.testing.expectEqual(
        @as(u16, 0),
        plan.stages[1].operation.filter.predicates[0].operand.parameter,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        plan.stages[2].schema.columns.len,
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        plan.stages[3].operation.limit.fixed,
    );
    try std.testing.expectEqual(@as(usize, 1), plan.projections.len);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{&definition_plan},
    );
    try expectPlanCacheRoundTrip(&plan, &definition_plan);
}

test "external relations compile to the same typed native stage schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data = external_test_definition,
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

test "sort and distinct plans cache compiled field indices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data = order_test_definition,
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
    var native_plan = try compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer native_plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        @as(u16, 2),
        native_plan.stages[0].operation.sort.keys[0].field_index,
    );
    try std.testing.expectEqual(
        SortDirection.descending,
        native_plan.stages[0].operation.sort.keys[0].direction,
    );
    try std.testing.expectEqual(
        NullOrder.first,
        native_plan.stages[0].operation.sort.keys[0].nulls,
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        native_plan.stages[1].operation.distinct.field_indices[0],
    );
    try std.testing.expectEqual(
        @as(u16, 0),
        native_plan.stages[2].operation.top_k.keys[0].field_index,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        native_plan.stages[2].operation.top_k.limit.fixed,
    );
    try expectOrderCacheRoundTrip(&native_plan, &definition_plan);
}
